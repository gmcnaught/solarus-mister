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
#include <SDL_joystick.h>
#include <SDL.h>              // SDL_INIT_JOYSTICK / SDL_WasInit / SDL_InitSubSystem
#include "mister_controls.h"
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

// --- MiSTer controller -> SDL input bridge ---------------------------------
// The FPGA core writes the P1 joystick bitmask to DDR (NativeVideoWriter_ReadJoystick).
// Each MiSTer input is resolved through the per-quest profile (controls.cfg) to EXACTLY
// ONE target: a virtual-joypad button/axis/hat, or a synthesized keyboard key.
//
// Why not always emit both: GameCommands::game_command_pressed (GameCommands.cpp:487)
// calls notify_command_pressed() with no duplicate guard, so a key+button pair for one
// physical press fires every command twice.
//
// Why a VIRTUAL joystick rather than hand-pushed SDL_JOYBUTTONDOWN events: a virtual
// device is a real SDL_Joystick, so Solarus's polling APIs work too — is_joypad_button_down
// (InputEvent.cpp:436), get_joypad_axis_state (:477) and get_joypad_hat_direction (:501)
// all return false/0 when InputEvent::joystick is null, which is what pushed events leave.

static mc_profile_t s_profile;
static SDL_Keycode  s_keycode[MC_IN_COUNT];   // resolved once at load, not per press
static SDL_Joystick* s_vjoy = nullptr;
static int          s_vjoy_index = -1;
static uint32_t     s_prev_joy = 0;
static bool         s_controls_loaded = false;

static bool mister_inputdbg() {
  static const bool on = (std::getenv("SOLARUS_INPUTDBG") != nullptr);
  return on;
}

// Read the whole config file. Returns nullptr if absent (caller falls back to defaults).
static char* mister_slurp(const char* path) {
  FILE* f = std::fopen(path, "rb");
  if (!f) return nullptr;
  std::fseek(f, 0, SEEK_END);
  long n = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  if (n < 0 || n > (1 << 20)) { std::fclose(f); return nullptr; }
  char* buf = (char*)std::malloc((size_t)n + 1);
  if (!buf) { std::fclose(f); return nullptr; }
  size_t got = std::fread(buf, 1, (size_t)n, f);
  buf[got] = '\0';
  std::fclose(f);
  return buf;
}

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

static const char* mister_target_str(const mc_target_t& t, char* buf, size_t n) {
  switch (t.kind) {
    case MC_BUTTON: std::snprintf(buf, n, "button %d", t.v0); break;
    case MC_AXIS:   std::snprintf(buf, n, "axis %d %c", t.v0, t.v1 > 0 ? '+' : '-'); break;
    case MC_HAT:    std::snprintf(buf, n, "hat 0x%02x", t.v1); break;
    case MC_KEY:    std::snprintf(buf, n, "key %s", t.key); break;
    default:        std::snprintf(buf, n, "none"); break;
  }
  return buf;
}

