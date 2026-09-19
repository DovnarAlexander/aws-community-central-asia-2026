#!/usr/bin/env bash
# Who is on call, and the opening titles.
#
# The demo tells the story of one team: Timur writes the service, Ruslan fixes
# production by editing numbers, Madina reads the documentation. They are the
# people two incidents happen to, and the postmortem at the end is theirs. The driver
# prints their lines and the speaker reads them out. Everything needed to set up
# the story happens in the terminal, so there is no slide introducing anyone and
# no reason to leave the window.
#
# Two members of the cast are new to the AWS edition, and they are the ones with
# a budget: KEDA decides how many workers there should be, Karpenter buys the
# machines to put them on. Neither has an opinion about whether that is a good
# idea.
#
# Written for bash 3.2, the system bash on macOS: no associative arrays, no
# mapfile.

# ── colours ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_TIMUR=$'\033[1;34m'; C_RUSLAN=$'\033[1;33m'; C_MADINA=$'\033[1;32m'
  C_KUBELET=$'\033[0;37m'; C_PG=$'\033[1;35m'
  C_KEDA=$'\033[1;31m'; C_KARPENTER=$'\033[1;36m'
else
  C_TIMUR=; C_RUSLAN=; C_MADINA=; C_KUBELET=; C_PG=; C_KEDA=; C_KARPENTER=
fi

# ── one line of dialogue ─────────────────────────────────────────────────────
# Format:  (o_o) Timur     > line
#
# The header is 20 characters wide. It was 19 in the original; "Karpenter" is
# nine characters and did not fit. A long line wraps with an eight-space indent
# -- under the face rather than under the text, which leaves the narrow stage
# panel some air.
_by() { # _by COLOUR FACE NAME LINE...
  [ "$FAST" = 1 ] && return 0
  local color="$1" face="$2" name="$3"; shift 3
  local l head
  head="  ${color}${face} $(_col 9 "$name")${C_OFF} ${C_DIM}>${C_OFF} "
  _fit 20 "$*" | while IFS= read -r l; do
    printf '%s%b%s%b\n' "$head" "$C_SAY" "$l" "$C_OFF"
    head='        '
  done
  return 0
}

timur()     { _by "$C_TIMUR"     '(o_o)' 'Timur'     "$@"; }
ruslan()    { _by "$C_RUSLAN"    '(-_-)' 'Ruslan'    "$@"; }
madina()    { _by "$C_MADINA"    '(^_^)' 'Madina'    "$@"; }
kubelet()   { _by "$C_KUBELET"   '[o_o]' 'kubelet'   "$@"; }
pg()        { _by "$C_PG"        '(~_~)' 'Postgres'  "$@"; }
keda()      { _by "$C_KEDA"      '[>_<]' 'KEDA'      "$@"; }
karpenter() { _by "$C_KARPENTER" '[$_$]' 'Karpenter' "$@"; }

# ── changing the application, out loud ───────────────────────────────────────
# The probes live in the manifest and the room watches them change in a diff.
# The service's own settings live in the same file and change in the same diff:
# how long it warms up, whether /healthz leaves the process, how big the pool
# is. Nothing on screen tells those two apart, so a step that raises
# initialDelaySeconds and quietly halves WARMUP_SECONDS in the same breath reads
# as a probe being fixed by editing the application -- which is not the argument
# this talk is making, and is exactly the kind of sleight of hand a room notices
# without being able to name.
#
# So every application-level change is announced by whoever owns the
# application, by name, with the reason. A probe change needs no such line: the
# whole talk is about probes, and the diff is the point.
#
#   appchange timur 'WARMUP_SECONDS  30 -> 10' "I trimmed the cache warm-up ..."
#
# The marker is deliberately not a speech bubble. It is a label on the change
# itself, and the reason follows in the owner's voice underneath it.
appchange() { # appchange SPEAKER 'VAR from -> to' WHY...
  [ "$FAST" = 1 ] && return 0
  local who="$1" what="$2"; shift 2
  printf '\n  %bapp change%b  %b%s%b\n' "$C_WARN" "$C_OFF" "$C_B" "$what" "$C_OFF"
  "$who" "$@"
  return 0
}

