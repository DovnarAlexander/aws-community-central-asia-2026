#!/usr/bin/env bash
# The bottom right pane: whatever the load generator is doing, if anything.
#
# This used to be a single `kubectl logs -f pod/loadgen` sent to the pane when
# the stage was built. At that moment there is no loadgen pod -- there is not
# supposed to be -- so the command failed, printed "no load running" and exited,
# and the pane spent the rest of the talk as a shell prompt. All four loads in
# the show ran unwatched, including the two the before/after table is built from.
#
# It also scrolled, which is the wrong shape for the job. A scrolling log has no
# column headings after the first five seconds, and it ended on a line of raw
# JSON. So this redraws a table in place instead, the way the stat panel next to
# it already does: the headings stay, the numbers move underneath them, and the
# finished run leaves a readable summary rather than a serialised struct.

set -uo pipefail

NS="${NS:-demo}"
POD=loadgen
# The pane is eleven rows, one of which tmux spends on the border, and the frame
# is title + blank + headings + ROWS + blank + totals. Four history rows leave a
# row of slack, so the title never scrolls away when a value comes out wider
# than expected. The pane was eight rows and showed three seconds of history and
# nothing else, which is a lot of space for four numbers.
ROWS="${ROWS:-4}"

C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'; C_OK=$'\033[1;32m'

title() { [ -n "${TMUX:-}" ] && tmux select-pane -T "LOAD${1:+ . $1}" 2>/dev/null; return 0; }

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

idle() {
  printf '\033[H\033[J  %sno load running%s\n' "$C_DIM" "$C_OFF"
  title ''
}

# mm:ss, because a run is under two minutes and "0:45" reads at a glance where
# "45s elapsed of 45s" does not.
clock() { printf '%d:%02d' $(( ${1:-0} / 60 )) $(( ${1:-0} % 60 )); }

width() { local w; w=$(tput cols 2>/dev/null); case "$w" in ''|*[!0-9]*) w=60 ;; esac; printf '%s' "$w"; }

