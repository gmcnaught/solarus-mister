# Phase 0 attribution — A9 frame time at the heavy village save spot (2026-07-07)

**Capture.** PID 7663, ship (non-`-pg`) `solarus-run` + instrumented **unstripped**
`libsolarus.so.1.6.5`. Village save spot (screenshot-proofed), ≥120 s hands-off
standing inside a longer run. `SOLARUS_BLITTER_DIAG=0`. Engine =
`patches/series/` through `0017`. **6866 SIGPROF samples @ 100 Hz = 68.66 s of
libsolarus self-time.**

**Method — LD_PROFILE, not gprof.** `-pg`/gprof was abandoned (mcount + gmon
plumbing); this is glibc **LD_PROFILE** (a 100 Hz process-wide SIGPROF PC
histogram over `libsolarus.so` only), symbolized by `scripts/sprof_parse.py`
(glibc's own `sprof` is broken here by a dlmopen assertion). Inputs:
`build/armhf/sprof-flat.txt` (self-time flat profile) and
`build/armhf/sprof-callpairs.txt` (PLT call-pair / mcount-arc counts — used for
grouping since the flat profile has no call graph). `build/armhf/` is
gitignored; the flat profile is committed as evidence at
`docs/superpowers/data/2026-07-07-sprof-flat.txt`.

The profile is **whole-run** (boot + quest load + drive + the standing window),
**all threads** (SIGPROF is process-wide), and covers only code that lives in
`libsolarus`. It is authoritative for **ranking and shape**, not for absolute
per-frame magnitude — for magnitude the **banners are ground truth** (A9 busy
30–33.5 ms/frame @ 25.5–27 fps, same spot, same day).

## How to read the numbers (discounts, threads, and the ms/frame scaling)

Four buckets of the raw profile are **not** main-thread frame time and are
removed before attribution:

| Raw row | % | What it really is | Disposition |
|---|---|---|---|
| `_init` | **30.72** | The **`.plt` region** (0xc6d28..0xd1ee8 follows `_init` with no covering symbol) = PLT stubs + LD_PROFILE's forced-lazy audit trampoline fired on **every cross-DSO call**. | **Discount** — profiling-mode artifact. Not mapped to any banner bucket. Qualitatively, heavy cross-DSO call sites (SDL, libc, GL-less blits, OpenAL) pay it; it is *not* engine work. |
| `initialize_lua_console()::{lambda}::_M_run` | **16.11** | The **Lua-console stdin thread** (separate thread). | Other-thread — see finding **F1** (real ship bug, cheap fix = lever **1d**). |
| `MainLoop::is_exiting()` | **10.30** | 173 M arc calls **from that console thread** (callpairs line 1). The main loop calls it ~100×/s = negligible; essentially all 10.30 % is the console thread's busy-poll. | Other-thread (console). A sliver (<0.01 %) is the real main loop. |
| `audio_thread_main` | **1.92** | The **core-1 audio mixing thread**. | Other-thread (audio). |

Discounts + other-threads = **59.05 %**. **Main-thread workload subtotal =
40.95 %** (= 2811 samples ≈ 28.1 s).

**ms/frame conversion (stated explicitly).** For a main-thread symbol at `p` %
of the whole profile: `ms/frame ≈ (p / 40.95) × 30 ms = p × 0.733`. I.e. the
main-thread subtotal is pinned to the banner-measured ~30 ms A9 frame and each
symbol takes its share of that. This is a **ranking-preserving** estimate; it
inherits the whole-run/standing-window dilution, so treat ±30 % as noise and
defer to banners for any A/B number.

## Flat top-20 (self time)

`k = 0.733 ms per %-point` (main-thread rows only).

| % | self s | symbol (abbreviated) | banner bucket | est. ms/frame |
|---|---|---|---|---|
| 30.72 | 21.09 | `_init` (= `.plt` region) | **DISCOUNT** (profiling artifact) | — |
| 16.11 | 11.06 | lua-console `_M_run` lambda | **OTHER THREAD** (console, F1) | — |
| 10.30 | 7.07 | `MainLoop::is_exiting` | **OTHER THREAD** (console, F1) | — |
| 3.39 | 2.33 | `Quadtree::Node::get_elements` | entities / z-sort family | 2.48 |
| 1.92 | 1.32 | `audio_thread_main` | **OTHER THREAD** (audio) | — |
| 1.35 | 0.93 | `Entities::update` | entities (update walk) | 0.99 |
| 1.17 | 0.80 | `__unguarded_linear_insert<ZOrder>` | entities / z-sort family | 0.86 |
| 1.06 | 0.73 | `__unique<…get_elements lambda>` | entities / z-sort family | 0.78 |
| 0.99 | 0.68 | `_Sp_counted_base::_M_release` | entities (shared_ptr churn) | 0.73 |
| 0.96 | 0.66 | `LuaContext::userdata_has_field(string)` | Lua boundary | 0.70 |
| 0.93 | 0.64 | `Tileset::update` | tileset | 0.68 |
| 0.80 | 0.55 | `Debug::check_assertion` | **UNSEEN** (assert-in-release, F2) | 0.59 |
| 0.80 | 0.55 | `AnimatedTilePattern::update` | tileset | 0.59 |
| 0.73 | 0.50 | `SurfaceImpl::is_pixel_transparent` | **UNSEEN** (pixel collision, F3) | 0.53 |
| 0.68 | 0.47 | `System::now` | tileset (anim clock, F4) | 0.50 |
| 0.68 | 0.47 | `__introsort_loop<ZOrder>` | entities / z-sort family | 0.50 |
| 0.67 | 0.46 | `__insertion_sort<ZOrder>` | entities / z-sort family | 0.49 |
| 0.67 | 0.46 | `Entity::update_sprites` | entities (update walk) | 0.49 |
| 0.66 | 0.45 | `LuaContext::userdata_has_field(char*)` | Lua boundary | 0.48 |
| 0.64 | 0.44 | `Map::get_ground(Point)` | collision / ground | 0.47 |

## Main-thread subsystem totals (grouped via call-pairs + source)

Summed over the **whole** flat profile (not just the top-20), grouped using
`sprof-callpairs.txt` and greps of `work/solarus/src/`. Percentages are of the
whole profile; ms/frame = `% × 0.733`.

| Subsystem (grouping) | Σ self % | est. ms/frame | Notes |
|---|---|---|---|
| **Quadtree `get_elements` + Z-order sort/unique/insert family** | ~9.0 | **~6.6** | **#1 main-thread cost.** `get_elements` (3.39) + `__unique`/`__introsort`/`__insertion_sort`/`__unguarded_linear_insert` over `EntityZOrderComparator` (3.58) + `_M_realloc_insert`/`_M_erase`/`~vector<Entity>` (0.86) + wrappers/`is_main_cell`/`get_num_elements` (0.47) + most of `_Sp_counted_base::_M_release` (0.99, shared_ptr copies made by this family — top arcs `__unique→_M_release` 3.6 M, `insertion_sort→_M_release`). Straddles collision queries **and** the per-frame **z-sorted visible-entity retrieval** in `Entities::draw` (via `get_entities_in_rectangle_z_sorted`). |
| **Entity update walk (non-quadtree)** | ~4.6 | **~3.4** | `Entities::update` (1.35) + `Entity::update`/`update_state`/`update_sprites`/`clear_old_*`/`update_stream_action` + `Sprite::update`/`Drawable::update` + movement `update()`s. |
| **Lua boundary / glue** | ~6.6 | **~4.8** | `userdata_has_field` ×3 (str 0.96 + char* 0.66 + `userdata_has_metafield` 0.38 = **2.00**) + `ScopedLuaRef` equals/push/is_empty (1.18) + `has_drawable`/`update_drawables` (0.45) + `get_entity_internal_type_name`/`get_positive_index` (0.60) + `Rb_tree<string>::find` (0.29) + `menus_on_update`/`update_timers`/`item_on_update`/`call_function`/`test_userdata`/`is_entity`/… (~1.4). **Single `lua_State` → cannot move off the main thread.** |
| **Tileset / animated tiles** | ~2.6 | **~1.9** | `Tileset::update` (0.93) + `AnimatedTilePattern::update` (0.80) + **`System::now` (0.68 — `AnimatedTilePattern::update→System::now` is 5.34 M arcs, the animated-tile frame clock, F4)** + `TilePattern::update`/`get_frame_rect`/`get_draw_region` (0.16). Banner said ~1.4 ms; gprof ~1.9 because `System::now` folds in. |
| **Emit / renderer / draw glue** | ~3.3 | **~2.4** | `emit_draw` (0.45) + `MisterBlitterRenderer::draw`/`upload`/`clear`/`resident_*` (0.60) + `neon_argb4444_row`/`neon_rgb565_row`/`to_argb4444` pixel conversion for uploads (0.49) + `SDLSurfaceImpl::get_surface` (0.26) + `blt_blit`/`blt_tile_list_static` (0.18) + `Entities::draw`/`Entity::draw*`/`Drawable::draw*`/`SurfaceDraw::draw`/`Video::render` (~0.85). |
| **Collision / ground / detectors** | ~1.8 | **~1.3** | `Map::get_ground` (0.50) + `test_collision_with_ground`/`_obstacles`/`_entities` (0.20) + `check_collision_with_detectors` (0.26) + `is_ground_obstacle`/`get_max_bounding_box`/`notify_position_changed`/`notify_entity_bounding_box_changed` (0.42). |
| **Pixel-precise collision (F3)** | ~1.5 | **~1.1** | `SurfaceImpl::is_pixel_transparent` (0.73) + `Surface::is_pixel_transparent` (0.35) + `PixelBits` ctor (0.28) + `test_aligned_collision`/`Sprite::test_collision` (0.03) + `are_pixel_collisions_enabled` (~0.1). **Plus** most of `check_assertion` (F2) is charged here. |
| **Sound (main thread)** | ~0.6 | **~0.4** | `NativeAudioWriter_Free/Capacity/Submit` (0.38) + `Music::update*`/`Sound::decode_file` (0.18). **The 1.92 % `audio_thread_main` is the separate core-1 thread — NOT this row.** |

## The ~10.7 ms/frame per-frame (non-step) share, attributed

The banners split A9 into `eng_cpp` update steps (18.6–21.5 ms) and a
**~10.7 ms/frame non-step draw/emit/Lua/present/glue** remainder. LD_PROFILE is
whole-run and cannot cleanly split step from per-frame, so this maps the
**per-frame-natured** subsystems (drawing, z-sorted retrieval, draw-time Lua,
emit, present) into that budget. Estimates carry the same ±30 %.

| Component | est. ms/frame | Evidence | Lever |
|---|---|---|---|
| **Z-sorted visible-entity retrieval for draw** | ~2.5–3.5 | The quadtree+z-sort family (~6.6 ms) is split between collision queries and the once-per-frame `Entities::draw → get_entities_in_rectangle_z_sorted` sort. When **standing still** the visible set + camera are constant, so this per-frame re-sort is pure waste. | **1e (new): z-sorted-visible-list cache** — invalidate on entity add/remove/move or camera move. Biggest single per-frame prize. |
| **emit (`blt_*` / renderer / pixel-convert)** | ~2.4 | Emit/draw-glue subsystem total. | Phase 2 worker (offloadable). |
| **Lua VM draw callbacks (`entity_on_pre/post_draw` → `userdata_has_field`)** | ~1.0 | callpairs: `entity_on_pre_draw→userdata_has_field` 128 K, `entity_on_post_draw→…` 128 K. Runs during draw recording. | **Stays main-thread** (single `lua_State`) — Phase 2 descope signal. |
| **Other Lua boundary/glue (updates/timers/menus)** | ~3.8 | Rest of the 4.8 ms Lua total (mostly step-time, but boundary-locked). | **Stays main-thread**; cheap sub-lever **1f** (cache `userdata_has_field`). |
| **present / pacing** | <0.3 in libsolarus | `Video::render`/`SurfaceDraw::draw` tiny; the real present cost is the **fabric wait** (2.7–3.6 ms/frame), which lives outside libsolarus so it is invisible here. | Phase 2 pacing-wait offload. |

**Phase 2 descope signal (explicit).** Of the ~10.7 ms, only **~2.4 ms is emit**
and **<0.3 ms is present-in-libsolarus**; the rest is Lua boundary (~4.8 ms,
main-thread-locked) + z-sorted draw retrieval (~2.5–3.5 ms, better fixed by a
cache than a thread) + the out-of-DSO fabric wait. **The emit-thread premise is
weaker than the spec assumed** — per the spec's own descope rule (emit+present
< ~4 ms), Phase 2 should shrink toward the pacing-wait/ring-submit offload and
push the savings hunt into Phase 1 (levers 1e/1f).

