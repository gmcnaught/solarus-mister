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
  "b\n"
  "\n"
  "[prefixbad]\n"
  "a     = nonetheless\n"
  "up    = hat up2\n"
  "b     = keyboard\n"
  "\n"
  "[prefixok]\n"
  "start = none\n"
  "up    = key up\n";

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

  /* 10. Prefix matches that are not whole tokens must be rejected as malformed lines
   *     (Finding 1): "nonetheless" must NOT match "none", "hat up2" must NOT match
   *     "hat up", "keyboard" must NOT match "key" + name "board". Each increments
   *     warnings and leaves the target at whatever [default] (or the built-in
   *     default) already gave it. */
  mc_load(CFG, "prefixbad", &p);
  assert(p.warnings == 3);
  assert(p.t[MC_IN_A].kind == MC_BUTTON && p.t[MC_IN_A].v0 == 0);   /* from [default], unchanged */
  assert(p.t[MC_IN_UP].kind == MC_AXIS  && p.t[MC_IN_UP].v0 == 1 && p.t[MC_IN_UP].v1 == -1); /* unchanged */
  assert(p.t[MC_IN_B].kind == MC_BUTTON && p.t[MC_IN_B].v0 == 1);   /* built-in default, unchanged */

  /* 11. A valid value that shares a prefix with a longer, invalid token must still
   *     parse: "none" itself, and "key up" (not swallowed as "k" + "ey up" or
   *     confused with any other keyword). */
  mc_load(CFG, "prefixok", &p);
  assert(p.warnings == 0);
  assert(p.t[MC_IN_START].kind == MC_NONE);
  assert(p.t[MC_IN_UP].kind == MC_KEY && !strcmp(p.t[MC_IN_UP].key, "up"));

  printf("controls_test: OK\n");
  return 0;
}
