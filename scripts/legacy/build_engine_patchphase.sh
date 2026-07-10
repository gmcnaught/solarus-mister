#!/bin/bash
#
# Phase 1: cross-build the Solarus 1.6.5 engine (solarus-run) for MiSTer armhf,
# software rendering only. Runs inside the solarus-armhf-build:bullseye image.
#
# Usage (from repo root):
#   docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
#   scripts/docker_run.sh scripts/build_engine.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."  # frozen ref lives in scripts/legacy/ (2 levels down); cd repo root

SOLARUS_REF="${SOLARUS_REF:-v1.6}"
SRC="work/solarus"
BUILD="${SOLARUS_BUILD_DIR:-build/armhf}"

# 1. Source checkout (engine only; quests are separate).
if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Solarus $SOLARUS_REF..."
  git clone --depth 1 --branch "$SOLARUS_REF" https://gitlab.com/solarus-games/solarus.git "$SRC"
fi

# [patch-series] Deterministic git identity for in-clone commits / am / reset.
# Harmless in normal builds; required for `git am` and the bootstrap harness.
git config --global user.email  >/dev/null 2>&1 || git config --global user.email "build@solarus-mister.local"
git config --global user.name   >/dev/null 2>&1 || git config --global user.name  "solarus-mister build"
git config --global --add safe.directory "$(pwd)/$SRC" 2>/dev/null || true

# 1b. Apply the MiSTer DDR video patch (task 003) into the source tree.
#     Idempotent: safe to re-run on an existing checkout.
echo "Applying MiSTer native-video patch..."
MDST="$SRC/src/graphics/sdlrenderer"
cp patches/mister/native_video_writer.c   "$MDST/"
cp patches/mister/native_video_writer.h   "$MDST/"
cp patches/mister/mister_native_video.cpp "$MDST/"
cp patches/mister/mister_native_video.h   "$MDST/"

# NOTE: use `sed > /tmp && cp` rather than `sed -i`. On Docker Desktop bind
# mounts, `sed -i` cannot create its temp file in the mounted dir ("Permission
# denied"); `cp` writes directly and works.
edit_inplace() { # edit_inplace <file> <sed-expr>
  local f="$1" expr="$2" tmp; tmp="$(mktemp /tmp/sb.XXXXXX)"
  sed "$expr" "$f" > "$tmp" && cp "$tmp" "$f"; rm -f "$tmp"
}

# Register the two new TUs with the engine library source list (once).
SRCLIST="$SRC/cmake/SolarusLibrarySources.cmake"
if ! grep -q "mister_native_video.cpp" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/SDLRenderer.cpp"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/mister_native_video.cpp"\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/native_video_writer.c"#'
fi

# Inject the present() hook + include into SDLRenderer.cpp (once).
SDLR="$MDST/SDLRenderer.cpp"
if ! grep -q "mister_native_video.h" "$SDLR"; then
  edit_inplace "$SDLR" 's|#include <SDL_hints.h>|#include <SDL_hints.h>\n#include "mister_native_video.h"|'
  # Name the present() window param (upstream comments it out) and pass it.
  edit_inplace "$SDLR" 's|present(SDL_Window\* /\*window\*/)|present(SDL_Window* window)|'
  edit_inplace "$SDLR" 's|^  SDL_RenderPresent(renderer);|  mister_present_frame(renderer, window);\n  SDL_RenderPresent(renderer);|'
fi

