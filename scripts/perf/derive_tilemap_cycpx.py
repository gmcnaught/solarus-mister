#!/usr/bin/env python3
"""Derive map-119 tilemap cyc/px from captured [blitter *] banners (Stage 5 Phase 1).

No RTL / no device: reuses the comp-pipeline cycle counter (C_STATUS+4) already
published every frame in [blitter hwperf], divided by the composited tilemap pixel
count reconstructed two independent ways (framebuffer-area and bucket-entries).
"""
import re

FB_W, FB_H, CELL = 320, 240, 8  # 320x240 frame; grid cells are 8px (Stage 3b B3)

def _num(pat, text, cast=float, default=None):
    m = re.search(pat, text)
    if not m:
        if default is not None:
            return default
        raise ValueError(f"pattern not found: {pat!r}")
    return cast(m.group(1))

def parse_window(text):
    return {
        "comp_cyc_per_frame": _num(r"\((\d+)\s*cyc/frame\)", text, float),
        "bucket_entries":     _num(r"\bentries=(\d+)", text, int),
        "blend_draws":        _num(r"blend NONE=\d+ BLEND=(\d+)", text, int),
        "fb_layers":          _num(r"tilemap_layers=(\d+)", text, int, default=3),
    }

def tilemap_cycpx(w):
    px_fb = FB_W * FB_H * w["fb_layers"]          # estimate A: full-frame per layer
    px_entries = w["bucket_entries"] * CELL * CELL # estimate B: composited grid cells
    px = px_fb if px_fb > 0 else px_entries
    cycpx = w["comp_cyc_per_frame"] / px if px else float("inf")
    div = (abs(px_fb - px_entries) / max(px_fb, px_entries) * 100.0) if max(px_fb, px_entries) else 0.0
    grid_live = w["blend_draws"] == 0             # per-tile BLEND == replay/fallback, not the grid path
    if 2.7 <= cycpx <= 3.3:
        verdict = "AMBIGUOUS"
    elif cycpx <= 3.0:
        verdict = "PASS"
    else:
        verdict = "FAIL"
    return {"cycpx": cycpx, "px_est_fb": px_fb, "px_est_entries": px_entries,
            "divergence_pct": div, "grid_path_live": grid_live, "verdict": verdict}

if __name__ == "__main__":
    import sys
    text = sys.stdin.read()
    r = tilemap_cycpx(parse_window(text))
    print(f"tilemap cyc/px = {r['cycpx']:.2f}  verdict={r['verdict']}  "
          f"grid_path_live={r['grid_path_live']}  "
          f"px(fb={r['px_est_fb']} entries={r['px_est_entries']} "
          f"div={r['divergence_pct']:.0f}%)")
