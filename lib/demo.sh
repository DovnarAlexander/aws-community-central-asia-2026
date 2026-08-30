#!/usr/bin/env bash
# The stage driver.
#
# The contract with the speaker: the only key pressed is "next" -- right arrow
# on a clicker, Enter, or space. Each beat prints a heading, then the exact
# command about to run, waits, runs it for real, and leaves the output on
# screen. Nothing is faked and nothing is pre-recorded.
#
# Written for bash 3.2, the system bash on macOS: no associative arrays, no
# mapfile.

set -uo pipefail

DEMO_ROOT="${DEMO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEMO_STATE="${DEMO_STATE:-/tmp/probes-demo}"
NS=demo
PROJECT="${PROJECT_TAG:-probes-demo}"
mkdir -p "$DEMO_STATE"

FAST=0 # set while fast-forwarding to a beat: run everything, wait for nothing

# ── theme ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_CMD=$'\033[1;36m'; C_SAY=$'\033[0;37m'; C_OK=$'\033[1;32m'
  C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'; C_HEAD=$'\033[1;35m'
else
  C_OFF=; C_B=; C_DIM=; C_CMD=; C_SAY=; C_OK=; C_BAD=; C_WARN=; C_HEAD=
fi

# Width comes from stty rather than tput: tput reads the size of stdout, which
# here is almost always a pipe, and with stderr silenced it falls back to the
# terminfo default of 80. The driver panel is already only 62% of the screen --
# thirty phantom columns wrecked the layout.
_width() {
  local w
  w=$(stty size 2>/dev/null | awk '{print $2}')
  case "$w" in ''|*[!0-9]*) w=$(tput cols 2>/dev/null) ;; esac
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  [ "$w" -lt 40 ] && w=40
  [ "$w" -gt 100 ] && w=100
  printf '%s\n' "$w"
}

_rule() { local w; w=$(_width); printf '%*s\n' "$w" '' | tr ' ' "${1:--}"; }

# ${#s} counts characters only in a UTF-8 locale. Without one, wrapping and
# column arithmetic drift apart, so fix the locale rather than hope.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*utf8*) ;;
  *) export LC_ALL=en_US.UTF-8 ;;
esac

