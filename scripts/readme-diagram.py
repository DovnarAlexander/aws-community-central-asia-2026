#!/usr/bin/env python3
"""Put a background behind a diagram so it survives a dark README.

    scripts/readme-diagram.py slides/public/diagrams/loop.svg docs/img/loop.svg

The deck's diagrams are exported with no background on purpose: a slide paints
its own, and a white box behind a drawing would show wherever the slide is
tinted. GitHub has no such slide. It renders the file against whatever theme the
reader chose, so the two captions that sit outside the boxes -- drawn in #1e1e2f
because they are read on paper-coloured slides -- disappear entirely for anybody
reading in dark mode.

So the README gets its own copy with one rectangle added underneath. Same
drawing, no second source to keep in step.
"""

import pathlib
import re
import sys

BG = '#ffffff'


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    svg = src.read_text()
    m = re.search(r'viewBox="([\d.\- ]+)"', svg)
    if not m:
        print(f"  {src} has no viewBox to size a background against", file=sys.stderr)
        return 1
    x, y, w, h = (float(v) for v in m.group(1).split())
    rect = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{BG}"/>')
    # After the defs, so it sits under the drawing rather than over it.
    out = re.sub(r'(</defs>)', r'\1' + rect, svg, count=1)
    if out == svg:                      # no defs: straight after the opening tag
        out = re.sub(r'(<svg[^>]*>)', r'\1' + rect, svg, count=1)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(out)
    print(f"  {src.name} -> {dst} ({int(w)}x{int(h)}, {BG} behind it)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
