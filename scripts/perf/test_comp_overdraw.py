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
