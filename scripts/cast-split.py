#!/usr/bin/env python3
"""Find the step boundaries in one recording of the show.

Record once, split automatically. The driver prints a header for every step --

    ================================================================================
      1.3 . Production config, and real traffic
    ================================================================================

-- so the boundaries are already in the recording and nobody has to read
timestamps off a scrubber. A step that gets renumbered or retitled moves its cut
with it, which hand-written timecodes would not.

    scripts/cast-split.py slides/public/casts/full.cast slides/public/casts

Writes <name>.cuts.json next to the recording and prints a Slidev fragment with
one slide per step.

Boundaries, not files. Cutting each step into a cast of its own is the obvious
thing to do and it is wrong: an asciicast is a stream of terminal writes, not a
sequence of frames, so a file that starts mid-stream starts on a blank terminal.
Everything tmux had drawn before the cut -- the pane borders, k9s, the load
panel -- is simply missing from the segment until something happens to repaint
it, which for a quiet pane is never. The deck plays ranges of the whole
recording instead: the player rebuilds the screen by replaying the history when
it seeks, in single-digit milliseconds, and the step opens with the whole stage
on it.
"""

import bisect
import json
import pathlib
import re
import sys

# The header line, once the colour codes are out of the way. Two leading spaces
# and " . " between number and title are the driver's format, not a guess.
#
# "0" is spelled out rather than allowed as a general bare number, because the
# driver prints the vote options in the same shape -- `  1 . Timur -- copied a
# probe out of an article` -- and a rule loose enough to catch step 0 catches
# those three as steps too. Zero is the only step without a minor number: it is
# the title card and the introductions, who is on call. It used to be excluded
# here and cut from 0.0 instead, which opened its slide on tmux building the
# stage rather than on the cast being introduced.
HEADER = re.compile(r"\n {2}(\d+\.\d+|0) \. ([^\r\n]{1,70})")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[=>]")

# Step 0's header, printed before anything is clicked. HEADER matches it too;
# this exists to tell "the show was never started" from "this is not a recording
# of the stage at all", which are the same empty result and different problems.
INTRO = re.compile(r"\n {2}0 \. ")

# The countdown a wait draws, in both shapes it has had: four dim characters
# at the end of the counters, and a number in front of a bar that drains.
COUNTDOWN = re.compile(r"\. (\d+)s \. \[->\] click to move on"
                       r"|\n\s+(\d+)s\s+[\u2588\u2591]")

# The dead-air cap the deck plays with. Both the cut times and the player have
# to use the same number or the cuts point at the wrong minute -- see read_cast
# -- so it is written into the manifest and Cast.vue takes it from there rather
# than carrying its own copy.
IDLE_TIME_LIMIT = 2.0

# Where a step is cut into more than one slide. The file says what a beat is and
# why it is written as a marker rather than a time; this only has to find it.
# Missing is not an error -- a deck with no beats file is the one-slide-per-step
# deck this script wrote before.
BEATS = pathlib.Path(__file__).resolve().parent / "pptx" / "beats.json"

# The driver's click prompt, with its label. `ask` prints one of these and then
# blocks on a keypress, so the frame it draws is the frame the recording stands
# on until somebody presses the clicker -- which makes it the one place a cut
# costs nothing to watch. The watch panel's own "[->] skips" tail is not a
# prompt and is deliberately not matched: it is redrawn every second while the
# show carries on underneath it.
PROMPT = re.compile(r"\[->\] (click [^\r\n.%]{0,60})")


def is_dark(bg):
    """True for a terminal background the deck should frame in dark chrome.

    Missing is dark: a cast with no theme in its header plays in the player's
    default, which is dark. The threshold is plain relative luminance -- this
    only has to tell #feffff from #1e1e2f, not grade a palette.
    """
    if not isinstance(bg, str) or not bg.startswith("#") or len(bg) != 7:
        return True
    try:
        r, g, b = (int(bg[i:i + 2], 16) for i in (1, 3, 5))
    except ValueError:
        return True
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128


