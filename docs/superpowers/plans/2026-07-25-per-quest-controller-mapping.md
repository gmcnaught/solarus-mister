# Per-Quest Controller Mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MiSTer controller work on every Solarus quest by presenting it as a real SDL virtual joystick and letting a per-quest config decide, for each input independently, whether it is delivered as a joypad event or a keyboard event.

**Architecture:** A pure header-only profile parser (`mister_controls.h`) turns `controls.cfg` into a 12-entry table of targets. The existing input bridge in `mister_native_video.cpp` attaches an SDL virtual joystick and, each frame, drives either that joystick's state or synthesized key events per the table. One input maps to exactly one target, so the double-fire that rules out "emit both" is structurally impossible.

**Tech Stack:** C99 header-only unit (host-tested with `cc`), C++17 engine glue, SDL2 2.28.5 virtual-joystick API, SystemVerilog `CONF_STR` string, Python deploy script, bash launcher.

**Spec:** `docs/superpowers/specs/2026-07-25-per-quest-controller-mapping-design.md`

## Deviations From The Spec

Three deliberate changes, made while planning. Each is a simplification, not a scope cut in disguise.

1. **No separate `mister_input.{cpp,h}`.** The spec proposed a new translation unit for the SDL side. A new `.cpp` would have to be added to the CMake source list, which lives inside `patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch` — editing a series patch for a few dozen lines of glue is a poor trade. The SDL side goes into `patches/mister/mister_native_video.cpp` instead, which is already the input bridge and already in the build. Only the pure, testable half (`mister_controls.h`) becomes a new file, and it is header-only.

2. **The M1/M2 milestone split is collapsed.** The spec staged the engine work ahead of the `CONF_STR` edit so the RBF could lag. That split does not survive contact: `start` sits at bit `0x800` in the eight-button layout but there is no fifth-button slot for it in the five-button core, so an M1-only build would need a *second* bit-mapping mode purely to be thrown away. Since the `CONF_STR` change is a two-line string edit and `deploy.py` ships engine and RBF together regardless, Task 6 lands before hardware validation and there is no intermediate state. If you genuinely need an engine-only drop, `l`, `r`, `select` and `start` simply never fire.

3. **No `write_dir` fallback for quest identity.** The spec wanted `SOLARUS_QUEST_ID`, then the quest's `write_dir` from `quest.dat`, then `[default]`. Reading `write_dir` means pulling Solarus quest headers into low-level DDR/SDL glue that currently includes none. The launcher always sets the env var, so the fallback would only serve manual launches — which can set `SOLARUS_QUEST_ID` themselves. Chain is therefore: env var, then `[default]`. If a manual-launch case turns up that needs it, add it then.

## Global Constraints

- **Header-only, no CMake edits.** `mister_controls.h` must be header-only and C-compatible (`static inline`), matching the existing `mister_overlay_id.h` / `fps_overlay.h` pattern. Adding a new `.cpp` translation unit would require editing the CMake source list inside `patches/series/0001-feat-mister-DDR-video-audio-hooks-blitter-renderer-p.patch` — avoid that entirely.
- **Whole-file copies, not series patches.** Everything under `patches/mister/` is a whole-file copy applied by `scripts/apply_mister_files.sh`. Edit those files DIRECTLY. Do not regenerate any patch in `patches/series/`.
- **`mister_poll_input()` keeps its name and signature** (`void mister_poll_input()`, declared in `patches/mister/mister_native_video.h:15`). Its only caller lives inside series patch 0022 (`patches/series/0022-perf-entities-cache-entities_to_draw-across-frames-d.patch:2616`). Changing the signature would force a series edit.
- **Renderer type-check requires both defines.** Any `-fsyntax-only` check MUST pass `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`. Nearly all of the implementation sits inside `#ifdef MISTER_NATIVE_VIDEO`; omitting them type-checks almost nothing and prints success on a file with hard errors. This has already produced one falsely-passing verification on this branch.
- **Axis levels must be full-scale ±32767.** Solarus's default `joypad_deadzone` is 10000 (`work/solarus/src/core/InputEvent.cpp:41`, applied at `:486`). Anything smaller is silently swallowed.
- **Hat direction constants must equal SDL's**: `MC_HAT_UP=0x01`, `MC_HAT_RIGHT=0x02`, `MC_HAT_DOWN=0x04`, `MC_HAT_LEFT=0x08` — identical to `SDL_HAT_UP/RIGHT/DOWN/LEFT`, so values pass straight through with no translation.
- **Input index == FPGA bit index.** `joystick_0` bit 0 = Right, 1 = Left, 2 = Down, 3 = Up, then buttons from bit 4 in `CONF_STR J1` entry order. The `mc_input_t` enum MUST be ordered to match so `mc_bit(i) == (1u << i)`.
- **Never self-declare a frame visually correct.** Visual outcomes require the operator's confirmation or a bit-exact objective test. This rule was learned the hard way on this project (see `MEMORY.md`).
- **Config parse failures never abort the engine.** Missing file, unknown section, malformed line, unknown key name → log a warning and fall back; the game still launches.

---

### Task 1: Profile parser (`mister_controls.h`)

Pure, header-only, no SDL and no hardware. This is the whole testable core of the feature.

**Files:**
- Create: `patches/mister/mister_controls.h`
- Create: `tests/controls_test.c`
- Modify: `tests/run_tests.sh` (append a test block before the final `echo "All host tests passed."` at line 180)

**Interfaces:**
- Consumes: nothing.
- Produces, relied on by Tasks 2, 4 and 5:
  - `typedef enum { MC_NONE=0, MC_BUTTON, MC_AXIS, MC_HAT, MC_KEY } mc_kind_t;`
  - `typedef struct { mc_kind_t kind; int v0, v1; char key[MC_KEYNAME_MAX]; } mc_target_t;`
  - `typedef struct { mc_target_t t[MC_IN_COUNT]; char section[MC_SECTION_MAX]; int warnings; } mc_profile_t;`
  - `static inline unsigned mc_bit(int input);`
  - `static inline void mc_defaults(mc_profile_t* p);`
  - `static inline void mc_load(const char* text, const char* quest_id, mc_profile_t* out);`
  - `static const char* const mc_input_names[MC_IN_COUNT];`
  - Enum constants `MC_IN_RIGHT=0, MC_IN_LEFT, MC_IN_DOWN, MC_IN_UP, MC_IN_A, MC_IN_B, MC_IN_X, MC_IN_Y, MC_IN_L, MC_IN_R, MC_IN_SELECT, MC_IN_START`, and `MC_IN_COUNT=12`.