# 1b-blitter. MisterBlitterRenderer (fpga-hw-blitter #008): a Renderer backend
#     that offloads 2D compositing to the FPGA hardware blitter. It SUBCLASSES
#     SDLRenderer so it BECOMES the draw-dispatch singleton (`SDLRenderer::get()`)
#     and actually intercepts every sprite/tile/composite draw — a decorator does
#     NOT (the singleton bypasses it). SDLRenderer::create() constructs it instead
#     of a plain SDLRenderer when SOLARUS_BLITTER is set + the DDR map succeeds;
#     otherwise behaviour is identical to stock. Carries the vendored
#     engine-agnostic emitter. Idempotent.
echo "Applying MiSTer blitter-renderer patch..."
cp patches/mister/mister_blitter_renderer.cpp "$MDST/"
cp patches/mister/mister_blitter_renderer.h   "$MDST/"
# [#52] fast NEON/scalar RGB565/ARGB4444 source converter (replaces the per-pixel
# SDL_ConvertSurfaceFormat/SDL_Blit_Slow that stalled the A9 in heavy areas).
cp patches/mister/mister_pixconv.cpp "$MDST/"
cp patches/mister/mister_pixconv.h   "$MDST/"
# Public-header copy so it can be included via the solarus/... path.
cp patches/mister/mister_blitter_renderer.h   "$SRC/include/solarus/graphics/sdlrenderer/"
mkdir -p "$MDST/blitter"
cp patches/mister/blitter/*.h patches/mister/blitter/*.c "$MDST/blitter/"

# [MiSTer #26] Lua-VM time profiler: bracket the single per-frame lua_pcall in
#   LuaTools::call_function so the renderer can split the update() tick into
#   lua_vm vs eng_cpp. Header used by BOTH the renderer (graphics/sdlrenderer)
#   and LuaTools (lua/). Idempotent.
cp patches/mister/mister_lua_prof.h "$MDST/"
cp patches/mister/mister_lua_prof.h "$SRC/src/lua/"
LUATOOLS="$SRC/src/lua/LuaTools.cpp"
if ! grep -q "mister_lua_prof.h" "$LUATOOLS"; then
  # include after the first #include in the file
  edit_inplace "$LUATOOLS" '0,/^#include /s|^\(#include .*\)$|\1\n#include "mister_lua_prof.h"|'
  # bracket the lua_pcall in call_function with enter/exit timing
  edit_inplace "$LUATOOLS" 's|^\(  int status = lua_pcall(l, nb_arguments, nb_results, base);\)$|  struct timespec _mlp_t0; bool _mlp_outer = mister_lua_prof_enter(\&_mlp_t0);\n\1\n  mister_lua_prof_exit(_mlp_outer, \&_mlp_t0);|'
fi

# Register the renderer + emitter TUs with the engine library source list (once).
if ! grep -q "mister_blitter_renderer.cpp" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/SDLRenderer.cpp"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/mister_blitter_renderer.cpp"\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/blitter/blt_emitter.c"\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/blitter/blt_alloc.c"#'
fi
# [MiSTer #14] Separately ensure blt_alloc.c is registered — the block above is guarded
# on mister_blitter_renderer.cpp, which an existing work/ checkout already has, so it
# would skip adding the new allocator TU. This adds it idempotently after blt_emitter.c.
if ! grep -q "blitter/blt_alloc.c" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/blitter/blt_emitter.c"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/blitter/blt_alloc.c"#'
fi
# [#52] Register the pixconv TU (idempotent; guarded separately like blt_alloc.c so
# an existing work/ checkout that already has the renderer registered still adds it).
if ! grep -q "mister_pixconv.cpp" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/mister_blitter_renderer.cpp"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/mister_pixconv.cpp"#'
fi

# (a) Befriend MisterBlitterRenderer in SDLRenderer.h so the subclass can reach
#     the private renderer/software_screen/set_render_target members it inherits.
SDLRH="$SRC/include/solarus/graphics/sdlrenderer/SDLRenderer.h"
if ! grep -q "friend class MisterBlitterRenderer" "$SDLRH"; then
  edit_inplace "$SDLRH" 's|  friend class SDLSurfaceImpl;|  friend class SDLSurfaceImpl;\n  friend class MisterBlitterRenderer;|'
fi

# (b) Inject the MisterBlitterRenderer construction into SDLRenderer::create()
#     (both the windowed-software and the windowless paths), guarded by
#     SOLARUS_BLITTER via MisterBlitterRenderer::try_create(). Idempotent.
if ! grep -q "MisterBlitterRenderer::try_create" "$SDLR"; then
  edit_inplace "$SDLR" 's|#include "mister_native_video.h"|#include "mister_native_video.h"\n#include "mister_blitter_renderer.h"|'
  # Windowless path: new SDLRenderer(nullptr,false) -> try blitter first.
  python3 - "$SDLR" <<'PYBLT1'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''  if(!window) {
    //No window... asked for a software renderer
    return RendererPtr(new SDLRenderer(nullptr,false));
  }'''
new = '''  if(!window) {
    //No window... asked for a software renderer
    if (auto* blt = MisterBlitterRenderer::try_create(nullptr,false))
      return RendererPtr(blt);
    return RendererPtr(new SDLRenderer(nullptr,false));
  }'''
assert old in s, "windowless create() anchor not found"
s = s.replace(old, new, 1)
open(p,"w").write(s)
print("SDLRenderer windowless blitter hook injected")
PYBLT1
  # Windowed path: return RendererPtr(new SDLRenderer(renderer, shaders)) ->
  # try blitter first (the force-software branch yields a software renderer).
  python3 - "$SDLR" <<'PYBLT2'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    return RendererPtr(new SDLRenderer(renderer, shaders));"
new = ("    if (auto* blt = MisterBlitterRenderer::try_create(renderer, shaders))\n"
       "      return RendererPtr(blt);\n"
       "    return RendererPtr(new SDLRenderer(renderer, shaders));")
assert old in s, "windowed create() anchor not found"
s = s.replace(old, new, 1)
open(p,"w").write(s)
print("SDLRenderer windowed blitter hook injected")
PYBLT2
fi

# 1c. Apply the MiSTer DDR audio patch (task 009) into the source tree.
#     Routes Solarus' OpenAL output through an OpenAL-soft loopback device and
#     pushes mixed 48kHz/S16 PCM into the FPGA DDR3 audio ring (no ALSA).
#     Idempotent.
echo "Applying MiSTer native-audio patch..."
MADST="$SRC/src/audio"
cp patches/mister/native_audio_writer.c   "$MADST/"
cp patches/mister/native_audio_writer.h   "$MADST/"
cp patches/mister/mister_native_audio.cpp "$MADST/"
cp patches/mister/mister_native_audio.h   "$MADST/"

# Register the two new audio TUs with the engine library source list (once).
if ! grep -q "mister_native_audio.cpp" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/audio/Sound.cpp"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/audio/mister_native_audio.cpp"\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/audio/native_audio_writer.c"#'
fi

# Inject loopback device-open + per-frame pump into Sound.cpp (once).
SND="$MADST/Sound.cpp"
if ! grep -q "mister_native_audio.h" "$SND"; then
  edit_inplace "$SND" 's|#include "solarus/audio/Sound.h"|#include "solarus/audio/Sound.h"\n#include "mister_native_audio.h"|'
  # Open the loopback device (fall back to the default device if unavailable).
  edit_inplace "$SND" 's|^      device = alcOpenDevice(nullptr);|#ifdef MISTER_NATIVE_AUDIO\n      device = mister_audio_loopback_open();\n      if (device == nullptr) device = alcOpenDevice(nullptr);\n#else\n      device = alcOpenDevice(nullptr);\n#endif|'
  # Create a loopback context (48kHz/stereo/S16) when the loopback device opened.
  edit_inplace "$SND" 's|^        context = alcCreateContext(device, nullptr);|#ifdef MISTER_NATIVE_AUDIO\n        context = mister_audio_active() ? mister_audio_loopback_create_context(device) : alcCreateContext(device, nullptr);\n#else\n        context = alcCreateContext(device, nullptr);\n#endif|'
  # Pump rendered samples to the DDR ring once per Sound::update() -- UNLESS the
  # dedicated audio thread (SOLARUS_AUDIO_THREAD) is running, in which case the
  # thread owns the mix and the render thread must not pump.
  edit_inplace "$SND" 's|^  // also update the music|#ifdef MISTER_NATIVE_AUDIO\n  if (!mister_audio_thread_active()) mister_audio_pump(device);\n#endif\n\n  // also update the music|'
  # Release the DDR mapping on shutdown.
  edit_inplace "$SND" 's|^  Music::quit();|  Music::quit();\n#ifdef MISTER_NATIVE_AUDIO\n  mister_audio_close();\n#endif|'
  # Skip the "is this still the default device?" auto-switch check for the
  # loopback device: it is named 'Loopback', never equals the system default
  # ('ALSA Default'), so the stock logic would disconnect it every second.
  # (6-space indent targets the check in update_device_connection(), not the
  #  4-space reconnect guard below it.)
  edit_inplace "$SND" 's|^      if (System::now() >= next_device_detection_date) {|      if (System::now() >= next_device_detection_date MISTER_AUDIO_NOT_ACTIVE) {|'
  edit_inplace "$SND" 's|MISTER_AUDIO_NOT_ACTIVE|\&\& !mister_audio_active()|'
fi

# 1c-thread. SOLARUS_AUDIO_THREAD: run the OpenAL-soft software mix on a dedicated
#   thread pinned to A9 core 1 (the FPGA audio-ring drain is the real-time clock),
#   off the render critical path. Default OFF (== inline behaviour above). Guarded
#   separately from the block above so it also upgrades an already-patched work/
#   checkout. See docs/superpowers/specs/2026-06-27-audio-core1-thread-design.md.
if ! grep -q "mister_audio_thread_start" "$SND"; then
  # Start the mix thread after Music is initialized (Sound::initialize()).
  edit_inplace "$SND" 's|^  Music::initialize();|  Music::initialize();\n#ifdef MISTER_NATIVE_AUDIO\n  mister_audio_thread_start();\n#endif|'
  # Stop + join the mix thread BEFORE Music::quit()/context teardown (Sound::quit()),
  # so no mix is in flight when the decoders/context/device are destroyed.
  edit_inplace "$SND" 's|^  // uninitialize the music subsystem|#ifdef MISTER_NATIVE_AUDIO\n  mister_audio_thread_stop();\n#endif\n  // uninitialize the music subsystem|'
fi
# Upgrade an already-patched checkout whose pump line is the old unguarded form.
if grep -q "^  mister_audio_pump(device);" "$SND"; then
  edit_inplace "$SND" 's|^  mister_audio_pump(device);|  if (!mister_audio_thread_active()) mister_audio_pump(device);|'
fi

# 1b-prof. SOLARUS_DRAW_PROF instrumentation: per-frame blit / render-target /
#          read-pixels counters + MainLoop::draw() phase timing. All env-gated
#          (SOLARUS_DRAW_PROF=1); zero log spam and ~free when unset. Idempotent.

# (a) Count blits (SDL_RenderCopy / RenderCopyEx) and real render-target switches
#     inside SDLRenderer.
if ! grep -q "mister_draw_count_blit" "$SDLR"; then
  # One blit per draw(): count on each RenderCopy / RenderCopyEx (draw() only;
  # clear()/fill() use FillRect/RenderClear and are not counted as blits).
  edit_inplace "$SDLR" 's|    SOLARUS_CHECK_SDL(SDL_RenderCopyEx(|    mister_draw_count_blit();\n    SOLARUS_CHECK_SDL(SDL_RenderCopyEx(|'
  edit_inplace "$SDLR" 's|    SOLARUS_CHECK_SDL(SDL_RenderCopy(renderer,ssrc|    mister_draw_count_blit();\n    SOLARUS_CHECK_SDL(SDL_RenderCopy(renderer,ssrc|'
  # A real render-target switch happens only inside the if() in set_render_target.
  edit_inplace "$SDLR" 's|^    SDL_SetRenderTarget(renderer, target);|    SDL_SetRenderTarget(renderer, target);\n    mister_draw_count_target_switch();|'
fi

# (b) Count the texture->surface read-back done lazily in SDLSurfaceImpl::get_surface
#     (the dirty render-target download — a hidden per-frame cost).
SSI="$MDST/SDLSurfaceImpl.cpp"
if ! grep -q "mister_native_video.h" "$SSI"; then
  edit_inplace "$SSI" 's|#include <SDL_render.h>|#include <SDL_render.h>\n#include "mister_native_video.h"|'
  edit_inplace "$SSI" 's|    SDLRenderer::get().set_render_target(get_texture());|    mister_draw_count_readpixels();\n    SDLRenderer::get().set_render_target(get_texture());|'
fi

# (c) MainLoop::draw() phase timing. Replace the draw() body with a version that,
#     when SOLARUS_DRAW_PROF is set, times each sub-phase (clear / game / lua
#     main_on_draw / Video::render composite / video_on_draw+finish present) and
#     logs ms + the per-frame blit/target-switch/readpixels counts ~once/second.
ML="$SRC/src/core/MainLoop.cpp"

# (c0) SOLARUS_MISTER_PROF run()-loop instrumentation: split per-iteration
#      logic (check_input+step) vs draw() time and steps/frame, logged once/sec.
#      Env-gated; restores the pre-existing baseline profiler reproducibly.
if ! grep -q "SOLARUS_MISTER_PROF" "$ML"; then
  python3 - "$ML" <<'PYLOOP'
import sys
path = sys.argv[1]
s = open(path).read()
old = """    check_input();

    // 2. Update the world once, or several times (skipping some draws)
    // to catch up if the system is slow.
    int num_updates = 0;"""
new = """    // [MiSTer prof] split logic (step) vs draw per iteration.
    static const bool mister_prof = (getenv("SOLARUS_MISTER_PROF") != nullptr);
    auto mister_ms = []() {
      struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
      return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
    };
    double mp_t0 = mister_prof ? mister_ms() : 0.0;

    check_input();

    // 2. Update the world once, or several times (skipping some draws)
    // to catch up if the system is slow.
    int num_updates = 0;"""
assert old in s, "MISTER_PROF anchor A not found"
s = s.replace(old, new, 1)

old2 = """    // 3. Redraw the screen.
    if (num_updates > 0 && !is_suspended()) {
      draw();
    }
"""
new2 = """    double mp_t1 = mister_prof ? mister_ms() : 0.0;

    // 3. Redraw the screen.
    if (num_updates > 0 && !is_suspended()) {
      draw();
    }

    if (mister_prof) {
      double mp_t2 = mister_ms();
      static double acc_logic = 0, acc_draw = 0, acc_period = 0;
      static int acc_steps = 0, acc_n = 0;
      static double last_t = 0;
      acc_logic += (mp_t1 - mp_t0);
      acc_draw  += (mp_t2 - mp_t1);
      acc_steps += num_updates;
      if (last_t > 0) acc_period += (mp_t2 - last_t);
      last_t = mp_t2;
      if (++acc_n >= 30) {
        fprintf(stderr,
          "[MiSTer loop] fps=%.1f  logic=%.1fms  draw=%.1fms  steps/frame=%.1f\\n",
          acc_period > 0 ? 1000.0 * acc_n / acc_period : 0.0,
          acc_logic / acc_n, acc_draw / acc_n, (double)acc_steps / acc_n);
        acc_logic = acc_draw = acc_period = 0; acc_steps = 0; acc_n = 0;
      }
    }
"""
assert old2 in s, "MISTER_PROF anchor B not found"
s = s.replace(old2, new2, 1)
open(path,"w").write(s)
print("MISTER_PROF loop instrumentation injected")
PYLOOP
fi

if ! grep -q "SOLARUS_DRAW_PROF" "$ML"; then
  # Declare the global-scope counter API before the Solarus namespace opens.
  python3 - "$ML" <<'PYDECL'
import sys
path = sys.argv[1]
s = open(path).read()
needle = "namespace Solarus {"
decl = ("// SOLARUS_DRAW_PROF counter API (global scope, defined in mister_native_video.cpp).\n"
        "extern bool mister_draw_prof_enabled();\n"
        "extern void mister_draw_take_counts(long*, long*, long*);\n\n")
i = s.index(needle)
s = s[:i] + decl + s[i:]
open(path,"w").write(s)
PYDECL
  # Swap the draw() body (matched verbatim against upstream v1.6).
  perl -0pi -e 's/void MainLoop::draw\(\) \{\n\n  root_surface->clear\(\);\n\n  if \(game != nullptr\) \{\n    game->draw\(root_surface\);\n  \}\n  lua_context->main_on_draw\(root_surface\);\n  Video::render\(root_surface\);\n  lua_context->video_on_draw\(Video::get_screen_surface\(\)\);\n  Video::finish\(\);\n\}/__DRAW_PROF_BODY__/' "$ML" 2>/dev/null || true
  if grep -q "__DRAW_PROF_BODY__" "$ML"; then
    tmpb="$(mktemp /tmp/sb.XXXXXX)"
    cat > "$tmpb" <<'CPPEOF'
void MainLoop::draw() {

  if (!::mister_draw_prof_enabled()) {
    root_surface->clear();
    if (game != nullptr) {
      game->draw(root_surface);
    }
    lua_context->main_on_draw(root_surface);
    Video::render(root_surface);
    lua_context->video_on_draw(Video::get_screen_surface());
    Video::finish();
    return;
  }

  // SOLARUS_DRAW_PROF: phase-timed draw(). Times each sub-phase with a
  // monotonic clock and accumulates the per-frame SDL blit / render-target
  // switch / read-pixels counters, logging means to stderr ~once/second.
  auto dp_ms = []() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
  };
  double t0 = dp_ms();
  root_surface->clear();
  double t1 = dp_ms();
  if (game != nullptr) {
    game->draw(root_surface);
  }
  double t2 = dp_ms();
  lua_context->main_on_draw(root_surface);
  double t3 = dp_ms();
  Video::render(root_surface);
  double t4 = dp_ms();
  lua_context->video_on_draw(Video::get_screen_surface());
  Video::finish();
  double t5 = dp_ms();

  long blits = 0, switches = 0, reads = 0;
  ::mister_draw_take_counts(&blits, &switches, &reads);

  static double a_clear = 0, a_game = 0, a_lua = 0, a_render = 0, a_present = 0, a_total = 0;
  static long a_blits = 0, a_switches = 0, a_reads = 0;
  static int a_n = 0;
  a_clear   += (t1 - t0);
  a_game    += (t2 - t1);
  a_lua     += (t3 - t2);
  a_render  += (t4 - t3);
  a_present += (t5 - t4);
  a_total   += (t5 - t0);
  a_blits   += blits;
  a_switches += switches;
  a_reads   += reads;
  if (++a_n >= 30) {
    fprintf(stderr,
      "[MiSTer draw] total=%.1fms | clear=%.1f game=%.1f lua_main=%.1f "
      "composite=%.1f present=%.1f || blits=%.0f tgt_switch=%.0f readpix=%.0f /frame\n",
      a_total / a_n, a_clear / a_n, a_game / a_n, a_lua / a_n,
      a_render / a_n, a_present / a_n,
      (double)a_blits / a_n, (double)a_switches / a_n, (double)a_reads / a_n);
    a_clear = a_game = a_lua = a_render = a_present = a_total = 0;
    a_blits = a_switches = a_reads = 0; a_n = 0;
  }
}
CPPEOF
    body="$(cat "$tmpb")"; rm -f "$tmpb"
    python3 - "$ML" "$body" <<'PYINNER'
import sys
path, body = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace("__DRAW_PROF_BODY__", body, 1)
open(path,"w").write(s)
PYINNER
  fi
fi

# 1c. Force the default "normal" video mode to 1x (native 320x240) instead of
#     quest_size*2 (640x480), so Solarus's whole geometry pipeline is 320x240 —
#     matching the FPGA DDR buffer. MiSTer's own scaler handles display upscaling.
VID="$SRC/src/graphics/Video.cpp"
if grep -q '"normal",' "$VID" && grep -qE 'quest_size \* 2' "$VID"; then
  tmp="$(mktemp /tmp/sb.XXXXXX)"
  perl -0pe 's/("normal",\s*\n\s*context\.geometry\.quest_size) \* 2,/$1,/' "$VID" > "$tmp" && cp "$tmp" "$VID"; rm -f "$tmp"
fi

# 1d. SOLARUS_OPAQUE_BLITS optimization (env-gated A/B). The whole-frame
#     composite blits are fully opaque copies onto a freshly-cleared/opaque
#     destination, yet default to BlendMode::BLEND which, on the SDL *software*
#     renderer with premultiplied targets, takes SDL_ComposeCustomBlendMode's
#     slow generic per-pixel path. Downgrading those specific blits to
#     BlendMode::NONE (a straight SDL_BlitSurface copy) is pixel-identical for
#     opaque full-cover content and removes the most expensive per-frame blits.
#     Two provably-safe sites are switched: the screen composite (Video::render,
#     screen cleared immediately before) and the camera->root composite
#     (Game::draw, dst filled opaque with the tileset bg color first).
if ! grep -q "SOLARUS_OPAQUE_BLITS" "$VID"; then
  python3 - "$VID" <<'PYOPT'
import sys
path = sys.argv[1]
s = open(path).read()
old = """  context.screen_surface->clear();
  proxy.draw(
        *context.screen_surface,
        *surface_to_render,
        DrawInfos(
          Rectangle(surface_to_render->get_size()),
          Point(),
          Point(),
          BlendMode::BLEND,
          255,0,
          get_output_size_no_bars()/surface_to_render->get_size(),
          null_proxy));"""
new = """  // [MiSTer] SOLARUS_OPAQUE_BLITS: the screen is cleared immediately above and
  // the quest surface covers it fully and opaquely, so BLEND (the slow custom
  // premultiplied compose path on the software renderer) is wasted here: a
  // straight copy (BlendMode::NONE -> SDL_BlitSurface) is pixel-identical and
  // much cheaper. Only flip when no shader is active (shader path untouched).
  static const bool mister_opaque_blits = (std::getenv("SOLARUS_NO_OPAQUE_BLITS") == nullptr);
  const BlendMode terminal_blend =
      (mister_opaque_blits && !final_draw_with_shader) ? BlendMode::NONE : BlendMode::BLEND;

  context.screen_surface->clear();
  proxy.draw(
        *context.screen_surface,
        *surface_to_render,
        DrawInfos(
          Rectangle(surface_to_render->get_size()),
          Point(),
          Point(),
          terminal_blend,
          255,0,
          get_output_size_no_bars()/surface_to_render->get_size(),
          null_proxy));"""
assert old in s, "Video::render composite anchor not found"
s = s.replace(old, new, 1)
# Need <cstdlib> for std::getenv.
if "#include <cstdlib>" not in s:
    s = s.replace("#include <utility>", "#include <utility>\n#include <cstdlib>", 1)
open(path,"w").write(s)
print("Video.cpp opaque-blit patched")
PYOPT
fi

# Camera->root composite in Game::draw (full-cover opaque draw onto bg-filled dst).
GAME="$SRC/src/core/Game.cpp"
# Reset Game.cpp to pristine so all Game.cpp source patches below re-apply cleanly
# every build (they are guarded by grep markers; resetting makes them deterministic
# and lets us EVOLVE a patch without a stale already-applied copy blocking it).
git -C "$SRC" checkout -- src/core/Game.cpp 2>/dev/null || true
if ! grep -q "SOLARUS_OPAQUE_BLITS" "$GAME"; then
  python3 - "$GAME" <<'PYOPT2'
import sys
path = sys.argv[1]
s = open(path).read()
old = """      } else {
        camera_surface->draw(dst_surface, camera->get_position_on_screen());
      }"""
new = """      } else {
        // [MiSTer] SOLARUS_OPAQUE_BLITS: dst_surface was just filled opaquely
        // with the tileset background color and the camera surface covers the
        // whole camera region, so a straight copy (NONE) is correct and avoids
        // the software renderer's slow premultiplied BLEND compose path.
        static const bool mister_opaque_blits = (std::getenv("SOLARUS_NO_OPAQUE_BLITS") == nullptr);
        if (mister_opaque_blits) {
          BlendMode prev = camera_surface->get_blend_mode();
          camera_surface->set_blend_mode(BlendMode::NONE);
          camera_surface->draw(dst_surface, camera->get_position_on_screen());
          camera_surface->set_blend_mode(prev);
        } else {
          camera_surface->draw(dst_surface, camera->get_position_on_screen());
        }
      }"""
assert old in s, "Game::draw camera composite anchor not found"
s = s.replace(old, new, 1)
if "#include <cstdlib>" not in s:
    # Game.cpp top includes; add after the first include line.
    idx = s.index("#include")
    eol = s.index("\n", idx)
    s = s[:eol+1] + "#include <cstdlib>\n" + s[eol+1:]
open(path,"w").write(s)
print("Game.cpp opaque-blit patched")
PYOPT2
fi

# [MiSTer] deterministic camera-surface tag (issue #15): tell the FPGA renderer
# EXACTLY which SurfaceImpl is the map camera surface so it aliases it on-fabric
# deterministically (no looks_like_promote lottery). Idempotent.
if ! grep -q "mister_tag_camera_surface" "$GAME"; then
  python3 - "$GAME" <<'PYTAG'
import sys
path = sys.argv[1]
s = open(path).read()
# forward declaration at file scope (before the first namespace Solarus block)
decl = ("#ifdef MISTER_NATIVE_VIDEO\n"
        "namespace Solarus { class SurfaceImpl; void mister_tag_camera_surface(const SurfaceImpl*);\n"
        "                    void mister_set_camera_pos(int, int);\n"
        "                    void mister_set_transition(bool, bool); }\n"
        "#endif\n\n")
anchor_ns = "namespace Solarus {"
assert anchor_ns in s, "namespace Solarus not found in Game.cpp"
i = s.index(anchor_ns)
s = s[:i] + decl + s[i:]
# [Bug#1] Publish the camera + tag BEFORE current_map->draw(). The resident
# animated-tile emit (res_emit_bucket_) and parallax dst (AnimatedTilePattern::
# get_draw_region) run INSIDE current_map->draw() and read mister_camera_x/y().
# The old placement published the camera AFTER the draw, so those consumers saw
# the PREVIOUS frame's camera -> animated tiles (flowers, parallax) lagged the
# camera by one frame: they drifted in the direction of travel while the camera
# moved and snapped back when it stopped. Entities (hero/enemies) and the static
# background use the live camera, so only the animated tiles visibly drifted.
# The camera position is set in Game::update (before draw) and is stable across
# the draw; the tag pointer is frame-stable, so moving both here is safe.
old = ("    dst_surface->fill_with_color(current_map->get_tileset().get_background_color());\n"
       "    current_map->draw();\n")
new = ("    dst_surface->fill_with_color(current_map->get_tileset().get_background_color());\n"
       "#ifdef MISTER_NATIVE_VIDEO\n"
       "    { const CameraPtr& _cam = current_map->get_camera();\n"
       "      if (_cam != nullptr) {\n"
       "        Solarus::mister_tag_camera_surface(&_cam->get_surface()->get_impl());\n"
       "        auto _ctl = _cam->get_top_left_xy();\n"
       "        Solarus::mister_set_camera_pos(_ctl.x, _ctl.y);\n"
       "      } }\n"
       "#endif\n"
       "    current_map->draw();\n")
assert old in s, "Game::draw pre-draw camera anchor not found"
s = s.replace(old, new, 1)
# [MiSTer #24] publish the map-transition state at the TOP of every Game::draw so the
# renderer's scrolling-transition handling (alias-disable + heap-reset) tracks it.
# Runs every frame regardless of the draw branch taken.
draw_anchor = "void Game::draw(const SurfacePtr& dst_surface) {\n"
assert draw_anchor in s, "Game::draw signature anchor not found"
s = s.replace(draw_anchor,
              draw_anchor +
              "#ifdef MISTER_NATIVE_VIDEO\n"
              "  Solarus::mister_set_transition(transition != nullptr,\n"
              "      transition != nullptr && transition->needs_previous_surface());\n"
              "#endif\n", 1)
open(path,"w").write(s)
print("Game.cpp camera-tag + transition-hook patched")
PYTAG
fi


# 1e. Perf optimizations (HW-measured 28->31fps on the A9, see the
#     solarus-perf-40fps memory). Both are reproducible source patches.
#  (a) Entities.cpp: tighten the draw-cull from the stock 3x-camera (9x area) to
#      camera + a safe margin (default 128px, env SOLARUS_CULL_MARGIN overrides).
#  (b) NonAnimatedRegions.cpp: blit fully-opaque static-tile cells with NONE
#      (fast copy) instead of the premultiplied custom BLEND (SDL_Blit_Slow).
ENT="$SRC/src/entities/Entities.cpp"
if ! grep -q "SOLARUS_CULL_MARGIN" "$ENT"; then
  python3 - "$ENT" <<'PYCULL'
import sys
path = sys.argv[1]
s = open(path).read()
old = """    Rectangle around_camera(
        Point(
            camera->get_x() - camera->get_size().width,
            camera->get_y() - camera->get_size().height
        ),
        camera->get_size() * 3
    );"""
new = """    // [MiSTer] Tighten the draw-cull from 3x-camera (9x area) to camera + a
    // safe margin: covers sprite overhang + camera motion, and entities that
    // draw out of their position are added separately below. Env
    // SOLARUS_CULL_MARGIN overrides the per-side px (default 128).
    static const char* mister_cm_env = std::getenv("SOLARUS_CULL_MARGIN");
    static const int mister_cm = mister_cm_env ? std::atoi(mister_cm_env) : 64;
    Rectangle around_camera(
        Point(camera->get_x() - mister_cm, camera->get_y() - mister_cm),
        Size(camera->get_size().width + 2 * mister_cm,
             camera->get_size().height + 2 * mister_cm));"""
assert old in s, "Entities.cpp around_camera anchor not found"
s = s.replace(old, new, 1)
if "#include <cstdlib>" not in s:
    idx = s.index("#include"); eol = s.index("\n", idx)
    s = s[:eol+1] + "#include <cstdlib>\n" + s[eol+1:]
open(path,"w").write(s)
print("Entities.cpp cull-margin patched")
PYCULL
fi

NAR="$SRC/src/entities/NonAnimatedRegions.cpp"
# Reset to pristine ONCE at the top of this file's whole patch section (mirrors the
# Entities.cpp/Game.cpp/Quadtree.h pattern elsewhere in this script): work/solarus/ is a
# PERSISTENT checkout, so an already-patched NonAnimatedRegions.cpp/.h has every marker this
# section's guards check for, and a later revision to any one block (e.g. record_static's
# fix, below) would otherwise be silently skipped forever. Resetting both files here, before
# either guarded block runs, means EVERY block in this section (opaque-tiles + record_static)
# re-applies cleanly and in full on every build, same as it would on a truly fresh clone.
git -C "$SRC" checkout -- src/entities/NonAnimatedRegions.cpp include/solarus/entities/NonAnimatedRegions.h 2>/dev/null || true
if ! grep -q "opaque region blocks everything" "$NAR"; then
  python3 - "$NAR" <<'PYOPAQUE'
import sys
path = sys.argv[1]
s = open(path).read()
anchor = '#include "solarus/graphics/Surface.h"\n'
inc = ('#include "solarus/graphics/SurfaceImpl.h"\n'
       '#include <SDL_surface.h>\n#include <cstdint>\n')
if "SurfaceImpl.h" not in s:
    assert anchor in s, "NonAnimatedRegions include anchor not found"
    s = s.replace(anchor, anchor + inc, 1)
old = """        cell_surface->clear(animated_square);
      }
    }
  }
}"""
new = """        cell_surface->clear(animated_square);
      }
    }
  }

  // [MiSTer] If the built cell has no transparent pixels, blit it with NONE
  // (fast SDL copy) instead of the premultiplied custom BLEND (SDL_Blit_Slow).
  // Safe: a fully opaque region blocks everything below it on any layer. Cells
  // with animated-tile holes / gaps keep their default BLEND. One-time scan.
  {
    SDL_Surface* cs = cell_surface->get_impl().get_surface();
    bool opaque = (cs != nullptr);
    if (cs != nullptr) {
      if (SDL_MUSTLOCK(cs)) { SDL_LockSurface(cs); }
      const uint32_t amask = cs->format->Amask;
      const int pitch32 = cs->pitch / 4;
      const uint32_t* cbase = static_cast<const uint32_t*>(cs->pixels);
      for (int yy = 0; yy < cs->h && opaque; ++yy) {
        const uint32_t* row = cbase + yy * pitch32;
        for (int xx = 0; xx < cs->w; ++xx) {
          if ((row[xx] & amask) != amask) { opaque = false; break; }
        }
      }
      if (SDL_MUSTLOCK(cs)) { SDL_UnlockSurface(cs); }
    }
    if (opaque) {
      cell_surface->set_blend_mode(BlendMode::NONE);
    }
  }
}"""
assert old in s, "NonAnimatedRegions build_cell end anchor not found"
s = s.replace(old, new, 1)
open(path,"w").write(s)
print("NonAnimatedRegions.cpp opaque-tiles patched")
PYOPAQUE
fi

# [static tile-list, Task 4] NonAnimatedRegions::record_static(Renderer&) -- walks every
# non-animated tile of this layer ONCE into the renderer's static tile-list (map coords),
# replacing the per-cell optimized_tiles_surfaces cache this class otherwise lazily builds
# in draw_on_map()/evicts in update(). Called from Entities.cpp's resident BUILD frame
# (Task 4 below), gated by SOLARUS_TILESTATIC.
NARH="$SRC/include/solarus/entities/NonAnimatedRegions.h"
if ! grep -q "record_static" "$NARH"; then
  python3 - "$NARH" <<'PYNARH'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="namespace Solarus {\n\nclass Map;\n"
assert anchor in s, "NonAnimatedRegions.h namespace/Map anchor not found"
s=s.replace(anchor,
    anchor + "class Renderer;  // [static tile-list] NonAnimatedRegions::record_static(Renderer&)\n",
    1)
anchor2="    void update();\n    void draw_on_map();\n"
assert anchor2 in s, "NonAnimatedRegions.h update()/draw_on_map() anchor not found"
decl=(
"    // [static tile-list] Record every non-animated tile of this layer into the renderer's\n"
"    // static tile-list (map coords), replacing the per-cell optimized_tiles_surfaces path.\n"
"    void record_static(Renderer& renderer);\n")
s=s.replace(anchor2, anchor2+decl, 1)
open(p,"w").write(s)
print("[static tile-list] NonAnimatedRegions.h: record_static() declared")
PYNARH
fi

NAR="$SRC/src/entities/NonAnimatedRegions.cpp"
if ! grep -q "record_static" "$NAR"; then
  python3 - "$NAR" <<'PYNARCPP'
import sys
p=sys.argv[1]; s=open(p).read()

# Includes: Renderer.h (TileBatchEntry + Renderer virtuals), TilePattern.h (get_width/
# get_height/get_draw_region -- TileInfo.h only forward-declares TilePattern).
anchor_inc = '#include "solarus/graphics/SurfaceImpl.h"\n#include <SDL_surface.h>\n#include <cstdint>\n'
assert anchor_inc in s, "NonAnimatedRegions.cpp include anchor not found"
incs = ('#include "solarus/graphics/Renderer.h"       // [static tile-list] TileBatchEntry/resident_record_static\n'
        '#include "solarus/entities/TilePattern.h"     // [static tile-list] get_draw_region/get_width/get_height\n')
s = s.replace(anchor_inc, anchor_inc + incs, 1)

tail = """    if (opaque) {
      cell_surface->set_blend_mode(BlendMode::NONE);
    }
  }
}
"""
assert tail in s, "NonAnimatedRegions.cpp build_cell()-close anchor not found"
assert s.count(tail) == 1, "NonAnimatedRegions.cpp build_cell()-close anchor not unique"
method = """
/**
 * \\brief [static tile-list] Records every non-animated tile of this layer into the
 * renderer's static tile-list (map coords), ONE TIME, replacing the per-cell
 * optimized_tiles_surfaces cache this class otherwise lazily builds in draw_on_map()
 * and evicts in update(). Bucketed by tileset image (blend follows the tileset image;
 * scroll_ratio is always 1 here -- animated/parallax/self-scrolling patterns never
 * reach non_animated_tiles: NonAnimatedRegions::build() routes any tile whose
 * pattern->is_animated() is true into rejected_tiles instead). Tiles that overlap an
 * animated 8x8 square are ALSO skipped here (see overlaps_animated_tile() below) --
 * build() puts those in rejected_tiles too, so the (unchanged) animated resident walk
 * in Entities::draw() already draws them whole, every frame; recording them here as
 * well would double-composite the straddling squares.
 * \\param renderer The renderer to record into (Renderer::resident_record_static).
 */
