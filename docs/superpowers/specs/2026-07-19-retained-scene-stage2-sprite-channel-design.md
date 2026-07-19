# Retained-Scene Stage 2 — SpriteChannel: design

**Date:** 2026-07-19
**Status:** design approved (brainstorm), pending spec review → implementation plan
**Parent design:** `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md` (§2, §4, §6, §7, §8)
**Precedent:** Stage 1 — `plans/2026-07-18-retained-scene-stage1-overlay-channel.md`,
`docs/superpowers/2026-07-18-stage1-overlay-hw-validation.md`
**Gate flag:** `SOLARUS_SPRITECH` (default OFF, presence-based)

---

## 1. What the investigation changed

Stage 2 was specified (parent §7) as "replace the `alias_target` replay with an ordered
`SpriteChannel` + `sprite_unit`", buying "sprites Z-correct; sprite cap+log". Four
premises behind that were checked against the code before planning. **All four failed.**

| Premise (parent spec / kickoff) | Verified finding |
|---|---|
| There is an `alias_target` blit *replay* to replace | **False.** No stored list of alias blits exists. `grep -rn "SpriteChannel" patches/` → zero hits. `draw()` → `emit_draw()` appends one `blt_blit` to the ring immediately, in order (`mister_blitter_renderer.cpp:2583-2590`, `:2049-2141`). The only genuine replay structures are the *tile* ones — `res_ops`, `res_static_ops`, `bg_planes`. |
| Stage 2 buys Z-correctness | **False — already free.** `emit()` writes at `cmd_count * 32` and monotonically increments (`blt_emitter.c:98-105`); the fabric executes the ring strictly in order. A list cannot add ordering that is already there. |
| Stage 2 is scaffolding Stage 3 needs | **False under architecture (ii)** — see §2. |
| Stage 1 HW measured ~450 camera-surface blits/frame (`alias_blits=27039`) | **Unsourced.** `27039` appears exactly once in the repo — in the kickoff doc `next-session-stage2-sprite-channel.md:26-28`. The cited HW record contains no `alias_blits` figure at all. |

**Therefore Stage 2's value must come from elsewhere.** This design relocates it to the
three things the investigation showed are genuinely missing, and shapes the work so that
it **survives Stage 3 rather than being deleted by it**.

### Sourced blit figures (for contrast with the unsourced one)

- `fpga/docs/60fps-bottleneck-hunt.md:50` — heavy overworld, `alias_blits~630`
- `specs/2026-07-13-bgplane-default-on-design.md:15-18` — parallax map, ~706,800/60fr
  ≈ **1,500 draws/frame**, ~15 fps

Both are dominated by **tiles**, not sprites: `g_alias_blits` conflates individual camera
blits (`:2586`) with entries-at-record-time (`:3287`, `:3316`), entries-at-emit-time
(`:3618`, `:3641`), and plane COPYs (`:3865`). **No existing counter answers "how many
sprites per frame".** This is why §5 defers the cap until after a census.

---

## 2. Architecture decision: host-side channel, no new RTL

Two possible shapes for Stage 3 were identified. They imply opposite answers for Stage 2.

- **(i) `scene_walker` owns the frame.** The fabric drives per-layer tilemap→sprite
  sequencing. Sprites must leave the ring. Stage 2's `sprite_unit` is required.
- **(ii) `tilemap_unit` is an in-band ring op.** The host emits one "composite this grid
  layer" command at the correct ordinal position in the ordered stream. Sprites stay in
  the ring. **`sprite_unit` is never needed.**

**(ii) is confirmed feasible, and is what the shipping code already does — twice.**

- A whole tile layer already collapses to one in-band command: `resident_emit_static_layer`
  emits a single windowed `blt_blit` at `:3862-3863`, called from `Entities.cpp:1580`
  *inside* the layer loop, occupying exactly the ordinal position the N bucket commands
  would have (fallback branch, `:3707-3712`).
- Per-layer interleave is real, not batched: one iteration of `Entities.cpp:1509` does
  animated tiles (`:1573-1574`) → static tiles / plane COPY (`:1580`) → **entities for
  that layer** (`:1687-1694`), closing at `:1695`. All append to the same emitter in call
  order, with no reordering anywhere.
