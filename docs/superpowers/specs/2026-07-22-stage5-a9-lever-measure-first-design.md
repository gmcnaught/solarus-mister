# Stage 5 (A9 track) — Measure-first A9 lever — design

**Date:** 2026-07-22
**Status:** design approved (brainstorm) → spec review → implementation plan
**Branch:** `worktree-stage5-a9-lever-plan` (off `origin/master` @ `9a55f71`)
**Track:** the **host / A9** performance axis, run in parallel with — and independent
of — the FPGA/fabric track (`feat/stage5-phase2-fb-ddr3`, another agent). This spec
touches **no** `fpga/**` and produces **no** new RBF.

---

## 1. Goal

Land the **single biggest A9-side (host CPU) lever** for the two scenes that now
register A9-bound — **map 3** (pattern worst-case interior) and **map 119**
(parallax overworld) — HW-validated and gated default-off. The lever is **chosen
from captured data on those two scenes, not assumed** from a different scene's
profile.

Deliberately narrow, matching the proven Stage-5 discipline: **one scene-set, one
decision, one lever.** A measured win over breadth.

### Non-goals
- No fabric / RTL / Quartus change and no new RBF — that is the other agent's track.
- No scanout change (the direct `comp_fbram` path stays; memory
  `solarus-scanout-avoid-ascal-direct-path`).
- No second lever this stage. If the capture surfaces two candidates, land only the
  highest-leverage one; the rest are follow-up stages.
- No broad multi-scene survey — map 3 + map 119 only (plus the town/village LD_PROFILE
  data already on file as cross-reference).

---

## 2. Why now, and what the existing data already says

The FPGA track's Stage-5 Phase-1 source-cache enlargement (`SRC_BLOCKS=128`, shipped
`Solarus_20260722.rbf`) cut the fetch-bound compositor ~3.66× on map 119 and flipped
map 1 **FABRIC → A9-bound** (`docs/superpowers/2026-07-22-stage5-source-cache-hw-validation.md`).
As the fabric cost keeps falling, the **A9 becomes the limiter** on more scenes — which
is what this track attacks.

### What the banners + LD_PROFILE already establish

The `[blitter a9split]` "lua" field is a **misnomer**: per `patches/mister/mister_lua_prof.h:5`
it measures the **whole `update()` tick** (C++ engine work + Lua callbacks), which
`[blitter luasplit]` then splits into `lua_vm` + `eng_cpp`. So the A9 cost is
**C++ engine work, not the Lua VM.**

**Map 119 standing, current ship (`Solarus_20260722.rbf`)** —
`docs/superpowers/data/stage5/ab-enlarged-map119.txt`, A9 = 21.3 ms @ 19.9 fps:

| A9 bucket | ms | Step-amplified (steps/fr ≈ 5.0)? | Composition |
|---|---:|---|---|
| update tick (`a9split` "lua") | 11.3 | yes | eng_cpp 8.7 (**entities 4.0**, sound 1.2, tileset 1.0, hero 0.8, other 1.6) + lua_vm ~2.6 |
| present | 6.0 | **no (fixed / frame)** | overlay-composite ARGB4444 upload + `mister_poll_input` + submit doorbell + resident finalize |
| emit | 4.0 | partial | draw-walk + per-blit emit |

**Village "heavy town", LD_PROFILE function-level attribution** (the authoritative
"where does A9 time go" capture — `docs/superpowers/2026-07-07-gprof-attribution.md`,
A9 30–33 ms @ 25–27 fps):

| Subsystem | est. ms/frame | Note |
|---|---:|---|
| **Quadtree `get_elements` + Z-order sort/unique family** | **~6.6** | **#1.** Straddles collision queries **and** the once-per-frame z-sorted visible-entity retrieval in `Entities::draw`; the latter is pure waste when the camera is static. |
| Lua boundary / glue | ~4.8 | `userdata_has_field` ×3 ≈ 2.0 ms |
| Entity update walk (non-quadtree) | ~3.4 | |
| Emit / renderer glue | ~2.4 | |
| Tileset / animated tiles | ~1.9 | `System::now` anim clock |
| Collision / ground / detectors | ~1.3 | |
| Pixel-precise collision | ~1.1 | invisible to every banner |