void NonAnimatedRegions::record_static(Renderer& renderer) {

  const size_t num_cells = non_animated_tiles.get_num_cells();
  const size_t num_columns = non_animated_tiles.get_num_columns();
  const Size& cell_size = non_animated_tiles.get_cell_size();

  const Surface* cur_ts = nullptr;
  SurfacePtr     cur_ts_sp;
  std::vector<TileBatchEntry> cur_entries;

  auto flush_bucket = [&]() {
    if (cur_ts != nullptr && !cur_entries.empty()) {
      renderer.resident_record_static(layer, /* scroll_ratio */ 1,
          cur_ts_sp->get_impl(), cur_ts_sp->get_blend_mode(), cur_entries);
    }
    cur_entries.clear();
    cur_ts = nullptr;
    cur_ts_sp = nullptr;
  };

  for (size_t cell_index = 0; cell_index < num_cells; ++cell_index) {
    const int row = (int) (cell_index / num_columns);
    const int column = (int) (cell_index % num_columns);
    const std::vector<TileInfo>& tiles_in_cell = non_animated_tiles.get_elements(cell_index);

    for (const TileInfo& tile: tiles_in_cell) {

      // Grid::add() stores a tile in EVERY cell its bounding box overlaps; only record it
      // once, when visiting its home cell (the row1/column1 Grid::add() itself computed
      // from tile.box) -- otherwise a tile spanning a cell boundary is recorded (and
      // blitted) once per cell it touches.
      const int home_row = tile.box.get_y() / cell_size.height;
      const int home_column = tile.box.get_x() / cell_size.width;
      if (home_row != row || home_column != column) {
        continue;
      }

      // [static tile-list, review fix] A non-animated tile whose box overlaps an animated
      // 8x8 square is ALSO in rejected_tiles (NonAnimatedRegions::build(), same
      // overlaps_animated_tile() check) -> tiles_in_animated_regions[layer] -> drawn WHOLE,
      // every frame, by the animated resident walk in Entities::draw(). Recording it here
      // too would composite it TWICE over the straddling squares: invisible for opaque
      // (NONE-blend) tiles, but a real visible darkening for BLEND tiles with alpha
      // (foliage/shadow/water-edge decals bordering a torch/animated water tile). The
      // legacy build_cell() avoided this by hole-punching those squares out of the cached
      // cell surface; record_static has no per-pixel surface to punch holes in, so instead
      // it excludes the tile entirely here and lets the (unchanged) animated walk draw it
      // -- exactly once, matching the legacy net result.
      if (overlaps_animated_tile(tile)) {
        continue;
      }

      const Tileset* tileset = tile.tileset != nullptr ? tile.tileset : &map.get_tileset();
      const SurfacePtr& tsimg = tileset->get_tiles_image();
      const TilePattern& pattern = *tile.pattern;

      // Every pattern reaching non_animated_tiles has is_animated() == false (build()
      // above routes animated/parallax/self-scrolling patterns to rejected_tiles instead),
      // so this is always batchable in practice -- checked anyway, same shape as the
      // animated walk in Entities::draw(): a non-batchable tile is a loud resident_escape()
      // fatal, never a silent draw.
      const int pw = pattern.get_width();
      const int ph = pattern.get_height();
      const Point base = tile.box.get_xy();
      Rectangle src;
      Point dst;
      const bool batchable = pw > 0 && ph > 0 &&
          pattern.get_draw_region(base, *tileset, src, dst);
      // A REPEATED/FILL tile (tile larger than its pattern) tiles the same pattern frame
      // across cells: expand into per-cell entries (src constant, dst stepped), same as
      // the animated walk. Cap by remaining TL_BUF room (minus the open bucket).
      const int ncx = batchable ? (tile.box.get_width()  + pw - 1) / pw : 0;
      const int ncy = batchable ? (tile.box.get_height() + ph - 1) / ph : 0;
      const long ncells = (long) ncx * (long) ncy;

      if (batchable &&
          ncells <= (long) (renderer.resident_room_entries() - (int) cur_entries.size())) {
        if (cur_ts != nullptr && cur_ts != tsimg.get()) {
          flush_bucket();
        }
        cur_ts = tsimg.get();
        cur_ts_sp = tsimg;
        for (int cy = 0; cy < ncy; ++cy) {
          for (int cx = 0; cx < ncx; ++cx) {
            cur_entries.push_back(TileBatchEntry{
                src, Point(base.x + cx * pw, base.y + cy * ph)});
          }
        }
      }
      else {
        flush_bucket();
        renderer.resident_escape(layer, reinterpret_cast<uintptr_t>(&tile));
      }
    }
  }
  flush_bucket();
}

