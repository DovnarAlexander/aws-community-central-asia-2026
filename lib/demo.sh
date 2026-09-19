#!/usr/bin/env bash
# The stage driver.
#
# The contract with the speaker: the only key pressed is "next" -- right arrow
# on a clicker, Enter, or space. Each step prints a heading, then the exact
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

FAST=0 # set while fast-forwarding to a step: run everything, wait for nothing

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

# The pane, not the measure. _width caps at 100 because a line of prose longer
# than that is hard to read across, but a rule is not prose: capped, it stops
# three columns short of the border on a 103-column driver pane and the cards
# look like they failed to fit. Rules and tables get the real width.
_pane_width() {
  local w
  w=$(stty size 2>/dev/null | awk '{print $2}')
  case "$w" in ''|*[!0-9]*) w=$(tput cols 2>/dev/null) ;; esac
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  [ "$w" -lt 40 ] && w=40
  printf '%s\n' "$w"
}

_rule() { local w; w=$(_pane_width); printf '%*s\n' "$w" '' | tr ' ' "${1:--}"; }

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

# ── the step registry ────────────────────────────────────────────────────────
STEP_IDS=(); STEP_TITLES=(); STEP_FUNCS=()

step() { # step ID TITLE FUNC
  STEP_IDS+=("$1"); STEP_TITLES+=("$2"); STEP_FUNCS+=("$3")
}

# ── what the speaker sees ────────────────────────────────────────────────────
say() {
  [ "$FAST" = 1 ] && return 0
  [ -z "$*" ] && { printf '\n'; return 0; }
  local l
  _fit 2 "$*" | while IFS= read -r l; do printf '  %b%s%b\n' "$C_SAY" "$l" "$C_OFF"; done
  return 0
}

head_step() { # head_step ID TITLE
  [ "$FAST" = 1 ] && return 0

  # The one thing a deck gives a speaker that a terminal does not is a sense of
  # where you are in it. tmux is already drawing a titled border around the
  # driver pane, so the step goes there: always visible, costs no rows, and
  # nobody has to look away from the terminal to find it.
  [ -n "${TMUX:-}" ] && tmux select-pane -T "DEMO . step $1 . $2" 2>/dev/null
  local l first=1
  printf '\n%b' "$C_HEAD"; _rule '='
  # Just the number and the title. An incident has a timeline, not a cast list,
  # and "1.1 . Timur ships a service" needs no noun in front of it -- the two
  # spaces of indent below line the continuation up under the title.
  _fit 2 "$1 . $2" | while IFS= read -r l; do
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
# two steps.
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
# ask [WHAT] -- block until the clicker is pressed, saying what the press does.
#
# "next" told the speaker that a press was expected and nothing about what it
# would cause, which on stage is the difference between clicking confidently and
# clicking to find out. Every caller now passes the consequence: click to apply,
# click to start the load, click to start step 2.1. The default is deliberately
# vague only where the next thing genuinely is just more talking.
ask() { # ask [WHAT]
  [ "$FAST" = 1 ] && return 0
  local what="${1:-click to go on}" key note=''
  while true; do
    printf '\r\033[K  %b[->]%b %b%s%b %b. [s] skip . [q] quit%s%b' \
      "$C_DIM" "$C_OFF" "$C_B" "$what" "$C_OFF" "$C_DIM" "$note" "$C_OFF"
    key=$(read_key) || continue
    case "$key" in
      next) printf '\r\033[K'; return 0 ;;
      skip) printf '\r\033[K  %b(skipped)%b\n' "$C_DIM" "$C_OFF"; return 1 ;;
      quit) printf '\r\033[K\n'; exit 0 ;;
      back) note='   . there is no going back' ;;
    esac
  done
}

