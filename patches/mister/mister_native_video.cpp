//
//  MiSTer native-video glue for Solarus (task 003). See header.
//
#include "mister_native_video.h"

#ifdef MISTER_NATIVE_VIDEO

#include "native_video_writer.h"
#include <SDL_render.h>
#include <SDL_video.h>
#include <SDL_pixels.h>
#include <cstdint>
#include <cstdio>
#include <vector>

static bool s_init_tried = false;
static bool s_active = false;
static std::vector<uint16_t> s_buf;   // RGB565 scratch
static int s_warned_size = 0;

void mister_present_frame(SDL_Renderer* renderer, SDL_Window* window) {
  if (!renderer) {
    return;
  }
  if (!s_init_tried) {
    s_init_tried = true;
    s_active = NativeVideoWriter_Init();
    std::fprintf(stderr, "[MiSTer] NativeVideoWriter_Init -> %s\n",
                 s_active ? "OK" : "FAILED");
    // Solarus opens a 2x desktop window (640x480). Force the native FPGA size:
    // resize the window to 320x240 and keep logical size matched, so the
    // software renderer's output equals the DDR buffer. MiSTer's own scaler
    // upscales for display. (window is passed from SDLRenderer::present, so we
    // avoid SDL_RenderGetWindow which is absent in the build's SDL 2.0.14 headers.)
    if (window) {
      SDL_SetWindowSize(window, 320, 240);
    }
    SDL_RenderSetLogicalSize(renderer, 320, 240);
  }
  if (!s_active) {
    return;
  }

  int w = 0, h = 0;
  if (SDL_GetRendererOutputSize(renderer, &w, &h) != 0) {
    return;
  }
  // NativeVideoWriter only accepts the FPGA's 320x240 buffer.
  if (w != 320 || h != 240) {
    if (s_warned_size++ == 0) {
      std::fprintf(stderr,
          "[MiSTer] renderer output %dx%d != 320x240; skipping DDR write\n", w, h);
    }
    return;
  }

  if (s_buf.size() < static_cast<size_t>(w * h)) {
    s_buf.resize(static_cast<size_t>(w * h));
  }
  // Read the just-rendered frame straight into RGB565 (read BEFORE present;
  // a window backbuffer may be invalid after SDL_RenderPresent).
  if (SDL_RenderReadPixels(renderer, nullptr, SDL_PIXELFORMAT_RGB565,
                           s_buf.data(), w * 2) != 0) {
    return;
  }
  NativeVideoWriter_WriteFrame(s_buf.data(), w, h, w * 2);
}

#else  // !MISTER_NATIVE_VIDEO

void mister_present_frame(SDL_Renderer*, SDL_Window*) {}

#endif
