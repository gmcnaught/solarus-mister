# Stage 5 (A9 track) — Measure-first A9 Lever — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the full A9 (host-CPU) cost drill on map 3 + map 119, commit a data-driven limiter verdict, so the single biggest A9 lever can be chosen from measurement — not assumed.

**Architecture:** Three concrete deliverables run in sequence: (1) a pure-Python A9-decomposition parser (TDD, runs in this worktree), (2) a device capture script that emits the *complete* banner drill + an LD_PROFILE function-level histogram, (3) a committed decision doc applying a deterministic fork rule. The lever code itself (Phase 3–4 of the spec) is **out of scope for this plan** and is authored as a follow-on plan once the verdict is committed — because the lever's files/tests/code are data-selected, and writing them now would either be a placeholder or pre-commit to a lever, violating the spec's anti-bias discipline.

**Tech Stack:** Python 3 (stdlib only — `re`, `statistics`, `sys`), bash, ssh/scp to the MiSTer device, the shipped `libsolarus.so.1.6.5` diag banners (no rebuild), glibc `LD_PROFILE`.

**Spec:** `docs/superpowers/specs/2026-07-22-stage5-a9-lever-measure-first-design.md`

## Global Constraints

- **No rebuild, no RBF, no `fpga/**` change.** Phase 1 uses the shipped engine + shipped `Solarus_20260722.rbf`. The full drill counters are already committed (`patches/series/{0009,0013,0022,0023}`).
- **Device IP** `192.168.20.81`; deploy root `/media/fat/games/solarus/`; logs to `/media/fat/logs/Solarus/` (NOT `/tmp` — wiped on restart).
- **One engine on the fabric only** — two `solarus-run` wedge the host. Leave `/media/fat/config/Solarus.s0` empty; launch via the `S0_FILE` override recipe (`solarus-two-engines-wedge-launch-recipe`).
- **Device contention** — this device is shared with the FPGA-track agent; Phase-1 capture needs exclusive device time and must be sequenced around that agent's runs.
- **Diag gate** — every banner is gated on `SOLARUS_BLITTER_DIAG=1`.
- **Anti-bias** — the decision doc (raw banners + parsed table + named limiter + one scoped lever) is committed **before** any lever code exists.
- **Never self-declare visual correctness** — irrelevant to Phases 1–2 (no rendering change), but the follow-on lever plan's final gate is the operator.
- **Python: stdlib only.** No pip installs on the device or in CI.
- Commit message trailer (per repo convention), on every commit:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and the `Claude-Session:` line.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `scripts/perf/a9_decompose.py` | Pure parser: raw banner log text → per-field medians → ranked A9 leaves → fork-rule lever candidate | 1 |
| `scripts/perf/test_a9_decompose.py` | Standalone-runnable unit tests over synthetic full-drill banner text | 1 |
| `scripts/perf/capture_a9_drill.sh` | Device capture: boot one engine, teleport to MAP/DEST, sample the COMPLETE banner stack standing + moving, ≥3 windows, commit raw log | 2 |
| `scripts/perf/README-stage5-a9.md` | Fixed spots (map 119 + map 3), the drive recipe, run instructions, the map-3-spot discovery method | 3 |
| `docs/superpowers/data/stage5-a9/*.txt` | Committed raw capture logs + parsed tables (Phase-1 output) | 4 |
| `docs/superpowers/2026-07-22-stage5-a9-decision.md` | Phase-2 verdict: per-scene A9 table, named limiter, one scoped lever | 5 |

---

## Task 1: A9 decomposition parser (TDD, pure Python, runs in this worktree)

**Files:**
- Create: `scripts/perf/a9_decompose.py`
- Test: `scripts/perf/test_a9_decompose.py`