def read_cast(path):
    """Header plus events at the times the player will put them on screen.

    asciinema 3 records v3, where each event carries the gap since the previous
    one rather than a timestamp. Everything below wants absolute times, so the
    difference is absorbed here and nowhere else.

    Player time, not recording time. The deck plays with idleTimeLimit, which
    shortens every gap longer than the limit -- this show waits on nodes being
    bought and rollouts settling, and capping that takes nineteen minutes of
    recording down to fourteen of watching. The player's clock therefore is not
    the recording's clock, and a cut measured in recording seconds lands minutes
    away from its step. Gaps are capped here for the same reason and by the same
    rule, so the numbers written out are the ones a seek will honour. The limit
    travels in the manifest, so the deck cannot quietly play with a different
    one.
    """
    lines = path.read_text().splitlines()
    header = json.loads(lines[0])
    version = header.get("version", 2)
    if version not in (2, 3):
        raise SystemExit(f"  asciicast v{version} is not a format this knows how to cut")

    events, clock, prev = [], 0.0, 0.0
    for ln in lines[1:]:
        if not ln.strip() or not ln.startswith("["):
            continue
        t, kind, data = json.loads(ln)
        gap = t if version == 3 else (t - prev)
        prev = t
        clock += min(gap, IDLE_TIME_LIMIT)
        events.append((round(clock, 6), kind, data))
    return header, events, version


def strip_ansi_with_map(text):
    """Return text without escape sequences, plus stripped->original offsets."""
    out, index, pos = [], [], 0
    for m in ANSI.finditer(text):
        for i in range(pos, m.start()):
            out.append(text[i])
            index.append(i)
        pos = m.end()
    for i in range(pos, len(text)):
        out.append(text[i])
        index.append(i)
    return "".join(out), index


class Stream:
    """Everything the recording printed, as one string you can ask times of.

    A match anywhere in it can be turned back into the moment it appeared on
    screen. Built once and handed to everything that looks for something --
    step headers, click prompts, a pod going CrashLoopBackOff -- because
    rebuilding it is three megabytes of string work each time.
    """

    def __init__(self, events):
        chunks, bounds, running = [], [], 0
        self.times = []
        for t, kind, data in events:
            if kind != "o":
                continue
            chunks.append(data)
            running += len(data)
            bounds.append(running)
            self.times.append(t)
        self.text, self.index = strip_ansi_with_map("".join(chunks))
        self._bounds = bounds

    def time_at(self, offset):
        """When the byte at this offset in the stripped text was printed."""
        if not self._bounds:
            return 0.0
        i = bisect.bisect_right(self._bounds, offset)
        return self.times[min(i, len(self.times) - 1)]

    def at(self, match_start):
        """When a match in the stripped text appeared."""
        return self.time_at(self.index[match_start])

    def previous_write(self, when):
        """The last moment anything was drawn before `when`.

        What a cut is backed up onto, so the slide that carries on opens on the
        frame the slide before it ended on rather than on the change itself.
        """
        i = bisect.bisect_left(self.times, when)
        return self.times[i - 1] if i else 0.0


def find_steps(stream):
    """Every step header in the stream, as (time, id, title), first hit wins."""
    found, seen = [], set()
    for m in HEADER.finditer(stream.text):
        step, title = m.group(1), m.group(2).strip()
        if step in seen:          # tmux repaints; the first one is the real cut
            continue
        seen.add(step)
        found.append((stream.at(m.start()), step, title))
    return found


# How far a beat is allowed to be backed up onto the frame before it, so the
# slide that carries on opens on a picture identical to the one the slide before
# it ended on. Anything longer and the new slide sits frozen waiting for a
# change the room has already been shown.
LEAD = 1.0