# ── animation ────────────────────────────────────────────────────────────────
# ANIM=1 types slowly. Any key stops the animation for the rest of the titles:
# if the schedule is tight, the speaker presses next and the text lands at once.
ANIM=0

_nap() { [ "$ANIM" = 1 ] && sleep "$1"; return 0; }

_type() { # _type COLOUR INDENT TEXT... -- a word at a time, wrapped to the panel
  local color="$1" pad="$2"; shift 2
  local l w first
  _fit "$pad" "$*" | while IFS= read -r l; do
    printf '%*s%b' "$pad" '' "$color"
    if [ "$ANIM" != 1 ]; then
      printf '%s' "$l"
    else
      first=1
      set -f
      for w in $l; do
        [ "$first" = 1 ] && first=0 || printf ' '
        printf '%s' "$w"
        sleep 0.03
      done
      set +f
    fi
    printf '%b\n' "$C_OFF"
  done
  return 0
}

# A step to think, which any key cuts short.
_beat_pause() {
  [ "$ANIM" = 1 ] || return 0
  case "$(read_key 1)" in
    next|skip) ANIM=0 ;;
    quit) exit 0 ;;
  esac
  return 0
}

_dots() { # _dots LABEL -- a line of running dots ending in ok
  [ "$FAST" = 1 ] && return 0
  printf '  %b%s%b ' "$C_DIM" "$(_col 24 "$1")" "$C_OFF"
  local i=0
  while [ "$i" -lt 10 ]; do printf '%b.%b' "$C_DIM" "$C_OFF"; _nap 0.05; i=$((i + 1)); done
  printf ' %bok%b\n' "$C_OK" "$C_OFF"
}

# ── cards ────────────────────────────────────────────────────────────────────
# Ruled on the left only: no width is computed, so nothing can misalign.
card() { # card HEADING LINE...
  [ "$FAST" = 1 ] && return 0
  local head="$1"; shift
  printf '\n  %b%s%b\n' "$C_B" "$head" "$C_OFF"
  _card_body "$@"
}

# A card that belongs to somebody. Nearly every teaching card in the show is
# Madina's: she is the one whose whole part is having read the documentation,
# and putting her name on them changes what they are. Unattributed, a card is
# the author interrupting the story to explain something. Signed, it is a thing
# a character produced -- which is the same content without the interruption,
# and it gives the room a person to attach the lesson to.
card_by() { # card_by COLOUR FACE NAME HEADING LINE...
  [ "$FAST" = 1 ] && return 0
  local color="$1" face="$2" name="$3" head="$4"; shift 4
  printf '\n  %b%s %s%b %b. %s%b\n' "$color" "$face" "$name" "$C_OFF" "$C_B" "$head" "$C_OFF"
  _card_body "$@"
}

madina_card() { card_by "$C_MADINA" '(^_^)' "Madina's notes" "$@"; }

_card_body() {
  local l
  for l in "$@"; do
    printf '  %b|%b %s\n' "$C_DIM" "$C_OFF" "$l"
    _nap 0.12
  done
  printf '\n'
}

# The room shouts an answer. The driver reads nothing -- it is pure paper -- but
# the room has now committed to a guess and will stay for the reveal.
vote() { # vote QUESTION OPTION...
  [ "$FAST" = 1 ] && return 0
  local q="$1"; shift
  local l i=1 v
  printf '\n%b' "$C_WARN"; _rule '-'
  _fit 2 "EVERYONE VOTE: $q" | while IFS= read -r l; do printf '  %s\n' "$l"; done
  _rule '-'; printf '%b' "$C_OFF"
  for v in "$@"; do
    local head; head="  ${C_B}${i}${C_OFF} . "
    _fit 6 "$v" | while IFS= read -r l; do printf '%s%s\n' "$head" "$l"; head='      '; done
    i=$((i + 1))
  done
  printf '\n'
}

