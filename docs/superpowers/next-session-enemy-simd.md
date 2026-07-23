# Next session — enemy per-update-cost lever (toward 60fps)

**Handoff written 2026-07-04. Assume you have zero context from the prior session; this is
your starting brief.**

## Where we are (the perf arc so far)

Solarus 1.6.5 ported to MiSTer FPGA. The FPGA composites; the A9 (ARM Cortex-A9, ARMv7,
NEON/VFPv3) runs game logic + emits blit commands. Heavy MoSDX overworlds are **100% A9-bound**.
Solarus runs game logic at a **fixed 100 Hz tick**; the MainLoop does catch-up, so at F fps it
runs ~`(1000/F)/10` update() passes per displayed frame (`steps/fr`). Cutting per-*step* cost
pays **super-linearly** (higher fps ⇒ fewer catch-up steps ⇒ less total work).

Shipped/validated levers on the same heavy spot:
- audio→core1, FASTPACE, resident animated tiles (PR#55/#56).
- **SOLARUS_IDLESKIP** (PR#57): skip idle-destructible `update()` no-op → fps ~15→17.3.
- **SOLARUS_IDLEPARK** (PR#59, HW-validated 2026-07-04): remove idle destructibles from the
  update *walk* entirely (park/wake) → **fps ~15→23.5 (+57%)**, `entities` 25.5→10.4ms,
  `steps/fr` 6.6→4.3. Correct (cut grass wakes/animates). Device currently runs this.

**Post-idlepark, the new #1 entity cost is ENEMY: ~13ms/frame over ~46 updates.**

## The thesis for this session (what to build toward)

> The genuinely high-leverage lever now is NOT reducing enemy update *frequency* — it's
> reducing per-update *cost*. Profiling flagged enemy work as ~90% non-Lua movement/collision,
> a SIMD/vectorization candidate. Same fps-leverage, no behavior change.

### Why NOT frequency (the correctness trap — do not fall into it)
On-screen entity updates are **semantically bound to 100 Hz**. The catch-up runs update()
specifically to advance game-time to match wall-time; an on-screen enemy updated every other
tick literally moves at half speed and its AI/animation timers drift = **slow-motion / laggy
AI**. "Spread enemy updates across cycles" is therefore WRONG for on-screen entities. (IDLEPARK
only worked because a parked destructible's update is a *proven no-op* — eliminating null work,
not reducing frequency.) The only correctness-safe frequency reduction is **off-screen/distant
LOD throttling**, which is a SEPARATE, riskier lever with limited payoff in MoSDX's small maps
(most entities are on-screen). Keep it out of scope unless profiling shows a big off-screen
population.

### Why per-update COST is the right lever
Reducing the cost of each enemy update changes no behavior and pays at the per-step rate
(≈ −6.3 fps per ms/step from the leverage model vs ≈ −1.5 fps per ms/frame for per-frame work).

## STEP 1 RESULT (2026-07-04, HW) — hypothesis #2 REFUTED, it's MOVEMENT

Added a `[blitter entsplit]` banner (diag-gated, enemy-only) splitting enemy non-lua
`Entity::update()` into phases. HW, standing-still heavy overworld (~22fps, enemy ~30
updates/fr), 5 clean windows:

- **move ≈ 4.0–5.3ms — DOMINANT (~70–80% of the ~5.3–7.9ms nonlua)** (`movement->update()`)
- sprite ≈ 0.5–1.5ms  · state ≈ 0.1–0.2ms (negligible)
- **of-which collision-with-DETECTORS ≈ 0.2–1.2ms** (the quadtree the plan guessed was
  "likely the big one" — it is NOT; ~10–15% of nonlua).

### MOVE-PHASE DRILL (2026-07-04, HW) — `move = integ + obstacle`
- integration residual ≈ **3.0–4.2ms (~65–70% of move) — dominant**
- terrain-obstacle (`test_collision_with_obstacles` funnel) ≈ 1.1–2.2ms
- detector-quadtree (nested) ≈ 0.4–1.2ms

**SIMD THESIS REFUTED (by measurement + code).** The dominant "integration" residual is
NOT vectorizable float math. `StraightMovement::update_smooth_xy` is date-gated branchy
per-axis logic (`System::now()` = cached `ticks`, ~free); its real cost is
`translate → set_position → Entity::notify_position_changed()`, run on EVERY enemy move
every tick, which does: (1) `quadtree->move()` spatial-index remove+reinsert, (2)
`check_collision_with_detectors` (the ~0.7ms subset), (3) `update_ground_below/observers`
map ground re-query, (4) Lua position-changed notify. Pointer-chasing + spatial-structure
maintenance — memory-bound/branchy, NOT float-parallel. NEON/`-ffast-math` will not help.

**Real behavior-neutral levers instead** (pick via brainstorming + one more optional drill
splitting notify_position_changed): (a) cut quadtree churn — skip `quadtree->move` when the
bounding box didn't cross a cell boundary; (b) cache/cheapen `update_ground_below` per move;
(c) obstacle-test pruning (~1.7ms). **Ceiling is MODEST**: enemy nonlua ~6.5ms/fr ≈ 1.5ms/tick;
eliminating ALL of it ≈ 22→~27fps. Hitting 30fps standing likely needs enemy + a 2nd lever
(revisit emit/hero/other, or fabric). Build: `-mcpu=cortex-a9 -mfpu=neon` + Release(-O3),
no `-ffast-math`. Instrumentation uncommitted on `perf/idle-destructible-park` (renderer
counters + `build_engine.sh` Entity.cpp/Map.cpp/Movement.cpp injections). Memory:
`solarus-enemy-per-update-cost-simd`.

## STEP 1 — PROFILE FIRST (do not build before this)

**"SIMD-candidate" is a hypothesis from a coarse profile label. Verify WHERE the non-Lua enemy
time actually goes before assuming vectorization is the answer.** The real win might be fewer
collision checks (spatial pruning), caching, or removing redundant per-tick work — not literal
NEON.

Two existing diag banners already split enemy cost (grep the device log):
- `[blitter enttype]` — per-EntityType update ms + count (enemy total).
- `[blitter entphase]` — splits enemy into **ai_lua** (`entity_on_update` Lua callback,
  throttle-only, single-lua_State-bound) vs **non-lua** (state machine + movement +
  collision-on-move → the parallel/optimize candidate).

Confirm the ~90% non-lua figure holds post-idlepark, then go FINER: add per-phase timing
*inside* `Enemy::update()` to attribute the non-lua cost to:
1. **movement** (`Entity::update_movement` / the movement object's `update()`),
2. **collision-with-detectors** (`check_collision_with_detectors` → quadtree query + per-detector
   overlap tests — likely the big one; it's pointer-chasing + branchy, NOT naturally SIMD),
3. **sprite/animation update**,
4. enemy state-machine bookkeeping.

Instrument the same way the existing diags do: a new injection block in `scripts/build_engine.sh`
bracketing each phase in `work/solarus/src/entities/Enemy.cpp` (+ base `Entity::update`) with
`clock_gettime(CLOCK_MONOTONIC)` accumulators, printed by a new `[blitter entsplit]` banner in
`patches/mister/mister_blitter_renderer.cpp`. Gate on `g_mister_lua_diag`. Follow the
`[blitter entphase]`/enemy-AI-Lua-split pattern already in `build_engine.sh` (search
`g_me_enemy_lua_ns`).

## STEP 2 — decide the lever from the profile

- If **collision-with-detectors** dominates: the win is likely **reducing/pruning checks**, not
  SIMD — e.g. tighter quadtree queries, skipping detector classes an enemy can't interact with,
  or caching per-tick spatial results. Look at `Entities::get_entities_in_rectangle*` and the
  detector overlap loop.
- If **movement integration / vector math** dominates and is a tight per-enemy loop: NEON/VFP
  vectorization or batching the float math across enemies is viable. Check whether the A9 build
  already enables `-mfpu=neon`/`-ffast-math` (see `scripts/build_engine.sh` / CMake flags) — a
  cheap first experiment is autovectorization flags before hand-written intrinsics.
- If **sprite update** dominates: likely per-sprite `System::now()`/animation advance overhead.

Then brainstorm (superpowers:brainstorming) the specific change, spec it, and implement gated
(new `SOLARUS_*` env flag, default off) exactly like IDLEPARK — engine-only injection, host-test
the pure part, HW A/B on the same spot.

## Recipes / where things are

- **Build:** `git -C work/solarus checkout -- . && git -C work/solarus clean -fdq`, then
  `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh`.
  Verify: `grep -c 'error:' log` = 0; `strings build/armhf/libsolarus.so.1.6.5 | grep -c <FLAG>`.
- **Deploy:** `cp build/armhf/{solarus-run,libsolarus.so.1.6.5} deploy/` (+ libs/), `./deploy.py --no-rbf`.
- **Relaunch + drive + read banners:** see memory `solarus-heavy-area-profile-and-offloads`
  (load_core via `/dev/MiSTer_cmd`, wait for quest_manager, write fresh `/media/fat/config/Solarus.s0`,
  hammer Action `0x020` on `0x3A000008` to load the save; sword=`0x010`, dpad down=`0x004`).
  Read: `ssh root@192.168.20.81 'grep -E "blitter (timing|enttype|entphase|engcpp)"
  /media/fat/logs/Solarus/Solarus.diag.log | tail -20'`. Standing-still, same save spot =
  reproducible A/B. `diag.env` on device carries the gate flags (scp separately; not shipped by deploy.py).
- **Device state:** currently running the IDLEPARK engine (`SOLARUS_IDLEPARK=1` in
  `/media/fat/games/Solarus/diag.env`). It has IDLESKIP + IDLEPARK gates baked (the IDLELIST
  probe is on the throwaway branch `probe/idlelist-throwaway`, not deployed).
- **Joypad bit map:** `patches/mister/mister_native_video.cpp` — 0x001 R, 0x002 L, 0x004 D,
  0x008 U, 0x010 sword/attack, 0x020 action, 0x040 item1, 0x100 pause.

## Relevant memories
`solarus-idleskip-hw-validated` (the full idleskip→idlelist→idlepark arc + leverage model),
`solarus-heavy-area-profile-and-offloads` (the deploy/relaunch/banner recipe + enemy/destructible
breakdown), `solarus-joypad-inject-hw`, `solarus-pr56-camera-independent-resident-hw`.

## Success criteria
Next milestone ~30fps standing on the heavy spot (16.7ms = 60fps is the ultimate). Any enemy-cost
change MUST be behavior-neutral (verify: enemy movement/AI unchanged at normal speed; HW A/B same
spot) and gated default-off.