**Interfaces:**
- Produces:
  - `parse_medians(text: str) -> dict[str, float]` — median of each numeric banner field across all `/60fr` windows in `text`. Keys include: `a9`, `update`, `emit`, `present`, `emit_walk`, `emit_blit`, `lua_vm`, `eng_cpp`, `ent_entities`, `ent_hero`, `ent_nonanim`, `ent_tileset`, `ent_sound`, `ent_other`, `steps_fr`, `per_step`, `enemy`, `enemy_ai_lua`, `enemy_nonlua`, `md_qtree`, `md_ground`, `md_detector`, `md_math`. Missing banners → key absent.
  - `enttype_medians(text: str) -> dict[str, float]` — per-EntityType update ms (e.g. `{"enemy": 7.0, "destructible": 2.1}`), median across windows.
  - `rank_leaves(m: dict) -> list[tuple[str, float, bool]]` — non-overlapping A9 leaves sorted ms-desc; the bool is `step_amplified` (True for update-side leaves, False for `present`/`emit_*`).
  - `pick_lever(m: dict, ent: dict) -> str` — the fork-rule lever candidate string.
  - `main(argv)` — read a log file path, print the table + verdict to stdout.

- [ ] **Step 1: Write the failing test**

Create `scripts/perf/test_a9_decompose.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/perf/test_a9_decompose.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'a9_decompose'` (module not created yet).

- [ ] **Step 3: Write the implementation**

Create `scripts/perf/a9_decompose.py`:

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 scripts/perf/test_a9_decompose.py`
Expected: `5 passed` (each `PASS test_*` line printed).

Also smoke-test the CLI against the real committed capture:
Run: `python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5/ab-enlarged-map119.txt`
Expected: prints an A9-leaves table (that file only carries `engcpp`+`a9split`, so `present`, `ent_entities`, etc. appear; `emit_walk`/`lua_vm`/enttype are absent) and a `LEVER CANDIDATE:` line — proves the parser degrades gracefully on a partial log.

- [ ] **Step 5: Commit**

```bash
git add scripts/perf/a9_decompose.py scripts/perf/test_a9_decompose.py
git commit -m "feat(stage5-a9): A9 banner-drill decomposition parser + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Task 2: Full-drill device capture script

**Files:**
- Create: `scripts/perf/capture_a9_drill.sh`
- Reference (do not modify): `scripts/perf/stage5_ab_cache.sh` (the A/B pattern), `scripts/perf/stage5_device_launch.sh` (the one-engine launch)

**Interfaces:**
- Consumes: `stage5_device_launch.sh` (launch), `a9_decompose.py` (post-process).
- Produces: a committed log `docs/superpowers/data/stage5-a9/drill-map${MAP}-${TAG}.txt` containing the COMPLETE banner stack for standing + moving, and the `a9_decompose.py` table appended.

**Why a new script:** `stage5_ab_cache.sh` greps only `timing hwperf p0 comp resident engcpp a9split` and only a **standing** window. This task's script adds the deep drill banners (`emitsplit luasplit drawcat enttype entphase entsplit movedrill cvt`) AND a **moving** window (held DOWN), and captures more windows for the reproducibility gate.

- [ ] **Step 1: Write the script**

Create `scripts/perf/capture_a9_drill.sh`:

