# Solarus 2.x — test option

A **second, opt-in engine line** alongside the shipping Solarus 1.6.5 build. It
replaces nothing: `scripts/build_engine.sh`, `deploy.py`, the patch series and the
RBF pairing are all untouched, and a device that never sets `SOLARUS_ENGINE=2`
never runs a line of this.

Upstream pin: **v2.1.0** (`09d45b3c40ab08388eee29e285903e8e3b90a4cc`), set in
`scripts/lib/patch_common.sh` as `SOLARUS2_REF` / `SOLARUS2_SHA`.

## Read this before you try it

**The 2.x build produces no picture on the device.** It is *pristine upstream*.
None of the downstream MiSTer work is in it — no FPGA-blitter renderer, no DDR
video or audio hooks, no perf patches. Under `SDL_VIDEODRIVER=dummy` the engine
composites into a CPU surface that nothing scans out, exactly as stock Solarus
would on a headless box.

What it *does* do, and what it is for right now:

| | works on the 2.x test build |
|---|---|
| cross-builds armhf against our lean SDL2 + LuaJIT | yes |
| links with no `libGL`/`libGLEW`/`libEGL` DT_NEEDED | yes, asserted by the build |
| boots, loads an OSD-picked quest, runs game logic | yes, headless |
| controller input (SDL evdev joystick) | expected to; unverified on HW |
| audio (OpenAL → ALSA) | expected to; unverified on HW |
| **video** | **no — nothing reaches the screen** |
| MiSTer perf work (blitter, tilemap channel, overlay, ring dbuf) | no, none of it exists here |

So it answers "does 2.x build, link and run on the A9 at all, against our
toolchain and our quest?" — the question you have to answer *before* deciding
whether porting the renderer is worth it. It does not answer "is 2.x faster".

## Why the build is stock, and not "the 1.6 series applied to 2.x"

The 46 patches in `patches/series/` are authored against pristine 1.6.5 and
cannot apply to 2.x. This is not a matter of fuzz:

- `src/main/Main.cpp`, which patch 0001 touches, **no longer exists** — the CLI
  moved to `cli/src/main.cpp` behind a `SOLARUS_CLI` option.
- The files the series leans on hardest have all drifted heavily:
  `src/core/MainLoop.cpp` (+151 lines), `src/entities/Entities.cpp` (+188),
  `src/graphics/Video.cpp` (+68), `src/graphics/Surface.cpp` (+57).
- The `Renderer` interface itself changed, which matters because
  `MisterBlitterRenderer` subclasses `SDLRenderer`: `create_texture()` gained a
  `margin` argument and a new pure-virtual `notify_target_changed()` appeared.
- The build system was rewritten into `cmake/Add*.cmake` modules, so
  `cmake/SolarusLibrarySources.cmake` (also patched by the series, to register
  the MiSTer TUs) has a different shape.

Forcing a `git am --3way` across that would yield a tree nobody could reason
about, and would quietly invalidate every HW validation the series carries. So
`scripts/build_engine2.sh` runs **no patch phase at all** and warns if the
checkout is dirty — what it builds is byte-for-byte upstream v2.1.0.

## Quest compatibility — 1.6 quests run on 2.x

Verified in upstream `src/core/MainLoop.cpp`, `check_version_compatibility()`:
quests declaring Solarus 1.5 or 1.6 are accepted by a 2.x engine (only quests
below 1.5, or newer than the engine, are rejected). Mystery of Solarus DX ships a
1.6 `quest.dat`, so the same `.sol` the shipping engine runs is the one the test
build runs — no separate quest packaging, and a genuine like-for-like comparison.

## Dependencies — one real difference from 1.6

Everything the 1.6 build needs, 2.x needs too (GLM is already in
`Dockerfile.solarus-build`; `glad`, `hqx` and `snes_spc` are vendored in
`third_party/`). The one new constraint:

> **Solarus 2.x requires SDL2 >= 2.0.18. Bullseye's `libsdl2-dev:armhf` is
> 2.0.14.**

So the lean from-source SDL2 (`scripts/build_sdl2.sh`, 2.28.5) is **mandatory**
here, where for the 1.6 build it is merely strongly preferred. There is no
`SOLARUS_ALLOW_STOCK_SDL2` escape hatch on this path — `build_engine2.sh` checks
for the prefix up front and fails with that explanation, because the raw CMake
failure ("Could NOT find SDL2: found unsuitable version") is a confusing way to
learn it.