## `eng_cpp` `other` (3.5 ms/frame) + `sound` (2 ms/frame), attributed

| Symbol / subsystem | est. ms/frame | Phase 1 lever |
|---|---|---|
| Pixel-precise collision (`is_pixel_transparent` ×2 + `PixelBits` ctor) | ~1.1 | **F3 / new candidate** — pixel-collision mask rebuild; not in any banner. Prune sprites that don't need pixel-precision, or cache masks. |
| Assertions live in "release" (`Debug::check_assertion`) | ~0.6 | **F2 / new candidate** — 4.05 M arcs from `is_pixel_transparent` (bounds assert) + 1.78 M from `ScopedLuaRef::push`. Build with `NDEBUG`/`SOLARUS_DEBUG=0` to compile them out. Near-free. |
| `userdata_has_field` ×3 (has-field probes on entities every frame) | ~1.5 | **1f (new)** — Solarus probes "does this userdata have field X" in C++ even when no script defines it. Cache the negative result per (type, field). |
| Ground query (`Map::get_ground`, `test_collision_with_ground`) | ~0.7 | **1b** (`SOLARUS_GROUNDCACHE`) — confirmed by gprof. |
| **Sound (main thread)** | **~0.4** | **1c confirmed** — main-thread sound is ~0.4 ms, *not* ~2 ms. The banner "sound ~2 ms" is dominated by the **separate core-1 `audio_thread_main` (1.92 %)**. So 1c is cheap-enable bookkeeping, not a main-thread hog — the Phase 2b "move sound to audio thread" idea is largely already true. |

