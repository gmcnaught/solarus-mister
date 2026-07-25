# Pacing barrier retirement + region-aware blend capture — design

**Date:** 2026-07-25
**Base:** `origin/master` @ `bdbb877` (PR #149 merged — blend-layer dialog offload)
**Scope:** engine-only, two independent levers. **No new RBF** — ships against
`Solarus_20260724.rbf` (the RBF #149 already shipped).

> **STATUS (2026-07-25, after HW testing).** These shipped as one PR originally; they
> were split.
>
> - **Part A (§3, pacing) — SHIPPING.** HW-validated: fps 26.3 → 37.5 on the map-40
>   dialog scene, 60 fps overworld, 43-48 fps on map 119, no over-production across
>   359 sampled windows, operator visual PASS. Evidence in
>   `docs/superpowers/data/pacing-ab/`.
> - **Part B (§4, region-aware blend capture) — PARKED, code reverted (`6b312ae`).**
>   It renders 3 of 4 pause submenus with the backdrop on top of the content. §4's
>   analysis of *why the pause menu was never captured* is still correct and worth
>   keeping; what it got wrong is **where** a captured layer must be emitted. Full
>   diagnosis, the per-submenu evidence, and the three candidate fixes:
>   `2026-07-25-blend-layer-zorder-parked.md`. Do not restart from §4 alone.
>
> §5's Gate B and the runbook's Gate B apply only to Part B and are therefore
> deferred with it.

Both levers are follow-ups to PR #149. Both of #149's recorded follow-up leads had a
factually wrong premise; this document records the corrected diagnosis first, because the
corrections *are* the design rationale.

---

## 1. Correcting Follow-up Lead 2 — "root clear ≈ 18.5 ms"

#149's memory note reads: *"`root_surface->clear()` alone ≈ 18.5 ms/frame (suspiciously high
for a 320×240 memset — investigate)."*

The bracket is not a memset. `MainLoop::draw()` (patch `0002`) times `clear=` around
`root_surface->clear()`. That call lands in `MisterBlitterRenderer::clear()`
(`mister_blitter_renderer.cpp:2743`), whose blitter-backed branch calls `ensure_frame()`
(`:2762`; definition at `:1313`) — and `ensure_frame` contains **two blocking waits**:

- the C_DONE handshake spin — wait for the fabric to finish the previous frame (`:1324-1340`)
- the anti-tear vblank barrier — wait for the reader's `vsync_count` to tick (`:1356-1385`)

The committed A/B data confirms it on both legs (`docs/superpowers/data/blendlayer-ab/`):

| leg | `clear=` | `fabric=` + `sleep=` |
|---|---|---|
| `BLENDLAYER=1` | 18.7 ms | 8.4 + 11.0 = **19.4 ms** |
| `BLENDLAYER=0` | 14.4 ms | 5.4 + 9.4 = **14.8 ms** |

`clear` is ~100 % **A9 idle**, not CPU work. Same failure mode as
`solarus-stage5-a9-arbror-den-dungeon`: a bracket that silently sums unrelated phases.

### Corrected budget (map 40, dialog up, `BLENDLAYER=1`)

Frame period 38.1 ms (26.4 fps) decomposes as:

- **18.7 ms** real A9 work — lua 9.5 + emit 2.9 + present 7.7
- **8.4 ms** idle, waiting for the fabric (single command ring serializes A9 ↔ fabric)
- **11.0 ms** idle, vblank barrier (`fastpace` skipped it only 3/60 frames)

**19.4 ms of a 38.1 ms frame is idle**, and the idle is scene-independent — it is not a
dialog cost. `pipeline_ceiling=33.7fps` in the banner already names the first half.

---

## 2. Correcting Follow-up Lead 1 — "the menu draws 28 small screen-space items"

#149's memory note reads: *"it draws ~28 small screen-space items
(`[blitter offtgt] 0x…(72x24)x14`, `offtarget=28`) straight to the A9 software path …
Needs a DIFFERENT mechanism: route per-item screen-space draws through the sprite/fabric
channel."*

**The 72×24 draws are not the menu.** They are the HUD action and attack icons —
`hud/action_icon.lua:19` and `hud/attack_icon.lua:19`, both `sol.surface.create(72, 24)`,
rebuilt per frame. Two surfaces × 14 draws = the reported `offtarget=28`. The identical
entries appear in ordinary gameplay captures with no menu open
(`docs/superpowers/stage3a-hw/scroll_on_fixed.log:3905`). They are also legitimate: they are
SDL-backed intermediates that the fabric later reads as uploaded sources, exactly as the
architecture intends.

**What the pause menu actually draws** (`menus/pause_submenu.lua:14-15, 201-208`):

```lua
self.background_surfaces = sol.surface.create("pause_submenus.png", true)
self.background_surfaces:set_opacity(216)
-- ...
self.background_surfaces:draw_region(320 * (submenu_index - 1), 0, 320, 240,
                                     dst_surface, (width - 320) / 2, (height - 240) / 2)
```

A **full-screen 320×240 region blit at opacity 216 onto the root** — structurally identical
to the dialog #149 already offloads, at the same opacity. `Game::draw` passes `root_surface`
into `game_on_draw` (`work/solarus/src/core/Game.cpp`), so `dst_surface` is the root.

### Why `capture=0`

`patches/mister/mister_blend_layer.h:35`:

```c
if (src_w != fb_w || src_h != fb_h) return 0;          /* full-screen source only */
```

The predicate tests the **source surface**. `pause_submenus.png` is a four-submenu
horizontal atlas — verified from the PNG headers in every language directory:
**1280×240**. So `1280 != 320` → rejected. The *drawn region* is exactly 320×240; only the
surface holding it is wide.

#149's design doc flagged this as an open item and resolved it toward source size because
that is what makes the dialog work (`dialog_surface` is full-screen even though the visible
box is a sub-rect). That resolution excludes every atlas-backed full-screen overlay.

**Lead 1 is therefore a predicate/region fix, not a new mechanism.** The fabric needs
nothing: #149 already ships the `comp_pipeline` PALPHA × global-opacity RTL that composites
216 correctly.

---

## 3. Part A — retire the host-side vblank barrier

### Change

Invert the default. The free-running ~60 fps cap already present in `present()` (`:4371`)
becomes the shipping pacing model; the `ensure_frame` vblank barrier (`:1356-1385`) becomes
opt-in.

- New positive flag `SOLARUS_VSYNC_BARRIER=1` re-enables the barrier (escape hatch).
- `SOLARUS_NO_VSYNC` retained as a deprecated alias so existing capture scripts and
  `docs/env-variables.md:83` readers keep working.
- The `vsync_pace` member and both code paths stay; only the default parse at `:2581` and
  the flag's documented meaning change.

### Why this is correct

**The barrier was misplaced and keyed on a dead variable; the `present()` cap replaces it as
the SOLE rate guard.** There is no reader acknowledgement anywhere in the fabric — nothing
tells the producer "the reader has moved past the buffer I'm about to overwrite" — so whatever
enforces the ~60 fps producer rate is the only thing standing between this design and torn
frames. Before this change that was the host-side barrier (misplaced and wrong, but present);
after this change it is the `present()` cap alone. The cap must not be removed or weakened
without something else taking over that job, and it should be re-checked any time a future
scene's fps rises toward or past 60.

The chain since Stage 5 Phase 2 is: `comp_pipeline` → **on-chip WORK** (`comp_fbram`) →
one snapshot burst → DDR3 `FB0`/`FB1` → reader.

1. **The compositor never touches DDR3 FB during a frame.** The only DDR3 FB write is the
   `fb_ddr_writer` burst, triggered at frame *end* once all commands are consumed
   (`fpga/rtl/blitter_top.sv:735`, `:779` → `S_SNAP_WAIT`).
2. **The burst writes the inactive buffer** — `~fb_bank` (`:1382`) — then `S_FRAME_VCTRL`
   publishes vctrl and flips (`:1241-1242`), then `C_DONE`. Both the snapshot state and the
   vctrl publish are unconditional on the fabric's own progress, not on anything the reader
   reports back.
3. **`fb_bank` is fabric-owned and never reloaded from `target_buf`/`C_TARGET`**
   (`:290-294`).

The barrier itself is a pre-Phase-2 vestige on two counts:

- **It paces on a variable it no longer owns.** Its comment reasons about
  "`target_buf` == the buffer shown two frames ago". `target_buf` has not selected the DDR3
  buffer since Phase 2.
- **It is placed a full frame too early.** It blocks at frame *start*; the write it guards
  happens at frame *end*, after all A9 emit and all fabric composite.

It is tempting to also call it redundant with the fabric-side vblank wait Phase 2 already
removed (`blitter_top.sv:1269-1278`: *"The snapshot NO LONGER waits for vblank … it now writes
the INACTIVE buffer, which scanout never reads, so no vblank alignment is needed for
correctness."*) — but that is the wrong lesson to draw. Phase 2's removal proves the fabric
never had a reader-acknowledgement mechanism to begin with; it only shows that a *single*
snapshot into the inactive buffer needs no vblank alignment. It says nothing about what
prevents *two* snapshots from landing inside one reader scan window, which is exactly the
hazard a producer-side rate cap exists to prevent. The host-side barrier and the fabric-side
wait were never guarding the same thing "on the merits" — the barrier was simply guarding it
from the wrong place, at the wrong time, off a variable that had stopped meaning anything.

**What still protects what:**

| hazard | protection | touched by this change |
|---|---|---|
| WORK cleared while snapshot still reading it | C_DONE handshake (`:1324-1340`) | **no** |
| snapshot overwrites the displayed buffer | writes inactive buffer + reader's own once-per-vblank vctrl poll | **no** |
| producer exceeds 60 fps → two snapshots per reader vblank | free-run ~60 fps cap in `present()`, now the SOLE guard (no fabric reader ack exists) | becomes the default AND becomes load-bearing |

What makes the cap safe in practice: `nanosleep` always sleeps at least the requested
duration, and the post-sleep timestamp is taken *after* the sleep returns, so every enforced
period is `target + ε` with `ε ≥ 0` — a far larger, always-favourable margin than the 21 µs
constant correction the barrier used to apply. This is a software-clock limiter, not a
hardware-locked one, but its one-sided error margin is why it holds up as the sole guard.

### Instrumentation fixes (ship with Part A)

These caused the wrong theory, so correcting them is in scope:

1. **Split the `clear=` bracket** in patch `0002` into `clear` / `fabwait` / `vblank`. The
   renderer already accumulates `t_fab_ns` and `t_sleep_ns`; expose them to the draw-phase
   banner rather than letting one bracket sum a memset with two blocking waits.
2. **Fix the `emit` over-statement** noted at `:999`. `emit_ms = (t_draw_ns - t_fab_ns -
   t_sleep_ns)` (`:4019`) subtracts a sleep that is not inside the draw window once pacing
   moves to `present()`. Attribute the `present()`-side sleep separately from the
   `ensure_frame`-side sleep.

### Expected result

Period becomes lua 9.5 + fabric-wait 8.4 + emit 2.9 + present 7.7 ≈ 28.5 ms →
**26.4 → ~35 fps** on the dialog scene, and every scene lifts. This is a projection from the
committed A/B decomposition, not a measurement; the HW gate below is what settles it.

Out of scope: the residual 8.4 ms fabric wait. Removing it means double-buffering the command
ring so A9 emit overlaps fabric composite (→ ~50 fps), which requires RTL and real work on
SDRAM staging / TL / GRID buffer lifetimes while the fabric still reads frame N. Deferred to
its own spec; Part A makes its payoff measurable instead of projected.

---

## 4. Part B — region-aware blend-layer capture

### Change

Thread the source region (`infos.region`) through the capture so every check keys on the
**region** rather than the source surface. Five sites assume a 320×240 source surface:

| site | today | change |
|---|---|---|
| `mister_blend_layer.h:35` | `src_w != fb_w` → reject | take region w/h; reject on `region != fb` |
| `renderer:2993-2994` | 1:1 guard compares `dst_rect` to **surface** size | compare to **region** size (the true no-scale test) |
| `renderer:3002` | `L.w/L.h` from the surface | from the region |
| `renderer:1628` | emit guard `src->get_width() != FB_W` | region fits within the surface; region == FB |
| `renderer:1641` | `blt_blit(..., ref, 0, 0, L.w, L.h, ...)` | `blt_blit(..., ref, L.sx, L.sy, ...)` |
| `renderer:1610` | `hash_surface_pixels` hashes the whole surface | `hash_surface_region` hashes the region's rows (see below) |

`BlendLayer` gains `sx, sy`. For the dialog, `region == (0,0,320,240)`, so `sx=sy=0` and every
comparison yields today's answer — **the change is backward compatible by construction**, and
the host test asserts that explicitly.

### Upload strategy

Upload the whole 1280×240 atlas once and blit the sub-region, rather than adding a
region-upload path to `upload()` (which is keyed on `(surface, format)` and would need a new
cache key and a partial-convert path).

- Cost: 1280×240 ARGB4444 = 614,400 bytes, against a 16–18 MiB heap.
- Frequency: once. The atlas is immutable, so its digest is stable and the existing
  content-hash cache suppresses every subsequent re-upload.

**The content hash becomes region-scoped in the same change.** The change-detection hash runs
every frame on the *cached* path — it is what decides whether to re-upload. Hashing the whole
1280×240 atlas to detect a change inside a 320×240 window reads 4× the necessary bytes on the
A9, every frame, which would give back a meaningful slice of the win this capture exists to
deliver. `hash_surface_pixels` is therefore replaced by a region-scoped
`hash_surface_region(src, sx, sy, w, h)` that chains FNV-1a row by row (an accumulating
variant added to `mister_blend_layer.h`); chaining yields the same digest as hashing the
region contiguously.

The `bl_src_hash` map stays keyed on the source surface pointer. That is correct: an atlas is
immutable, so its region digests are stable and the cache simply never forces a re-upload
after the first. Should a future quest mutate one region of a shared atlas, the digest for the
*drawn* region still changes and forces the re-upload, because the hash is region-scoped.

### Unchanged

Z-order (layers emit after the root overlay, in capture order), registry-overflow fallback to
software, upload-failure drop-with-count, and the `armed` gate driven by
`Game::set_paused` / `start_dialog` / `stop_dialog` (patch `0045`).

### Expected result

Pause menu `capture` 0 → 1, the ~29 ms-class software blend moves to the fabric,
**~20 → ~35-40 fps**. See risk 1 below — the magnitude is inferred, not measured.

---

## 5. Testing and validation

### Host suite (`bash tests/run_tests.sh`)

Extend `tests/blend_layer_test.c`:

- region-keyed predicate **accepts** a 1280×240 surface with a 320×240 region at
  `(320*k, 0)`;
- **rejects** a 320×240 region drawn scaled (dst extent ≠ region extent);
- **rejects** a sub-full-screen region on a full-screen surface (HUD draws must stay on root);
- **regression:** a full-surface 320×240 dialog draw produces layer params byte-identical to
  the pre-change emit, including `sx=sy=0`;
- **hash continuation:** chaining `mister_blend_layer_hash_accum` over two halves equals
  `mister_blend_layer_hash` over the whole — the property row-by-row region hashing relies on.

### Renderer type-check

Native syntax check per CLAUDE.md, with both `-D` flags — they are mandatory, and omitting
them has already produced one falsely-passing verification on this repo:

```
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
```

### HW gates (operator — never self-declared)

Two A/B captures. **The authoritative procedure is
`docs/superpowers/plans/2026-07-25-pacing-and-region-capture-runbook.md`** — follow it, not
this summary, which exists only to say what each gate is for.

**Gate A — pacing.** Map 40 with a dialog held, barrier on vs off
(`scripts/perf/capture_pacing_ab.sh`).
- Expect: fps 26.4 → ~35; `sleep≈0` in `[blitter timing]`; `clear=` in `[MiSTer draw]` drops
  to a sub-millisecond real memset once the bracket is split; `fabwait` unchanged between
  legs (it is the fabric handshake, which this lever must not touch).
- **Operator visual: tear check in a CAP-LIMITED scene, sustained for minutes.** Per §3 the
  cap is now the sole rate guard, so the check is only meaningful where the cap actually
  engages. The map-40 walk expects `fps≈35, sleep≈0` — the cap never fires there, so that
  walk would pass even with pacing completely broken. It is a baseline, not the gate. The
  decisive step is a scene at or above the scan rate (title screen, Select-a-File, pause
  menu), with `sleep > 0` and `fps ≈ 59.9` confirmed from `[blitter timing]` FIRST, then
  watched sustained — any residual drift beats slowly, so a glance cannot clear it.

**Gate B — menu.** Pause menu open, old vs new predicate.
- Expect: `[blitter blendlayer] armed=1 layers=1 capture=1 blits=1 escape=0`; `game=` drops
  by the blend cost; fps up. Also record `[blitter inter]` occupancy before and after the
  menu opens — the whole-atlas upload stages into the 4 MiB INTER arena, and INTER overflow
  is a known failure class (#84).
- **Operator visual:** the menu renders correctly at opacity 216, across **all four**
  submenus (the region origin changes per submenu — a wrong `sx` shows the neighbouring
  submenu, and is invisible on submenu 0).
- **Also carries a tear watch.** Part B raises menu fps into the regime Part A's cap
  governs, so the menu is where the two levers interact; this is the natural cap-limited
  scene for Gate A's decisive check.

### Rollback

Each part is independently revertible by flag: `SOLARUS_VSYNC_BARRIER=1` restores today's
pacing; `SOLARUS_BLENDLAYER=0` restores the software blend. A failed gate on one part does
not block the other.

---

## 6. Risks on the record

1. **Part B's magnitude is inferred, not measured.** That the full-screen blend dominates the
   menu's reported 35 ms follows from its shape matching the dialog's ~29 ms. If Part B lands
   correctly and fps barely moves, that is a real outcome: re-measure and decompose the menu
   frame rather than assume a second lever.
2. **Part A's tear check is the only thing between "correct" and "shipped tearing."** It
   cannot be self-declared (`solarus-no-self-declared-visual-validation` — this has failed
   three times on this project).
3. **The 60 fps cap is now the sole rate guard** (see §3, "Why this is correct" — the fabric
   provides no reader acknowledgement, so nothing else prevents two snapshots landing inside
   one reader scan window). It must not be removed or weakened without a replacement, and its
   correctness should be re-checked if a future scene sustains fps at or above 60.
4. **Instrumentation changes shift the meaning of existing banner fields.** Committed capture
   data from before this PR (`docs/superpowers/data/blendlayer-ab/`) is still valid but its
   `clear=` and `emit=` columns are not directly comparable to post-PR captures. Note this in
   the PR body so future readers do not compare across the boundary.
