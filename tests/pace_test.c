/* pace_test — pure producer-pacing arithmetic. Build: see tests/run_tests.sh. */
#include "mister_pace.h"
#include <stdio.h>

int main(void){
  int fails=0;
  const long T = MISTER_PACE_TARGET_US;

  /* The shipped constant is the 59.9228 Hz scan period rounded UP. A value at or
     below 16687 would let the producer outrun the scanout -- the exact defect that
     shipped once (16667). Pin it. */
  if (T != 16689){ printf("FAIL: MISTER_PACE_TARGET_US is %ld, expected 16689\n", T); fails++; }

  /* Below target -> owed the remainder. */
  if (mister_pace_sleep_us(0, T)      != T)      { printf("FAIL: elapsed 0\n"); fails++; }
  if (mister_pace_sleep_us(1, T)      != T-1)    { printf("FAIL: elapsed 1\n"); fails++; }
  if (mister_pace_sleep_us(T-1, T)    != 1)      { printf("FAIL: elapsed T-1\n"); fails++; }

  /* At and above target -> nothing owed (must not return a negative sleep). */
  if (mister_pace_sleep_us(T, T)      != 0)      { printf("FAIL: elapsed == T\n"); fails++; }
  if (mister_pace_sleep_us(T+1, T)    != 0)      { printf("FAIL: elapsed T+1\n"); fails++; }
  if (mister_pace_sleep_us(1000000, T)!= 0)      { printf("FAIL: elapsed huge\n"); fails++; }

  /* Clock went backwards -> 0, NOT a huge sleep that would stall the producer. */
  if (mister_pace_sleep_us(-1, T)     != 0)      { printf("FAIL: elapsed -1\n"); fails++; }
  if (mister_pace_sleep_us(-1000000,T)!= 0)      { printf("FAIL: elapsed very negative\n"); fails++; }

  /* A non-default target behaves identically about its own boundary -- this is the
     frame generator's calibration mode (120 fps = 8333 us), which must run the SAME
     code path as the shipped cap, differing only in this constant. */
  const long T120 = 8333;
  if (mister_pace_sleep_us(0, T120)      != T120){ printf("FAIL: 120fps elapsed 0\n"); fails++; }
  if (mister_pace_sleep_us(T120-1, T120) != 1)   { printf("FAIL: 120fps boundary-1\n"); fails++; }
  if (mister_pace_sleep_us(T120, T120)   != 0)   { printf("FAIL: 120fps at boundary\n"); fails++; }
  if (mister_pace_sleep_us(T120+1, T120) != 0)   { printf("FAIL: 120fps past boundary\n"); fails++; }

  /* The calibration target MUST be shorter than the shipped one, or the control
     mode could not over-produce and the whole calibration argument collapses. */
  if (!(T120 < T)){ printf("FAIL: calibration target not faster than shipped\n"); fails++; }

  if (fails){ printf("pace_test: %d FAIL\n", fails); return 1; }
  printf("pace_test: OK\n"); return 0;
}