### Levers already shipped (do not re-propose)

Default-**ON**, HW-validated: `SOLARUS_IDLEPARK` (+57 % fps alone), `STATICPARK`,
`DRAWCACHE`, `FASTPACE`, `QTREE_MARGIN=8` (fat-AABB, −70 % reinserts), `AUDIO_THREAD`,
`CULL_MARGIN=64`, opaque-blit fast-path. The cheap enemy/quadtree-churn wins are
largely **already taken** (combined soak: per-step engine cost 5.2 → 1.3–2.9 ms).

Opt-in / default-**OFF** (correctness gaps, A/B only): `HASFIELDCACHE`
(~1.5–2 ms, blocked on a metatable-mutation invalidation gap), `GROUNDCACHE` (~0.7 ms),
`IDLESKIP` (superseded), `GRIDOV` (fabric, perf-neutral).

### The biggest *un-built* prize, and why we still measure first

The gprof doc names **lever 1e — a z-sorted visible-entity-list cache** — "the biggest
single per-frame prize," ~2.5–3.5 ms of standing-frame waste, **distinct from
DRAWCACHE** (which caches the visible *list* but the z-sort family still runs inside
the quadtree retrieval). That is the working prior for "the lever."

But the ~6.6 ms / lever-1e numbers are from the **town** scene, not map 3 or map 119.
For map 119 the whole `entities` bucket is only 4.0 ms and is **not** type-attributed
in the saved logs; map 3 has **no** A9 drill captured at all. A wrong pick costs an
armhf build + a HW A/B cycle + operator time. Hence: **capture the two named scenes,
commit the verdict, then choose.**

---

## 3. Architecture — four gated phases

Each phase hard-gates the next. Mirrors the Stage-5 rebaseline template
(`specs/2026-07-21-stage5-perf-rebaseline-design.md`), retargeted from fabric to A9.

```
Phase 1  Capture    full A9 drill on map 3 + map 119, standing+moving, current ship (NO rebuild)
Phase 2  Decide     fork rule → name biggest A9 sub-cost → scope ONE lever → commit decision doc BEFORE code
Phase 3  Implement  the lever, SOLARUS_<LEVER> default-off, host-test + type-check + armhf build
Phase 4  Validate   deploy --no-rbf → HW A/B same spots → operator visual gate (behaviour-neutral)
```

### Phase 1 — Capture (host-only, existing RBF + existing engine, NO rebuild)

**Rebuild-free by construction.** The complete drill is already compiled into the
shipping `libsolarus.so.1.6.5` via the committed patch series — the eng_cpp
sub-timers (`g_me_upd_entities_ns`/`_hero_ns`/`_tileset_ns`/`_sound_ns`, `g_me_steps`;
patches 0009/0013/0022/0023), the per-type counters (`g_me_ent_type_ns[]`), and the
enemy nonlua phase split (`g_me_enemy_lua_ns`, entsplit `t_ent_*_prev`). Enabling
`SOLARUS_BLITTER_DIAG=1` prints all of them. The earlier A/B captures merely *filtered*
these banner lines out; the counters are live.

**Capture the complete banner stack** (not the filtered A/B subset):

