//
//  MiSTer native-video glue for Solarus (task 003). See header.
//
#include "mister_native_video.h"

#ifdef MISTER_NATIVE_VIDEO

#include "native_video_writer.h"
#include <SDL_render.h>
#include <SDL_video.h>
#include <SDL_pixels.h>
#include <SDL_events.h>
#include <SDL_keyboard.h>
#include <SDL_keycode.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static bool s_init_tried = false;
static bool s_active = false;
static std::vector<uint16_t> s_buf;   // RGB565 scratch
static int s_warned_size = 0;

// --- MiSTer controller -> SDL keyboard bridge ------------------------------
// The FPGA core writes the P1 joystick bitmask to DDR (NativeVideoWriter_ReadJoystick).
// We edge-detect it each frame and synthesize SDL key events mapped to Solarus's
// default keyboard bindings, so quests are playable with no joypad config.
// MiSTer/OpenBOR bit layout: 0=Right 1=Left 2=Down 3=Up
//   4=B(right) 5=A(bottom) 6=Y(top) 7=X(left) 8=Start
struct MisterKeyMap { uint32_t mask; SDL_Keycode sym; };
static const MisterKeyMap k_mister_keymap[] = {
  { 0x001, SDLK_RIGHT },  // Right
  { 0x002, SDLK_LEFT  },  // Left
  { 0x004, SDLK_DOWN  },  // Down
  { 0x008, SDLK_UP    },  // Up
  { 0x010, SDLK_c     },  // B(right) -> ATTACK (sword)
  { 0x020, SDLK_SPACE },  // A(bottom) -> ACTION (menu confirm)
  { 0x040, SDLK_x     },  // Y(top)   -> ITEM_1
  { 0x080, SDLK_v     },  // X(left)  -> ITEM_2
  { 0x100, SDLK_d     },  // Start    -> PAUSE
};
static uint32_t s_prev_joy = 0;

static void mister_push_key(SDL_Keycode sym, bool down) {
  SDL_Event e;
  SDL_zero(e);
  e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
  e.key.type = e.type;
  e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
  e.key.repeat = 0;
  e.key.keysym.sym = sym;
  e.key.keysym.scancode = SDL_GetScancodeFromKey(sym);
  e.key.keysym.mod = KMOD_NONE;
  SDL_PushEvent(&e);
}

static void mister_poll_input() {
  uint32_t joy = NativeVideoWriter_ReadJoystick(0);
  uint32_t changed = joy ^ s_prev_joy;
  if (changed) {
    for (const MisterKeyMap& m : k_mister_keymap) {
      if (changed & m.mask) {
        mister_push_key(m.sym, (joy & m.mask) != 0);
      }
    }
    s_prev_joy = joy;
  }
}

void mister_present_frame(SDL_Renderer* renderer, SDL_Window* window) {
  if (!renderer) {
    return;
  }
  if (!s_init_tried) {
    s_init_tried = true;
    s_active = NativeVideoWriter_Init();
    std::fprintf(stderr, "[MiSTer] NativeVideoWriter_Init -> %s\n",
                 s_active ? "OK" : "FAILED");
    (void)window;  // geometry is fixed at 320x240 by the 1x "normal" video-mode
                   // patch (initialize_software_video_modes); no resize needed.
  }
  if (!s_active) {
    return;
  }

  // Bridge MiSTer controller -> SDL keyboard every frame (independent of video).
  mister_poll_input();

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

  // Debug: dump one RGB565 frame to a file for offset/format diagnosis.
  // Enable with SOLARUS_MISTER_DUMP=/path. View on host:
  //   ffmpeg -f rawvideo -pixel_format rgb565le -video_size 320x240 -i f.raw out.png
  static int s_frame = 0;
  if (++s_frame == 120) {
    const char* dump = getenv("SOLARUS_MISTER_DUMP");
    if (dump) {
      if (FILE* f = fopen(dump, "wb")) {
        fwrite(s_buf.data(), 1, static_cast<size_t>(w * h * 2), f);
        fclose(f);
        std::fprintf(stderr, "[MiSTer] dumped %dx%d RGB565 frame to %s\n", w, h, dump);
      }
    }
  }

  NativeVideoWriter_WriteFrame(s_buf.data(), w, h, w * 2);
}

#else  // !MISTER_NATIVE_VIDEO

void mister_present_frame(SDL_Renderer*, SDL_Window*) {}

#endif
