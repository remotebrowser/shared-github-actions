#!/usr/bin/env bash
# Sources _lib/load-secrets.sh with a stub `op` standing in for 1Password, and
# checks that each op:// reference reaches SECRETS with its exact bytes and is
# masked, and that a bad line, a failed read or a missing token stops the load.
#
#   .github/scripts/test-onepassword.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=_lib/dotenv.sh
. "$repo_root/_lib/dotenv.sh"

failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  printf '        want %q\n        got  %q\n' "$2" "$3"
  failures=$((failures + 1))
}
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}
contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "*$2*" "$3"; fi
}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# The stub answers `op read --no-newline <ref>` from one file per reference, so a
# value keeps its exact bytes, and logs each call.
mkdir -p "$workdir/bin" "$workdir/vault"
cat >"$workdir/bin/op" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$OP_STUB_DIR/calls"
if [ "$#" -ne 3 ] || [ "$1 $2" != "read --no-newline" ]; then
  echo "stub op: unexpected arguments: $*" >&2
  exit 2
fi
file="$OP_STUB_DIR/$(printf '%s' "$3" | tr '/:' '__')"
if [ ! -f "$file" ]; then
  echo "[ERROR] could not read secret '$3'" >&2
  exit 1
fi
cat "$file"
EOF
chmod +x "$workdir/bin/op"

put() {
  printf '%s' "$2" >"$workdir/vault/$(printf '%s' "$1" | tr '/:' '__')"
}

# shellcheck disable=SC2016  # $ and ` are literal payload, not expansions
dollar_value='p$ssw`rd`$(whoami)${HOME}'
json_value='{"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"}'
pem_value=$'-----BEGIN PRIVATE KEY-----\nMIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8\n-----END PRIVATE KEY-----\n'
put op://ci/DATABASE_URL/credential 'postgres://app:s3cret@db.internal:5432/app'
put op://ci/SERVICE_ACCOUNT/credential "$json_value"
put op://ci/TLS_KEY/private/key "$pem_value"
put op://ci/WEIRD/credential "$dollar_value"
put op://ci/FLY_API_TOKEN/credential 'fo1_flytoken123'

# Sources load-secrets.sh in a child bash with the given env, and leaves its exit
# status in status, its stdout and stderr in out and err, and SECRETS in secrets.
load() {
  rm -f "$workdir/vault/calls" "$workdir/secrets"
  : >"$workdir/github_env"
  set +e
  # shellcheck disable=SC2016  # the child bash expands $1, $2 and $SECRETS
  env GITHUB_ENV="$workdir/github_env" OP_STUB_DIR="$workdir/vault" PATH="$workdir/bin:$PATH" "$@" \
    bash -c '. "$1" && printf "%s" "$SECRETS" >"$2"' _ "$repo_root/_lib/load-secrets.sh" "$workdir/secrets" \
    >"$workdir/out" 2>"$workdir/err"
  status=$?
  set -e
  out=$(cat "$workdir/out")
  err=$(cat "$workdir/err")
  secrets=$(cat "$workdir/secrets" 2>/dev/null || true)
}

# Decodes one key of the SECRETS stream into DECODED.
value_of() {
  local enc
  enc=$(grep "^$1=" <<<"$secrets" | head -n1)
  dotenv_decode "${enc#*=}"
}

echo "== references are read with their exact bytes =="

load OP_SERVICE_ACCOUNT_TOKEN=stub \
  FLY_API_TOKEN_INPUT=op://ci/FLY_API_TOKEN/credential \
  ONEPASSWORD_SECRETS=$'DATABASE_URL=op://ci/DATABASE_URL/credential\n\n# a comment\nSERVICE_ACCOUNT=op://ci/SERVICE_ACCOUNT/credential\nTLS_KEY=op://ci/TLS_KEY/private/key\nWEIRD=op://ci/WEIRD/credential' \
  EXTRA_SECRETS=$'PLAIN=literal\nDATABASE_URL=override'
check "exit status" 0 "$status"
value_of SERVICE_ACCOUNT
check "json value" "$json_value" "$DECODED"
value_of TLS_KEY
check "pem value with a section and a trailing newline" "$pem_value" "$DECODED"
value_of WEIRD
check "dollar and backtick value" "$dollar_value" "$DECODED"
value_of PLAIN
check "extra-secrets value" "literal" "$DECODED"

dotenv_to_args "$secrets"
check "extra-secrets comes after 1Password" \
  "DATABASE_URL=postgres://app:s3cret@db.internal:5432/app DATABASE_URL=override" \
  "$(printf '%s\n' "${SECRET_ARGS[@]}" | grep '^DATABASE_URL=' | paste -sd ' ' -)"

contains "fly-api-token reference is read" "fo1_flytoken123" "$(cat "$workdir/github_env")"
check "fly-api-token is not staged" "" "$(grep '^FLY_API_TOKEN=' <<<"$secrets" || true)"
contains "a value is masked" "::add-mask::postgres://app:s3cret@db.internal:5432/app" "$out"
contains "each line of a multi-line value is masked" \
  "::add-mask::MIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8" "$out"
check "one op read for each reference" 5 "$(wc -l <"$workdir/vault/calls" | tr -d ' ')"

echo
echo "== a missing token stops the load before op runs =="

load FLY_API_TOKEN_INPUT=fo1_plain ONEPASSWORD_SECRETS='DATABASE_URL=op://ci/DATABASE_URL/credential'
check "exit status is not zero" 1 "$((status != 0))"
contains "error names the token input" "onepassword-token is not set" "$err"
check "op is not called" "false" "$([ -f "$workdir/vault/calls" ] && echo true || echo false)"

load FLY_API_TOKEN_INPUT=op://ci/FLY_API_TOKEN/credential
check "fly-api-token reference without a token fails" 1 "$((status != 0))"

echo
echo "== a line that is not a reference stops the load =="

load OP_SERVICE_ACCOUNT_TOKEN=stub FLY_API_TOKEN_INPUT=fo1_plain \
  ONEPASSWORD_SECRETS=$'DATABASE_URL=op://ci/DATABASE_URL/credential\nLEAKED=postgres://app:hunter2@db'
check "exit status is not zero" 1 "$((status != 0))"
contains "error names the line number" "onepassword-secrets line 2" "$err"
check "error does not show the line" "false" "$([[ "$err$out" == *hunter2* ]] && echo true || echo false)"
check "no SECRETS stream" "" "$secrets"

echo
echo "== a failed read stops the load =="

load OP_SERVICE_ACCOUNT_TOKEN=stub FLY_API_TOKEN_INPUT=fo1_plain \
  ONEPASSWORD_SECRETS='MISSING=op://ci/MISSING/credential'
check "exit status is not zero" 1 "$((status != 0))"
contains "error names the key" "op read failed for onepassword-secrets MISSING" "$err"
check "no SECRETS stream" "" "$secrets"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
