#!/usr/bin/env bash
# Runs the whole demo unattended and checks that the failures still happen.
#
# The point is not that the commands exit zero. The point is that the service
# still breaks in the specific ways the talk promises: a pod that restarts
# itself in act 1, a connection wall and a climbing node count in act 2. A demo
# that quietly stopped failing would pass every ordinary test and ruin the talk.
#
# Takes roughly twenty minutes. Run it the day before, not an hour before.

set -uo pipefail

DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEMO_ROOT"

STATE="${DEMO_STATE:-/tmp/probes-demo}"
LOG="${SMOKE_LOG:-$STATE/smoke.log}"
mkdir -p "$STATE"

if [ -t 1 ]; then
  C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'
else
  C_OFF=; C_B=; C_DIM=; C_OK=; C_BAD=
fi

PASS=0
FAIL=0

check() { # check DESCRIPTION ACTUAL EXPECTATION_TEXT TEST...
  local desc="$1" actual="$2" expect="$3"; shift 3
  if "$@"; then
    printf '  %s+%s %-46s %s%s%s\n' "$C_OK" "$C_OFF" "$desc" "$C_DIM" "$actual" "$C_OFF"
    PASS=$((PASS + 1))
  else
    printf '  %sx%s %-46s %sgot %s, expected %s%s\n' \
      "$C_BAD" "$C_OFF" "$desc" "$C_BAD" "$actual" "$expect" "$C_OFF"
    FAIL=$((FAIL + 1))
  fi
}

jget() { # jget LABEL FIELD
  jq -r "$2 // 0" "$STATE/$1.json" 2>/dev/null || echo 0
}

fileval() { cat "$STATE/$1" 2>/dev/null || echo 0; }

printf '\n  %ssmoke -- the whole demo, unattended%s\n' "$C_B" "$C_OFF"
printf '  %sthis takes about twenty minutes; output goes to %s%s\n\n' "$C_DIM" "$LOG" "$C_OFF"

./scripts/preflight.sh || {
  printf '\n  %spreflight failed -- fix that before smoking%s\n\n' "$C_BAD" "$C_OFF"
  exit 1
}

printf '\n  %sresetting%s\n' "$C_DIM" "$C_OFF"
./demo --reset >/dev/null 2>&1

printf '  %srunning every beat%s\n\n' "$C_DIM" "$C_OFF"

# The driver reads one key per prompt. With stdin a pipe it treats end-of-input
# as "next", so an endless stream of newlines walks it through the whole show
# without a person -- and every wait still runs to its full length, because
# watch_pods only accepts an early exit from a real terminal.
yes '' | ./demo > "$LOG" 2>&1
RC=$?

printf '\n  %sact 1 -- liveness kills a healthy pod%s\n' "$C_B" "$C_OFF"

BEFORE_RESTARTS=$(fileval act1-before.restarts)
AFTER_RESTARTS=$(fileval act1-after.restarts)

check 'the broken probe restarts pods' "$BEFORE_RESTARTS restarts" 'more than 0' \
  test "$BEFORE_RESTARTS" -gt 0
check 'the fixed probe does not' "$AFTER_RESTARTS restarts" '0' \
  test "$AFTER_RESTARTS" -eq 0

BEFORE_5XX=$(jget act1-before .server_err)
AFTER_OK=$(jget act1-after .ok)

check 'the broken run serves errors' "$BEFORE_5XX 5xx" 'more than 0' \
  test "$BEFORE_5XX" -gt 0
check 'the fixed run serves traffic' "$AFTER_OK requests" 'more than 0' \
  test "$AFTER_OK" -gt 0

printf '\n  %sact 2 -- the probe that buys EC2%s\n' "$C_B" "$C_OFF"

BEFORE_NODES=$(fileval act2-before.nodes)
AFTER_NODES=$(fileval act2-after.nodes)

check 'the cascade buys nodes' "$BEFORE_NODES nodes" 'at least 2' \
  test "$BEFORE_NODES" -ge 2
check 'the fix needs fewer' "$AFTER_NODES nodes" "fewer than $BEFORE_NODES" \
  test "$AFTER_NODES" -lt "$BEFORE_NODES"

# The evidence that the wall was actually reached, rather than the workers
# merely being slow. Without this line in the logs, act 2 told a story the
# cluster did not live.
if grep -qi 'too many connections\|pool at [0-9]*/' "$LOG"; then
  printf '  %s+%s %-46s %sfound in the logs%s\n' "$C_OK" "$C_OFF" 'the connection wall was reached' "$C_DIM" "$C_OFF"
  PASS=$((PASS + 1))
else
  printf '  %sx%s %-46s %sno connection error in the logs%s\n' \
    "$C_BAD" "$C_OFF" 'the connection wall was reached' "$C_BAD" "$C_OFF"
  FAIL=$((FAIL + 1))
fi

printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '  %s%d of %d checks failed%s -- read %s\n\n' "$C_BAD" "$FAIL" "$((PASS + FAIL))" "$C_OFF" "$LOG"
  exit 1
fi

printf '  %sall %d checks passed%s. the demo still breaks the way it should.\n\n' "$C_OK" "$PASS" "$C_OFF"
[ "$RC" -eq 0 ] || printf '  %snote: the driver exited %s%s\n\n' "$C_DIM" "$RC" "$C_OFF"
