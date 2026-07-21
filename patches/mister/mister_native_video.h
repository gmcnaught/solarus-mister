//
//  MiSTer native-video glue for Solarus (task 003).
//  Bridges the MiSTer controller (FPGA joystick bitmask in DDR at 0x3A000000,
//  via NativeVideoWriter) to SDL key events, plus SOLARUS_DRAW_PROF draw
//  counters. (The dead SW-video present path was removed in Task 4.)
//
#ifndef SOLARUS_MISTER_NATIVE_VIDEO_H
#define SOLARUS_MISTER_NATIVE_VIDEO_H

// Bridge the MiSTer controller (FPGA joystick bitmask in DDR) -> SDL key events.
// Called once per frame from the blitter offload present() path (which submits to
// the fabric instead of doing an SDL present), so it must call this directly or
// input is never polled.
// No-op unless built with -DMISTER_NATIVE_VIDEO.
void mister_poll_input();

// ---- SOLARUS_DRAW_PROF draw-phase instrumentation -------------------------
// Lightweight per-frame counters incremented from SDLRenderer, summarised
// once/second by MainLoop::draw() when the env var SOLARUS_DRAW_PROF is set.
// All cheap (predictable branch) when profiling is disabled.

// True iff SOLARUS_DRAW_PROF is set in the environment (cached on first call).
bool mister_draw_prof_enabled();

// Count one SDL_RenderCopy/RenderCopyEx (a blit) for the current frame.
void mister_draw_count_blit();
// Count one *real* SDL_SetRenderTarget switch (render-target change).
void mister_draw_count_target_switch();
// Count one SDL_RenderReadPixels (texture->surface download; e.g. a dirty
// render-target read-back, or the final present read-back).
void mister_draw_count_readpixels();

// Read-and-reset the per-frame counters (called once per drawn frame).
void mister_draw_take_counts(long* blits, long* target_switches, long* readpixels);

#endif
