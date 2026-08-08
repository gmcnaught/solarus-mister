#!/usr/bin/env python3
"""Score a MiSTer screenshot against a golden capture — the .62 render-fault judge.

Why this exists: `sdram_selftest` produced five false hardware verdicts and returns
different answers for the same hardware + bitstream across a power cycle
(docs/superpowers/2026-08-06-sdram-62-investigation-handoff.md §3). A MiSTer
screenshot measures the actual symptom through the actual datapath, needs no
on-device C, no handshake semantics and no memory-map constants — the three things
that generated every false verdict.

Metrics (all objective; no human judgement in the loop after the golden is set):

  textmatch THE VERDICT SIGNAL. Exact-pixel agreement with the golden, restricted
            to the non-black golden pixels of the footer band (rows 205-239) — the
            "www.solarus-games.org" line. The title screen cycles day/night, so a
            perfectly correct frame matches the full golden only ~58% of the time;
            the footer text is identical in both variants. Restricting to non-black
            pixels is what stops an all-black frame from scoring 98% on a band that
            is mostly background. Measured: day 100%, night 100%, .62 fault 22-59%.
  match%    exact-pixel agreement with the golden over the whole frame. Reported
            for information only — day/night makes it useless as a gate.
  altratio  mean|dLum| at x-lag 1 divided by the same at x-lag 2. The observed .62
            fault is strictly period-2 in x (alternate 16-bit pixel words read as
            zero), which drives this ratio to 35-55. A correct frame sits below 1
            because a natural image varies MORE over 2 pixels than over 1.
  oddzero   fraction of odd-x pixels that are exactly black.
  uniq      distinct colours (a blank/black frame is not a verdict).

Calibration from the 2026-08-06 captures:
  .81 correct title screen : altratio 0.79   oddzero 0.40
  .62 garbage title screen : altratio 35-55  oddzero 0.79-0.88

Screenshots arrive at the core's native raster or a pixel-doubled copy of it,
depending on the video mode in force; the doubled capture is decimated by 2, so the
fault's period-2 signature is measured in native pixel space either way.

The raster is NOT a constant: it went 320x240 -> 416x240 when the framebuffer was
widened for 416-wide quests (fpga/rtl/fb_geom.vh). Hardcoding it here would not fail
loudly -- every metric would simply be computed over the wrong pixel grid, and the
period-2 alternation test in particular is meaningless if the row stride is wrong.
So the geometry is INFERRED from the capture and cross-checked against the set of
rasters the core can actually produce.

Usage:
    shot_score.py <shot.png> [<shot2.png> ...] --golden <golden.png>
    shot_score.py <shot.png> --stats-only        # no golden: report metrics only

Exit status: 0 if any input scored PASS, 1 otherwise (so a caller can gate on it).
"""

import argparse
import sys
from collections import Counter

try:
    from PIL import Image
except ImportError:  # pragma: no cover - environment guard
    sys.exit("shot_score: Pillow is required (pip install pillow)")

# Rasters the core can emit, widest first. 416x240 is the current framebuffer
# (fb_geom.vh FB_W/FB_H); 320x240 is retained so captures taken before the widening
# still score. Add a row here rather than editing W/H if the raster changes again.
KNOWN_RASTERS = ((416, 240), (320, 240))

# Set by load_native() from the capture it just read; every metric below is a
# function of these, never of a literal.
W, H = KNOWN_RASTERS[0]

# Verdict thresholds. ALT_FAIL is set an order of magnitude below the observed
# fault (35-55) and several times above a correct frame (0.79), so neither a
# noisier scene nor a milder fault can land in the gap unclassified.
ALT_FAIL = 3.0
TEXT_PASS = 95.0
BLANK_FRAC = 0.99

# Footer band holding the static "www.solarus-games.org" line, identical in the
# title screen's day and night variants. Rows only -- the band spans the full width,
# whatever that is -- and H-relative so it stays the bottom 35 lines.
FOOTER_Y0, FOOTER_Y1 = H - 35, H


