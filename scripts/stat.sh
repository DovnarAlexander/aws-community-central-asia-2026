#!/usr/bin/env bash
# The right-hand stat panel: nodes, queue depth, database connections.
#
# One panel rather than three, because the argument of act 2 lives in the
# relationship between these numbers -- the queue climbing while the node count
# climbs and the connection count sits pinned at the wall. Split across separate
# panels the audience has to assemble that themselves.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/aws-env.sh"

NS=demo
PROJECT="${PROJECT_TAG:-probes-demo}"
INTERVAL="${INTERVAL:-2}"

QUEUE_URL=$(aws sqs get-queue-url --queue-name "$PROJECT-work" --query QueueUrl --output text 2>/dev/null)

C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'

while true; do
  nodes=$(kubectl get nodes -l role=demo --no-headers 2>/dev/null | wc -l | tr -d ' ')
  burn=$(awk -v n="${nodes:-0}" 'BEGIN { printf "%.2f", n * 0.017 }')

  depth=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'join(`/`, [Attributes.ApproximateNumberOfMessages, Attributes.ApproximateNumberOfMessagesNotVisible])' \
    --output text 2>/dev/null)

  # The master user keeps RDS's reserved connection slots, so this query still
  # answers after the wall has locked every application pod out.
  conns=$(kubectl exec -n "$NS" deploy/dbshell -- sh -c \
    'psql "$DSN" -tAc "SELECT count(*) || \"/\" || current_setting(\"max_connections\") || \" active \" || count(*) FILTER (WHERE state = \"active\") FROM pg_stat_activity WHERE datname = current_database()"' 2>/dev/null | tr -d '\r')

  printf '\033[H\033[J'
  printf '  %sNODES%s     %s%-4s%s %s~$%s/h%s\n' "$C_DIM" "$C_OFF" "$C_B" "${nodes:-?}" "$C_OFF" "$C_DIM" "$burn" "$C_OFF"
  printf '  %sQUEUE%s     %s%s%s %svisible/in-flight%s\n' "$C_DIM" "$C_OFF" "$C_B" "${depth:-?}" "$C_OFF" "$C_DIM" "$C_OFF"

  case "$conns" in
    '') printf '  %sDB%s        %s-- unreachable%s\n' "$C_DIM" "$C_OFF" "$C_BAD" "$C_OFF" ;;
    *)  printf '  %sDB%s        %s%s%s\n' "$C_DIM" "$C_OFF" "$C_B" "$conns" "$C_OFF" ;;
  esac

  sleep "$INTERVAL"
done