**Parsing semantics to implement (fixed contract — Task 2's tests depend on it):**
1. Start from the built-in defaults (`mc_defaults`).
2. Apply the `[default]` section from the text, if present.
3. Apply the `[<quest_id>]` section on top, if present. Later assignment wins, so a quest section only needs to state its differences.
4. Comments start with `;` and run to end of line. `\r` is stripped (CRLF-tolerant — the SD card is FAT).
5. A malformed line inside a section being applied increments `warnings`. Lines in sections NOT being applied are ignored silently — otherwise the `[default]` pass would warn about every quest-section line.

- [ ] **Step 1: Write the failing test**

Create `tests/controls_test.c`:

```c
/* Host unit test for the per-quest controller mapping parser. cc-compatible. */
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "../patches/mister/mister_controls.h"

static const char* CFG =
  "; a comment line\n"
  "[default]\n"
  "up    = axis 1 -\n"
  "down  = axis 1 +\n"
  "a     = button 0   ; action\n"
  "start = button 4\n"
  "\n"
  "[keyquest]\n"
  "up    = key up\n"
  "a     = key space\n"
  "start = none\n"
  "\n"
  "[hatquest]\n"
  "up    = hat up\n"
  "left  = hat left\n"
  "\n"
  "[bad]\n"
  "nosuchinput = button 1\n"
  "a           = button banana\n"
  "b\n";

int main(void) {
  mc_profile_t p;

  /* 1. Built-in defaults match stock Solarus joypad layout (Savegame.cpp:191). */
  mc_defaults(&p);
  assert(p.t[MC_IN_RIGHT].kind == MC_AXIS  && p.t[MC_IN_RIGHT].v0 == 0 && p.t[MC_IN_RIGHT].v1 == 1);
  assert(p.t[MC_IN_LEFT ].kind == MC_AXIS  && p.t[MC_IN_LEFT ].v0 == 0 && p.t[MC_IN_LEFT ].v1 == -1);
  assert(p.t[MC_IN_UP   ].kind == MC_AXIS  && p.t[MC_IN_UP   ].v0 == 1 && p.t[MC_IN_UP   ].v1 == -1);
  assert(p.t[MC_IN_DOWN ].kind == MC_AXIS  && p.t[MC_IN_DOWN ].v0 == 1 && p.t[MC_IN_DOWN ].v1 == 1);
  assert(p.t[MC_IN_A].kind == MC_BUTTON && p.t[MC_IN_A].v0 == 0);
  assert(p.t[MC_IN_B].kind == MC_BUTTON && p.t[MC_IN_B].v0 == 1);
  assert(p.t[MC_IN_Y].kind == MC_BUTTON && p.t[MC_IN_Y].v0 == 2);
  assert(p.t[MC_IN_X].kind == MC_BUTTON && p.t[MC_IN_X].v0 == 3);
  assert(p.t[MC_IN_START].kind == MC_BUTTON && p.t[MC_IN_START].v0 == 4);

  /* 2. Input index == FPGA joystick_0 bit index. */
  assert(mc_bit(MC_IN_RIGHT) == 0x001u);
  assert(mc_bit(MC_IN_UP)    == 0x008u);
  assert(mc_bit(MC_IN_A)     == 0x010u);
  assert(mc_bit(MC_IN_START) == 0x800u);

  /* 3. Unknown quest id -> [default] section applied, section name "default". */
  mc_load(CFG, "no-such-quest", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.t[MC_IN_A].kind == MC_BUTTON && p.t[MC_IN_A].v0 == 0);
  assert(p.warnings == 0);

  /* 4. Quest section overrides [default] per input; unstated inputs inherit. */
  mc_load(CFG, "keyquest", &p);
  assert(!strcmp(p.section, "keyquest"));
  assert(p.t[MC_IN_UP].kind == MC_KEY && !strcmp(p.t[MC_IN_UP].key, "up"));
  assert(p.t[MC_IN_A ].kind == MC_KEY && !strcmp(p.t[MC_IN_A ].key, "space"));
  assert(p.t[MC_IN_START].kind == MC_NONE);
  assert(p.t[MC_IN_DOWN].kind == MC_AXIS);   /* inherited from [default] */
  assert(p.warnings == 0);

  /* 5. Hat targets parse to SDL-identical direction codes. */
  mc_load(CFG, "hatquest", &p);
  assert(p.t[MC_IN_UP  ].kind == MC_HAT && p.t[MC_IN_UP  ].v1 == MC_HAT_UP);
  assert(p.t[MC_IN_LEFT].kind == MC_HAT && p.t[MC_IN_LEFT].v1 == MC_HAT_LEFT);
  assert(MC_HAT_UP == 0x01 && MC_HAT_RIGHT == 0x02);
  assert(MC_HAT_DOWN == 0x04 && MC_HAT_LEFT == 0x08);

  /* 6. Malformed lines are counted, never fatal; good lines still applied. */
  mc_load(CFG, "bad", &p);
  assert(p.warnings == 3);                    /* unknown input, bad value, no '=' */
  assert(p.t[MC_IN_A].kind == MC_BUTTON && p.t[MC_IN_A].v0 == 0);  /* unchanged */

  /* 7. NULL text -> built-in defaults, no crash. */
  mc_load(NULL, "anything", &p);
  assert(p.t[MC_IN_A].kind == MC_BUTTON && p.t[MC_IN_A].v0 == 0);

  /* 8. CRLF tolerance (the SD card is FAT). */
  mc_load("[q]\r\na = button 6\r\n", "q", &p);
  assert(p.t[MC_IN_A].kind == MC_BUTTON && p.t[MC_IN_A].v0 == 6);
  assert(p.warnings == 0);

  /* 9. Comment-only and blank lines are not warnings. */
  mc_load("[q]\n; just a comment\n\n   \n", "q", &p);
  assert(p.warnings == 0);

  printf("controls_test: OK\n");
  return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cc -Wall -Wextra -O2 tests/controls_test.c -o /tmp/controls_test
```
Expected: FAIL — `fatal error: '../patches/mister/mister_controls.h' file not found`.

- [ ] **Step 3: Write the implementation**

Create `patches/mister/mister_controls.h`:

```c
/*
 * Per-quest controller mapping — pure, header-only, C-compatible.
 *
 * The MiSTer pad reaches the A9 as a bitmask in DDR3 (NativeVideoWriter_ReadJoystick).
 * Quests disagree about what input they accept: Mystery of Solarus DX uses stock
 * GameCommands keyboard defaults, Patched Tunics runs its own raw-input layer that
 * while Patched Tunics runs its own raw-input layer whose on_key_pressed swallows every
 * key it does not own (lib/bindings.lua + zentropy.lua:730) — only joypad events reach
 * it. No single fixed mapping works.
 *
 * Emitting BOTH a key and a joypad event per press is not an option either:
 * GameCommands::game_command_pressed (work/solarus/src/core/GameCommands.cpp:487) calls
 * game.notify_command_pressed() with no duplicate guard, so every command would fire twice.
 *
 * So this unit resolves each MiSTer input to EXACTLY ONE target — a joypad button/axis/hat
 * or a keyboard key — read from controls.cfg. One input, one target: double-fire is
 * structurally impossible.
 *
 * Pure by design: no SDL, no DDR, no engine types, so tests/controls_test.c exercises it
 * on the host with plain cc.
 */
#ifndef MISTER_CONTROLS_H
#define MISTER_CONTROLS_H

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define MC_IN_COUNT     12
#define MC_KEYNAME_MAX  24
#define MC_SECTION_MAX  64

typedef enum {
  MC_NONE = 0,   /* input does nothing                                   */
  MC_BUTTON,     /* v0 = button index                                    */
  MC_AXIS,       /* v0 = axis index, v1 = +1 or -1                       */
  MC_HAT,        /* v0 = hat index (always 0), v1 = MC_HAT_* direction   */
  MC_KEY         /* key[] = SDL key name, resolved by the caller         */
} mc_kind_t;

/* Deliberately identical to SDL_HAT_UP/RIGHT/DOWN/LEFT so values pass straight through. */
#define MC_HAT_UP     0x01
#define MC_HAT_RIGHT  0x02
#define MC_HAT_DOWN   0x04
#define MC_HAT_LEFT   0x08

/* Input index == FPGA joystick_0 bit index: bits 0-3 are the D-pad, buttons start at
 * bit 4 in CONF_STR J1 entry order. Do not reorder. */
enum {
  MC_IN_RIGHT = 0, MC_IN_LEFT = 1, MC_IN_DOWN = 2, MC_IN_UP = 3,
  MC_IN_A = 4, MC_IN_B = 5, MC_IN_X = 6, MC_IN_Y = 7,
  MC_IN_L = 8, MC_IN_R = 9, MC_IN_SELECT = 10, MC_IN_START = 11
};

typedef struct {
  mc_kind_t kind;
  int v0, v1;
  char key[MC_KEYNAME_MAX];
} mc_target_t;

typedef struct {
  mc_target_t t[MC_IN_COUNT];
  char section[MC_SECTION_MAX];  /* section actually applied ("default" if no quest match) */
  int warnings;                  /* malformed lines seen in applied sections               */
} mc_profile_t;

static const char* const mc_input_names[MC_IN_COUNT] = {
  "right", "left", "down", "up",
  "a", "b", "x", "y",
  "l", "r", "select", "start"
};

static inline unsigned mc_bit(int input) { return 1u << input; }

static inline const char* mc_skip_ws(const char* s) {
  while (*s == ' ' || *s == '\t') s++;
  return s;
}

static inline void mc_set(mc_profile_t* p, int in, mc_kind_t k,
                          int v0, int v1, const char* key) {
  p->t[in].kind = k;
  p->t[in].v0 = v0;
  p->t[in].v1 = v1;
  p->t[in].key[0] = '\0';
  if (key) {
    size_t n = strlen(key);
    if (n >= MC_KEYNAME_MAX) n = MC_KEYNAME_MAX - 1;
    memcpy(p->t[in].key, key, n);
    p->t[in].key[n] = '\0';
  }
}

/* Built-in fallback == stock Solarus joypad defaults (Savegame.cpp:191), so any
 * unauthored quest using stock GameCommands works with no profile written. */
static inline void mc_defaults(mc_profile_t* p) {
  memset(p, 0, sizeof *p);
  mc_set(p, MC_IN_RIGHT, MC_AXIS, 0,  1, NULL);
  mc_set(p, MC_IN_LEFT,  MC_AXIS, 0, -1, NULL);
  mc_set(p, MC_IN_DOWN,  MC_AXIS, 1,  1, NULL);
  mc_set(p, MC_IN_UP,    MC_AXIS, 1, -1, NULL);
  mc_set(p, MC_IN_A,      MC_BUTTON, 0, 0, NULL);  /* action */
  mc_set(p, MC_IN_B,      MC_BUTTON, 1, 0, NULL);  /* attack */
  mc_set(p, MC_IN_Y,      MC_BUTTON, 2, 0, NULL);  /* item_1 */
  mc_set(p, MC_IN_X,      MC_BUTTON, 3, 0, NULL);  /* item_2 */
  mc_set(p, MC_IN_START,  MC_BUTTON, 4, 0, NULL);  /* pause  */
  mc_set(p, MC_IN_L,      MC_BUTTON, 5, 0, NULL);
  mc_set(p, MC_IN_R,      MC_BUTTON, 6, 0, NULL);
  mc_set(p, MC_IN_SELECT, MC_BUTTON, 7, 0, NULL);
  memcpy(p->section, "default", 8);
}

static inline int mc_input_index(const char* name, size_t len) {
  int i;
  for (i = 0; i < MC_IN_COUNT; i++) {
    if (strlen(mc_input_names[i]) == len && !strncmp(mc_input_names[i], name, len)) {
      return i;
    }
  }
  return -1;
}

/* Parse the right-hand side of a mapping line. Returns 1 on success, 0 if malformed. */
static inline int mc_parse_target(const char* s, mc_target_t* out) {
  memset(out, 0, sizeof *out);
  s = mc_skip_ws(s);

  if (!strncmp(s, "none", 4)) {
    out->kind = MC_NONE;
    return 1;
  }
  if (!strncmp(s, "button", 6)) {
    char* end;
    long n = strtol(s + 6, &end, 10);
    if (end == s + 6 || n < 0 || n > 31) return 0;
    out->kind = MC_BUTTON;
    out->v0 = (int)n;
    return 1;
  }
  if (!strncmp(s, "axis", 4)) {
    char* end;
    const char* p;
    long n = strtol(s + 4, &end, 10);
    if (end == s + 4 || n < 0 || n > 7) return 0;
    p = mc_skip_ws(end);
    if (*p == '+')      out->v1 =  1;
    else if (*p == '-') out->v1 = -1;
    else                return 0;
    out->kind = MC_AXIS;
    out->v0 = (int)n;
    return 1;
  }
  if (!strncmp(s, "hat", 3)) {
    const char* p = mc_skip_ws(s + 3);
    if      (!strncmp(p, "up",    2)) out->v1 = MC_HAT_UP;
    else if (!strncmp(p, "down",  4)) out->v1 = MC_HAT_DOWN;
    else if (!strncmp(p, "left",  4)) out->v1 = MC_HAT_LEFT;
    else if (!strncmp(p, "right", 5)) out->v1 = MC_HAT_RIGHT;
    else return 0;
    out->kind = MC_HAT;
    out->v0 = 0;
    return 1;
  }
  if (!strncmp(s, "key", 3)) {
    const char* p = mc_skip_ws(s + 3);
    size_t n = strlen(p);
    while (n && (p[n - 1] == ' ' || p[n - 1] == '\t')) n--;
    if (n == 0 || n >= MC_KEYNAME_MAX) return 0;
    memcpy(out->key, p, n);
    out->key[n] = '\0';
    out->kind = MC_KEY;
    return 1;
  }
  return 0;
}

/* Apply every mapping line of section `want`. Sets *found when the section exists. */
static inline void mc_apply(const char* text, const char* want,
                            mc_profile_t* p, int* found) {
  const char* s = text;
  int in_section = 0;

  while (*s) {
    const char* eol = strchr(s, '\n');
    size_t len = eol ? (size_t)(eol - s) : strlen(s);
    char line[256];
    char* cut;
    const char* t;
    size_t n = len < sizeof(line) - 1 ? len : sizeof(line) - 1;

    memcpy(line, s, n);
    line[n] = '\0';

    cut = strchr(line, ';');            /* comment to end of line */
    if (cut) *cut = '\0';
    cut = strchr(line, '\r');           /* CRLF tolerance (FAT) */
    if (cut) *cut = '\0';

    t = mc_skip_ws(line);

    if (*t == '[') {
      const char* close = strchr(t, ']');
      if (close) {
        char cur[MC_SECTION_MAX];
        size_t sn = (size_t)(close - t - 1);
        if (sn >= MC_SECTION_MAX) sn = MC_SECTION_MAX - 1;
        memcpy(cur, t + 1, sn);
        cur[sn] = '\0';
        in_section = !strcmp(cur, want);
        if (in_section && found) *found = 1;
      }
    } else if (*t && in_section) {
      const char* eq = strchr(t, '=');
      if (!eq) {
        p->warnings++;
      } else {
        size_t kn = (size_t)(eq - t);
        int idx;
        mc_target_t tgt;
        while (kn && (t[kn - 1] == ' ' || t[kn - 1] == '\t')) kn--;
        idx = mc_input_index(t, kn);
        if (idx < 0 || !mc_parse_target(eq + 1, &tgt)) {
          p->warnings++;
        } else {
          p->t[idx] = tgt;
        }
      }
    }
    /* Lines outside the wanted section are ignored WITHOUT warning: the [default]
     * pass would otherwise warn about every quest-section line. */

    if (!eol) break;
    s = eol + 1;
  }
}

/* Resolve the profile for `quest_id` from `text` (the whole controls.cfg, or NULL).
 * Layering: built-in defaults, then [default], then [<quest_id>]. */
static inline void mc_load(const char* text, const char* quest_id, mc_profile_t* out) {
  mc_defaults(out);
  if (!text) return;

  mc_apply(text, "default", out, NULL);

  if (quest_id && *quest_id) {
    int found = 0;
    mc_apply(text, quest_id, out, &found);
    if (found) {
      size_t n = strlen(quest_id);
      if (n >= MC_SECTION_MAX) n = MC_SECTION_MAX - 1;
      memcpy(out->section, quest_id, n);
      out->section[n] = '\0';
    }
  }
}

#endif /* MISTER_CONTROLS_H */
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cc -Wall -Wextra -O2 tests/controls_test.c -o /tmp/controls_test && /tmp/controls_test
```
Expected: no warnings, and `controls_test: OK`.

- [ ] **Step 5: Wire into the host suite**

In `tests/run_tests.sh`, insert immediately BEFORE the final line `echo "All host tests passed."`:

```bash
echo "== controls (per-quest controller mapping parser) =="
$CC -Wall -Wextra -O2 \
    tests/controls_test.c \
    -o /tmp/controls_test
/tmp/controls_test
```

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.` and includes the `== controls ... ==` block.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_controls.h tests/controls_test.c tests/run_tests.sh
git commit -m "feat(controls): per-quest controller mapping parser

Header-only, SDL-free profile parser: resolves each MiSTer input to exactly
one target (joypad button/axis/hat OR keyboard key). One input, one target,
so the double-fire from GameCommands.cpp:487 having no duplicate guard is
structurally impossible. Built-in fallback mirrors stock Solarus joypad
defaults (Savegame.cpp:191)."
```

---

### Task 2: The shipped profiles

The profiles are data, and a typo in them should fail CI rather than the operator's evening.

**Files:**
- Create: `games/Solarus/controls.cfg.default`
- Create: `tests/controls_profiles_test.c`
- Modify: `tests/run_tests.sh` (append a block after the Task 1 block)

**Interfaces:**
- Consumes: `mc_load`, `mc_profile_t`, `mc_target_t`, the `MC_IN_*` and `MC_*` kind constants from Task 1.
- Produces: `games/Solarus/controls.cfg.default`, shipped by Task 5's `deploy.py` change.

- [ ] **Step 1: Write the failing test**

Create `tests/controls_profiles_test.c`. It reads the real shipped file, so the file and the assertions can never drift:

```c
/* Asserts the SHIPPED controls.cfg.default resolves to the intended tables. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "../patches/mister/mister_controls.h"

static char* slurp(const char* path) {
  long n;
  char* buf;
  FILE* f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
  fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
  buf = (char*)malloc((size_t)n + 1);
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "short read\n"); exit(1); }
  buf[n] = '\0';
  fclose(f);
  return buf;
}

static void want_button(const mc_profile_t* p, int in, int b) {
  assert(p->t[in].kind == MC_BUTTON && p->t[in].v0 == b);
}
static void want_axis(const mc_profile_t* p, int in, int a, int sign) {
  assert(p->t[in].kind == MC_AXIS && p->t[in].v0 == a && p->t[in].v1 == sign);
}
static void want_key(const mc_profile_t* p, int in, const char* k) {
  assert(p->t[in].kind == MC_KEY && !strcmp(p->t[in].key, k));
}

int main(void) {
  char* cfg = slurp("games/Solarus/controls.cfg.default");
  mc_profile_t p;

  /* [default] — stock Solarus joypad layout, so unauthored quests just work. */
  mc_load(cfg, "unknown-quest", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.warnings == 0);
  want_axis(&p, MC_IN_RIGHT, 0,  1);
  want_axis(&p, MC_IN_LEFT,  0, -1);
  want_axis(&p, MC_IN_DOWN,  1,  1);
  want_axis(&p, MC_IN_UP,    1, -1);
  want_button(&p, MC_IN_A, 0);
  want_button(&p, MC_IN_B, 1);
  want_button(&p, MC_IN_Y, 2);
  want_button(&p, MC_IN_X, 3);
  want_button(&p, MC_IN_START, 4);

  /* [mystery_of_solarus_dx] — byte-for-byte today's hardcoded key table, so MoSDX
   * is a zero-regression gate: any behaviour change means the bridge itself broke. */
  mc_load(cfg, "mystery_of_solarus_dx", &p);
  assert(!strcmp(p.section, "mystery_of_solarus_dx"));
  assert(p.warnings == 0);
  want_key(&p, MC_IN_RIGHT, "right");
  want_key(&p, MC_IN_LEFT,  "left");
  want_key(&p, MC_IN_DOWN,  "down");
  want_key(&p, MC_IN_UP,    "up");
  want_key(&p, MC_IN_B, "c");        /* attack */
  want_key(&p, MC_IN_A, "space");    /* action */
  want_key(&p, MC_IN_Y, "x");        /* item_1 */
  want_key(&p, MC_IN_X, "v");        /* item_2 */
  want_key(&p, MC_IN_START, "d");    /* pause  */
  assert(p.t[MC_IN_L].kind == MC_NONE);
  assert(p.t[MC_IN_R].kind == MC_NONE);
  assert(p.t[MC_IN_SELECT].kind == MC_NONE);

  /* [patched-tunics-b007e656] — all joypad, PT's own numbering from lib/bindings.lua.
   * Axes, never a hat: bindings.mixin defines on_joypad_axis_moved and NO hat handler. */
  mc_load(cfg, "patched-tunics-b007e656", &p);
  assert(!strcmp(p.section, "patched-tunics-b007e656"));
  assert(p.warnings == 0);
  want_axis(&p, MC_IN_RIGHT, 0,  1);
  want_axis(&p, MC_IN_LEFT,  0, -1);
  want_axis(&p, MC_IN_DOWN,  1,  1);
  want_axis(&p, MC_IN_UP,    1, -1);
  want_button(&p, MC_IN_B, 0);       /* attack    */
  want_button(&p, MC_IN_A, 1);       /* action    */
  want_button(&p, MC_IN_L, 2);       /* map       */
  want_button(&p, MC_IN_R, 3);       /* inventory */
  want_button(&p, MC_IN_Y, 4);       /* item_1    */
  want_button(&p, MC_IN_X, 5);       /* item_2    */
  want_button(&p, MC_IN_START, 6);   /* escape    */
  assert(p.t[MC_IN_SELECT].kind == MC_NONE);
  /* No PT input may be a hat — PT has no on_joypad_hat_moved handler. */
  {
    int i;
    for (i = 0; i < MC_IN_COUNT; i++) assert(p.t[i].kind != MC_HAT);
  }

  /* [zelda-roth-se-v1.2.1] — no section of its own: ROTH uses stock GameCommands joypad
   * bindings for gameplay, and its menus (including savegames.lua, via the
   * gui_designer:map_joypad_to_keyboard mixin) accept joypad input fine. It falls through
   * to [default] end to end — assert that fall-through actually happens. */
  mc_load(cfg, "zelda-roth-se-v1.2.1", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.warnings == 0);
  want_axis(&p, MC_IN_RIGHT, 0,  1);
  want_axis(&p, MC_IN_LEFT,  0, -1);
  want_axis(&p, MC_IN_DOWN,  1,  1);
  want_axis(&p, MC_IN_UP,    1, -1);
  want_button(&p, MC_IN_A, 0);       /* action */
  want_button(&p, MC_IN_B, 1);       /* attack */
  want_button(&p, MC_IN_Y, 2);       /* item_1 */
  want_button(&p, MC_IN_X, 3);       /* item_2 */
  want_button(&p, MC_IN_START, 4);   /* pause  */
  want_button(&p, MC_IN_L, 5);
  want_button(&p, MC_IN_R, 6);
  want_button(&p, MC_IN_SELECT, 7);

  free(cfg);
  printf("controls_profiles_test: OK\n");
  return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
cc -Wall -Wextra -O2 tests/controls_profiles_test.c -o /tmp/controls_profiles_test && /tmp/controls_profiles_test
```
Expected: FAIL — `cannot open games/Solarus/controls.cfg.default`.

- [ ] **Step 3: Write the shipped config**

Create `games/Solarus/controls.cfg.default`:

```ini
; Solarus for MiSTer — per-quest controller mapping.
;
; Quests disagree about what input they accept, so one fixed mapping cannot work:
;   * Mystery of Solarus DX uses stock Solarus GameCommands keyboard defaults.
;   * Patched Tunics runs its OWN raw-input layer (lib/bindings.lua, mixed into the
;     game itself at zentropy.lua:730) whose on_key_pressed swallows every key it
;     does not own — only joypad events reach it.
;   * Zelda ROTH SE uses stock GameCommands for gameplay, and its menus (including the
;     save-file menu, savegames.lua:336) accept joypad input via the
;     gui_designer:map_joypad_to_keyboard mixin (lib/gui_designer.lua:235-276), which
;     forwards any joypad button to the confirm key and joypad axes/hats to the
;     direction keys. [default] already mirrors stock joypad GameCommands, so ROTH
;     needs no section of its own — it falls through to [default] end to end, and
;     going all-joypad lets ROTH's own pause_commands.lua remap menu rebind every
;     input in game.
;
; Each MiSTer input therefore resolves to EXACTLY ONE target. Never map one input to
; both a key and a button: GameCommands has no duplicate guard, so the command fires
; twice.
;
; Syntax:
;   <input> = button N | axis N + | axis N - | hat up|down|left|right | key <name> | none
;
;   inputs : right left down up a b x y l r select start
;   layers : built-in defaults, then [default], then [<quest-id>] (later wins, so a
;            quest section need only state its differences)
;   quest-id = the .sol filename without extension, e.g. patched-tunics-b007e656
;   comments start with ';'
;
; Edit this file on the SD card and relaunch the quest — no rebuild needed.

[default]
; Stock Solarus joypad defaults (Savegame.cpp set_default_joypad_controls), so any
; quest we have not profiled still works if it uses stock GameCommands.
right  = axis 0 +
left   = axis 0 -
down   = axis 1 +
up     = axis 1 -
a      = button 0        ; action
b      = button 1        ; attack
y      = button 2        ; item_1
x      = button 3        ; item_2
start  = button 4        ; pause
l      = button 5        ; spare — remappable inside quests that offer it
r      = button 6        ; spare
select = button 7        ; spare

[mystery_of_solarus_dx]
; Deliberately identical to the pre-2026-07-25 hardcoded bridge table. MoSDX is the
; quest the whole port was validated against, so keeping it on the known-good path
; makes it a regression gate.
right  = key right
left   = key left
down   = key down
up     = key up
b      = key c           ; attack
a      = key space       ; action
y      = key x           ; item_1
x      = key v           ; item_2
start  = key d           ; pause
l      = none
r      = none
select = none

[patched-tunics-b007e656]
; PT's own button numbering from lib/bindings.lua. Directions MUST be axes: the mixin
; defines on_joypad_axis_moved and has no on_joypad_hat_moved.
right  = axis 0 +
left   = axis 0 -
down   = axis 1 +
up     = axis 1 -
b      = button 0        ; attack
a      = button 1        ; action
l      = button 2        ; map
r      = button 3        ; inventory
y      = button 4        ; item_1
x      = button 5        ; item_2
start  = button 6        ; escape / save menu
select = none

; Zelda ROTH SE (zelda-roth-se-v1.2.1) has no section here on purpose: it uses stock
; GameCommands joypad bindings for gameplay, and its menus accept joypad input via
; the map_joypad_to_keyboard mixin (see the top-of-file note) — so [default] already
; covers it end to end.
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
cc -Wall -Wextra -O2 tests/controls_profiles_test.c -o /tmp/controls_profiles_test && /tmp/controls_profiles_test
```
Expected: `controls_profiles_test: OK`.

Note the test opens a repo-relative path, and `tests/run_tests.sh` already does `cd "$(dirname "$0")/.."` at line 4, so it runs from the repo root.

- [ ] **Step 5: Wire into the host suite**

In `tests/run_tests.sh`, insert immediately after the `== controls ... ==` block added in Task 1:

```bash
echo "== controls_profiles (shipped controls.cfg.default resolves as intended) =="
$CC -Wall -Wextra -O2 \
    tests/controls_profiles_test.c \
    -o /tmp/controls_profiles_test
/tmp/controls_profiles_test
```

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`

- [ ] **Step 7: Commit**

```bash
git add games/Solarus/controls.cfg.default tests/controls_profiles_test.c tests/run_tests.sh
git commit -m "feat(controls): shipped profiles for the three quests

[default] mirrors stock Solarus joypad bindings. MoSDX keeps today's exact
key table as a zero-regression gate. Patched Tunics goes all-joypad with axis
directions (its mixin has no hat handler). ROTH gets no section of its own:
it uses stock GameCommands joypad bindings for gameplay, and its menus accept
joypad via the map_joypad_to_keyboard mixin, so [default] covers it end to
end. Test reads the shipped file so they cannot drift."
```

---

### Task 3: Virtual-joystick capability probe

**Do not rebuild SDL2 before this task says to.** The spec assumed a rebuild was needed; investigation showed otherwise, and rebuilding blind carries a real cost.

**Background — read before acting.** `scripts/build_sdl2.sh:60` passes `--disable-joystick-virtual`, but the installed config (`work/sdl2-prefix/include/SDL2/SDL_config.h:336`) has `#define SDL_JOYSTICK_VIRTUAL 1`, and line 333 has `SDL_JOYSTICK_HIDAPI 1` despite `--disable-hidapi`. Two disable flags with no effect on a lib whose mtime (Jun 11 16:02) matches the day those flags were added: the shipped SDL2 almost certainly predates them. Practical consequences:
- Virtual joystick support is probably ALREADY compiled into the deployed `libSDL2-2.0.so.0`, so no rebuild is needed.
- A fresh rebuild would newly apply the previously-ignored disables (hidapi, haptic, sensor, power), changing the shipped lib well beyond this feature and putting the HW-validated 29-lib runtime closure at risk.

So: probe first, rebuild only if the probe fails.

**Files:**
- Create: `/tmp/vjoy_probe.c` (scratch, not committed)
- Modify (only if the probe fails): `scripts/build_sdl2.sh:60`

**Interfaces:**
- Consumes: nothing.
- Produces: a decision recorded in the commit message — "virtual joystick available, no SDL2 rebuild" or "rebuilt SDL2".

- [ ] **Step 1: Write the probe**

Create `/tmp/vjoy_probe.c`:

```c
/* Probes whether the runtime SDL2 supports virtual joysticks, and lists any
 * physical joysticks that would compete with ours for Solarus's single slot. */
#include <stdio.h>
#include <SDL.h>

int main(void) {
  int idx, i, n;
  SDL_VirtualJoystickDesc desc;

  if (SDL_Init(SDL_INIT_JOYSTICK) != 0) {
    printf("PROBE: SDL_Init(JOYSTICK) failed: %s\n", SDL_GetError());
    return 1;
  }

  n = SDL_NumJoysticks();
  printf("PROBE: physical joysticks before attach = %d\n", n);
  for (i = 0; i < n; i++) {
    printf("PROBE:   [%d] %s\n", i, SDL_JoystickNameForIndex(i));
  }

  SDL_zero(desc);
  desc.version  = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
  desc.type     = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
  desc.naxes    = 2;
  desc.nbuttons = 8;
  desc.nhats    = 1;
  desc.name     = "MiSTer Controller";

  idx = SDL_JoystickAttachVirtualEx(&desc);
  if (idx < 0) {
    printf("PROBE: VIRTUAL JOYSTICK UNSUPPORTED: %s\n", SDL_GetError());
    SDL_Quit();
    return 2;
  }
  printf("PROBE: virtual joystick attached at index %d, total now %d\n",
         idx, SDL_NumJoysticks());
  printf("PROBE: name at that index = %s\n", SDL_JoystickNameForIndex(idx));
  printf("PROBE: VIRTUAL JOYSTICK SUPPORTED\n");

  SDL_JoystickDetachVirtual(idx);
  SDL_Quit();
  return 0;
}
```

- [ ] **Step 2: Cross-compile it for armhf against the shipped SDL2**

Run:
```bash
docker run --rm -v "$PWD":/src -w /src solarus-armhf-build:bullseye \
  arm-linux-gnueabihf-gcc -O2 /tmp/vjoy_probe.c \
    -I work/sdl2-prefix/include/SDL2 \
    -L work/sdl2-prefix/lib -lSDL2 \
    -o /tmp/vjoy_probe_arm
```

If `/tmp/vjoy_probe.c` is not visible inside the container, copy it into the repo first (`cp /tmp/vjoy_probe.c ./vjoy_probe.c`, adjust the path, and `rm` it before committing).

Expected: an armhf ELF at `/tmp/vjoy_probe_arm`.

- [ ] **Step 3: Run it on the device**

Run:
```bash
scp /tmp/vjoy_probe_arm root@192.168.20.81:/tmp/vjoy_probe
ssh root@192.168.20.81 'cd /media/fat/games/Solarus && \
  SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH=/media/fat/games/Solarus/libs:. \
  /tmp/vjoy_probe'
```

Expected: either `PROBE: VIRTUAL JOYSTICK SUPPORTED` or `PROBE: VIRTUAL JOYSTICK UNSUPPORTED: <reason>`.

**Record the physical-joystick lines too** — they answer the enumeration-race risk from the spec. Solarus binds to the FIRST joystick it sees (`work/solarus/src/core/InputEvent.cpp:316`, `if (joystick == nullptr)`). If `physical joysticks before attach = 0`, there is no race and no mitigation is needed. If it is non-zero, Task 4 Step 7 covers it.

- [ ] **Step 4: Branch on the result**

**If SUPPORTED (expected):** change nothing in the build. Skip to Step 6.

**If UNSUPPORTED:** edit `scripts/build_sdl2.sh:60`, changing `--disable-joystick-virtual` to `--enable-joystick-virtual`, then run `bash scripts/build_sdl2.sh` and verify:
```bash
grep -n "SDL_JOYSTICK_VIRTUAL" work/sdl2-prefix/include/SDL2/SDL_config.h
```
Expected: `#define SDL_JOYSTICK_VIRTUAL 1`.

Then re-run Steps 2–3 to confirm the probe now reports SUPPORTED, and **re-verify the runtime lib closure before shipping** — the rebuild will newly apply `--disable-hidapi`, `--disable-haptic`, `--disable-sensor` and `--disable-power`, so `DT_NEEDED` may shrink:
```bash
docker run --rm -v "$PWD":/src -w /src solarus-armhf-build:bullseye \
  arm-linux-gnueabihf-readelf -d work/sdl2-prefix/lib/libSDL2-2.0.so.0 | grep NEEDED
```
Compare against `deploy/libs/` and drop or add libs so the closure still resolves.

- [ ] **Step 5: Clean up the scratch probe**

Run: `rm -f ./vjoy_probe.c` (only if you copied it into the repo in Step 2)
Then: `git status --short` — expected: no stray `vjoy_probe.c`.

- [ ] **Step 6: Commit the decision**

If nothing changed, record the finding in an empty commit so the next session does not repeat the investigation:

```bash
git commit --allow-empty -m "chore(controls): SDL2 virtual-joystick capability probed on HW

Deployed libSDL2 reports VIRTUAL JOYSTICK SUPPORTED, so no SDL2 rebuild is
needed: build_sdl2.sh's --disable-joystick-virtual never took effect on the
shipped lib (SDL_config.h:336 has it =1, and :333 has HIDAPI=1 despite
--disable-hidapi). Rebuilding would newly apply those disables and perturb
the HW-validated 29-lib closure for no benefit.

Physical joysticks visible to SDL on device: <N> — see plan Task 3 Step 3."
```

If SDL2 was rebuilt instead:

```bash
git add scripts/build_sdl2.sh
git commit -m "build(sdl2): enable virtual joystick driver

The MiSTer pad is presented to Solarus as an SDL virtual joystick, which needs
SDL_JOYSTICK_VIRTUAL. Runtime lib closure re-verified after the rebuild."
```

---

### Task 4: Virtual joystick + per-input emission

Replaces the hardcoded keymap in the input bridge. This is the only engine file that changes.

**Files:**
- Modify: `patches/mister/mister_native_video.cpp` — replace `k_mister_keymap` (lines 56–73), `s_prev_joy` (line 74) and the body of `mister_poll_input()` (lines 128–150)
- Reference: `patches/mister/mister_native_video.h:15` (`mister_poll_input` declaration — do NOT change it)

**Interfaces:**
- Consumes: `mc_profile_t`, `mc_load`, `mc_bit`, `mc_input_names`, `MC_IN_*`, `MC_NONE/BUTTON/AXIS/HAT/KEY`, `MC_HAT_*` from Task 1; `games/Solarus/controls.cfg.default` from Task 2 (deployed as `controls.cfg` by Task 5).
- Produces: no new public symbols. `mister_poll_input()` keeps its exact existing signature so series patch 0022's callsite is untouched.

**Critical design point — axes and hats are STATE-based, not edge-based.** Two inputs share one axis (`left = axis 0 -`, `right = axis 0 +`) and four share one hat. Emitting per edge would let releasing `left` zero an axis that `right` is still holding. So recompute every axis, hat and button from the full joystick word each frame; only keyboard targets are edge-driven (a key held down must not re-post `SDL_KEYDOWN` every frame). Summing `+1` and `-1` also makes left+right cancel to neutral, matching Solarus's own `masks_to_directions8` treating left+right as stop (`GameCommands.cpp:62`).

- [ ] **Step 1a: Add the two new includes**

In `patches/mister/mister_native_video.cpp`, in the existing include block (lines 8–19, inside `#ifdef MISTER_NATIVE_VIDEO`), add after `#include <SDL_keycode.h>`:

```cpp
#include <SDL_joystick.h>
#include "mister_controls.h"
```

- [ ] **Step 1b: Replace the keymap block with profile state**

In `patches/mister/mister_native_video.cpp`, replace lines 56–74 (the `--- MiSTer controller -> SDL keyboard bridge ---` comment, `MisterKeyMap`, `k_mister_keymap` and `static uint32_t s_prev_joy = 0;`) with:

```cpp
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
```

- [ ] **Step 2: Add profile load and virtual-joystick attach**

Immediately after `mister_push_key()` (which ends at line 126 of the original file), add:

```cpp
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
```

- [ ] **Step 3: Replace the poll body**

Replace the body of `mister_poll_input()` (original lines 128–150) with:

```cpp
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
```

- [ ] **Step 4: Confirm the include set**

`mister_slurp` needs `FILE`/`fopen` from `<cstdio>`, `getenv`/`malloc`/`free` from `<cstdlib>`, `SDL_GetKeyFromName` from `<SDL_keyboard.h>` and `SDLK_UNKNOWN` from `<SDL_keycode.h>` — all four were already present (lines 13–14, 16–17). Step 1a added the two new ones.

Run: `grep -n "#include" patches/mister/mister_native_video.cpp | head -20`
Expected: the list contains `<cstdio>`, `<cstdlib>`, `<SDL_keyboard.h>`, `<SDL_keycode.h>`, `<SDL_joystick.h>` and `"mister_controls.h"`.

- [ ] **Step 5: Type-check natively**

Run (both `-D` flags are MANDATORY — see Global Constraints):
```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_native_video.cpp
```
Expected: no output (success).

If the host SDL2 is older than 2.0.14 it will not have `SDL_VirtualJoystickDesc`; in that case rely on the armhf build in Step 6 and note it.

- [ ] **Step 6: Build the engine for armhf**

Run: `bash scripts/build_engine.sh`
Expected: build completes; `build/armhf/solarus-run` and `build/armhf/libsolarus.so.1.6.5` are refreshed.

- [ ] **Step 7: Handle the enumeration race, only if Task 3 saw physical joysticks**

If Task 3 Step 3 reported `physical joysticks before attach = 0`, skip this step entirely — there is no race.

If it reported a non-zero count, Solarus may bind to a physical device instead of ours. Add a series patch making `InputEvent` prefer our device.

In `work/solarus/src/core/InputEvent.cpp`, replace the `SDL_JOYDEVICEADDED` branch (lines 314–324) with:

```cpp
    else if (internal_event.type == SDL_JOYDEVICEADDED) {
      if (joypad_enabled) {
        // [MiSTer] The MiSTer pad is presented as a virtual joystick named
        // "MiSTer Controller". Physical /dev/input devices may enumerate first and
        // claim the single joystick slot, leaving our device invisible to the polling
        // APIs below. So our device wins: it opens even if another is already open.
        const int which = internal_event.jdevice.which;
        const char* added_name = SDL_JoystickNameForIndex(which);
        const bool is_mister =
            (added_name != nullptr && std::string(added_name) == "MiSTer Controller");
        if (joystick == nullptr || is_mister) {
          if (joystick != nullptr) {
            SDL_JoystickClose(joystick);
            joystick = nullptr;
          }
          joystick = SDL_JoystickOpen(which);
          if (joystick == nullptr) {
            Logger::error("Failed to open joystick");
          } else {
            const char* joystick_name = SDL_JoystickName(joystick);
            Logger::info("Using joystick: '" + std::string(joystick_name ? joystick_name : "") + "'");
          }
        }
      }
    }
```

Then regenerate the series patch per the project's normal flow, re-run `bash scripts/build_engine.sh`, and re-run `bash tests/run_tests.sh`.

Note the behavior change beyond preference: the original only opened when `joystick == nullptr`, so it never replaced a live device. The version above closes the incumbent when ours arrives. That is intended — on MiSTer, physical pads are owned by Main_MiSTer and forwarded to the FPGA, so a directly-opened physical device would be a duplicate input path, not a second player.

- [ ] **Step 8: Run the host suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`

- [ ] **Step 9: Commit**

```bash
git add patches/mister/mister_native_video.cpp
git commit -m "feat(controls): drive an SDL virtual joystick from the MiSTer pad

Replaces the hardcoded 9-entry keyboard table with per-input resolution
through the quest profile. Attaches a virtual SDL_Joystick (2 axes, 8 buttons,
1 hat) so Solarus's polling APIs work, not just events.

Axes/hats/buttons are recomputed from the full joystick word each frame, never
per edge: two inputs share an axis and four share a hat, so an edge update
would let releasing one zero a target the other still holds. Keyboard targets
stay edge-driven so a held key does not re-post KEYDOWN. Axis levels are full
scale because Solarus's default deadzone is 10000.

Logs the resolved profile at startup plus any physical joysticks present;
SOLARUS_INPUTDBG=1 traces every bit edge and the target it emitted."
```

---

### Task 5: Launcher and packaging wiring

Without this the engine cannot identify the quest and the config never reaches the device. Both traps below have bitten this project before.

**Files:**
- Modify: `games/Solarus/solarus_run.sh` (after the quest resolve block, around line 110)
- Modify: `scripts/apply_mister_files.sh` (renderer/video copy block, after line 20)
- Modify: `deploy.py` (`game_scripts` list at line 119; upload section after the diag.env block ending at line 186)

**Interfaces:**
- Consumes: `games/Solarus/controls.cfg.default` from Task 2; `SOLARUS_QUEST_ID` / `SOLARUS_CONTROLS` env vars read by Task 4.
- Produces: `SOLARUS_QUEST_ID` exported to the engine; `controls.cfg` present on the device; `mister_controls.h` present in the engine source tree at build time.

- [ ] **Step 1: Export the quest id from the launcher**

In `games/Solarus/solarus_run.sh`, immediately after the line `QUEST="$RUNDIR"` (line 118), add:

```bash
# [controls] Per-quest controller mapping. The engine resolves its section of
# controls.cfg from this id — the .sol basename without extension. Without it the
# engine falls back to the quest's write_dir and then to [default].
SOLARUS_QUEST_ID="$(basename "$QUEST_SOL")"
SOLARUS_QUEST_ID="${SOLARUS_QUEST_ID%.*}"
export SOLARUS_QUEST_ID
echo "Solarus: quest id for controls.cfg: $SOLARUS_QUEST_ID"
```

- [ ] **Step 2: Verify the id derivation**

Run:
```bash
bash -c 'QUEST_SOL=/media/fat/games/Solarus/quests/patched-tunics-b007e656.sol
i="$(basename "$QUEST_SOL")"; echo "${i%.*}"'
```
Expected: `patched-tunics-b007e656` — matching the section name in `controls.cfg.default`.

- [ ] **Step 3: Copy the new header into the engine tree**

In `scripts/apply_mister_files.sh`, after the `cp patches/mister/mister_overlay_id.h "$MDST/"` line (line 20), add:

```bash
cp patches/mister/mister_controls.h        "$MDST/"   # [controls] per-quest input mapping
```

This is the exact class of omission that recurred with `mister_pace.h` in PR #149: a new `patches/mister/` file that never reaches the build.

- [ ] **Step 4: Verify the copy list covers every new file**

Run:
```bash
for f in mister_controls.h; do
  grep -q "patches/mister/$f" scripts/apply_mister_files.sh \
    && echo "OK   $f" || echo "MISSING $f"
done
```
Expected: `OK   mister_controls.h`

- [ ] **Step 5: Ship the config without clobbering user edits**

In `deploy.py`, extend the `game_scripts` list at line 119 to include the config, and add a ship-if-absent step.

First, change:
```python
    game_scripts = [REPO / "games/Solarus" / n for n in (
        "solarus_run.sh", "quest_manager.sh", "quest_lib.sh", "core_watch.sh",
        "solarus_daemon.sh")]
```
to:
```python
    game_scripts = [REPO / "games/Solarus" / n for n in (
        "solarus_run.sh", "quest_manager.sh", "quest_lib.sh", "core_watch.sh",
        "solarus_daemon.sh")]
    # [controls] Per-quest controller mapping. Shipped as .default and copied to
    # controls.cfg only when absent, so a user's edits survive redeploys.
    controls_default = REPO / "games/Solarus" / "controls.cfg.default"
```

Then extend the existence check at line 123 from:
```python
    for p in (binary, handler, launcher, *game_scripts):
```
to:
```python
    for p in (binary, handler, launcher, controls_default, *game_scripts):
```

Then, immediately after the diag.env `else:` branch that ends with
`ssh(host, f"rm -f {GAMEDIR}/diag.env", check=False)` (line 186), add:

```python
    # [controls] Always refresh the reference copy; only seed controls.cfg when the
    # device has none, so hand-edits on the SD card survive a redeploy.
    print("\n-- Uploading controls.cfg.default (per-quest controller mapping) --")
    scp_verified(host, controls_default, f"{GAMEDIR}/controls.cfg.default")
    ssh(host, f"[ -f {GAMEDIR}/controls.cfg ] || cp {GAMEDIR}/controls.cfg.default "
              f"{GAMEDIR}/controls.cfg", check=False)
    ssh(host, f"echo 'controls.cfg on device:'; head -1 {GAMEDIR}/controls.cfg", check=False)
```

- [ ] **Step 6: Verify deploy.py still parses**

Run: `python3 -c "import ast,sys; ast.parse(open('deploy.py').read()); print('deploy.py OK')"`
Expected: `deploy.py OK`

- [ ] **Step 7: Run the host suite**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.` (this suite includes `resolve_quest_test.sh`, which covers the launcher helper the new export sits next to).

- [ ] **Step 8: Commit**

```bash
git add games/Solarus/solarus_run.sh scripts/apply_mister_files.sh deploy.py
git commit -m "feat(controls): wire quest id, header copy and config packaging

solarus_run.sh exports SOLARUS_QUEST_ID (the .sol basename) so the engine can
pick its controls.cfg section. apply_mister_files.sh copies mister_controls.h
into the engine tree — the omission class that recurred with mister_pace.h in
PR #149. deploy.py ships controls.cfg.default every time but seeds controls.cfg
only when absent, so SD-card edits survive redeploys."
```

---

### Task 6: Extend the OSD button list to eight

Five buttons cannot reach Patched Tunics' seven actions however good the profile is. This is the only RBF change, and it is a two-line string edit: `fpga/rtl/openbor_video_reader.sv:574` already writes the full 32-bit `joystick_0` to DDR3 (`ddr_din <= {32'd0, joystick_0}`), so buttons 6–8 reach the A9 with no datapath work.

**Files:**
- Modify: `fpga/Solarus.sv:267-268`
- Modify: `docs/deploy-recipe.md` (add the migration note)

**Interfaces:**
- Consumes: the `MC_IN_*` bit order from Task 1 (`a`=`0x010` … `start`=`0x800`).
- Produces: `joystick_0` bits `0x010`–`0x800` carrying A, B, X, Y, L, R, Select, Start in that order.

- [ ] **Step 1: Edit the CONF_STR**

In `fpga/Solarus.sv`, replace lines 267–268:

```systemverilog
	"J1,Sword,Action,Item 1,Item 2,Pause;",
	"jn,A,B,X,Y,Start;",