_col()  { local w="$1" t="$2" n; n=$((w - ${#t})); [ "$n" -lt 0 ] && n=0; printf '%s%*s' "$t" "$n" ''; }
_rcol() { local w="$1" t="$2" n; n=$((w - ${#t})); [ "$n" -lt 0 ] && n=0; printf '%*s%s' "$n" '' "$t"; }

# _fit INDENT TEXT... -- wrap to the driver panel's width. The panel is under
# half the screen, so a long line cannot be handed to the terminal: it would
# wrap to column zero and the indent would fall apart. Prints bare lines; the
# caller adds colour and indent.
_fit() {
  local pad="$1"; shift
  local w avail line='' word
  w=$(_width); avail=$((w - pad)); [ "$avail" -lt 24 ] && avail=24
  set -f
  for word in $*; do
    if [ -z "$line" ]; then line="$word"
    elif [ $((${#line} + 1 + ${#word})) -le "$avail" ]; then line="$line $word"
    else printf '%s\n' "$line"; line="$word"
    fi
  done
  set +f
  [ -n "$line" ] && printf '%s\n' "$line"
  return 0
}

# ── the beat registry ────────────────────────────────────────────────────────
BEAT_IDS=(); BEAT_TITLES=(); BEAT_FUNCS=()

beat() { # beat ID TITLE FUNC
  BEAT_IDS+=("$1"); BEAT_TITLES+=("$2"); BEAT_FUNCS+=("$3")
}

# ── what the speaker sees ────────────────────────────────────────────────────
say() {
  [ "$FAST" = 1 ] && return 0
  [ -z "$*" ] && { printf '\n'; return 0; }
  local l
  _fit 2 "$*" | while IFS= read -r l; do printf '  %b%s%b\n' "$C_SAY" "$l" "$C_OFF"; done
  return 0
}

head_beat() { # head_beat ID TITLE
  [ "$FAST" = 1 ] && return 0
  local l first=1
  printf '\n%b' "$C_HEAD"; _rule '='
  _fit 2 "BEAT $1 . $2" | while IFS= read -r l; do
    if [ "$first" = 1 ]; then printf '  %s\n' "$l"; first=0; else printf '        %s\n' "$l"; fi
  done
  _rule '='; printf '%b\n' "$C_OFF"
}

bigsay() { # the line the room takes home
  [ "$FAST" = 1 ] && return 0
  local l
  printf '\n%b' "$C_OK"; _rule '='
  _fit 2 "$*" | while IFS= read -r l; do printf '  %s\n' "$l"; done
  _rule '='; printf '%b\n' "$C_OFF"
}

badsay() {
  [ "$FAST" = 1 ] && return 0
  local l
  printf '\n%b' "$C_BAD"; _rule '='
  _fit 2 "$*" | while IFS= read -r l; do printf '  %s\n' "$l"; done
  _rule '='; printf '%b\n' "$C_OFF"
}

# ── input ────────────────────────────────────────────────────────────────────
# A presenter clicker sends arrows or PageUp/PageDown, not Enter. An arrow
# arrives as a three-character escape sequence (ESC [ C), so it has to be read
# to the end: otherwise the tail spills into the next prompt and one press eats
# two beats.
#
# A bare Esc -- the "blank the screen" button on a clicker -- sends no tail, so
# it can only be detected by timeout. bash 3.2, the system bash on macOS, cannot
# do fractional read timeouts, so there it waits a whole second.
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then ESC_WAIT=0.05; else ESC_WAIT=1; fi

# The driver parses keys itself, so terminal echo is off for the duration:
# otherwise every clicker press prints ^[[C on the screen behind you.
TTY_SAVED=''
_tty_quiet() { [ -t 0 ] || return 0; TTY_SAVED=$(stty -g 2>/dev/null); stty -echo 2>/dev/null; return 0; }
_tty_restore() { [ -n "$TTY_SAVED" ] && stty "$TTY_SAVED" 2>/dev/null; TTY_SAVED=''; return 0; }

# read_key [TIMEOUT] -- prints next | back | skip | quit | other.
# Returns 1 if nothing was pressed before the timeout.
read_key() {
  local k tail extra
  if [ $# -gt 0 ]; then
    IFS= read -rsn1 -t "$1" k || return 1
  else
    # End of input means `task smoke`, which feeds the driver from a pipe.
    IFS= read -rsn1 k || { echo next; return 0; }
  fi
  case "$k" in
    ''|$'\n'|$'\r'|' ') echo next; return 0 ;;
    n|N) echo next; return 0 ;;
    s|S) echo skip; return 0 ;;
    q|Q) echo quit; return 0 ;;
    $'\033') : ;;
    *) echo other; return 0 ;;
  esac
  IFS= read -rsn2 -t "$ESC_WAIT" tail || { echo other; return 0; }
  case "$tail" in
    '[C'|'OC'|'[B'|'OB') echo next ;;                       # right and down
    '[D'|'OD'|'[A'|'OA') echo back ;;                       # left and up
    '[6') IFS= read -rsn1 -t "$ESC_WAIT" extra; echo next ;; # PageDown
    '[5') IFS= read -rsn1 -t "$ESC_WAIT" extra; echo back ;; # PageUp
    *) echo other ;;
  esac
  return 0
}

# 0 -- carry on, 1 -- skip. `q` leaves the demo entirely.
ask() {
  [ "$FAST" = 1 ] && return 0
  local key note=''
  while true; do
    printf '\r\033[K  %b[->] next . [s] skip . [q] quit%s%b' "$C_DIM" "$note" "$C_OFF"
    key=$(read_key) || continue
    case "$key" in
      next) printf '\r\033[K'; return 0 ;;
      skip) printf '\r\033[K  %b(skipped)%b\n' "$C_DIM" "$C_OFF"; return 1 ;;
      quit) printf '\r\033[K\n'; exit 0 ;;
      back) note='   . there is no going back' ;;
    esac
  done
}