reveal() { # reveal TEXT
  [ "$FAST" = 1 ] && return 0
  local l
  printf '\n%b' "$C_OK"; _rule '-'
  _fit 2 "THE ANSWER: $*" | while IFS= read -r l; do printf '  %s\n' "$l"; done
  _rule '-'; printf '%b\n' "$C_OFF"
}

# ── titles ───────────────────────────────────────────────────────────────────
_hero() { # _hero COLOUR FACE NAME ROLE
  printf '\n  %b%s %s%b %b. %s%b\n' "$1" "$2" "$3" "$C_OFF" "$C_DIM" "$4" "$C_OFF"
}

b_0() {
  [ "$FAST" = 1 ] && return 0
  ANIM=0; [ -t 1 ] && [ -t 0 ] && ANIM=1
  clear

  printf '\n'
  _dots 'reaching the cluster'
  _dots 'waking the database'
  _dots 'calling the developer'
  _dots 'calling the DevOps'
  _dots 'hiring an intern'
  _nap 0.4

  printf '\n%b' "$C_HEAD"; _rule '='
  _type "$C_HEAD" 2 'THE PROBE THAT KILLED ITSELF'
  printf '%b' "$C_HEAD"; _rule '='; printf '%b\n' "$C_OFF"
  _type "$C_DIM" 2 'A real cluster, a real database, real failures.'
  _type "$C_DIM" 2 'Nothing is recorded -- including the parts that go wrong.'
  _beat_pause

  printf '\n  %bON CALL%b\n' "$C_B" "$C_OFF"

  _hero "$C_TIMUR" '(o_o)' 'Timur' 'backend'
  _type "$C_SAY" 8 '"I wrote the service. It takes 10 seconds to start:'
  _type "$C_SAY" 8 'warms a cache, opens a pool. The probe I copied from a blog post.'
  _type "$C_SAY" 8 'It is green, so it is correct."'
  _beat_pause

  _hero "$C_RUSLAN" '(-_-)' 'Ruslan' 'DevOps'
  _type "$C_SAY" 8 '"Any production problem is a number in a YAML file.'
  _type "$C_SAY" 8 'The method works. It has never failed me before today."'
  _beat_pause

  _hero "$C_MADINA" '(^_^)' 'Madina' 'intern'
  _type "$C_SAY" 8 '"I read the documentation."'
  _type "$C_SAY" 8 'Nobody asks her opinion for a while.'
  _beat_pause

  _hero "$C_KUBELET" '[o_o]' 'kubelet' 'the executioner'
  _type "$C_SAY" 8 '"I do not read your code. I read your manifest,'
  _type "$C_SAY" 8 'and then I pull the trigger."'
  _beat_pause

  _hero "$C_PG" '(~_~)' 'Postgres' 'the database'
  _type "$C_SAY" 8 '"Two vCPU, 54 connections you may have,'
  _type "$C_SAY" 8 'and a great deal of patience."'
  _beat_pause

  _hero "$C_KEDA" '[>_<]' 'KEDA' 'the pod autoscaler'
  _type "$C_SAY" 8 '"The queue is deep, so I will add workers."'
  _type "$C_SAY" 8 'It has no other ideas.'
  _beat_pause

  _hero "$C_KARPENTER" '[$_$]' 'Karpenter' 'the node autoscaler'
  _type "$C_SAY" 8 '"Pods are Pending, so I will buy machines."'
  _type "$C_SAY" 8 'This one has a credit card.'
  _beat_pause

  printf '\n'
  _type "$C_DIM" 2 'Any resemblance to your team is coincidental. Probably.'
  printf '\n'

  # The only theory that has to come before the first failure: who is asking,
  # and what the three answers do. Everything else is taught inside the waits,
  # at the moment the cluster is about to demonstrate it -- see `teach` in
  # lib/demo.sh. Six minutes of slides up front became this one card.
  ask 'click for the one thing you need before incident 1' || true
  card 'WHAT THIS TALK IS ABOUT' \
    'Every container you run has something asking it questions.' \
    'Not a load balancer, not a human: kubelet, every few seconds,' \
    'forever, using numbers out of your manifest.' \
    '' \
    "$(_col 12 'startup')has it finished booting?" \
    "$(_col 12 'liveness')is it alive?        a wrong answer restarts it" \
    "$(_col 12 'readiness')can it serve?       a wrong answer unplugs it" \
    '' \
    'Of everything that can take a container down -- a crash, an OOM,' \
    'an eviction, a rollout -- a probe is the only one that does it' \
    'while the process is working perfectly well.'

  bigsay "Two incidents. Both times the service was killed by a check, not by traffic."
}

