#!/usr/bin/env bash
# One screen of checks, run backstage before going on.
#
# The original demo could promise that nothing it needed came over the network.
# This one cannot, so the promise is replaced by a list: every external thing
# the demo depends on, checked in the order it would fail.
#
# Exit 0 -- ready. Exit 1 -- something needs attention before you walk on.

set -uo pipefail

PROJECT="${PROJECT_TAG:-probes-demo}"
NS=demo
REGION="${AWS_REGION:-eu-central-1}"

if [ -t 1 ]; then
  C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'
else
  C_OFF=; C_B=; C_DIM=; C_OK=; C_BAD=; C_WARN=
fi

FAILED=0
WARNED=0

ok()   { printf '  %s✓%s %-34s %s%s%s\n' "$C_OK"   "$C_OFF" "$1" "$C_DIM" "${2:-}" "$C_OFF"; }
bad()  { printf '  %s✗%s %-34s %s%s%s\n' "$C_BAD"  "$C_OFF" "$1" "$C_BAD"  "${2:-}" "$C_OFF"; FAILED=$((FAILED + 1)); }
warn() { printf '  %s!%s %-34s %s%s%s\n' "$C_WARN" "$C_OFF" "$1" "$C_WARN" "${2:-}" "$C_OFF"; WARNED=$((WARNED + 1)); }

section() { printf '\n  %s%s%s\n' "$C_B" "$1" "$C_OFF"; }

printf '\n  %spreflight -- %s%s\n' "$C_B" "$PROJECT" "$C_OFF"

# ── tooling ──────────────────────────────────────────────────────────────────

section 'on this machine'

# envsubst is on this list because of how quietly it fails. Every manifest on
# stage is applied through it; without it kubectl gets an empty stream, says
# "no objects passed to apply" in one line, and the demo carries on for twenty
# minutes deploying nothing at all.
for tool in aws kubectl helm k9s tmux jq terragrunt docker envsubst; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool"
  else
    case "$tool" in
      envsubst) bad "$tool" 'not installed -- brew install gettext' ;;
      *)        bad "$tool" 'not installed' ;;
    esac
  fi
done

# ── credentials ──────────────────────────────────────────────────────────────

section 'aws'

# Nothing here sets AWS_PROFILE -- whatever the standard credential chain
# resolves is what the demo runs against. Which makes "the right account" a
# thing worth checking out loud, rather than assuming one profile name.
if IDENTITY=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null); then
  ACCOUNT=$(printf '%s' "$IDENTITY" | awk '{print $1}')
  ARN=$(printf '%s' "$IDENTITY" | awk '{print $2}')
  ok 'credentials' "account $ACCOUNT"
  ok 'identity' "${ARN##*/}"
else
  bad 'credentials' 'aws sts get-caller-identity failed'
  printf '\n  %severything below depends on this. fix it first.%s\n\n' "$C_BAD" "$C_OFF"
  exit 1
fi

# The account Terraform is pinned to, read from where it is already declared so
# the two cannot drift. A wrong account fails the apply anyway -- failing here
# says why, before twenty minutes of EKS.
EXPECTED_ACCOUNT=$(sed -n 's/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"\([0-9]\{12\}\)".*/\1/p' \
                   "$(dirname "$0")/../infra/root.hcl" | head -1)