head_row() { # head_row LABEL MODE RPS ELAPSED DURATION
  local left right pad w
  w=$(width)
  left="${1:-load} . ${2:-?} . ${3:-?} rps"
  # The clock is the thing the room cannot get from anywhere else: the panel
  # shows four numbers changing and no sense of how long they have left to
  # change for. Blank when the run has no duration, which is incident 1 -- it
  # stops when the driver says so.
  right=''
  [ -n "${5:-}" ] && [ "${5:-}" != 0 ] && right="$(clock "${4:-0}") / $(clock "$5")"
  pad=$(( w - 2 - ${#left} - ${#right} - 2 ))
  [ "$pad" -lt 1 ] && pad=1
  printf '\033[H\033[J'
  printf '  %s%s%s%*s%s%s%s\n\n' "$C_B" "$left" "$C_OFF" "$pad" '' "$C_DIM" "$right" "$C_OFF"
  printf '  %s%6s %8s %6s %6s%s\n' "$C_DIM" 'rps' 'p95' '5xx' 'err' "$C_OFF"
}

# What the run has done so far, under the rows that show what it is doing now.
# Every number here is a sum over the whole log rather than the visible tail,
# so the footer does not reset when the history scrolls.
totals_row() { # totals_row SENT ELAPSED TARGET S5 ERR
  local sent="${1:-0}" el="${2:-0}" target="${3:-0}" s5="${4:-0}" er="${5:-0}" avg=0 colour=''
  [ "$el" -gt 0 ] && avg=$(( sent / el ))
  # Amber when the generator cannot place the load it was asked for: that is the
  # service failing to keep up, and it shows here before it shows anywhere else.
  [ "$target" -gt 0 ] && [ "$avg" -lt $(( target * 4 / 5 )) ] && colour="$C_WARN"
  { [ "$s5" -gt 0 ] || [ "$er" -gt 0 ]; } && colour="$C_BAD"
  printf '\n  %ssent%s %s   %savg%s %s%s/s of %s%s   %s5xx%s %s   %serr%s %s\n' \
    "$C_DIM" "$C_OFF" "$sent" \
    "$C_DIM" "$C_OFF" "$colour" "$avg" "$target" "$C_OFF" \
    "$C_DIM" "$C_OFF" "$s5" "$C_DIM" "$C_OFF" "$er"
}

# The generator prints `rps 300 p95  12ms 5xx  0 err  0`, with the whole line
# coloured and a trailing marker when something is wrong. Reading the four
# numbers out and laying them out here means the columns line up whatever the
# width of each value, which is the entire point of a table.
render_running() { # render_running LABEL MODE RPS ELAPSED DURATION SENT S5 ERR < tail
  local label="$1" mode="$2" rps="$3" el="$4" dur="$5" sent="$6" tot5="$7" toter="$8"
  local line n p5 s5 er colour
  head_row "$label" "$mode" "$rps" "$el" "$dur"
  while IFS= read -r line; do
    [[ "$line" =~ ^rps[[:space:]]+([0-9]+)[[:space:]]+p95[[:space:]]+([0-9a-z.]+)[[:space:]]+5xx[[:space:]]+([0-9]+)[[:space:]]+err[[:space:]]+([0-9]+) ]] || continue
    n="${BASH_REMATCH[1]}"; p5="${BASH_REMATCH[2]}"
    s5="${BASH_REMATCH[3]}"; er="${BASH_REMATCH[4]}"
    # Red when requests are failing, amber when they are merely slow: under a
    # liveness probe with timeoutSeconds: 1, slow is how the failure starts, and
    # seeing the row change colour before anything breaks is half the lesson.
    # *ms is tested before *s on purpose: case takes the first match, and
    # "980ms" ends in s too. Anything measured in whole seconds is slow by
    # definition -- the liveness probe in step 1.3 gives up after one.
    colour=''
    case "$p5" in
      *ms) [ "${p5%ms}" -gt 500 ] 2>/dev/null && colour="$C_WARN" ;;
      *s)  colour="$C_WARN" ;;
    esac
    [ "$s5" -gt 0 ] || [ "$er" -gt 0 ] && colour="$C_BAD"
    printf '  %s%6s %8s %6s %6s%s\n' "$colour" "$n" "$p5" "$s5" "$er" "$C_OFF"
  done
  totals_row "$sent" "$el" "$rps" "$tot5" "$toter"
}

# The generator's own last line already reads as prose:
#   -- label: 13100 requests, 2xx 13059, 5xx 41, err 0, p50 140ms, p95 189ms...
# so the numbers come from there rather than from the JSON next to it.
render_done() { # render_done LABEL < log
  local label="$1" tail_line req ok srv err p50 p95
  tail_line=$(grep '^-- ' | tail -1)
  [ -n "$tail_line" ] || return 1

  req=$(printf '%s' "$tail_line" | sed -n 's/.*: \([0-9]*\) requests.*/\1/p')
  ok=$(printf '%s'  "$tail_line" | sed -n 's/.*2xx \([0-9]*\).*/\1/p')
  srv=$(printf '%s' "$tail_line" | sed -n 's/.*5xx \([0-9]*\).*/\1/p')
  err=$(printf '%s' "$tail_line" | sed -n 's/.*err \([0-9]*\).*/\1/p')
  p50=$(printf '%s' "$tail_line" | sed -n 's/.*p50 \([0-9a-z.]*\).*/\1/p')
  p95=$(printf '%s' "$tail_line" | sed -n 's/.*p95 \([0-9a-z.]*\).*/\1/p')

  printf '\033[H\033[J'
  printf '  %s%s%s %sfinished%s\n\n' "$C_B" "$label" "$C_OFF" "$C_DIM" "$C_OFF"
  printf '  %ssent%s %8s    %sp50%s %7s\n' "$C_DIM" "$C_OFF" "${req:-?}" "$C_DIM" "$C_OFF" "${p50:-?}"
  printf '  %s2xx %s %s%8s%s    %sp95%s %7s\n' \
    "$C_DIM" "$C_OFF" "$C_OK" "${ok:-?}" "$C_OFF" "$C_DIM" "$C_OFF" "${p95:-?}"
  printf '  %s5xx %s %s%8s%s    %serr%s %s%7s%s\n' \
    "$C_DIM" "$C_OFF" "$([ "${srv:-0}" -gt 0 ] && printf '%s' "$C_BAD")" "${srv:-?}" "$C_OFF" \
    "$C_DIM" "$C_OFF" "$([ "${err:-0}" -gt 0 ] && printf '%s' "$C_BAD")" "${err:-?}" "$C_OFF"
  return 0
}

# The uid rather than the name: every load in the show reuses the name `loadgen`,
# and following by name alone would either stay on a finished run forever or miss
# the next one entirely.
current=''; state=idle; label=''; mode=''; rps=''; dur=''
idle

while true; do
  uid=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null)

  if [ -z "$uid" ]; then
    [ "$state" != idle ] && { state=idle; current=''; idle; }
    sleep 2
    continue
  fi

  if [ "$uid" != "$current" ]; then
    # A pod that has not started has no log to read, so wait rather than spin.
    case "$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" in
      ''|Pending) sleep 1; continue ;;
    esac
    args=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].args[*]}' 2>/dev/null)
    label=$(printf '%s\n' "$args" | tr ' ' '\n' | sed -n 's/^-label=//p')
    mode=$(printf '%s\n' "$args"  | tr ' ' '\n' | sed -n 's/^-mode=//p')
    rps=$(printf '%s\n' "$args"   | tr ' ' '\n' | sed -n 's/^-rps=//p')
    # -duration=45s -> 45. Incident 1's loads carry no duration and stop when
    # the driver deletes the pod, so an empty value here means "no clock".
    dur=$(printf '%s\n' "$args"   | tr ' ' '\n' | sed -n 's/^-duration=\([0-9]*\)s$/\1/p')
    current="$uid"; state=running
    title "$label"
    head_row "$label" "$mode" "$rps" 0 "$dur"
  fi

  if [ "$state" = done ]; then
    # The final frame stays put until the pod goes away. Nothing to redraw.
    sleep 2
    continue
  fi

  # The whole log rather than the last forty lines: the footer sums every second
  # of the run, and a tail would make those totals restart once the run outlived
  # the window. Ninety lines of text once a second costs nothing.
  log=$(kubectl -n "$NS" logs "$POD" 2>/dev/null | strip_ansi)
  if printf '%s\n' "$log" | grep -q '^-- '; then
    printf '%s\n' "$log" | render_done "$label" && state=done
  else
    # One line a second, so the count of them is the elapsed time.
    stats=$(printf '%s\n' "$log" | awk '
      /^rps[ \t]+[0-9]+/ { n++; sent += $2; for (i = 1; i < NF; i++) {
          if ($i == "5xx") s5 += $(i+1); if ($i == "err") er += $(i+1) } }
      END { printf "%d %d %d %d", n+0, sent+0, s5+0, er+0 }')
    set -- $stats
    printf '%s\n' "$log" | grep '^rps' | tail -n "$ROWS" \
      | render_running "$label" "$mode" "$rps" "$1" "$dur" "$2" "$3" "$4"
  fi
  sleep 1
done
