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

# The dead-air cap the deck plays with. Both the cut times and the player have
# to use the same number or the cuts point at the wrong minute -- see read_cast
# -- so it is written into the manifest and Cast.vue takes it from there rather
# than carrying its own copy.
IDLE_TIME_LIMIT = 2.0


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


def find_steps(events):
    """Every step header in the stream, as (time, id, title), first hit wins."""
    # One string of everything printed, with a note of which event each byte
    # came from, so a match can be turned back into a timestamp.
    chunks, owner = [], []
    for i, (t, kind, data) in enumerate(events):
        if kind != "o":
            continue
        chunks.append(data)
        owner.append((len(data), i, t))

    whole = "".join(chunks)
    stripped, index = strip_ansi_with_map(whole)

    # offset in `whole` -> the event that produced it
    bounds, running = [], 0
    for size, i, t in owner:
        running += size
        bounds.append((running, t))

    def time_at(offset):
        for end, t in bounds:
            if offset < end:
                return t
        return bounds[-1][1] if bounds else 0.0

    found, seen = [], set()
    for m in HEADER.finditer(stripped):
        step, title = m.group(1), m.group(2).strip()
        if step in seen:          # tmux repaints; the first one is the real cut
            continue
        seen.add(step)
        found.append((time_at(index[m.start()]), step, title))
    return found


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1])
    outdir = pathlib.Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    header, events, _ = read_cast(src)
    steps = find_steps(events)
    # Step 0 on its own is the title card and nothing after it: the stage opened,
    # the cast was introduced, and whoever was recording stopped before clicking
    # into 1.1. That is a recording of ./stage, just not of the show.
    if not [st for st in steps if st[1] != "0"]:
        # Two very different failures produce no cuts, and "is this a recording
        # of ./stage?" is the wrong question for the common one: a recording
        # that stops on the title card is a recording of the stage, it just
        # never left the intro. Telling those apart is one look for step 0's
        # own header, which the driver prints before anything is clicked.
        intro = strip_ansi_with_map("".join(
            d for _, kind, d in events if kind == "o"))[0]
        if INTRO.search(intro):
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
    cuts = []
    for i, (start, step, title) in enumerate(marks):
        # The last step has no end: it runs to wherever the recording stops, and
        # a number here would only be the same thing said less honestly.
        end = marks[i + 1][0] if i + 1 < len(marks) else None
        cuts.append({
            "step": step,
            "title": title,
            "from": round(start, 3),
            "to": None if end is None else round(end, 3),
        })

    manifest = outdir / f"{src.stem}.cuts.json"
    manifest.write_text(json.dumps({
        "source": src.name,
        "idle_time_limit": IDLE_TIME_LIMIT,
        "duration": round(total, 3),
        "cuts": cuts,
    }, indent=2) + "\n")

    print(f"  {src.name} -> {len(cuts)} steps -> {manifest}\n")
    for c in cuts:
        length = (c["to"] if c["to"] is not None else total) - c["from"]
        print(f"  {c['step']:5} {int(length // 60)}:{int(length % 60):02d}  {c['title']}")

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
