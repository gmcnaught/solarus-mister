import subprocess, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from derive_tilemap_cycpx import parse_window, tilemap_cycpx

# A synthetic standing-map119 window: comp counter ~ 460800 cyc/frame over
# ~230400 composited px (3 layers * 320*240) -> ~2.0 cyc/px (clean PASS).
SAMPLE = """\
[blitter hwperf] /60fr: fabric_hw=5.20ms comp=4.68ms comp%=90% (460800 cyc/frame) | A9-or-fabric-bound: FABRIC
[blitter resident] /60fr: rebuild=0 fast_noop=60 patch_pass=0 patched_entries=0 | buckets=6 patterns=41 entries=3600 tl_used=1000/4096 valid=1 fatal=0
[blitter p0] /60fr: draws=210 fills=1 | blend NONE=210 BLEND=0 ADD=0 MUL=0 | op full=210 part=0 | xform rot=0 scale=0 colormod=0 | distinct_tex=6
"""

def test_parse_pulls_fields():
    w = parse_window(SAMPLE)
    assert w["comp_cyc_per_frame"] == 460800.0
    assert w["bucket_entries"] == 3600
    assert w["blend_draws"] == 0

def test_cycpx_clean_pass():
    r = tilemap_cycpx(parse_window(SAMPLE))
    # 460800 / (3*320*240=230400) = 2.0
    assert abs(r["cycpx"] - 2.0) < 0.01
    assert r["verdict"] == "PASS"
    assert r["grid_path_live"] is True   # BLEND=0 -> parallax went through the grid, not per-tile BLEND

def test_ambiguous_band_flags_escalation():
    amb = SAMPLE.replace("460800", "691200")  # 691200/230400 = 3.0 -> AMBIGUOUS
    r = tilemap_cycpx(parse_window(amb))
    assert r["verdict"] == "AMBIGUOUS"

def test_grid_path_not_live_when_blend_present():
    replay = SAMPLE.replace("BLEND=0", "BLEND=1500")
    r = tilemap_cycpx(parse_window(replay))
    assert r["grid_path_live"] is False   # per-tile BLEND -> measuring a fallback/replay scene, invalid

if __name__ == "__main__":
    import sys
    tests = [name for name in dir() if name.startswith("test_")]
    failed = 0
    for name in tests:
        try:
            globals()[name]()
            print(f"OK: {name}")
        except AssertionError as e:
            print(f"FAIL: {name}: {e}")
            failed += 1
    sys.exit(1 if failed else 0)