```bash
#!/usr/bin/env bash
# Stage 5 (A9 track) Phase 1 — full A9 banner drill on ONE map, STANDING + MOVING.
# Rebuild-free: the shipped engine emits every banner under SOLARUS_BLITTER_DIAG=1.
# Usage: MAP=119 DEST=from_dungeon_10 TAG=map119 scripts/perf/capture_a9_drill.sh
#        MAP=3   DEST=<pick>          TAG=map3   scripts/perf/capture_a9_drill.sh
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
RBF="${RBF:-Solarus_20260722.rbf}"          # current ship (enlarged P_SRC cache)
MAP="${MAP:?set MAP=3|119}"; DEST="${DEST:?set DEST=<teleport destination>}"
TAG="${TAG:?set TAG=map3|map119}"
LOG=/media/fat/logs/Solarus/stage5-a9.log
FIFO=/tmp/sol_in
OUTDIR="docs/superpowers/data/stage5-a9"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/drill-${TAG}.txt"
# The COMPLETE A9 drill stack (superset of stage5_ab_cache.sh).
BANNERS="timing hwperf p0 resident cvt a9split emitsplit luasplit engcpp drawcat enttype entphase entsplit movedrill"

# One engine on the fabric (RBF swapped into the shared launch script).
sed -e "s#Solarus_20260721.rbf#${RBF}#g" -e 's#stage5-boot.log#stage5-a9.log#g' \
    "$(dirname "$0")/stage5_device_launch.sh" > /tmp/_a9_launch.sh
scp -q /tmp/_a9_launch.sh "$HOST:/tmp/a9_launch.sh"
ssh "$HOST" "sh /tmp/a9_launch.sh" >/dev/null 2>&1 &
sleep 20   # boot + fabric settle

# start save + teleport to target
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 7
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"$MAP\",\"$DEST\")\n' > $FIFO"
sleep 8

# confirm map
CUR=""
for _ in 1 2 3 4 5; do
  ssh "$HOST" "printf 'print(\"CURMAP_NOW=\"..sol.main.game:get_map():get_id())\n' > $FIFO" 2>/dev/null || true
  sleep 2
  CUR=$(ssh "$HOST" "grep -ao 'CURMAP_NOW=[0-9]*' $LOG | tail -1" 2>/dev/null || true)
  [ -n "$CUR" ] && break
done

grab() {  # $1 = state label; tail 5 windows/banner so >=3 clean are available
  echo "### A9 DRILL  TAG=$TAG  RBF=$RBF  map=$MAP  state=$1  ($CUR)"
  for b in $BANNERS; do
    echo "--- [blitter $b] (last 5) ---"
    ssh "$HOST" "grep -E \"\\[blitter $b\\]\" $LOG | tail -5" 2>/dev/null || true
  done
}

# STANDING: idle ~14s so counters stabilise (>=3 60-frame windows land).
sleep 14
{ grab standing; } | tee "$OUT"

# MOVING: hold DOWN (0x04 on 0x3A000008) for ~14s, then release.
ssh "$HOST" "for i in \$(seq 1 700); do busybox devmem 0x3A000008 32 0x04; sleep 0.02; done" &
sleep 14
ssh "$HOST" "busybox devmem 0x3A000008 32 0x00" || true
{ grab moving; } | tee -a "$OUT"

echo "--- engine alive? ---" | tee -a "$OUT"
ssh "$HOST" "pidof solarus-run >/dev/null && echo ALIVE || echo DEAD" | tee -a "$OUT"
echo "captured -> $OUT"
```

- [ ] **Step 2: Verify the script is syntactically clean**

Run: `bash -n scripts/perf/capture_a9_drill.sh && shellcheck scripts/perf/capture_a9_drill.sh`
Expected: `bash -n` silent (exit 0). shellcheck: no errors (the repo shellcheck-cleans perf scripts — `805661b`). If shellcheck flags the `for i in $(seq ...)` word-splitting or unused `i`, fix with `# shellcheck disable=SC2034` on the loop or `_i`, matching how `stage5_ab_cache.sh` handles it.

- [ ] **Step 3: Confirm the banner list is complete vs the source**

Run: `for b in timing hwperf a9split emitsplit luasplit engcpp drawcat enttype entphase entsplit movedrill cvt; do grep -q "\[blitter $b\]" patches/mister/mister_blitter_renderer.cpp && echo "ok $b" || echo "MISSING $b"; done`
Expected: every line `ok <b>` — proves each banner the script greps is actually emitted by the shipped renderer (guards against grepping a banner that never prints → silent empty capture).

- [ ] **Step 4: Commit**

```bash
git add scripts/perf/capture_a9_drill.sh
git commit -m "feat(stage5-a9): full-drill device capture (standing+moving, all banners)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Task 3: README — fixed spots + map-3 discovery method

**Files:**
- Create: `scripts/perf/README-stage5-a9.md`
- Reference: `scripts/perf/README-stage5.md` (the map-119 spot, reused verbatim)

**Interfaces:**
- Produces: the documented reproducible drive for both maps + the method to finalize the map-3 spot on-device (the spot itself is discovered in Task 4).

- [ ] **Step 1: Write the README**

Create `scripts/perf/README-stage5-a9.md`:

```markdown
# Stage 5 (A9 track) — full A9-drill capture

Rebuild-free A9 cost attribution on the two A9-bound scenes. Uses the SHIPPED engine
+ `Solarus_20260722.rbf`; every banner is emitted under `SOLARUS_BLITTER_DIAG=1`.

## Fixed spots

- **map 119** (parallax overworld): save1.dat, teleport `from_dungeon_10`. Moving = hold
  DOWN. (Identical to `README-stage5.md`, so A9 numbers line up with the fabric A/B.)
