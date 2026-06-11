#!/bin/bash
#
# Phase 1: cross-build the Solarus 1.6.5 engine (solarus-run) for MiSTer armhf,
# software rendering only. Runs inside the solarus-armhf-build:bullseye image.
#
# Usage (from repo root):
#   docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
#   docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

SOLARUS_REF="${SOLARUS_REF:-v1.6}"
SRC="work/solarus"
BUILD="${SOLARUS_BUILD_DIR:-build/armhf}"

# 1. Source checkout (engine only; quests are separate).
if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Solarus $SOLARUS_REF..."
  git clone --depth 1 --branch "$SOLARUS_REF" https://gitlab.com/solarus-games/solarus.git "$SRC"
fi

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
  # Pump rendered samples to the DDR ring once per Sound::update().
  edit_inplace "$SND" 's|^  // also update the music|#ifdef MISTER_NATIVE_AUDIO\n  mister_audio_pump(device);\n#endif\n\n  // also update the music|'
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
  static const bool mister_opaque_blits = (std::getenv("SOLARUS_OPAQUE_BLITS") != nullptr);
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
        static const bool mister_opaque_blits = (std::getenv("SOLARUS_OPAQUE_BLITS") != nullptr);
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

USE_LUAJIT="${SOLARUS_USE_LUAJIT:-0}"
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
  -DCMAKE_C_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS" \
  -DCMAKE_CXX_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS" \
  "${LUA_CMAKE_ARGS[@]}" \
  -DSOLARUS_GUI=OFF \
  -DSOLARUS_TESTS=OFF \
  -DSOLARUS_GL_ES=OFF

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
