# Stage 4 — Delete Dead Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the genuinely-dead code left after the retained-scene migration — the disconnected software-video path, the now-redundant Overlay/Sprite escape-hatch fallbacks, and two closed-investigation diagnostics — without changing any shipping-default behavior.

**Architecture:** Three independent host/engine-only removals plus a stale-doc sweep, landed C→B→A so the riskiest (A, which touches the git-am patch series) lands on an already-green tree. No RTL, no Quartus, no seed sweep — runs on the deployed B2 tilemap RBF. Every removal is behavior-neutral because all four retained-scene channels are already default-ON and the software path is already disconnected (black screen).

**Tech Stack:** C++11 (Solarus engine + `MisterBlitterRenderer` whole-file copy), C (native-video HAL), git-am patch series (`patches/series/*.patch`), host C/C++ test harness (`tests/run_tests.sh`), armhf cross-build in Docker (`scripts/build_engine.sh`).

## Global Constraints

- **Behavior-neutral on the default path.** Every retained-scene channel (Overlay, Sprite, Scroll-fabric, Tilemap) is already default-ON; the SW path is disconnected. No task may change what the shipping launch (`solarus_run.sh`, which sets none of these vars) renders.
- **Type-check the renderer with `-std=c++11`, NOT c++17.** The container build is C++11; `-std=c++17` masked a build-breaking aggregate-init in Stage 3b B3. Type-check recipe (from CLAUDE.md), mandatory `-D` flags included:
  ```
  g++ -fsyntax-only -std=c++11 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
- **Do NOT touch, this pass:** `SOLARUS_SCROLLFAB` + its `g_transition_scroll` software-scroll fallback (deliberate escape hatch); `SOLARUS_TILEMAPCH` + its replay path (load-bearing overlap fallback); `SOLARUS_TILERESIDENT` (required for animated tiles); `SOLARUS_PALETTE` path (live default-ON feature); the reserved bgplane wire constants (`OP_BGPLANE_WRITE = 8`, `BLT_F_BGCOV`); `mister_poll_input()` and the `mister_draw_*` profiling counters (called from series `0001`/`0002`); the `0x3A000000` video-control word + audio ring; the `OFF_BGCACHE` DDR reservation (deferred to its own MR).
- **`fps_overlay_enabled()` is a SEPARATE FPS-HUD toggle** (renderer:1142, used at :3911) — it is NOT the overlay channel. Leave it untouched.
- **Verification per task:** `bash tests/run_tests.sh` green + the `-std=c++11` type-check clean + a grep proving the removed symbol is gone. Task 4 additionally requires a full in-container armhf build + `scripts/verify_patches.sh`. Task 6 is the HW smoke pass.
- **Commit messages** end with the repo's Co-Authored-By + Claude-Session trailers (see existing commits).

**Line numbers below are anchors as of branch `feat/stage4-delete-dead-paths` @ HEAD; re-grep before editing since earlier tasks shift later line numbers.**

---

### Task 1: Remove closed-investigation diagnostics (Scope C)

Two independent, self-contained diagnostic removals in the renderer: `SOLARUS_ARENA_PROBE` (#24 SDRAM-arena probe, closed + HW-validated) and `SOLARUS_POT_DIAG` (bgplane-pots trace; bgplane is deleted). Two commits.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (pure removal; no symbol survives for later tasks).

- [ ] **Step 1: Remove `SOLARUS_ARENA_PROBE`.** Delete every site (re-grep first: `grep -n "arena_probe\|ARENA_PROBE\|run_arena_probe" patches/mister/mister_blitter_renderer.cpp`):
  - the `bool arena_probe = false;` member + its two-line `// [#24 arena probe] ...` comment (~708–710)
  - the entire `void run_arena_probe() { ... }` method including its leading comment block (~1336–1373; the method closes at the `  }` at ~1373)
  - the parse line `self->d->arena_probe = (std::getenv("SOLARUS_ARENA_PROBE") != nullptr);` (~2443)
  - the dispatch + its comment: `if (d->arena_probe) { d->run_arena_probe(); return; }` and the `// [#24 arena probe] ... hijacks the frame ...` comment above it (~3460–3462)

- [ ] **Step 2: Verify ARENA_PROBE gone + tree still builds.**

  Run: `grep -rn "arena_probe\|ARENA_PROBE" patches/mister/mister_blitter_renderer.cpp` → Expected: no output.
  Run the `-std=c++11` type-check (Global Constraints) → Expected: exits 0, no errors.
  Run: `bash tests/run_tests.sh` → Expected: all green.

