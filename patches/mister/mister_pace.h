#ifndef MISTER_PACE_H
#define MISTER_PACE_H
/* Producer-pacing arithmetic for the MiSTer blitter path.
 *
 * Header-only, dependency-free and side-effect-free so that BOTH the renderer
 * (patches/mister/mister_blitter_renderer.cpp) and the standalone frame generator
 * (patches/mister/frame_gen/frame_gen.c) call the SAME logic, and so the host suite
 * can unit-test it. Mirrors the mister_blend_layer.h / mister_overlay_id.h
 * convention. */

/* Scanout frame period in MICROSECONDS, rounded UP.
 *
 * Derivation (fpga/rtl/openbor_video_timing.sv:12-13) — carry FULL precision. The
 * RTL comment's rounded "15,700 Hz / 59.92 Hz" figures do NOT reproduce this value:
 *     pixel clock 53,693,182 Hz, H total 3420, V total 262 lines
 *     period = 1e6 * 3420 * 262 / 53,693,182 = 16,688.15 us  ->  rounded UP: 16689
 * Deriving instead from the rounded 15,700 Hz gives 16,687.90 -> 16,688, which is
 * 0.25 us SHORT of the true period and would reintroduce producer drift. The true
 * refresh is 59.9228 Hz, not 59.9237 Hz.
 *
 * Rounded UP so any residual drift leaves the producer marginally SLOWER than the
 * scanout. The core does NOT run at 60.00 Hz: shipping 16,667 let the producer gain
 * ~21 us per frame, slipping a whole frame every ~795 cap-limited frames -- two
 * snapshots inside one scan window, i.e. a one-frame tear on a ~13 s beat, which is
 * long enough that a brief visual check misses it.
 *
 * THIS IS THE SOLE RATE GUARD. Since the host-side vblank barrier was retired
 * (PR #151) nothing else limits the producer, and the fabric has NO reader
 * acknowledgement -- nothing tells it the scanout has moved off the buffer it is
 * about to overwrite. Do not raise this above the true scan period, and re-validate
 * with the frame generator if it changes at all. */
#define MISTER_PACE_TARGET_US 16689

/* Microseconds still owed before the next submit may proceed; 0 if none.
 *
 * `elapsed_us` is the time since the previous submit completed. A negative value
 * (a clock that went backwards) yields 0 rather than an enormous sleep that would
 * stall the producer outright. `target_us` is a parameter rather than baked in so
 * the frame generator's calibration mode drives a deliberately-too-fast rate
 * through this identical path instead of bypassing it. */
static inline long mister_pace_sleep_us(long elapsed_us, long target_us) {
  if (elapsed_us < 0) return 0;
  if (elapsed_us >= target_us) return 0;
  return target_us - elapsed_us;
}

#endif /* MISTER_PACE_H */
