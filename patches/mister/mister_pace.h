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
 * Since the scanout pacer below became the default (SOLARUS_PACE=scanout) this cap is
 * the FALLBACK rate guard (counter stalled, or SOLARUS_PACE=timer). Before that it was
 * THE SOLE RATE GUARD. Since the host-side vblank barrier was retired
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

/* [fps-dip] Scanout-counter pacer (SOLARUS_PACE=scanout, the default).
 *
 * The wall-clock cap above cannot hold a phase against the scanout: its period is
 * 16,689 us plus nanosleep overshoot (measured on .62: mean 16,790 us, p99 17,519),
 * so the submit drifts across the vblank boundary every few seconds and jitters back
 * and forth while it sits there -- two submits inside one scanout frame (the first is
 * overwritten unseen) followed by a scanout frame with no new frame (a repeat). A
 * 51 s capture had 190 unseen + 247 repeated frames that way.
 *
 * The scanout pacer publishes at most once per scanout frame, right after a vblank:
 * before ringing the doorbell it waits until the reader's vblank counter
 * (0x3A070000, +1 per displayed frame) differs from the value read at the previous
 * publish. The composite then has almost a whole scanout period before the next
 * vblank latches it. If the counter does not move for `stall_us` (core reloading,
 * an old RBF that does not publish it) the caller falls back to the wall-clock cap
 * for that frame.
 *
 * Returns MISTER_PACE_GO (publish now), MISTER_PACE_WAIT (poll again) or
 * MISTER_PACE_STALLED (counter not advancing: use the wall-clock cap). */
#define MISTER_PACE_WAIT    0
#define MISTER_PACE_GO      1
#define MISTER_PACE_STALLED 2
#define MISTER_PACE_STALL_US 50000L

static inline int mister_pace_scan_step(unsigned now_vs, unsigned last_pub_vs,
                                        long waited_us, long stall_us) {
  if (now_vs != last_pub_vs) return MISTER_PACE_GO;
  if (waited_us >= stall_us) return MISTER_PACE_STALLED;
  return MISTER_PACE_WAIT;
}

#endif /* MISTER_PACE_H */
