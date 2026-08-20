#!/usr/bin/env bash
# Round-trips secret values through the real encoder (setup-doppler/doppler-export,
# with a stub curl standing in for the Doppler API) and back through dotenv_decode,
# asserting byte equality. Guards the escaping chain that feeds `flyctl secrets set`.
#
#   .github/scripts/test-dotenv.sh

set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "needs bash 4+ (doppler-export uses \${k^^}); got $BASH_VERSION" >&2
  exit 1
fi

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

# Every case is a value as it sits in Doppler. Byte-for-byte, this is what the
# container must receive.
names=(
  PLAIN_TOKEN
  JSON_SIMPLE
  JSON_ESCAPED_NEWLINE
  PEM_MULTILINE
  DOLLAR_AND_BACKTICK
  HASH_IN_VALUE
  EMPTY
  TRAILING_NEWLINE
)
# shellcheck disable=SC2016  # $ and ` are literal payload, not expansions
values=(
  'dop_v1_abc123DEF456'
  '{"type":"service_account","project_id":"corelens","client_email":"a@b.iam.gserviceaccount.com"}'
  '{"type":"service_account","private_key":"-----BEGIN PRIVATE KEY-----\nMIIBVgIBADAN\n-----END PRIVATE KEY-----\n"}'
  $'-----BEGIN PRIVATE KEY-----\nMIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8\nAgEAAiEA1nQ\n-----END PRIVATE KEY-----\n'
  'p$ssw`rd`$(whoami)${HOME}'
  'value#not-a-comment "quoted" tail'
  ''
  $'first line\nsecond line\n'
)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

jq_args=()
for i in "${!names[@]}"; do
  jq_args+=(--arg "${names[$i]}" "${values[$i]}")
done
jq -n "${jq_args[@]}" '$ARGS.named' >"$workdir/doppler-response.json"

# doppler-export shells out to curl; hand it the fixture instead of the network.
mkdir -p "$workdir/bin"
cat >"$workdir/bin/curl" <<EOF
#!/usr/bin/env bash
cat "$workdir/doppler-response.json"
EOF
chmod +x "$workdir/bin/curl"

# stderr carries ::add-mask:: directives that are noise here.
dotenv=$(PATH="$workdir/bin:$PATH" DOPPLER_TOKEN=stub \
  "$repo_root/setup-doppler/doppler-export" stub-project stub-config 2>/dev/null)

echo "== encoder wire format =="

# Each secret must occupy exactly one line: flyctl secrets import (still the
# documented direct-pipe recipe) and most dotenv parsers read line by line.
check "one line per key" "${#names[@]}" "$(grep -c '^[A-Za-z_][A-Za-z0-9_]*=' <<<"$dotenv")"
check "line count" "${#names[@]}" "$(wc -l <<<"$dotenv" | tr -d ' ')"

check "plain value is quoted" \
  'PLAIN_TOKEN="dop_v1_abc123DEF456"' \
  "$(grep '^PLAIN_TOKEN=' <<<"$dotenv")"
check "quotes are escaped" \
  'JSON_SIMPLE="{\"type\":\"service_account\",\"project_id\":\"corelens\",\"client_email\":\"a@b.iam.gserviceaccount.com\"}"' \
  "$(grep '^JSON_SIMPLE=' <<<"$dotenv")"
check "empty value is a bare pair of quotes" \
  'EMPTY=""' \
  "$(grep '^EMPTY=' <<<"$dotenv")"

echo
echo "== dotenv_decode round trip =="

for i in "${!names[@]}"; do
  name=${names[$i]}
  enc=$(grep "^${name}=" <<<"$dotenv" | head -n1)
  dotenv_decode "${enc#*=}"
  check "$name" "${values[$i]}" "$DECODED"
done

echo
echo "== dotenv_to_args =="

dotenv_to_args "$dotenv"
check "arg count" "${#names[@]}" "${#SECRET_ARGS[@]}"
for i in "${!names[@]}"; do
  check "argv ${names[$i]}" "${names[$i]}=${values[$i]}" "${SECRET_ARGS[$i]}"
done

# Blank lines, comments and the trailing blank that load-secrets.sh appends when
# EXTRA_SECRETS is empty must not become argv words.
dotenv_to_args $'A="one"\n\n# comment\nB="two"\n'
check "skips blanks and comments" "A=one B=two" "${SECRET_ARGS[*]}"

# flyctl reads a value of exactly "-" from stdin, so at most one key can hold it.
dotenv_to_args $'A="-"\nB="two"\n'
check "single dash value is allowed" "A=- B=two" "${SECRET_ARGS[*]}"
if dotenv_to_args $'A="-"\nB="-"\n' 2>/dev/null; then
  fail "two dash values are rejected" "non-zero exit" "exit 0"
else
  pass "two dash values are rejected"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