Note also that 2.x **always compiles** `src/graphics/glrenderer/*` (they are
unconditional in `SolarusLibrarySources.cmake`, where 1.6 compiled the GL
renderer out when OpenGL was absent). That is fine: it reaches GL through the
vendored `glad` loader, which resolves entry points at runtime via
`SDL_GL_GetProcAddress`, and `find_package(OpenGL)` is not `REQUIRED` — so with
no `libgl-dev` in the image nothing links `OpenGL::GL` and the binaries carry no
GL `DT_NEEDED`. `GlRenderer` is simply never constructed under
`-force-software-rendering`. Both `build_engine2.sh` and CI assert this, so if it
ever stops being true you find out at build time, not on a black device.

## Recipe

Build (inside the armhf cross image; each step is a separate `docker run` so a
failure is attributable):

```bash
docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
scripts/docker_run.sh scripts/build_sdl2.sh      # MANDATORY here (>= 2.0.18)
scripts/docker_run.sh scripts/build_luajit.sh    # unless SOLARUS2_USE_LUAJIT=0
scripts/docker_run.sh scripts/build_engine2.sh
```

Artifacts land in `build/armhf-v2/` (`solarus-run`, `libsolarus.so.2.1.0`). The
1.6 tree in `work/solarus` and `build/armhf` is never touched — the 2.x source
lives in `work/solarus2`.

Collect the runtime closure into its own directory:

```bash
SOLARUS_BUILD_DIR=build/armhf-v2 SOLARUS_DEPLOY_LIBS=deploy/v2/libs \
  scripts/docker_run.sh scripts/collect_runtime_libs.sh
```

Deploy — into `/media/fat/games/Solarus/v2/`, touching nothing the shipping
install uses:

```bash
scripts/deploy_engine2.sh [--host 192.168.20.81]
```

Select it at launch by adding one line to `/media/fat/games/Solarus/diag.env`:

```
SOLARUS_ENGINE=2
```

Then load the Solarus core and pick a quest as usual. `solarus_run.sh` will exec
`v2/solarus-run` with `v2/libs` first on `LD_LIBRARY_PATH`, skip the blitter
exports (there is no blitter to enable), and — because this engine draws nothing
— **always** capture stdout/stderr to
`/media/fat/logs/Solarus/Solarus.diag.log`. That log is your only instrument.

Back out with `rm -rf /media/fat/games/Solarus/v2` and drop the diag.env line.
There is no shipping state to restore, which is the point of the split.

`deploy.py` deliberately knows nothing about any of this: the real install and
the experiment do not share a code path, so a 2.x session cannot brick a working
device.

## Bumping the pin

Change `SOLARUS2_REF` / `SOLARUS2_SHA` together in
`scripts/lib/patch_common.sh`, then rebuild. Because there is no patch series on
this line there is nothing to rebase and no round-trip gate to satisfy — the pin
exists purely so a measurement can't shift under you between runs.

## What a real 2.x port would take

Not scoped, not started. Recorded here so the size is not a surprise:

1. **Port `MisterBlitterRenderer` to the 2.x `Renderer` interface.** The
   interface delta is genuinely small — `create_texture(w, h, margin)` and the
   new `notify_target_changed()` — so the renderer itself is the cheapest large
   piece. It is also the piece that buys the picture, and everything downstream
   of it (the whole fabric datapath, the RBF, `blitter_ref.h`'s wire ABI) is
   engine-version-agnostic.
2. **Re-derive the engine-truth hooks the renderer depends on.** These are
   scattered through the series, not in the renderer: the root-surface tag
   (`mister_tag_root_surface`), camera publication, scroll-transition offsets,
   the static-tile pattern tokens, map `w8`/`h8`. Each is a small edit to a file
   that has drifted, so each needs re-reading rather than re-applying.
3. **Re-validate, don't re-apply, the perf series.** Patches 0003–0036 are perf
   levers whose defaults were set by HW validation against 1.6.5's engine
   behaviour. 2.x has its own changes in exactly those areas, so their measured
   wins do not transfer; they would need re-measuring before being turned on.

The honest ordering is 1 → 2 first, purely to get a picture and a frame rate to
compare, and to defer 3 until there is a number worth improving.