def clean_label(raw):
    """A prompt label with whatever tmux repainted next to it taken off.

    The prompt is one line inside a pane, and the same write often carries the
    pane borders and part of the next pane, so the captured label comes out as
    "click when you are done talking\u2500\u2500\u252c\u2500\u2500\u2502\u2502" or with the next pane's
    columns stuck to it. Whitespace is squeezed here and the label is matched as
    a prefix, which is the only rule that survives a full-screen repaint.
    """
    return re.sub(r"\s+", " ", raw).strip()


def resolve_gate(stream, label, lo, hi, nth=1):
    """When a click prompt was ANSWERED, not when it went up.

    `ask` prints its prompt once and blocks, but the countdown prompts redraw
    themselves every second, so the prompt is on screen for a run of events and
    what matters is the end of the run: the next thing printed after it is the
    click landing. Cutting on the prompt's first appearance instead would put
    the cut before the pause rather than after it, and the slide would open on
    a wait the room has already sat through.
    """
    runs = [(stream.at(m.start()), clean_label(m.group(1)))
            for m in PROMPT.finditer(stream.text)]
    runs = [(t, g) for t, g in runs if lo <= t < hi]
    seen, i = 0, 0
    while i < len(runs):
        t, g = runs[i]
        if not g.startswith(label):
            i += 1
            continue
        j = i
        while (j + 1 < len(runs) and runs[j + 1][1].startswith(label)
               and runs[j + 1][0] - runs[j][0] <= 3.0):
            j += 1
        seen += 1
        if seen == nth:
            # The first write after the prompt stopped being redrawn.
            k = bisect.bisect_right(stream.times, runs[j][0])
            return stream.times[k] if k < len(stream.times) else None
        i = j + 1
    return None


def resolve_text(stream, pattern, lo, hi, nth=1):
    """When something first appeared on screen inside a step."""
    hits = 0
    for m in re.finditer(pattern, stream.text):
        t = stream.at(m.start())
        if not (lo <= t < hi):
            continue
        hits += 1
        if hits == nth:
            return t
    return None


def find_beats(stream, step, lo, hi, spec):
    """The extra cuts inside one step, as (cut time, title).

    A beat that cannot be found is reported and skipped rather than guessed at.
    Skipping is the honest failure here: the step still plays, as one slide,
    the way it did before the beat was written down.
    """
    out, complaints = [], []
    for entry in spec:
        at = entry["at"]
        kind, _, arg = at.partition(":")
        if kind == "gate":
            t = resolve_gate(stream, arg, lo, hi, entry.get("nth", 1))
        elif kind == "text":
            t = resolve_text(stream, arg, lo, hi, entry.get("nth", 1))
        else:
            complaints.append(f"    {step}: {at!r} is not a gate: or a text: marker")
            continue
        if t is None:
            complaints.append(f"    {step}: nothing in the step matches {at!r}")
            continue
        out.append((t, entry.get("title", "")))
    out.sort()
    return out, complaints