```

with:

```systemverilog
	// [controls] Quest-neutral button names: the OSD "Define buttons" screen describes
	// the PHYSICAL pad, and games/Solarus/controls.cfg assigns per-quest meaning. Eight
	// entries because Patched Tunics has seven distinct actions (attack, action, map,
	// inventory, item_1, item_2, escape) and five slots cannot reach them.
	// Bit order (joystick_0): 0x010=A 0x020=B 0x040=X 0x080=Y 0x100=L 0x200=R
	// 0x400=Select 0x800=Start — must stay in step with mc_input_names in
	// patches/mister/mister_controls.h.
	"J1,A,B,X,Y,L,R,Select,Start;",
	"jn,A,B,X,Y,L,R,Select,Start;",
```

- [ ] **Step 2: Verify the edit**

Run: `grep -n "J1,\|jn," fpga/Solarus.sv`
Expected: exactly one `J1,A,B,X,Y,L,R,Select,Start;` and one `jn,A,B,X,Y,L,R,Select,Start;`.

- [ ] **Step 3: Document the migration**

Append to `docs/deploy-recipe.md`:

```markdown
## Controller mapping (2026-07-25)

The core's OSD button list changed from five quest-specific names
(`Sword, Action, Item 1, Item 2, Pause`) to eight quest-neutral ones
(`A, B, X, Y, L, R, Select, Start`). Per-quest meaning now lives in
`/media/fat/games/Solarus/controls.cfg`, which you can edit on the SD card — no
rebuild needed.

