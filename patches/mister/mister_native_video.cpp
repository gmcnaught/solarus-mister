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
#include <ctime>
#include <vector>

// Monotonic milliseconds for profiling.
static double mister_now_ms() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

// ---- SOLARUS_DRAW_PROF per-frame draw counters ----------------------------
#include <atomic>
static std::atomic<long> s_draw_blits{0};
static std::atomic<long> s_draw_target_switches{0};
static std::atomic<long> s_draw_readpixels{0};

bool mister_draw_prof_enabled() {
  static const bool on = (std::getenv("SOLARUS_DRAW_PROF") != nullptr);
  return on;
}
void mister_draw_count_blit() {
  if (mister_draw_prof_enabled()) s_draw_blits.fetch_add(1, std::memory_order_relaxed);
}
void mister_draw_count_target_switch() {
  if (mister_draw_prof_enabled()) s_draw_target_switches.fetch_add(1, std::memory_order_relaxed);
}
void mister_draw_count_readpixels() {
  if (mister_draw_prof_enabled()) s_draw_readpixels.fetch_add(1, std::memory_order_relaxed);
}
void mister_draw_take_counts(long* blits, long* target_switches, long* readpixels) {
  if (blits)           *blits           = s_draw_blits.exchange(0, std::memory_order_relaxed);
  if (target_switches) *target_switches = s_draw_target_switches.exchange(0, std::memory_order_relaxed);
  if (readpixels)      *readpixels      = s_draw_readpixels.exchange(0, std::memory_order_relaxed);
}

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
  const bool prof = (getenv("SOLARUS_MISTER_PROF") != nullptr);
  double t_read0 = prof ? mister_now_ms() : 0.0;
  mister_draw_count_readpixels();  // final present read-back
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

  // Profiling (SOLARUS_MISTER_PROF=1): every ~1s log measured fps, mean
  // present-to-present period, and the share spent in our readback+DDR copy
  // (vs. Solarus logic+draw, which is the rest of the period).
  if (prof) {
    static double s_last = 0.0, s_acc_period = 0.0, s_acc_our = 0.0;
    static int s_n = 0;
    double t_our = mister_now_ms() - t_read0;   // readback + WriteFrame
    double t_now = mister_now_ms();
    if (s_last > 0.0) {
      s_acc_period += (t_now - s_last);
      s_acc_our += t_our;
      if (++s_n >= 60) {
        double mean_period = s_acc_period / s_n;
        std::fprintf(stderr,
            "[MiSTer prof] fps=%.1f  frame=%.1fms  our_readback+ddr=%.1fms (%.0f%%)  "
            "solarus(logic+draw)=%.1fms\n",
            1000.0 / mean_period, mean_period,
            s_acc_our / s_n, 100.0 * s_acc_our / s_acc_period,
            mean_period - s_acc_our / s_n);
        s_acc_period = 0.0; s_acc_our = 0.0; s_n = 0;
      }
    }
    s_last = t_now;
  }
}

#else  // !MISTER_NATIVE_VIDEO

void mister_present_frame(SDL_Renderer*, SDL_Window*) {}
bool mister_draw_prof_enabled() { return false; }
void mister_draw_count_blit() {}
void mister_draw_count_target_switch() {}
void mister_draw_count_readpixels() {}
void mister_draw_take_counts(long* b, long* t, long* r) { if(b)*b=0; if(t)*t=0; if(r)*r=0; }

#endif
