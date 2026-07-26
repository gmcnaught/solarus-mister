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
  want_button(&p, MC_IN_L, 5);
  want_button(&p, MC_IN_R, 6);
  want_button(&p, MC_IN_SELECT, 7);

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

  /* [zelda-roth-se-v1.2.1] — no section of its own: ROTH uses stock GameCommands
   * joypad bindings for gameplay, and its menus (including savegames.lua, via the
   * gui_designer:map_joypad_to_keyboard mixin) accept joypad input fine. It falls
   * through to [default] end to end — assert that fall-through actually happens. */
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
