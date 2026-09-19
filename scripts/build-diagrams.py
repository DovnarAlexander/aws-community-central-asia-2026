#!/usr/bin/env python3
"""
Author the deck's diagrams as Excalidraw scenes.

Why a generator and not four files drawn by hand: the four pictures share a
vocabulary — the same box size, the same brand colours, the same gap between a
box and the arrow that leaves it. Drawn by hand they drift apart the first time
one of them is edited. Here the vocabulary is `box()` and `arrow()`, and a
change to either lands in all four.

Output: slides/diagrams/*.excalidraw.json — the source, openable in Excalidraw
or the Obsidian plugin. `task deck:diagrams` renders each one to an SVG under
slides/public/diagrams/, which is what the slides actually load: the Excalidraw
renderer pulls its module from a CDN at run time, and this deck has to survive
a venue with no network.
"""
import json
import math
import os

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "slides", "diagrams")

# Naviteq palette — the same hexes the theme's tokens carry. Excalidraw stores
# colours per element, so they cannot come from a CSS variable.
INDIGO      = "#3b3dbf"
INDIGO_TINT = "#eef0fb"
ACCENT      = "#f5a623"
ACCENT_TINT = "#fdf1dd"
RED         = "#ef4444"
RED_TINT    = "#fdecec"
GREEN       = "#10b981"
GREEN_TINT  = "#e7f8f2"
CYAN        = "#06b6d4"
CYAN_TINT   = "#e4f8fc"
INK         = "#1e1e2f"
MUTED       = "#6b7280"
BORDER      = "#c7cad8"

_seed = [1000]


def _next():
    _seed[0] += 7
    return _seed[0]


def _base(kind, x, y, w, h, stroke, fill="transparent", **extra):
    el = {
        "id": extra.pop("id"),
        "type": kind,
        "x": x, "y": y, "width": w, "height": h,
        "angle": 0,
        "strokeColor": stroke,
        "backgroundColor": fill,
        "fillStyle": "solid",
        "strokeWidth": extra.pop("strokeWidth", 2),
        "strokeStyle": extra.pop("strokeStyle", "solid"),
        "roughness": 1,
        "opacity": 100,
        "groupIds": [],
        "frameId": None,
        "roundness": extra.pop("roundness", {"type": 3}),
        "seed": _next(),
        "version": 1,
        "versionNonce": _next(),
        "isDeleted": False,
        "boundElements": [],
        "updated": 1,
        "link": None,
        "locked": False,
    }
    el.update(extra)
    return el


def box(id, x, y, w, h, label, stroke=INDIGO, fill=INDIGO_TINT, size=16,
        ink=INK, bold=False, dashed=False, align="center"):
    """A rectangle with its label bound into it.

    The label needs an entry on both sides — `containerId` on the text and a
    matching `boundElements` record on the rectangle. With only one of the two
    the export drops the text and the box comes out blank.
    """
    rect = _base("rectangle", x, y, w, h, stroke, fill, id=id,
                 strokeStyle="dashed" if dashed else "solid")
    lines = label.count("\n") + 1
    th = lines * size * 1.25
    text = _base("text", x + 8, y + (h - th) / 2, w - 16, th, ink, id=f"{id}-t",
                 roundness=None, strokeWidth=1)
    text.update({
        "text": label, "originalText": label,
        "fontSize": size, "fontFamily": 2,
        "textAlign": align, "verticalAlign": "middle",
        "containerId": id, "lineHeight": 1.25, "autoResize": False,
    })
    if bold:
        text["fontFamily"] = 2
    rect["boundElements"] = [{"type": "text", "id": f"{id}-t"}]
    return [rect, text]


def label(id, x, y, text, size=14, colour=MUTED, w=None, align="left"):
    """Free-standing text — a caption, an arrow label, a note."""
    lines = text.count("\n") + 1
    width = w if w is not None else max(len(l) for l in text.split("\n")) * size * 0.56
    el = _base("text", x, y, width, lines * size * 1.25, colour, id=id,
               roundness=None, strokeWidth=1)
    el.update({
        "text": text, "originalText": text,
        "fontSize": size, "fontFamily": 2,
        "textAlign": align, "verticalAlign": "top",
        "containerId": None, "lineHeight": 1.25, "autoResize": True,
    })
    return [el]


def _edge(rect, tx, ty, gap):
    """Where a line from this box's centre towards (tx, ty) leaves the box."""
    cx, cy = rect[0] + rect[2] / 2, rect[1] + rect[3] / 2
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    hw, hh = rect[2] / 2 + gap, rect[3] / 2 + gap
    scale = min(hw / abs(dx) if dx else math.inf, hh / abs(dy) if dy else math.inf)
    return cx + dx * scale, cy + dy * scale


