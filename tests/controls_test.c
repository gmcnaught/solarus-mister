/* Host unit test for the per-quest controller mapping parser. cc-compatible. */
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "../patches/mister/mister_controls.h"

static const char* CFG =
  "; a comment line\n"
  "[default]\n"
  "up    = key w      ; comment\n"
  "down  = key s\n"
  "a     = key space\n"
  "start = key return\n"
  "\n"
  "[keyquest]\n"
  "up    = key up\n"
  "a     = key space\n"
  "start = none\n"
  "\n"
  "[bad]\n"
  "nosuchinput = key z\n"
  "a           = banana\n"
  "b\n"
  "\n"
  "[prefixbad]\n"
  "a     = nonetheless\n"
  "b     = keyboard\n"
  "\n"
  "[prefixok]\n"
  "start = none\n"
  "up    = key up\n";

int main(void) {
  mc_profile_t p;

  /* 1. Built-in defaults match stock Solarus KEYBOARD layout
   *    (set_default_keyboard_controls, Savegame.cpp:174). */
  mc_defaults(&p);
  assert(p.t[MC_IN_RIGHT].kind == MC_KEY && !strcmp(p.t[MC_IN_RIGHT].key, "right"));
  assert(p.t[MC_IN_LEFT ].kind == MC_KEY && !strcmp(p.t[MC_IN_LEFT ].key, "left"));
  assert(p.t[MC_IN_DOWN ].kind == MC_KEY && !strcmp(p.t[MC_IN_DOWN ].key, "down"));
  assert(p.t[MC_IN_UP   ].kind == MC_KEY && !strcmp(p.t[MC_IN_UP   ].key, "up"));
  assert(p.t[MC_IN_A].kind == MC_KEY && !strcmp(p.t[MC_IN_A].key, "space"));  /* action */
  assert(p.t[MC_IN_B].kind == MC_KEY && !strcmp(p.t[MC_IN_B].key, "c"));      /* attack */
  assert(p.t[MC_IN_Y].kind == MC_KEY && !strcmp(p.t[MC_IN_Y].key, "x"));      /* item_1 */
  assert(p.t[MC_IN_X].kind == MC_KEY && !strcmp(p.t[MC_IN_X].key, "v"));      /* item_2 */
  assert(p.t[MC_IN_START].kind == MC_KEY && !strcmp(p.t[MC_IN_START].key, "d")); /* pause */
  assert(p.t[MC_IN_L].kind == MC_NONE);
  assert(p.t[MC_IN_R].kind == MC_NONE);
  assert(p.t[MC_IN_SELECT].kind == MC_NONE);

  /* 2. Input index == FPGA joystick_0 bit index. */
  assert(mc_bit(MC_IN_RIGHT) == 0x001u);
  assert(mc_bit(MC_IN_UP)    == 0x008u);
  assert(mc_bit(MC_IN_A)     == 0x010u);
  assert(mc_bit(MC_IN_START) == 0x800u);

  /* 3. Unknown quest id -> [default] section applied, section name "default". */
  mc_load(CFG, "no-such-quest", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.t[MC_IN_UP].kind == MC_KEY && !strcmp(p.t[MC_IN_UP].key, "w"));
  assert(p.warnings == 0);

  /* 4. Quest section overrides [default] per input; unstated inputs inherit. */
  mc_load(CFG, "keyquest", &p);
  assert(!strcmp(p.section, "keyquest"));
  assert(p.t[MC_IN_UP].kind == MC_KEY && !strcmp(p.t[MC_IN_UP].key, "up"));
  assert(p.t[MC_IN_A ].kind == MC_KEY && !strcmp(p.t[MC_IN_A ].key, "space"));
  assert(p.t[MC_IN_START].kind == MC_NONE);
  assert(p.t[MC_IN_DOWN].kind == MC_KEY && !strcmp(p.t[MC_IN_DOWN].key, "s")); /* inherited from [default] */
  assert(p.warnings == 0);

  /* 5. Malformed lines are counted, never fatal; good lines still applied. */
  mc_load(CFG, "bad", &p);
  assert(p.warnings == 3);                    /* unknown input, bad value, no '=' */
  assert(p.t[MC_IN_A].kind == MC_KEY && !strcmp(p.t[MC_IN_A].key, "space"));  /* unchanged */

  /* 6. NULL text -> built-in defaults, no crash. */
  mc_load(NULL, "anything", &p);
  assert(p.t[MC_IN_A].kind == MC_KEY && !strcmp(p.t[MC_IN_A].key, "space"));

  /* 7. CRLF tolerance (the SD card is FAT). */
  mc_load("[q]\r\na = key g\r\n", "q", &p);
  assert(p.t[MC_IN_A].kind == MC_KEY && !strcmp(p.t[MC_IN_A].key, "g"));
  assert(p.warnings == 0);

  /* 8. Comment-only and blank lines are not warnings. */
  mc_load("[q]\n; just a comment\n\n   \n", "q", &p);
  assert(p.warnings == 0);

  /* 9. Prefix matches that are not whole tokens must be rejected as malformed lines
   *    (Finding 1): "nonetheless" must NOT match "none", and "keyboard" must NOT
   *    match "key" + name "board". Each increments warnings and leaves the target
   *    at whatever [default] (or the built-in default) already gave it. */
  mc_load(CFG, "prefixbad", &p);
  assert(p.warnings == 2);
  assert(p.t[MC_IN_A].kind == MC_KEY && !strcmp(p.t[MC_IN_A].key, "space"));  /* from [default], unchanged */
  assert(p.t[MC_IN_B].kind == MC_KEY && !strcmp(p.t[MC_IN_B].key, "c"));      /* built-in default, unchanged */

  /* 10. A valid value that shares a prefix with a longer, invalid token must still
   *     parse: "none" itself, and "key up" (not swallowed as "k" + "ey up" or
   *     confused with any other keyword). */
  mc_load(CFG, "prefixok", &p);
  assert(p.warnings == 0);
  assert(p.t[MC_IN_START].kind == MC_NONE);
  assert(p.t[MC_IN_UP].kind == MC_KEY && !strcmp(p.t[MC_IN_UP].key, "up"));

  printf("controls_test: OK\n");
  return 0;
}
