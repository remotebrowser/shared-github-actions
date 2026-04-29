#!/usr/bin/env bash
# Sourced by deploy-fly and test-on-fly. One doppler-export call total per
# action invocation; the in-memory output is reused for both FLY_API_TOKEN
# resolution and the eventual `flyctl secrets import`.
#
# Inputs (env, set by caller):
#   DOPPLER_TOKEN        optional; when set, secrets are fetched from Doppler
#   DOPPLER_PROJECT      required when DOPPLER_TOKEN is set
#   DOPPLER_CONFIG       required when DOPPLER_TOKEN is set
#   FLY_API_TOKEN_INPUT  optional; the caller's `fly-api-token` action input
#   EXTRA_SECRETS        optional; dotenv lines appended after Doppler keys
#
# Outputs (exported into caller shell):
#   FLY_API_TOKEN  resolved token (also written to $GITHUB_ENV and ::add-mask::'d)
#   FLY_ORG_SLUG   extracted from Doppler when present (also written to $GITHUB_ENV).
#                  Empty if Doppler doesn't have it. Callers needing --org should
#                  check and either fall back or fail with a clearer error.
#   SECRETS        full dotenv stream: Doppler + GIT_REV + EXTRA_SECRETS
#
# Errors via `return 1` so that callers' `set -e` propagates without killing
# their shell prematurely; falls back to `exit 1` if not sourced.

set -euo pipefail

SECRETS=""
DOPPLER_FLY_TOKEN=""
if [ -n "${DOPPLER_TOKEN:-}" ]; then
  SECRETS=$(doppler-export "$DOPPLER_PROJECT" "$DOPPLER_CONFIG")
  if ! grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' <<<"$SECRETS"; then
    echo "refusing to proceed: Doppler returned 0 keys" >&2
    # shellcheck disable=SC2317  # both arms reachable depending on source vs exec
    return 1 2>/dev/null || exit 1
  fi
  DOPPLER_FLY_TOKEN=$(sed -n 's/^FLY_API_TOKEN="\(.*\)"$/\1/p' <<<"$SECRETS" | head -n1)
fi

if [ -n "${FLY_API_TOKEN_INPUT:-}" ]; then
  if [ -n "$DOPPLER_FLY_TOKEN" ] && [ "$DOPPLER_FLY_TOKEN" != "$FLY_API_TOKEN_INPUT" ]; then
    echo "::warning::fly-api-token input is set AND Doppler holds a different FLY_API_TOKEN; using the input value."
  fi
  FLY_API_TOKEN="$FLY_API_TOKEN_INPUT"
elif [ -n "$DOPPLER_FLY_TOKEN" ]; then
  FLY_API_TOKEN="$DOPPLER_FLY_TOKEN"
else
  echo "FLY_API_TOKEN not available: pass fly-api-token explicitly, or set FLY_API_TOKEN in Doppler." >&2
  # shellcheck disable=SC2317  # both arms reachable depending on source vs exec
  return 1 2>/dev/null || exit 1
fi
echo "::add-mask::$FLY_API_TOKEN"
{
  echo "FLY_API_TOKEN<<__EOF_FLY_API_TOKEN__"
  printf '%s\n' "$FLY_API_TOKEN"
  echo "__EOF_FLY_API_TOKEN__"
} >>"$GITHUB_ENV"
export FLY_API_TOKEN

# Extract FLY_ORG_SLUG from Doppler so callers can pass --org to flyctl
# (notably `flyctl apps create`, which prompts interactively without it).
# Not masked — org slugs are public.
FLY_ORG_SLUG=""
if [ -n "$SECRETS" ]; then
  FLY_ORG_SLUG=$(sed -n 's/^FLY_ORG_SLUG="\(.*\)"$/\1/p' <<<"$SECRETS" | head -n1)
fi
if [ -n "$FLY_ORG_SLUG" ]; then
  echo "FLY_ORG_SLUG=$FLY_ORG_SLUG" >>"$GITHUB_ENV"
fi
export FLY_ORG_SLUG

# Final stream: Doppler first, then GIT_REV, then EXTRA_SECRETS (last wins on dup keys).
SECRETS=$(printf '%s\nGIT_REV="%s"\n%s\n' "$SECRETS" "$GITHUB_SHA" "${EXTRA_SECRETS:-}")
export SECRETS
