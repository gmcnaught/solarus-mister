"""Offline overdraw attribution for SOLARUS_COMPTRACE dumps.

Reads one COMP_FRAME..COMP_END block, clips every emitted dst rect to the
320x240 screen, sums composited pixels per category, and reports the overdraw
map. tilemap rects are stored in MAP coords and transformed to screen via the
per-bucket camera bias (normal: -cam ; parallax: cam//ratio - cam), matching
mister_blitter_renderer.cpp's static_bucket_bias / res_emit_bucket_.
"""
import argparse
import sys
from collections import namedtuple

Rec = namedtuple("Rec", "cat dx dy w h blend op ratio")


class Frame:
    def __init__(self, map_, cam, fb, records):
        self.map = map_
        self.cam = cam
        self.fb = fb
        self.records = records


class Report:
    def __init__(self, per_cat, total, grid, mean_overdraw, max_overdraw):
        self.per_cat = per_cat
        self.total = total
        self.grid = grid
        self.mean_overdraw = mean_overdraw
        self.max_overdraw = max_overdraw


def parse_frame(lines):
    map_ = 0
    cam = (0, 0)
    fb = (320, 240)
    records = []
    started = False
    for raw in lines:
        t = raw.strip().split()
        if not t:
            continue
        if t[0] == "COMP_FRAME":
            kv = dict(tok.split("=", 1) for tok in t[1:] if "=" in tok)
            map_ = int(kv.get("map", "0"))
            cam = (int(kv.get("camx", "0")), int(kv.get("camy", "0")))
            fb = (int(kv.get("fbw", "320")), int(kv.get("fbh", "240")))
            started = True
            continue
        if t[0] == "COMP_END":
            break
        if t[0] == "COMP" and started:
            _, cat, dx, dy, w, h, blend, op, ratio = t[:9]
            records.append(Rec(cat, int(dx), int(dy), int(w), int(h),
                               int(blend), int(op), int(ratio)))
    return Frame(map_, cam, fb, records)


def screen_rect(rec, cam):
    if rec.cat == "tilemap":
        cx, cy = cam
        if rec.ratio <= 1:
            bx, by = -cx, -cy
        else:
            bx, by = cx // rec.ratio - cx, cy // rec.ratio - cy
        return (rec.dx + bx, rec.dy + by, rec.w, rec.h)
    return (rec.dx, rec.dy, rec.w, rec.h)


def clip(rect, W, H):
    x, y, w, h = rect
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return None
    return (x0, y0, x1 - x0, y1 - y0)


def attribute(frame):
    W, H = frame.fb
    grid = [[0] * W for _ in range(H)]
    per_cat = {}
    for rec in frame.records:
        c = clip(screen_rect(rec, frame.cam), W, H)
        if c is None:
            continue
        x, y, w, h = c
        per_cat[rec.cat] = per_cat.get(rec.cat, 0) + w * h
        for yy in range(y, y + h):
            row = grid[yy]
            for xx in range(x, x + w):
                row[xx] += 1
    total = sum(per_cat.values())
    mx = max((max(r) for r in grid), default=0)
    mean = total / (W * H) if W and H else 0.0
    return Report(per_cat, total, grid, mean, mx)


def _ascii_heatmap(grid, cols=80, rows=48):
    H = len(grid)
    W = len(grid[0]) if H else 0
    shades = " .:-=+*#%@"
    mx = max((max(r) for r in grid), default=0) or 1
    out = []
    for ry in range(rows):
        line = []
        for rx in range(cols):
            x = rx * W // cols
            y = ry * H // rows
            v = grid[y][x]
            line.append(shades[min(len(shades) - 1, v * (len(shades) - 1) // mx)])
        out.append("".join(line))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="COMPTRACE overdraw attribution")
    ap.add_argument("log", help="captured stderr log containing a COMP_FRAME block")
    ap.add_argument("--comp-cyc", type=float, default=None,
                    help="comp cyc/frame from [blitter hwperf] for cross-check")
    ap.add_argument("--cyc-per-px", type=float, default=2.38,
                    help="modeled fabric cycles per composited px (cache-knee.md)")
    ap.add_argument("--heatmap", action="store_true", help="print ASCII overdraw heatmap")
    a = ap.parse_args(argv)
    with open(a.log) as fh:
        frame = parse_frame(fh)
    rep = attribute(frame)
    print("map=%d cam=%s fb=%s records=%d"
          % (frame.map, frame.cam, frame.fb, len(frame.records)))
    print("composited px total = %d  (mean overdraw %.2fx, max %d)"
          % (rep.total, rep.mean_overdraw, rep.max_overdraw))
    for cat in sorted(rep.per_cat, key=lambda k: -rep.per_cat[k]):
        px = rep.per_cat[cat]
        print("  %-8s %9d px  %5.1f%%" % (cat, px, 100.0 * px / rep.total))
    if a.comp_cyc:
        modeled = a.comp_cyc / a.cyc_per_px
        print("cross-check: hwperf comp=%.0f cyc / %.2f cyc-per-px = %.0f modeled px"
              % (a.comp_cyc, a.cyc_per_px, modeled))
        print("             traced/modeled = %.2f  (1.0 = trustworthy; <1 = fabric"
              " does more per px than dst-area, e.g. blend RMW)" % (rep.total / modeled))
    if a.heatmap:
        print(_ascii_heatmap(rep.grid))
    return 0


if __name__ == "__main__":
    sys.exit(main())