| Banner | Field(s) used |
|---|---|
| `[blitter timing]` | fps, period, fabric, **A9**, sleep, pipeline_ceiling |
| `[blitter hwperf]` | fabric_hw, comp, **A9-or-fabric verdict** (context: is the scene truly A9-bound here?) |
| `[blitter a9split]` | A9 = update + emit + present |
| `[blitter emitsplit]` | emit = walk + blit |
| `[blitter luasplit]` | update = lua_vm + **eng_cpp** |
| `[blitter engcpp]` | eng_cpp = entities + hero + nonanim + tileset + sound + other; **steps/fr, per_step** |
| `[blitter enttype]` | per-EntityType update ms (which kind of entity — enemy? npc? dynamic_tile?) |
| `[blitter entphase]` | enemy = ai_lua (throttle-only) + nonlua (move/collision) |
| `[blitter entsplit]` | enemy nonlua = sprite + move(integ) + state + collision + obstacle + qtree + ground |
| `[blitter drawcat]` | anim_tiles/fr vs entities/fr (are the draws tiles or sprites?) |

**Scenes & states:**
- **map 119** — fixed spot already defined: save1, teleport `from_dungeon_10`.
- **map 3** — a fixed reproducible teleport spot must be chosen during harness
  bring-up (open item §7); pick one that exercises map 3's pattern worst-case
  (max distinct patterns per `solarus-quest-tilemap-census`).
- Each scene captured **standing** (isolates per-tick engine cost) **and moving**
  (held direction → adds camera-scroll; the standing→moving delta reveals emit/sim
  churn and, critically, whether a draw-retrieval cache can help while the camera
  moves — it may only pay when standing).
- ≥ 3 clean 60-frame windows per (scene, state), same spot; two independent runs must
  agree within window jitter (reproducibility gate).

**Present-bucket attribution — bounded escalation.** The `present` residual (~6 ms,
non-amplified) has no dedicated sub-banner; it is `A9 − update − emit`. Attribute it
by elimination against the known present-path work (overlay ARGB4444 re-upload seen in
`[blitter cvt] dyn_reup`, `mister_poll_input`, the submit doorbell). **Only if**
`present` is the dominant bucket **and** elimination is ambiguous do we add a small
bracket probe (a one-off rebuild); otherwise Phase 1 stays rebuild-free.

**Deliverable:** raw logs committed under `docs/superpowers/data/stage5-a9/`, plus a
per-(scene,state) A9 decomposition table.

### Phase 2 — Decide (deterministic fork rule; committed BEFORE any lever code)

Applied to the **standing** numbers of each map, with the **moving** delta as
tiebreak, using the drill's *deepest attributable* bucket:

| Dominant A9 sub-cost (from the drill) | The lever (Phase 3) | Est. | Nature |
|---|---|---:|---|
| **Draw-retrieval / z-sort** family (camera-static re-sort waste; `drawcat`+quadtree signal) | **z-sorted visible-entity cache (lever 1e)** — cache the sorted visible set; invalidate on entity add/remove/z-change/camera-move (DRAWCACHE-adjacent) | 2.5–3.5 | per-frame, behaviour-neutral |
| **Lua-glue** (`userdata_has_field`) | **`HASFIELDCACHE` safe-flip** — add the missing metatable-mutation invalidation hook, then default-on | 1.5–2 | per-tick |
| **`entities` nonlua** move-bookkeeping (entsplit: qtree / ground / obstacle) | residual enemy levers — `GROUNDCACHE` safe-flip, obstacle-test prune | modest (QTREE_MARGIN took the big share) | per-tick, step-amplified |
| **`present`** (overlay re-upload) | **overlay dirty-skip** — don't re-upload the root when it did not change | ≤ overlay share | per-frame |
| **`emit`** walk | emit-walk collapse | ~ | per-frame |
| **`tileset`** (anim clock) | `System::now` hoist (F4) | ~ | per-tick |

**Leverage tiebreak.** Per-tick (update) costs get the super-linear catch-up bonus
(fewer catch-up steps ⇒ higher fps ⇒ fewer steps); per-frame (present/emit/draw)
costs are linear. Between two candidates of similar ms, prefer the per-tick one —
**unless** the moving-state capture shows a draw-cache is defeated by scrolling, in
which case discount it accordingly.