pause() {
  [ "$FAST" = 1 ] && return 0
  local l
  if [ $# -gt 0 ]; then
    printf '\n'
    _fit 2 "$*" | while IFS= read -r l; do printf '  %b%s%b\n' "$C_B" "$l" "$C_OFF"; done
  fi
  ask >/dev/null || true
}

# run: show the command, wait for a press, then actually run it.
run() {
  local cmd="$*" l first=1
  printf '\n'
  # Commands are wrapped by hand too: kubectl and psql lines are long, and the
  # terminal breaks them mid-word with no indent, which is unreadable.
  _fit 4 "$cmd" | while IFS= read -r l; do
    if [ "$first" = 1 ]; then printf '  %b$ %s%b\n' "$C_CMD" "$l" "$C_OFF"; first=0
    else printf '    %b%s%b\n' "$C_CMD" "$l" "$C_OFF"; fi
  done
  ask || return 0
  eval "$cmd" 2>&1 | sed 's/^/  /'
  local rc=${PIPESTATUS[0]}
  [ "$rc" != 0 ] && printf '  %b-> exit %s%b\n' "$C_WARN" "$rc" "$C_OFF"
  return 0
}

# runq: setup the room does not need to watch.
runq() { eval "$*" >/dev/null 2>&1; return 0; }

# show: put a file on the screen.
show() {
  local f="$1"
  printf '\n  %b%s%b\n' "$C_B" "$f" "$C_OFF"
  ask || return 0
  if command -v bat >/dev/null 2>&1; then
    bat --style=plain --color=always --language=yaml "$DEMO_ROOT/$f"
  else
    sed 's/^/  /' "$DEMO_ROOT/$f"
  fi
}

# showdiff: the most useful slide in the whole talk -- what actually changed.
showdiff() {
  printf '\n  %bwhat changes: %s -> %s%b\n' "$C_B" "$(basename "$1")" "$(basename "$2")" "$C_OFF"
  ask || return 0
  git --no-pager diff --no-index --color=always --unified=2 \
    "$DEMO_ROOT/$1" "$DEMO_ROOT/$2" 2>/dev/null | tail -n +5 | sed 's/^/  /'
  return 0
}

# ── applying manifests ───────────────────────────────────────────────────────
# Manifests carry ${IMAGE} and ${QUEUE_URL} so that the diffs stay readable and
# the repository stays free of an account id in a dozen files.
export IMAGE="${IMAGE:-}"
export QUEUE_URL="${QUEUE_URL:-}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

resolve_env() {
  [ -n "$IMAGE" ] || IMAGE=$(cd "$DEMO_ROOT/infra/demo/.terragrunt-stack/registry" 2>/dev/null \
    && terragrunt output -raw repository_url 2>/dev/null)
  [ -n "$IMAGE" ] && IMAGE="${IMAGE}:latest"

  [ -n "$QUEUE_URL" ] || QUEUE_URL=$(aws sqs get-queue-url --queue-name "$PROJECT-work" \
    --query QueueUrl --output text 2>/dev/null)

  export IMAGE QUEUE_URL
}

apply() { # apply MANIFEST -- substitute, then apply
  envsubst < "$DEMO_ROOT/$1" | kubectl apply -f -
}

# ── cluster helpers ──────────────────────────────────────────────────────────
# The name column stretches with the panel: at a fixed 28 characters the line
# did not fit and every pod took two rows.
pods_table() { # pods_table [SELECTOR]
  local sel="${1:-app in (svc,worker)}"
  local w nw
  w=$(_width); nw=$((w - 30))
  [ "$nw" -lt 16 ] && nw=16
  [ "$nw" -gt 30 ] && nw=30
  kubectl -n "$NS" get pods -l "$sel" --no-headers 2>/dev/null \
    | awk -v nw="$nw" '{printf "  %-*s %-4s %-16s R:%s\n", nw, $1, $2, $3, $4}' \
    | sed -e "s/CrashLoopBackOff/${C_BAD}CrashLoopBackOff${C_OFF}/" \
          -e "s/Pending/${C_WARN}Pending${C_OFF}/" \
          -e "s/Error/${C_BAD}Error${C_OFF}/" \
          -e "s/0\/1/${C_BAD}0\/1${C_OFF}/" \
          -e "s/1\/1/${C_OK}1\/1${C_OFF}/"
}

ready_count() { # ready_count [SELECTOR]
  local sel="${1:-app in (svc,worker)}" total ready
  total=$(kubectl -n "$NS" get pods -l "$sel" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl -n "$NS" get pods -l "$sel" --no-headers 2>/dev/null | awk '$2=="1/1"' | wc -l | tr -d ' ')
  echo "$ready/$total"
}

restarts_total() { # restarts_total [SELECTOR]
  local sel="${1:-app in (svc,worker)}"
  kubectl -n "$NS" get pods -l "$sel" --no-headers 2>/dev/null | awk '{s+=$4} END {print s+0}'
}

# The number act 2 is really about. Karpenter nodes are labelled role=demo, so
# this counts machines bought for the demo and not the one running the system.
node_count() {
  kubectl get nodes -l role=demo --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Rough hourly spend on Karpenter capacity. Spot prices move, so this is an
# order of magnitude rather than an invoice -- but seeing it climb while
# throughput sits at zero is the point of the whole second act.
node_burn() {
  local n; n=$(node_count)
  awk -v n="${n:-0}" 'BEGIN { printf "%.2f", n * 0.017 }'
}

queue_depth() {
  [ -n "$QUEUE_URL" ] || return 0
  aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'join(`/`, [Attributes.ApproximateNumberOfMessages, Attributes.ApproximateNumberOfMessagesNotVisible])' \
    --output text 2>/dev/null
}

_redraw_lines=0
_redraw() {
  local text="$1"
  [ "$_redraw_lines" -gt 0 ] && printf '\033[%dA\033[J' "$_redraw_lines"
  printf '%s\n' "$text"
  _redraw_lines=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
}

# watch_pods: a live table in the driver panel, counting down. "Next" cuts the
# wait short -- useful once the room has clearly got the point.
watch_pods() { # watch_pods SECONDS [CAPTION] [SELECTOR]
  [ "$FAST" = 1 ] && { sleep "${1:-5}"; return 0; }
  local secs="${1:-30}" cap="${2:-}" sel="${3:-app in (svc,worker)}"
  local start=$SECONDS
  _redraw_lines=0
  printf '\n'
  while [ $((SECONDS - start)) -lt "$secs" ]; do
    local left=$((secs - (SECONDS - start)))
    local body
    body="  ${C_DIM}${cap}${C_OFF}
  ${C_DIM}ready ${C_OFF}${C_B}$(ready_count "$sel")${C_OFF}${C_DIM} . restarts ${C_OFF}${C_B}$(restarts_total "$sel")${C_OFF}${C_DIM} . nodes ${C_OFF}${C_B}$(node_count)${C_OFF}${C_DIM} . ${left}s . [->]${C_OFF}
$(pods_table "$sel")"
    _redraw "$body"
    # Cut the wait short -- but only when a person is actually at the keyboard.
    # Under `task smoke` stdin is a pipe and the wait must run to completion.
    if [ -t 0 ]; then
      case "$(read_key 1)" in next|skip|quit) break ;; esac
    else
      sleep 1
    fi
  done
  _redraw_lines=0
  return 0
}

# watch_scale: act 2's panel. Queue depth and node count next to each other is
# the whole argument -- one climbing while the other climbs, and throughput at
# zero between them.
watch_scale() { # watch_scale SECONDS [CAPTION]
  [ "$FAST" = 1 ] && { sleep "${1:-5}"; return 0; }
  local secs="${1:-60}" cap="${2:-}"
  local start=$SECONDS
  _redraw_lines=0
  printf '\n'
  while [ $((SECONDS - start)) -lt "$secs" ]; do
    local left=$((secs - (SECONDS - start)))
    local body
    body="  ${C_DIM}${cap}${C_OFF}
  ${C_DIM}queue ${C_OFF}${C_B}$(queue_depth)${C_OFF}${C_DIM} . workers ${C_OFF}${C_B}$(ready_count 'app=worker')${C_OFF}${C_DIM} . nodes ${C_OFF}${C_B}$(node_count)${C_OFF}${C_DIM} ~\$$(node_burn)/h . ${left}s . [->]${C_OFF}
$(pods_table 'app=worker')"
    _redraw "$body"
    if [ -t 0 ]; then
      case "$(read_key 1)" in next|skip|quit) break ;; esac
    else
      sleep 1
    fi
  done
  _redraw_lines=0
  return 0
}

