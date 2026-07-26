/*
 * Per-quest controller mapping — pure, header-only, C-compatible.
 *
 * The MiSTer pad reaches the A9 as a bitmask in DDR3 (NativeVideoWriter_ReadJoystick).
 * Quests disagree about what input they accept: Mystery of Solarus DX uses stock
 * GameCommands keyboard defaults, Patched Tunics runs its own raw-input layer that
 * swallows every key it does not own (lib/bindings.lua + zentropy.lua:730), and Zelda
 * ROTH SE's save-file menu handles on_key_pressed ONLY. No single fixed mapping works.
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

/* Built-in fallback: the nine directional/face-button defaults (right/left/up/down,
 * a/b/x/y, start) mirror stock Solarus's joypad defaults (Savegame.cpp:191), so any
 * unauthored quest using stock GameCommands works with no profile written. Upstream
 * Solarus defines NO stock joypad binding for L, R, or select; the button 5/6/7
 * assignments below are this project's own spare-button mapping, not from Savegame.cpp. */
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

/* True at end-of-string or plain ASCII whitespace — the only characters allowed to
 * follow a matched keyword so a prefix match ("none" inside "nonetheless", "up" inside
 * "up2", "key" inside "keyboard") cannot be mistaken for the whole token. */
static inline int mc_is_delim(char c) {
  return c == '\0' || c == ' ' || c == '\t';
}

/* Parse the right-hand side of a mapping line. Returns 1 on success, 0 if malformed.
 *
 * Keyword matching uses strncmp() for the prefix plus an mc_is_delim() check on the
 * character immediately following, so a keyword only matches when it is a whole
 * token — "nonetheless" does not match "none", "hat up2" does not match "hat up",
 * and "keyboard" does not match "key" (with "board" misread as the key name).
 *
 * "button" and "axis" don't need an explicit delimiter check: strtol() requires an
 * actual digit right after the keyword (optionally preceded by whitespace), so any
 * non-numeric suffix ("buttonx", "axisfoo") already fails via end == s + prefixlen.
 * This also means "button0"/"axis0" (no space before the digit) are accepted, which
 * is deliberate — there is no keyword that starts "button"/"axis" followed by a
 * digit, so no ambiguity is possible. Likewise "axis 0+" (no space before the sign)
 * is deliberately still accepted: the '+'/'-' is not alphanumeric, so it cannot be
 * confused with a longer keyword either. */
static inline int mc_parse_target(const char* s, mc_target_t* out) {
  memset(out, 0, sizeof *out);
  s = mc_skip_ws(s);

  if (!strncmp(s, "none", 4) && mc_is_delim(s[4])) {
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
  if (!strncmp(s, "hat", 3) && mc_is_delim(s[3])) {
    const char* p = mc_skip_ws(s + 3);
    size_t kw_len;
    if      (!strncmp(p, "up",    2)) { out->v1 = MC_HAT_UP;    kw_len = 2; }
    else if (!strncmp(p, "down",  4)) { out->v1 = MC_HAT_DOWN;  kw_len = 4; }
    else if (!strncmp(p, "left",  4)) { out->v1 = MC_HAT_LEFT;  kw_len = 4; }
    else if (!strncmp(p, "right", 5)) { out->v1 = MC_HAT_RIGHT; kw_len = 5; }
    else return 0;
    if (!mc_is_delim(p[kw_len])) return 0;
    out->kind = MC_HAT;
    out->v0 = 0;
    return 1;
  }
  if (!strncmp(s, "key", 3) && mc_is_delim(s[3])) {
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
