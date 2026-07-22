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
/// Returns false on any failure. This is the live controller-input path: it
/// establishes the DDR mapping that NativeVideoWriter_ReadJoystick reads from.
bool NativeVideoWriter_Init(void);

/// Read the FPGA→ARM joystick bitmask for a player (0..3) from DDR3.
/// Bits (MiSTer hps_io / OpenBOR core layout): 0=Right 1=Left 2=Down 3=Up
/// 4=B(right face) 5=A(bottom) 6=Y(top) 7=X(left) 8=Start. 0 if not active.
unsigned int NativeVideoWriter_ReadJoystick(int player);

#ifdef __cplusplus
}
#endif

#else /* !MISTER_NATIVE_VIDEO — no-op stubs for non-MiSTer builds */

#include <stdbool.h>

static inline bool NativeVideoWriter_Init(void)   { return false; }
static inline unsigned int NativeVideoWriter_ReadJoystick(int player)
{
    (void)player; return 0u;
}

#endif /* MISTER_NATIVE_VIDEO */

#endif /* NATIVE_VIDEO_WRITER_H */