"""
s = s.replace(tail, tail + method, 1)
open(p, "w").write(s)
print("[static tile-list] NonAnimatedRegions.cpp: record_static() implemented")
PYNARCPP
fi


# 1b-perf (#26). Collision-query shared_ptr churn (gdb-profiled hotspot). The const
# Entities::get_entities_in_rectangle_z_sorted COPIES every shared_ptr<Entity> from
# the quadtree result into a shared_ptr<const Entity> vector — an atomic refcount
# inc/dec per candidate, per moving entity, per frame (Cortex-A9 atomics are pricey).
# MOVE-convert instead (shared_ptr<Entity>&& -> shared_ptr<const Entity> is a
# non-atomic pointer transfer). Idempotent (reset-to-pristine + grep guard).
ENT="$SRC/src/entities/Entities.cpp"
git -C "$SRC" checkout -- src/entities/Entities.cpp 2>/dev/null || true
if ! grep -q "MiSTer #26: move-convert" "$ENT"; then
  python3 - "$ENT" <<'PYENT'
import sys
path = sys.argv[1]
s = open(path).read()
old = """  result.reserve(non_const_result.size());
  for (ConstEntityPtr entity : non_const_result) {
      result.push_back(entity);
  }"""
new = """  // [MiSTer #26: move-convert] Move each shared_ptr<Entity> into the
  // shared_ptr<const Entity> result (a non-atomic pointer transfer) instead of
  // copying (an atomic refcount op per candidate). This const overload is on the
  // collision hot path (Map::check_collision_*), called per moving entity/frame.
  result.reserve(non_const_result.size());
  for (EntityPtr& entity : non_const_result) {
      result.push_back(std::move(entity));
  }"""
assert old in s, "Entities.cpp const z-sorted copy-loop anchor not found"
s = s.replace(old, new, 1)
if "#include <utility>" not in s:
    idx = s.index("#include")
    eol = s.index("\n", idx)
    s = s[:eol+1] + "#include <utility>\n" + s[eol+1:]
open(path,"w").write(s)
print("Entities.cpp collision-copy -> move patched")
PYENT
fi


# 1b-perf2 (#26). Quadtree::get_elements per-query std::set -> vector + single sort.
# The collision/draw-cull query built a std::set<shared_ptr<Entity>, ZOrderComparator>
# every call (RB-tree node alloc + O(log n) comparator per insert + a final set->vector
# copy = N atomic refcount incs), per moving entity per frame. Collect into a vector
# (push_back), then ONE std::sort + std::unique using the comparator's equivalence —
# reproduces the set's z-order AND dedup exactly (z-index is unique per entity within a
# layer, so set-equivalence == identity). Kills the RB-tree allocs + the set->vector copy.
# Touches Quadtree.h (decl) + Quadtree.inl (both get_elements). Idempotent.
QTH="$SRC/include/solarus/containers/Quadtree.h"
QTI="$SRC/include/solarus/containers/Quadtree.inl"
git -C "$SRC" checkout -- include/solarus/containers/Quadtree.h include/solarus/containers/Quadtree.inl 2>/dev/null || true
if ! grep -q "MiSTer #26: vector+sort" "$QTI"; then
  python3 - "$QTH" "$QTI" <<'PYQT'
import sys
hp, ip = sys.argv[1], sys.argv[2]

# --- Quadtree.h: Node::get_elements declaration  Set& -> std::vector<T>& ---
h = open(hp).read()
old_h = """        void get_elements(
            const Rectangle& region,
            Set& result
        ) const;"""
new_h = """        void get_elements(
            const Rectangle& region,
            std::vector<T>& result        // [MiSTer #26: vector+sort] was Set&
        ) const;"""
assert old_h in h, "Quadtree.h Node::get_elements decl anchor not found"
h = h.replace(old_h, new_h, 1)
open(hp, "w").write(h)

# --- Quadtree.inl: Node::get_elements signature + emplace -> push_back ---
s = open(ip).read()
old_sig = """void Quadtree<T, Comparator>::Node::get_elements(
    const Rectangle& region,
    Set& result
) const {"""
new_sig = """void Quadtree<T, Comparator>::Node::get_elements(
    const Rectangle& region,
    std::vector<T>& result        // [MiSTer #26: vector+sort] was Set&
) const {"""
assert old_sig in s, "Quadtree.inl Node::get_elements signature anchor not found"
s = s.replace(old_sig, new_sig, 1)
assert "result.emplace(pair.first);" in s, "Node::get_elements emplace anchor not found"
s = s.replace("result.emplace(pair.first);", "result.push_back(pair.first);", 1)

# --- Quadtree.inl: top-level get_elements set -> vector + sort + unique ---
old_top = """  Set element_set;
  root.get_elements(region, element_set);
  return std::vector<T>(element_set.begin(), element_set.end());"""
new_top = """  // [MiSTer #26: vector+sort] Collect into a vector then ONE sort + unique
  // (comparator-equivalence dedup) instead of per-insert into a std::set:
  // kills per-element RB-tree node allocation and the set->vector copy.
  std::vector<T> result;
  root.get_elements(region, result);
  Comparator comp;
  std::sort(result.begin(), result.end(), comp);
  result.erase(std::unique(result.begin(), result.end(),
      [&comp](const T& a, const T& b) { return !comp(a, b) && !comp(b, a); }),
    result.end());
  return result;"""
assert old_top in s, "Quadtree.inl top-level get_elements anchor not found"
s = s.replace(old_top, new_top, 1)
open(ip, "w").write(s)
print("Quadtree get_elements set -> vector+sort patched")
PYQT
fi

# 1b-perf3 (fat-AABB). Quadtree::move broad-phase hysteresis (SOLARUS_QTREE_MARGIN):
# store an inflated box, skip the remove+add reinsert while the true box stays
# inside it. Runs AFTER the #26 block above (which reverts Quadtree to pristine then
# applies vector+sort); touches disjoint regions (includes / move() / members, NOT
# get_elements) so the two never conflict. Idempotent (grep fat_margin). Correctness
# + rationale: docs/superpowers/plans/2026-07-05-quadtree-fat-aabb.md.
# (The script is idempotent — a no-op if fat_margin is already present.)
python3 scripts/patch_quadtree_fat.py "$QTH" "$QTI"


# 1f. [#52 levers 1&3] eng_cpp + draw-category instrumentation. Engine-side
#     classification the renderer can't do: per-frame animated-tile vs entity draw
#     counts (Entities::draw) + eng_cpp update sub-timers (Entities::update +
#     Game::update_tilesets). All gated on g_mister_lua_diag -> zero cost when DIAG
#     is off. Counters are DEFINED in mister_blitter_renderer.cpp and printed by its
#     [blitter drawcat] / [blitter engcpp] banner. MUST run AFTER the Entities.cpp /
#     Game.cpp resets above so it survives the rebuild. Idempotent (grep-guarded).
# [SOLARUS_IDLEPARK] Make the reused idle predicate + sweep-range headers visible to
# Entities.cpp (compiled from src/entities/). Destructible.cpp copies mister_idleskip.h
# too; copying here as well is harmless (idempotent overwrite).
cp patches/mister/mister_idlepark.h "$SRC/src/entities/"
cp patches/mister/mister_idleskip.h "$SRC/src/entities/"
ENT="$SRC/src/entities/Entities.cpp"
if ! grep -q "_me_now_ns" "$ENT"; then
  python3 - "$ENT" <<'PYME1'
import sys
path = sys.argv[1]
s = open(path).read()

# (a) file-scope: <time.h> + extern counters + a monotonic-ns helper, after 1st include.
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  '#include <cstdlib>     // [SOLARUS_IDLEPARK] std::getenv\n'
  '#include <algorithm>   // [SOLARUS_IDLEPARK] std::remove\n'
  '#include "solarus/entities/Destructible.h"  // [SOLARUS_IDLEPARK] full type + accessors\n'
  '#include "solarus/graphics/Sprite.h"        // [SOLARUS_IDLEPARK] sprite anim state\n'
  '#include "mister_idlepark.h"                // [SOLARUS_IDLEPARK] sweep-range\n'
  '#include "mister_idleskip.h"                // [SOLARUS_IDLEPARK] idle predicate (reused)\n'
  '// [#52] eng_cpp/draw-category profiling counters (defined in mister_blitter_renderer.cpp).\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long  g_me_draw_anim_tiles;\n'
  '  extern volatile long long  g_me_draw_entities;\n'
  '  extern volatile long long  g_me_upd_hero_ns;\n'
  '  extern volatile long long  g_me_upd_entities_ns;\n'
  '  extern volatile long long  g_me_upd_nonanim_ns;\n'
  '  extern volatile long long  g_me_ent_type_ns[32];\n'
  '  extern volatile long long  g_me_ent_type_cnt[32];\n'
  '}\n'
  'namespace { inline long long _me_now_ns() {\n'
  '  struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '  return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '} }\n'
  '// [SOLARUS_IDLEPARK] Sleep oracle: a destructible is idle (parkable) when the reused\n'
  '// PR#57 predicate holds. Same 7 inputs as the SOLARUS_IDLESKIP check.\n'
  'namespace { inline bool destructible_is_idle(Solarus::Destructible* d) {\n'
  '  const Solarus::SpritePtr& _sp = d->get_sprite();\n'
  '  bool _spr = _sp && !_sp->is_paused() && !_sp->is_animation_finished()\n'
  '           && _sp->get_frame_delay() > 0;\n'
  '  return solarus_destructible_skippable(\n'
  '      d->is_suspended()?1:0, d->get_is_being_cut()?1:0,\n'
  '      d->is_waiting_for_regeneration()?1:0, d->get_is_regenerating()?1:0,\n'
  '      (d->get_movement()!=nullptr)?1:0, d->has_stream_action()?1:0, _spr?1:0);\n'
  '} }\n'
)
s = s[:eol+1] + block + s[eol+1:]

# (b) Entities::update -> bracket hero / all-entities / nonanim regions.
upd_old = """void Entities::update() {

  Debug::check_assertion(map.is_started(), "The map is not started");

  // First update the hero.
  hero->update();

  // Update the dynamic entities.
  for (const EntityPtr& entity: all_entities) {

    if (
        !entity->is_being_removed() &&
        entity->get_type() != EntityType::CAMERA  // The camera is updated after.
    ) {
      entity->update();
    }
  }

  // Update the camera after everyone else.
  camera->update();
  entities_to_draw.clear();  // Invalidate entities to draw.
  for (int layer = map.get_min_layer(); layer <= map.get_max_layer(); ++layer) {
    non_animated_regions[layer]->update();
  }

  // Remove the entities that have to be removed now.
  remove_marked_entities();
}"""
upd_new = """void Entities::update() {

  Debug::check_assertion(map.is_started(), "The map is not started");

  long long _me_t0;
  // First update the hero.
  _me_t0 = g_mister_lua_diag ? _me_now_ns() : 0;
  hero->update();
  if (g_mister_lua_diag) g_me_upd_hero_ns += _me_now_ns() - _me_t0;

  // Update the dynamic entities.
  _me_t0 = g_mister_lua_diag ? _me_now_ns() : 0;
  long long _me_prev = _me_t0;  // [enttype] running clock for per-EntityType attribution
  // [SOLARUS_IDLEPARK] Walk entities_to_update (= all_entities minus parked idle
  // destructibles) when gated; else the stock all_entities (bit-identical to before).
  // Explicit iterator loop: park_destructible() erases the current node from
  // entities_to_update mid-walk, so capture the next iterator BEFORE the body
  // (std::list: unrelated iterators stay valid across an erase). `entity` is a COPY of
  // the shared_ptr so it stays valid even if its list slot is erased in the body.
  // [HW-validated default ON] idle-destructible parking ships enabled (PR#59, +57%);
  // an explicit SOLARUS_IDLEPARK=0 opts out. Unset or non-"0" -> ON.
  static const char* _idlepark_env = std::getenv("SOLARUS_IDLEPARK");
  static const bool _idlepark = !(_idlepark_env && _idlepark_env[0] == '0');
  idlepark_enabled = _idlepark;
  EntityList& _walk = _idlepark ? entities_to_update : all_entities;
  for (EntityList::iterator _it = _walk.begin(); _it != _walk.end(); ) {
    EntityList::iterator _next = _it; ++_next;
    const EntityPtr entity = *_it;

    if (
        !entity->is_being_removed() &&
        entity->get_type() != EntityType::CAMERA  // The camera is updated after.
    ) {
      entity->update();
    }
    // Attribute this entity's update to its EntityType (one clock read/entity).
    if (g_mister_lua_diag) {
      long long _me_t = _me_now_ns();
      int _me_ty = (int)entity->get_type();
      if ((unsigned)_me_ty < 32u) {
        g_me_ent_type_ns[_me_ty]  += _me_t - _me_prev;
        g_me_ent_type_cnt[_me_ty] += 1;
      }
      _me_prev = _me_t;
    }
    // [IDLEPARK] Park a destructible that has returned to idle (erases *_it; _next held).
    if (_idlepark && entity->get_type() == EntityType::DESTRUCTIBLE) {
      Destructible* _d = static_cast<Destructible*>(entity.get());
      if (destructible_is_idle(_d)) park_destructible(_d);
    }
    _it = _next;
  }
  // [IDLEPARK] Incremental backstop sweep (~n/30 per tick): wake any parked destructible
  // that is no longer idle (Lua-driven sprite/movement has no C++ wake hook).
  if (_idlepark && !destructibles.empty()) {
    int _ss, _cc, _nx;
    solarus_idlepark_sweep_range(idlepark_cursor, (int)destructibles.size(), 30,
                                 &_ss, &_cc, &_nx);
    for (int _k = 0; _k < _cc; ++_k) {
      Destructible* _d = destructibles[(_ss + _k) % (int)destructibles.size()];
      if (!destructible_is_idle(_d)) wake_destructible(_d);
    }
    idlepark_cursor = _nx;
  }
  if (g_mister_lua_diag) g_me_upd_entities_ns += _me_now_ns() - _me_t0;

  // Update the camera after everyone else.
  camera->update();
  entities_to_draw.clear();  // Invalidate entities to draw.
  _me_t0 = g_mister_lua_diag ? _me_now_ns() : 0;
  for (int layer = map.get_min_layer(); layer <= map.get_max_layer(); ++layer) {
    non_animated_regions[layer]->update();
  }
  if (g_mister_lua_diag) g_me_upd_nonanim_ns += _me_now_ns() - _me_t0;

  // Remove the entities that have to be removed now.
  remove_marked_entities();
}"""
assert upd_old in s, "Entities::update anchor not found"
s = s.replace(upd_old, upd_new, 1)

# (c) draw-category counts (animated tile vs entity), gated on diag.
t_old = """      if (tile.overlaps(*camera) || !tile.is_drawn_at_its_position()) {
        tile.draw(*camera);
      }"""
t_new = """      if (tile.overlaps(*camera) || !tile.is_drawn_at_its_position()) {
        if (g_mister_lua_diag) ++g_me_draw_anim_tiles;
        tile.draw(*camera);
      }"""
assert t_old in s, "Entities::draw animated-tile anchor not found"
s = s.replace(t_old, t_new, 1)

e_old = """      if (!entity->is_being_removed() &&
          entity->is_enabled() &&
          entity->is_visible()) {
        entity->draw(*camera);
      }"""
e_new = """      if (!entity->is_being_removed() &&
          entity->is_enabled() &&
          entity->is_visible()) {
        if (g_mister_lua_diag) ++g_me_draw_entities;
        entity->draw(*camera);
      }"""
assert e_old in s, "Entities::draw entity anchor not found"
s = s.replace(e_old, e_new, 1)

open(path, "w").write(s)
print("Entities.cpp eng_cpp/draw-category instrumentation injected")
PYME1
fi

# --- [SOLARUS_IDLEPARK] Entities.h: forward-decl Destructible + parking members. ---
ENTH="$SRC/include/solarus/entities/Entities.h"
if ! grep -q "entities_to_update" "$ENTH"; then
  python3 - "$ENTH" <<'PYENTH'
import sys
path = sys.argv[1]
s = open(path).read()
fwd = "class Quadtree;"
assert fwd in s, "Entities.h Quadtree forward-decl anchor not found"
s = s.replace(fwd, fwd + "\nclass Destructible;", 1)
anchor = "EntityList all_entities;                        /**< All map entities except tiles and the hero. */"
assert anchor in s, "Entities.h all_entities member anchor not found"
add = (anchor + "\n\n"
  "    // [SOLARUS_IDLEPARK] parking machinery.\n"
  "  public:\n"
  "    void wake_destructible(Destructible* d);   /**< re-add a parked destructible to the walk. */\n"
  "    void park_destructible(Destructible* d);   /**< drop an idle destructible from the walk. */\n"
  "    bool idlepark_enabled = false;             /**< gate state, published by update(). */\n"
  "  private:\n"
  "    EntityList entities_to_update;             /**< all_entities minus parked destructibles. */\n"
  "    std::vector<Destructible*> destructibles;  /**< cache for the incremental re-scan. */\n"
  "    int idlepark_cursor = 0;                   /**< re-scan sweep position. */")
s = s.replace(anchor, add, 1)
open(path, "w").write(s)
print("Entities.h SOLARUS_IDLEPARK members injected")
PYENTH
fi

# --- [SOLARUS_IDLEPARK] Entities.cpp: wake/park bodies + add/remove maintenance. ---
if ! grep -q "Entities::park_destructible" "$ENT"; then
  python3 - "$ENT" <<'PYIDLEPARK'
import sys
path = sys.argv[1]
s = open(path).read()

adef = "void Entities::add_entity(const EntityPtr& entity) {"
assert adef in s, "Entities.cpp add_entity anchor not found"
bodies = (
  "void Entities::park_destructible(Destructible* d) {\n"
  "  if (d->idlepark_parked) return;\n"
  "  d->idlepark_parked = true;\n"
  "  entities_to_update.erase(d->idlepark_it);   // O(1) via cached iterator\n"
  "}\n\n"
  "void Entities::wake_destructible(Destructible* d) {\n"
  "  if (!d->idlepark_parked) return;\n"
  "  d->idlepark_parked = false;\n"
  "  d->idlepark_it = entities_to_update.insert(entities_to_update.end(),\n"
  "      std::static_pointer_cast<Entity>(d->shared_from_this()));\n"
  "}\n\n")
s = s.replace(adef, bodies + adef, 1)

add_anchor = ("    if (type != EntityType::HERO) {\n"
              "      all_entities.push_back(entity);\n"
              "    }")
assert add_anchor in s, "Entities.cpp all_entities.push_back anchor not found"
add_new = (add_anchor + "\n"
  "    // [SOLARUS_IDLEPARK] mirror into the walk list; destructibles start active and\n"
  "    // park on their first idle tick. Cache the list iterator for O(1) park/wake.\n"
  "    if (type != EntityType::HERO) {\n"
  "      auto _ip_it = entities_to_update.insert(entities_to_update.end(), entity);\n"
  "      if (type == EntityType::DESTRUCTIBLE) {\n"
  "        Destructible* _d = static_cast<Destructible*>(entity.get());\n"
  "        _d->idlepark_it = _ip_it;\n"
  "        _d->idlepark_parked = false;\n"
  "        destructibles.push_back(_d);\n"
  "      }\n"
  "    }")
s = s.replace(add_anchor, add_new, 1)

rem_anchor = ("    // Remove it from the whole list.\n"
              "    all_entities.remove(entity);")
assert rem_anchor in s, "Entities.cpp all_entities.remove anchor not found"
rem_new = (rem_anchor + "\n"
  "    // [SOLARUS_IDLEPARK] mirror removal into the walk list + destructibles cache.\n"
  "    if (type == EntityType::DESTRUCTIBLE) {\n"
  "      Destructible* _d = static_cast<Destructible*>(entity.get());\n"
  "      if (!_d->idlepark_parked) entities_to_update.erase(_d->idlepark_it);\n"
  "      destructibles.erase(std::remove(destructibles.begin(), destructibles.end(), _d),\n"
  "                          destructibles.end());\n"
  "    } else if (type != EntityType::HERO) {\n"
  "      entities_to_update.remove(entity);\n"
  "    }")
s = s.replace(rem_anchor, rem_new, 1)

open(path, "w").write(s)
print("Entities.cpp SOLARUS_IDLEPARK wake/park + maintenance injected")
PYIDLEPARK
fi

# --- [SOLARUS_IDLEPARK] Destructible.h: parked flag + iterator + accessors. ---
DESTRH="$SRC/include/solarus/entities/Destructible.h"
if ! grep -q "idlepark_parked" "$DESTRH"; then
  python3 - "$DESTRH" <<'PYDESTRH'
import sys
path = sys.argv[1]
s = open(path).read()
# ensure <list>/<memory> for the iterator member type
if "#include <list>" not in s:
    idx = s.index("#include"); eol = s.index("\n", idx)
    s = s[:eol+1] + "#include <list>\n#include <memory>\n" + s[eol+1:]
anchor = "    bool is_regenerating;              /**< Whether this object is currently regenerating. */"
assert anchor in s, "Destructible.h is_regenerating field anchor not found"
add = (anchor + "\n\n"
  "  public:\n"
  "    // [SOLARUS_IDLEPARK] parking bookkeeping + accessors for the idle predicate.\n"
  "    bool get_is_being_cut() const { return is_being_cut; }\n"
  "    bool get_is_regenerating() const { return is_regenerating; }\n"
  "    bool idlepark_parked = false;\n"
  "    std::list<std::shared_ptr<Entity>>::iterator idlepark_it;\n"
  "  private:")
s = s.replace(anchor, add, 1)
open(path, "w").write(s)
print("Destructible.h SOLARUS_IDLEPARK fields injected")
PYDESTRH
fi

# --- [SOLARUS_IDLEPARK] Destructible.cpp: wake hooks at cut/lift + explode. ---
DESTR="$SRC/src/entities/Destructible.cpp"
if ! grep -q "wake_destructible(this)" "$DESTR"; then
  python3 - "$DESTR" <<'PYDESTRWAKE'
import sys
path = sys.argv[1]
s = open(path).read()
# Entities.h must be complete to call wake_destructible/idlepark_enabled.
if '#include "solarus/entities/Entities.h"' not in s:
    idx = s.index("#include"); eol = s.index("\n", idx)
    s = s[:eol+1] + '#include "solarus/entities/Entities.h"\n' + s[eol+1:]
hook = ("\n  // [SOLARUS_IDLEPARK] a cut/lift/destroy re-activates a parked destructible now.\n"
        "  if (get_entities().idlepark_enabled) get_entities().wake_destructible(this);\n")
for fn in ("void Destructible::play_destroy_animation() {",
           "void Destructible::explode() {"):
    assert fn in s, "Destructible.cpp anchor not found: " + fn
    s = s.replace(fn, fn + hook, 1)
open(path, "w").write(s)
print("Destructible.cpp SOLARUS_IDLEPARK wake hooks injected")
PYDESTRWAKE
fi

# --- [enemy split] bracket the enemy AI Lua callback (entity_on_update) so the
#     renderer's [blitter entphase] banner can split the enemy update cost into
#     AI-Lua (single-lua_State-bound, throttle-only) vs non-Lua (state machine +
#     movement + collision-on-move, the SIMD/parallel candidate). Diag-gated. ---
ENEMY="$SRC/src/entities/Enemy.cpp"
if ! grep -q "g_me_enemy_lua_ns" "$ENEMY"; then
  python3 - "$ENEMY" <<'PYENEMY'
import sys
path = sys.argv[1]
s = open(path).read()

# file-scope: <time.h> + extern counter + a monotonic-ns helper, after 1st include.
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  '// [enemy split] AI-Lua profiling counter (defined in mister_blitter_renderer.cpp).\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long  g_me_enemy_lua_ns;\n'
  '}\n'
  'namespace { inline long long _me_now_ns_enemy() {\n'
  '  struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '  return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '} }\n'
)
s = s[:eol+1] + block + s[eol+1:]

# bracket the once-per-enemy-per-tick AI callback at the end of Enemy::update().
old = "  get_lua_context()->entity_on_update(*this);"
new = (
  "  {\n"
  "    long long _me_el0 = g_mister_lua_diag ? _me_now_ns_enemy() : 0;\n"
  "    get_lua_context()->entity_on_update(*this);\n"
  "    if (g_mister_lua_diag) g_me_enemy_lua_ns += _me_now_ns_enemy() - _me_el0;\n"
  "  }"
)
assert s.count(old) == 1, "Enemy.cpp entity_on_update anchor not unique"
s = s.replace(old, new, 1)

open(path, "w").write(s)
print("Enemy.cpp AI-Lua split instrumentation injected")
PYENEMY
fi

# --- [enemy entsplit] Finer per-phase attribution of the enemy NON-LUA update cost.
#     Enemy::update() -> Entity::update() does the heavy work; split it into the three
#     Entity::update phases (sprite/anim, movement, state incl. stream) and, as a
#     cross-cutting nested subset, the collision-with-detectors quadtree cost (timed
#     at the Map funnel, below). All enemy-only (get_type()==ENEMY) + diag-gated, so a
#     non-enemy entity pays only one get_type() + branch. Feeds the [blitter entsplit]
#     banner so STEP-2 picks the lever (prune collision vs SIMD movement). ---
ENTITY="$SRC/src/entities/Entity.cpp"
if ! grep -q "g_me_ent_sprite_ns" "$ENTITY"; then
  python3 - "$ENTITY" <<'PYENTSPLIT'
import sys
path = sys.argv[1]
s = open(path).read()

# file-scope: <time.h> + extern phase counters + a monotonic-ns helper, after 1st include.
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  '// [enemy entsplit] enemy non-lua phase counters (defined in mister_blitter_renderer.cpp).\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long g_me_ent_sprite_ns;\n'
  '  extern volatile long long g_me_ent_move_ns;\n'
  '  extern volatile long long g_me_ent_state_ns;\n'
  '  extern volatile long long g_me_ent_qtree_ns;\n'
  '  extern volatile long long g_me_ent_ground_ns;\n'
  '}\n'
  'namespace { inline long long _me_now_ns_ent() {\n'
  '  struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '  return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '} }\n'
)
s = s[:eol+1] + block + s[eol+1:]

# bracket the three phases in Entity::update(). get_type()==ENEMY (virtual) restricts
# accumulation to enemies; clock reads only fire when _me_en. clear_old_movements() is
# folded into the movement bucket, update_stream_action() into the state bucket.
old = """  update_sprites();

  // Update the movement.
  if (movement != nullptr) {
    movement->update();
  }
  clear_old_movements();
  update_stream_action();

  // Update the state if any.
  update_state();"""
new = """  const bool _me_en = g_mister_lua_diag && get_type() == EntityType::ENEMY;

  { long long _me_t = _me_en ? _me_now_ns_ent() : 0;
    update_sprites();
    if (_me_en) g_me_ent_sprite_ns += _me_now_ns_ent() - _me_t; }

  // Update the movement.
  { long long _me_t = _me_en ? _me_now_ns_ent() : 0;
    if (movement != nullptr) {
      movement->update();
    }
    clear_old_movements();
    if (_me_en) g_me_ent_move_ns += _me_now_ns_ent() - _me_t; }

  { long long _me_t = _me_en ? _me_now_ns_ent() : 0;
    update_stream_action();
    // Update the state if any.
    update_state();
    if (_me_en) g_me_ent_state_ns += _me_now_ns_ent() - _me_t; }"""
assert s.count(old) == 1, "Entity::update phase anchor not unique"
s = s.replace(old, new, 1)

# [move drill L2] Split the per-move bookkeeping in notify_position_changed (fired on
# EVERY enemy move) into quadtree-reinsert vs ground-requery. detector collision here
# funnels into Map::check_collision_with_detectors (already timed as g_me_ent_coll_ns).
np_old = """  // Notify the quadtree.
  notify_bounding_box_changed();

  if (is_detector()) {
    // Since this entity is a detector, all entities need to check
    // their collisions with it.
    get_map().check_collision_from_detector(*this);
  }

  // Check collisions between this entity and other detectors.
  check_collision_with_detectors();

  // Update the ground.
  if (is_ground_modifier()) {
    update_ground_observers();
  }
  update_ground_below();"""
np_new = """  const bool _me_en2 = g_mister_lua_diag && get_type() == EntityType::ENEMY;

  // Notify the quadtree.
  { long long _me_t = _me_en2 ? _me_now_ns_ent() : 0;
    notify_bounding_box_changed();
    if (_me_en2) g_me_ent_qtree_ns += _me_now_ns_ent() - _me_t; }

  if (is_detector()) {
    // Since this entity is a detector, all entities need to check
    // their collisions with it.
    get_map().check_collision_from_detector(*this);
  }

  // Check collisions between this entity and other detectors.
  check_collision_with_detectors();

  // Update the ground.
  { long long _me_t = _me_en2 ? _me_now_ns_ent() : 0;
    if (is_ground_modifier()) {
      update_ground_observers();
    }
    update_ground_below();
    if (_me_en2) g_me_ent_ground_ns += _me_now_ns_ent() - _me_t; }"""
assert s.count(np_old) == 1, "notify_position_changed anchor not unique"
s = s.replace(np_old, np_new, 1)

open(path, "w").write(s)
print("Entity.cpp entsplit phase instrumentation injected")
PYENTSPLIT
fi

# --- [enemy entsplit] collision subset: time Map::check_collision_with_detectors (both
#     overloads funnel the quadtree query + per-detector overlap). RAII timer captures
#     all return paths; enemy-only (entity.get_type()==ENEMY) + diag-gated. This cost is
#     NESTED inside the sprite (frame-change pixel collision) and move (position-changed
#     notify) phases above, so the banner reports it as an of-which subset. ---
MAP="$SRC/src/core/Map.cpp"
if ! grep -q "g_me_ent_coll_ns" "$MAP"; then
  python3 - "$MAP" <<'PYMAPCOLL'
import sys
path = sys.argv[1]
s = open(path).read()

# file-scope: <time.h> + EntityType + extern counter + ns helper + RAII timer.
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  '#include "solarus/entities/EntityType.h"\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long g_me_ent_coll_ns;\n'
  '}\n'
  'namespace {\n'
  '  inline long long _me_now_ns_map() {\n'
  '    struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '    return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '  }\n'
  '  struct _MeCollTimer {\n'
  '    long long t0; bool on;\n'
  '    explicit _MeCollTimer(bool en) : t0(en ? _me_now_ns_map() : 0), on(en) {}\n'
  '    ~_MeCollTimer() { if (on) g_me_ent_coll_ns += _me_now_ns_map() - t0; }\n'
  '  };\n'
  '}\n'
)
s = s[:eol+1] + block + s[eol+1:]

# arm the RAII timer at the top of both check_collision_with_detectors overloads.
for sig in ("void Map::check_collision_with_detectors(Entity& entity) {",
            "void Map::check_collision_with_detectors(Entity& entity, Sprite& sprite) {"):
    assert s.count(sig) == 1, "Map collision overload not unique: " + sig
    s = s.replace(sig, sig + "\n  _MeCollTimer _me_ct(g_mister_lua_diag && "
                  "entity.get_type() == EntityType::ENEMY);", 1)

open(path, "w").write(s)
print("Map.cpp entsplit collision timer injected")
PYMAPCOLL
fi

# --- [move drill] Split the enemy MOVE phase into integration-math vs terrain-obstacle
#     collision. Movement::test_collision_with_obstacles(int,int) is the single funnel
#     for ALL movement subclasses' obstacle testing (the Point overload delegates to it;
#     StraightMovement/PathFinding/etc all route here -> map.test_collision_with_obstacles).
#     Time it -> g_me_ent_obst_ns; the banner derives integration = move - obstacle. RAII
#     timer, enemy-only (entity->get_type()==ENEMY, nullptr-guarded) + diag-gated. ---
MOVEMENT="$SRC/src/movements/Movement.cpp"
if ! grep -q "g_me_ent_obst_ns" "$MOVEMENT"; then
  python3 - "$MOVEMENT" <<'PYMOVEOBST'
import sys
path = sys.argv[1]
s = open(path).read()

# file-scope: <time.h> + EntityType + extern counter + ns helper + RAII timer.
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  '#include "solarus/entities/EntityType.h"\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long g_me_ent_obst_ns;\n'
  '}\n'
  'namespace {\n'
  '  inline long long _me_now_ns_mv() {\n'
  '    struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '    return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '  }\n'
  '  struct _MeObstTimer {\n'
  '    long long t0; bool on;\n'
  '    explicit _MeObstTimer(bool en) : t0(en ? _me_now_ns_mv() : 0), on(en) {}\n'
  '    ~_MeObstTimer() { if (on) g_me_ent_obst_ns += _me_now_ns_mv() - t0; }\n'
  '  };\n'
  '}\n'
)
s = s[:eol+1] + block + s[eol+1:]

# arm the RAII timer at the top of the int,int funnel (const method; entity is a member).
sig = "bool Movement::test_collision_with_obstacles(int dx, int dy) const {"
assert s.count(sig) == 1, "Movement obstacle funnel not unique"
s = s.replace(sig, sig + "\n  _MeObstTimer _me_ot(g_mister_lua_diag && entity != nullptr && "
              "entity->get_type() == EntityType::ENEMY);", 1)

open(path, "w").write(s)
print("Movement.cpp move-drill obstacle timer injected")
PYMOVEOBST
fi

# --- [perf SOLARUS_IDLESKIP] idle-destructible update-skip. A static, uncut,
#     non-regenerating, movement-less destructible's update() (and the base
#     Entity::update() it calls) is a per-tick no-op; the 100Hz catch-up runs it
#     ~4-5x/frame for ~600-660 grass/bushes (~4.5ms). Skip it when the pure
#     predicate (tests/idleskip_test.c, TDD'd) proves the tick is a no-op.
#     Env-gated (default OFF), engine-only, no ABI/RTL change. ---
cp patches/mister/mister_idleskip.h "$SRC/src/entities/"
DESTR="$SRC/src/entities/Destructible.cpp"
if ! grep -q "solarus_destructible_skippable" "$DESTR"; then
  python3 - "$DESTR" <<'PYDESTR'
import sys
path = sys.argv[1]
s = open(path).read()

# includes: <cstdlib> (getenv) + the predicate header + extern skip counters.
idx = s.index("#include"); eol = s.index("\n", idx)
s = s[:eol+1] + (
  '#include <cstdlib>\n'
  '#include "mister_idleskip.h"\n'
  'extern "C" { extern volatile long long g_me_destr_seen, g_me_destr_skipped; }\n'
) + s[eol+1:]

# early-out at the very top of Destructible::update().
old = """void Destructible::update() {

  Entity::update();"""
new = """void Destructible::update() {

  // [perf SOLARUS_IDLESKIP] Skip the whole tick when this destructible is provably
  // idle+static: an uncut, non-regenerating, movement-less, stream-less destructible
  // with no animating sprite changes no observable state and fires no callback this
  // tick, so Destructible::update() AND the Entity::update() below are a no-op.
  // Conservative: any doubt -> fall through to the normal update. (Destructibles do
  // not use sprite frame-synchronization, so a static get_frame_delay()==0 sprite is
  // safe to treat as non-animating.)
  {
    static const bool _idleskip = (std::getenv("SOLARUS_IDLESKIP") != nullptr);
    if (_idleskip) {
      ++g_me_destr_seen;
      // main sprite by REF (no per-call allocation, unlike get_sprites()); a
      // destructible has a single sprite, so this is its animation state.
      const SpritePtr& _sp = get_sprite();
      bool _spr_change = _sp && !_sp->is_paused() && !_sp->is_animation_finished()
                      && _sp->get_frame_delay() > 0;
      if (solarus_destructible_skippable(
              is_suspended() ? 1 : 0,
              is_being_cut ? 1 : 0,
              is_waiting_for_regeneration() ? 1 : 0,
              is_regenerating ? 1 : 0,
              (get_movement() != nullptr) ? 1 : 0,
              has_stream_action() ? 1 : 0,
              _spr_change ? 1 : 0)) {
        ++g_me_destr_skipped;
        return;
      }
    }
  }

  Entity::update();"""
assert old in s, "Destructible::update anchor not found"
s = s.replace(old, new, 1)

open(path, "w").write(s)
print("Destructible.cpp SOLARUS_IDLESKIP update-skip injected")
PYDESTR
fi

GAME="$SRC/src/core/Game.cpp"
if ! grep -q "g_me_upd_tileset_ns" "$GAME"; then
  python3 - "$GAME" <<'PYME2'
import sys
path = sys.argv[1]
s = open(path).read()
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long  g_me_upd_tileset_ns;\n'
  '}\n'
  'namespace { inline long long _me_now_ns_g() {\n'
  '  struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '  return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '} }\n'
)
s = s[:eol+1] + block + s[eol+1:]
old = """  // Update the map.
  update_tilesets();
  current_map->update();"""
new = """  // Update the map.
  {
    long long _me_t0 = g_mister_lua_diag ? _me_now_ns_g() : 0;
    update_tilesets();
    if (g_mister_lua_diag) g_me_upd_tileset_ns += _me_now_ns_g() - _me_t0;
  }
  current_map->update();"""
assert old in s, "Game::update update_tilesets anchor not found"
s = s.replace(old, new, 1)
open(path, "w").write(s)
print("Game.cpp tileset-timer instrumentation injected")
PYME2
fi

# 1f-2. [eng_cpp "other" attribution] Two extra buckets the [blitter engcpp] banner
#       needs to PIN the previously-unaccounted ~14ms "other":
#         (1) g_me_steps  — sum of MainLoop num_updates (the catch-up STEP count).
#             The renderer's "update" phase wall-time runs step() num_updates times
#             per DISPLAYED frame to hold game-time at 60Hz when slow, so EVERY
#             eng_cpp bucket is ~num_updates-amplified. steps/fr lets the banner
#             divide eng_cpp down to a true per-tick figure (the headline finding:
#             "other" is mostly catch-up amplification, not a fixed per-frame cost).
#         (2) g_me_upd_sound_ns — System::update() wall-ns (Sound mix/pump + Music
#             decode), the largest non-Lua eng_cpp slice not previously timed.
#       MainLoop.cpp / System.cpp are NOT git-checkout-reset, so a one-time grep-
#       guarded injection survives rebuilds. Both gated on g_mister_lua_diag.
if ! grep -q "g_me_steps" "$ML"; then
  python3 - "$ML" <<'PYSTEPS'
import sys
path = sys.argv[1]
s = open(path).read()
# extern decl after the first include (file scope, C linkage to match the renderer).
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\nextern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long g_me_steps;\n'
  '}\n'
)
s = s[:eol+1] + block + s[eol+1:]
# accumulate num_updates once per displayed frame, after the catch-up while loop.
anchor = "    double mp_t1 = mister_prof ? mister_ms() : 0.0;"
assert anchor in s, "MainLoop num_updates accumulation anchor not found"
s = s.replace(anchor,
  "    if (g_mister_lua_diag) g_me_steps += num_updates;  // [eng_cpp] catch-up step count\n"
  + anchor, 1)
open(path, "w").write(s)
print("MainLoop.cpp g_me_steps (catch-up step count) instrumentation injected")
PYSTEPS
fi

# [residency] Fire the one-time whole-quest asset preload at quest-open (renderer up + quest
# mounted by MainLoop's ctor; run() start is the first safe point). Idempotent.
if ! grep -q "mister_preload_quest_assets" "$ML"; then
  edit_inplace "$ML" '1s|^|#include "solarus/graphics/sdlrenderer/mister_blitter_renderer.h"\n|'
  edit_inplace "$ML" 's|void MainLoop::run() {|void MainLoop::run() {\n  mister_preload_quest_assets();|'
fi

# [residency] Notify the blitter when a surface is destroyed so its cache/slots are
# reclaimed (fixes stale-pointer reuse). Idempotent: only patch once.
SIMPL="$SRC/src/graphics/SurfaceImpl.cpp"
if ! grep -q "mister_forget_surface" "$SIMPL"; then
  edit_inplace "$SIMPL" '1s|^|#include "solarus/graphics/sdlrenderer/mister_blitter_renderer.h"\n|'
  edit_inplace "$SIMPL" 's|SurfaceImpl::~SurfaceImpl() *{|SurfaceImpl::~SurfaceImpl() {\n  mister_forget_surface(this);|'
fi

SYS="$SRC/src/core/System.cpp"
if ! grep -q "g_me_upd_sound_ns" "$SYS"; then
  python3 - "$SYS" <<'PYSND'
import sys
path = sys.argv[1]
s = open(path).read()
idx = s.index("#include"); eol = s.index("\n", idx)
block = (
  '\n#include <time.h>\n'
  'extern "C" {\n'
  '  extern volatile int       g_mister_lua_diag;\n'
  '  extern volatile long long g_me_upd_sound_ns;\n'
  '}\n'
  'namespace { inline long long _me_now_ns_s() {\n'
  '  struct timespec _ts; clock_gettime(CLOCK_MONOTONIC, &_ts);\n'
  '  return (long long)_ts.tv_sec * 1000000000LL + _ts.tv_nsec;\n'
  '} }\n'
)
s = s[:eol+1] + block + s[eol+1:]
old = """  ticks += timestep;
  Sound::update();
}"""
new = """  ticks += timestep;
  {
    long long _me_t0 = g_mister_lua_diag ? _me_now_ns_s() : 0;
    Sound::update();
    if (g_mister_lua_diag) g_me_upd_sound_ns += _me_now_ns_s() - _me_t0;
  }
}"""
assert old in s, "System::update Sound::update anchor not found"
s = s.replace(old, new, 1)
open(path, "w").write(s)
print("System.cpp sound-timer (g_me_upd_sound_ns) instrumentation injected")
PYSND
fi


# 1g. [#52 tilelist] TilePattern::get_draw_region — draw-free (src_rect,dst) query
#     for batchable patterns. Base TilePattern default returns false; SimpleTilePattern
#     and AnimatedTilePattern override to return true. Idempotent.
#     Parallax tiles ARE batchable: AnimatedTilePattern(parallax) returns true, and
#     ParallaxScrollingTilePattern inherits SimpleTilePattern's override (true). Their
#     camera/ratio scroll is supplied by the per-bucket bias at emit (scroll_ratio), NOT
#     by escaping. (Only a whole-map TL_BUF overflow escapes -> res_fatal.)
TPH="$SRC/include/solarus/entities/TilePattern.h"
if ! grep -q "get_draw_region" "$TPH"; then
  python3 - "$TPH" <<'PYTP'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="    virtual void draw("
i=s.index(anchor)
decl=("    // [MiSTer #52] Draw-free batch query: return (src_rect,dst) without drawing.\n"
      "    // Default false = not batchable (caller draws normally).\n"
      "    virtual bool get_draw_region(const Point& dst_position, const Tileset& tileset,\n"
      "                                 Rectangle& out_src, Point& out_dst) const { return false; }\n\n")
s=s[:i]+decl+s[i:]; open(p,"w").write(s)
print("TilePattern.h get_draw_region decl added")
PYTP
fi

# SimpleTilePattern.h: add override declaration after is_animated
STPH="$SRC/include/solarus/entities/SimpleTilePattern.h"
if ! grep -q "get_draw_region" "$STPH"; then
  python3 - "$STPH" <<'PYSTPH'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="    virtual bool is_animated() const override;\n"
i=s.index(anchor)
decl=("    virtual bool get_draw_region(const Point& dst_position, const Tileset& tileset,\n"
      "                                 Rectangle& out_src, Point& out_dst) const override;\n")
s=s[:i+len(anchor)]+decl+s[i+len(anchor):]
open(p,"w").write(s)
print("SimpleTilePattern.h get_draw_region override decl added")
PYSTPH
fi

# SimpleTilePattern.cpp: insert impl before the closing namespace brace
STP="$SRC/src/entities/SimpleTilePattern.cpp"
if ! grep -q "get_draw_region" "$STP"; then
  python3 - "$STP" <<'PYSTP'
import sys
p=sys.argv[1]; s=open(p).read()
add=("\nbool SimpleTilePattern::get_draw_region(const Point& dst_position, const Tileset&,\n"
     "    Rectangle& out_src, Point& out_dst) const {\n"
     "  out_src = position_in_tileset; out_dst = dst_position; return true;\n"
     "}\n\n")
i=s.rfind("}")   # last } = closing namespace Solarus
s=s[:i]+add+s[i:]
open(p,"w").write(s)
print("SimpleTilePattern get_draw_region impl added")
PYSTP
fi

# AnimatedTilePattern.h: add override declaration after is_drawn_at_its_position
ATPH="$SRC/include/solarus/entities/AnimatedTilePattern.h"
if ! grep -q "get_draw_region" "$ATPH"; then
  python3 - "$ATPH" <<'PYATPH'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="    bool is_drawn_at_its_position() const override;\n"
i=s.index(anchor)
decl=("    bool get_draw_region(const Point& dst_position, const Tileset& tileset,\n"
      "                         Rectangle& out_src, Point& out_dst) const override;\n")
s=s[:i+len(anchor)]+decl+s[i+len(anchor):]
open(p,"w").write(s)
print("AnimatedTilePattern.h get_draw_region override decl added")
PYATPH
fi

# AnimatedTilePattern.cpp: insert impl before the closing namespace brace.
#   Mirrors draw() exactly: same frame-index expression, same parallax escape.
ATP="$SRC/src/entities/AnimatedTilePattern.cpp"
if ! grep -q "get_draw_region" "$ATP"; then
  python3 - "$ATP" <<'PYATP'
import sys
p=sys.argv[1]; s=open(p).read()
add=("\nint mister_camera_x(); int mister_camera_y();  // [#52] published camera top-left\n"
     "bool AnimatedTilePattern::get_draw_region(const Point& dst_position, const Tileset&,\n"
     "    Rectangle& out_src, Point& out_dst) const {\n"
     "  int num_frames = (int)frames.size();\n"
     "  int final_frame_index = frame_index;\n"
     "  if (mirror_loop && frame_index >= num_frames)\n"
     "    final_frame_index = (2 * num_frames - 2) - frame_index;\n"
     "  out_src = frames[final_frame_index];\n"
     "  out_dst = dst_position;\n"
     "  // [#52] Parallax tiles have a viewport-dependent dst. They are batchable in the\n"
     "  // RESIDENT path (it rebuilds on any camera move), so the published camera top-left\n"
     "  // gives the correct fixed dst while the cached list is used. Mirrors draw() exactly.\n"
     "  if (parallax)\n"
     "    out_dst += Point(mister_camera_x(), mister_camera_y()) / ParallaxScrollingTilePattern::ratio;\n"
     "  return true;\n"
     "}\n\n")
i=s.rfind("}")   # last } = closing namespace Solarus
s=s[:i]+add+s[i:]
open(p,"w").write(s)
print("AnimatedTilePattern get_draw_region impl added")
PYATP
fi

# [#52 resident / Tier B] Per-pattern FRAME accessors. The fabric resident path needs,
# per distinct pattern: the full set of frame rects (-> FRT table, built once/scene) and
# the current mirror-resolved frame index (-> CFT table, written each frame). Add three
# virtuals to TilePattern (base default = 1 static frame) + overrides on Simple/Animated.
TPH="$SRC/include/solarus/entities/TilePattern.h"
if ! grep -q "get_frame_count" "$TPH"; then
  python3 - "$TPH" <<'PYTPF'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="    virtual bool get_draw_region(const Point& dst_position, const Tileset& tileset,\n"
i=s.index(anchor)
decl=("    // [MiSTer #52 Tier B] Frame table accessors for the resident fabric path.\n"
      "    // Default: a single static frame whose rect comes from get_draw_region.\n"
      "    virtual int get_frame_count() const { return 1; }\n"
      "    virtual Rectangle get_frame_rect(int /*frame*/, const Tileset& tileset) const {\n"
      "      Rectangle src; Point dst; get_draw_region(Point(0,0), tileset, src, dst); return src;\n"
      "    }\n"
      "    virtual int get_current_frame() const { return 0; }\n")
s=s[:i]+decl+s[i:]; open(p,"w").write(s)
print("TilePattern.h frame accessors added")
PYTPF
fi

ATPH="$SRC/include/solarus/entities/AnimatedTilePattern.h"
if ! grep -q "get_frame_count" "$ATPH"; then
  python3 - "$ATPH" <<'PYATPF'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="    bool get_draw_region(const Point& dst_position, const Tileset& tileset,\n"
i=s.index(anchor)
decl=("    int get_frame_count() const override;\n"
      "    Rectangle get_frame_rect(int frame, const Tileset& tileset) const override;\n"
      "    int get_current_frame() const override;\n")
s=s[:i]+decl+s[i:]; open(p,"w").write(s)
print("AnimatedTilePattern.h frame accessors added")
PYATPF
fi

ATP="$SRC/src/entities/AnimatedTilePattern.cpp"
if ! grep -q "get_frame_count" "$ATP"; then
  python3 - "$ATP" <<'PYATPFI'
import sys
p=sys.argv[1]; s=open(p).read()
add=("\nint AnimatedTilePattern::get_frame_count() const { return (int)frames.size(); }\n"
     "\nRectangle AnimatedTilePattern::get_frame_rect(int frame, const Tileset&) const {\n"
     "  if (frame < 0 || frame >= (int)frames.size()) return Rectangle();\n"
     "  return frames[frame];\n"
     "}\n"
     "\nint AnimatedTilePattern::get_current_frame() const {\n"
     "  // mirror-resolved final_frame_index (matches draw()/get_draw_region).\n"
     "  int num_frames = (int)frames.size();\n"
     "  int final_frame_index = frame_index;\n"
     "  if (mirror_loop && frame_index >= num_frames)\n"
     "    final_frame_index = (2 * num_frames - 2) - frame_index;\n"
     "  return final_frame_index;\n"
     "}\n")
i=s.rfind("}")   # last } = closing namespace Solarus
s=s[:i]+add+s[i:]; open(p,"w").write(s)
print("AnimatedTilePattern frame accessors impl added")
PYATPFI
fi

# [#52 tilelist Task 6, collapsed Task 7] TileBatchEntry struct on the base Renderer
# class. [Task 7] The base batched-tile virtual + its software-decompose default body
# (Task 6's original addition here) are DELETED: once the resident path collapsed to a
# single fabric-resolved path with no fallback, nothing calls it anymore (MisterBlitter-
# Renderer no longer overrides it, and the engine walk no longer calls it either) —
# TileBatchEntry itself stays, since resident_record_batch's signature (below) still
# carries entries in that shape.
RH="$SRC/include/solarus/graphics/Renderer.h"
if ! grep -q "struct TileBatchEntry" "$RH"; then
  python3 - "$RH" <<'PYTILEB'
import sys
p = sys.argv[1]
sh = open(p).read()

# Add #include <vector> after #include <memory>
if '#include <vector>' not in sh:
    sh = sh.replace('#include <memory>', '#include <memory>\n#include <vector>', 1)

# Add TileBatchEntry struct in Solarus namespace, before class Renderer
tile_struct = (
    "// [#52] Per-tile (src_rect, dst) pair; shape carried through resident_record_batch.\n"
    "struct TileBatchEntry { Rectangle src; Point dst; };\n\n"
)
anchor_class = "class Renderer\n{"
assert anchor_class in sh, "Renderer class anchor not found in Renderer.h"
sh = sh.replace(anchor_class, tile_struct + anchor_class, 1)
open(p, "w").write(sh)
print("[#52 Task 6, collapsed Task 7] Renderer.h: TileBatchEntry struct added")
PYTILEB
fi

# [#52 resident, Task 7] Base Renderer resident-tile-list virtuals (SOLARUS_TILERESIDENT).
# Default impls are no-ops (software path does not participate); MisterBlitterRenderer
# overrides all of them. Mode: 1=build(record) / 2=fast(replay+patch) / 0=disabled.
RH="$SRC/include/solarus/graphics/Renderer.h"
if ! grep -q "resident_begin_frame" "$RH"; then
  python3 - "$RH" <<'PYRES'
import sys
p=sys.argv[1]; s=open(p).read()
if '#include <cstdint>' not in s:
    s=s.replace('#include <vector>', '#include <vector>\n#include <cstdint>', 1)
anchor = "  virtual void draw(SurfaceImpl& dst, const SurfaceImpl& src, const DrawInfos& infos) = 0;\n"
assert anchor in s, "Renderer draw() pure-virtual anchor not found in Renderer.h"
decl=(
"\n"
"  // [#52 resident, Task 7] Resident animated-tile list (SOLARUS_TILERESIDENT), the SOLE\n"
"  // fabric animated-tile path (no legacy/engine-src-patch tier, no per-scene escape).\n"
"  // Default impls are no-ops; MisterBlitterRenderer overrides.\n"
"  // resident_begin_frame returns the per-frame mode: 0 = disabled (unset / fabric off /\n"
"  // mid transition-scroll), 1 = build (walk + resident_record_batch/resident_escape),\n"
"  // 2 = fast (skip the walk; per pattern call resident_update, then resident_emit_layer\n"
"  // per layer).\n"
"  virtual int resident_begin_frame(uintptr_t /*map_id*/, uintptr_t /*tileset_id*/) { return 0; }\n"
"  virtual bool resident_take_patch_turn() { return false; }\n"
"  virtual std::size_t resident_pattern_count() const { return 0; }\n"
"  virtual uintptr_t resident_pattern_token(std::size_t /*k*/) const { return 0; }\n"
"  // Per-pattern per-frame update: writes the current frame (CFT) + captures the frame\n"
"  // rects (FRT) the fabric resolves src from. frames[] holds frame_count rects (<= 8).\n"
"  // cur_src is frames[current_frame].\n"
"  virtual void resident_update(uintptr_t /*token*/, const Rectangle& /*cur_src*/,\n"
"                               int /*current_frame*/, int /*frame_count*/,\n"
"                               const Rectangle* /*frames*/) {}\n"
"  virtual void resident_record_batch(int /*layer*/, int /*scroll_ratio*/,\n"
"                                     const SurfaceImpl& /*tileset_image*/,\n"
"                                     BlendMode /*blend*/,\n"
"                                     const std::vector<TileBatchEntry>& /*entries*/,\n"
"                                     const std::vector<uintptr_t>& /*tokens*/) {}\n"
"  // [Task 7: no per-tile oracle] resident_escape used to record a non-batchable tile\n"
"  // (repeated/parallax) for ordered per-tile replay; that mechanism is gone — hitting it\n"
"  // is now a hard failure (MisterBlitterRenderer logs + latches res_fatal). The fast path\n"
"  // drives the interleaved per-layer op list: resident_layer_op_count, then per op\n"
"  // resident_emit_layer_op (renderer emits the bucket; every op is a bucket now).\n"
"  // resident_layer_op_tile always returns 0 (kept for ABI symmetry, unused).\n"
"  virtual void resident_escape(int /*layer*/, uintptr_t /*tile*/) {}\n"
"  virtual void resident_emit_layer(int /*layer*/) {}\n"
"  virtual int resident_layer_op_count(int /*layer*/) const { return 0; }\n"
"  virtual uintptr_t resident_layer_op_tile(int /*layer*/, int /*i*/) const { return 0; }\n"
"  virtual void resident_emit_layer_op(int /*layer*/, int /*i*/) {}\n"
"  // Remaining TL_BUF capacity (in tile entries) so the batcher can expand repeated/fill\n"
"  // tiles into per-cell entries without overflowing; software path is unbounded.\n"
"  virtual int resident_room_entries() const { return 1 << 30; }\n"
"  // [static tile-list] Non-animated tile buckets, parallel to resident_record_batch/\n"
"  // resident_layer_op_count/resident_emit_layer_op but for the direct BLT_OP_TILELIST\n"
"  // path (12-byte entries, no FRT/pattern indirection). Default impls are no-ops.\n"
"  virtual void resident_record_static(int /*layer*/, int /*scroll_ratio*/,\n"
"                                      const SurfaceImpl& /*tileset_image*/,\n"
"                                      BlendMode /*blend*/,\n"
"                                      const std::vector<TileBatchEntry>& /*entries*/) {}\n"
"  virtual int  resident_static_op_count(int /*layer*/) const { return 0; }\n"
"  virtual void resident_emit_static_op(int /*layer*/, int /*i*/) {}\n")
s=s.replace(anchor, anchor+decl, 1)
open(p,"w").write(s)
print("[#52 resident] Renderer.h: resident-tile-list virtuals added")
PYRES
fi
# [static tile-list] Upgrade an already-patched checkout (the block above is skipped once
# resident_begin_frame exists) with the static-bucket virtuals, same pattern as the audio
# pump upgrade above: guard on the new marker specifically, insert after resident_room_entries.
if ! grep -q "resident_record_static" "$RH"; then
  python3 - "$RH" <<'PYRESSTATIC'
import sys
p=sys.argv[1]; s=open(p).read()
anchor = "  virtual int resident_room_entries() const { return 1 << 30; }\n"
assert anchor in s, "resident_room_entries anchor not found in Renderer.h"
decl=(
"  // [static tile-list] Non-animated tile buckets, parallel to resident_record_batch/\n"
"  // resident_layer_op_count/resident_emit_layer_op but for the direct BLT_OP_TILELIST\n"
"  // path (12-byte entries, no FRT/pattern indirection). Default impls are no-ops.\n"
"  virtual void resident_record_static(int /*layer*/, int /*scroll_ratio*/,\n"
"                                      const SurfaceImpl& /*tileset_image*/,\n"
"                                      BlendMode /*blend*/,\n"
"                                      const std::vector<TileBatchEntry>& /*entries*/) {}\n"
"  virtual int  resident_static_op_count(int /*layer*/) const { return 0; }\n"
"  virtual void resident_emit_static_op(int /*layer*/, int /*i*/) {}\n")
s=s.replace(anchor, anchor+decl, 1)
open(p,"w").write(s)
print("[static tile-list] Renderer.h: static-bucket virtuals added (upgrade path)")
PYRESSTATIC
fi


# [#52 tilelist Task 8, collapsed Task 7] Entities::draw animated-tile BATCHING.
# Rewires the per-layer animated-tile loop to collect visible tiles per tileset image
# and flush each bucket into the renderer's resident store (Renderer::resident_record_batch
# -> one BLT_OP_TILELIST_RES on the fabric path; per-entry draw() on the software path).
# MUST run AFTER the 1f instrumentation block (anchors on the post-instrumentation
# loop carrying ++g_me_draw_anim_tiles). Idempotent (grep-guarded on resident_begin_frame).
# [Task 7] SINGLE fabric-resolved path, no fallback: the env-gated per-tile escape hatch
# and the legacy (non-resident) batched-draw branch are both deleted.
#
# Two guarded edits:
#   (a) Tile.h  — minimal public getter for the private `tileset` member
#                 (Tile::draw_on_surface resolves the effective tileset the same way).
#   (b) Entities.cpp — includes (Video/Renderer/<map>) + the batched/resident loop.
#
# Equivalence to the per-tile path (Task 9 HW A/B verifies):
#   - vp = camera->get_top_left_xy()  == the viewport Tile::built_in_draw passes.
#   - effective tileset = tile.get_tileset() ? : &map.get_tileset()  (== draw_on_surface).
#   - dst_position = (top_left - vp)  == fill_surface's single-iteration dst for a
#     one-pattern tile; a REPEATED/FILL tile (entity size != pattern size) is EXPANDED
#     into per-cell resident entries. The escape path (resident_escape -> res_fatal, no
#     per-tile oracle) is reached only when a tile's cells don't fit remaining TL_BUF
#     room (whole-map overflow) or a pattern is non-batchable (get_draw_region false).
#     NOTE: parallax patterns are BATCHABLE (get_draw_region true; camera term via the
#     scroll_ratio bias) — they do NOT escape. The build frame still draws an escaped
#     tile once via tile.draw(*camera) so the fatal is loud, not a silent black-out.
#   - blend passed = tsimg->get_blend_mode() (what draw_region/map_blend use).
#   - g_me_draw_anim_tiles is incremented for EVERY visible animated tile (batched or
#     escaped) so [blitter drawcat] stays meaningful.
TILEH="$SRC/include/solarus/entities/Tile.h"
if ! grep -q "get_tileset" "$TILEH"; then
  python3 - "$TILEH" <<'PYTILEH'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="    bool is_animated() const;\n"
assert anchor in s, "Tile.h is_animated() anchor not found"
getter=("    // [MiSTer #52] Effective per-tile tileset override (nullptr = use the\n"
        "    // map's tileset), mirroring Tile::draw_on_surface. Needed by the\n"
        "    // animated-tile batcher in Entities::draw.\n"
        "    const Tileset* get_tileset() const { return tileset; }\n")
s=s.replace(anchor, anchor+getter, 1)
open(p,"w").write(s)
print("[#52 Task 8] Tile.h: get_tileset() getter added")
PYTILEH
fi

ENT8="$SRC/src/entities/Entities.cpp"
if ! grep -q "resident_begin_frame" "$ENT8"; then
  python3 - "$ENT8" <<'PYTB8'
import sys
p=sys.argv[1]; s=open(p).read()

# (a) includes for Video::get_renderer(), Renderer/TileBatchEntry, std::map.
inc_anchor='#include "solarus/graphics/Surface.h"\n'
assert inc_anchor in s, "Entities.cpp Surface.h include anchor not found"
incs=('#include "solarus/graphics/Renderer.h"  // [#52] TileBatchEntry/resident_record_batch\n'
      '#include "solarus/graphics/Video.h"     // [#52] Video::get_renderer()\n'
      '#include "solarus/entities/ParallaxScrollingTilePattern.h"  // [#52] ::ratio for parallax bias\n')
s=s.replace(inc_anchor, inc_anchor+incs, 1)

# (b) replace the post-instrumentation animated-tile loop with the gated batcher.
old=("""    for (unsigned int i = 0; i < tiles_in_animated_regions[layer].size(); ++i) {
      Tile& tile = *tiles_in_animated_regions[layer][i];
      if (tile.overlaps(*camera) || !tile.is_drawn_at_its_position()) {
        if (g_mister_lua_diag) ++g_me_draw_anim_tiles;
        tile.draw(*camera);
      }
    }""")
assert old in s, "Entities::draw post-instrumentation animated-tile anchor not found"
new=("""    // [#52 resident, Task 7] SINGLE fabric-resolved animated-tile path, no fallback:
    // the env-gated per-tile-loop branch and the legacy (non-resident) batched-walk
    // branch are both gone. resident_begin_frame's per-frame mode:
    //   1 = build (walk + record into the renderer's resident store)
    //   2 = fast  (skip the walk; patch ticked patterns + replay headers)
    //   0 = disabled (SOLARUS_TILERESIDENT unset / fabric off / mid transition-scroll):
    //       the walk below still runs but records nothing (no legacy draw path exists).
    Renderer& R = Video::get_renderer();
    const Point vp = camera->get_top_left_xy();
    const int rmode = R.resident_begin_frame(
        reinterpret_cast<uintptr_t>(&map),
        reinterpret_cast<uintptr_t>(&map.get_tileset()));
    if (rmode == 2) {
      // FAST: update each distinct pattern ONCE this frame (writes the per-pattern
      // current frame + captures the frame rects for the fabric's FRT/CFT resolve),
      // then replay this layer's recorded buckets at their paint position. [Task 7]
      // every op is a bucket now — no escaped-tile replay branch.
      if (R.resident_take_patch_turn()) {
        const Tileset& ts = map.get_tileset();
        const size_t np = R.resident_pattern_count();
        for (size_t k = 0; k < np; ++k) {
          const TilePattern* pat =
              reinterpret_cast<const TilePattern*>(R.resident_pattern_token(k));
          Rectangle cur; Point pdst;
          if (!pat->get_draw_region(Point(0, 0), ts, cur, pdst)) continue;
          Rectangle fr[8];                       // BLT_MAXF = 8 frames max
          int fc = pat->get_frame_count(); if (fc > 8) fc = 8; if (fc < 1) fc = 1;
          for (int f = 0; f < fc; ++f) fr[f] = pat->get_frame_rect(f, ts);
          R.resident_update(reinterpret_cast<uintptr_t>(pat), cur,
                            pat->get_current_frame(), fc, fr);
        }
      }
      const int _nops = R.resident_layer_op_count(layer);
      for (int _oi = 0; _oi < _nops; ++_oi) R.resident_emit_layer_op(layer, _oi);
    }
    else {
      // BUILD (rmode==1) or disabled (rmode==0): walk the animated tiles. In BUILD the
      // bucket flush records into the resident store (tokens parallel entries); when
      // disabled, flush_bucket has nothing to hand the entries to (no legacy draw path).
      const Surface* cur_ts = nullptr;
      SurfacePtr     cur_ts_sp;
      int            cur_scroll_ratio = 1;   // [#52 camera-indep] bucket splits on this
      std::vector<TileBatchEntry> cur_entries;
      std::vector<uintptr_t>      cur_tokens;
      auto flush_bucket = [&]() {
        if (cur_ts != nullptr && !cur_entries.empty() && rmode == 1) {
          R.resident_record_batch(layer, cur_scroll_ratio, cur_ts_sp->get_impl(),
              cur_ts_sp->get_blend_mode(), cur_entries, cur_tokens);
        }
        cur_entries.clear();
        cur_tokens.clear();
        cur_ts = nullptr;
        cur_ts_sp = nullptr;
      };
      for (unsigned int i = 0; i < tiles_in_animated_regions[layer].size(); ++i) {
        Tile& tile = *tiles_in_animated_regions[layer][i];
        const bool _visible = tile.overlaps(*camera) || !tile.is_drawn_at_its_position();
        // [#52 camera-independent] BUILD (rmode==1) records the WHOLE MAP so the resident
        // list is camera-independent (the fabric culls off-screen entries via the per-bucket
        // bias); disabled (rmode==0) keeps the viewport cull (moot: nothing is recorded).
        if (rmode != 1 && !_visible) continue;
        if (g_mister_lua_diag && _visible) ++g_me_draw_anim_tiles;
        const TilePattern& pattern = tile.get_tile_pattern();
        const Tileset* effective_tileset =
            tile.get_tileset() != nullptr ? tile.get_tileset()
                                          : &map.get_tileset();
        const SurfacePtr& tsimg = effective_tileset->get_tiles_image();
        // Parallax patterns (AnimatedTilePattern parallax / ParallaxScrollingTilePattern)
        // are "not drawn at their position": they scroll at camera/ratio (ratio=2). The
        // per-bucket bias supplies the camera term at emit, so split buckets by scroll ratio.
        const bool _parallax = !pattern.is_drawn_at_its_position();
        const int _ratio = _parallax ? ParallaxScrollingTilePattern::ratio : 1;
        const Point dst_position(tile.get_top_left_x() - vp.x,
                                 tile.get_top_left_y() - vp.y);
        Rectangle src;
        Point dst;
        // Batchable patterns (Simple/Animated -> get_draw_region true) map each cell
        // to one (src,dst). A REPEATED/FILL tile (tile larger than its pattern) tiles
        // the same pattern frame across cells, so we EXPAND it into per-cell entries
        // (src constant, dst stepped) instead of falling back to per-tile tile.draw() —
        // that tail was the dominant emit cost. Cap by remaining TL_BUF room (minus the
        // open bucket); a tile whose cells don't fit is a resident hard failure (Task 7:
        // no per-tile oracle — resident_escape logs + latches res_fatal, no silent replay).
        const int _pw = pattern.get_width(), _ph = pattern.get_height();
        const bool _batchable = _pw > 0 && _ph > 0 &&
            pattern.get_draw_region(dst_position, *effective_tileset, src, dst);
        // BUILD stores MAP coords (camera-independent base = tile map position); disabled
        // (rmode==0) computes screen coords, though nothing consumes them (moot).
        const Point _base = (rmode == 1)
            ? Point(tile.get_top_left_x(), tile.get_top_left_y())
            : dst;
        const int _ncx = _batchable ? (tile.get_width()  + _pw - 1) / _pw : 0;
        const int _ncy = _batchable ? (tile.get_height() + _ph - 1) / _ph : 0;
        const long _ncells = (long)_ncx * (long)_ncy;
        if (_batchable &&
            _ncells <= (long)(R.resident_room_entries() - (int)cur_entries.size())) {
          if (cur_ts != nullptr &&
              (cur_ts != tsimg.get() || cur_scroll_ratio != _ratio)) flush_bucket();
          cur_ts = tsimg.get();
          cur_ts_sp = tsimg;
          cur_scroll_ratio = _ratio;
          // Token = the (shared) pattern pointer for BOTH animated and static patterns:
          // the fabric needs an FRT slot per distinct pattern (static/parallax = 1 frame).
          for (int _cy = 0; _cy < _ncy; ++_cy)
            for (int _cx = 0; _cx < _ncx; ++_cx) {
              cur_entries.push_back(TileBatchEntry{
                  src, Point(_base.x + _cx * _pw, _base.y + _cy * _ph)});
              cur_tokens.push_back(reinterpret_cast<uintptr_t>(&pattern));
            }
        }
        else {
          flush_bucket();
          if (rmode == 1) R.resident_escape(layer, reinterpret_cast<uintptr_t>(&tile));
          tile.draw(*camera);
        }
      }
      flush_bucket();
    }""")
s=s.replace(old, new, 1)
open(p,"w").write(s)
print("[#52 Task 8, collapsed Task 7] Entities.cpp: resident batched animated-tile loop injected")
PYTB8
fi

# [static tile-list, Task 4] SOLARUS_TILESTATIC: walk non-animated tiles into the renderer's
# static tile-list on the BUILD frame (NonAnimatedRegions::record_static, Task 4 above), emit
# them as the background on FAST frames (before the animated op loop), and stop building/
# blitting the per-cell NonAnimatedRegions cache (draw_on_map()/update()) while the gate is on.
# Default ON, same convention as the other HW-validated mister_flag_default_on gates; an
# explicit SOLARUS_TILESTATIC=0 falls back to the legacy per-cell path unchanged. Four
# guarded edits, all against the code the Task 8 block above already injected/confirmed:
#   (a) Entities.cpp file-scope helper: mister_flag_default_on (Renderer's copy has internal
#       linkage in its own TU, so it isn't reachable here -- same convention, own definition).
#   (b) Entities::update(): gate the per-cell eviction sweep.
#   (c) Entities::draw(): declare _tilestatic once per layer, right after rmode.
#   (d) Entities::draw(): emit static ops before the animated op loop (FAST), record_static()
#       on the BUILD frame, and gate draw_on_map() (both BUILD and FAST/disabled).
ENT9="$SRC/src/entities/Entities.cpp"
if ! grep -q "mister_flag_default_on" "$ENT9"; then
  python3 - "$ENT9" <<'PYTILESTATIC'
import sys
p=sys.argv[1]; s=open(p).read()

# (a) file-scope default-ON flag helper, next to the other small inline helpers up top.
anchor_a = """namespace { inline bool destructible_is_idle(Solarus::Destructible* d) {
  const Solarus::SpritePtr& _sp = d->get_sprite();
  bool _spr = _sp && !_sp->is_paused() && !_sp->is_animation_finished()
           && _sp->get_frame_delay() > 0;
  return solarus_destructible_skippable(
      d->is_suspended()?1:0, d->get_is_being_cut()?1:0,
      d->is_waiting_for_regeneration()?1:0, d->get_is_regenerating()?1:0,
      (d->get_movement()!=nullptr)?1:0, d->has_stream_action()?1:0, _spr?1:0);
} }"""
assert anchor_a in s, "Entities.cpp destructible_is_idle anchor not found"
helper_a = """
// [static tile-list, SOLARUS_TILESTATIC] Same default-ON convention as
// mister_blitter_renderer.cpp's mister_flag_default_on (that one has internal linkage in
// its own TU, so it isn't reachable from here): unset, or any value not starting with '0',
// -> ON; an explicit "=0" opts out.
namespace { inline bool mister_flag_default_on(const char* name) {
  const char* v = std::getenv(name);
  return !(v && v[0] == '0');
} }"""
s = s.replace(anchor_a, anchor_a + helper_a, 1)

# (b) Entities::update(): skip the per-cell eviction sweep when the gate is on (nothing to
# evict -- record_static()/resident_static_op_count replace the cache entirely).
anchor_b = """  for (int layer = map.get_min_layer(); layer <= map.get_max_layer(); ++layer) {
    non_animated_regions[layer]->update();
  }"""
assert anchor_b in s, "Entities.cpp non_animated_regions update() anchor not found"
new_b = """  // [static tile-list] The per-cell optimized_tiles_surfaces cache (lazy build + camera-
  // window eviction) is unused when SOLARUS_TILESTATIC is on -- the whole layer is recorded
  // once into the renderer's static tile-list instead (Entities::draw, BUILD frame). Skip the
  // sweep so it isn't dead work every tick.
  static const bool _tilestatic_upd = mister_flag_default_on("SOLARUS_TILESTATIC");
  if (!_tilestatic_upd) {
    for (int layer = map.get_min_layer(); layer <= map.get_max_layer(); ++layer) {
      non_animated_regions[layer]->update();
    }
  }"""
s = s.replace(anchor_b, new_b, 1)

# (c) Entities::draw(): cache the gate once per layer, right after rmode is computed.
anchor_c = """    const int rmode = R.resident_begin_frame(
        reinterpret_cast<uintptr_t>(&map),
        reinterpret_cast<uintptr_t>(&map.get_tileset()));
    if (rmode == 2) {"""
assert anchor_c in s, "Entities.cpp rmode/resident_begin_frame anchor not found"
new_c = """    const int rmode = R.resident_begin_frame(
        reinterpret_cast<uintptr_t>(&map),
        reinterpret_cast<uintptr_t>(&map.get_tileset()));
    // [static tile-list] Entities.cpp needs its own reachable copy of the default-ON flag
    // reader (see helper above); cached once, reused by the BUILD/FAST branches below.
    static const bool _tilestatic = mister_flag_default_on("SOLARUS_TILESTATIC");
    if (rmode == 2) {"""
s = s.replace(anchor_c, new_c, 1)

# (d) FAST: emit the static background BEFORE the animated op loop. BUILD: record_static()
# after the animated walk. Both (and disabled): gate draw_on_map() off, since the static ops
# (FAST) / record_static() (BUILD) replace the per-cell path it draws.
anchor_d1 = """      const int _nops = R.resident_layer_op_count(layer);
      for (int _oi = 0; _oi < _nops; ++_oi) R.resident_emit_layer_op(layer, _oi);
    }
    else {"""
assert anchor_d1 in s, "Entities.cpp FAST op-loop anchor not found"
new_d1 = """      if (_tilestatic) {
        // [static tile-list] Emitted BEFORE the animated op loop so animated tiles paint on
        // top of this background -- the reverse of the original per-cell order (animated
        // first, then a holed non-animated cell on top); putting static first and letting
        // animated overpaint it gets the same result without per-cell hole-punching.
        const int _nsops = R.resident_static_op_count(layer);
        for (int _si = 0; _si < _nsops; ++_si) R.resident_emit_static_op(layer, _si);
      }
      const int _nops = R.resident_layer_op_count(layer);
      for (int _oi = 0; _oi < _nops; ++_oi) R.resident_emit_layer_op(layer, _oi);
    }
    else {"""
s = s.replace(anchor_d1, new_d1, 1)

anchor_d2 = """      flush_bucket();
    }

    // Draw the non-animated tiles (with transparent rectangles on the regions of animated tiles
    // since they are already drawn).
    non_animated_regions[layer]->draw_on_map();"""
assert anchor_d2 in s, "Entities.cpp flush_bucket()/draw_on_map() anchor not found"
new_d2 = """      flush_bucket();
    }

    // [static tile-list] BUILD frame: walk this layer's non-animated tiles once into the
    // renderer's static bucket store (replaces the per-cell optimized_tiles_surfaces path
    // below). Disabled (rmode==0) records nothing (no legacy draw path to hand entries to).
    if (rmode == 1 && _tilestatic) {
      non_animated_regions[layer]->record_static(R);
    }

    // Draw the non-animated tiles (with transparent rectangles on the regions of animated tiles
    // since they are already drawn). [static tile-list] Skipped when SOLARUS_TILESTATIC is on:
    // the FAST-frame static ops (emitted above, before the animated op loop) and the
    // BUILD-frame record_static() call (just above) replace this per-cell path entirely.
    if (!_tilestatic) {
      non_animated_regions[layer]->draw_on_map();
    }"""
s = s.replace(anchor_d2, new_d2, 1)

open(p, "w").write(s)
print("[static tile-list, Task 4] Entities.cpp: SOLARUS_TILESTATIC walk/emit/suppress wired")
PYTILESTATIC
fi


# [patch-series] Stop after the source-patch phase (text-only, no compile).
# Used by capture_golden.sh and the migration equivalence gate.
if [ "${SOLARUS_PATCH_ONLY:-0}" = "1" ]; then
  echo "[patch-series] SOLARUS_PATCH_ONLY=1 — patched tree ready in $SRC, skipping build."
  exit 0
fi


# 2. Configure. Software-only: no GUI (Qt editor), no tests, GLES off. OpenGL is
#    optional upstream; we still force software rendering at runtime
#    (-force-software-rendering). MISTER_NATIVE_VIDEO enables the DDR present-hook.
#
#    Lua backend (env SOLARUS_USE_LUAJIT, default OFF -> vanilla Lua 5.1):
#      SOLARUS_USE_LUAJIT=1  -> link the armhf LuaJIT built by
#                               scripts/build_luajit.sh (build/luajit-armhf).
#                               Run that script first; we point FindLuaJIT.cmake
#                               at the prefix via LUAJIT_DIR + CMAKE_PREFIX_PATH.
# NOTE: -DCMAKE_C/CXX_FLAGS on the command line REPLACES the toolchain file's
# *_FLAGS_INIT, so the NEON/cpu flags must be repeated here or the software
# renderer compiles without SIMD/A9 scheduling (measured ~free 2x lever).
MISTER_ARCH_FLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"

# --- Optional gprof instrumentation (SOLARUS_GPROF, default OFF) -------------
# SOLARUS_GPROF=1 builds solarus-run + libsolarus with gcc's -pg mcount
# instrumentation so a NORMAL-EXIT run of the engine drops a gmon.out (the
# standard gprof input). Post-process on the host with the matching cross gprof:
#   arm-linux-gnueabihf-gprof build/armhf/solarus-run gmon.out   (scripts/gprof_report.sh)
#
# Rules that this build must satisfy for usable profiles:
#   * -pg must be on BOTH the compile line (CMAKE_*_FLAGS) AND the link line of
#     BOTH the shared library and the run binary (CMAKE_SHARED/EXE_LINKER_FLAGS)
#     — nearly all engine code lives in libsolarus, so instrumenting only the
#     binary would profile almost nothing.
#   * LTO/IPO must be OFF: cross-TU inlining dissolves the function boundaries
#     gprof attributes samples to and can drop mcount calls entirely. We force
#     SOLARUS_LTO=OFF for a gprof build regardless of the caller's setting.
#   * -g keeps the symbol/line info gprof uses for its annotated call graph.
# Default OFF -> an ordinary ship build (no -pg cost, LTO honoured).
GPROF_C_FLAGS=""
GPROF_LINK_FLAGS=""
LTO_SETTING="${SOLARUS_LTO:-ON}"
if [ "${SOLARUS_GPROF:-0}" = "1" ] || [ "${SOLARUS_GPROF:-0}" = "ON" ]; then
  echo "SOLARUS_GPROF=1: building with -pg gprof instrumentation (LTO forced OFF)."
  GPROF_C_FLAGS="-pg -g"
  GPROF_LINK_FLAGS="-pg"
  LTO_SETTING="OFF"
fi

# Default ON (issue #26): LuaJIT is the shipped baseline — HW-validated full JIT on
# the Cortex-A9 (ARMv7/VFPv3), ~20-30% A9 win in gameplay. Requires build/luajit-armhf
# (run scripts/build_luajit.sh first); set SOLARUS_USE_LUAJIT=0 for vanilla Lua 5.1.
USE_LUAJIT="${SOLARUS_USE_LUAJIT:-1}"
LUA_CMAKE_ARGS=()
if [ "$USE_LUAJIT" = "1" ] || [ "$USE_LUAJIT" = "ON" ]; then
  LUAJIT_PREFIX="$(pwd)/build/luajit-armhf"
  if [ ! -f "$LUAJIT_PREFIX/lib/libluajit-5.1.so" ]; then
    echo "ERROR: SOLARUS_USE_LUAJIT set but $LUAJIT_PREFIX not built." >&2
    echo "       Run scripts/build_luajit.sh first." >&2
    exit 1
  fi
  echo "Building engine with LuaJIT from $LUAJIT_PREFIX"
  export LUAJIT_DIR="$LUAJIT_PREFIX"
  LUA_CMAKE_ARGS=(
    -DSOLARUS_USE_LUAJIT=ON
    -DCMAKE_PREFIX_PATH="$LUAJIT_PREFIX"
    -DLUAJIT_INCLUDE_DIR="$LUAJIT_PREFIX/include/luajit-2.1"
    -DLUAJIT_LIBRARY="$LUAJIT_PREFIX/lib/libluajit-5.1.so"
  )
else
  echo "Building engine with vanilla Lua 5.1 (set SOLARUS_USE_LUAJIT=1 for LuaJIT)"
  LUA_CMAKE_ARGS=(-DSOLARUS_USE_LUAJIT=OFF)
fi

cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_TOOLCHAIN_FILE="$(pwd)/cmake/arm-linux-gnueabihf.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS $GPROF_C_FLAGS" \
  -DCMAKE_CXX_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS $GPROF_C_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$GPROF_LINK_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$GPROF_LINK_FLAGS" \
  "${LUA_CMAKE_ARGS[@]}" \
  -DSOLARUS_GUI=OFF \
  -DSOLARUS_TESTS=OFF \
  -DSOLARUS_GL_ES=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_POLICY_DEFAULT_CMP0069=NEW \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$LTO_SETTING"   # (#26) LTO: cross-TU inlining of the template-heavy quadtree/shared_ptr/comparator. CMP0069=NEW forces it (Solarus' old cmake_minimum ignores IPO otherwise). Set SOLARUS_LTO=OFF to disable; SOLARUS_GPROF=1 forces it OFF (gprof needs intact function boundaries).

# 3. Build the engine + run binary.
cmake --build "$BUILD" -j"$(nproc)"

echo ""
echo "Build done. Artifacts under $BUILD/ :"
find "$BUILD" -maxdepth 2 -name 'solarus*' -type f -perm -u+x 2>/dev/null || true
echo ""
echo "Open items to confirm after first build:"
echo "  - Does the binary link libGL/libGLEW? (ldd). If so, ship Mesa libGL armhf"
echo "    from the gmloader work, or patch out GlRenderer. GL is unused at runtime"
echo "    with -force-software-rendering but may be a load-time DT_NEEDED."
echo "  - DDR video hook (patches/) not yet applied — see CLAUDE.md Phase 3."
