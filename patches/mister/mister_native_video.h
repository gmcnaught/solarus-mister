//
//  MiSTer native-video glue for Solarus (task 003).
//  Reads the renderer's 320x240 output and pushes it to the MiSTer DDR
//  framebuffer (0x3A000000) via NativeVideoWriter. Called from
//  SDLRenderer::present() just before SDL_RenderPresent.
//
#ifndef SOLARUS_MISTER_NATIVE_VIDEO_H
#define SOLARUS_MISTER_NATIVE_VIDEO_H

struct SDL_Renderer;

// No-op unless built with -DMISTER_NATIVE_VIDEO.
void mister_present_frame(SDL_Renderer* renderer);

#endif
