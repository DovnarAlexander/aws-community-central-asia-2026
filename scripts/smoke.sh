#!/usr/bin/env bash
# Runs the whole demo unattended and checks that the failures still happen.
#
# The point is not that the commands exit zero. The point is that the service
# still breaks in the specific ways the talk promises: a pod that restarts
# itself in incident 1, a connection wall and a climbing node count in incident 2. A demo
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

# An empty summary file is not the same as a missing one, and jq answers both
# with silence rather than an error -- which reached `test` as an empty string
# and buried the real failure under "integer expression expected".
jget() { # jget LABEL FIELD
  local v; v=$(jq -r "$2 // 0" "$STATE/$1.json" 2>/dev/null)
  case "$v" in ''|null) echo 0 ;; *) echo "$v" ;; esac
}

fileval() {
  local v; v=$(cat "$STATE/$1" 2>/dev/null)
  case "$v" in '') echo 0 ;; *) echo "$v" ;; esac
}

# Ctrl-C halfway through leaves workers, nodes and a deep queue behind, which is
# the same poisoned stage by a different route.
trap 'printf "\n  interrupted -- resetting\n"; ./demo --reset >/dev/null 2>&1; exit 130' INT TERM

printf '\n  %ssmoke -- the whole demo, unattended%s\n' "$C_B" "$C_OFF"
printf '  %sthis takes about twenty minutes; output goes to %s%s\n\n' "$C_DIM" "$LOG" "$C_OFF"

./scripts/preflight.sh || {
  printf '\n  %spreflight failed -- fix that before smoking%s\n\n' "$C_BAD" "$C_OFF"
  exit 1
}

printf '\n  %sresetting%s\n' "$C_DIM" "$C_OFF"
./demo --reset >/dev/null 2>&1

printf '  %srunning every step%s\n\n' "$C_DIM" "$C_OFF"

# The driver reads one key per prompt. With stdin a pipe it treats end-of-input
# as "next", so an endless stream of newlines walks it through the whole show
# without a person -- and every wait still runs to its full length, because
# watch_pods only accepts an early exit from a real terminal.
yes '' | ./demo > "$LOG" 2>&1
RC=$?

printf '\n  %sact 1 -- liveness kills a healthy pod%s\n' "$C_B" "$C_OFF"

BEFORE_RESTARTS=$(fileval incident1-before.restarts)
AFTER_RESTARTS=$(fileval incident1-after.restarts)

check 'the broken probe restarts pods' "$BEFORE_RESTARTS restarts" 'more than 0' \
  test "$BEFORE_RESTARTS" -gt 0
check 'the fixed probe does not' "$AFTER_RESTARTS restarts" '0' \
  test "$AFTER_RESTARTS" -eq 0

BEFORE_5XX=$(jget incident1-before .server_err)
AFTER_OK=$(jget incident1-after .ok)

check 'the broken run serves errors' "$BEFORE_5XX 5xx" 'more than 0' \
  test "$BEFORE_5XX" -gt 0
check 'the fixed run serves traffic' "$AFTER_OK requests" 'more than 0' \
  test "$AFTER_OK" -gt 0

printf '\n  %sact 2 -- the probe that buys EC2%s\n' "$C_B" "$C_OFF"

BEFORE_NODES=$(fileval incident2-before.nodes)
AFTER_NODES=$(fileval incident2-after.nodes)
BEFORE_READY=$(fileval incident2-before.workers_ready)
BEFORE_TOTAL=$(fileval incident2-before.workers_total)
AFTER_READY=$(fileval incident2-after.workers_ready)
AFTER_TOTAL=$(fileval incident2-after.workers_total)

check 'the cascade buys nodes' "$BEFORE_NODES nodes" 'at least 2' \
  test "$BEFORE_NODES" -ge 2

# Not "fewer nodes afterwards": the NodePool's consolidateAfter is 2m and the
# step is ninety seconds, so a node count that came down inside the window would
# mean Karpenter had been reconfigured, not that the fix worked. What the fix
# has to show here is that nothing else was bought.
check 'the fix stops buying' "$AFTER_NODES nodes" "no more than $BEFORE_NODES" \
  test "$AFTER_NODES" -le "$BEFORE_NODES"

# The number the incident actually turns on. Before: workers up, most of them
# NotReady, which is why the queue ran away. After: every one of them serving.
# Halves rather than "all of them": KEDA adds and replaces workers continuously,
# so at the instant of the mark a freshly created pod is legitimately not Ready
# yet. Requiring every one of them would make this a test of timing instead of a
# test of the fix. Measured so far: 0 of 24 before, 10 of 12 after.
check 'the cascade leaves workers NotReady' "$BEFORE_READY of $BEFORE_TOTAL ready" \
  'fewer than half' test "$((BEFORE_READY * 2))" -lt "$BEFORE_TOTAL"
check 'the fix makes the workers serve' "$AFTER_READY of $AFTER_TOTAL ready" \
  'more than half' test "$((AFTER_READY * 2))" -gt "$AFTER_TOTAL"
check 'and there are workers at all' "$AFTER_TOTAL workers" 'more than 0' \
  test "$AFTER_TOTAL" -gt 0

# The evidence that the wall was actually reached, rather than the workers
# merely being slow. Without this line in the logs, incident 2 told a story the
# cluster did not live.
if grep -qi 'too many connections\|pool at [0-9]*/' "$LOG"; then
  printf '  %s+%s %-46s %sfound in the logs%s\n' "$C_OK" "$C_OFF" 'the connection wall was reached' "$C_DIM" "$C_OFF"
  PASS=$((PASS + 1))
else
  printf '  %sx%s %-46s %sno connection error in the logs%s\n' \
    "$C_BAD" "$C_OFF" 'the connection wall was reached' "$C_BAD" "$C_OFF"
  FAIL=$((FAIL + 1))
fi

# The show ends on step 2.4, which means it ends with the fixed svc, a worker
# deployment and a ScaledObject that KEDA keeps populated for as long as the
# queue is deep -- and after a smoke run the queue is very deep. Leaving that
# behind poisons the next `task stage`: incident 1 plays with incident 2's workers already
# running, KEDA scaling in the background, and incident 2's reveal spent before it
# starts. Reset here, after the assertions have read everything they need.
printf '\n  %sputting the cluster back to the state the show starts from%s\n' "$C_DIM" "$C_OFF"
./demo --reset >/dev/null 2>&1

printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '  %s%d of %d checks failed%s -- read %s\n\n' "$C_BAD" "$FAIL" "$((PASS + FAIL))" "$C_OFF" "$LOG"
  exit 1
fi

printf '  %sall %d checks passed%s. the demo still breaks the way it should.\n\n' "$C_OK" "$PASS" "$C_OFF"
[ "$RC" -eq 0 ] || printf '  %snote: the driver exited %s%s\n\n' "$C_DIM" "$RC" "$C_OFF"