**Anti-bias discipline.** The decision doc — raw banners, the per-scene A9 table, the
named limiter, and the one selected lever with its expected magnitude — is committed
**before** any lever code, so the measurement is not retrofitted to justify a
pre-picked lever. Working prior is **1e**, but the data rules.

### Phase 3 — Implement (host branch)

New `SOLARUS_<LEVER>` env flag, **default-off**, wired via the existing `mister_flag_*`
convention. `=0` is a true no-op / exact prior behaviour, so the ship default is
unchanged until HW-proven and the A/B is clean.

Chain: TDD the pure logic (cache invalidation / correctness) as a host test in
`tests/run_tests.sh` → `-std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`
type-check (the two `-D` flags are mandatory — the renderer body is `#ifdef
MISTER_NATIVE_VIDEO`, per CLAUDE.md) → armhf Docker build (`scripts/build_engine.sh`).

If the lever is engine-side (`libsolarus` — e.g. 1e touches `Entities`/`Quadtree`,
HASFIELDCACHE touches `LuaContext`), it is a **patch-series** change
(`patches/series/*.patch`); if renderer-side (overlay dirty-skip, emit-walk), it is a
**whole-file** edit under `patches/mister/`. `grep <symbol> patches/series/0001*.patch`
to confirm which before touching.

### Phase 4 — Validate

`deploy.py --no-rbf` (engine only; the RBF is unchanged) → HW A/B at the identical
map 3 + map 119 spots (flag off vs on, same drive) → the selected metric must move in
the predicted direction and fps/period must improve → **operator visual gate**
(behaviour-neutral: same movement/AI/render at normal speed). Repo rule holds: **never
self-declare visual correctness** — the operator is the final gate
(`solarus-no-self-declared-visual-validation`).

**Regression guard:** flag-off must reproduce the Phase-1 baseline numbers (proves
`=0` is a true no-op).

---

## 4. Component boundaries

| Unit | Responsibility | Interface | Depends on |
|---|---|---|---|
| **Capture harness** (`scripts/perf/`, extend the Stage-5 scripts) | boot map 3 + map 119 reproducibly, drive standing+moving, collect the full banner stack | in: quest + teleport target + direction; out: raw banner logs | safe single-engine launch, `-lua-console` FIFO harness, existing diag banners |
| **A9 decomposition** (host post-process) | turn the banner stack into a per-(scene,state) A9 table | in: raw logs; out: A9 table + limiter candidate | Phase-1 logs only |
| **Decision doc** (`docs/superpowers/`) | apply the fork rule, name the limiter, scope one lever | in: the A9 table; out: committed verdict + lever scope | Phase-2 data only |
| **The lever** (host; engine-side or renderer-side, TBD by Phase 2) | the one behaviour-neutral optimization | gated `SOLARUS_<LEVER>`; `=0` = exact prior behaviour | its build/test chain |

Each independently testable: harness by "does it reach map 3 / map 119 and emit the
full stack"; decomposition by a synthetic banner set; decision by the committed data;
lever by its host test + HW A/B.

---

## 5. Testing strategy

- **Phase 1:** reproducibility — two runs at the same spot agree within jitter; the
  `[blitter hwperf]` verdict confirms the scene is actually A9-bound *there* (guards
  against profiling a still-fabric-bound capture and misattributing).
- **Phase 2:** the fork rule is deterministic given the numbers; the doc is the artifact.
- **Phase 3:** pure-logic host test (TDD) for the lever's correctness — especially any
  cache-invalidation path (the z-order-stale class that bit DRAWCACHE in patch 0028,
  and the HASFIELDCACHE metatable-mutation gap, are the known traps); `-std=c++17`
  type-check; armhf build links.
