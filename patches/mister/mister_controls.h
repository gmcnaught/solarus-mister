/*
 * Per-quest controller mapping — pure, header-only, C-compatible.
 *
 * The MiSTer pad reaches the A9 as a bitmask in DDR3 (NativeVideoWriter_ReadJoystick),
 * and is turned into synthesized SDL keyboard events. Quests disagree about which keys
 * they listen for: Mystery of Solarus DX uses stock Solarus GameCommands keyboard
 * defaults outright. Zelda ROTH SE also uses stock GameCommands for its standard
 * commands, but its Lua scripts ADD their own quest-private keyboard commands (save,
 * run, map, ...) that live outside GameCommands and need their own mappings. Patched
 * Tunics runs its own raw-input layer entirely (lib/bindings.lua, mixed into the game
 * itself at zentropy.lua:730) that listens for a completely different set of keys (s,
 * space, a, d, w, tab, escape). No single fixed key table works for all three.
 *
 * So this unit resolves each MiSTer input to EXACTLY ONE target — a keyboard key, or
 * nothing — read from controls.cfg.
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
  MC_KEY         /* key[] = SDL key name, resolved by the caller         */
} mc_kind_t;

/* Input index == FPGA joystick_0 bit index: bits 0-3 are the D-pad, buttons start at
 * bit 4 in CONF_STR J1 entry order. Do not reorder. */
enum {
  MC_IN_RIGHT = 0, MC_IN_LEFT = 1, MC_IN_DOWN = 2, MC_IN_UP = 3,
  MC_IN_A = 4, MC_IN_B = 5, MC_IN_X = 6, MC_IN_Y = 7,
  MC_IN_L = 8, MC_IN_R = 9, MC_IN_SELECT = 10, MC_IN_START = 11
};

typedef struct {
  mc_kind_t kind;
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

static inline void mc_set(mc_profile_t* p, int in, mc_kind_t k, const char* key) {
  p->t[in].kind = k;
  p->t[in].key[0] = '\0';
  if (key) {
    size_t n = strlen(key);
    if (n >= MC_KEYNAME_MAX) n = MC_KEYNAME_MAX - 1;
    memcpy(p->t[in].key, key, n);
    p->t[in].key[n] = '\0';
  }
}

/* Built-in fallback == stock Solarus keyboard defaults
 * (set_default_keyboard_controls, Savegame.cpp:174), so any unauthored quest using
 * stock GameCommands works with no profile written. Upstream Solarus defines no
 * stock keyboard binding for L, R or select; they are MC_NONE, same as stock. */
static inline void mc_defaults(mc_profile_t* p) {
  memset(p, 0, sizeof *p);
  mc_set(p, MC_IN_RIGHT, MC_KEY, "right");
  mc_set(p, MC_IN_LEFT,  MC_KEY, "left");
  mc_set(p, MC_IN_DOWN,  MC_KEY, "down");
  mc_set(p, MC_IN_UP,    MC_KEY, "up");
  mc_set(p, MC_IN_A,     MC_KEY, "space");  /* action */
  mc_set(p, MC_IN_B,     MC_KEY, "c");      /* attack */
  mc_set(p, MC_IN_Y,     MC_KEY, "x");      /* item_1 */
  mc_set(p, MC_IN_X,     MC_KEY, "v");      /* item_2 */
  mc_set(p, MC_IN_START, MC_KEY, "d");      /* pause  */
  mc_set(p, MC_IN_L,      MC_NONE, NULL);
  mc_set(p, MC_IN_R,      MC_NONE, NULL);
  mc_set(p, MC_IN_SELECT, MC_NONE, NULL);
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
 * follow a matched keyword so a prefix match ("none" inside "nonetheless", "key" inside
 * "keyboard") cannot be mistaken for the whole token. */
static inline int mc_is_delim(char c) {
  return c == '\0' || c == ' ' || c == '\t';
}

/* Parse the right-hand side of a mapping line. Returns 1 on success, 0 if malformed.
 *
 * Keyword matching uses strncmp() for the prefix plus an mc_is_delim() check on the
 * character immediately following, so a keyword only matches when it is a whole
 * token — "nonetheless" does not match "none", and "keyboard" does not match "key"
 * (with "board" misread as the key name). This word-boundary check was added after
 * review found both were silently accepted; keep it. */
static inline int mc_parse_target(const char* s, mc_target_t* out) {
  memset(out, 0, sizeof *out);
  s = mc_skip_ws(s);

  if (!strncmp(s, "none", 4) && mc_is_delim(s[4])) {
    out->kind = MC_NONE;
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
