#!/usr/bin/env bash
# The right-hand stat panel: nodes, queue depth, database connections.
#
# One panel rather than three, because the argument of incident 2 lives in the
# relationship between these numbers -- the queue climbing while the node count
# climbs and the connection count sits pinned at the wall. Split across separate
# panels the audience has to assemble that themselves.
set -uo pipefail

NS=demo
PROJECT="${PROJECT_TAG:-probes-demo}"
INTERVAL="${INTERVAL:-2}"

QUEUE_URL=$(aws sqs get-queue-url --queue-name "$PROJECT-work" --query QueueUrl --output text 2>/dev/null)

C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'

# ── the shape, not just the number ───────────────────────────────────────────
# Incident 2's argument is a divergence: the queue climbing while the node count
# climbs under it and throughput sits at zero. As two numbers that change, the
# room has to hold the previous value in their heads to see it. As two lines,
# they just see it.
#
# Sixteen samples every third tick is about a minute and a half of history at
# the default interval -- long enough to cover the cascade, short enough that
# the recovery visibly bends the line rather than being lost in an average.
SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
HIST=16
SAMPLE_EVERY=3
hist_n=(); hist_q=(); tick=0

# Each series is scaled to its own maximum, and the maximum is whatever is in
# the window -- an absolute scale would flatten the node line into nothing next
# to a queue counted in hundreds of thousands.
spark() { # spark VALUE...
  local max=0 v idx out=''
  for v in "$@"; do [ "$v" -gt "$max" ] && max="$v"; done
  [ "$max" -le 0 ] && { printf '%*s' "$#" ''; return 0; }
  for v in "$@"; do
    idx=$(( v * 7 / max ))
    out="$out${SPARK[$idx]}"
  done
  printf '%s' "$out"
}

# A failed kubectl or a throttled aws call must not put a zero in the history:
# a spurious dip reads as a recovery that did not happen.
push() { # push ARRAY_NAME VALUE
  case "$2" in ''|*[!0-9]*) return 0 ;; esac
  eval "$1[\${#$1[@]}]=\$2"
  eval "[ \${#$1[@]} -gt $HIST ] && $1=(\"\${$1[@]:1}\")"
  return 0
}

while true; do
  nodes=$(kubectl get nodes -l role=demo --no-headers 2>/dev/null | wc -l | tr -d ' ')
  burn=$(awk -v n="${nodes:-0}" 'BEGIN { printf "%.2f", n * 0.017 }')

  depth=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'join(`/`, [Attributes.ApproximateNumberOfMessages, Attributes.ApproximateNumberOfMessagesNotVisible])' \
    --output text 2>/dev/null)

  # The master user keeps RDS's reserved connection slots, so this query still
  # answers after the wall has locked every application pod out.
  #
  # Single quotes in the SQL, and the sh -c payload double-quoted so they
  # survive the trip. In Postgres "active" is an identifier, not a string: the
  # earlier version of this line asked for a column called "/" and this panel
  # printed "-- unreachable" for its entire life, which looks exactly like a
  # database that has stopped answering.
  conns=$(kubectl exec -n "$NS" deploy/dbshell -- sh -c \
    "psql \"\$DSN\" -tAc \"SELECT count(*) || '/' || current_setting('max_connections') || ' active ' || count(*) FILTER (WHERE state = 'active') FROM pg_stat_activity WHERE datname = current_database()\"" 2>/dev/null | tr -d '\r')

  tick=$((tick + 1))
  if [ $((tick % SAMPLE_EVERY)) -eq 0 ]; then
    push hist_n "${nodes:-}"
    push hist_q "${depth%%/*}"
  fi

  printf '\033[H\033[J'
  printf '  %sNODES%s  %s%-3s%s %s~$%s/h%s  %s%s%s\n' \
    "$C_DIM" "$C_OFF" "$C_B" "${nodes:-?}" "$C_OFF" "$C_DIM" "$burn" "$C_OFF" \
    "$C_WARN" "$( [ ${#hist_n[@]} -gt 0 ] && spark "${hist_n[@]}" )" "$C_OFF"
  printf '  %sQUEUE%s  %s%-13s%s %s%s%s\n' \
    "$C_DIM" "$C_OFF" "$C_B" "${depth:-?}" "$C_OFF" \
    "$C_WARN" "$( [ ${#hist_q[@]} -gt 0 ] && spark "${hist_q[@]}" )" "$C_OFF"

  case "$conns" in
    '') printf '  %sDB%s     %s-- unreachable%s\n' "$C_DIM" "$C_OFF" "$C_BAD" "$C_OFF" ;;
    *)  printf '  %sDB%s     %s%s%s\n' "$C_DIM" "$C_OFF" "$C_B" "$conns" "$C_OFF" ;;
  esac

  sleep "$INTERVAL"
done
