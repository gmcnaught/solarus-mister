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
# Public-header copy so it can be included via the solarus/... path.
cp patches/mister/mister_blitter_renderer.h   "$SRC/include/solarus/graphics/sdlrenderer/"
mkdir -p "$MDST/blitter"
cp patches/mister/blitter/*.h patches/mister/blitter/*.c "$MDST/blitter/"

# Register the renderer + emitter TUs with the engine library source list (once).
if ! grep -q "mister_blitter_renderer.cpp" "$SRCLIST"; then
  edit_inplace "$SRCLIST" 's#\("\${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/SDLRenderer.cpp"\)#\1\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/mister_blitter_renderer.cpp"\n    "${CMAKE_CURRENT_SOURCE_DIR}/src/graphics/sdlrenderer/blitter/blt_emitter.c"#'
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
        "                    void mister_set_camera_pos(int, int); void mister_set_paused(bool);\n"
        "                    void mister_set_transition(bool); }\n"
        "#endif\n\n")
anchor_ns = "namespace Solarus {"
assert anchor_ns in s, "namespace Solarus not found in Game.cpp"
i = s.index(anchor_ns)
s = s[:i] + decl + s[i:]
# insert the tag + camera-position calls right after the camera surface is obtained
old = "      const SurfacePtr& camera_surface = camera->get_surface();\n"
new = (old +
       "#ifdef MISTER_NATIVE_VIDEO\n"
       "      Solarus::mister_tag_camera_surface(&camera_surface->get_impl());\n"
       "      { auto _ctl = camera->get_top_left_xy();\n"
       "        Solarus::mister_set_camera_pos(_ctl.x, _ctl.y); }\n"
       "#endif\n")
assert old in s, "Game::draw camera_surface anchor not found"
s = s.replace(old, new, 1)
# [MiSTer #23] set the paused/dialog flag at the TOP of every Game::draw so the
# bg-cache never snapshots a menu/pause/dialog screen as the background (it persists
# after exit otherwise). Runs every frame regardless of the draw branch taken.
draw_anchor = "void Game::draw(const SurfacePtr& dst_surface) {\n"
assert draw_anchor in s, "Game::draw signature anchor not found"
s = s.replace(draw_anchor,
              draw_anchor +
              "#ifdef MISTER_NATIVE_VIDEO\n"
              "  Solarus::mister_set_paused(is_paused() || is_dialog_enabled());\n"
              "  Solarus::mister_set_transition(transition != nullptr);\n"
              "#endif\n", 1)
open(path,"w").write(s)
print("Game.cpp camera-tag + paused-hook patched")
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
  -DCMAKE_C_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS" \
  -DCMAKE_CXX_FLAGS="-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO $MISTER_ARCH_FLAGS" \
  "${LUA_CMAKE_ARGS[@]}" \
  -DSOLARUS_GUI=OFF \
  -DSOLARUS_TESTS=OFF \
  -DSOLARUS_GL_ES=OFF \
  -DCMAKE_POLICY_DEFAULT_CMP0069=NEW \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="${SOLARUS_LTO:-ON}"   # (#26) LTO: cross-TU inlining of the template-heavy quadtree/shared_ptr/comparator. CMP0069=NEW forces it (Solarus' old cmake_minimum ignores IPO otherwise). Set SOLARUS_LTO=OFF to disable.

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
