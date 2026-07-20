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
  `comp_pipeline`, an issue-interval-1 compositor, #36) builds each frame in an
  **on-chip BRAM framebuffer** (`comp_fbram`, PR #49; the fabric snapshots
  WORK→SCAN at vblank for tear-free scanout); **source atlases are preloaded
  whole-quest into SDRAM** at load (#66, 128 MB module, jtframe XL). No frame
  pixels cross the f2h bus and none live in SDRAM. The A9 never composites.
- **Per-layer static plane bake** (`SOLARUS_BGPLANE`, **default OFF since 2026-07-20**;
  was default ON from PR #121. `SOLARUS_BGPLANE=1` restores it). Each map's static tile
  layers bake once into per-layer ARGB4444 planes in a dedicated SDRAM arena
  (`bg_planes`), then render as one plane COPY/frame instead of per-tile-per-frame
  BLENDs — a parallax fabric win. **Turned back off because the bake is the single
  cause of three HW-confirmed defects:** the scroll seam rendering the incoming map as
  plain `background_color` (#122), the transition hitch + bg-colour flash on *every*
  transition type (#127), and probably the scroll black frame (#123). Attribution is a
  single-variable HW comparison — the seam defect reproduces with `SOLARUS_SCROLLFAB`
  both ON and OFF, and vanishes only with the bake disabled. Cost: parallax throughput
  (map 119 was already 15–19 fps *with* the bake, and raising it is a Stage 3b goal, so
  the number could not change the decision). **Stage 3b deletes the bake outright**, at
  which point the flag and subsystem go away. The bake ran synchronously at map-load
  (`bake_all_planes_sync`; `SOLARUS_BGPLANE_SYNC=0` = legacy one-cell-per-frame).
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
- **Software path — disconnected, debugging only** (`SOLARUS_SW=1`, or if the
  DDR map fails). The plain `SDLRenderer` composites into a CPU `SDL_Surface`;
  a `present()` hook DMAs RGB565 frames to DDR (`0x3A000000`) via
  `NativeVideoWriter`. Current cores **no longer scan out from DDR**, so this
  path shows a black screen — never use it as an A/B video reference (use
  full-datapath sim instead). Slated for removal.

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