pause() { # pause [TEXT] [WHAT]
  [ "$FAST" = 1 ] && return 0
  local text="${1:-}" what="${2:-click to go on}" l
  if [ -n "$text" ]; then
    printf '\n'
    _fit 2 "$text" | while IFS= read -r l; do printf '  %b%s%b\n' "$C_B" "$l" "$C_OFF"; done
  fi
  # Not >/dev/null. That redirect is why this prompt was invisible: pause printed
  # its line in bold, swallowed the one piece of text that said a press was
  # expected, and left the speaker guessing whether the show was waiting for them
  # or for the cluster.
  ask "$what" || true
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
  # Derived rather than passed in: a label at the call site would drift from the
  # command above it the first time somebody edited one and not the other.
  local what='click to run it'
  case "$cmd" in
    *"apply -f"*)   what='click to apply it' ;;
    *"set env"*)    what='click to change it' ;;
    *"get events"*) what='click to see what kubelet said' ;;
    *psql*)         what='click to ask the database' ;;
    *logs*)         what='click to read the logs' ;;
  esac

  ask "$what" || return 0
  eval "$cmd" 2>&1 | sed 's/^/  /'
  local rc=${PIPESTATUS[0]}
  [ "$rc" != 0 ] && printf '  %b-> exit %s%b\n' "$C_WARN" "$rc" "$C_OFF"
  return 0
}

# runq: setup the room does not need to watch.
runq() { eval "$*" >/dev/null 2>&1; return 0; }

# show: put a file on the screen.
# Every manifest opens with a block of comment explaining what it is for and
# what it is about to break. That block is for whoever opens the repository six
# months from now; on stage it is a wall of prose in front of the four lines the
# room came to see, and in a diff between two steps it is the largest hunk on
# screen while the actual change is one line at the bottom. So the header comes
# off before anything is shown. Comments inside the manifest stay: those label
# the thing being pointed at.
_body() { # _body FILE -- the manifest without its header comment
  awk 'started || ($0 !~ /^#/ && $0 !~ /^[[:space:]]*$/) { started = 1; print }' "$1"
}

show() {
  local f="$1"
  printf '\n  %b%s%b\n' "$C_B" "$f" "$C_OFF"
  ask 'click to open it' || return 0
  if command -v bat >/dev/null 2>&1; then
    _body "$DEMO_ROOT/$f" | bat --style=plain --color=always --language=yaml
  else
    _body "$DEMO_ROOT/$f" | sed 's/^/  /'
  fi
}

# showdiff: the most useful slide in the whole talk -- what actually changed.
showdiff() {
  printf '\n  %bwhat changes: %s -> %s%b\n' "$C_B" "$(basename "$1")" "$(basename "$2")" "$C_OFF"
  ask 'click to see the diff' || return 0
  local a b
  a=$(mktemp) && b=$(mktemp) || return 0
  _body "$DEMO_ROOT/$1" > "$a"
  _body "$DEMO_ROOT/$2" > "$b"
  git --no-pager diff --no-index --color=always --unified=2 \
    "$a" "$b" 2>/dev/null | tail -n +5 | sed 's/^/  /'
  rm -f "$a" "$b"
  return 0
}

# ── applying manifests ───────────────────────────────────────────────────────
# Manifests carry ${IMAGE} and ${QUEUE_URL} so that the diffs stay readable and
# the repository stays free of an account id in a dozen files.
export IMAGE="${IMAGE:-}"
export QUEUE_URL="${QUEUE_URL:-}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"

