//
//  Native Video DDR3 Writer — gmloader MiSTer
//
//  API for writing pre-converted RGB565 frames from ARM to DDR3 for FPGA
//  native video output. DDR layout matches OpenBOR_7533 exactly so the
//  same FPGA core RBF can be shared.
//
//  DDR memory layout (physical base 0x3A000000, 1 MiB region):
//    0x3A000000 + 0x000     : Control word (frame_counter[31:2] | active_buf[1:0])
//    0x3A000000 + 0x008     : Joystick P1 — FPGA→ARM, do NOT overwrite
//    0x3A000000 + 0x010     : Cart control — reserved, do NOT overwrite
//    0x3A000000 + 0x018     : Joystick P2 — reserved
//    0x3A000000 + 0x020     : Joystick P3 — reserved
//    0x3A000000 + 0x028     : Joystick P4 — reserved
//    0x3A000000 + 0x030     : Audio ring write pointer — reserved
//    0x3A000000 + 0x038     : Audio ring read pointer — reserved
//    0x3A000000 + 0x000040  : Video buffer 0 (320×240 RGB565, 153,600 bytes)
//    0x3A000000 + 0x040040  : Video buffer 1 (320×240 RGB565, 153,600 bytes)
//

#ifndef NATIVE_VIDEO_WRITER_H
#define NATIVE_VIDEO_WRITER_H

#ifdef MISTER_NATIVE_VIDEO

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize DDR3 native video writer. Maps /dev/mem at 0x3A000000.
/// Clears both video buffers and writes control word = 0.
/// Returns false on any failure.
bool NativeVideoWriter_Init(void);

/// Write control word = 0, unmap DDR region, close /dev/mem fd.
void NativeVideoWriter_Shutdown(void);

/// Write one pre-converted RGB565 frame to the active DDR3 double-buffer.
/// Silently ignored if width != 320, height != 240, or writer is not active.
/// Uses single memcpy when pitch == width*2, else copies row-by-row.
/// Increments frame_counter (starts at 1, never 0) and writes control word
/// AFTER pixel data, then toggles active_buf.
/// @param pixels_rgb565  Source pixel data, already in RGB565 format
/// @param width          Frame width (must be 320)
/// @param height         Frame height (must be 240)
/// @param pitch          Source row stride in bytes
void NativeVideoWriter_WriteFrame(const void* pixels_rgb565, int width,
                                  int height, int pitch);

/// Returns true if DDR3 writer is initialized and ready.
bool NativeVideoWriter_IsActive(void);

#ifdef __cplusplus
}
#endif

#else /* !MISTER_NATIVE_VIDEO — no-op stubs for non-MiSTer builds */

#include <stdbool.h>

static inline bool NativeVideoWriter_Init(void)   { return false; }
static inline void NativeVideoWriter_Shutdown(void) {}
static inline void NativeVideoWriter_WriteFrame(const void* pixels_rgb565,
                                                int width, int height,
                                                int pitch)
{
    (void)pixels_rgb565; (void)width; (void)height; (void)pitch;
}
static inline bool NativeVideoWriter_IsActive(void) { return false; }

#endif /* MISTER_NATIVE_VIDEO */

#endif /* NATIVE_VIDEO_WRITER_H */
