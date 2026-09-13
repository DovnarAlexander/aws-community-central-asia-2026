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
# Three, not four. The pane is eight rows, one of which tmux spends on the
# border, and the frame is title + blank + headings + ROWS. Four fills it exactly
# and the title scrolls away the moment anything is a row taller than expected;
# three leaves a row of slack, and at one redraw a second the extra second of
# history is worth less than a frame that always holds still.
ROWS="${ROWS:-3}"

C_OFF=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
C_BAD=$'\033[1;31m'; C_WARN=$'\033[1;33m'; C_OK=$'\033[1;32m'

title() { [ -n "${TMUX:-}" ] && tmux select-pane -T "LOAD${1:+ . $1}" 2>/dev/null; return 0; }

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

idle() {
  printf '\033[H\033[J  %sno load running%s\n' "$C_DIM" "$C_OFF"
  title ''
}

head_row() { # head_row LABEL MODE RPS
  printf '\033[H\033[J'
  printf '  %s%s%s %s. %s . %s rps%s\n\n' \
    "$C_B" "${1:-load}" "$C_OFF" "$C_DIM" "${2:-?}" "${3:-?}" "$C_OFF"
  printf '  %s%6s %7s %6s %6s%s\n' "$C_DIM" 'rps' 'p95' '5xx' 'err' "$C_OFF"
}

# The generator prints `rps 300 p95  12ms 5xx  0 err  0`, with the whole line
# coloured and a trailing marker when something is wrong. Reading the four
# numbers out and laying them out here means the columns line up whatever the
# width of each value, which is the entire point of a table.
render_running() { # render_running LABEL MODE RPS < log
  local label="$1" mode="$2" rps="$3" line n p5 s5 er colour
  head_row "$label" "$mode" "$rps"
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
    printf '  %s%6s %7s %6s %6s%s\n' "$colour" "$n" "$p5" "$s5" "$er" "$C_OFF"
  done
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
current=''; state=idle; label=''; mode=''; rps=''
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
    current="$uid"; state=running
    title "$label"
    head_row "$label" "$mode" "$rps"
  fi

  if [ "$state" = done ]; then
    # The final frame stays put until the pod goes away. Nothing to redraw.
    sleep 2
    continue
  fi

  log=$(kubectl -n "$NS" logs "$POD" --tail=40 2>/dev/null | strip_ansi)
  if printf '%s\n' "$log" | grep -q '^-- '; then
    printf '%s\n' "$log" | render_done "$label" && state=done
  else
    printf '%s\n' "$log" | tail -n "$ROWS" | render_running "$label" "$mode" "$rps"
  fi
  sleep 1
done
