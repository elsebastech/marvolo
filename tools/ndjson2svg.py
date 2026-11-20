#!/usr/bin/env python3
"""Convert a NoteLive ndjson capture into an SVG.

    python3 tools/ndjson2svg.py SESSION.ndjson [OUT.svg] [--color RRGGBB] [--bg RRGGBB]

The ndjson is one JSON event per line, as written by the app:

    {"t":"ink","x":12345,"y":22011,"p":1840}
    {"t":"hover","x":12345,"y":22011}
    {"t":"marker"}
    {"t":"status","state":"connected",...}

A stroke is a run of `ink` events terminated by `hover` or `marker`; `marker`
also starts a new page. Unknown event types (`done`, `status`, ...) are ignored,
so a capture from any version of the app converts.

The SVG keeps the device coordinate system (Y grows downward, origin top-left,
no flip) and encodes pressure as stroke width, so it can be diffed, printed or
rasterised without the app.
"""
import json
import sys

W, H = 28800, 40000  # device active area, generous on Y (real ink reached 39043)


def parse(path):
    """-> [(page, [(x, y, p), ...]), ...]"""
    strokes, cur, page = [], [], 0
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue  # a truncated final line is normal if the app was killed
        t = ev.get("t")
        if t == "ink":
            cur.append((ev["x"], ev["y"], ev.get("p", 0)))
        elif t in ("hover", "marker"):
            if len(cur) > 1:
                strokes.append((page, cur))
            cur = []
            if t == "marker":
                page += 1
    if len(cur) > 1:
        strokes.append((page, cur))
    return strokes


def width(p, lo=0.7, hi=4.2, full=8191):
    """Same mapping as the on-screen renderer at 1x."""
    return max(lo, min(hi, lo + p / 1100))


def to_svg(strokes, color="15120f", bg="f6f4ef"):
    if not strokes:
        raise SystemExit("no strokes found in this capture")
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'width="{W}" height="{H}">',
        f'<rect width="{W}" height="{H}" fill="#{bg}"/>',
        f'<g fill="none" stroke="#{color}" stroke-linecap="round" stroke-linejoin="round">',
    ]
    for _, pts in strokes:
        # One polyline per stroke, width taken per segment so pressure shows.
        for i in range(1, len(pts)):
            x0, y0, p0 = pts[i - 1]
            x1, y1, p1 = pts[i]
            out.append(f'<line x1="{x0}" y1="{y0}" x2="{x1}" y2="{y1}" '
                       f'stroke-width="{width((p0 + p1) / 2):.2f}"/>')
    out += ["</g>", "</svg>", ""]
    return "\n".join(out)


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    src = argv[1]
    dst = argv[2] if len(argv) > 2 and not argv[2].startswith("--") else src.rsplit(".", 1)[0] + ".svg"
    color = bg = None
    if "--color" in argv:
        color = argv[argv.index("--color") + 1]
    if "--bg" in argv:
        bg = argv[argv.index("--bg") + 1]

    strokes = parse(src)
    svg = to_svg(strokes, **({"color": color} if color else {}),
                 **({"bg": bg} if bg else {}))
    open(dst, "w", encoding="utf-8").write(svg)

    pts = sum(len(p) for _, p in strokes)
    pages = len({pg for pg, _ in strokes})
    print(f"{src}: {len(strokes)} strokes, {pts} points, {pages} page(s) -> {dst}")


if __name__ == "__main__":
    main(sys.argv)