resolve_env() {
  # `terragrunt output -raw` pads its value with trailing spaces, which turn a
  # tag into something the registry reports as a missing repository. Strip.
  [ -n "$IMAGE" ] || IMAGE=$(cd "$DEMO_ROOT/infra/demo/.terragrunt-stack/registry" 2>/dev/null \
    && terragrunt output -raw repository_url 2>/dev/null | tr -d '[:space:]')
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

# The number incident 2 is really about. Karpenter nodes are labelled role=demo, so
# this counts machines bought for the demo and not the one running the system.
node_count() {
  kubectl get nodes -l role=demo --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Rough hourly spend on Karpenter capacity. Spot prices move, so this is an
# order of magnitude rather than an invoice -- but seeing it climb while
# throughput sits at zero is the point of the whole second incident.
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

# _hold: the line that says the show is waiting on purpose.
#
# The countdown used to be four dim characters at the end of the counters
# ("... ~$0.42/h . 80s . [->] click to move on"), which reads as a caption
# rather than as a clock. A presenter who cannot see that the wait is
# deliberate and finite presses the clicker, and the wait -- which exists to
# put KEDA and Karpenter on screen doing the thing -- ends before anything
# happened. Seven waits went that way in the recording that shipped.
#
# So it gets a bar that drains, its own line, and the number first.
_hold() { # _hold LEFT TOTAL
  local left="$1" total="$2" w bar fill i done_ rest full empty tail
  w=$(_pane_width)
  # The hint is the first thing to go on a narrow pane: a bar that wrapped
  # would put half of itself on the row _redraw is about to overwrite.
  tail='let it run . [->] skips'
  bar=$((w - 34))
  if [ "$w" -lt 60 ]; then tail='[->] skips'; bar=$((w - 21)); fi
  [ "$bar" -gt 52 ] && bar=52
  [ "$bar" -lt 8 ] && bar=8
  [ "$total" -gt 0 ] || total=1
  fill=$(( (total - left) * bar / total ))
  [ "$fill" -gt "$bar" ] && fill="$bar"
  [ "$fill" -lt 0 ] && fill=0
  # Built from octal escapes rather than written as characters. The bash that
  # ships with macOS is 3.2 and loses bytes out of a multibyte literal it is
  # asked to append in a loop, which turned the bar into mojibake; printf hands
  # back the three bytes intact whatever the shell thinks a character is.
  full=$(printf '\342\226\210'); empty=$(printf '\342\226\221')
  done_=''; rest=''
  i=0; while [ $i -lt "$fill" ]; do done_="$done_$full"; i=$((i + 1)); done
  i=$fill; while [ $i -lt "$bar" ]; do rest="$rest$empty"; i=$((i + 1)); done
  printf '  %s%3ss%s  %s%s%s%s%s%s  %s%s%s\n' \
    "$C_B" "$left" "$C_OFF" "$C_WARN" "$done_" "$C_OFF" \
    "$C_DIM" "$rest" "$C_OFF" "$C_DIM" "$tail" "$C_OFF"
}

# _drain: throw away keystrokes that are already queued.
#
# A clicker press that arrives while the driver is busy sits in the terminal
# buffer until something reads it, and the next thing to read is usually a
# timed wait -- which treats it as "move on" and skips the very thing the step
# exists to show. That is not hypothetical: the committed recording lost all
# three of incident 2's waits this way, so the cascade was never on screen.
# Waits therefore start from an empty buffer. `pause` deliberately does not
# drain: there a queued press is the presenter being ready, and honouring it is
# correct.
_drain() {
  [ -t 0 ] || return 0
  local saved junk
  # Not `read -t 0.01`: the bash macOS ships is 3.2 and takes whole seconds
  # only, so a fractional timeout is a hard error and every wait printed one.
  # A whole second would work and cost a second of the show at each of the nine
  # waits, so the terminal driver does it instead. With canonical mode off and
  # min 0 time 0 a read returns whatever is already queued and then returns
  # nothing, which bash reads as end of input -- one call, no waiting. `read`
  # is used without -n here on purpose: -n makes bash set VMIN=1 itself, which
  # would undo the very setting this depends on.
  saved=$(stty -g 2>/dev/null) || return 0
  stty -icanon -echo min 0 time 0 2>/dev/null || return 0
  IFS= read -r junk 2>/dev/null
  stty "$saved" 2>/dev/null
  return 0
}

# watch_pods: a live table in the driver panel, counting down. "Next" cuts the
# wait short -- useful once the room has clearly got the point.
watch_pods() { # watch_pods SECONDS [CAPTION] [SELECTOR]
  [ "$FAST" = 1 ] && { sleep "${1:-5}"; return 0; }
  _drain
  local secs="${1:-30}" cap="${2:-}" sel="${3:-app in (svc,worker)}"
  local start=$SECONDS
  _redraw_lines=0
  printf '\n'
  while [ $((SECONDS - start)) -lt "$secs" ]; do
    local left=$((secs - (SECONDS - start)))
    local body
    body="  ${C_DIM}${cap}${C_OFF}
  ${C_DIM}ready ${C_OFF}${C_B}$(ready_count "$sel")${C_OFF}${C_DIM} . restarts ${C_OFF}${C_B}$(restarts_total "$sel")${C_OFF}${C_DIM} . nodes ${C_OFF}${C_B}$(node_count)${C_OFF}
$(_hold "$left" "$secs")
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

# watch_scale: incident 2's panel. Queue depth and node count next to each other is
# the whole argument -- one climbing while the other climbs, and throughput at
# zero between them.
watch_scale() { # watch_scale SECONDS [CAPTION]
  [ "$FAST" = 1 ] && { sleep "${1:-5}"; return 0; }
  _drain
  local secs="${1:-60}" cap="${2:-}"
  local start=$SECONDS
  _redraw_lines=0
  printf '\n'
  while [ $((SECONDS - start)) -lt "$secs" ]; do
    local left=$((secs - (SECONDS - start)))
    local body
    body="  ${C_DIM}${cap}${C_OFF}
  ${C_DIM}queue ${C_OFF}${C_B}$(queue_depth)${C_OFF}${C_DIM} . workers ${C_OFF}${C_B}$(ready_count 'app=worker')${C_OFF}${C_DIM} . nodes ${C_OFF}${C_B}$(node_count)${C_OFF}${C_DIM} ~\$$(node_burn)/h${C_OFF}
$(_hold "$left" "$secs")
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

# ── teaching while the cluster works ─────────────────────────────────────────
# The waits in this demo are of two kinds and only one of them is the show.
# RESTARTS climbing, the queue depth and the node count pulling apart -- that is
# what the room came for, and nothing may be printed over it. The rest is dead
# time: a node being bought, a rollout settling, a queue filling before KEDA has
# looked at it. That is where the theory goes now, so the talk explains a probe
# while the cluster is busy proving the point, instead of spending six minutes
# on slides first and demonstrating afterwards.
#
#   teach 'HEADING' 'line' 'line' -- 'command that ends the wait' [TIMEOUT] [CAPTION]
#
# The card stays on screen while the command is polled underneath it, and the
# right-hand panes keep running the whole time. That is the reason these are
# cards in the terminal rather than slides in another window: the node counter
# climbs next to the card explaining why it climbs, and one tmux window means
# nothing to switch to and nothing to switch back from.
teach()        { _teach card        "$@"; }  # teach HEADING LINE... -- 'CMD' [TIMEOUT] [CAP]
teach_madina() { _teach madina_card "$@"; }  # the same, signed

# notes: the card with no wait attached and no press to continue, for the steps
# that do their own waiting afterwards. The rule it exists to keep is that the
# text is on screen from the first second of a wait rather than after it -- the
# speaker should be reading the card aloud while the cluster works, not watching
# a countdown in silence and explaining once it has finished.
notes()        { card        "$@"; }
notes_madina() { madina_card "$@"; }

# settle: the wait under a step that is talking rather than showing a card --
# an argument belongs in a voice, and a card left up through it would be two
# things asking for the same attention.
settle() { _wait_keyed "$@"; }

_teach() { # _teach RENDERER HEADING LINE... -- 'WAIT_COMMAND' [TIMEOUT] [CAPTION]
  local render="$1"; shift
  local heading="$1"; shift
  local body=()
  while [ $# -gt 0 ] && [ "$1" != '--' ]; do body[${#body[@]}]="$1"; shift; done
  [ "${1:-}" = '--' ] && shift
  local cmd="${1:-}" timeout="${2:-180}" cap="${3:-waiting}"

  if [ "$FAST" = 1 ]; then
    [ -n "$cmd" ] && wait_for "$cmd" "$timeout" "$cap"
    return 0
  fi

  if [ ${#body[@]} -gt 0 ]; then "$render" "$heading" "${body[@]}"; else "$render" "$heading"; fi

  [ -n "$cmd" ] || { ask 'click when you are done with this' || true; return 0; }
  _wait_keyed "$cmd" "$timeout" "$cap"
}

# wait_for, except that a press also ends it. Under a card the speaker is
# talking, not watching a spinner, and Karpenter takes anywhere between twenty
# seconds and a minute -- so a card is written with the line that matters first
# and the rest as depth to drop when the node arrives early.
#
# Pressing next here means "I am done talking", not "the cluster is ready". It
# is the same contract as `skip` on any other prompt: the speaker's call.
_wait_keyed() { # _wait_keyed 'COMMAND' TIMEOUT 'CAPTION'
  local cmd="$1" timeout="${2:-180}" cap="${3:-waiting}"
  local start=$SECONDS spin='|/-\' i=0
  while [ $((SECONDS - start)) -lt "$timeout" ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      printf '\r\033[K  %b+ %s (%ss)%b\n' "$C_OK" "$cap" "$((SECONDS - start))" "$C_OFF"
      return 0
    fi
    i=$(((i + 1) % 4))
    printf '\r\033[K  %b%s %s (%ss) . [->] click when you are done talking%b' \
      "$C_DIM" "${spin:$i:1}" "$cap" "$((SECONDS - start))" "$C_OFF"
    # Under `task smoke` stdin is a pipe: poll on a plain sleep, or the wait
    # ends on the first line of feed and the assertions run too early.
    if [ -t 0 ]; then
      case "$(read_key 1)" in
        next|skip) printf '\r\033[K'; return 0 ;;
        quit) printf '\r\033[K\n'; exit 0 ;;
      esac
    else
      sleep 1
    fi
  done
  printf '\r\033[K  %bx gave up: %s%b\n' "$C_WARN" "$cap" "$C_OFF"
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

  # Starting and stopping the load are events in the show, not footnotes. They
  # used to be one terse line and one dim one, so the room could watch the
  # numbers move on the right without ever being told what had been turned on.
  [ "$FAST" = 1 ] || {
    printf '\n  %bload starts%b  %b%s%b %s. %s . %s rps' \
      "$C_OK" "$C_OFF" "$C_B" "$label" "$C_OFF" "$C_DIM" "$mode" "$rps"
    case "$duration" in 0s|'') printf ' until it is stopped' ;; *) printf ' for %s' "$duration" ;; esac
    printf '%b\n' "$C_OFF"
    printf '  %swatch the LOAD panel, bottom right%s\n' "$C_DIM" "$C_OFF"
  }
}

load_stop_quiet() {
  # The generator prints its SUMMARY when it stops, not while it runs -- so ask
  # it to stop, then read. Reading first only ever worked for the incident 2 loads,
  # which carry a -duration and therefore stop on their own; incident 1 runs until
  # signalled, so its summary was collected before it existed and the before and
  # after table had nothing to compare for the entire life of this demo.
  #
  # Deleting the pod is the signal. Logs stay readable while it terminates, and
  # that is the window this loop reads in.
  if [ -f "$DEMO_STATE/load.label" ]; then
    local label summary
    label=$(cat "$DEMO_STATE/load.label")

    # Read before deleting. A generator that carried a -duration has already
    # stopped, printed its summary and is sitting there Completed -- deleting it
    # first would take the log away with it.
    summary=$(kubectl -n "$NS" logs loadgen 2>/dev/null | grep '^SUMMARY ' | tail -1)

    if [ -z "$summary" ]; then
      # Still running, which means the step was cut short -- every load in the
      # show carries a -duration chosen to end inside its own window. Deleting
      # the pod is the only signal available (the image is distroless: no shell,
      # nothing to exec a kill into), and it is a poor one: the container prints
      # the summary and exits, and the pod object follows it within about a
      # second. So poll without sleeping, and give up the moment kubectl says
      # the pod is gone rather than spending the whole deadline on a corpse.
      local out rc deadline
      kubectl -n "$NS" delete pod loadgen --ignore-not-found --grace-period=15 --wait=false >/dev/null 2>&1
      deadline=$((SECONDS + 10))
      while [ "$SECONDS" -lt "$deadline" ]; do
        out=$(kubectl -n "$NS" logs loadgen 2>/dev/null); rc=$?
        summary=$(printf '%s\n' "$out" | grep '^SUMMARY ' | tail -1)
        [ -n "$summary" ] && break
        [ "$rc" -ne 0 ] && break
      done
    fi

    printf '%s' "${summary#SUMMARY }" > "$DEMO_STATE/$label.json"
    rm -f "$DEMO_STATE/load.label"
  fi
  kubectl -n "$NS" delete pod loadgen --ignore-not-found --wait=false >/dev/null 2>&1
}

load_stop() {
  # The label has to be read before load_stop_quiet collects it and takes the
  # file away, or the line that announces the end of a run cannot name it.
  local label=''
  [ -f "$DEMO_STATE/load.label" ] && label=$(cat "$DEMO_STATE/load.label" 2>/dev/null)
  load_stop_quiet
  [ "$FAST" = 1 ] || printf '\n  %bload stops%b   %b%s%b %s. the panel keeps the summary%s\n' \
    "$C_WARN" "$C_OFF" "$C_B" "${label:-load}" "$C_OFF" "$C_DIM" "$C_OFF"
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

# The selector matters: incident 1 is about the api and must not count a worker left
# over from a previous run, which is how "the fixed probe does not restart pods"
# ends up failing on somebody else's restarts.
mark_restarts() { # mark_restarts LABEL [SELECTOR]
  restarts_total "${2:-app in (svc,worker)}" > "$DEMO_STATE/$1.restarts"
}
mark_nodes()    { node_count     > "$DEMO_STATE/$1.nodes"; }

# The number incident 2 turns on: before the fix most workers are up and NotReady,
# after it every one of them serves. Node count cannot carry that proof --
# Karpenter's consolidateAfter is 2m and the step is shorter than that.
mark_workers() { # mark_workers LABEL
  local rc; rc=$(ready_count 'app=worker')
  printf '%s' "${rc%%/*}" > "$DEMO_STATE/$1.workers_ready"
  printf '%s' "${rc##*/}" > "$DEMO_STATE/$1.workers_total"
}

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

  # Leftover messages would have KEDA scaling before incident 2 has started -- an incident
  # that opens on a queue which is already deep is a different incident. A purge is
  # asynchronous, AWS allows one a minute and it can take a minute to finish, so
  # this waits for the depth to actually reach zero instead of assuming it.
  if [ -n "$QUEUE_URL" ]; then
    local dlq deadline
    aws sqs purge-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1

    # The dead letter queue too: nothing reads it during the demo, but a pile of
    # yesterday's failures in there is a confusing thing to find while debugging
    # why today's messages are not being processed.
    dlq=$(aws sqs get-queue-url --queue-name "$PROJECT-dlq" --query QueueUrl --output text 2>/dev/null)
    case "$dlq" in ''|None) : ;; *) aws sqs purge-queue --queue-url "$dlq" >/dev/null 2>&1 ;; esac

    deadline=$((SECONDS + 90))
    while [ "$SECONDS" -lt "$deadline" ]; do
      case "$(queue_depth)" in '0/0'|'') break ;; esac
      sleep 3
    done
  fi

  # Everything the run wrote, by exclusion rather than by list. The list came
  # first and went stale the moment a new kind of marker was added: after the
  # worker counts arrived, a reset left last run's numbers sitting there for the
  # next run's assertions to read. Excluding the two files that are not markers
  # cannot go stale in the same way.
  find "$DEMO_STATE" -maxdepth 1 -type f \
    ! -name 'driver.pid' ! -name 'smoke.log' -delete 2>/dev/null

  # The other half of "the state the show starts from", and the half this used
  # to leave to luck: not only the absence of the last run, but the presence of
  # everything the steps assume. All three applies are no-ops when the objects
  # are already there, which is what makes this safe to run from any state --
  # after a smoke, on a half-built cluster, or twice in a row.
  #
  # The db secret is not here because it comes out of SSM rather than a file;
  # `task reset` runs `task secrets` in front of this for that one.
  kubectl apply -f "$DEMO_ROOT/k8s/00-namespace.yaml" -f "$DEMO_ROOT/k8s/00-service.yaml" >/dev/null 2>&1
  kubectl apply -f "$DEMO_ROOT/k8s/dbshell.yaml" >/dev/null 2>&1
  kubectl -n "$NS" rollout status deploy/dbshell --timeout=60s >/dev/null 2>&1
}

# ── entry ────────────────────────────────────────────────────────────────────
demo_list() {
  local i=0
  printf '\n%b  the timeline%b\n\n' "$C_B" "$C_OFF"
  while [ $i -lt ${#STEP_IDS[@]} ]; do
    printf '  %b%-6s%b %s\n' "$C_CMD" "${STEP_IDS[$i]}" "$C_OFF" "${STEP_TITLES[$i]}"
    i=$((i + 1))
  done
  printf '\n  %b./demo 2.1%b -- start at step 2.1 (earlier ones run silently)\n' "$C_CMD" "$C_OFF"
  printf '  %b./demo --reset%b -- tear the workloads down and start over\n\n' "$C_CMD" "$C_OFF"
}

_index_of() {
  local want="$1" i=0
  while [ $i -lt ${#STEP_IDS[@]} ]; do
    [ "${STEP_IDS[$i]}" = "$want" ] && { echo "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}

demo_main() {
  trap 'load_stop_quiet; _tty_restore; printf "\n"; exit 0' INT TERM

  resolve_env

  case "${1:-}" in
    -l|--list) demo_list; return 0 ;;
    --reset) demo_reset
             printf '  %b+ workloads gone, queues empty, marks cleared, dbshell up%b\n' "$C_OK" "$C_OFF"
             return 0 ;;
  esac

  # Checked here rather than left to the first apply: a missing envsubst makes
  # every manifest resolve to an empty stream, and the driver would otherwise
  # run the whole show against a namespace in which nothing was ever created.
  if ! command -v envsubst >/dev/null 2>&1; then
    printf '\n  %bx envsubst not found%b\n' "$C_BAD" "$C_OFF"
    printf '    every manifest on stage is applied through it\n'
    printf '    %bbrew install gettext%b\n\n' "$C_B" "$C_OFF"
    return 1
  fi

  if [ -z "$IMAGE" ] || [ -z "$QUEUE_URL" ]; then
    printf '\n  %bx cannot find the environment%b\n' "$C_BAD" "$C_OFF"
    printf '    IMAGE=%s\n    QUEUE_URL=%s\n' "${IMAGE:-unset}" "${QUEUE_URL:-unset}"
    printf '    run %btask preflight%b\n\n' "$C_B" "$C_OFF"
    return 1
  fi

  # Starting from the top against a cluster that still carries a previous run is
  # the quiet way to ruin a rehearsal: incident 1 plays with incident 2's workers already
  # running and KEDA scaling behind it, and incident 2 opens with the scale-up it
  # exists to demonstrate already finished. A `task smoke` the night before
  # leaves exactly that. Jumping to a step is exempt -- rebuilding the state of
  # the steps before it is the entire point of doing so.
  if [ -z "${1:-}" ]; then
    local leftovers=''
    kubectl -n "$NS" get deploy svc          >/dev/null 2>&1 && leftovers="$leftovers deploy/svc"
    kubectl -n "$NS" get deploy worker       >/dev/null 2>&1 && leftovers="$leftovers deploy/worker"
    kubectl -n "$NS" get scaledobject worker >/dev/null 2>&1 && leftovers="$leftovers scaledobject/worker"
    if [ -n "$leftovers" ]; then
      printf '\n  %bx the cluster still has a previous run on it%b\n' "$C_BAD" "$C_OFF"
      printf '    %s\n' "$leftovers"
      printf '    %btask reset%b, then start again\n\n' "$C_B" "$C_OFF"
      return 1
    fi
  fi

  _tty_quiet
  # ./stage tells a live session from a stale one by this file: the layout can
  # outlive the driver that was in it.
  echo $$ > "$DEMO_STATE/driver.pid"
  trap '_tty_restore; rm -f "$DEMO_STATE/driver.pid"' EXIT

  local start=0
  if [ -n "${1:-}" ]; then
    start=$(_index_of "$1") || { printf '%bno step %s%b\n' "$C_BAD" "$1" "$C_OFF"; demo_list; return 1; }
  fi

  if [ "$start" -gt 0 ]; then
    printf '\n  %bfast-forwarding to step %s...%b\n' "$C_DIM" "$1" "$C_OFF"
    FAST=1
    local j=0
    while [ $j -lt "$start" ]; do "${STEP_FUNCS[$j]}"; j=$((j + 1)); done
    FAST=0
    printf '  %b+ state restored%b\n' "$C_OK" "$C_OFF"
  fi

  local i="$start"
  while [ $i -lt ${#STEP_IDS[@]} ]; do
    head_step "${STEP_IDS[$i]}" "${STEP_TITLES[$i]}"
    "${STEP_FUNCS[$i]}"
    i=$((i + 1))
    [ $i -lt ${#STEP_IDS[@]} ] && pause "-> step ${STEP_IDS[$i]}: ${STEP_TITLES[$i]}" "click to start step ${STEP_IDS[$i]}"
  done

  load_stop_quiet
  if type finale >/dev/null 2>&1; then finale; else bigsay "Done."; fi
}