if [ -n "$EXPECTED_ACCOUNT" ] && [ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  bad 'account' "$ACCOUNT, expected $EXPECTED_ACCOUNT -- wrong credentials"
fi

# ── cluster ──────────────────────────────────────────────────────────────────

section 'cluster'

if STATUS=$(aws eks describe-cluster --name "$PROJECT" --query 'cluster.status' --output text 2>/dev/null); then
  if [ "$STATUS" = "ACTIVE" ]; then
    ok 'control plane' "$STATUS"
  else
    bad 'control plane' "$STATUS"
  fi
else
  bad 'control plane' 'not found -- task up'
fi

if kubectl get ns "$NS" >/dev/null 2>&1; then
  ok 'kubectl reaches the api'
else
  bad 'kubectl reaches the api' 'task kubeconfig'
fi

# Nothing on stage fails visibly when this is missing: the pods come up, the
# probes go green, and every request the load generator makes is a connection
# error to a name that does not resolve. Both incidents then run to the end measuring
# nothing at all.
if kubectl -n "$NS" get service svc >/dev/null 2>&1; then
  ok 'service/svc' 'what the load generator resolves'
else
  bad 'service/svc' 'missing -- task reset'
fi

# `task smoke` ends on the last step, not on a clean cluster, so the night before
# a talk this is the check that catches it. The driver refuses to start the show
# from the top while these exist; this is the earlier, gentler warning.
LEFTOVERS=$(kubectl -n "$NS" get deploy svc worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${LEFTOVERS:-0}" -eq 0 ]; then
  ok 'no workloads from a previous run'
else
  warn 'workloads from a previous run' "$LEFTOVERS deployment(s) -- task reset"
fi

NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
if [ "${NODES:-0}" -ge 1 ]; then
  ok 'nodes ready' "$NODES"
else
  bad 'nodes ready' 'none'
fi

# A warm Karpenter node before the talk means incident 1's Pending step lasts about
# fifty seconds instead of however long EC2 feels like taking on the day.
KARPENTER_NODES=$(kubectl get nodes -l role=demo --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${KARPENTER_NODES:-0}" -ge 1 ]; then
  ok 'karpenter capacity warm' "$KARPENTER_NODES node(s)"
else
  warn 'karpenter capacity warm' 'none -- first pod will wait for EC2'
fi

for deploy in "kube-system/coredns" "keda/keda-operator"; do
  ns=${deploy%%/*}; name=${deploy##*/}
  if kubectl -n "$ns" get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'; then
    ok "$name"
  else
    bad "$name" 'not ready'
  fi
done

if kubectl get nodepool demo >/dev/null 2>&1; then
  ok 'karpenter nodepool'
else
  bad 'karpenter nodepool' 'missing'
fi

# ── data ─────────────────────────────────────────────────────────────────────

section 'database and queue'

if DB=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null); then
  if [ "$DB" = "available" ]; then
    ok 'rds' "$DB"
  else
    bad 'rds' "$DB"
  fi
else
  bad 'rds' 'not found'
fi

if kubectl -n "$NS" get secret db >/dev/null 2>&1; then
  ok 'secret/db'
else
  bad 'secret/db' 'task reset'
fi

if kubectl -n "$NS" get deploy dbshell >/dev/null 2>&1; then
  ok 'dbshell'
else
  bad 'dbshell' 'task reset'
fi

# The row count is the one thing that silently ruins incident 2: a half-seeded table
# makes the expensive readiness scan cheap, and the cascade never arrives.
#
# Single-quoted on purpose. $DSN has to reach the pod's shell intact -- expanded
# here it is empty, because the DSN only exists inside the container.
ROWS=$(kubectl exec -n "$NS" deploy/dbshell -- \
       sh -c 'psql "$DSN" -tAc "SELECT count(*) FROM items"' 2>/dev/null | tr -d '[:space:]')

case "$ROWS" in
  2000000) ok 'seeded rows' "$ROWS" ;;
  ''|*[!0-9]*) warn 'seeded rows' 'could not check' ;;
  *) bad 'seeded rows' "$ROWS, expected 2000000 -- task seed" ;;
esac

QUEUE_URL=$(aws sqs get-queue-url --queue-name "$PROJECT-work" --query QueueUrl --output text 2>/dev/null)
if [ -n "$QUEUE_URL" ]; then
  DEPTH=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
          --attribute-names ApproximateNumberOfMessages \
          --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null)
  if [ "${DEPTH:-0}" -eq 0 ] 2>/dev/null; then
    ok 'sqs work queue' 'empty'
  else
    warn 'sqs work queue' "$DEPTH messages left over -- purge before incident 2"
  fi
else
  bad 'sqs work queue' 'not found'
fi

# ── guards ───────────────────────────────────────────────────────────────────

section 'guards'

EXPIRES=$(aws eks describe-cluster --name "$PROJECT" --query 'cluster.tags.ExpiresAt' --output text 2>/dev/null)
case "$EXPIRES" in
  ''|None) warn 'cluster ExpiresAt' 'unset -- the reaper will treat it as expired' ;;
  *)
    # Being reaped mid-talk would be a memorable way to learn this lesson.
    NOW=$(date -u +%s)
    EXP=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$EXPIRES" +%s 2>/dev/null \
          || date -u -d "$EXPIRES" +%s 2>/dev/null)
    if [ -n "$EXP" ] && [ "$EXP" -gt "$((NOW + 5400))" ]; then
      ok 'cluster ExpiresAt' "$EXPIRES"
    else
      warn 'cluster ExpiresAt' "$EXPIRES -- under 90 min left, re-apply to extend"
    fi
    ;;
esac

if aws lambda get-function --function-name "$PROJECT-reaper" >/dev/null 2>&1; then
  ok 'reaper'
else
  warn 'reaper' 'missing -- task guardrails:apply'
fi

# ── verdict ──────────────────────────────────────────────────────────────────

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  printf '  %s%d check(s) failed%s' "$C_BAD" "$FAILED" "$C_OFF"
  [ "$WARNED" -gt 0 ] && printf '%s, %d warning(s)%s' "$C_DIM" "$WARNED" "$C_OFF"
  printf '\n\n'
  exit 1
fi

if [ "$WARNED" -gt 0 ]; then
  printf '  %sready, with %d warning(s)%s\n\n' "$C_WARN" "$WARNED" "$C_OFF"
else
  printf '  %sready%s\n\n' "$C_OK" "$C_OFF"
fi
