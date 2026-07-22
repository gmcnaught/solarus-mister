#!/usr/bin/env python3
"""Decompose a captured [blitter ...] banner log into the A9 (host-CPU) cost tree
and name the fork-rule lever candidate. Stdlib only.

The a9split "lua" field is the WHOLE update() tick (see patches/mister/mister_lua_prof.h);
luasplit splits it into lua_vm + eng_cpp; engcpp splits eng_cpp into leaves. present and
emit are per-frame (fixed); every update-side leaf is step-amplified by steps/fr.
"""
import re, sys, statistics

_F = r"([\d.]+)"  # a float field

_PATS = {
    "a9split":   re.compile(r"\[blitter a9split\].*?A9="+_F+r"ms = lua="+_F+r"ms \+ emit="+_F+r"ms \+ present="+_F+r"ms"),
    "emitsplit": re.compile(r"\[blitter emitsplit\].*?emit="+_F+r"ms = walk="+_F+r" \+ blit="+_F),
    "luasplit":  re.compile(r"\[blitter luasplit\].*?update="+_F+r"ms = lua_vm="+_F+r"ms \+ eng_cpp="+_F+r"ms"),
    "engcpp":    re.compile(r"\[blitter engcpp\].*?eng_cpp="+_F+r"ms = entities="+_F+r" \+ hero="+_F+r" \+ nonanim="+_F+r" \+ tileset="+_F+r" \+ sound="+_F+r" \+ other="+_F+r" \| steps/fr="+_F+r" per_step="+_F+r"ms"),
    "entphase":  re.compile(r"\[blitter entphase\].*?enemy="+_F+r"ms = ai_lua="+_F+r".*?\+ nonlua="+_F),
    "movedrill": re.compile(r"\[blitter movedrill\].*?qtree_reinsert="+_F+r"ms ground_requery="+_F+r"ms detector="+_F+r"ms math\+setpos\+notify="+_F+r"ms"),
}

# banner -> (regex group index, output key)
_FIELDS = {
    "a9split":   [(1, "a9"), (2, "update"), (3, "emit"), (4, "present")],
    "emitsplit": [(1, "emit"), (2, "emit_walk"), (3, "emit_blit")],
    "luasplit":  [(1, "update"), (2, "lua_vm"), (3, "eng_cpp")],
    "engcpp":    [(1, "eng_cpp"), (2, "ent_entities"), (3, "ent_hero"), (4, "ent_nonanim"),
                  (5, "ent_tileset"), (6, "ent_sound"), (7, "ent_other"), (8, "steps_fr"), (9, "per_step")],
    "entphase":  [(1, "enemy"), (2, "enemy_ai_lua"), (3, "enemy_nonlua")],
    "movedrill": [(1, "md_qtree"), (2, "md_ground"), (3, "md_detector"), (4, "md_math")],
}

_ENTTYPE_LINE = re.compile(r"\[blitter enttype\].*?n="+_F+r"/fr \|(.*)")
_ENTTYPE_PAIR = re.compile(r"(\w+)="+_F+r"ms\((\d+)\)")

# update-side leaves are amplified by the catch-up steps/fr; present+emit are per-frame.
_STEP_AMPLIFIED = {"lua_vm", "ent_entities", "ent_hero", "ent_nonanim",
                   "ent_tileset", "ent_sound", "ent_other"}
_LEAF_KEYS = ["present", "emit_walk", "emit_blit", "lua_vm",
              "ent_entities", "ent_hero", "ent_nonanim", "ent_tileset", "ent_sound", "ent_other"]

def parse_medians(text):
    acc = {}
    for banner, pat in _PATS.items():
        for m in pat.finditer(text):
            for gi, key in _FIELDS[banner]:
                acc.setdefault(key, []).append(float(m.group(gi)))
    return {k: statistics.median(v) for k, v in acc.items()}

def enttype_medians(text):
    acc = {}
    for line in _ENTTYPE_LINE.finditer(text):
        for name, ms, _cnt in _ENTTYPE_PAIR.findall(line.group(2)):
            acc.setdefault(name, []).append(float(ms))
    return {k: statistics.median(v) for k, v in acc.items()}

def rank_leaves(m):
    leaves = [(k, m[k], k in _STEP_AMPLIFIED) for k in _LEAF_KEYS if k in m]
    return sorted(leaves, key=lambda t: t[1], reverse=True)

def pick_lever(m, ent):
    leaves = rank_leaves(m)
    if not leaves:
        return "INSUFFICIENT DATA — no a9split/emitsplit/engcpp banners parsed"
    top = leaves[0][0]
    if top == "present":
        return ("present dominant -> overlay dirty-skip (don't re-upload the root when "
                "unchanged); FIRST attribute present via [blitter cvt] dyn_reup + poll_input")
    if top in ("emit_walk", "emit_blit"):
        return ("emit dominant -> z-sorted visible-entity cache (lever 1e) OR emit-walk "
                "collapse; use LD_PROFILE to disambiguate draw-retrieval/z-sort vs blit")
    if top == "lua_vm":
        return ("lua_vm dominant -> Lua-glue: HASFIELDCACHE safe-flip; confirm via "
                "LD_PROFILE userdata_has_field share")
    if top == "ent_entities":
        top_type = max(ent, key=ent.get) if ent else "?"
        if top_type == "enemy":
            return ("entities dominant, enemy top type -> enemy move-bookkeeping lever "
                    "(see [blitter movedrill]: qtree_reinsert / ground_requery / detector); "
                    "cross-check LD_PROFILE for quadtree get_elements straddling collision+z-sort")
        return (f"entities dominant, top type '{top_type}' -> {top_type} update lever; "
                "cross-check LD_PROFILE quadtree get_elements (collision vs z-sort retrieval)")
    if top == "ent_tileset":
        return "tileset dominant -> System::now anim-clock hoist (F4)"
    return f"{top} dominant -> inspect LD_PROFILE for the responsible function"

def main(argv):
    if len(argv) < 2:
        print("usage: a9_decompose.py <capture.log>", file=sys.stderr); return 2
    text = open(argv[1], encoding="utf-8", errors="replace").read()
    m, ent = parse_medians(text), enttype_medians(text)
    print(f"A9 total (median): {m.get('a9', float('nan')):.2f} ms | steps/fr={m.get('steps_fr', float('nan')):.2f}")
    print("\nA9 leaves (ms, sorted; *=step-amplified):")
    for name, ms, ampl in rank_leaves(m):
        print(f"  {ms:6.2f}  {name}{' *' if ampl else ''}")
    if ent:
        print("\nentities by type (ms):")
        for name in sorted(ent, key=ent.get, reverse=True):
            print(f"  {ent[name]:6.2f}  {name}")
    print(f"\nLEVER CANDIDATE: {pick_lever(m, ent)}")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
