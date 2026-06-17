/*
 *  fb_dump.c — dump the live MiSTer framebuffer (0x3A region, 320x240 RGB565) to a
 *  binary PPM (P6) for visual verification of on-device rendering. Reads the video
 *  control word to pick the displayed buffer. Usage: ./fb_dump [out.ppm]
 *  GPL-3.0.
 */
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>

#define VIDEO_PHYS 0x3A000000u
#define VIDEO_SIZE 0x00100000u
#define FB0_OFF    0x00000040u
#define FB1_OFF    0x00040040u
#define W 320
#define H 240

int main(int argc, char **argv) {
    const char *out = argc > 1 ? argv[1] : "/tmp/fb.ppm";
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }
    volatile uint8_t *v = mmap(NULL, VIDEO_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, VIDEO_PHYS);
    if (v == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t ctrl = *(volatile uint32_t *)v;
    fprintf(stderr, "ctrl=0x%08x disp_buf(low bit)=%d\n", ctrl, ctrl & 1);

    const uint32_t offs[2] = { FB0_OFF, FB1_OFF };
    for (int b = 0; b < 2; b++) {
        const volatile uint16_t *fb = (const volatile uint16_t *)(v + offs[b]);
        char path[256]; snprintf(path, sizeof path, "%s.buf%d.ppm", out, b);
        FILE *f = fopen(path, "wb");
        if (!f) { perror("fopen"); return 1; }
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        long nz = 0;
        for (int i = 0; i < W * H; i++) {
            uint16_t p = fb[i];
            if (p) nz++;
            uint8_t r = (uint8_t)(((p >> 11) & 0x1F) * 255 / 31);
            uint8_t g = (uint8_t)(((p >> 5)  & 0x3F) * 255 / 63);
            uint8_t bl = (uint8_t)(( p        & 0x1F) * 255 / 31);
            fputc(r, f); fputc(g, f); fputc(bl, f);
        }
        fclose(f);
        fprintf(stderr, "wrote %s nonzero=%ld/%d\n", path, nz, W * H);
    }
    return 0;
}