- [ ] **Step 3: Commit.**
  ```bash
  git add patches/mister/mister_blitter_renderer.cpp
  git commit -m "cleanup(blitter): remove SOLARUS_ARENA_PROBE (closed #24)"
  ```

- [ ] **Step 4: Remove `SOLARUS_POT_DIAG`.** Delete every site (re-grep: `grep -n "pot_diag\|POT_DIAG" patches/mister/mister_blitter_renderer.cpp`):
  - the members + comment: `bool pot_diag = false;`, `std::unordered_set<uint64_t> pot_diag_seen;`, `static constexpr size_t POT_DIAG_MAX_LINES = 512;` and the `// [pot diag, DIAGNOSTIC ONLY] ...` comment (~711–722)
  - the entire `void pot_diag_log(...) { ... }` method (~2093–2114; closes at `  }` ~2114)
  - the three call sites and their guards: the `if (pot_diag) { ... pot_diag_log("ESC-blend", ...); }` block (~2135–2136), the `if (pot_diag) { ... pot_diag_log("ESC-upload", ...); }` block (~2172–2173), and the bare `pot_diag_log("EMIT", ...);` call (~2188). Delete the whole `if (pot_diag) { ... }` blocks (open brace through matching close), not just the inner call.
  - the parse line `self->d->pot_diag = (std::getenv("SOLARUS_POT_DIAG") != nullptr);` (~2444)

- [ ] **Step 5: Verify POT_DIAG gone + tree still builds.**

  Run: `grep -rn "pot_diag\|POT_DIAG" patches/mister/mister_blitter_renderer.cpp` → Expected: no output.
  Run the `-std=c++11` type-check → Expected: exits 0.
  Run: `bash tests/run_tests.sh` → Expected: all green.

- [ ] **Step 6: Commit.**
  ```bash
  git add patches/mister/mister_blitter_renderer.cpp
  git commit -m "cleanup(blitter): remove SOLARUS_POT_DIAG (bgplane deleted)"
  ```

---

### Task 2: Hardwire Overlay channel ON, remove `SOLARUS_OVERLAY` (Scope B)

The Overlay channel is default-ON and HW-proven. Delete its flag and dead software-fallback branch so overlay compositing is unconditional. The dead branch is the old per-surface base-SDL root-blit path (renderer ~2820–2835).

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Remove the member + parse + startup log.** Re-grep: `grep -n "overlay_enabled\|SOLARUS_OVERLAY" patches/mister/mister_blitter_renderer.cpp`.
  - Delete `bool overlay_enabled = false;` + its `// [Stage 1] Overlay channel ...` comment (~602–605).
  - Delete the parse + log block (~2461–2465):
    ```cpp
    // ...comment...
    self->d->overlay_enabled = mister_flag_default_on("SOLARUS_OVERLAY");
    if (self->d->overlay_enabled)
      std::fprintf(stderr, "[MiSTer blitter] overlay channel ENABLED (SOLARUS_OVERLAY)\n");
    ```

- [ ] **Step 2: Make the overlay-flush guard unconditional.** At ~1467, change:
  ```cpp
  if (!overlay_enabled || !overlay_touched) return;
  ```
  to:
  ```cpp
  if (!overlay_touched) return;
  ```

- [ ] **Step 3: Make the root-draw overlay unconditional and delete the dead fallback.** At ~2813, the block is currently:
  ```cpp
  if (d->overlay_enabled) {
    SDLRenderer::draw(dst, src, infos);
    d->mark_src_dirty(&dst);
    d->overlay_touched = true;
    if (d->diag) d->g_overlay_draws++;
    return;
  }
  // [Task 4] A root-surface blit ... (Only reachable with the overlay channel off ...)
  d->flush_sprites_before_other_op();
  bool emitted = d->emit_draw(src, infos, 0, 0);
  if (emitted && d->diag) d->g_blits++;
  if (d->diag && d->diag_frame_log < d->diag_frame_log_max) {
    Rectangle rb = infos.dst_rectangle();
    std::fprintf(stderr, "[blt rootblit f%d] ...", ...);
  }
  // No SDL fallback: ...
  return;
  ```
  Replace the entire span (from `if (d->overlay_enabled) {` through the final `return;` at ~2835) with the unconditional body:
  ```cpp
  SDLRenderer::draw(dst, src, infos);
  d->mark_src_dirty(&dst);      // root pixels changed -> refresh its upload
  d->overlay_touched = true;
  if (d->diag) d->g_overlay_draws++;
  return;
  ```
  (Keep the explanatory `// [Stage 1 / SOLARUS_OVERLAY] Overlay channel ...` comment above it; drop the "Only reachable with the overlay channel off" fallback comment.)

