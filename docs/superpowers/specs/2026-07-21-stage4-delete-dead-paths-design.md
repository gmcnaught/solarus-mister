# Retained-Scene Stage 4 — Delete Dead Paths (design)

**Date:** 2026-07-21
**Status:** design, pending implementation plan
**Precedes:** implementation plan (`docs/superpowers/plans/`)
**Roadmap:** final stage of the retained-scene compositor migration
(`docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md` §7,
Stage 4: "remove bgplane, resident caches, flat-command remnants once 0–3 validated").

## 1. Motivation and the reframe

The roadmap's literal Stage 4 targets are mostly already done or turned out
load-bearing:

- **bgplane** — the RTL was removed in Stage 3b Phase B2 (`8f62dfc refactor(blitter):
  remove inert bgplane RTL`). What remains is the *intentionally-RESERVED* opcode 8
  (`OP_BGPLANE_WRITE` / `BLT_OP_BGPLANE_WRITE = 8`) and `BLT_F_BGCOV`, held so
  host↔RTL numbering stays stable — **do not remove these**. Only a stale comment in
  `comp_src_linebuf.sv` and the CLAUDE.md "still physically exists" note are wrong.
- **"resident caches"** — **load-bearing, not dead.** `SOLARUS_TILERESIDENT` is
  default-ON and required for animated tiles; the static replay path
  (`resident_emit_static_layer`) is the overlap-bucket fallback that fires even with
  `SOLARUS_TILEMAPCH` ON. It stays.
- **"flat-command remnants"** — the "flat" references are all narrative comments
  (the `res_fatal` "flats every room" story), not a live opcode. Nothing to remove.

So Stage 4 is redefined to the code that is *genuinely* dead or vestigial now that
the four retained-scene channels (Overlay, Sprite, Scroll-fabric, Tilemap) are all
default-ON and HW-validated. Three independent removals plus a stale-doc sweep, all
**behavior-neutral on the shipping default path.**

## 2. Scope

### A — Disconnected software-video path

The `SOLARUS_SW` full-frame software-composite path is disconnected: current cores
scan out from on-chip BRAM, so it shows a black screen and is explicitly "never a
valid test reference." Remove its video machinery, **surgically** — the file that
hosts it is a mixed HAL that also provides live input.

> **SCOPE CORRECTION (found during implementation, 2026-07-21):** `native_video_writer.{c,h}`
> is NOT pure SW-video and is **not deleted**. `NativeVideoWriter_Init` (DDR mmap) +
> `NativeVideoWriter_ReadJoystick` are the **live controller-input path**, called every frame
> by `mister_poll_input()` (renderer:3737). Only `NativeVideoWriter_WriteFrame` +
> `mister_present_frame` + the frame-buffer statics are dead. Corrected scope: keep the file,
> its CMake source line, and `apply_mister_files.sh`; remove only the dead video-write half +
> `present_frame`; the series-`0001` edit is present()-call removal only. The bullets below are
> superseded by the plan's Task 4 (corrected).

- ~~**Delete** `native_video_writer.{c,h}`~~ — SUPERSEDED (see correction above): the writer
  is retained for the live input path; only its dead `WriteFrame` half is trimmed.
- **Excise** `mister_present_frame()` (the SW-path present) and its
  `#include "native_video_writer.h"` + DMA body from `mister_native_video.cpp/.h`.
  `mister_present_frame()` is called from **series patch `0001`** (the upstream
  `present()`/MainLoop DDR video hook); that patch must be regenerated to drop the
  call. Behavior-neutral: the shipping blitter path bypasses `mister_present_frame`,
  and controller input is already polled independently via `mister_poll_input()`
  (`mister_blitter_renderer.cpp:3893`).
- **Keep** the file `mister_native_video.{cpp,h}` — it still exports the load-bearing
  `mister_poll_input()`.
- **Keep** the `0x3A000000` video-control word and the audio ring
  (`0x3A000030`/`0x38`) that share that DDR region. This region is **not** deleted;
  only the full-frame pixel DMA producer is.
- **Update** `scripts/apply_mister_files.sh` to stop copying the two
  `native_video_writer.*` files.
- **Investigate + likely remove** the draw-profiling counters
  (`mister_draw_count_blit` / `_target_switch` / `_readpixels`,
  `mister_draw_prof_enabled`, `mister_draw_take_counts`): grep shows no live callers
  in the renderer. If confirmed dead, remove them and any `draw_prof` scaffolding; if
  a series patch still calls them, keep and note it. (Resolved in the plan, not here.)

### B — Escape-hatch fallback bodies (hardwire ON, remove flags)

Overlay and Sprite are default-ON and HW-proven; their pre-channel fallback bodies
are dead weight and their env flags are now just A/B-debug vestiges. Delete both.

- **`SOLARUS_OVERLAY`** — remove `overlay_enabled`, its `mister_flag_default_on`
  parse, and every `if (overlay_enabled)` / else-fallback branch (the old per-surface
  base-SDL draw path, the aliased-surface loss class). Overlay compositing becomes
  unconditional.
- **`SOLARUS_SPRITECH`** — remove `spritech`, its parse, and every guarded branch,
  including the `SOLARUS_SPRITECH=0` direct-`emit_draw` / `alias_target` replay
  fallback. The SpriteChannel becomes unconditional.
- **Explicitly retained (do NOT touch):**
  - `SOLARUS_SCROLLFAB` and its `SOLARUS_SCROLLFAB=0` software-scroll fallback
    (`g_transition_scroll`, `scroll_bandaid_active()`, `previous_map_surface`) — kept
    as the deliberate transition escape hatch.
  - `SOLARUS_TILEMAPCH` and the `SOLARUS_TILEMAPCH=0` → replay path — the replay path
    is **load-bearing** (overlapping-static-tile buckets fall back to it even with the
    flag ON), so it and the flag both stay.
  - `SOLARUS_TILERESIDENT` — required for animated tiles; stays.