def load_native(path):
    """Return a native-raster RGB pixel list, decimating a pixel-doubled capture.

    Sets the module-level W/H/footer band from whichever KNOWN_RASTERS entry the
    capture matches (1:1 or 2:1), so a mixed-geometry batch cannot be scored against
    a stale grid. Raises on anything unrecognised rather than guessing -- a wrong
    guess here produces plausible numbers for the wrong pixels.
    """
    global W, H, FOOTER_Y0, FOOTER_Y1
    im = Image.open(path).convert("RGB")
    w, h = im.size
    for rw, rh in KNOWN_RASTERS:
        if (w, h) == (rw, rh):
            break
        if (w, h) == (2 * rw, 2 * rh):
            im = im.resize((rw, rh), Image.NEAREST)  # NEAREST = take every 2nd pixel
            break
    else:
        known = ", ".join(f"{rw}x{rh} (or {2*rw}x{2*rh})" for rw, rh in KNOWN_RASTERS)
        raise ValueError(f"{path}: unexpected capture size {w}x{h}; known rasters: {known}")
    W, H = im.size
    FOOTER_Y0, FOOTER_Y1 = H - 35, H
    return list(im.getdata())


def lum(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def metrics(px):
    d1 = d2 = 0.0
    n1 = n2 = 0
    for y in range(H):
        row = [lum(px[y * W + x]) for x in range(W)]
        for x in range(W - 1):
            d1 += abs(row[x + 1] - row[x])
            n1 += 1
        for x in range(W - 2):
            d2 += abs(row[x + 2] - row[x])
            n2 += 1
    # +0.01 guards a perfectly flat frame; such a frame is caught as BLANK anyway.
    altratio = (d1 / n1) / ((d2 / n2) + 0.01)

    odd = [px[y * W + x] for y in range(H) for x in range(1, W, 2)]
    oddzero = sum(1 for p in odd if p == (0, 0, 0)) / len(odd)

    counts = Counter(px)
    return {
        "altratio": altratio,
        "oddzero": oddzero,
        "uniq": len(counts),
        "modal_frac": counts.most_common(1)[0][1] / len(px),
    }


def text_match(px, gold):
    """Match over the golden's non-black footer pixels (the static URL line)."""
    idx = [
        y * W + x
        for y in range(FOOTER_Y0, FOOTER_Y1)
        for x in range(W)
        if gold[y * W + x] != (0, 0, 0)
    ]
    if not idx:
        return None
    return 100.0 * sum(1 for i in idx if px[i] == gold[i]) / len(idx)


def verdict(m, tmatch):
    if m["modal_frac"] > BLANK_FRAC:
        return "BLANK"          # a uniform frame proves nothing either way
    if m["altratio"] >= ALT_FAIL:
        return "FAIL-ALT"       # the period-2 alternating-pixel fault
    if tmatch is None:
        return "NO-GOLDEN"
    if tmatch >= TEXT_PASS:
        return "PASS"
    return "FAIL-OTHER"         # wrong scene, or a corruption of another shape


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("shots", nargs="+")
    ap.add_argument("--golden")
    ap.add_argument("--stats-only", action="store_true")
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    if not args.golden and not args.stats_only:
        sys.exit("shot_score: --golden is required unless --stats-only")

    gold = load_native(args.golden) if args.golden else None

    best = None
    for path in args.shots:
        try:
            px = load_native(path)
        except (OSError, ValueError) as exc:
            print(f"{args.label} {path}: NO-CAPTURE ({exc})")
            continue
        m = metrics(px)
        match = tmatch = None
        if gold is not None:
            match = 100.0 * sum(1 for a, b in zip(px, gold) if a == b) / (W * H)
            tmatch = text_match(px, gold)
        v = verdict(m, tmatch)
        print(
            f"{args.label} {path}: {v} "
            f"text={'n/a' if tmatch is None else f'{tmatch:.1f}%'} "
            f"match={'n/a' if match is None else f'{match:.1f}%'} "
            f"altratio={m['altratio']:.2f} oddzero={m['oddzero']:.2f} "
            f"uniq={m['uniq']} modal={m['modal_frac']:.2f}"
        )
        # Best = highest match among non-blank frames; a screenshot can land on a
        # transition frame, so several are taken and the best one is the verdict.
        key = (v != "BLANK", tmatch if tmatch is not None else 0.0)
        if best is None or key > best[0]:
            best = (key, v, tmatch)

    if best is None:
        print(f"{args.label} RESULT: NO-CAPTURE")
        return 1
    _, v, tmatch = best
    print(f"{args.label} RESULT: {v} best-text={'n/a' if tmatch is None else f'{tmatch:.1f}%'}")
    return 0 if v == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