**One-time step after installing this core:** the rename invalidates any existing
`Solarus_input.map` in `/media/fat/config`. Open the OSD and re-run **Define buttons**
once. Until you do, buttons will appear mismapped.

`controls.cfg` is seeded from `controls.cfg.default` only if it does not already exist,
so your edits survive a redeploy. To start over, delete `controls.cfg` and redeploy.
```

- [ ] **Step 4: Build the RBF**

Run: `bash fpga/build_solarus.sh`

Expected: a new dated RBF (the current ship is `Solarus_20260723.rbf`; `deploy.py` selects the RBF by the convention documented in its own comments and in `scripts/Solarus.sh` — keep them in step).

Review the timing report as usual. This edit changes only a parameter string fed to `hps_io`, so slack should be essentially unchanged; if it moved materially, investigate before shipping rather than assuming noise.

- [ ] **Step 5: Commit**

```bash
git add fpga/Solarus.sv docs/deploy-recipe.md
git commit -m "feat(core): eight quest-neutral OSD buttons

Five slots cannot reach Patched Tunics' seven actions. The OSD now names the
physical pad and controls.cfg assigns per-quest meaning. String-only change:
openbor_video_reader.sv:574 already writes all 32 joystick_0 bits to DDR3, so
buttons 6-8 need no datapath work. Invalidates existing Solarus_input.map —
Define buttons must be re-run once, documented in the deploy recipe."
```

---

### Task 7: Hardware validation

Nothing here may be self-declared correct. Every visual outcome needs the operator's confirmation; the logs supply the objective half.

**Files:**
- Create: `docs/superpowers/2026-07-25-controller-mapping-hw-validation.md`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: the HW validation record referenced by the final PR.

- [ ] **Step 1: Deploy engine + RBF**

Run: `./deploy.py`
Expected: sha1-verified upload of `solarus-run`, libs, `controls.cfg.default`, the RBF, and a printed first line of the device's `controls.cfg`.

- [ ] **Step 2: Re-run Define buttons**

Ask the operator to load the core, open the OSD, and run **Define buttons**, mapping their pad to A, B, X, Y, L, R, Select, Start.

This is a required manual step — the rename in Task 6 invalidates the old map, and every result below is meaningless without it.

- [ ] **Step 3: Capture the startup profile log for each quest**

For each quest, launch detached and capture the log (the detached recipe keeps the engine alive after the ssh session ends):

```bash
ssh root@192.168.20.81 'cd /media/fat/games/Solarus && \
  setsid sh solarus_run.sh > /media/fat/logs/Solarus/controls.log 2>&1 </dev/null &'