# wait_for: spin until a command succeeds. This keeps the stage honest -- we
# wait for the cluster rather than sleeping a magic number and hoping.
wait_for() { # wait_for 'COMMAND' TIMEOUT 'CAPTION'
  local cmd="$1" timeout="${2:-120}" cap="${3:-waiting}"
  local start=$SECONDS spin='|/-\' i=0
  while [ $((SECONDS - start)) -lt "$timeout" ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      [ "$FAST" = 1 ] || printf '\r\033[K  %b+ %s (%ss)%b\n' "$C_OK" "$cap" "$((SECONDS - start))" "$C_OFF"
      return 0
    fi
    if [ "$FAST" != 1 ]; then
      i=$(((i + 1) % 4))
      printf '\r\033[K  %b%s %s (%ss)%b' "$C_DIM" "${spin:$i:1}" "$cap" "$((SECONDS - start))" "$C_OFF"
    fi
    sleep 1
  done
  [ "$FAST" = 1 ] || printf '\r\033[K  %bx gave up: %s%b\n' "$C_WARN" "$cap" "$C_OFF"
  return 1
}

# ── load ─────────────────────────────────────────────────────────────────────
# The generator runs in the cluster, so the summary comes back through
# `kubectl logs` rather than from a file on the laptop.

load_start() { # load_start MODE RPS LABEL [DURATION] [WORKERS]
  local mode="$1" rps="$2" label="$3" duration="${4:-0s}" workers="${5:-100}"
  load_stop_quiet

  export LOAD_MODE="$mode" LOAD_RPS="$rps" LOAD_LABEL="$label"
  export LOAD_DURATION="$duration" LOAD_WORKERS="$workers"
  if [ "$mode" = "enqueue" ]; then
    export LOAD_URL="http://svc.$NS.svc.cluster.local/enqueue"
  else
    export LOAD_URL="http://svc.$NS.svc.cluster.local/work"
  fi

  envsubst < "$DEMO_ROOT/k8s/loadgen.yaml" | kubectl apply -f - >/dev/null 2>&1
  echo "$label" > "$DEMO_STATE/load.label"

  [ "$FAST" = 1 ] || printf '  %b> load: %s rps, %s (panel bottom right)%b\n' \
    "$C_B" "$rps" "$mode" "$C_OFF"
}

load_stop_quiet() {
  # Capture the summary before deleting the pod, or it goes with it.
  if [ -f "$DEMO_STATE/load.label" ]; then
    local label; label=$(cat "$DEMO_STATE/load.label")
    kubectl -n "$NS" logs loadgen 2>/dev/null \
      | grep '^SUMMARY ' | tail -1 | cut -d' ' -f2- > "$DEMO_STATE/$label.json" 2>/dev/null
    rm -f "$DEMO_STATE/load.label"
  fi
  kubectl -n "$NS" delete pod loadgen --ignore-not-found --wait=false >/dev/null 2>&1
}

load_stop() {
  load_stop_quiet
  [ "$FAST" = 1 ] || printf '  %b# load stopped%b\n' "$C_DIM" "$C_OFF"
}

# compare: a before/after card built from two real measurements.
compare() { # compare LABEL_BEFORE LABEL_AFTER HEADING
  [ "$FAST" = 1 ] && return 0
  local a="$DEMO_STATE/$1.json" b="$DEMO_STATE/$2.json"
  if [ ! -s "$a" ] || [ ! -s "$b" ]; then
    printf '  %bno data to compare (%s / %s)%b\n' "$C_WARN" "$1" "$2" "$C_OFF"
    return 0
  fi
  _g() { jq -r "$2" "$1" 2>/dev/null; }
  # Column widths: 2 indent + 20 label + 11 + 11 = 44 characters. The driver
  # panel on stage is narrow; anything wider wraps and the table falls apart.
  _row() { # _row COLOUR_BEFORE COLOUR_AFTER LABEL BEFORE AFTER
    printf '  %s%b%s%b%b%s%b\n' \
      "$(_col 20 "$3")" "$1" "$(_rcol 11 "$4")" "$C_OFF" "$2" "$(_rcol 11 "$5")" "$C_OFF"
  }
  local l
  printf '\n%b' "$C_B"; _rule '-'
  _fit 2 "${3:-before / after}" | while IFS= read -r l; do printf '  %s\n' "$l"; done
  _rule '-'; printf '%b' "$C_OFF"
  _row "$C_DIM" "$C_DIM" '' 'BEFORE' 'AFTER'
  _row '' '' 'requests'          "$(_g "$a" .requests)"           "$(_g "$b" .requests)"
  _row '' "$C_OK" 'served 2xx'   "$(_g "$a" .ok)"                 "$(_g "$b" .ok)"
  _row "$C_BAD" "$C_OK" '5xx'    "$(_g "$a" .server_err)"         "$(_g "$b" .server_err)"
  _row "$C_BAD" "$C_OK" 'dropped connections' "$(_g "$a" .conn_err)" "$(_g "$b" .conn_err)"
  _row '' '' 'served per second' "$(_g "$a" '.ok_per_sec|floor')" "$(_g "$b" '.ok_per_sec|floor')"
  _row '' '' 'p50'               "$(_g "$a" .p50_ms)ms"           "$(_g "$b" .p50_ms)ms"
  _row '' '' 'p95'               "$(_g "$a" .p95_ms)ms"           "$(_g "$b" .p95_ms)ms"
  _row '' '' 'p99'               "$(_g "$a" .p99_ms)ms"           "$(_g "$b" .p99_ms)ms"
  if [ -f "$DEMO_STATE/$1.restarts" ] && [ -f "$DEMO_STATE/$2.restarts" ]; then
    _row "$C_BAD" "$C_OK" 'pod restarts' \
      "$(cat "$DEMO_STATE/$1.restarts")" "$(cat "$DEMO_STATE/$2.restarts")"
  fi
  if [ -f "$DEMO_STATE/$1.nodes" ] && [ -f "$DEMO_STATE/$2.nodes" ]; then
    _row "$C_BAD" "$C_OK" 'nodes bought' \
      "$(cat "$DEMO_STATE/$1.nodes")" "$(cat "$DEMO_STATE/$2.nodes")"
  fi
  printf '%b' "$C_B"; _rule '-'; printf '%b\n' "$C_OFF"
}

mark_restarts() { restarts_total > "$DEMO_STATE/$1.restarts"; }
mark_nodes()    { node_count     > "$DEMO_STATE/$1.nodes"; }

# ── the database panel ───────────────────────────────────────────────────────
# A long-lived psql pod, so a query on stage is an exec rather than a cold pod
# start. It connects as the master user, which on RDS holds rds_superuser and
# therefore keeps the reserved connection slots -- the counter stays readable
# even when the wall has locked everything else out.
psql_q() {
  kubectl exec -n "$NS" deploy/dbshell -- \
    sh -c "psql \"\$DSN\" -tAc \"$1\"" 2>/dev/null
}

psql_show() {
  kubectl exec -n "$NS" deploy/dbshell -- \
    sh -c "psql \"\$DSN\" -c \"$1\"" 2>&1
}

# ── reset ────────────────────────────────────────────────────────────────────
demo_reset() {
  load_stop_quiet
  kubectl -n "$NS" delete deploy svc worker --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$NS" delete scaledobject worker --ignore-not-found >/dev/null 2>&1
  # Leftover messages would have KEDA scaling before act 2 has started.
  [ -n "$QUEUE_URL" ] && aws sqs purge-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1
  rm -f "$DEMO_STATE"/*.json "$DEMO_STATE"/*.restarts "$DEMO_STATE"/*.nodes
}

# ── entry ────────────────────────────────────────────────────────────────────
demo_list() {
  local i=0
  printf '\n%b  beats%b\n\n' "$C_B" "$C_OFF"
  while [ $i -lt ${#BEAT_IDS[@]} ]; do
    printf '  %b%-6s%b %s\n' "$C_CMD" "${BEAT_IDS[$i]}" "$C_OFF" "${BEAT_TITLES[$i]}"
    i=$((i + 1))
  done
  printf '\n  %b./demo 2.1%b -- start at beat 2.1 (earlier ones run silently)\n' "$C_CMD" "$C_OFF"
  printf '  %b./demo --reset%b -- tear the workloads down and start over\n\n' "$C_CMD" "$C_OFF"
}

_index_of() {
  local want="$1" i=0
  while [ $i -lt ${#BEAT_IDS[@]} ]; do
    [ "${BEAT_IDS[$i]}" = "$want" ] && { echo "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

demo_main() {
  trap 'load_stop_quiet; _tty_restore; printf "\n"; exit 0' INT TERM

  resolve_env

  case "${1:-}" in
    -l|--list) demo_list; return 0 ;;
    --reset) demo_reset; printf '  %bstate reset%b\n' "$C_OK" "$C_OFF"; return 0 ;;
  esac

  if [ -z "$IMAGE" ] || [ -z "$QUEUE_URL" ]; then
    printf '\n  %bx cannot find the environment%b\n' "$C_BAD" "$C_OFF"
    printf '    IMAGE=%s\n    QUEUE_URL=%s\n' "${IMAGE:-unset}" "${QUEUE_URL:-unset}"
    printf '    run %btask preflight%b\n\n' "$C_B" "$C_OFF"
    return 1
  fi

  _tty_quiet
  # ./stage tells a live session from a stale one by this file: the layout can
  # outlive the driver that was in it.
  echo $$ > "$DEMO_STATE/driver.pid"
  trap '_tty_restore; rm -f "$DEMO_STATE/driver.pid"' EXIT

  local start=0
  if [ -n "${1:-}" ]; then
    start=$(_index_of "$1") || { printf '%bno beat %s%b\n' "$C_BAD" "$1" "$C_OFF"; demo_list; return 1; }
  fi

  if [ "$start" -gt 0 ]; then
    printf '\n  %bfast-forwarding to beat %s...%b\n' "$C_DIM" "$1" "$C_OFF"
    FAST=1
    local j=0
    while [ $j -lt "$start" ]; do "${BEAT_FUNCS[$j]}"; j=$((j + 1)); done
    FAST=0
    printf '  %b+ state restored%b\n' "$C_OK" "$C_OFF"
  fi

  local i="$start"
  while [ $i -lt ${#BEAT_IDS[@]} ]; do
    head_beat "${BEAT_IDS[$i]}" "${BEAT_TITLES[$i]}"
    "${BEAT_FUNCS[$i]}"
    i=$((i + 1))
    [ $i -lt ${#BEAT_IDS[@]} ] && pause "-> beat ${BEAT_IDS[$i]}: ${BEAT_TITLES[$i]}"
  done

  load_stop_quiet
  if type finale >/dev/null 2>&1; then finale; else bigsay "Done."; fi
}
