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

static void want_key(const mc_profile_t* p, int in, const char* k) {
  assert(p->t[in].kind == MC_KEY && !strcmp(p->t[in].key, k));
}
static void want_none(const mc_profile_t* p, int in) {
  assert(p->t[in].kind == MC_NONE);
}

/* [default] is stock Solarus keyboard bindings (Savegame.cpp set_default_keyboard_controls),
 * so any quest without its own section falls through to it end to end. */
static void assert_default_table(const mc_profile_t* p) {
  want_key(p, MC_IN_RIGHT, "right");
  want_key(p, MC_IN_LEFT,  "left");
  want_key(p, MC_IN_DOWN,  "down");
  want_key(p, MC_IN_UP,    "up");
  want_key(p, MC_IN_B, "c");        /* attack */
  want_key(p, MC_IN_A, "space");    /* action */
  want_key(p, MC_IN_Y, "x");        /* item_1 */
  want_key(p, MC_IN_X, "v");        /* item_2 */
  want_key(p, MC_IN_START, "d");    /* pause  */
  want_none(p, MC_IN_L);
  want_none(p, MC_IN_R);
  want_none(p, MC_IN_SELECT);
}

int main(void) {
  char* cfg = slurp("games/Solarus/controls.cfg.default");
  mc_profile_t p;

  /* [default] — stock Solarus keyboard bindings, so unauthored quests just work. */
  mc_load(cfg, "unknown-quest", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.warnings == 0);
  assert_default_table(&p);

  /* [default] again, all twelve inputs explicitly, via the real quest id it resolves for. */
  mc_load(cfg, "mystery_of_solarus_dx", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.warnings == 0);
  assert_default_table(&p);

  /* Zelda ROTH SE has no section of its own either: it uses stock GameCommands, so
   * [default] (stock Solarus keyboard bindings) already covers it end to end. */
  mc_load(cfg, "zelda-roth-se-v1.2.1", &p);
  assert(!strcmp(p.section, "default"));
  assert(p.warnings == 0);
  assert_default_table(&p);

  /* [patched-tunics-b007e656] — PT's own keys from lib/bindings.lua. All twelve inputs,
   * so every one of PT's seven actions is checked, not just the ones the old hardcoded
   * bridge happened to reach. */
  mc_load(cfg, "patched-tunics-b007e656", &p);
  assert(!strcmp(p.section, "patched-tunics-b007e656"));
  assert(p.warnings == 0);
  want_key(&p, MC_IN_RIGHT, "right");
  want_key(&p, MC_IN_LEFT,  "left");
  want_key(&p, MC_IN_DOWN,  "down");
  want_key(&p, MC_IN_UP,    "up");
  want_key(&p, MC_IN_B, "s");        /* attack */
  want_key(&p, MC_IN_A, "space");    /* action */
  want_key(&p, MC_IN_L, "tab");      /* map */
  want_key(&p, MC_IN_R, "w");        /* inventory */
  want_key(&p, MC_IN_Y, "a");        /* item_1 */
  want_key(&p, MC_IN_X, "d");        /* item_2 */
  want_key(&p, MC_IN_START, "escape"); /* escape / save menu */
  want_none(&p, MC_IN_SELECT);

  free(cfg);
  printf("controls_profiles_test: OK\n");
  return 0;
}