- [ ] **Step 4: Make the diag-print unconditional.** At ~3557, change:
  ```cpp
  if (d->overlay_enabled)
    std::fprintf(stderr, "[blitter overlay] draws=%ld composites=%ld dropped=%ld\n",
                 d->g_overlay_draws, d->g_overlay_blits, d->g_overlay_esc);
  ```
  to drop the `if (d->overlay_enabled)` guard (the `std::fprintf` runs unconditionally inside the existing diag block).

- [ ] **Step 5: Verify OVERLAY flag gone, FPS toggle untouched, tree builds.**

  Run: `grep -n "overlay_enabled\|SOLARUS_OVERLAY" patches/mister/mister_blitter_renderer.cpp` → Expected: no matches for `overlay_enabled` or `SOLARUS_OVERLAY`.
  Run: `grep -n "fps_overlay_enabled" patches/mister/mister_blitter_renderer.cpp` → Expected: STILL present at ~1142 and ~3911 (untouched).
  Run the `-std=c++11` type-check → Expected: exits 0.
  Run: `bash tests/run_tests.sh` → Expected: all green.

- [ ] **Step 6: Commit.**
  ```bash
  git add patches/mister/mister_blitter_renderer.cpp
  git commit -m "cleanup(blitter): hardwire overlay channel ON, remove SOLARUS_OVERLAY"
  ```

---

### Task 3: Hardwire Sprite channel ON, remove `SOLARUS_SPRITECH` (Scope B)

The Sprite channel is default-ON and HW-proven. Remove its flag and make its branches unconditional. **CRITICAL:** the `emit_draw` at ~2858 is NOT the removable fallback — it is the `rc == -1` escape path (PAL8 / colour-mod / unexpressible), reached even with the channel on. Keep it. Only the `if (d->spritech)` *conditions* are dropped.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Remove the member + parse + startup log.** Re-grep: `grep -n "\bspritech\b\|SOLARUS_SPRITECH" patches/mister/mister_blitter_renderer.cpp`.
  - Delete `bool spritech = false;` + its `// [Task 4 / Stage 2 / SOLARUS_SPRITECH] ...` comment (~732–734).
  - Delete the parse + log block (~2481–2483):
    ```cpp
    self->d->spritech = mister_flag_default_on("SOLARUS_SPRITECH");
    if (self->d->spritech)
      std::fprintf(stderr, "[MiSTer blitter] sprite channel ENABLED (SOLARUS_SPRITECH)\n");
    ```

- [ ] **Step 2: Make the pre-op sprite flush unconditional.** At ~2333, change:
  ```cpp
  if (spritech && spr_ch.count > 0) sprite_channel_flush(-1);
  ```
  to:
  ```cpp
  if (spr_ch.count > 0) sprite_channel_flush(-1);
  ```

- [ ] **Step 3: Make the sprite-channel reset unconditional.** At ~2596, change:
  ```cpp
  if (d->spritech) blt_sprite_channel_reset(&d->spr_ch);
  ```
  to:
  ```cpp
  blt_sprite_channel_reset(&d->spr_ch);
  ```

- [ ] **Step 4: Make the sprite-buffer push unconditional, KEEP the escape fallthrough.** At ~2847 the block is:
  ```cpp
  if (d->spritech) {
    int rc = d->sprite_channel_push(src, infos, d->alias_off_x, d->alias_off_y);
    if (rc == 1) { return; }
    if (rc == 0) { d->g_spr_dropped++; return; }
    d->sprite_channel_flush(-1);
  }
  bool emitted = d->emit_draw(src, infos, d->alias_off_x, d->alias_off_y);   // <- KEEP (rc==-1 escape)
  if (emitted && d->diag) d->g_sprite_blits++;
  return;
  ```
  Remove ONLY the `if (d->spritech) {` wrapper and its closing `}` — de-indent the push logic so it runs unconditionally. The `emit_draw` line and everything after it stays exactly as-is (it is the escape path when `sprite_channel_push` returns `-1`). Result:
  ```cpp
  int rc = d->sprite_channel_push(src, infos, d->alias_off_x, d->alias_off_y);
  if (rc == 1) { return; }
  if (rc == 0) { d->g_spr_dropped++; return; }
  d->sprite_channel_flush(-1);   // rc == -1: flush buffered sprites, then fall through
  bool emitted = d->emit_draw(src, infos, d->alias_off_x, d->alias_off_y);
  if (emitted && d->diag) d->g_sprite_blits++;
  return;
  ```

