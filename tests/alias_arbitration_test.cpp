/* Host unit test for the pure alias-target arbitration logic. No SDL/engine
 * deps. Build+run:
 *   c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
 *       tests/alias_arbitration_test.cpp -o /tmp/alias_arbitration_test \
 *   && /tmp/alias_arbitration_test
 * See docs/superpowers/specs/2026-07-10-title-fabric-alias-design.md.
 */
#include "alias_arbitration.h"
#include <cassert>
#include <cstdio>

int main() {
  /* Eligibility: all four conditions required. */
  assert(alias_cand_eligible(1, 1, 1, 1) == 1);
  assert(alias_cand_eligible(0, 1, 1, 1) == 0);  /* not FB-sized */
  assert(alias_cand_eligible(1, 0, 1, 1) == 0);  /* geometry not a 1:1 promote */
  assert(alias_cand_eligible(1, 1, 0, 1) == 0);  /* not re-established this frame */
  assert(alias_cand_eligible(1, 1, 1, 0) == 0);  /* received no draws */

  /* 1. Live tag is authoritative: adopt when not already the alias (gameplay). */
  {
    alias_obs_t o = { /*tag_present=*/1, /*tag_is_alias=*/0, /*tag_live=*/1,
                      /*cand_present=*/0, /*cand_is_alias=*/0 };
    assert(alias_decide(o) == ALIAS_ADOPT_TAG);
  }
  /* 2. Live tag already the alias -> keep (steady gameplay, no thrash). */
  {
    alias_obs_t o = { 1, 1, 1, 0, 0 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }
  /* 3. Live tag wins even when a candidate also exists (never steal from a
   *    live camera). */
  {
    alias_obs_t o = { 1, 0, 1, 1, 0 };
    assert(alias_decide(o) == ALIAS_ADOPT_TAG);
  }
  /* 4. Dead tag + live candidate + candidate not yet alias -> adopt candidate
   *    (THE title fix: dead camera tag no longer hijacks the alias). */
  {
    alias_obs_t o = { /*tag_present=*/1, /*tag_is_alias=*/1, /*tag_live=*/0,
                      /*cand_present=*/1, /*cand_is_alias=*/0 };
    assert(alias_decide(o) == ALIAS_ADOPT_PROMOTE);
  }
  /* 5. Dead tag + candidate already the alias -> keep (steady title, stable). */
  {
    alias_obs_t o = { 1, 0, 0, 1, 1 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }
  /* 6. No tag + live candidate -> adopt candidate. */
  {
    alias_obs_t o = { 0, 0, 0, 1, 0 };
    assert(alias_decide(o) == ALIAS_ADOPT_PROMOTE);
  }
  /* 7. No tag + no candidate -> keep. */
  {
    alias_obs_t o = { 0, 0, 0, 0, 0 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }
  /* 8. Dead tag + no candidate -> keep (stays broken/software until a candidate
   *    is detected; harmless — Component 4 emits the promote normally). */
  {
    alias_obs_t o = { 1, 1, 0, 0, 0 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }

  std::printf("alias_arbitration_test: all cases passed\n");
  return 0;
}