sleep 20
ssh root@192.168.20.81 'grep "\[MiSTer input\]" /media/fat/logs/Solarus/controls.log'
```

Expected for Patched Tunics: `section='patched-tunics-b007e656' warnings=0`, a `virtual joystick attached at index N (open=yes)` line, and the twelve resolved-target lines showing `b -> button 0`, `a -> button 1`, `l -> button 2`, `r -> button 3`.

**Record `physical joysticks before attach = N`.** If N is non-zero and input misbehaves, Task 4 Step 7's mitigation is required.

- [ ] **Step 4: MoSDX zero-regression gate**

Its profile is today's exact key table, so any behavioral change means the bridge itself broke, not the profiles.

Ask the operator to confirm, on Mystery of Solarus DX: movement in all eight directions; sword (B); action/confirm (A); item 1 (Y); item 2 (X); pause (Start); and that the save-file menu is navigable.

Objective half: `SOLARUS_INPUTDBG=1` in `diag.env` and confirm the trace shows `b bit 0x020 DOWN -> key c` and friends.

Record PASS/FAIL per item. **A FAIL here blocks everything else.**

- [ ] **Step 5: ROTH — falls through to `[default]`**

Ask the operator to confirm, on Zelda ROTH SE:
1. Save-file select: cursor moves with the D-pad and confirms with A, via `[default]`'s
   all-joypad bindings and ROTH's own `map_joypad_to_keyboard` menu mixin — the case that
   proves ROTH needs no profile of its own.
2. Gameplay: movement, attack (B), item 1 (Y), item 2 (X), pause (Start).
3. Pause → Commands menu: rebind attack to a different joypad button, leave the menu, and confirm the new button attacks. This is the "each quest's own remap menu is the mapping UI" premise, on hardware.

- [ ] **Step 6: PT — all seven actions**

Ask the operator to confirm, on Patched Tunics: movement (axes); attack (B); action (A); **map (L)**; **inventory (R)**; item 1 (Y); item 2 (X); **escape/save menu (Start)**.

The three in bold are unreachable before this change and are the point of the whole task. If any of them fails, capture `SOLARUS_INPUTDBG=1` output for that button before diagnosing.

- [ ] **Step 7: Write the validation record**

Create `docs/superpowers/2026-07-25-controller-mapping-hw-validation.md` containing: the deployed engine and RBF names; the startup `[MiSTer input]` block for each of the three quests; `physical joysticks before attach` and whether the mitigation was needed; the operator's PASS/FAIL per item for Steps 4–6; and any residual issues with the quest and input that triggered them.

State plainly what was NOT covered — for example, quests other than the three on the device are covered only by `[default]` and remain unverified on hardware.

- [ ] **Step 8: Commit**

```bash
git add docs/superpowers/2026-07-25-controller-mapping-hw-validation.md
git commit -m "docs(controls): HW validation record for per-quest mapping

MoSDX zero-regression gate, ROTH file-select plus in-game rebinding, and all
seven Patched Tunics actions including map/inventory/escape, which were
unreachable with the old five-button keyboard bridge."
```

---

## Verification Checklist

Before opening the PR, confirm each of these and paste the actual output — not a claim that it passed:

- [ ] `bash tests/run_tests.sh` ends with `All host tests passed.`
- [ ] The renderer type-check runs clean WITH `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`
- [ ] `bash scripts/build_engine.sh` completes
- [ ] `grep -q "patches/mister/mister_controls.h" scripts/apply_mister_files.sh`
- [ ] `python3 -c "import ast; ast.parse(open('deploy.py').read())"` succeeds
- [ ] `grep -n "J1,\|jn," fpga/Solarus.sv` shows the eight-entry lists
- [ ] The HW validation record exists and carries operator PASS/FAIL, not self-assessment