- [ ] **Step 5: Verify SPRITECH flag gone, escape path intact, tree builds.**

  Run: `grep -n "\bspritech\b\|SOLARUS_SPRITECH" patches/mister/mister_blitter_renderer.cpp` → Expected: no matches.
  Run: `grep -n "sprite_channel_push\|emit_draw(src, infos, d->alias_off_x" patches/mister/mister_blitter_renderer.cpp` → Expected: both still present (push logic + escape emit_draw retained).
  Run the `-std=c++11` type-check → Expected: exits 0.
  Run: `bash tests/run_tests.sh` → Expected: all green.

- [ ] **Step 6: Commit.**
  ```bash
  git add patches/mister/mister_blitter_renderer.cpp
  git commit -m "cleanup(blitter): hardwire sprite channel ON, remove SOLARUS_SPRITECH"
  ```

---

### Task 4: Remove the disconnected software-video path (Scope A)

Excise the `SOLARUS_SW` full-frame software present. `mister_present_frame()` (`mister_native_video.cpp:185–286`) is the SW-path present — never called on the shipping blitter path (`MisterBlitterRenderer::present()` overrides `SDLRenderer::present()`), and its internal `mister_poll_input()` is redundant with the renderer's own poll at :3893. Delete it, its sole consumer `native_video_writer.{c,h}`, its orphaned statics/helpers, its copy wiring, and its call site in series `0001`. **KEEP** the file `mister_native_video.{cpp,h}` (exports `mister_poll_input()` + `mister_draw_*`, both live) and the `0x3A000000` audio/control region.

**Files:**
- Delete: `patches/mister/native_video_writer.c`, `patches/mister/native_video_writer.h`
- Delete: `patches/mister/draw_prof_and_opaque_blits.patch` (orphan — grep-confirmed unreferenced by any script or series)
- Modify: `patches/mister/mister_native_video.cpp`, `patches/mister/mister_native_video.h`
- Modify: `scripts/apply_mister_files.sh:13-14`
- Modify (regenerate): `patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch`

**Interfaces:**
- Consumes: `mister_poll_input()`, `mister_draw_*` (retained in `mister_native_video`).
- Produces: nothing.

- [ ] **Step 1: Delete the SW-video writer + orphan patch file.**
  ```bash
  git rm patches/mister/native_video_writer.c patches/mister/native_video_writer.h \
         patches/mister/draw_prof_and_opaque_blits.patch
  ```

- [ ] **Step 2: Strip `mister_present_frame` + orphans from the HAL.** In `patches/mister/mister_native_video.cpp`:
  - Delete the entire `void mister_present_frame(SDL_Renderer*, SDL_Window*) { ... }` (~185–286).
  - Delete `#include "native_video_writer.h"`.
  - Delete the now-orphaned file-static state used only by `present_frame`: `s_active`, `s_init_tried`, `s_buf`, `s_rgba`, `s_warned_size`, and the `mister_present_frame`-local `s_frame`/`s_last`/`s_acc_*`/`s_n` (the last group are function-locals, removed with the function).
  - Delete `mister_abgr8888_to_rgb565` (used only by `present_frame`) **only if** post-removal grep shows no other caller: `grep -n "mister_abgr8888_to_rgb565" patches/mister/mister_native_video.cpp` → if empty after the function is gone, remove its definition + prototype too.
  - `mister_now_ms`: `grep -n "mister_now_ms" patches/mister/mister_native_video.cpp` after removal — if 0 refs remain, delete its definition; if still referenced (e.g. by profiling elsewhere in the file), keep it.
  In `patches/mister/mister_native_video.h`:
  - Delete the `void mister_present_frame(SDL_Renderer* renderer, SDL_Window* window);` declaration.
  - Delete the `mister_abgr8888_to_rgb565` / `mister_now_ms` prototypes only if their definitions were removed above.
  - **KEEP** `mister_poll_input()` and all `mister_draw_*` prototypes.

