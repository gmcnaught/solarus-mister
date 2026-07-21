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
/* 0x008–0x038: reserved (joysticks, cart ctrl, audio ptrs).
 * Joysticks are FPGA→ARM (read-only here); never written by this module. */
#define NV_JOY0_OFFSET      0x00000008u
#define NV_JOY1_OFFSET      0x00000018u
#define NV_JOY2_OFFSET      0x00000020u
#define NV_JOY3_OFFSET      0x00000028u
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

unsigned int NativeVideoWriter_ReadJoystick(int player)
{
    static const uint32_t joy_offsets[4] = {
        NV_JOY0_OFFSET, NV_JOY1_OFFSET, NV_JOY2_OFFSET, NV_JOY3_OFFSET
    };
    if (!ddr_base || player < 0 || player > 3) {
        return 0u;
    }
    volatile uint32_t *joy =
        (volatile uint32_t *)(ddr_base + joy_offsets[player]);
    return (unsigned int)(*joy);
}

#endif /* MISTER_NATIVE_VIDEO */
