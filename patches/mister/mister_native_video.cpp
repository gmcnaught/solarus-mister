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

// ---- SCRIPTED INPUT (SOLARUS_INPUT_SCRIPT) — autonomous test driver --------
// Lets us boot the quest, navigate the intro, and walk the hero WITHOUT a human
// at the controller (so gameplay fps / scroll behaviour can be measured + a
// screenshot validated headlessly). Format: comma-separated "t_ms:mask" steps;
// each step's joystick mask is HELD until the next step's t_ms. Masks use the
// same bit layout as the FPGA joystick (0x001=R 0x002=L 0x004=D 0x008=U
// 0x010=B 0x020=A 0x100=Start). Example to enter the intro then walk down:
//   SOLARUS_INPUT_SCRIPT="800:0x010,900:0,1600:0x010,1700:0,2500:0x004"
// The scripted mask is OR'd onto the real controller, so a human can still play.
struct ScriptStep { double t_ms; uint32_t mask; };
static std::vector<ScriptStep> s_script;
static bool s_script_parsed = false;
static double s_script_t0 = 0.0;
static uint32_t script_joy() {
  if (!s_script_parsed) {
    s_script_parsed = true;
    const char* env = std::getenv("SOLARUS_INPUT_SCRIPT");
    if (env && *env) {
      const char* p = env;
      while (*p) {
        char* end = nullptr;
        double t = std::strtod(p, &end);
        if (end == p) break;
        if (*end != ':') break;
        uint32_t m = (uint32_t)std::strtoul(end + 1, &end, 0);
        s_script.push_back({t, m});
        while (*end == ',' ) end++;
        p = end;
      }
      s_script_t0 = mister_now_ms();
      std::fprintf(stderr, "[MiSTer] input script: %zu steps\n", s_script.size());
    }
  }
  if (s_script.empty()) return 0;
  double el = mister_now_ms() - s_script_t0;
  uint32_t m = 0;
  for (const ScriptStep& s : s_script) if (el >= s.t_ms) m = s.mask;
  return m;
}

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

void mister_poll_input() {
  // Ensure the DDR mapping exists. ReadJoystick needs ddr_base, which is set by
  // NativeVideoWriter_Init(). The blitter offload path submits to the fabric and
  // never does an SDL present, so nothing else calls Init; without this lazy init
  // ReadJoystick would return 0 (its NULL-ddr guard) -> no input.
  if (!s_init_tried) {
    s_init_tried = true;
    s_active = NativeVideoWriter_Init();
    std::fprintf(stderr, "[MiSTer] NativeVideoWriter_Init (from input poll) -> %s\n",
                 s_active ? "OK" : "FAILED");
  }
  uint32_t joy = NativeVideoWriter_ReadJoystick(0) | script_joy();
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

#else  // !MISTER_NATIVE_VIDEO

void mister_poll_input() {}
bool mister_draw_prof_enabled() { return false; }
void mister_draw_count_blit() {}
void mister_draw_count_target_switch() {}
void mister_draw_count_readpixels() {}
void mister_draw_take_counts(long* b, long* t, long* r) { if(b)*b=0; if(t)*t=0; if(r)*r=0; }

#endif
