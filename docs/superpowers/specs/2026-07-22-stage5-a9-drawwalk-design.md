# Stage 5 (A9 track) — per-drawable draw-walk reduction

**Date:** 2026-07-22
**Branch:** `feat/stage5-a9-next-lever`
**Predecessor decision:** `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md`
(PR #139) — named the limiter and mandated a finer probe as the first Phase-3 step.
**Ship class:** engine-only (A9/host). **No RBF.** Diagnostics are diag-gated and
zero-cost when off; levers are env-flag-gated until HW-validated default-on.
**Target scene:** map 3 town (A9-bound). map 119 stays fabric-bound (control, not a goal).

## Problem

The named limiter (predecessor decision, findings 1–3) is the **per-drawable draw-walk**:
Solarus `Entities::draw` z-order sort + per-entity `Sprite::draw` geometry + our virtual
dispatch, for ~60 drawn entities/frame — measured as `engine_traversal` ≈ **4.6 ms standing /
5.3 ms moving** on map 3, ~90 % of `emit_walk`, and **motion-independent** (per-displayed-frame,
so recovery raises fps ~1:1, upper bound). `sprite_push` (per-sprite resolution cache) is
**refuted** and the z-sort/visible-set cache is **ruled out** for the operative case (motion-
independent cost cannot be recovered by a camera-keyed cache).

`engine_traversal` is a **residual** (`walk − sprite_push − resident_emit − overlay`). The
predecessor decision requires — before committing any mechanism — one finer probe that splits it
into its real components, because they have very different cut-ability and the last working prior
(`sprite_push`) was refuted by data. This spec covers that probe, the decision gate, and the
pre-designed lever menu the gate selects among, plus the successive-lever loop.

## Hot-path facts (read from source, `work/solarus/src/`)

`Entities::draw()` (`entities/Entities.cpp`):
- Builds `entities_to_draw` (cull to camera+margin via `get_entities_in_rectangle_z_sorted`,
  per-layer `std::sort` + `std::unique`) **only inside `if (entities_to_draw.empty())`** — i.e.
  only on a DRAWCACHE miss (`SOLARUS_DRAWCACHE`, patch 0022, default on). On a hit the sort does
  not run. This is why the z-sort is expected to be ≈0 per displayed frame.
- Then, every frame, the per-drawable loop: `for entity in entities_to_draw[layer]: if
  visible/enabled/not-removed: entity->draw(*camera)`.

`Entity::draw()` (`entities/Entity.cpp:3877`), per entity per frame:
1. `get_lua_context()->entity_on_pre_draw(*this, camera)`
2. `built_in_draw(camera)` → `draw_sprites` → per sprite `get_map().draw_visual(...)`
   → `Sprite::draw` geometry → our virtual `MisterBlitterRenderer` dispatch → blit
3. `get_lua_context()->entity_on_post_draw(*this, camera)`

`entity_on_pre_draw`/`entity_on_post_draw` (`lua/EntityApi.cpp:6721/6741`) early-out via
`userdata_has_field(entity, "on_pre_draw"/"on_post_draw")`. `userdata_has_field`
(`lua/LuaContext.cpp`) calls `userdata_has_metafield`, which does **4 Lua C-API ops + 2 string
hashes per call** (`luaL_getmetatable(type_name)` + `lua_pushstring(key)` + `lua_rawget` +
`lua_isnil` + `lua_pop`). That is **2 probes × ~60 entities = ~120 Lua-VM crossings/frame** that
do nothing useful in the common "no draw override" case — motion-independent, per-frame. This is
the **leading suspect**, and a prior flag (`SOLARUS_HASFIELDCACHE`, currently opt-in/OFF for an
instance-level metatable-mutation invalidation gap) already targets exactly this cost. The probe
must confirm it before we build — do not pre-pick.

## Section 1 — The finer attribution probe (anti-bias gate, first deliverable)

Add a `[blitter drawsplit]` decomposition that splits `engine_traversal` into four **disjoint**
sub-brackets. Diag-gated (`g_mister_lua_diag`, same gate as the existing walksplit), delta-counter
style, `/60fr`, matching `[blitter walksplit]` exactly. New `volatile long long` globals in the
renderer; new brackets placed in the Solarus draw path via the patch series (these files already
carry MiSTer diag counters — `g_me_drawcache_hit`, `g_me_draw_entities` — so there is precedent
and a landing site).

| Bracket | Instrumentation site | What it captures |
|---|---|---|
| `sort` (`g_draw_build_ns`) | wrap the `if (entities_to_draw.empty()){…}` build block in `Entities::draw` | candidate (a): cull + z-sort + unique. **Expected ≈0** (DRAWCACHE hit) — the measurement *confirms* the sort is already cached. |
| `lua_hook` (`g_draw_luahook_ns`) | wrap `entity_on_pre_draw(...)` **and** `entity_on_post_draw(...)` in `Entity::draw` (sum both) | the ~120 `userdata_has_metafield` probes/frame + any real callback. Leading suspect. |
| `sprite_geom` | `g_draw_builtin_ns` (wrap `built_in_draw(camera)`) **minus** the blit + sprite_push already measured nested inside it | candidate (b) `Sprite::draw` geometry + (c) our virtual dispatch glue, net of the pixel blit. |
| `residual` | computed: `engine_traversal − sort − lua_hook − sprite_geom` | (d) loop overhead + per-op flush + FPS-overlay emit + `overlay_id_fold` diag tax (non-shippable measurement terms). |

**Nesting discipline.** `g_draw_builtin_ns` wraps the whole `built_in_draw` (the per-entity sprite
draw) and therefore *contains* the already-counted per-entity `blit` (`g_emit_blit_ns`) and
`sprite_push` (`g_sprite_push_ns`) deltas for that frame. It does **not** contain `resident_emit`
(the static-tile channel runs per-layer *outside* the entity loop) or `overlay` (emitted after the
draw pass) — those are siblings already netted out of `engine_traversal`, not nested in `builtin`.
`sprite_geom` is therefore `builtin − blit − sprite_push`. Because those two globals are the same
ones the walksplit already reads, the arithmetic reuses existing deltas — no new nested brackets,
no double-instrumentation.

**Gate rule (mandatory, ship-blocking):** every sub-bracket (`sort`, `lua_hook`, `sprite_geom`,
`residual`) must be **≥ 0 on every window**. A negative means a bracket is mis-scoped or double-
counted — fix the instrumentation, do not ship or interpret. Same rule the walksplit already
enforces on `engtrav_ms`.

**Cross-check:** `sort + lua_hook + sprite_geom + residual` must equal `engine_traversal` for the
same window (identity by construction; assert in the print or verify in the raw capture).

### Decision gate (Task 1 exit)

Commit the drawsplit brackets **before any lever code**. Then HW-capture map 3 standing + moving
(≥3 windows each, median), raw to `docs/superpowers/data/stage5-a9/drawsplit-map3.txt`. Write a
short sub-decision (`docs/superpowers/2026-07-22-stage5-a9-drawsplit-decision.md`) naming the true
split and selecting the Section-2 lever. Anti-bias identical to the predecessor: the direction is
selected *from the capture*, not pre-picked. If the leading suspect (`lua_hook`) is refuted, the
menu still selects correctly.

## Section 2 — Pre-designed lever menu (gate selects one)

Each lever is engine-only, env-flag-gated, and carries the **same correctness bar**:
**bit-exact blit-emission order vs current** (host test modelling the engine-side emission against
the emitter, per `tests/run_tests.sh`) **+ operator visual gate** (Z-fighting / missing-sprite /
dynamic-hook check). Never self-declared visual correctness
(`solarus-no-self-declared-visual-validation`).

### Lever A — draw-hook probe elimination  *(selected if `lua_hook` dominates — expected)*

Eliminate the redundant per-entity-per-frame `userdata_has_metafield` probe for `on_pre_draw` /
`on_post_draw`. Preferred shape: cache the **type-metatable** probe result keyed by
`get_lua_type_name()` for each of the two draw-hook keys. Type metatables are registered once per
entity type and are effectively immutable at gameplay time, so the invalidation surface is far
smaller than the existing per-instance `SOLARUS_HASFIELDCACHE` (whose disclosed gap is exactly a
script mutating the shared type metatable after a `false` was cached for an instance).

- **Instance-table case:** entities with `is_with_lua_table()` (already a cheap bool) can carry
  the hook as a per-instance field; keep the existing per-instance membership check for those (it
  is already cheap — the expensive part is the metatable probe). The cache short-circuits only the
  metatable probe.
- **Invalidation (correctness-critical):** a script that adds `on_pre_draw`/`on_post_draw` to a
  type metatable at runtime must still trigger. Add an invalidation hook at the metatable-write
  site (or a metatable-generation counter checked before trusting a cached `false`). If a clean
  type-level invalidation proves infeasible, fall back to fixing `SOLARUS_HASFIELDCACHE`'s
  instance-level invalidation and defaulting it on for only these two keys.
- **Correctness bar additions:** a test that dynamically registering a draw hook at runtime still
  fires it; bit-exact emission for the common (no-hook) entities.

Env flag: `SOLARUS_DRAWHOOKCACHE` (opt-in until HW-validated default-on, matching prior lever
rollout: measure → soak → flip default).

### Lever B — `Sprite::draw` geometry memoization  *(selected if `sprite_geom` dominates)*

Cache the resolved source rectangle + origin per `(sprite, animation, direction, frame)`;
recompute only when the animation frame or direction changes (tracked by the existing
`set_current_frame` path). Motion contributes only a cheap per-frame dst offset applied on top of
the cached src geometry — consistent with the motion-independence of the cost. Correctness bar:
bit-exact resolved geometry vs the recompute path.

### Lever C — z-sort hoist  *(selected if `sort` dominates — expected refuted)*

If the probe shows the build/sort block runs per displayed frame (DRAWCACHE missing every frame),
the fix is a **DRAWCACHE-invalidation bug** (something dirties `entities_to_draw` every frame),
not a new cache. Diagnose the over-invalidation; do not add a redundant second cache over 0022.

### Lever D — dispatch-glue trim  *(selected if `residual`/dispatch dominates)*

Streamline the `draw_visual` → `Sprite::draw` → virtual `MisterBlitterRenderer` dispatch path
(devirtualization / hoisting invariant lookups out of the per-entity loop). Expected thin; only
pursued if the residual proves to be real shippable dispatch cost rather than diag tax (d).

## Section 3 — Successive-lever loop + validation

After landing the gate-selected lever:

1. **Validate that lever:** host bit-exact emission test → native renderer type-check
   (`g++ -fsyntax-only` recipe from CLAUDE.md, both `-D` flags mandatory) → deploy engine
   (no RBF) → HW A/B on `[blitter walksplit]` + `[blitter drawsplit]`, map 3 standing + moving →
   operator visual gate. Record the A/B in a dated HW-validation doc.
2. **Re-measure and decide again:** if a second sub-leaf is now dominant and the recoverable
   magnitude justifies the work, land the next lever behind a **fresh decision gate** — one-lever
   discipline, measure between landings, anti-bias doc each time. The drawsplit instrumentation is
   reused as the standing measurement harness across landings.
3. **Stop condition:** the residual is diffuse/small (no single sub-leaf worth a lever) OR the fps
   target is met OR the scene flips fabric-bound (`[blitter hwperf]` verdict = FABRIC — then it is
   no longer an A9 arc).

**Expected magnitude (upper bound, from predecessor finding):** recoverable ceiling ~4.6 ms
standing / ~5.3 ms moving of a 14.3 / 16.4 ms A9 budget; recovering half of `engine_traversal`
projects map 3 moving A9 ~16.4 → ~13.8 ms (fps ~33 → ~38, upper bound — the step-amplified `lua`
leaf grows slightly as the frame speeds up and partially eats the win).

## Scope guardrails (do not drift)

- **Engine-only, no RBF.** All work is A9/host. If a candidate needs RTL, it is out of this arc.
- **map 3 is the target.** map 119 is the fabric-bound control; this arc will not raise its fps.
- **`lua`/eng_cpp reduction stays deferred** (the #1 raw leaf, but step-amplified and correctness-
  risky — enemy AI/collision/movement, `solarus-enemy-per-update-cost-simd`).
- **No self-declared visual correctness.** Every lever's visual gate is the operator's or an
  objective bit-exact test.
- **Diagnostics ship diag-gated, zero-cost when off.** Levers ship env-flag-gated until HW-
  validated default-on.

## Testing strategy

- **Host suite** (`tests/run_tests.sh`): add a bit-exact emission-order model test for the selected
  lever — identical blit stream (op params, order) with the lever on vs off across a representative
  entity set including at least one draw-override entity and one dynamically-registered hook.
- **Native type-check:** the renderer `g++ -fsyntax-only` recipe (both `-DMISTER_NATIVE_VIDEO`
  `-DMISTER_NATIVE_AUDIO` mandatory — omitting them type-checks almost nothing).
- **Probe self-check:** every drawsplit sub-bracket ≥ 0; sum equals `engine_traversal` per window.
- **HW:** deploy engine, `[blitter walksplit]`/`[blitter drawsplit]` A/B, operator visual gate;
  dated HW-validation doc per landing. Never ship on self-declared visual correctness.

## References

- `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md` — predecessor decision (this arc's
  parent); mandated the finer probe.
- `docs/superpowers/data/stage5-a9/walksplit-map{3,119}.txt` — predecessor raw drills.
- `patches/mister/mister_blitter_renderer.cpp` — `[blitter walksplit]`/`[blitter emitsplit]` at
  ~L3730–3758; new drawsplit globals + print land here.
- `patches/series/0022-perf-entities-cache-entities_to_draw-across-frames-d.patch` — DRAWCACHE +
  existing diag counters in `Entities.cpp`; landing precedent for the new brackets.
- `work/solarus/src/entities/Entity.cpp:3877` (`Entity::draw`), `lua/EntityApi.cpp:6721`
  (`entity_on_pre_draw`), `lua/LuaContext.cpp` (`userdata_has_field`/`userdata_has_metafield`).
- CLAUDE.md — renderer native type-check recipe; engine source layout (series vs whole-file).