- The bake is hoisted but the **composite is not** — `bake_all_planes_sync`
  (`:2670-2673`) writes plane pixels **to SDRAM only**, is a no-op in steady state
  (`:3141`), and terminates with a full-screen FILL + `submit_and_drain()` (`:3182-3184`)
  so it cannot leak into the displayed frame.
- The project already tried and **abandoned** hoisting: the "plane COPY before everything
  on its layer" special case is gone, along with the `resident_static_before_animated`
  virtual (`:3714-3719`, `Entities.cpp:1567-1572`).

**And `tilemap_unit` is ~80% already built.** `OP_TILELIST_RES` (opcode 6) is already a
pattern-index → src-rect indirection with a per-batch scroll offset: `res_bias_x/res_bias_y`
(`blitter_top.sv:684-685`, applied `:924-925`) is the scroll offset; CFT + `frt_bram`
(`:365`, MAXP=128 × MAXF=8) is the pattern→src table; `S_TLR_SLICE` (`:918`) resolves
pid → rect then **joins the shared `S_TL_ISSUE`**, proving a new address-generation
front-end can inherit the existing cull/issue/await-done loop. The delta to a grid op is
iteration source only (2D counter vs flat list), plus a packed index fetcher and
scrolled-edge tile clipping.

**Decision: Stage 2 ships as a host-side channel with no new RTL** — the same shape as
Stage 1, which also needed zero RTL for the same underlying reason.

Cost evidence supporting "no new RTL": FSM state is `reg [5:0]` (`blitter_top.sv:212`)
with ~10–12 free codes; RAM blocks stand at **435/553 = 79%**
(`plans/2026-07-08-phase3b-background-plane-cache.md:1190-1196`); `blitter_top.sv:359-364`
documents a "Task 3 LAB-overflow chase" that forced explicit `ramstyle` pragmas, the class
any new BRAM array would land in. Opcode space itself is ample (8-bit opcode, highest
used is 9) — it is not the constraint.

---

## 3. The acceptance test — objective, not visual

Today entities emit immediately, interleaved per layer. Because entities are already the
**last statement of each layer iteration** (`Entities.cpp:1687-1695`), buffering a layer's
sprite records and flushing them at that layer's end produces an **identical** emitted
order.

> **Acceptance: with `SOLARUS_SPRITECH` present vs absent, the emitted ring command
> sequence must be bit-identical below the cap.**

This is checkable headlessly against `blitter_ref.c`/`.h`, which its own header
(`blitter_ref.h:5-13`) states exists so the host emitter "can be developed + unit-tested
with no hardware". It executes a command list with exact RTL semantics into a 320×240
RGB565 framebuffer.