- **map 3** (pattern worst-case interior, per `solarus-quest-tilemap-census`): spot TBD —
  finalize on-device (see "Choosing the map-3 spot"), then record the exact
  `DEST` here so future A/B is byte-reproducible.

## Run

Sequence around the FPGA-track agent — only ONE engine may run on the fabric.

    MAP=119 DEST=from_dungeon_10 TAG=map119 bash scripts/perf/capture_a9_drill.sh
    MAP=3   DEST=<chosen>        TAG=map3   bash scripts/perf/capture_a9_drill.sh

Each run writes `docs/superpowers/data/stage5-a9/drill-<TAG>.txt` with STANDING then
MOVING windows for the full banner stack. Post-process:

    python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map119.txt

## Choosing the map-3 spot

`sol...:teleport("3","<dest>")` needs a destination that exists on map 3. List them from
the quest, or teleport to map 3's default entrance and confirm via the `CURMAP_NOW=3`
echo the capture script already prints. Pick a standing spot that renders map 3's dense
pattern set (the worst-case tilemap) with the hero idle. Record the chosen `DEST` above
and in the decision doc.

## Reproducibility gate

Two independent runs at the same spot must agree within window jitter. The capture tails
5 windows/banner so >=3 clean 60-frame windows are available for the median.
```

- [ ] **Step 2: Verify links resolve**

Run: `ls scripts/perf/README-stage5.md scripts/perf/capture_a9_drill.sh scripts/perf/a9_decompose.py`
Expected: all three paths exist (the README references them).

- [ ] **Step 3: Commit**

```bash
git add scripts/perf/README-stage5-a9.md
git commit -m "docs(stage5-a9): capture README + fixed spots + map-3 discovery method

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Task 4: Phase-1 capture execution (device runbook) — produces the data

> **This task runs on hardware.** It has no unit test — its "test" is the reproducibility gate and the `[blitter hwperf]` bound verdict. Requires exclusive device time (coordinate with the FPGA-track agent). If the device is unavailable, this task blocks; Tasks 1–3 and 5's template do not.

**Files:**
- Create (committed output): `docs/superpowers/data/stage5-a9/drill-map119.txt`, `docs/superpowers/data/stage5-a9/drill-map3.txt`
- Create (committed output): `docs/superpowers/data/stage5-a9/decompose-map119.txt`, `docs/superpowers/data/stage5-a9/decompose-map3.txt`

- [ ] **Step 1: Confirm the shipped engine + RBF are on the device**

Run:
```bash
ssh root@192.168.20.81 'sha1sum /media/fat/games/solarus/solarus-run /media/fat/games/solarus/libs/libsolarus.so.1.6.5; ls /media/fat/_Other/Solarus_20260722.rbf'
```
Expected: the `libsolarus.so.1.6.5` sha1 matches the current build, and `Solarus_20260722.rbf` exists. If the device holds a stale engine (the Stage-5 decision doc hit exactly this), redeploy first: `./deploy.py --no-rbf` and re-verify the sha1.

- [ ] **Step 2: Capture map 119 (standing + moving)**

Run: `MAP=119 DEST=from_dungeon_10 TAG=map119 bash scripts/perf/capture_a9_drill.sh`
Expected: `docs/superpowers/data/stage5-a9/drill-map119.txt` written, ends `ALIVE`, and `state=standing (CURMAP_NOW=119)`. Every `--- [blitter <b>] (last 5) ---` section is non-empty for `a9split engcpp emitsplit luasplit` (the core split) and for `enttype entphase movedrill` (proves the deep drill counters are live in the shipped engine).

- [ ] **Step 3: Choose + capture the map-3 spot**