def cut_short(path):
    """Waits that ended before their countdown did, as lines to print.

    A wait is a run of falling numbers. Whether it was clicked through is a
    question about the clock, not about the frames: the panel redraws once per
    loop, and a loop that gets quick answers out of kubectl redraws several
    times inside one second, so counting repeated frames calls an ordinary wait
    a broken one. What a clicked-through wait actually looks like is a
    countdown that started at eighty and stopped three seconds later.

    Measured on the recording's own clock rather than the player's: the cap that
    makes the deck watchable also shortens exactly the gaps being measured here.
    """
    raw, chunks = 0.0, []
    for ln in path.read_text().splitlines()[1:]:
        if not ln.startswith("["):
            continue
        t, kind, data = json.loads(ln)
        raw += t
        if kind == "o":
            chunks.append((raw, data))

    frames, buf = [], ""
    for t, data in chunks:
        buf = (buf + ANSI.sub("", data))[-400:]
        for m in COUNTDOWN.finditer(buf):
            frames.append((t, int(m.group(1) or m.group(2))))
        if COUNTDOWN.search(buf):
            buf = buf[-40:]

    waits, cur = [], None
    for t, v in frames:
        if cur and v < cur["last"]:
            cur["last"], cur["end"] = v, t
        elif not cur or v != cur["last"]:
            if cur:
                waits.append(cur)
            cur = {"first": v, "last": v, "start": t, "end": t}
    if cur:
        waits.append(cur)

    # Anything under ten seconds is a pause between beats, not a wait on the
    # cluster, and is not what this is looking for.
    short = [w for w in waits
             if w["first"] >= 10 and (w["end"] - w["start"]) < w["first"] * 0.6]
    if not short:
        return []
    out = ["", f"  \033[1;31m!\033[0m {len(short)} of the waits ended early:"]
    for w in short:
        out.append(f"    {w['first']}s countdown, over in "
                   f"{round(w['end'] - w['start'])}s")
    out += ["",
            "    A wait that is clicked through still draws its panel, so the recording",
            "    looks complete while the cluster never got far enough to show anything.",
            "    Let each one run its bar out, and do not press ahead on the prompt",
            "    before it."]
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1])
    outdir = pathlib.Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    header, events, _ = read_cast(src)
    stream = Stream(events)
    steps = find_steps(stream)
    # Step 0 on its own is the title card and nothing after it: the stage opened,
    # the cast was introduced, and whoever was recording stopped before clicking
    # into 1.1. That is a recording of ./stage, just not of the show.
    if not [st for st in steps if st[1] != "0"]:
        # Two very different failures produce no cuts, and "is this a recording
        # of ./stage?" is the wrong question for the common one: a recording
        # that stops on the title card is a recording of the stage, it just
        # never left the intro. Telling those apart is one look for step 0's
        # own header, which the driver prints before anything is clicked.
        if INTRO.search(stream.text):
            print("  the recording stops at the title card -- step 1.1 was never started",
                  file=sys.stderr)
            print("  run the show through to the end, then quit tmux to stop recording",
                  file=sys.stderr)
        else:
            print("  no step headers found -- is this a recording of ./stage?",
                  file=sys.stderr)
        return 1

    # The driver prints step 0's header a few seconds in, once the stage has
    # been built, so the cut lands on the introductions rather than on tmux
    # drawing panes. Only a recording that somehow has no header for it falls
    # back to cutting from zero.
    marks = steps if steps[0][1] == "0" else [(0.0, "0", "Who is on call")] + steps
    total = events[-1][0] if events else 0.0

    beats_spec = json.loads(BEATS.read_text()) if BEATS.exists() else {}
    cuts, complaints = [], []
    for i, (start, step, title) in enumerate(marks):
        # The last step has no end: it runs to wherever the recording stops, and
        # a number here would only be the same thing said less honestly.
        end = marks[i + 1][0] if i + 1 < len(marks) else None
        stop = total if end is None else end

        inner, gripes = find_beats(stream, step, start, stop,
                                   beats_spec.get(step, []))
        complaints += gripes

        # Each cut is backed up onto the frame before it, so the slide that
        # carries on opens on a picture identical to the one the slide before it
        # ended on and the join is invisible. There is nothing drawn in that
        # window by construction -- it ends at the previous write -- so nothing
        # is played twice.
        # opens[k] is where slide k starts playing, closes[k] where it stops.
        # They overlap by `lead`: the film before a cut runs up TO the change,
        # the film after it opens on the frame BEFORE the change. Both show the
        # same still across the join, and the change itself happens under the
        # click.
        opens, closes, titles = [start], [], [title]
        for when, name in inner:
            lead = min(LEAD, when - stream.previous_write(when))
            begin = round(when - lead, 3)
            if begin - opens[-1] < 2.0:       # too close to the cut before it
                continue
            closes.append(round(when, 3))
            opens.append(begin)
            titles.append(name or title)
        closes.append(end)

        for k, begin in enumerate(opens):
            last = k + 1 == len(opens)
            cuts.append({
                # A step with beats numbers them; a step without one keeps the
                # id the driver printed, so nothing downstream has to know
                # which kind it is looking at.
                "step": step if len(opens) == 1 else f"{step}.{k + 1}",
                "parent": step,
                "beat": k + 1,
                "beats": len(opens),
                # True when this slide is the middle of a film rather than the
                # start of one: what tells film.mjs to open it on its own first
                # frame instead of a frame from the middle.
                "continues": k > 0,
                "title": titles[k],
                # The parent step's own span, so a slide that is one beat of a
                # film can still draw a progress bar for the whole step rather
                # than refilling one of its own every time the slide changes.
                "step_from": round(start, 3),
                "step_to": None if end is None else round(end, 3),
                "from": round(begin, 3),
                "to": (None if (last and closes[k] is None)
                       else round(closes[k], 3)),
            })

    manifest = outdir / f"{src.stem}.cuts.json"
    manifest.write_text(json.dumps({
        "source": src.name,
        "idle_time_limit": IDLE_TIME_LIMIT,
        "duration": round(total, 3),
        "cuts": cuts,
    }, indent=2) + "\n")

    slides = len(cuts)
    print(f"  {src.name} -> {len(marks)} steps, {slides} slides -> {manifest}\n")
    for c in cuts:
        length = (c["to"] if c["to"] is not None else total) - c["from"]
        print(f"  {c['step']:7} {int(length // 60)}:{int(length % 60):02d}  {c['title']}")

    # A beat that could not be found is the one failure here that is silent
    # otherwise: the step still cuts, as one slide, and looks fine in the
    # manifest. Said last, where the eye already is.
    if complaints:
        print(f"\n  \033[1;31m!\033[0m {len(complaints)} beats in {BEATS.name} "
              f"did not match this recording and were skipped:", file=sys.stderr)
        for line in complaints:
            print(line, file=sys.stderr)

    # Said after the lengths rather than before them, because the lengths are
    # the evidence: a fast-forwarded recording looks fine until you notice which
    # steps are seconds long.
    for line in cut_short(src):
        print(line, file=sys.stderr)


    # Per-step casts from the days this script wrote files. Nothing references
    # them once the slides ask for steps, and a stale 1.1.cast sitting next to a
    # live manifest is exactly the sort of thing that gets debugged for an hour.
    stale = sorted(p for p in outdir.glob("*.cast")
                   if p != src and re.fullmatch(r"\d+(\.\d+)?", p.stem))
    if stale:
        print("\n  these are left over from the old per-step split and are no longer read:")
        print("    " + "  ".join(p.name for p in stale))

    # The deck has two shapes for a cast, and which one fits is decided by the
    # recording, not by taste: 120 columns go in a window on a slide, a
    # screen-sized recording (GEOM=native) has too many to survive being
    # squeezed into one and gets the whole canvas instead.
    term = header.get("term") or {}
    cols = term.get("cols") or header.get("width") or 120
    full_bleed = cols > 130
    # The window frame around a narrow cast has a light and a dark version, and
    # which one is right is decided by the terminal that was recorded, not by
    # the deck: a dark frame around a recording from a light terminal reads as a
    # mistake. asciinema writes the terminal's own background into the header.
    dark = " dark" if is_dark((term.get("theme") or {}).get("bg")) else ""
    if full_bleed:
        print(f"\n  recorded at {cols} columns -- wider than a window on a slide,")
        print("  so these come out full-bleed (see nq-cast-full in slides/style.css)")

    print("\n  --- slides, ready to paste ---\n")
    for c in cuts:
        step, title = c["step"], c["title"]
        if c.get("beats", 1) > 1:
            title = f"{c['parent']} \u00b7 {c['beat']}/{c['beats']} \u00b7 {title}"
        if full_bleed:
            print(f"""---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/{src.name}" step="{step}" fit="both" />
  </div>
</div>

<!-- {step} · {title} -->
""")
        else:
            print(f"""---
layout: default
---

# {step} · {title}

<WindowMockup title="stage · {step}"{dark}>
  <Cast src="/casts/{src.name}" step="{step}" />
</WindowMockup>
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
