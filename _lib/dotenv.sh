#!/usr/bin/env bash
# Sourced by _lib/load-secrets.sh, so it is in scope for every action that loads
# secrets.
#
# setup-doppler/doppler-export emits dotenv: each value is wrapped in double
# quotes with \ " $ ` LF and CR escaped (see its `dotenv)` case). That is correct
# dotenv, but only a dotenv parser undoes it. Anything that hands a value to a
# program instead has to decode it first, or the escaping reaches the app
# verbatim — a JSON secret arrives as {\"type\": ...} and fails to parse.

# Reverses the doppler-export escaping for one value, leaving the plain bytes in
# DECODED. A single left-to-right pass is unambiguous because every literal
# backslash was doubled on the way in.
DECODED=""
dotenv_decode() {
  local enc=$1 out
  enc=${enc#\"}
  enc=${enc%\"}
  # `$( )` strips trailing newlines and a PEM value ends with one, so close the
  # substitution with a sentinel byte and cut it back off.
  out=$(printf '%s' "$enc" | perl -pe 's/\\(.)/ $1 eq "n" ? "\n" : ($1 eq "r" ? "\r" : $1) /ge'; printf X)
  DECODED=${out%X}
}

# Turns a dotenv stream into SECRET_ARGS, an array of decoded `KEY=VALUE` argv
# words for `flyctl secrets set`. argv carries quotes, backslashes and real
# newlines; `flyctl secrets import` reads stdin line by line and cannot. Blank
# lines and anything that isn't KEY= are skipped, matching the `keys` listing
# the callers compute alongside this.
SECRET_ARGS=()
dotenv_to_args() {
  local line key dashes=()
  SECRET_ARGS=()
  while IFS= read -r line; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key=${line%%=*}
    dotenv_decode "${line#*=}"
    if [ "$DECODED" = "-" ]; then
      dashes+=("$key")
    fi
    SECRET_ARGS+=("${key}=${DECODED}")
  done <<<"$1"
  # `flyctl secrets set` treats a value of exactly `-` as "read this one from
  # stdin" (`secrets import` has no such rule). Callers pass a literal `-` on
  # stdin so a single such key still round-trips, but stdin is consumed by the
  # first read and Go map order decides which key gets it.
  if [ "${#dashes[@]}" -gt 1 ]; then
    echo "::error::${#dashes[@]} secrets hold the literal value '-' (${dashes[*]}); flyctl secrets set can only take one of those from stdin" >&2
    return 1
  fi
}