- [ ] **Step 3: Stop copying the deleted writer files.** In `scripts/apply_mister_files.sh`, delete the two lines (~13–14):
  ```bash
  cp patches/mister/native_video_writer.c   "$MDST/"
  cp patches/mister/native_video_writer.h   "$MDST/"
  ```

- [ ] **Step 4: Regenerate series `0001` to drop the present() call.** The patched hunk turns `SDLRenderer::present` into:
  ```cpp
  void SDLRenderer::present(SDL_Window* window) {
    mister_present_frame(renderer, window);
    SDL_RenderPresent(renderer);
  }
  ```
  Apply the series to a clean work tree, edit that hunk in the working copy so `present` reverts to the upstream form (drop the `mister_present_frame` call; the signature can stay `SDL_Window* /*window*/`), then re-export so line counts stay correct — do NOT hand-edit the `@@` counts:
  ```bash
  bash scripts/apply_patch_series.sh          # applies series onto pristine upstream in work/
  # edit work/solarus/src/graphics/sdlrenderer/SDLRenderer.cpp: remove the
  #   `mister_present_frame(renderer, window);` line from SDLRenderer::present()
  git -C work/solarus config diff.algorithm myers   # pin myers (patience breaks round-trip)
  bash scripts/export_patches.sh              # regenerates patches/series/*.patch
  ```
  (If `apply_patch_series.sh`/`export_patches.sh` need args, run them with `-h` first; follow `docs/superpowers/specs/2026-07-06-engine-patch-series-design.md`.)

- [ ] **Step 5: Verify the series round-trips and nothing dangling remains.**

  Run: `bash scripts/verify_patches.sh` → Expected: clean round-trip, no diff.
  Run: `grep -rn "mister_present_frame\|native_video_writer\|NativeVideoWriter" patches/` → Expected: no matches (all references gone from series, HAL, and scripts).
  Run: `grep -rn "mister_poll_input\|mister_draw_count" patches/` → Expected: STILL present (series 0001/0002 + HAL retained).

- [ ] **Step 6: Full in-container armhf build (the real gate for series + linkage).**

  Run: `bash scripts/build_engine.sh` (Docker `solarus-armhf-build:bullseye`).
  Expected: series patches `git am` clean; produces `build/armhf/libsolarus.so.1.6.5` + `build/armhf/solarus-run`; no undefined-reference to `NativeVideoWriter_*` / `mister_present_frame`.

- [ ] **Step 7: Commit.**
  ```bash
  git add -A
  git commit -m "cleanup(blitter): remove disconnected SOLARUS_SW software-video path

Deletes native_video_writer.{c,h} + mister_present_frame + orphan statics,
drops the present() hook from series 0001, and stops copying the writer files.
Keeps mister_poll_input + mister_draw_* (live via series 0001/0002) and the
shared 0x3A000000 audio/control region. Behavior-neutral: the SW path was
disconnected (black screen) and bypassed by the blitter present() override."
  ```

---

### Task 5: Fix stale comments and docs (Scope: docs)

Correct the documentation that actively misleads — the CLAUDE.md bgplane-RTL note (RTL removed in B2) and the `SOLARUS_PALETTE` "default OFF" comment/initializer (it is default-ON, exonerated).

**Files:**
- Modify: `CLAUDE.md`
- Modify: `patches/mister/mister_blitter_renderer.cpp` (comment-only)

**Interfaces:**
- Consumes: nothing. Produces: nothing.

- [ ] **Step 1: Fix the CLAUDE.md bgplane-RTL note.** In `CLAUDE.md`, find the paragraph beginning "**The bgplane RTL still physically exists**" (under the Phase-A deletion note). Replace it with the current truth:
  > **The bgplane RTL was removed in Stage 3b Phase B2** (`8f62dfc`). Only the deliberately-RESERVED wire constants remain — `OP_BGPLANE_WRITE = 8` / `BLT_F_BGCOV` in `blitter_ref.h` and one explanatory comment in `comp_src_linebuf.sv` — held so host↔RTL opcode numbering stays stable; never reuse opcode 8.
  Also delete the now-false clause stating removal "riding that phase's Quartus build" / "removed in Phase B."

- [ ] **Step 2: Fix the `SOLARUS_PALETTE` default comment + initializer annotation.** In `patches/mister/mister_blitter_renderer.cpp`:
  - At ~1012, change the comment `[PAL8 v1] Paletted composition (SOLARUS_PALETTE, default OFF).` to `... (SOLARUS_PALETTE, default ON — parsed via mister_flag_default_on in the ctor; SOLARUS_PALETTE=0 forces legacy 16bpp).`
  - At ~1020, annotate the member so it can't mislead again:
    ```cpp
    bool palette_enabled = false;   // pre-parse default only; real value set ON in ctor (mister_flag_default_on)
    ```

