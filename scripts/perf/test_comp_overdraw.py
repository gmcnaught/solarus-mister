# scripts/perf/test_comp_overdraw.py
import comp_overdraw as co

FRAME = [
    "COMP_FRAME map=119 camx=100 camy=200 fbw=320 fbh=240",
    # fill: FB-space, exactly the screen -> 320*240 px, overdraw 1 everywhere
    "COMP fill 0 0 320 240 0 255 1",
    # blit: FB-space 100x100 at (0,0) -> stacks on the fill (overdraw 2 there)
    "COMP blit 0 0 100 100 4 255 1",
    # sprite: partly off-screen left -> clips to (0,0,10,10)
    "COMP sprite -20 0 30 10 4 255 1",
    # tilemap normal (ratio=1): map (100,200) - cam (100,200) = screen (0,0), 8x8
    "COMP tilemap 100 200 8 8 0 255 1",
    # tilemap parallax (ratio=2): screen x = 240 + (100//2 - 100) = 240-50 = 190
    "COMP tilemap 240 200 8 8 0 255 2",
    # overlay: full-screen PALPHA
    "COMP overlay 0 0 320 240 2 255 1",
    "COMP_END",
]

def test_parse_frame_header():
    f = co.parse_frame(FRAME)
    assert f.map == 119
    assert f.cam == (100, 200)
    assert f.fb == (320, 240)
    assert len(f.records) == 6

def test_screen_rect_tilemap_normal():
    f = co.parse_frame(FRAME)
    r = [x for x in f.records if x.cat == "tilemap" and x.ratio == 1][0]
    assert co.screen_rect(r, f.cam) == (0, 0, 8, 8)

def test_screen_rect_tilemap_parallax():
    f = co.parse_frame(FRAME)
    r = [x for x in f.records if x.cat == "tilemap" and x.ratio == 2][0]
    # sx = 240 + (100//2 - 100) = 190 ; sy = 200 + (200//2 - 200) = 100
    assert co.screen_rect(r, f.cam) == (190, 100, 8, 8)

def test_clip_partial_and_offscreen():
    assert co.clip((-20, 0, 30, 10), 320, 240) == (0, 0, 10, 10)
    assert co.clip((400, 0, 10, 10), 320, 240) is None

def test_attribute_totals_and_overdraw():
    f = co.parse_frame(FRAME)
    rep = co.attribute(f)
    # fill 320*240 = 76800 ; overlay 76800 ; blit 100*100 = 10000 ;
    # sprite clipped 10*10 = 100 ; two 8x8 tiles = 128
    assert rep.per_cat["fill"] == 76800
    assert rep.per_cat["overlay"] == 76800
    assert rep.per_cat["blit"] == 10000
    assert rep.per_cat["sprite"] == 100
    assert rep.per_cat["tilemap"] == 128
    assert rep.total == 76800 + 76800 + 10000 + 100 + 128
    # hottest pixel (0,0): fill + blit + sprite(clipped to 0,0,10,10) +
    # tilemap-normal(screen 0,0) + overlay all overlap = 5
    assert rep.max_overdraw == 5
    assert abs(rep.mean_overdraw - rep.total / (320 * 240)) < 1e-9


# --- FIX 1: multi-block selection -----------------------------------------

# A two-block capture: the savegame's starting map (5) built first, then the
# teleported-to target map (119) built second -- mirrors the real capture
# flow this analyzer is meant to consume.
MULTI_BLOCK = [
    "COMP_FRAME map=5 camx=10 camy=20 fbw=320 fbh=240",
    "COMP fill 0 0 320 240 0 255 1",
    "COMP_END",
    "COMP_FRAME map=119 camx=100 camy=200 fbw=320 fbh=240",
    "COMP fill 0 0 320 240 0 255 1",
    "COMP blit 0 0 50 50 4 255 1",
    "COMP_END",
]

def test_parse_frame_multiblock_defaults_to_last_complete_block():
    f = co.parse_frame(MULTI_BLOCK)
    assert f.map == 119
    assert f.cam == (100, 200)
    # exactly the map-119 block's own records -- proves no leak from map 5
    assert len(f.records) == 2

def test_parse_frame_want_map_selects_named_block():
    f = co.parse_frame(MULTI_BLOCK, want_map=5)
    assert f.map == 5
    assert f.cam == (10, 20)
    assert len(f.records) == 1

def test_parse_frame_want_map_missing_raises_value_error():
    try:
        co.parse_frame(MULTI_BLOCK, want_map=999)
        assert False, "expected ValueError for an absent map id"
    except ValueError as e:
        msg = str(e)
        assert "999" in msg
        # error lists the map ids actually seen, for operator diagnosis
        assert "5" in msg and "119" in msg


# --- FIX 2: malformed-line guard --------------------------------------------

MALFORMED_BLOCK = [
    "COMP_FRAME map=119 camx=0 camy=0 fbw=320 fbh=240",
    "COMP fill 0 0 320",                  # truncated: < 9 tokens, must skip
    "COMP fill a b c d 0 255 1",           # non-numeric fields, must skip
    "COMP blit 10 10 20 20 4 255 1",       # valid, must still be attributed
    "COMP_END",
]

def test_parse_frame_skips_malformed_comp_lines_without_crashing():
    f = co.parse_frame(MALFORMED_BLOCK)
    # only the one well-formed record survives
    assert len(f.records) == 1
    assert f.records[0].cat == "blit"
    rep = co.attribute(f)
    assert rep.per_cat.get("fill") is None
    assert rep.per_cat["blit"] == 20 * 20
    assert rep.total == 400