### C — Closed-investigation diagnostics

Remove the env-gated diagnostics whose investigations are closed; keep general
instrumentation and live perf levers.

- **Remove `SOLARUS_ARENA_PROBE`** + `run_arena_probe()` and the `arena_probe`
  member/parse/dispatch — the #24 SDRAM-arena bit-exact probe, closed + HW-validated.
- **Remove `SOLARUS_POT_DIAG`** + `pot_diag_log()`, `pot_diag_seen`,
  `POT_DIAG_MAX_LINES`, and the `pot_diag` member/parse/call sites — the bgplane-pots
  investigation, whose subsystem (bgplane) is deleted.
- **Keep** general instrumentation: `SOLARUS_BLITTER_DIAG` (the `res_*` counters, a
  reusable perf/health readout — the eventual Stage-3 perf-acceptance measurement will
  want it), `SOLARUS_BLITTER_TRACE_N`.
- **Keep** live perf levers: `SOLARUS_DRAWCACHE`, `SOLARUS_FASTPACE`,
  `SOLARUS_IDLESKIP`, and all preload/loadbar/vsync feature flags.

### Stale comments / docs

- Fix `CLAUDE.md`: the bgplane RTL "still physically exists / removed in Phase B" note
  is stale — the RTL was removed in Phase B2. Reword to "removed; only the RESERVED
  opcode 8 + `BLT_F_BGCOV` constants and one `comp_src_linebuf.sv` comment remain,
  deliberately."
- Fix the misleading `SOLARUS_PALETTE` documentation: the member initializer
  `bool palette_enabled = false;` (a pre-parse default) and the comment
  `"SOLARUS_PALETTE, default OFF"` are wrong — the ctor parses it via
  `mister_flag_default_on`, so it is **default-ON** (flipped in `3df5654`, Phase 5,
  HW-validated with the 32-bank RBF; the paletted path was **exonerated** in the
  #84/#120 investigations — the real root cause was the perm-restage overflow, fixed
  host-side). Correct the comment and annotate the initializer as pre-parse only. No
  behavioral change — `SOLARUS_PALETTE` is already ON.
- `SOLARUS_SW` and `native_video`-path references in surviving comments updated to
  reflect removal.

## 3. Explicitly out of scope

- **`OFF_BGCACHE` DDR-reservation reclaim** (~15.7 MiB heap headroom). The cache
  itself is already gone; only the memory-map reservation lingers (caps the bump heap,
  gates `SDRAM_ATLAS_BASE`). Reclaiming it shifts memory offsets and needs its own
  offset-map validation — **deferred to a separate MR.**
- **The `SOLARUS_PALETTE` paletted-composition path** — a live, default-ON feature,
  not dead code. Untouched except for the stale-comment fix above.
- **`SOLARUS_SCROLLFAB` / `SOLARUS_TILEMAPCH` / `SOLARUS_TILERESIDENT`** paths and
  flags — retained per §2.B.
- The reserved bgplane wire constants (`OP_BGPLANE_WRITE = 8`, `BLT_F_BGCOV`) —
  retained ABI, never reuse opcode 8.
- Any RTL change — the bgplane RTL is already gone; Stage 4 is host/engine only.

## 4. Risk and validation

All three removals are **behavior-neutral on the default shipping path**: every
retained-scene channel is already default-ON, and the software-video path is already
disconnected (black screen). The risk is *accidentally cutting live code* (e.g. the
shared `0x3A000000` region, `mister_poll_input`, the load-bearing replay path), which
the scope boundaries above are written to prevent.

Validation posture (no RTL, no Quartus, no seed sweep — runs on the deployed B2 RBF):

1. **Host test suite** — `bash tests/run_tests.sh` green (models engine-side logic).
2. **Renderer type-check** — the native `g++ -fsyntax-only` recipe from CLAUDE.md,
   **with `-std=c++11`** (the Stage 3b B3 gotcha: `-std=c++17` masked a build-breaking
   aggregate-init; the container build is C++11).
3. **In-container armhf build** — `scripts/build_engine.sh` produces
   `libsolarus.so.1.6.5` + `solarus-run`; the regenerated series patch `0001` must
   `git am` clean.
4. **One HW smoke pass** — deploy, boot a quest, walk overworld + one interior +
   confirm a transition still runs. Purpose is "nothing live got cut," per the
   never-self-declare-visual-correctness rule (operator's eyes, not the agent's).

## 5. Sequencing

Single branch, one MR, three reviewable commits + a docs commit, landed in order:

1. **C** (diagnostics) — smallest, most self-contained, lowest risk.
2. **B** (hardwire Overlay + Sprite, remove flags) — renderer-only, no series edit.
3. **A** (software-video path) — last; it is the only one that touches the git-am
   series (patch `0001`) and the build wiring, so it lands on an already-green tree.
4. **docs** — CLAUDE.md + `SOLARUS_PALETTE`/`SOLARUS_SW` comment fixes.

Each commit keeps the tree building and host-tests green so the HW smoke pass at the
end validates a known-good composition.

## 6. References

- `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md` §7 (Stage 4).
- `patches/mister/mister_blitter_renderer.{cpp,h}` — the renderer (whole-file copy).
- `patches/mister/mister_native_video.{cpp,h}`, `native_video_writer.{c,h}` — the HAL
  + SW-video writer (whole-file copies).
- `patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch` —
  the DDR video/audio hook (series; the `mister_present_frame` call site).
- `scripts/apply_mister_files.sh` — whole-file copy wiring.
- CLAUDE.md — "Rendering architecture" note (software path "slated for removal").