- **Phase 4:** HW A/B shows the predicted metric move + fps delta at both spots;
  operator visual gate; flag-off reproduces baseline (no-op proof).

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Device contention** — only one engine on the fabric ("two engines wedge the host", `solarus-two-engines-wedge-launch-recipe`); Phase 1 needs exclusive device time | sequence Phase 1 around the other agent's FPGA runs; safe launch recipe (empty `Solarus.s0`, one engine, `S0_FILE` override, log to `/media/fat/logs/Solarus/`). Hard dependency, not a blocker. |
| **Harness self-pollution (F1)** — the `-lua-console` FIFO drive triggers the stdin busy-poll that eats an A9 core, inflating absolute A9 numbers | the **A/B delta is clean** — flag-off and flag-on run the *same* harness, so F1 is a common-mode offset that cancels in the delta. Note the absolute inflation in the decision doc; optionally land `-lua-console=no` capture-hygiene separately (F1 is itself a real ship win). |
| **map 119 still marginally FABRIC-bound on current ship** (`fabric_hw` 26.78 > A9 21.4) → its A9-lever fps payoff is partly gated on the other agent's Phase-2 | capture **both** map 3 (cleaner A9 read) and map 119; let map 3 anchor the decision if map 119's verdict is FABRIC that day. Record the verdict per-scene. |
| **Scrolling defeats draw-caches** — a z-sort/draw cache may only pay when the camera is static | the moving-state capture explicitly measures this; the fork rule discounts a draw-cache lever whose moving-state benefit is ~0. |
| **Wrong lever picked → wasted build** | the whole measure-first structure exists to prevent this; the decision doc gates the build. |
| **Self-declared visual correctness** | operator-gated final check, per repo rule. |
| **Cache-invalidation correctness bug** (the recurring class) | TDD the invalidation as a host test before the armhf build; explicitly cover the known traps (z-order-stale, metatable-mutation). |

---

## 7. Open items (resolve during planning / execution)

- **Fixed map-3 teleport spot** (destination + held direction) — pick during Phase-1
  harness bring-up; record it in the decision doc for future A/B reproducibility.
- **Whether to pre-land `-lua-console=no` (F1)** as a capture-hygiene step before
  Phase 1, or accept the common-mode offset and note it. (F1 is a real ship win either
  way; keeping it out of *this* lever's scope preserves the one-lever discipline.)
- **The precise lever** — intentionally left to Phase 2; it is data-selected, not
  pre-decided. Working prior: lever 1e (z-sorted visible-entity cache).
- **Present-bucket probe** — build only under the bounded-escalation clause (§3
  Phase 1).

## References

- `specs/2026-07-21-stage5-perf-rebaseline-design.md` — the fabric-track template this mirrors (four gated phases, anti-bias decision doc, leverage model).
- `docs/superpowers/2026-07-07-gprof-attribution.md` — the authoritative LD_PROFILE function-level A9 attribution (quadtree/z-sort #1; lever 1e = biggest un-built prize).
- `docs/superpowers/2026-07-22-stage5-source-cache-hw-validation.md` — the fabric Phase-1 that flips scenes to A9-bound; `data/stage5/ab-enlarged-map119.txt` (current-ship map 119 A9 = 21.3 ms breakdown).
- `docs/superpowers/2026-07-21-stage5-decision.md` — map 119 pre-cache A9 = 32.2 ms breakdown + the `a9split`-"lua"-is-really-`update` clarification.
- `patches/mister/mister_lua_prof.h` — proves `a9split` "lua" = whole `update()` tick; the eng_cpp/enemy drill counter contract.
- `patches/mister/mister_blitter_renderer.cpp` (~3630–3800) — the full banner stack; `patches/series/{0009,0013,0022,0023}` — the drill counters are committed (Phase 1 is rebuild-free).
- Memories: `solarus-enemy-per-update-cost-simd` (enemy move-bookkeeping, SIMD refuted), `solarus-quest-tilemap-census` (map 3 = pattern worst-case), `solarus-two-engines-wedge-launch-recipe`, `solarus-84-luaconsole-teleport-repro` (the drive harness), `solarus-no-self-declared-visual-validation`.