def arrow(id, a, b, colour=INDIGO, dashed=False, gap=6, bend=None, width=2):
    """An arrow from box `a` to box `b`, both given as (x, y, w, h).

    `bend` is one waypoint or a list of them, in scene coordinates, for the
    arrows that have to route around something.

    The endpoints are computed here rather than left to Excalidraw's bindings:
    `exportToSvg` draws the points it is given and never re-solves a binding, so
    a scene that relies on them renders as a pile of arrows at the origin.
    """
    ac = (a[0] + a[2] / 2, a[1] + a[3] / 2)
    bc = (b[0] + b[2] / 2, b[1] + b[3] / 2)
    if bend is None:
        vias = []
    elif isinstance(bend[0], (int, float)):
        vias = [bend]
    else:
        vias = list(bend)
    # Each end leaves its own box heading for the next point along the line —
    # the nearest waypoint if there is one, the other box's centre if there is
    # not. Aiming an end at its own centre is the one thing that does not work:
    # the direction is zero and the arrowhead lands in the middle of the box.
    sx, sy = _edge(a, *(vias[0] if vias else bc), gap)
    ex, ey = _edge(b, *(vias[-1] if vias else ac), gap)
    pts = [[0, 0]] + [[v[0] - sx, v[1] - sy] for v in vias] + [[ex - sx, ey - sy]]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    # A routed arrow gets square corners. Excalidraw's curve smoothing turns a
    # short first segment followed by a long one into a swoop that reads as a
    # second arrowhead at the wrong end.
    el = _base("arrow", sx, sy, max(xs) - min(xs), max(ys) - min(ys), colour,
               id=id, roundness=None if vias else {"type": 2}, strokeWidth=width,
               strokeStyle="dashed" if dashed else "solid")
    el.update({
        "points": pts, "lastCommittedPoint": None,
        "startBinding": None, "endBinding": None,
        "startArrowhead": None, "endArrowhead": "arrow", "elbowed": False,
    })
    return [el]


def frame(id, x, y, w, h, title, colour=BORDER, title_at="top"):
    """A dashed grouping box, titled just inside one of its corners.

    Inside rather than straddling the border: a caption sitting on a dashed
    line reads as struck through, and Excalidraw text has no plate behind it
    to break the line with. `title_at="bottom"` frees the top band of the frame
    for a route that has to pass through it.
    """
    r = _base("rectangle", x, y, w, h, colour, "transparent", id=id,
              strokeStyle="dashed", strokeWidth=1, roundness={"type": 3})
    ty = y + 10 if title_at == "top" else y + h - 26
    return [r] + label(f"{id}-t", x + 16, ty, title, size=13, colour=MUTED)


def write(name, *groups):
    elements = [e for g in groups for e in g]
    scene = {
        "type": "excalidraw",
        "version": 2,
        "source": "aws-community-central-asia-2026/scripts/build-diagrams.py",
        "elements": elements,
        "appState": {"viewBackgroundColor": "transparent", "gridSize": None},
        "files": {},
    }
    path = os.path.join(OUT, f"{name}.excalidraw.json")
    with open(path, "w") as fh:
        json.dump(scene, fh, indent=1)
    print(f"  {path}  ({len(elements)} elements)")


# ── 1. who asks, and what a wrong answer costs ─────────────────────────────
def probes():
    K = (340, 0, 220, 52)
    cols = [(0, 200), (340, 200), (680, 200)]   # x, width
    PY, QY, CY = 116, 196, 260
    g = []
    g += box("kubelet", *K, "kubelet", stroke=INDIGO, fill=INDIGO_TINT, size=18)

    spec = [
        ("startup",   "startup",   "Has it finished\nbooting?",  "holds the other two off\nwhile it runs",      CYAN,  CYAN_TINT),
        ("liveness",  "liveness",  "Is the process\nalive?",     "RESTARTS the container\nwork in flight dies", RED,   RED_TINT),
        ("readiness", "readiness", "Can it serve\nright now?",   "leaves the Service\nand comes back by itself", GREEN, GREEN_TINT),
    ]
    for (id, name, question, consequence, colour, tint), (cx, cw) in zip(spec, cols):
        pb = (cx, PY, cw, 46)
        cb = (cx, CY, cw, 60)
        g += box(f"{id}", *pb, name, stroke=colour, fill=tint, size=17)
        g += label(f"{id}-q", cx, QY, question, size=14, colour=MUTED, w=cw, align="center")
        g += box(f"{id}-c", *cb, consequence, stroke=colour, fill="transparent", size=13, ink=colour)
        g += arrow(f"{id}-a1", K, pb, colour=colour)
        g += arrow(f"{id}-a2", (cx, QY - 8, cw, 44), cb, colour=colour, gap=2)
    write("probes", g)


