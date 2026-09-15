#!/usr/bin/env python3
"""Check a recording for escape sequences the deck's player cannot render.

    scripts/cast-lint.py slides/public/casts/full.cast

Exits non-zero if the cast will play back wrong, and says what and why.

The one that matters is DECSLRM -- left and right margins. tmux draws a
side-by-side layout by fencing the cursor into one pane's column band and
writing inside it:

    \\033[?69h          allow margins
    \\033[105;167s      fence columns 105..167 -- the right-hand column
    ...the pods, the stat panel, the load panel...
    \\033[1;103s        fence columns 1..103 -- the driver

asciinema-player's terminal does not implement margins. It takes those writes
at full width, so the right-hand panes land across the whole screen, wrap where
they should not, and never get cleared -- the stat panel ends up drawn four
times down the page with fragments of k9s between the copies. The recording is
not damaged; it is asking for something the player cannot do. Nothing in the
deck can fix it afterwards, which is why this runs at record time: the cure is
to stop tmux using margins while the cast is being made, and the only cheap
moment to find out it did not work is right after recording.

This is deliberately not a general asciicast validator. It looks for the
sequences that have actually bitten this deck, and it would rather say nothing
than say something vague.
"""

import json
import pathlib
import re
import sys

# CSI Pl ; Pr s -- with parameters this is DECSLRM. Bare CSI s is a cursor
# save, which is ordinary and harmless, so the parameters are what is matched.
DECSLRM = re.compile(r"\x1b\[(\d+);(\d+)s")
# CSI ? 69 h/l -- the mode that makes DECSLRM mean anything at all.
DECLRMM = re.compile(r"\x1b\[\?69[hl]")


def output(path):
    """Everything the recording wrote to the terminal, as one string."""
    lines = path.read_text().splitlines()
    if not lines:
        raise SystemExit(f"  {path} is empty")
    chunks = []
    for ln in lines[1:]:
        if not ln.startswith("["):
            continue
        _, kind, data = json.loads(ln)
        if kind == "o":
            chunks.append(data)
    return "".join(chunks)


def bands(text):
    """The column bands the recording fenced itself into, most used first."""
    seen = {}
    for m in DECSLRM.finditer(text):
        key = (int(m.group(1)), int(m.group(2)))
        seen[key] = seen.get(key, 0) + 1
    return sorted(seen.items(), key=lambda kv: -kv[1])


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print(f"  no recording at {path}", file=sys.stderr)
        return 2

    text = output(path)
    margins = len(DECSLRM.findall(text))
    if not margins:
        print(f"  \033[1;32m✓\033[0m {path.name} plays as recorded")
        return 0

    print(f"  \033[1;31m✗\033[0m {path.name} uses terminal margins "
          f"({margins} times) and will play back with the panes scrambled",
          file=sys.stderr)
    print(file=sys.stderr)
    print("  tmux fenced the cursor into these column bands:", file=sys.stderr)
    for (left, right), n in bands(text)[:4]:
        print(f"    columns {left:>4}..{right:<4}  {n} times", file=sys.stderr)
    print(file=sys.stderr)
    print("  The player's terminal does not implement margins, so everything", file=sys.stderr)
    print("  written inside a band lands at full width instead: the right-hand", file=sys.stderr)
    print("  panes are drawn across the whole screen and never cleared.", file=sys.stderr)
    print(file=sys.stderr)
    print("  Record again with margins off -- \033[1mtask deck:record\033[0m does that now, and", file=sys.stderr)
    print("  \033[1mtask deck:record:probe\033[0m checks it in ten seconds without running the show.", file=sys.stderr)
    if DECLRMM.search(text):
        print("  (the recording also enables them explicitly, so this is tmux, not a guess)",
              file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