Discover a valid map-3 destination (per README §"Choosing the map-3 spot"), then:
Run: `MAP=3 DEST=<chosen> TAG=map3 bash scripts/perf/capture_a9_drill.sh`
Expected: `drill-map3.txt` written, `CURMAP_NOW=3`, `ALIVE`. Record the chosen `DEST` back into `README-stage5-a9.md` (edit + amend Task 3's commit or a fresh commit).

- [ ] **Step 4: Reproducibility gate — re-run each map once and diff**

Run each capture a second time to a temp tag and compare the A9 medians:
```bash
MAP=119 DEST=from_dungeon_10 TAG=map119-r2 bash scripts/perf/capture_a9_drill.sh
python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map119.txt
python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map119-r2.txt
```
Expected: the two runs' `A9 total` and top-3 leaves agree within window jitter (the `[blitter timing] jitter=` magnitude). If they diverge widely, the spot isn't settling — extend the pre-sample `sleep` and re-run before trusting the numbers.

- [ ] **Step 5: Post-process + commit the data**

Run:
```bash
python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map119.txt > docs/superpowers/data/stage5-a9/decompose-map119.txt
python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map3.txt   > docs/superpowers/data/stage5-a9/decompose-map3.txt
git add docs/superpowers/data/stage5-a9/
git commit -m "data(stage5-a9): captured full A9 drill + decomposition, map 3 + map 119

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Task 5: Phase-2 decision doc (the verdict — committed BEFORE any lever code)

**Files:**
- Create: `docs/superpowers/2026-07-22-stage5-a9-decision.md`
- Reference: `docs/superpowers/2026-07-21-stage5-decision.md` (the fabric-track decision doc — same format), the spec §4 fork-rule table.

**Interfaces:**
- Consumes: the Task-4 data + `a9_decompose.py` `LEVER CANDIDATE:` output.
- Produces: a committed verdict naming the limiter for each scene and scoping exactly ONE lever, with its expected magnitude — the input to the follow-on Phase 3–4 plan.

- [ ] **Step 1: (Optional, only if banners are ambiguous) LD_PROFILE cross-check**

The banner taxonomy cannot cleanly separate quadtree cost spent in *collision* (update side) from quadtree cost spent in the *z-sorted draw-retrieval* (draw side) — both live in `Quadtree::get_elements`. If Task-4 shows `ent_entities` OR `emit_walk` as the top leaf, run the LD_PROFILE function-level histogram (rebuild-free — glibc env feature over `libsolarus.so`), symbolized by the existing tool, to attribute it:
```bash
# mechanism documented in docs/superpowers/2026-07-07-gprof-attribution.md
python3 scripts/sprof_parse.py <captured .profile>
```
Expected: a flat function list; note the `Quadtree::get_elements` / z-sort / `userdata_has_field` shares. Skip this step if a `present`/`tileset`/`lua_vm` leaf already dominates unambiguously.

- [ ] **Step 2: Write the decision doc**

Create `docs/superpowers/2026-07-22-stage5-a9-decision.md` with these sections (fill the bracketed values from Task 4 / Step 1 — this is the artifact, so the numbers are real, not placeholders):

```markdown
# Stage 5 (A9 track) — map 3 + map 119 A9 limiter decision

**Date:** 2026-07-22
**Engine:** libsolarus.so.1.6.5 sha1 <from Task 4 Step 1>  RBF Solarus_20260722.rbf
**Scenes:** map 119 (save1, teleport from_dungeon_10) ; map 3 (save1, teleport <chosen DEST>)
**Raw:** docs/superpowers/data/stage5-a9/drill-map{119,3}.txt ; decompose-map{119,3}.txt

## Per-scene A9 decomposition (median of >=3 windows)

### map 119
- standing: <paste a9_decompose.py table — A9 total, ranked leaves, entities-by-type>
- moving:   <paste>  (delta vs standing exposes draw/scroll churn)
- [blitter hwperf] verdict: <A9 | FABRIC>  (is it actually A9-bound HERE, this run?)

### map 3
- standing: <paste>
- moving:   <paste>
- hwperf verdict: <A9 | FABRIC>

## Verdict — fork rule applied
- Biggest A9 leaf, map 3: <name> (<ms>, <fixed|step-amplified>)
- Biggest A9 leaf, map 119: <name> (<ms>, ...)
- a9_decompose LEVER CANDIDATE: <string>
- LD_PROFILE cross-check (if run): <function-level attribution>

**Named limiter:** <the one A9 sub-cost that dominates the two scenes>
**Leverage note:** <per-tick (super-linear via steps/fr) vs per-frame (linear)>

## The ONE lever (scoped)
**<lever name>** — <what it changes, behaviour-neutral, gated SOLARUS_<FLAG> default-off>
- Expected magnitude: <ms/frame, and predicted fps move given steps/fr>
- Files it will touch: <engine-side patches/series OR renderer-side patches/mister>
- Known correctness trap to TDD: <z-order-stale | metatable-mutation | invalidation gap>
- Moving-state caveat: <does it still pay while the camera scrolls?>

## Deferred (NOT this stage)
<the runner-up levers; one-lever discipline>
```

- [ ] **Step 3: Sanity-check the verdict against the data**

Run: `python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map3.txt`
Expected: the `LEVER CANDIDATE:` line printed matches the "a9_decompose LEVER CANDIDATE" quoted in the doc (the doc must not contradict the tool). If map 119's `hwperf` verdict is still FABRIC that run, the doc must say so and lean on map 3 for the decision (per spec §6).

- [ ] **Step 4: Commit (this is the anti-bias gate — no lever code exists yet)**

```bash
git add docs/superpowers/2026-07-22-stage5-a9-decision.md
git commit -m "decide(stage5-a9): A9 limiter verdict + one scoped lever (pre-code)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t"
```

---

## Phase 3–4 Handoff (out of scope for this plan — by design)

Once Task 5 commits the verdict, **re-invoke `superpowers:writing-plans`** to author the lever's implementation plan. It is deliberately not written here: the lever's files, tests, and code are selected by the Task-5 data, and pre-writing them would violate the spec's anti-bias discipline (spec §4, §7). The follow-on plan takes the decision doc's "The ONE lever (scoped)" block as its spec and follows the spec's Phase 3–4:

- Gated `SOLARUS_<LEVER>` env flag, default-off (`=0` = exact prior behaviour).
- TDD the pure logic — **especially the invalidation path** (the z-order-stale class that bit DRAWCACHE in patch `0028`; the HASFIELDCACHE metatable-mutation gap) — as a host test in `tests/run_tests.sh`.
- `-std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO` type-check (both `-D` mandatory, per CLAUDE.md), then armhf Docker build (`scripts/build_engine.sh`).
- `./deploy.py --no-rbf` → HW A/B at the identical map 3 + map 119 spots (flag off vs on, same drive) → operator visual gate (never self-declared).
- Regression guard: flag-off reproduces the Task-4 baseline (no-op proof).

---

## Self-Review

**Spec coverage:**
- Spec §3 Phase 1 (Capture, rebuild-free, full banner stack, standing+moving, both maps, reproducibility, bounded present-escalation) → Tasks 2, 3, 4 (+ the parser in Task 1). ✓
- Spec §3 Phase 2 (deterministic fork rule, decision doc committed before code) → Task 5 (+ `pick_lever` in Task 1). ✓
- Spec §3 Phases 3–4 (the lever, gated, host-test, HW A/B, operator gate) → Handoff section (deferred by design; the spec's anti-bias clause §4/§7 requires the verdict first). ✓
- Spec §4 component boundaries (capture harness / decomposition / decision doc / lever) → Tasks 2 / 1 / 5 / Handoff. ✓
- Spec §6 risks: device contention (Task 4 preface + README + Global Constraints), F1 common-mode (noted in decision-doc template + spec), map-119-still-fabric (Task 5 Step 3), scrolling-defeats-caches (Task 2 moving window + decision-doc "moving-state caveat"). ✓
- Spec §7 open items: map-3 spot (Task 3 method + Task 4 Step 3), pre-land `-lua-console=no` (left as a separate concern per one-lever discipline — noted, not folded in), present probe (bounded-escalation, Task 4/Step-1-of-5 elimination first), exact lever (Task 5). ✓

**Placeholder scan:** the only bracketed `<...>` values are inside the Task-5 decision-doc *template* — that document's content is genuinely data-derived and produced at execution, which is the correct place for real numbers. All executable steps (Python, bash, commands) contain complete, runnable content. No "TBD/handle edge cases/similar to Task N".

**Type consistency:** `parse_medians`/`enttype_medians`/`rank_leaves`/`pick_lever`/`main` signatures match between Task-1 tests and implementation; the banner keys used in tests (`present`, `ent_entities`, `lua_vm`, `md_qtree`, `steps_fr`) exactly match `_FIELDS`/`_LEAF_KEYS`. The capture script's `$BANNERS` list is a superset of the parser's regex banners (Task 2 Step 3 asserts each is emitted by the renderer).
```
