# solarus-mister — porting notes

Port the **Solarus 1.6.5** engine to MiSTer. Engine-build project (like
`../epic-mister-sdl-buffer-output`), NOT per-game packaging. Device IP
`192.168.20.81`; deploy root `/media/fat/games/solarus/`.

**Rendering architecture (current).** One real render path, set up in
`games/Solarus/solarus_run.sh`:
- **FPGA compositor** (`SOLARUS_BLITTER=1` + `SOLARUS_BLITTER_SINGLEBUF=1`,
  default ON, HW-validated shipping path). A `MisterBlitterRenderer` subclasses
  Solarus's `SDLRenderer` and turns every clear/fill/draw into a hardware **blit
  command** (`blt_emitter` → DDR command ring; map tile layers collapse into
  per-layer `BLT_OP_TILELIST` commands, #52). The FPGA fabric (`blitter_top` →
  `comp_pipeline`, an issue-interval-1 compositor, #36) composites each frame into an
  **on-chip WORK framebuffer** (`comp_fbram`, PR #49). **Stage 5 Phase 2 (FB→DDR3, PR #138,
  HW-validated 2026-07-22, ships `Solarus_20260723.rbf`)** moved the *scanout copy* off-chip:
  a per-vblank `fb_ddr_writer` bursts the finished WORK frame into a **DDR3 double-buffer**
  (`0x3A000040`/`0x3A040040`, fabric-owned `fb_bank` alternation) and the OpenBOR reader scans
  it out via `ddr3_scan_adapter` (reader un-bridged; `ddr_blitter_arb` now 3-master,
  reader>scanout>blitter). This deleted the on-chip SCAN banks (**89%→61% BRAM, ~158 M10K
  freed**), is perf-neutral (HW A/B fps==baseline; WORK stays on-chip so the composite RMW never
  touches DDR3). The snapshot writes the **inactive** buffer, so it needs NO vblank gate —
  removing that gate (`S_SNAP_WAIT`) was THE fps fix (the old gate sat in the frame critical
  path, ~16.7ms/frame; a faster writer was a red herring). Tear-free = the reader's own
  once-per-vblank control-word poll (operator-confirmed). So the scanout FB copy now DOES cross
  the f2h bus into DDR3 (was: on-chip only). **Source atlases are preloaded whole-quest into
  SDRAM** at load (#66, 128 MB module, jtframe XL) — the SEPARATE SDRAM chip, never DDR3, so
  source fetch and FB traffic don't contend. The A9 never composites.
  The compositor reads atlas pixels through an on-chip **P_SRC cache** (`sdram_fb_cache`
  ch5, a jtframe 4-way set-associative cache). **Stage 5 Phase 1** enlarged it via a
  decoupled `SRC_BLOCKS=128` param (32 KB, SETS=32; was `RO_BLOCKS=2` = 512 B) — HW-validated
  fetch-stall fix, map119 compositor 3.66× / fps 11.9→19.9, ships in `Solarus_20260722.rbf`
  (`docs/superpowers/2026-07-22-stage5-source-cache-hw-validation.md`). `SRC_BLOCKS` must give a
  power-of-2 set count (jtframe bit-slices the set index), so it is one of {4,8,…,128,256}, ch5
  ONLY (P_SCAN/ch4 stays `RO_BLOCKS`).
- **Per-layer static plane bake — DELETED (Stage 3b Phase A, 2026-07-20).** `SOLARUS_BGPLANE`
  no longer exists; setting it does nothing. The bake pre-rendered each map's static tile layers
  into per-layer ARGB4444 planes in an SDRAM arena, and was HW-proven to be the single cause of
  the scroll seam (#122), the transition hitch + bg-colour flash (#127), and the scroll black
  frame (#123). It was flipped default-OFF on 2026-07-20 and removed outright the same day
  (~1,400 lines: the bake bodies, the `bg_planes` state, the SDRAM arena, three geometry headers,
  five host tests, and two engine patches). #122 and #123 are closed by HW validation
  (`docs/superpowers/2026-07-20-stage3b-phaseA-hw-validation.md`); #127's scroll leg passes but
  it stays open pending a fade-transition observation.
  Static tiles now always take the per-bucket replay path in `resident_emit_static_layer()` —
  the path `SOLARUS_BGPLANE=0` already selected, so removal was behaviour-neutral.
  **Two things were deliberately retained, do not "clean them up":** `BLT_OP_BGPLANE_WRITE = 8`
  and `BLT_F_BGCOV = 0x80` in `blitter_ref.h` are held as RESERVED wire-ABI constants so
  host↔RTL numbering stays stable and `test_wire_constants.py` passes unedited — Phase B must
  allocate a *fresh* opcode, never recycle 8; and `blt_fill_flags()` is kept as a generic emitter
  API though currently callerless.
  **The bgplane RTL was removed in Stage 3b Phase B2** (`8f62dfc`). Only the
  deliberately-RESERVED wire constants remain — `OP_BGPLANE_WRITE = 8` / `BLT_F_BGCOV`
  in `blitter_ref.h` and one explanatory comment in `comp_src_linebuf.sv` — held so
  host↔RTL opcode numbering stays stable; never reuse opcode 8.
- **Overlay channel** (`SOLARUS_OVERLAY`, **default ON** since the Stage 1 retained-scene
  work; `SOLARUS_OVERLAY=0` forces off). Screen-space draws onto the **root surface**
  (HUD, dialog, menu, title, intro, Lua `main_on_draw`/`game_on_draw`) no longer go to
  the fabric individually: they render via stock base SDL into the root — which
  `SDLRenderer::clear()` zeroes to a fully transparent `(0,0,0,0)` ARGB buffer — and the
  whole root is uploaded ARGB4444 and composited **last**, per-pixel alpha, as one
  full-screen `OP_BLIT`+`BLT_BLEND_PALPHA` before `blt_end_frame`. **No RTL**: the ring
  executes in order, so "composited last" just means "emitted last". This ends the
  aliased-surface loss class (draws that fell through to base SDL and were never
  presented, since `present()` never calls `SDLRenderer::present()`). Root identification
  is engine truth via `mister_tag_root_surface` (MainLoop), not a first-wins heuristic.
  Note render targets are **premultiplied** (`Surface::create(w,h)` defaults
  `premultiplied=true`) while `PALPHA` is straight source-over, so ARGB4444 uploads of
  such surfaces go through `mpix::to_argb4444_unpremultiplied`. Cosmetic residual:
  translucent menus under-dim the world (#124); `fill()` is deliberately NOT routed here
  (fades keep `blt_fill_alpha`'s 8-bit alpha rather than ARGB4444's 16 levels).
  **Overlay content-identity skip** (`SOLARUS_OVERLAYSKIP`, **default ON since 2026-07-22**;
  `=0` forces the per-frame re-upload). Stage 5 A9-track lever: the root is cleared+repainted
  every frame so it is always dirty, but the *result* is usually pixel-identical (static HUD),
  so `upload()` re-converts+re-uploads the whole 320×240 ARGB4444 root every frame for nothing —
  the #1 host-CPU cost (`present` ~6.5 ms). The renderer folds each root draw's op params
  (src ptr, src/dst rects, blend, opacity, rotation, scale, color — `mister_overlay_id.h`) into
  a per-frame **op-param digest**, plus a **per-frame source-mutation** set (`written_this_frame`,
  NOT the persistent `dirty_src`). When the digest matches last frame AND no source was rewritten
  this frame, it drops the root from `dirty_src` so `upload()` returns the cached ref without
  reconverting — the cached blit is still emitted. The mutation set is the stale-HUD guard (a HUD
  value change re-renders its source → marked → forces non-skip). HW-validated 2026-07-22
  (present −90 %, A9 −7…−10 ms, fps up; guard fires on HUD change; operator gate PASS —
  `docs/superpowers/2026-07-22-stage5-a9-overlay-skip-hw-validation.md`). Engine-only, no RBF.
- **Sprite channel** (`SOLARUS_SPRITECH`, **default ON since 2026-07-20**; `=0` restores
  the direct `emit_draw` path). Stage 2 of the retained-scene migration: an ordered
  per-frame sprite list replacing the `alias_target` replay, Z-correct by emission
  order. HW-validated 2026-07-19 (~16k frames, 218k sprites).
- **Scroll fabric path** (`SOLARUS_SCROLLFAB`, **default ON since 2026-07-20**; `=0`
  restores the `g_transition_scroll` software path, deliberately retained as the escape
  hatch). Stage 3a: composites a scrolling map transition on the fabric — engine-truth
  scroll offsets, the camera alias pointed at the scrolled offset, and the old map
  emitted as a normal fabric blit — instead of falling back to a full software map
  render. HW-validated 2026-07-20 (`docs/superpowers/2026-07-20-stage3a-hw-validation.md`):
  fabric branch fires, no fully-clipped old-map blit across 116 windows, both axes
  sign-correct, overflow/dropped 0.
- **Tilemap channel** (`SOLARUS_TILEMAPCH`, **default ON since 2026-07-21**; `=0` forces
  replay). Stage 3b B3: static tile layers composite as one **`BLT_OP_TILEMAP`** grid-walk
  command per bucket (an 8px per-cell pattern-index grid in a 2 MiB DDR GRID_BUF,
  `blitter_top.sv` walks it, resolving each cell through the shared CFT/FRT pattern tables)
  instead of a per-tile `OP_TILELIST` replay. HW-validated 2026-07-21 (overworld, interiors,
  map 119 parallax, map 3). **Two load-bearing facts:** (1) `cells_off` in the header is
  **GRID_BUF-RELATIVE** (the fabric adds `GRID_BUF_QW`) — the host allocator (`grid_alloc.h`)
  hands out 0-based offsets and the DDR write adds `OFF_GRIDBUF`; passing a ddr-relative
  offset = garbage. (2) The one-pid-per-cell grid **cannot represent OVERLAPPING static
  tiles**: `blt_grid_build_ov()` detects intra-bucket overlap and that bucket **falls back
  per-bucket to replay**. Overlapping tiles occur in **both** interior walls **and some
  overworld maps** (e.g. map 119's composited parallax items) — the grid win is **per-bucket
  (non-overlapping static layers), NOT a map-type split**. The build is gated on the flag, so
  `SOLARUS_TILEMAPCH=0` is a true no-op; a fall-back bucket reserves no GRID_BUF (build+check
  precede allocation). Grids resolve pids through `frt_bram`/`cft_mem`, which the grid path
  uploads itself (FRT_UPLOAD) so a static-only scene isn't stale.
  Known SEPARATE (pre-B3, non-tilemap) issue: overworld→overworld lua-console `teleport`
  crashes non-deterministically (gdb-masked) with the tilemap AND scroll fabric BOTH off —
  a transition/retained-scene race, not a grid bug; normal walking play is unaffected.
  Requires the tilemap RBF (`Solarus_20260721.rbf`+; current ship `Solarus_20260723.rbf` =
  Stage 5 Phase 1 enlarged P_SRC cache + Phase 2 FB→DDR3); deploy ships engine+RBF together.
- **Software path — history, disconnected debugging path (removed Stage 4).** The plain
  `SDLRenderer` used to composite into a CPU `SDL_Surface` and a `present()` hook DMA'd
  RGB565 frames to DDR (`0x3A000000`) via `NativeVideoWriter`; current cores no longer
  scan out from DDR, so it only ever showed a black screen. **SW video-present removed
  in Stage 4** (`mister_present_frame` + `NativeVideoWriter_WriteFrame` deleted);
  `SOLARUS_SW` is no longer a code path. `native_video_writer` is retained — its
  `Init`/`ReadJoystick` serve the live controller-input path.

Both build with `-force-software-rendering` (no OpenGL/Mesa anywhere). The fabric
datapath/dataflow is documented in `docs/frame-dataflow.md`.

**Engine source layout.** Downstream MiSTer mods enter the build (`scripts/build_engine.sh`)
two ways: (1) a reviewable **git-am series** (`patches/series/*.patch`, applied to
pristine upstream), and (2) **whole-file copies** under `patches/mister/` (via
`scripts/apply_mister_files.sh`). `mister_blitter_renderer.{cpp,h}` and all of
`patches/mister/blitter/` are whole-file copies — edit them DIRECTLY; they are NOT
in the series, so nothing to regenerate. `grep <symbol> patches/series/0001*.patch`
to check whether something lives in the series before touching it.

**Host tests + quick renderer check.** `bash tests/run_tests.sh` runs the host suite —
C/C++ tests that MODEL the engine-side logic against the blitter emitter/ref
(`patches/mister/blitter/`); they do NOT compile the renderer. To type-check a
renderer edit natively (no armhf Docker): `g++ -fsyntax-only -std=c++17
-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO -I patches/mister
-I patches/mister/blitter -I work/solarus/include -I build/armhf/include
-I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags)
patches/mister/mister_blitter_renderer.cpp`. The two `-D` flags are **mandatory**:
`scripts/build_engine.sh` defines them unconditionally, and nearly the entire renderer
implementation lives inside `#ifdef MISTER_NATIVE_VIDEO` — omit them and this command
type-checks almost nothing, printing success even when the file has hard errors
(this already produced one falsely-passing verification on this branch).

Upstream: `https://gitlab.com/solarus-games/solarus` (GPLv3), tag/branch `v1.6`
(version 1.6.5). API id for raw/tree fetch: project `solarus-games%2Fsolarus`.

## Why this is viable (verified — do not re-litigate)

Solarus has a built-in software renderer; OpenGL is optional (only for shaders).
Evidence in upstream `v1.6`:
- `src/graphics/Video.cpp`: arg `-force-software-rendering` → window WITHOUT
  `SDL_WINDOW_OPENGL`; renderer = `create_chain<GlRenderer, SDLRenderer>` (GL
  first, SDL software fallback); force-software skips GL entirely.
- `src/graphics/sdlrenderer/SDLRenderer.cpp`:
  - `create()`: force_software → `SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER,
    "software", OVERRIDE)` + `SDL_CreateRenderer(window,-1,SDL_RENDERER_SOFTWARE)`.
  - Windowless ctor: `software_screen = SDL_CreateRGBSurface(...)` then
    `renderer = SDL_CreateSoftwareRenderer(software_screen)` → game composites to
    a CPU surface in system memory.
  - `present()` ends with `SDL_RenderPresent(renderer)` — **the DDR hook point**.

## DDR sink (OpenBOR-derived writer)

> This is the **transitional software-path** transport (being retired). The
> primary path is the FPGA compositor (see the Rendering architecture note at the
> top + `docs/frame-dataflow.md`), where the fabric composites into an SDRAM
> framebuffer and `present()` only submits the command ring — `NativeVideoWriter`
> full-frame DMA is bypassed.

The blitter already writes frames to MiSTer DDR at `0x3A000000` via a
`NativeVideoWriter` whose DDR layout matches the **MiSTer OpenBOR** core
(`OpenBOR_7533`) — the same core this project's RBF is forked from
(`fpga/rtl/openbor_video_reader.sv`). It is engine-agnostic (takes a CPU pixel
buffer + WxH + format). Solarus `software_screen` is an `SDL_Surface` (RGBA8888/RGB)
at the quest's native size (usually 320×240) — convert to the DDR format (RGB565 per
`blitter-config-and-launch`/`fps-profiling-shaders` memories) and write.

## Build phases

0. **[DONE] De-risk** — software path confirmed (above).
1. **[DONE] Engine build, armhf.** `scripts/build_engine.sh` in
   `solarus-armhf-build:bullseye` → `build/armhf/solarus-run` +
   `libsolarus.so.1.6.5`. All :armhf deps resolved from apt. **No libGL/GLEW
   DT_NEEDED** (libgl-dev not installed → find_package(OpenGL) empty → GL
   renderer compiled out). DT_NEEDED: SDL2/image/ttf, openal, physfs,
   vorbis(file), modplug, libluajit-5.1.so.2, pthread/stdc++/m/gcc_s/c. **LuaJIT is
   now the default** (issue #26): `scripts/build_luajit.sh` cross-builds armhf LuaJIT
   2.1 into `build/luajit-armhf`; `build_engine.sh` defaults `SOLARUS_USE_LUAJIT=1`
   (set =0 for vanilla Lua 5.1). HW-validated full JIT on the A9 (`jit.status()=true
   ARMv7 VFPv3`); ~20-30% A9 win in gameplay (gameplay Lua is C-API-bound so it's
   short of the title's 4.5x — does not alone reach 60fps). Ship `libluajit-5.1.so.2`
   in libs/. Original notes:
   Cross-compile Solarus 1.6.5 in the epic Docker arm
   toolchain. CMake: disable OpenGL/GLEW (software only — shaders unavailable, ok).
   Deps to cross-build/provide (all must be armhf, glibc ≤2.31 / focal like the
   Mesa builds): SDL2, SDL2_image, SDL2_ttf, Lua 5.1 or **LuaJIT** (ARM32 ok),
   OpenAL-soft, libvorbis/ogg, libmodplug, physfs. Output: `solarus-run` binary.
   Note PortMaster ships per-game `libmodplug.so.1` + `libphysfs.so.1` — confirms
   those are the dynamic deps to ship.
2. **Headless boot.** No X / no `/dev/dri` on MiSTer. Run SDL2 with the **dummy**
   video driver (`SDL_VIDEODRIVER=dummy`) so the windowless
   `SDL_CreateSoftwareRenderer(software_screen)` path is taken. Goal: engine
   reaches the main loop without a display.
3. **DDR video hook.** Patch `SDLRenderer::present()` (or post-`SDL_RenderPresent`)
   to push `software_screen` → `NativeVideoWriter` (`patches/` holds the diff).
   Verify frames hit DDR: `busybox devmem 0x3A000000` increments.
4. **First quest.** Mystery of Solarus DX (free official). Run
   `solarus-run quests/mystery_of_solarus_dx.solarus`. (Quest data is byo — the
   PortMaster port zip carries only libs + scripts, not the `.solarus`; fetch the
   quest from solarus-games.org. `scripts/fetch_quest.sh`.)
5. **Input + audio.** Map MiSTer controllers (SDL_GameController / the gptk map
   `zmos.gptk` from the port for reference); OpenAL → ALSA.

## Invocation (target)

```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH=/media/fat/games/solarus/libs:. \
  ./solarus-run -force-software-rendering quests/mystery_of_solarus_dx.solarus 2>&1 | tee /tmp/solarus.log'
```

## Deploy recipe (end-user SD-mirror, task 007 — VALIDATED on HW 2026-06-12)

The repo IS the MiSTer SD-mirror tree (extracts to `/media/fat/`), modeled on
MiSTer_OpenBOR. End-user model: load the **Solarus** core from the MiSTer OSD →
Master_Daemon (Frontier) routes by CORENAME → runs `games/Solarus/_handler.sh` →
engine auto-launches; pick a quest from the native OSD file browser.

Layout (committed parts in **bold**; the rest are gitignored ship artifacts):
- `_Other/Solarus_YYYYMMDD.rbf` — branded core (CONF_STR setname=Solarus, `SC0,SOL`
  Load-Quest slot). Built in CI; `gh run download <id> -n solarus-rbf`. NOT committed.
- `games/Solarus/solarus-run` + `libs/` — engine + .so closure. Refresh from
  `build/armhf/{solarus-run,libsolarus.so.1.6.5}`. NOT committed.
- **`games/Solarus/_handler.sh`** — Master_Daemon auto-launch dispatcher.
- **`games/Solarus/solarus_run.sh`** — shared launch logic (env + quest resolve +
  exec), called by BOTH the handler and the Scripts launcher.
- `games/Solarus/quests/<name>.sol` — quests. NOT committed.
- **`scripts/Solarus.sh`** → deploys to `/media/fat/Scripts/Solarus.sh` (manual
  launcher: load_core + run shared logic).
- **`docs/Solarus/README.md`**, **`version.txt`**, **`README.md`**.

Quest packaging: a `.sol` IS a `data.solarus` archive = a zip of the quest's
`data/` CONTENTS (quest files at the zip ROOT, NOT under a `data/` prefix; MiSTer
OSD filters the 3-char `SOL` extension). `scripts/package_quest.sh <quest_dir>
[out.sol]`. `solarus-run` needs a quest DIRECTORY, so the handler indirects:
`ln -sf <picked.sol> /tmp/solarus_quest/data.solarus` then
`exec ./solarus-run -force-software-rendering /tmp/solarus_quest`.

Quest selection: the OSD writes the picked path to `/media/fat/config/Solarus.s0`
(may have trailing `\r`/junk — trim CR and cut at the first `.sol`).
`quest_manager.sh` polls it by mtime (a stale `.s0` from a prior session is NOT
auto-loaded) and launches/switches the engine on a pick. **No fallback** — the
core idles until a quest is picked (PICO-8/OpenBOR/PSX pattern). Auto-launch
comes from `solarus_daemon.sh` (Frontier-independent core-load watcher,
self-registers into `user-startup.sh`; defers to Frontier's Master_Daemon if
that is running).

Launch env: `SDL_VIDEODRIVER=dummy`, `LD_LIBRARY_PATH=<gamedir>/libs:<gamedir>`,
flag `-force-software-rendering`.

`./deploy.py [--no-rbf] [--host IP]` pushes the tree over SSH (key-authed; plain
ssh/scp/tar, no paramiko). **Device gotchas (learned):** busybox has **no
`pkill`** (use `kill -9 $(pidof solarus-run)`); FAT **can't overwrite an open
exe** in place (rm the old binary first, AND a partial scp leaves a truncated
file — verify sha1 after upload); FAT can't chown (busybox `tar -xof`, macOS
`tar --no-xattrs --no-mac-metadata` to avoid `._` AppleDouble files); **FAT is
CASE-INSENSITIVE** so `games/solarus` == `games/Solarus` (setname capital-S merges
with any old lowercase install — no separate dir).

HW validation 2026-06-12: core load → CORENAME=Solarus; `_handler.sh` fired;
both s0-pick and quests/ fallback paths resolved; engine booted ("Opening quest
'/tmp/solarus_quest'", "Quest format: 1.6"); video frame counter (`0x3A000000`)
advancing; audio ring (`0x3A000030`/`0x38`) flowing+wrapping ("Connected to audio
device 'Loopback'"); joypad enabled; live title-screen screenshot captured.

## Perf outlook

Solarus games are 2D tile + sprite blits at ~320×240, no 3D. Even so, the
per-frame software composite dominated the A9 on heavy overworlds (~20 fps), which
is the whole motivation for the FPGA compositor: the A9 emits blit commands and the
fabric does the pixels (~45 fps standing overworld on the earlier fabric blitter,
targeting 60). Lua quest scripting (LuaJIT) is the remaining A9 variable to watch
on script-heavy quests.

## Asset / licensing

Engine GPLv3. Quests are individually licensed; Mystery of Solarus DX is free
(GPL/CC, by the Solarus team). Keep engine binaries + quest data OUT of git;
`scripts/` re-fetches.
