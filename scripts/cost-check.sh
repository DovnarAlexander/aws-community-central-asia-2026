#!/usr/bin/env bash
# Sweeps the account for anything that costs money and should not be alive.
#
# This is the layer between `task down` (which can lie: Terraform reports success
# on a partial destroy) and the hourly reaper (which only fires once an hour).
# Run it at the end of every session. It is deliberately blunt -- it reports
# every billable resource it finds, tagged or not, because the failure mode we
# care about is exactly the resource that escaped its tags.
#
# Exit 0 -- nothing alive. Exit 1 -- something is running.
#
#   scripts/cost-check.sh              # the demo region
#   scripts/cost-check.sh --all-regions # paranoid sweep, slow
#   scripts/cost-check.sh --quiet       # only print if something is alive

set -uo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"
PROJECT="${PROJECT_TAG:-probes-demo}"
ALL_REGIONS=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --all-regions) ALL_REGIONS=1 ;;
    --quiet|-q)    QUIET=1 ;;
    -h|--help)     sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[1;32m'; C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'
else
  C_OFF=; C_B=; C_DIM=; C_OK=; C_BAD=; C_WARN=
fi

command -v aws >/dev/null 2>&1 || { echo "aws cli not found" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }

if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  printf '%s✗%s no AWS credentials. Export AWS_PROFILE (or any other credentials\n' "$C_BAD" "$C_OFF" >&2
  printf '    the aws cli accepts), then retry.\n' >&2
  exit 2
fi

FINDINGS=$(mktemp)
trap 'rm -f "$FINDINGS"' EXIT

# find <what> <detail> <usd-per-hour>
find_it() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$FINDINGS"; }

# Approximate eu-central-1 on-demand rates. The point is to make a forgotten
# cluster's cost legible at a glance, not to reconcile the invoice.
rate_ec2() {
  case "$1" in
    t3.nano) echo 0.0060 ;;   t3.micro) echo 0.0120 ;;
    t3.small) echo 0.0240 ;;  t3.medium) echo 0.0480 ;;
    t3.large) echo 0.0960 ;;  t3.xlarge) echo 0.1920 ;;
    t4g.nano) echo 0.0048 ;;  t4g.micro) echo 0.0096 ;;
    t4g.small) echo 0.0192 ;; t4g.medium) echo 0.0384 ;;
    t4g.large) echo 0.0768 ;;
    c6g.large) echo 0.0776 ;; c6g.xlarge) echo 0.1552 ;;
    m6g.large) echo 0.0888 ;; m6g.xlarge) echo 0.1776 ;;
    m5.large) echo 0.1070 ;;
    *) echo 0.1000 ;;         # unknown type: assume it is not cheap
  esac
}

rate_rds() {
  case "$1" in
    db.t4g.micro) echo 0.0180 ;;  db.t4g.small) echo 0.0360 ;;
    db.t4g.medium) echo 0.0720 ;; db.m6g.large) echo 0.1560 ;;
    db.m5.large) echo 0.1920 ;;
    *) echo 0.1600 ;;
  esac
}