## Findings surfaced that the banners never showed

- **F1 — Lua-console stdin thread spins a whole A9 core (REAL ship bug).** The
  daemon launches the engine with **stdin = `/dev/null`**, so the Lua-console
  `getline()` loop hits EOF instantly and busy-polls `MainLoop::is_exiting()`
  (173 M calls over the run — ranks #2–#3 in the raw profile). It is a separate
  thread, so it is **not** main-thread frame time, but it burns a core that
  contends with the core-1 audio thread and (once Phase 2 lands) the emit
  worker. **Fix = lever 1d**: launch with **`-lua-console=no`** (verified
  spelling, `work/solarus/src/main/Main.cpp:70`:
  `-lua-console=yes|no … (default yes)`). Win: frees ~a core of contention;
  **frame-time effect unknown until HW A/B** — it is not main-thread ms.
- **F2 — assertions are compiled IN.** `Debug::check_assertion` at 0.80 % in a
  shipping build; 5.8 M calls/run. Build with `NDEBUG` to drop them (~0.6 ms/frame).
- **F3 — pixel-precise collision (`is_pixel_transparent` + `PixelBits`) ~1.1 ms/frame**,
  invisible to every banner. Candidate: mask cache / precision opt-out per sprite.
- **F4 — `System::now` 0.68 %** is almost entirely the animated-tile clock
  (`AnimatedTilePattern::update → System::now`, 5.34 M arcs). Folds into the
  tileset lever; a per-frame timestamp hoist would erase it.

## Cross-check vs the banners — reconciled

Scaling the main-thread subtotal to 30 ms and grouping into banner buckets:

| Bucket | gprof est. | Banner | Verdict |
|---|---|---|---|
| entities (update walk + quadtree/z-sort + collision) | ~11.3 | 9.4–11.7 | ✅ matches (and gprof *localizes* it: the quadtree z-sort family is the dominant sub-cost, which the banners lumped together). |
| tileset | ~1.9 | ~1.4 | ✅ close (gprof folds in `System::now`). |
| hero | (dispersed; `Hero::*` rows all ≤0.01 %) | ~2.3 | ⚠️ gprof shows hero work dispersed into the shared entity/movement/collision machinery rather than named `Hero::*` self-time — consistent, not contradictory. |
| sound (main thread) | ~0.4 | ~2 | ↔️ reconciles once you separate threads: the ~2 ms banner is the **core-1 audio thread** (1.92 %), main-thread sound is ~0.4 ms. |
| enemy move (integ + obstacle) | integ dispersed into quadtree-reinsert family; named collision self-time ~1.3 | integ 2.3–3.2 + obstacle 1.2–2.4 | ⚠️ gprof puts most enemy "integ" cost in the **quadtree reinsert + z-sort family**, not in `notify_position_changed` self-time — so 1b's "quadtree churn is the integ cost" thesis is *confirmed*, and the family-level view says fix the retrieval/sort, not the leaf. |

**Bottom line:** ranking and magnitudes reconcile with the banners once (a) the
`.plt` artifact is discounted, (b) the console + audio threads are separated
out, and (c) the quadtree get_elements/z-sort family is understood as one entity
substrate straddling update **and** draw. The one hard disagreement is
**directional, not magnitude**: emit is only ~2.4 ms of the 10.7 ms per-frame
share, so **Phase 2's emit-offload should be descoped toward pacing-only** and
the freed effort spent on the gprof-surfaced Phase-1 levers (1e z-sorted cache,
1f has-field cache) plus the near-free F1/F2/F4 wins.