# ── the end ──────────────────────────────────────────────────────────────────
# The postmortem this would have got, had anyone written one.
DEMO_URL="${DEMO_URL:-https://github.com/DovnarAlexander/aws-community-central-asia-2026}"

# What this run actually bought. The card used to say eighteen EC2 instances,
# which no run of this show has ever produced -- twenty-four workers at 250m is
# six cores, so Karpenter buys a handful and the counter on the right says so
# all the way through. A talk that opens with "a real cluster, real failures,
# nothing is recorded" cannot close on a number that counter never reached.
#
# mark_nodes wrote the real one during incident 2. With nothing to read -- the
# show started midway, or incident 2 was skipped -- the line drops the count
# rather than inventing one.
_nodes_bought() {
  local n=''
  [ -f "$DEMO_STATE/incident2-before.nodes" ] && n=$(cat "$DEMO_STATE/incident2-before.nodes" 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*) printf 'EC2 machines, bought while nothing was being served' ;;
    1)           printf 'one EC2 machine, bought while nothing was being served' ;;
    *)           printf '%s EC2 machines, bought while nothing was being served' "$n" ;;
  esac
}

finale() {
  card 'POSTMORTEM' \
    "$(_col 15 'Incident')service down for 40 minutes" \
    "$(_col 15 'Response')added replicas" \
    "$(_col 15 'What helped')nothing" \
    "$(_col 15 'Also')$(_nodes_bought)" \
    "$(_col 15 'Root cause')a probe asking about somebody else's health" \
    "$(_col 15 'At fault')Timur 0 . Ruslan 0 . kubelet 0" \
    "$(_col 15 'Action item')Madina reviews the probes now"

  ruslan "\"Nobody at fault\" is not a real postmortem."
  madina "It is. The line that caused it was not written by anyone. It was copied."
  # His method is the through-line of both incidents and it has never once lost
  # out loud. The titles gave him "any production problem is a number in a YAML
  # file"; this is where he finds out.
  ruslan "Both times I reached for the number."
  madina "It was never the number."
  madina "I wrote all of this down, by the way."

  bigsay "Probes are the only code that can kill a healthy service, and now bill you for it."

  # The last reason to leave the terminal was the closing checklist, and the
  # room does not read a checklist -- it photographs one. So the ending is the
  # thing worth photographing: a link, which carries the checklist and the code
  # that produced everything they just watched. `task qr` renders it; without
  # that file this still prints the URL, which is the part that matters.
  card 'TAKE THIS WITH YOU' \
    'Everything you just saw, including the manifests with the numbers:' \
    '' \
    "  $DEMO_URL" \
    '' \
    'The checklist is in docs/CHECKLIST.md. The probes are in k8s/.' \
    'The failures are reproducible: task bootstrap, then ./demo.'

  [ -f "$DEMO_ROOT/docs/qr.txt" ] && sed 's/^/  /' "$DEMO_ROOT/docs/qr.txt"
  return 0
}

step "0" "Who is on call" b_0
