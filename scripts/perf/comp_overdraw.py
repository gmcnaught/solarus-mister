"""Offline overdraw attribution for SOLARUS_COMPTRACE dumps.

Reads one or more COMP_FRAME..COMP_END blocks, clips every emitted dst rect to
the 320x240 screen, sums composited pixels per category, and reports the
overdraw map. tilemap rects are stored in MAP coords and transformed to screen
via the per-bucket camera bias (normal: -cam ; parallax: cam//ratio - cam),
matching mister_blitter_renderer.cpp's static_bucket_bias / res_emit_bucket_.

A capture may contain multiple COMP_FRAME..COMP_END blocks (the capture flow
builds the savegame's starting map AND then the teleported-to target map, so
the target block is typically the LAST complete block, not the first) --
parse_frame() selects accordingly, see its docstring.
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


def _parse_blocks(lines):
    """Parse a COMPTRACE capture into a list of (Frame, complete) pairs, one
    per COMP_FRAME..COMP_END block encountered, in file order. A block's
    record accumulation is reset at each COMP_FRAME header (records never
    leak across blocks). `complete` is True once a block's COMP_END is seen;
    a trailing block with no COMP_END is included as (Frame, False).
    """
    blocks = []
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
            records = []
            started = True
            continue
        if t[0] == "COMP_END":
            if started:
                blocks.append((Frame(map_, cam, fb, records), True))
                started = False
            continue
        if t[0] == "COMP" and started:
            if len(t) < 9:
                continue
            try:
                _, cat, dx, dy, w, h, blend, op, ratio = t[:9]
                rec = Rec(cat, int(dx), int(dy), int(w), int(h),
                          int(blend), int(op), int(ratio))
            except ValueError:
                continue
            records.append(rec)
    if started:
        # trailing incomplete block
        blocks.append((Frame(map_, cam, fb, records), False))
    return blocks


def parse_frame(lines, want_map=None):
    """Parse a COMPTRACE capture that may hold multiple COMP_FRAME..COMP_END
    blocks and return a single selected Frame.

    A block's records are reset at each COMP_FRAME header (records never leak
    across blocks -- see _parse_blocks). A block is "complete" once its
    COMP_END is seen.

    Selection:
      - want_map is None (default): return the LAST complete block. This is
        the common case -- the capture flow builds the savegame's starting
        map and then the teleported-to target map, so the target block is
        the last one, not the first.
      - want_map is an int: return the (complete-or-not) block whose
        map == want_map. Raises ValueError, listing the map ids actually
        seen, if no block matches.

    An incomplete trailing block (no COMP_END) is only returned if it is the
    ONLY block parsed (best-effort partial attribution); it is never
    preferred over a complete block.

    `lines` may be a one-shot iterator (e.g. an open file) -- it is consumed
    exactly once here.
    """
    blocks = _parse_blocks(lines)

    if not blocks:
        return Frame(0, (0, 0), (320, 240), [])

    if want_map is not None:
        for frame, _complete in blocks:
            if frame.map == want_map:
                return frame
        seen = sorted({frame.map for frame, _complete in blocks})
        raise ValueError(
            "no COMP_FRAME block found for map=%d (maps seen: %s)"
            % (want_map, seen))

    complete = [frame for frame, is_complete in blocks if is_complete]
    if complete:
        return complete[-1]
    # only an incomplete trailing block exists -- return it, best-effort
    return blocks[-1][0]


def screen_rect(rec, cam):
    """Map a tilemap record's MAP-space rect to SCREEN space via the
    per-bucket camera bias.

    Assumptions inherited from mister_blitter_renderer.cpp's
    static_bucket_bias / res_emit_bucket_ (do not "fix" these here without
    updating the engine formula too -- the two must stay in lockstep):

    - STANDING capture only: this ignores the Stage-3a scroll fabric term
      (`obx`/`oby`, see SOLARUS_SCROLLFAB / g_transition_scroll), which is 0
      unless a scroll transition is actively compositing. A capture taken
      mid-scroll would need that term added and this analyzer does not
      support it.
    - NON-NEGATIVE camera coords assumed: Python's `//` floors toward
      negative infinity while the engine's C++ `/` truncates toward zero.
      For a parallax bucket (ratio > 1) with a negative camera coordinate,
      `cx // ratio` and the engine's `cx / ratio` can differ by 1px. This is
      a latent divergence, not a bug fix target -- map-119 standing captures
      always have non-negative camx/camy so it does not currently bite.
    """
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
    ap.add_argument("--map", type=int, default=None,
                    help="select the COMP_FRAME block for this map id "
                         "(default: last complete block in the capture)")
    a = ap.parse_args(argv)
    with open(a.log) as fh:
        lines = fh.readlines()
    blocks = _parse_blocks(lines)
    n_complete = sum(1 for _frame, complete in blocks if complete)
    frame = parse_frame(lines, want_map=a.map)
    print("blocks: %d complete (%d total parsed) -- selected map=%d%s"
          % (n_complete, len(blocks), frame.map,
             " (want_map=%d)" % a.map if a.map is not None else " (last complete)"))
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
        print("             traced/modeled = %.2f  (~1.0 = trustworthy; <1.0 = fabric"
              " does more per px than dst-area, e.g. blend RMW; >1.0 = expected/benign,"
              " the fabric can early-out on fully-transparent src px while this analyzer"
              " sums whole dst rects, so traced dst-area over-counts actual writes)"
              % (rep.total / modeled))
    if a.heatmap:
        print(_ascii_heatmap(rep.grid))
    return 0


if __name__ == "__main__":
    sys.exit(main())