sweep_region() {
  local r="$1" out

  # ── EC2 ────────────────────────────────────────────────────────────────────
  out=$(aws ec2 describe-instances --region "$r" \
        --filters Name=instance-state-name,Values=pending,running \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Project`].Value|[0]]' \
        --output text 2>/dev/null)
  while IFS=$'\t' read -r id type proj; do
    [ -z "${id:-}" ] && continue
    [ "$proj" = "None" ] && proj='untagged'
    find_it "EC2 $r" "$id  $type  ($proj)" "$(rate_ec2 "$type")"
  done <<< "$out"

  # ── EKS ────────────────────────────────────────────────────────────────────
  out=$(aws eks list-clusters --region "$r" --query 'clusters[]' --output text 2>/dev/null)
  for c in $out; do
    [ -z "$c" ] && continue
    find_it "EKS $r" "$c  (control plane)" "0.1000"
  done

  # ── RDS ────────────────────────────────────────────────────────────────────
  out=$(aws rds describe-db-instances --region "$r" \
        --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus,AllocatedStorage]' \
        --output text 2>/dev/null)
  while IFS=$'\t' read -r id class status gb; do
    [ -z "${id:-}" ] && continue
    if [ "$status" = "stopped" ]; then
      # Storage still bills, and AWS auto-restarts a stopped instance after
      # seven days. "Stopped" is not "gone".
      find_it "RDS $r" "$id  $class  STOPPED (storage ${gb}GB, auto-starts in <=7d)" \
        "$(awk -v g="$gb" 'BEGIN{printf "%.4f", g*0.137/730}')"
    else
      find_it "RDS $r" "$id  $class  $status" "$(rate_rds "$class")"
    fi
  done <<< "$out"

  # ── NAT gateways ───────────────────────────────────────────────────────────
  out=$(aws ec2 describe-nat-gateways --region "$r" \
        --filter Name=state,Values=available,pending \
        --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
  for n in $out; do
    [ -z "$n" ] && continue
    find_it "NAT $r" "$n  (plus \$0.045/GB processed)" "0.0520"
  done

  # ── load balancers ─────────────────────────────────────────────────────────
  out=$(aws elbv2 describe-load-balancers --region "$r" \
        --query 'LoadBalancers[].[LoadBalancerName,Type]' --output text 2>/dev/null)
  while IFS=$'\t' read -r name type; do
    [ -z "${name:-}" ] && continue
    find_it "ELB $r" "$name  ($type, plus LCU)" "0.0270"
  done <<< "$out"

  out=$(aws elb describe-load-balancers --region "$r" \
        --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null)
  for name in $out; do
    [ -z "$name" ] && continue
    find_it "ELB $r" "$name  (classic)" "0.0300"
  done

  # ── unattached EIPs ────────────────────────────────────────────────────────
  out=$(aws ec2 describe-addresses --region "$r" \
        --query 'Addresses[?AssociationId==`null`].PublicIp' --output text 2>/dev/null)
  for ip in $out; do
    [ -z "$ip" ] && continue
    find_it "EIP $r" "$ip  (unattached)" "0.0050"
  done

  # ── unattached EBS ─────────────────────────────────────────────────────────
  out=$(aws ec2 describe-volumes --region "$r" \
        --filters Name=status,Values=available \
        --query 'Volumes[].[VolumeId,Size]' --output text 2>/dev/null)
  while IFS=$'\t' read -r vid gb; do
    [ -z "${vid:-}" ] && continue
    find_it "EBS $r" "$vid  ${gb}GB  (unattached)" \
      "$(awk -v g="$gb" 'BEGIN{printf "%.4f", g*0.0952/730}')"
  done <<< "$out"
}

# ── run ──────────────────────────────────────────────────────────────────────

if [ "$ALL_REGIONS" = 1 ]; then
  REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null)
  [ -z "$REGIONS" ] && REGIONS="$REGION"
else
  REGIONS="$REGION"
fi

[ "$QUIET" = 1 ] || printf '\n  %ssweeping account %s%s  %s%s%s\n' \
  "$C_DIM" "$ACCOUNT" "$C_OFF" "$C_DIM" "$(echo "$REGIONS" | tr '\n' ' ')" "$C_OFF"

for r in $REGIONS; do sweep_region "$r"; done

COUNT=$(wc -l < "$FINDINGS" | tr -d ' ')

if [ "$COUNT" = 0 ]; then
  [ "$QUIET" = 1 ] || printf '\n  %s✓ nothing running.%s no compute, no databases, no gateways, no stray volumes.\n\n' \
    "$C_OK" "$C_OFF"
  exit 0
fi

HOURLY=$(awk -F'\t' '{s+=$3} END {printf "%.2f", s}' "$FINDINGS")
DAILY=$(awk -v h="$HOURLY" 'BEGIN{printf "%.2f", h*24}')
MONTHLY=$(awk -v h="$HOURLY" 'BEGIN{printf "%.0f", h*730}')

printf '\n  %s%s billable resource(s) alive%s\n\n' "$C_BAD" "$COUNT" "$C_OFF"
awk -F'\t' -v b="$C_B" -v o="$C_OFF" -v d="$C_DIM" \
  '{printf "  %s%-10s%s %-58s %s$%s/h%s\n", b, $1, o, $2, d, $3, o}' "$FINDINGS"

printf '\n  %sestimated burn%s  %s$%s/hour%s  ·  $%s/day  ·  $%s/month if left\n' \
  "$C_DIM" "$C_OFF" "$C_WARN" "$HOURLY" "$C_OFF" "$DAILY" "$MONTHLY"
printf '  %sapproximate on-demand rates, %s%s\n' "$C_DIM" "$REGION" "$C_OFF"
printf '\n  tear down with: %stask down%s\n\n' "$C_B" "$C_OFF"

exit 1
