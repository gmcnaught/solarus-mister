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
  **Preload cost levers (2026-08-07, engine-only, no RBF).** Census of the shipping quest:
  335 PNGs, 1.62 MiB compressed inflating to 32.19 MiB / 31.61 Mpx, and **98.2 % of scanlines
  are filter type 0** — so libpng ARM-NEON unfiltering is a DEAD lever, it would optimise 1.8 %
  of the work; do not build it. Three levers ship instead:
  (1) **Walk prune** — `preload_prune_dir()` skips `logos/` (never drawn: the window icon is a
  no-op under `SDL_VIDEODRIVER=dummy`) and every `languages/<other>` dir, since
  `QuestFiles.cpp:289` resolves language files through `languages/<current_language>/` only.
  −16 % of decoded pixels (31.61→26.60 Mpx) and the same share of perm SDRAM. The language
  filter is engine truth: `CurrentQuest::get_language()` is already set when the preload runs,
  because MainLoop's CONSTRUCTOR runs `main.lua` (which calls `sol.main.load_settings()`) while
  `mister_preload_quest_assets()` is called later at the top of `MainLoop::run()`. If it IS
  empty the prune deliberately keeps ALL languages — never let a language asset fall through to
  lazy staging into the small mutable INTER region (that is the #84 failure mode).
  (2) **Always-PAL8** — `pal_extract_rgba` now dedups on the QUANTIZED `(RGB565, A4)` pair
  instead of source RGBA8888. That pair is all the CLUT stores, so colours the fabric cannot
  distinguish no longer each burn an entry. `9.tiles.png`, the ONLY quest asset that ever failed
  `pal_extract`, goes 258 distinct RGBA8888 → **90** distinct CLUT entries. Post-prune the whole
  quest fits: max palette 227, none over 256, CLUT at 5989/8192 (73 %). **No pixel changes value**
  — the quantization already happened one line later.
  (3) **Decode-ahead worker** (`SOLARUS_PRELOADTHREAD`, default ON; `=0` is the A/B) — patch 0047
  splits `Surface::get_surface_from_file()` into a threadable decode
  (`Surface::prefetch_image_file`) and a main-thread `create_texture()`, and the preload runs a
  worker ≤6 files ahead of the staging cursor. Upstream-sanctioned, not assumed: `Tileset::load()`
  already decodes off `ResourceProvider`'s preloader thread — which is running concurrently with
  this loop already — for exactly this reason. Tileset tiles images are skipped by the worker
  (they never go through `get_surface_from_file`). Objective gate: the preload logs
  `decode-ahead: on, N prefetch hits, M inline decodes`; **hits ≈ 0 means the worker never got in
  front and any wall-clock change came from something else.**
  (4) **No RGBA32 round-trip** (patch 0048, rides the same `SOLARUS_PRELOADTHREAD` flag).
  `Surface.cpp` converted EVERY decoded image to `Video::get_pixel_format()` =
  `SDL_PIXELFORMAT_ABGR8888` (`Video.cpp:235`), so paletted PNGs were inflated as
  palette+indices, **expanded to RGBA32, then had a palette and index plane laboriously
  re-derived** by `pal_extract_rgba` — an `SDL_GetRGBA` call plus a linear palette scan PER
  PIXEL over 26.6 Mpx. `pal_extract_indexed` (a memcpy per row) could never fire despite
  317/335 sources being paletted. `convert_to_preferred_format()` is now split out of
  `create_sdl_surface_from_file()`, with `decode_image_file_native()` /
  `adopt_prefetched_native()` around it, so the decode-ahead worker takes the palette while the
  surface is still INDEX8 and only then hands it over for the conversion the engine still needs.
  > **`pal_extract_indexed` HAD A LATENT ALPHA BUG that this made load-bearing.** It derived
  > alpha from `SDL_GetSurfaceAlphaMod()` and gave every non-colorkey entry the same value,
  > flattening a PNG's tRNS chunk to opaque. It never showed because the branch was unreachable.
  > It now reads `colors[i].a` — where SDL_image puts tRNS — and **259 of the 270 paletted quest
  > assets carry tRNS**, so getting this wrong would have made most of the quest opaque.
  **HW-validated on `.81` 2026-08-07** (`Solarus_20260807.rbf`, engine-only):
  preload **13.56 s → 9.45 s (−30 %)**, reproducible to 0.01 s over two rounds;
  `271 surfaces 8bpp-paletted, 0 CLUT-overflow, 0 truecolor->16bpp` (always-PAL8 leaves NO
  fallbacks — previously `9.tiles.png` fell to 16bpp); decode-ahead `200 prefetch hits / 51
  inline`, `palette from native decode 230 / re-derive 41`. **Equivalence evidence:** perm
  footprint is byte-identical across the A/B (`26597896` bytes both legs), footer textmatch
  100 %, and the best cross-config frame pair differs by 1960 px versus a **same-config
  animation floor of 13860-17801 px** — i.e. the two extraction paths differ by less than the
  title screen's own animation noise, with 0 diffs in the static footer band. Offline, native
  resolution matches the RGBA32 round-trip **bit-for-bit over all 270 paletted assets**.
  **Operator visual gate PASS** (2026-08-07) — the check that closes the tRNS-alpha question in
  the real renderer, since the objective checks only bound the data and the static bands.
  `SOLARUS_PRELOADTHREAD=0` is the A/B and restores both the single-threaded decode and the
  re-derive path. Full report:
  `docs/superpowers/2026-08-07-preload-decode-hw-validation.md`.
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
  tiles** directly: `blt_grid_build_ov()` detects intra-bucket overlap, and — by default
  since productization on 2026-07-23 (`SOLARUS_GRIDOV`, default ON) — that bucket
  **decomposes into ≤`BLT_GRIDOV_MAXK` non-overlapping grid sub-layers** (`blt_grid_decompose`),
  emitting K `BLT_OP_TILEMAP` commands in painter's order; it **falls back per-bucket to
  replay** only when `SOLARUS_GRIDOV=0` (legacy escape hatch) or decomposition declines
  (K > `BLT_GRIDOV_MAXK`, or GRID_BUF is full). Overlapping tiles occur in **both** interior
  walls **and some overworld maps** (e.g. map 119's composited parallax items) — the grid win
  is **per-bucket (non-overlapping static layers), NOT a map-type split**. The build is gated
  on the flag, so
  `SOLARUS_TILEMAPCH=0` is a true no-op; a fall-back bucket reserves no GRID_BUF (build+check
  precede allocation). Grids resolve pids through `frt_bram`/`cft_mem`, which the grid path
  uploads itself (FRT_UPLOAD) so a static-only scene isn't stale.
  Known SEPARATE (pre-B3, non-tilemap) issue: overworld→overworld lua-console `teleport`
  crashes non-deterministically (gdb-masked) with the tilemap AND scroll fabric BOTH off —
  a transition/retained-scene race, not a grid bug; normal walking play is unaffected.
  Requires the tilemap RBF (`Solarus_20260721.rbf`+; current ship `Solarus_20260726.rbf` =
  Stage 5 Phase 1 enlarged P_SRC cache + Phase 2 FB→DDR3 + the command-ring double-buffer
  bank mux); deploy ships engine+RBF together.
- **Software path — history, disconnected debugging path (removed Stage 4).** The plain
  `SDLRenderer` used to composite into a CPU `SDL_Surface` and a `present()` hook DMA'd
  RGB565 frames to DDR (`0x3A000000`) via `NativeVideoWriter`; current cores no longer
  scan out from DDR, so it only ever showed a black screen. **SW video-present removed
  in Stage 4** (`mister_present_frame` + `NativeVideoWriter_WriteFrame` deleted);
  `SOLARUS_SW` is no longer a code path. `native_video_writer` is retained — its
  `Init`/`ReadJoystick` serve the live controller-input path.

- **Skip-screen-blit** (`SOLARUS_SKIP_SCREEN_BLIT`, **default ON since 2026-07-22** when
  `SOLARUS_BLITTER` owns scanout; `=0` restores the stock blit). Stage 5 A9-track lever SW-3:
  `Video::render` (`work/solarus/src/graphics/Video.cpp`) did a full 320×240 `screen_surface->clear()`
  + root→screen copy every frame, but on the fabric path `screen_surface` has **no scanout consumer**
  — the overlay uploads the ROOT surface (`g_tagged_root`), the fabric scans out its own on-chip FB,
  and `video:on_draw` (screen_surface's only other writer) is already invisible in MiSTer. So the blit
  is dead work; SW-3 skips it (never on the shader path). HW-validated 2026-07-22 (map3 A/B:
  `[MiSTer draw]` composite 1.8→0 ms, standing A9 15.4→9.5 ms, **fps 31→53** — the win compounds via
  step-amplification, fewer game-logic catch-up steps at higher fps; operator visual gate PASS —
  `docs/superpowers/2026-07-22-stage5-a9-skip-screen-blit-hw-validation.md`). Engine-only, no RBF.
  The measure-first arc that found it refuted four pre-designed per-drawable levers first
  (`docs/superpowers/2026-07-22-stage5-a9-{drawsplit,drawresidsplit}-decision.md`).
- **Command-ring double-buffer** (`SOLARUS_RINGDBUF`, **default ON since 2026-07-26**;
  `=0` disables the overlap). Gives the blitter command ring a second bank so the A9 can
  build frame S+1 while the fabric composites frame S — frame period goes from `A9 +
  fabric` (serialized) to `max(A9, fabric, 16.69ms cap)`. HW-validated 2026-07-26:
  **map 119 +43%** (29.4→42.6 fps), **map 3 + dialog +52%** (33→50.5 fps), `fabric_hw`
  IDENTICAL across both legs of both scenes (the clean-A/B proof that the win is purely
  overlap, not less work); tear test 0 over-windows, 11-teleport soak clean, `dfq_drop=0`,
  operator visual gate PASS
  (`docs/superpowers/2026-07-26-ring-dbuf-hw-validation.md`).
  **RTL changed** (bank mux, `C_DONE = done+1` semantics, a publish-spacing tear guard) so
  this ships with a **new RBF**.
  > **THE ENGINE AND RBF ARE A MATCHED PAIR — `SOLARUS_RINGDBUF=0` IS NOT AN OLD-RBF
  > COMPAT LEG.** `OFF_HEAP` moved `0x80000`→`0x100000` **unconditionally** (to make room
  > for bank 1's ctrl+ring) and the fabric's `SRC_QW` moved with it, so this engine reads
  > every `OP_STAGE` source from the new base regardless of the flag. Pair it with any
  > pre-ring-dbuf bitstream and atlases are fetched 512 KiB low → **silently garbage
  > tiles**, flag on or off. There is no version handshake to catch this. Deploy
  > engine+RBF together, and the rollback unit is the pair.
  Spec: `docs/superpowers/specs/2026-07-26-ring-double-buffer-design.md`.

Both build with `-force-software-rendering` (no OpenGL/Mesa anywhere). The fabric
datapath/dataflow is documented in `docs/frame-dataflow.md`.

**Engine source layout.** Downstream MiSTer mods enter the build (`scripts/build_engine.sh`)
two ways: (1) a reviewable **git-am series** (`patches/series/*.patch`, applied to
pristine upstream), and (2) **whole-file copies** under `patches/mister/` (via
`scripts/apply_mister_files.sh`). `mister_blitter_renderer.{cpp,h}` and all of
`patches/mister/blitter/` are whole-file copies — edit them DIRECTLY; they are NOT
in the series, so nothing to regenerate. `grep <symbol> patches/series/0001*.patch`
to check whether something lives in the series before touching it.

> **ADDING A NEW HEADER THE RENDERER INCLUDES? Register it in
> `scripts/apply_mister_files.sh` or the engine build WILL fail.** That script is what
> copies the whole-file additions into the engine tree; a header that is not listed
> simply does not exist there, and `build_engine.sh` dies with
> `<name>.h: No such file or directory`.
>
> **The local type-check cannot catch this** — the recipe below passes
> `-I patches/mister`, where the header *does* exist, so it passes happily on a tree
> that cannot build an engine. Neither can the host suite (it doesn't compile the
> renderer) nor code review (the source is correct). Only the engine cross-build or CI
> sees it.
>
> This has now bitten **twice**: `mister_blend_layer.h` (PR #149) and `mister_pace.h`
> (PR #152, where it survived a type-check and two clean code reviews). After adding
> any `patches/mister/*.h` that the renderer `#include`s, run
> `scripts/docker_run.sh scripts/build_engine.sh` before believing the branch is sound.

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

**Solarus 2.x — opt-in TEST OPTION, not a replacement (`docs/solarus2.md`).** A
second engine line builds upstream **v2.1.0 + `patches/series2/` + `patches/mister/`**
via `scripts/build_engine2.sh` into `work/solarus2` → `build/armhf-v2`, deploys to
`/media/fat/games/Solarus/v2/` via `scripts/deploy_engine2.sh`, and is selected at
launch by `SOLARUS_ENGINE=2` in `diag.env`. **It IS offloaded to the fabric** — the
blitter renderer, tile channels, overlay, sprite channel and DDR video/audio hooks
are all in it — but **none of the 1.6 perf series (0003–0036) is ported**, so expect
it to be slower than the 1.6 ship build. **HW-validated 2026-08-07 on `.81` for a
STATIC scene only** (`docs/superpowers/2026-08-07-solarus2-fabric-hw-validation.md`):
title `textmatch` 100 %, and a parked map-119 frame **99.92 % pixel-exact against the
1.6 engine** — motion, soak and audio are still unobserved.
`SOLARUS2_STOCK=1` still builds pristine upstream (no patch phase, no picture) as a
reference leg; pair it with `SOLARUS_ENGINE2_STOCK=1` in `diag.env`, which is what
tells `solarus_run.sh` to skip the blitter exports and always capture the log.
Five things to know before touching it: (1) the 46-patch 1.6 series CANNOT apply to
2.x (`src/main/Main.cpp` → `cli/src/main.cpp`, `Renderer` gained
`notify_target_changed()` and a `margin` arg on `create_texture()`), which is why
the 2.x line has its OWN re-derived series — edit it via
`scripts/apply_patch_series2.sh` → commit in `work/solarus2` →
`scripts/export_patches2.sh`; (2) `patches/mister/` is SHARED VERBATIM between the
two lines — the only version switch is `mister_dst_view_offset()` in
`mister_blitter_renderer.cpp`, guarded by `SOLARUS_MAJOR_VERSION >= 2`, because 2.x
moved the camera scroll into a per-surface `View` and draws entities in MAP
coordinates; **an edit there must type-check against BOTH trees**; (3) 2.x needs
**SDL2 ≥ 2.0.18** so the lean `scripts/build_sdl2.sh` prefix is MANDATORY there
(stock bullseye :armhf is 2.0.14) — there is no `SOLARUS_ALLOW_STOCK_SDL2` escape
hatch on that path; (4) 1.6-format quests DO run on 2.x (upstream
`check_version_compatibility`), so the shipping `.sol` works unchanged; (5) the
fabric ABI is shared, so a 2.x engine needs the SAME current RBF as the ship build
— the engine↔RBF pairing warning above applies to it identically. `deploy.py` knows
nothing about this line and must stay that way.

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
2-5. **[DONE]** Headless boot, video hook, first quest, input + audio — all
   shipped and HW-validated; see the Rendering architecture note at the top and
   the Deploy recipe below for the current state.

## Invocation (target)

```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH=/media/fat/games/solarus/libs:. \
  ./solarus-run -force-software-rendering quests/mystery_of_solarus_dx.solarus 2>&1 | tee /tmp/solarus.log'
```

## Deploy recipe (end-user SD-mirror, task 007 — VALIDATED on HW)

Full recipe — SD-mirror layout, quest packaging (`.sol`), OSD quest selection,
launch env, `./deploy.py [--no-rbf] [--host IP]` — lives in
**`docs/deploy-recipe.md`**. Read it before deploying.

**Testing a release** — tag an RC from master, validate it with
`scripts/release_test.sh`, then publish the tested artifacts with their CI
run-ids pinned. Recipe: **`docs/release-testing.md`**. Note Gate 2 WIPES the
Solarus install on the device (quests and `controls.cfg` are preserved) — that
is deliberate, and it is what makes a packaging defect fail loudly.

**Device gotchas (learned) — apply to ANY push to the device:** busybox has **no
`pkill`** (use `kill -9 $(pidof solarus-run)`); FAT **can't overwrite an open
exe** in place (rm the old binary first, AND a partial scp leaves a truncated
file — verify sha1 after upload); FAT can't chown (busybox `tar -xof`, macOS
`tar --no-xattrs --no-mac-metadata` to avoid `._` AppleDouble files); **FAT is
CASE-INSENSITIVE** so `games/solarus` == `games/Solarus` (setname capital-S merges
with any old lowercase install — no separate dir).

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