This matters because of Stage 1's central lesson: the overlay reported
`draws=480 composites=60 dropped=0` — perfectly healthy counters — while **visibly
under-dimming menus** (#124). Counters that cannot fail are not evidence. A bit-exact
sequence equivalence can fail, and therefore means something.

Within-layer ordering detail that any implementation **must preserve**: static is emitted
*after* animated (`Entities.cpp:1548-1566`), a deliberate fix for parallax patterns
painting in front of their own layer. This is exactly the kind of hard-won detail a
clean-slate rewrite silently drops; the equivalence test is what catches it.

---

## 4. Components

### 4.1 Honest counters (prerequisite — lands first)

Not optional, and not merely diagnostic: **this component contains the one unambiguous
bug the investigation found.**

- **Ring-drop counter.** `emit()` returns −1 without incrementing `cmd_count` — the
  command is never written — and `present()` submits the frame anyway
  (`:4297-4305`: "we still submit what we have rather than dropping to a software
  composite"). There is a boolean `em.overflow` flag but **no per-drop count**. A frame
  can lose arbitrary world content with no signal in the diag log. Compare the resident
  path, which hard-latches loudly via `res_fatal` (`:3248`, `:3268`, `:3299`, `:3327`,
  `:3345`). That asymmetry — silent loss in one path, loud failure in the other — is the
  bug-prone shape.
- **Split `g_alias_blits`.** `:2586` becomes a true `g_sprite_blits` (individual
  camera-surface blits); the tile paths (`:3287`, `:3316`, `:3618`, `:3641`, `:3865`) get
  their own counters. One name must mean one thing.

### 4.2 SpriteChannel

Ordered per-layer record buffer of camera-surface blits, flushed in place at layer end,
with a bounded cap, tail-drop, and a logged drop count (parent §6 overflow table).

Fed by the existing classification at `draw()` case (2) — `dst.get_width() == FB_W &&
d->alias_target == &dst && !g_transition_scroll` (`:2583-2590`). Camera adoption is
engine truth via `mister_tag_camera_surface` (`:158-159`), not a heuristic — the same
property that made Stage 1's root tagging correct.

### 4.3 INTER occupancy log

`blt_alloc_used` is called on `em.sdram_perm` (`:1556`) and the DDR3 bounce heap (`:1598`)
but **never on `em.sdram_inter`**. The only INTER signal today is failure-shaped.

The 4 MiB sizing (`:317`, `:325`) rests on a comment (`:318-324`) asserting "Inter working
set is ~2 MiB (measured), so 4 MiB here is ample" — a measurement with **no cited log line
anywhere in the repo**. This component gives parent §8's scratch-arena census something to
census.

### 4.4 Gate

`SOLARUS_SPRITECH`, default OFF, flipped in a separate commit per project convention.

**Presence-based, like every other flag here: `=0` still ENABLES it; it must be absent to
disable.** This nearly invalidated Stage 1's A/B baseline
(`2026-07-18-stage1-overlay-hw-validation.md:35-37`) and must be stated in the plan, the
log line, and the validation record.

---

## 5. The cap — deferred to a census, deliberately

No cap value is chosen in this design.

The only sourced figures (~630, ~1500/frame) are tile-dominated, and the counter that
would answer the question conflates tiles with sprites (§1). Picking a number now means
inventing one — which is precisely how `27039` entered the handoff doc and became a
premise nobody had measured.

**Sequence:** §4.1 counters land → census the worst-case scenes → set the cap from the
measured sprite count with headroom.

**Census scenes:** the parallax map and the town — the two busiest on record
(`60fps-bottleneck-hunt.md:44-48`, `2026-07-13-bgplane-default-on-design.md:14-18`).
Note the existing lua-console teleport route
(`2026-07-12-issue84-root-cause-and-paletted-composition-brief.md` §2) is a *tileset*
sweep, not a sprite-density sweep, and does not include either scene — it needs extending.

A renderer-independent cross-check already exists: `g_me_draw_entities` and
`g_me_draw_anim_tiles` (`Entities.cpp:1687`, `:1609`) separate entities from animated
tiles at the engine's own draw walk, and tick even in pass-through mode without `/dev/mem`
(`:2194-2196`, `:2213-2214`).

---

## 6. Out of scope

- **`sprite_unit` RTL** — §2. Redundant under (ii), and not free given fitter pressure.
- **Any change to `resident` / `bgplane`** — Stage 3.
- **The tilemap grid op** — Stage 3, and gated on §7 below.

---

## 7. Risk carried forward: 60 fps is not yet established

`2026-06-25-compositor-throughput-session.md:44-48` measures the overworld at fps=19.9,
fabric=36.6 ms, **comp=75%** — fabric-bound with the A9 idle, and
`pipeline_ceiling ~25–31 fps` even double-buffered. A new expanding opcode cuts ring-walk
and emit cost (the ~9 ms/frame of non-compositor fabric work, `:50-52`) but **not the 75%
that is `comp_pipeline` itself**.

That measurement predates bgplane default-ON (PR #121, 2026-07-13), which collapsed the
parallax case from ~1500 BLENDs to one COPY, so it may be stale. But it is the most recent
*measured* ceiling in the repo, whereas the parent design's §5 budget (~1.8× headroom) is
an **estimate**.

**Decision (operator, this session): re-measure the ceiling on the current default-ON
build before committing to Stage 3.** If the ceiling still holds, Stage 3 delivers large
bug-reduction *without* 60 fps, and the 60 fps goal needs a separate workstream against
`comp_pipeline` throughput. This is cheap — existing HW cycle counters, one session.

Related STA discipline: `2026-06-25-compositor-throughput-session.md:68` records that
**"RBF builds even with neg slack"** — a passing build is not evidence of passing timing
(baseline `27c421c` was −3.359 ns). No Quartus reports are in-tree; they are CI artifacts.

---

## 8. Testing and validation

- **Host tests** (`patches/mister/build_host_tests.sh` — the CI gate; `tests/run_tests.sh`
  is referenced by no workflow): sequence-equivalence SPRITECH on/off against
  `blitter_ref`; cap enforcement; drop accounting; per-layer order incl. the
  static-after-animated rule (§3).
- **Build**: inside the container — `scripts/docker_run.sh bash scripts/build_engine.sh` —
  and **grep `BUILD_EXIT`** rather than trusting the task exit code. Running on the host
  produces a host-path `CMakeCache.txt` that then blocks the container build.
- **Deploy**: ships from `deploy/libs/`, **sha1-verify on device**. `deploy.py` exit 0
  says nothing about which files moved — a Stage 1 run reported success having updated
  only `solarus-run`.
- **HW gate**: leave `Solarus.s0` **empty**, load the core, launch with a private
  `S0_FILE` override — two concurrent engines make the host mostly unresponsive. Log to
  `/media/fat/logs/Solarus/`, never `/tmp` (wiped on restart). The lua-console path
  `exec`s with its own redirect to `Solarus.diag.log`. **Never blind-inject joypad
  input.** Operator's eyes plus an objective signal; **no stage advances on the agent's
  say-so.**

---

## 9. Inherited items — flagged, not scoped

Neither is Stage 2 work; both are cheap to fold into the same build/HW cycle if the
operator wants them.

- **#124 — overlay under-dims translucent menus.** Shipped as least-bad. Decisive
  experiment: one rebuild bypassing the un-premultiply; else round-to-nearest alpha
  packing. Two candidates remain untested (ARGB4444 `(a>>4)` always truncating down, up to
  6.7% low; un-premultiply over-brightening RGB).
- **#122 / #123 — scroll-transition artifacts.** The parent design predicted Stage 1 would
  structurally delete both. **Never verified** — scroll was observed only in passing
  ("might have been fine"). Closing them requires a deliberate scroll-transition A/B.

---

## 10. Evidence index

| Claim | Source |
|---|---|
| No alias replay exists | `mister_blitter_renderer.cpp:2583-2590`, `:2049-2141` |
| Ring order guaranteed | `blt_emitter.c:98-105` |
| Per-layer interleave | `Entities.cpp:1509`, `:1573-1580`, `:1687-1695` |
| Layer collapses to one in-band command | `mister_blitter_renderer.cpp:3862-3863`, `:3707-3712` |
| Bake hoisted, composite in-band | `:2670-2673`, `:3141`, `:3182-3184` |
| Hoisting tried and abandoned | `:3714-3719`, `Entities.cpp:1567-1572` |
| `OP_TILELIST_RES` = indirection + scroll | `blitter_top.sv:684-685`, `:918`, `:924-925`, `:365` |
| Silent ring drop | `blt_emitter.c:98-105`, `mister_blitter_renderer.cpp:4297-4305` |
| Counter conflation | `:2586`, `:3287`, `:3316`, `:3618`, `:3641`, `:3865` |
| `27039` unsourced | `next-session-stage2-sprite-channel.md:26-28` (sole occurrence) |
| Fitter pressure | `blitter_top.sv:212`, `:359-364`; `phase3b…:1190-1196` |
| Pipeline ceiling | `2026-06-25-compositor-throughput-session.md:44-48`, `:50-52`, `:68` |
| Counters can pass while pixels are wrong | `2026-07-18-stage1-overlay-hw-validation.md:15-25`, `:47-48` |
