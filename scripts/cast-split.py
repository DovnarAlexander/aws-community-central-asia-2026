#!/usr/bin/env python3
"""Cut one recording of the show into one cast per step.

Record once, split automatically. The driver prints a header for every step --

    ================================================================================
      1.3 . Production config, and real traffic
    ================================================================================

-- so the boundaries are already in the recording and nobody has to read
timestamps off a scrubber. A step that gets renumbered or retitled moves its cut
with it, which hand-written timecodes would not.

    scripts/cast-split.py slides/public/casts/full.cast slides/public/casts

Writes <id>.cast per step, rebased so each one starts at zero, and prints a
Slidev fragment with one slide per segment.
"""

import json
import pathlib
import re
import sys

# The header line, once the colour codes are out of the way. Two leading spaces
# and " . " between number and title are the driver's format, not a guess.
HEADER = re.compile(r"\n {2}(\d+\.\d+) \. ([^\r\n]{1,70})")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[=>]")

# Step 0's header, printed before anything is clicked. Same shape as the others
# but numbered "0" rather than "N.N", which is why HEADER does not match it and
# why it is the thing to look for when nothing else is there.
INTRO = re.compile(r"\n {2}0 \. ")


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
    """Header plus events at absolute times, for asciicast v2 or v3.

    asciinema 3 records v3, where each event carries the gap since the previous
    one rather than a timestamp. Everything below wants absolute times, so the
    difference is absorbed here and nowhere else.
    """
    lines = path.read_text().splitlines()
    header = json.loads(lines[0])
    version = header.get("version", 2)
    if version not in (2, 3):
        raise SystemExit(f"  asciicast v{version} is not a format this knows how to cut")

    events, clock = [], 0.0
    for ln in lines[1:]:
        if not ln.strip() or not ln.startswith("["):
            continue
        t, kind, data = json.loads(ln)
        if version == 3:
            clock += t
            t = clock
        events.append((round(t, 6), kind, data))
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


def write_segment(header, events, start, end, path, title, version):
    """One segment, rebased to zero, in the same asciicast version it came from."""
    out = dict(header)
    out["title"] = title
    # A timestamp copied from the full recording would date every segment to the
    # moment the whole run started, which is wrong for all but the first.
    out.pop("timestamp", None)
    with path.open("w") as f:
        f.write(json.dumps(out) + "\n")
        prev = start
        for t, kind, data in events:
            if t < start or (end is not None and t >= end):
                continue
            # v3 wants the gap since the previous kept event -- measured from the
            # cut, so a segment never opens with the pause that preceded it.
            stamp = (t - prev) if version == 3 else (t - start)
            prev = t
            f.write(json.dumps([round(stamp, 6), kind, data]) + "\n")


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1])
    outdir = pathlib.Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    header, events, version = read_cast(src)
    steps = find_steps(events)
    if not steps:
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

    # Everything before the first header is the titles: who is on call.
    cuts = [(0.0, "0", "Who is on call")] + steps
    written = []
    for i, (start, step, title) in enumerate(cuts):
        end = cuts[i + 1][0] if i + 1 < len(cuts) else None
        path = outdir / f"{step}.cast"
        write_segment(header, events, start, end, path, f"{step} . {title}", version)
        length = (end - start) if end else (events[-1][0] - start if events else 0)
        written.append((step, title, length, path))

    print(f"  {src.name} -> {len(written)} segments\n")
    for step, title, length, path in written:
        print(f"  {step:5} {int(length // 60)}:{int(length % 60):02d}  {title}")

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
    for step, title, _, _ in written:
        if step == "0":
            continue
        if full_bleed:
            print(f"""---
layout: default
class: nq-cast-slide nq-cast-full
---

<div class="nq-fig">
  <div class="nq-cast-frame">
    <Cast src="/casts/{step}.cast" fit="both" />
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
  <Cast src="/casts/{step}.cast" />
</WindowMockup>
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