static void mister_load_controls() {
  const char* path = std::getenv("SOLARUS_CONTROLS");
  if (!path || !*path) path = "controls.cfg";   // cwd is GAMEDIR (solarus_run.sh cd's there)
  char* text = mister_slurp(path);

  const char* quest_id = std::getenv("SOLARUS_QUEST_ID");
  mc_load(text, quest_id ? quest_id : "", &s_profile);
  std::free(text);

  bool need_joy = false;
  for (int i = 0; i < MC_IN_COUNT; i++) {
    const mc_target_t& t = s_profile.t[i];
    s_keycode[i] = SDLK_UNKNOWN;
    if (t.kind == MC_KEY) {
      s_keycode[i] = SDL_GetKeyFromName(t.key);
      if (s_keycode[i] == SDLK_UNKNOWN) {
        std::fprintf(stderr, "[MiSTer input] WARNING: unknown key name '%s' for input '%s'"
                             " — that input will do nothing\n", t.key, mc_input_names[i]);
      }
    } else if (t.kind != MC_NONE) {
      need_joy = true;
    }
  }

  std::fprintf(stderr, "[MiSTer input] controls.cfg='%s' quest='%s' section='%s' warnings=%d\n",
               path, quest_id ? quest_id : "(unset)", s_profile.section, s_profile.warnings);
  for (int i = 0; i < MC_IN_COUNT; i++) {
    char b[48];
    std::fprintf(stderr, "[MiSTer input]   %-6s (bit 0x%03x) -> %s\n",
                 mc_input_names[i], mc_bit(i),
                 mister_target_str(s_profile.t[i], b, sizeof b));
  }

  if (need_joy) {
    if (!SDL_WasInit(SDL_INIT_JOYSTICK) && SDL_InitSubSystem(SDL_INIT_JOYSTICK) != 0) {
      std::fprintf(stderr, "[MiSTer input] SDL_InitSubSystem(JOYSTICK) failed: %s\n",
                   SDL_GetError());
      return;
    }
    // Enumeration probe: Solarus binds to the FIRST joystick it sees
    // (InputEvent.cpp:316). Log what else is present so a race is visible in the log
    // rather than as mysterious dead input.
    int before = SDL_NumJoysticks();
    std::fprintf(stderr, "[MiSTer input] physical joysticks before attach = %d\n", before);
    for (int i = 0; i < before; i++) {
      std::fprintf(stderr, "[MiSTer input]   [%d] %s\n", i, SDL_JoystickNameForIndex(i));
    }

    SDL_VirtualJoystickDesc desc;
    SDL_zero(desc);
    desc.version  = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type     = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes    = 2;
    desc.nbuttons = 8;
    desc.nhats    = 1;
    desc.name     = "MiSTer Controller";
    s_vjoy_index = SDL_JoystickAttachVirtualEx(&desc);
    if (s_vjoy_index < 0) {
      std::fprintf(stderr, "[MiSTer input] SDL_JoystickAttachVirtualEx failed: %s\n",
                   SDL_GetError());
      return;
    }
    s_vjoy = SDL_JoystickOpen(s_vjoy_index);
    std::fprintf(stderr, "[MiSTer input] virtual joystick attached at index %d (open=%s)\n",
                 s_vjoy_index, s_vjoy ? "yes" : "NO");
  }
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
  if (!s_controls_loaded) {
    s_controls_loaded = true;
    mister_load_controls();
  }

  uint32_t joy = NativeVideoWriter_ReadJoystick(0) | script_joy();
  uint32_t changed = joy ^ s_prev_joy;
  if (!changed) return;

  // Axes, hats and buttons are recomputed from the FULL state, never per edge: two
  // inputs share one axis and four share one hat, so an edge-driven update would let
  // releasing 'left' zero an axis that 'right' is still holding. Summing +1/-1 also
  // makes left+right cancel to neutral, matching masks_to_directions8 (GameCommands.cpp:62).
  int axis_val[2] = { 0, 0 };
  int hat_val = 0;
  uint32_t btn_mask = 0;

  for (int i = 0; i < MC_IN_COUNT; i++) {
    const mc_target_t& t = s_profile.t[i];
    const bool down = (joy & mc_bit(i)) != 0;
    switch (t.kind) {
      case MC_AXIS:
        if (down && t.v0 >= 0 && t.v0 < 2) axis_val[t.v0] += t.v1;
        break;
      case MC_HAT:
        if (down) hat_val |= t.v1;
        break;
      case MC_BUTTON:
        if (down && t.v0 >= 0 && t.v0 < 8) btn_mask |= (1u << t.v0);
        break;
      case MC_KEY:
        // Keyboard targets stay EDGE-driven: a held key must not re-post KEYDOWN.
        if ((changed & mc_bit(i)) && s_keycode[i] != SDLK_UNKNOWN) {
          mister_push_key(s_keycode[i], down);
        }
        break;
      default:
        break;
    }
    if (mister_inputdbg() && (changed & mc_bit(i))) {
      char b[48];
      std::fprintf(stderr, "[MiSTer input] %-6s bit 0x%03x %s -> %s\n",
                   mc_input_names[i], mc_bit(i), down ? "DOWN" : "UP  ",
                   mister_target_str(t, b, sizeof b));
    }
  }

  if (s_vjoy) {
    for (int a = 0; a < 2; a++) {
      // Full scale: Solarus's default joypad_deadzone is 10000 (InputEvent.cpp:41).
      Sint16 v = axis_val[a] > 0 ? 32767 : (axis_val[a] < 0 ? -32767 : 0);
      SDL_JoystickSetVirtualAxis(s_vjoy, a, v);
    }
    SDL_JoystickSetVirtualHat(s_vjoy, 0, (Uint8)hat_val);
    for (int b = 0; b < 8; b++) {
      SDL_JoystickSetVirtualButton(s_vjoy, b, (Uint8)((btn_mask >> b) & 1u));
    }
  }

  s_prev_joy = joy;
}

#else  // !MISTER_NATIVE_VIDEO

void mister_poll_input() {}
bool mister_draw_prof_enabled() { return false; }
void mister_draw_count_blit() {}
void mister_draw_count_target_switch() {}
void mister_draw_count_readpixels() {}
void mister_draw_take_counts(long* b, long* t, long* r) { if(b)*b=0; if(t)*t=0; if(r)*r=0; }

#endif