- [ ] **Step 3: Refresh the CLAUDE.md software-path note.** In the "Software path — disconnected, debugging only" bullet, note it is now REMOVED: change "Slated for removal." to "**Removed in Stage 4** (`native_video_writer` + `mister_present_frame` deleted); `SOLARUS_SW` is no longer a code path." Keep the surrounding architectural description as history if useful, or trim to one line.

- [ ] **Step 4: Verify + commit.**

  Run: `grep -n "still physically exists\|removed in Phase B" CLAUDE.md` → Expected: no matches.
  Run: `grep -n "default OFF" patches/mister/mister_blitter_renderer.cpp` → Expected: no SOLARUS_PALETTE "default OFF" match.
  Run the `-std=c++11` type-check → Expected: exits 0 (comment-only change).
  ```bash
  git add CLAUDE.md patches/mister/mister_blitter_renderer.cpp
  git commit -m "docs: fix stale bgplane-RTL note + SOLARUS_PALETTE default-ON comment"
  ```

---

### Task 6: HW smoke validation (operator-gated)

Behavior-neutral is a claim, not a fact, until the engine runs on device. One smoke pass confirms nothing live was cut. **NEVER self-declare visual correctness — this is the operator's eyes** (per the repo rule).

**Files:** none (deploy + observe).

- [ ] **Step 1: Refresh deploy artifacts from the build.** Copy `build/armhf/{solarus-run,libsolarus.so.1.6.5}` into the deploy tree per the deploy recipe (CLAUDE.md "Deploy recipe"); verify sha1 after upload (FAT can leave a truncated scp).

- [ ] **Step 2: Deploy to device** `192.168.20.81` via `./deploy.py --no-rbf` (Stage 4 is engine-only; the deployed B2 tilemap RBF is unchanged). Confirm lib closure + sha1 on device.

- [ ] **Step 3: Operator smoke pass.** Boot a quest (Mystery of Solarus DX). Confirm with the operator's eyes:
  - title/intro + a dialog/menu render (Overlay channel unconditional path)
  - overworld walk renders sprites correctly (Sprite channel unconditional path)
  - at least one map transition runs (Scroll-fabric + Tilemap untouched)
  - no new `[MiSTer blitter]`/engine errors in the log; frame counter (`0x3A000000`) advancing; audio flowing (confirms the shared region survived Task 4)

- [ ] **Step 4: Record the result** in `docs/superpowers/` (a short `2026-07-21-stage4-hw-validation.md`), commit, and open the PR (`feat/stage4-delete-dead-paths` → master) summarizing A/B/C + docs, with the operator confirmation. Do NOT mark Stage 4 done until the operator confirms.

---

## Self-Review

**Spec coverage:** A (Task 4) ✓; B Overlay (Task 2) ✓; B Sprite (Task 3) ✓; C ARENA_PROBE+POT_DIAG (Task 1) ✓; stale docs incl. CLAUDE.md bgplane note + SOLARUS_PALETTE comment + SW-path note (Task 5) ✓; validation posture host+typecheck+build+HW (per-task + Task 6) ✓; retained items (SCROLLFAB/TILEMAPCH/TILERESIDENT/PALETTE/reserved constants/poll_input/draw-prof/audio region/OFF_BGCACHE) protected by Global Constraints + explicit KEEP steps ✓; sequencing C→B→A ✓ (Tasks 1→2/3→4).

**Placeholder scan:** no TBD/TODO. The two conditional deletions in Task 4 Step 2 (`mister_abgr8888_to_rgb565`, `mister_now_ms`) carry an explicit grep-decision rule, not a vague "clean up." Draw-prof resolved to KEEP (live callers), not deferred.

**Type consistency:** removed symbols (`arena_probe`, `run_arena_probe`, `pot_diag`, `pot_diag_log`, `pot_diag_seen`, `overlay_enabled`, `spritech`, `mister_present_frame`, `NativeVideoWriter_*`) are each fully deleted with a grep-clean gate; retained symbols (`fps_overlay_enabled`, `sprite_channel_push`, `emit_draw`, `mister_poll_input`, `mister_draw_*`) are named consistently across tasks and asserted-present in verification steps.