# ── 2. what is actually running ────────────────────────────────────────────
def architecture():
    g = []
    g += frame("vpc", 0, 16, 880, 280, "VPC  ·  2 AZ  ·  public subnets  ·  no NAT")
    g += frame("eks", 20, 54, 580, 218, "EKS", title_at="bottom")

    api    = (40, 96, 158, 56)
    sqs    = (236, 96, 150, 56)
    worker = (424, 96, 158, 56)
    keda   = (236, 198, 150, 50)
    karp   = (424, 198, 158, 50)
    syst   = (40, 198, 158, 50)
    rds    = (664, 134, 192, 72)

    g += box("api", *api, "api\n/work  /healthz  /ready", size=14)
    g += box("sqs", *sqs, "SQS work queue", size=14, stroke=ACCENT, fill=ACCENT_TINT)
    g += box("worker", *worker, "worker\nSQS consumer", size=14)
    g += box("keda", *keda, "KEDA\nreads queue depth", size=13, stroke=CYAN, fill=CYAN_TINT)
    g += box("karp", *karp, "Karpenter\nbuys spot nodes", size=13, stroke=CYAN, fill=CYAN_TINT)
    g += box("sys", *syst, "system node\nCoreDNS", size=13, stroke=BORDER, fill="transparent", ink=MUTED)
    g += box("rds", *rds, "RDS PostgreSQL\nmax_connections 57", size=14)

    g += arrow("a-api-sqs", api, sqs)
    g += arrow("a-sqs-w", sqs, worker)
    g += arrow("a-sqs-keda", sqs, keda, colour=CYAN, dashed=True)
    g += arrow("a-keda-karp", keda, karp, colour=CYAN)
    g += arrow("a-karp-w", karp, worker, colour=CYAN)
    g += arrow("a-w-rds", worker, rds)
    # The api reaches the database too, and the straight line to it runs through
    # the worker. Routed over the top of the row instead.
    g += arrow("a-api-rds", api, rds, bend=[(119, 74), (760, 74)])
    g += label("l-depth", 320, 160, "depth", size=12, colour=CYAN)
    write("architecture", g)


# ── 3. the two verdicts ────────────────────────────────────────────────────
def verdicts():
    g = []
    pod = (300, 0, 260, 54)
    lv  = (40, 108, 350, 52)
    rd  = (470, 108, 350, 52)
    lvc = (40, 190, 350, 92)
    rdc = (470, 190, 350, 92)

    g += box("pod", *pod, "a pod that is working fine", size=17)
    g += box("lv", *lv, "liveness says no", size=16, stroke=RED, fill=RED_TINT)
    g += box("rd", *rd, "readiness says no", size=16, stroke=GREEN, fill=GREEN_TINT)
    g += box("lvc", *lvc,
             "kubelet KILLS the container\n\nwork in flight dies · the pool is rebuilt\nthe cache is cold again",
             size=13, stroke=RED, fill="transparent", ink=INK)
    g += box("rdc", *rdc,
             "the pod leaves the EndpointSlice\n\nit keeps running · no traffic reaches it\nit comes back by itself",
             size=13, stroke=GREEN, fill="transparent", ink=INK)
    g += arrow("a-l", pod, lv, colour=RED)
    g += arrow("a-r", pod, rd, colour=GREEN)
    g += arrow("a-l2", lv, lvc, colour=RED)
    g += arrow("a-r2", rd, rdc, colour=GREEN)
    g += label("l-irr", 40, 292, "irreversible — one job: notice a process that will never recover",
               size=13, colour=RED)
    g += label("l-rev", 470, 292, "reversible — slow is a readiness question, never a liveness one",
               size=13, colour=GREEN)
    write("verdicts", g)


# ── 4. the loop ────────────────────────────────────────────────────────────
def loop():
    cx, cy, rx, ry = 430, 190, 300, 150
    bw, bh = 196, 52
    nodes = [
        ("n0", -90,  "the probe asks\nthe database",   INDIGO, INDIGO_TINT),
        ("n1", -30,  "replicas go\nNotReady",          INDIGO, INDIGO_TINT),
        ("n2",  30,  "workers stop\nconsuming SQS",    INDIGO, INDIGO_TINT),
        ("n3",  90,  "queue depth\ngrows",             ACCENT, ACCENT_TINT),
        ("n4", 150,  "KEDA adds\nworkers",             ACCENT, ACCENT_TINT),
        ("n5", 210,  "Karpenter buys\nnodes",          RED,    RED_TINT),
    ]
    g, boxes = [], {}
    for id, deg, text, stroke, fill in nodes:
        r = math.radians(deg)
        bx = cx + rx * math.cos(r) - bw / 2
        by = cy + ry * math.sin(r) - bh / 2
        boxes[id] = (bx, by, bw, bh)
        g += box(id, bx, by, bw, bh, text, size=14, stroke=stroke, fill=fill)
    order = [n[0] for n in nodes]
    for i, id in enumerate(order):
        nxt = order[(i + 1) % len(order)]
        colour = RED if id == "n5" else (ACCENT if id in ("n3", "n4") else INDIGO)
        g += arrow(f"a-{id}", boxes[id], boxes[nxt], colour=colour, width=2)
    g += label("l-mid", 300, 168, "nothing in the loop is broken", size=17, colour=INK, w=260, align="center")
    g += label("l-mid2", 300, 194, "every component does what it was asked", size=14, colour=MUTED, w=260, align="center")
    g += label("l-cost", 58, 54, "the only part of it with a price tag", size=14, colour=RED)
    write("loop", g)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print("diagram sources:")
    probes()
    architecture()
    verdicts()
    loop()
