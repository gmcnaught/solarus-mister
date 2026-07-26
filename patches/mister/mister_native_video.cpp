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

// --- MiSTer controller -> SDL keyboard bridge ------------------------------
// The FPGA core writes the P1 joystick bitmask to DDR (NativeVideoWriter_ReadJoystick).
// We edge-detect it each frame and synthesize SDL key events.
//
// The keys are per-quest, loaded from controls.cfg, because quests listen for different
// ones: stock GameCommands quests (Mystery of Solarus DX, Zelda ROTH SE) want
// arrows/c/space/x/v/d, while Patched Tunics runs its own input layer (lib/bindings.lua)
// that listens for s/space/a/d/w/tab/escape. The old hardcoded table was the stock set,
// so on PT it reached only movement and action — attack was unreachable and the pause
// button sent PT's item_2 key.
static mc_profile_t s_profile;
static SDL_Keycode  s_keycode[MC_IN_COUNT];   // resolved once at load, not per keypress
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
// 0x010=A 0x020=B 0x040=X 0x080=Y 0x100=L 0x200=R 0x400=Select 0x800=Start).
// Example to enter the intro (attack/confirm = B = 0x020) then walk down:
//   SOLARUS_INPUT_SCRIPT="800:0x020,900:0,1600:0x020,1700:0,2500:0x004"
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

static void mister_load_controls() {
  const char* env_path = std::getenv("SOLARUS_CONTROLS");
  const bool explicit_path = (env_path && *env_path);
  const char* path = explicit_path ? env_path : "controls.cfg";  // cwd is GAMEDIR (solarus_run.sh cd's there)
  char* text = mister_slurp(path);

  // Fallback: if the primary path can't be opened AND the caller didn't explicitly
  // point at one (SOLARUS_CONTROLS unset), try the shipped controls.cfg.default
  // before giving up to the built-in table. Covers a hand-install or any packaging
  // that forgot to seed controls.cfg — without this, quests with quest-private keys
  // (e.g. Patched Tunics) would silently fall back to the stock table and attack
  // would be unreachable again. `path` is reassigned so the log below reports the
  // file actually read, not the one first attempted.
  if (!text && !explicit_path) {
    path = "controls.cfg.default";
    text = mister_slurp(path);
  }

  const char* quest_id = std::getenv("SOLARUS_QUEST_ID");
  mc_load(text, quest_id ? quest_id : "", &s_profile);
  std::free(text);

  for (int i = 0; i < MC_IN_COUNT; i++) {
    s_keycode[i] = SDLK_UNKNOWN;
    if (s_profile.t[i].kind == MC_KEY) {
      s_keycode[i] = SDL_GetKeyFromName(s_profile.t[i].key);
      if (s_keycode[i] == SDLK_UNKNOWN) {
        std::fprintf(stderr, "[MiSTer input] WARNING: unknown key name '%s' for input '%s'"
                             " — that input will do nothing\n",
                     s_profile.t[i].key, mc_input_names[i]);
      }
    }
  }

  std::fprintf(stderr, "[MiSTer input] controls='%s' quest='%s' section='%s' warnings=%d\n",
               path, quest_id ? quest_id : "(unset)", s_profile.section, s_profile.warnings);
  for (int i = 0; i < MC_IN_COUNT; i++) {
    std::fprintf(stderr, "[MiSTer input]   %-6s (bit 0x%03x) -> %s%s\n",
                 mc_input_names[i], mc_bit(i),
                 s_profile.t[i].kind == MC_KEY ? "key " : "none",
                 s_profile.t[i].kind == MC_KEY ? s_profile.t[i].key : "");
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

  for (int i = 0; i < MC_IN_COUNT; i++) {
    if (!(changed & mc_bit(i))) continue;
    const bool down = (joy & mc_bit(i)) != 0;
    if (s_keycode[i] != SDLK_UNKNOWN) {
      mister_push_key(s_keycode[i], down);
    }
    if (mister_inputdbg()) {
      std::fprintf(stderr, "[MiSTer input] %-6s bit 0x%03x %s -> %s%s\n",
                   mc_input_names[i], mc_bit(i), down ? "DOWN" : "UP  ",
                   s_profile.t[i].kind == MC_KEY ? "key " : "none",
                   s_profile.t[i].kind == MC_KEY ? s_profile.t[i].key : "");
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
