//
//  Native Video DDR3 Writer — gmloader MiSTer
//
//  Writes 320x240 RGB565 frames to DDR3 at 0x3A000000 for FPGA native
//  video output. Double-buffered with control word handshake.
//
//  DDR layout matches OpenBOR_7533 exactly (openbor_video_reader.sv):
//    0x3A000000 + 0x000     : Control word (frame_counter[31:2] | active_buf[1:0])
//    0x3A000000 + 0x000040  : Video buffer 0 (320×240 RGB565, 153,600 bytes)
//    0x3A000000 + 0x040040  : Video buffer 1 (320×240 RGB565, 153,600 bytes)
//
//  Reserved offsets 0x008–0x038 are NEVER written by this module.
//

#ifdef MISTER_NATIVE_VIDEO

#include "native_video_writer.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* DDR layout constants — must match OpenBOR_7533 */
#define NV_DDR_PHYS_BASE    0x3A000000u
#define NV_DDR_REGION_SIZE  0x00100000u   /* 1 MiB */
#define NV_CTRL_OFFSET      0x00000000u
/* 0x008–0x038: reserved (joysticks, cart ctrl, audio ptrs) — never written */
#define NV_BUF0_OFFSET      0x00000040u
#define NV_BUF1_OFFSET      0x00040040u
#define NV_FRAME_WIDTH      320
#define NV_FRAME_HEIGHT     240
#define NV_FRAME_BYTES      (NV_FRAME_WIDTH * NV_FRAME_HEIGHT * 2)  /* 153,600 */

static int              mem_fd      = -1;
static volatile uint8_t *ddr_base  = NULL;
static uint32_t         frame_counter = 0;
static int              active_buf  = 0;

bool NativeVideoWriter_Init(void)
{
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        return false;
    }

    ddr_base = (volatile uint8_t *)mmap(NULL, NV_DDR_REGION_SIZE,
                                        PROT_READ | PROT_WRITE, MAP_SHARED,
                                        mem_fd, NV_DDR_PHYS_BASE);
    if (ddr_base == MAP_FAILED) {
        ddr_base = NULL;
        close(mem_fd);
        mem_fd = -1;
        return false;
    }

    /* Clear both video buffers */
    memset((void *)(ddr_base + NV_BUF0_OFFSET), 0, NV_FRAME_BYTES);
    memset((void *)(ddr_base + NV_BUF1_OFFSET), 0, NV_FRAME_BYTES);

    /* Write control word = 0 so FPGA knows no frame is ready yet */
    volatile uint32_t *ctrl = (volatile uint32_t *)(ddr_base + NV_CTRL_OFFSET);
    *ctrl = 0;

    frame_counter = 0;
    active_buf    = 0;
    return true;
}

void NativeVideoWriter_Shutdown(void)
{
    if (ddr_base) {
        /* Signal FPGA: no more frames — blank output */
        volatile uint32_t *ctrl = (volatile uint32_t *)(ddr_base + NV_CTRL_OFFSET);
        *ctrl = 0;
        munmap((void *)ddr_base, NV_DDR_REGION_SIZE);
        ddr_base = NULL;
    }
    if (mem_fd >= 0) {
        close(mem_fd);
        mem_fd = -1;
    }
}

void NativeVideoWriter_WriteFrame(const void *pixels_rgb565, int width,
                                  int height, int pitch)
{
    /* Reject anything that isn't exactly 320×240 or if not initialised */
    if (!ddr_base || !pixels_rgb565) return;
    if (width != NV_FRAME_WIDTH || height != NV_FRAME_HEIGHT) return;

    /* Select destination buffer */
    uint32_t buf_offset = (active_buf == 0) ? NV_BUF0_OFFSET : NV_BUF1_OFFSET;
    volatile uint8_t *dst = ddr_base + buf_offset;

    /* Copy pixel data — single shot when stride is packed, row-by-row otherwise */
    if (pitch == NV_FRAME_WIDTH * 2) {
        memcpy((void *)dst, pixels_rgb565, (size_t)NV_FRAME_BYTES);
    } else {
        const uint8_t *src = (const uint8_t *)pixels_rgb565;
        int row_bytes = NV_FRAME_WIDTH * 2;
        for (int y = 0; y < NV_FRAME_HEIGHT; y++) {
            memcpy((void *)(dst + (size_t)y * (size_t)row_bytes),
                   src + (size_t)y * (size_t)pitch,
                   (size_t)row_bytes);
        }
    }

    /* Increment frame counter — starts at 1 so FPGA can detect first valid frame */
    frame_counter++;

    /* Write control word AFTER pixel data is committed.
     * On strongly-ordered device memory (O_SYNC + MAP_SHARED) ARM guarantees
     * pixel writes reach memory before this store — no explicit DSB needed. */
    volatile uint32_t *ctrl = (volatile uint32_t *)(ddr_base + NV_CTRL_OFFSET);
    *ctrl = (frame_counter << 2) | (uint32_t)(active_buf & 1);

    /* Toggle buffer for next frame */
    active_buf ^= 1;
}

bool NativeVideoWriter_IsActive(void)
{
    return ddr_base != NULL;
}

#endif /* MISTER_NATIVE_VIDEO */
