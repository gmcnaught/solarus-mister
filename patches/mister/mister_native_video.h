//
//  MiSTer native-video glue for Solarus (task 003).
//  Reads the renderer's 320x240 output and pushes it to the MiSTer DDR
//  framebuffer (0x3A000000) via NativeVideoWriter. Called from
//  SDLRenderer::present() just before SDL_RenderPresent.
//
#ifndef SOLARUS_MISTER_NATIVE_VIDEO_H
#define SOLARUS_MISTER_NATIVE_VIDEO_H

struct SDL_Renderer;
struct SDL_Window;

// No-op unless built with -DMISTER_NATIVE_VIDEO.
void mister_present_frame(SDL_Renderer* renderer, SDL_Window* window);

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
