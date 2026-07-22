#!/usr/bin/env python3
"""Unit tests for a9_decompose. Run: python3 scripts/perf/test_a9_decompose.py"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from a9_decompose import parse_medians, enttype_medians, rank_leaves, pick_lever

# Two synthetic /60fr windows modelled on the real map-119 standing capture
# (docs/superpowers/data/stage5/ab-enlarged-map119.txt) plus the deeper drill
# banners the A/B subset omitted. Values chosen so present (fixed) is the top
# leaf and entities (amplified) is the top update-side leaf.
SAMPLE = """\
[blitter timing] /60fr: fps=19.9 period=50.3ms | fabric=15.8ms A9=21.3ms sleep=13.1ms | jitter=43.0ms spin_iters=57 | pipeline_ceiling=29.0fps | fastpace=on skips=1/60
[blitter a9split] /60fr: A9=21.3ms = lua=11.3ms + emit=4.0ms + present=6.0ms
[blitter emitsplit] /60fr: emit=4.0ms = walk=2.6 + blit=1.4 | ps_add(diag-tax)=0.0 -> real_emit~4.0ms
[blitter luasplit] /60fr: update=11.3ms = lua_vm=2.6ms + eng_cpp=8.7ms
[blitter engcpp] /60fr: eng_cpp=8.7ms = entities=4.0 + hero=0.8 + nonanim=0.0 + tileset=1.0 + sound=1.2 + other=1.6 | steps/fr=5.03 per_step=1.7ms
[blitter enttype] /60fr: n=210/fr | enemy=2.4ms(6) destructible=0.9ms(20) npc=0.4ms(3)
[blitter entphase] /60fr: enemy=2.4ms = ai_lua=0.3 (throttle-only) + nonlua=2.1 (state/move/collision -> SIMD-candidate)
[blitter movedrill] /60fr enemy per-move bookkeeping: qtree_reinsert=1.0ms ground_requery=0.4ms detector=0.4ms math+setpos+notify=0.3ms
[blitter a9split] /60fr: A9=20.9ms = lua=10.8ms + emit=3.8ms + present=6.3ms
[blitter emitsplit] /60fr: emit=3.8ms = walk=2.4 + blit=1.4 | ps_add(diag-tax)=0.0 -> real_emit~3.8ms
[blitter luasplit] /60fr: update=10.8ms = lua_vm=2.5ms + eng_cpp=8.3ms
[blitter engcpp] /60fr: eng_cpp=8.3ms = entities=3.9 + hero=0.8 + nonanim=0.0 + tileset=0.9 + sound=1.2 + other=1.5 | steps/fr=5.05 per_step=1.6ms
"""

def test_parse_medians_core_split():
    m = parse_medians(SAMPLE)
    assert m["a9"] == 21.1            # median(21.3, 20.9)
    assert m["present"] == 6.15       # median(6.0, 6.3)
    assert m["emit"] == 3.9           # median(4.0, 3.8)
    assert m["ent_entities"] == 3.95  # median(4.0, 3.9)
    assert m["lua_vm"] == 2.55        # median(2.6, 2.5)
    assert abs(m["steps_fr"] - 5.04) < 1e-9

def test_enttype_and_movedrill():
    ent = enttype_medians(SAMPLE)
    assert ent["enemy"] == 2.4
    m = parse_medians(SAMPLE)
    assert m["md_qtree"] == 1.0       # only one movedrill window

def test_rank_leaves_present_is_top_fixed():
    leaves = rank_leaves(parse_medians(SAMPLE))
    top_name, top_ms, top_ampl = leaves[0]
    assert top_name == "present" and top_ms == 6.15 and top_ampl is False
    # entities is the largest step-amplified leaf
    ampl = [(n, ms) for (n, ms, a) in leaves if a]
    assert ampl[0][0] == "ent_entities"

def test_pick_lever_present_top():
    lever = pick_lever(parse_medians(SAMPLE), enttype_medians(SAMPLE))
    assert "overlay dirty-skip" in lever and "dyn_reup" in lever

def test_pick_lever_entities_enemy():
    # A window where entities dominates and enemy is the top type -> movedrill lever
    txt = SAMPLE + (
        "[blitter a9split] /60fr: A9=18.0ms = lua=14.0ms + emit=2.0ms + present=2.0ms\n"
        "[blitter emitsplit] /60fr: emit=2.0ms = walk=1.0 + blit=1.0 | ps_add(diag-tax)=0.0 -> real_emit~2.0ms\n"
        "[blitter luasplit] /60fr: update=14.0ms = lua_vm=1.0ms + eng_cpp=13.0ms\n"
        "[blitter engcpp] /60fr: eng_cpp=13.0ms = entities=10.0 + hero=0.5 + nonanim=0.0 + tileset=0.5 + sound=1.0 + other=1.0 | steps/fr=6.00 per_step=2.2ms\n"
        "[blitter enttype] /60fr: n=300/fr | enemy=9.0ms(30) destructible=0.5ms(10)\n"
        "[blitter entphase] /60fr: enemy=9.0ms = ai_lua=0.5 (throttle-only) + nonlua=8.5\n"
        "[blitter movedrill] /60fr enemy per-move bookkeeping: qtree_reinsert=4.0ms ground_requery=1.0ms detector=1.0ms math+setpos+notify=2.5ms\n"
    ) * 3
    lever = pick_lever(parse_medians(txt), enttype_medians(txt))
    assert "enemy move-bookkeeping" in lever

def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn(); print(f"PASS {fn.__name__}")
    print(f"\n{len(fns)} passed")

if __name__ == "__main__":
    _run()
