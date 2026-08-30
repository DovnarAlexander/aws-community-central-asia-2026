#!/usr/bin/env bash
# Prints the ExpiresAt tag value every unit in the demo stack is tagged with.
#
# Read by infra/root.hcl. `task up` exports PROBES_EXPIRES_AT once so that every
# unit in a run agrees on the same instant and repeated plans stay stable; a
# bare `terragrunt` invocation falls back to eight hours from now, which is long
# enough for a working session and short enough that forgetting costs one night.
set -euo pipefail

if [ -n "${PROBES_EXPIRES_AT:-}" ]; then
  printf '%s' "$PROBES_EXPIRES_AT"
  exit 0
fi

HOURS="${PROBES_TTL_HOURS:-8}"

if date -u -v+1H >/dev/null 2>&1; then
  printf '%s' "$(date -u -v+"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ)"   # BSD, macOS
else
  printf '%s' "$(date -u -d "+${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"  # GNU
fi
