/* frame_gen — drive the FPGA compositor at a chosen rate, independent of the engine.
 *
 * WHY: since PR #151 retired the host vblank barrier, the free-running cap in
 * present() is the SOLE rate guard -- the fabric has no reader acknowledgement, so
 * nothing else stops the producer overwriting a buffer the scanout is still reading.
 * But no game scene reaches the scan rate, so (a) the cap has never actually clamped
 * anything, and (b) the over-production detector has never been shown to fire. This
 * settles both.
 *
 * MODES (one code path; they differ ONLY in the pacing target):
 *   --paced      target = MISTER_PACE_TARGET_US. THE GATE.  PASS iff published <= displayed.
 *   --rate N     target = 1e6/N (default 120).   CALIBRATION. PASS iff published >  displayed.
 *
 * The --rate verdict is deliberately inverted: if driving faster than the scanout does
 * NOT over-produce, the detector is broken and any --paced pass is meaningless. Run
 * the calibration first; a gate pass only counts on a build whose calibration passed.
 *
 * Build:  bash scripts/build_frame_gen.sh
 * Run:    RBF loaded, engine NOT running (it refuses otherwise -- two producers on one
 *         command ring is the two-engines wedge).
 *
 * NOTE --rate DELIBERATELY TEARS. That is the point. Relaunch the engine afterwards.
 *
 * CONTENT: a static dark background with one bright vertical bar that sweeps
 * left-to-right, wrapping around. Earlier this cleared the whole framebuffer to
 * a colour that alternated every frame -- at the ~106 fps this actually
 * achieves that is a 106 Hz full-screen strobe: unpleasant to watch, and it
 * HIDES tearing rather than revealing it, because every frame already differs
 * from the last, so the eye has no stable reference to notice a split against
 * (operator feedback from a live run: counters proved over-production, 1589
 * published vs 899 displayed in 15s, but the tear itself was not visible).
 * A moving bar on a static background gives the eye a fixed frame of
 * reference; a tear then shows as a clean horizontal step where the bar's
 * position jumps between the rows above and below the split -- visible on
 * every frame, not just at a colour transition, and comfortable to watch.
 */
#include "blt_emitter.h"
#include "blt_alloc.h"
#include "blitter_ref.h"
#include "mister_pace.h"

#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* ---- DDR layout — MUST MATCH mister_blitter_renderer.cpp / blitter_defs.vh ---- */
#define BLT_DDR_PHYS   0x3B000000u
#define BLT_DDR_SIZE   0x01000000u
#define OFF_RING       0x00000040u
#define RING_CAP       0x00007FC0u
#define OFF_HEAP       0x00008000u
#define HEAP_CAP       0x00100000u

#define VIDEO_PHYS     0x3A000000u
#define VIDEO_SIZE     0x00100000u
#define OFF_VCTRL      0x00000000u   /* ((frame_counter+1)<<2)|active_buf */
#define OFF_VSYNC      0x00070000u   /* scanout displayed-frame counter   */

#define C_SUBMIT   0x00u
#define C_CMDCOUNT 0x08u
#define C_TARGET   0x10u
#define C_CLEAR    0x18u
#define C_FLAGS    0x20u
#define C_DONE     0x28u
#define C_SRCSEL   0x38u

/* Framebuffer geometry (fixed for this core). */
#define FB_W 320
#define FB_H 240

/* Maximum contrast in RGB565: a torn frame shows as a hard horizontal step in
 * the bar, where the bar's x position above and below the split disagree. */
#define COLOUR_BG  0x0841u   /* near-black background, held constant every frame */
#define COLOUR_BAR 0xFFE0u   /* bright yellow bar */

/* Bar geometry: ~24px wide, stepping 3px/frame sweeps the full 320px width in
 * ~107 frames -- ~1.0s at the ~106 fps this build actually achieves. */
#define BAR_W    24
#define BAR_STEP 3

/* Above this the DDR3 snapshot traffic leaves the regime any real workload occupies;
 * a wedge there is more likely a bus artifact than a pacing finding. */
#define RATE_MAX 240

static volatile uint8_t *g_ddr, *g_vid;

static inline void w32(volatile uint8_t *b, uint32_t o, uint32_t v){ *(volatile uint32_t*)(b+o)=v; }
static inline uint32_t r32(volatile uint8_t *b, uint32_t o){ return *(volatile uint32_t*)(b+o); }

/* long long: on this armhf target `long` is 32-bit (LONG_MAX ~2.1e9), and tv_sec is
 * seconds since boot (never resets) -- tv_sec*1000000 overflows a 32-bit long past
 * ~2147s (~36min) of uptime, well within a real device session. Any consumer that
 * needs the result to fit in a `long` (e.g. mister_pace_sleep_us, shared with the
 * renderer and NOT to be widened) must take a small delta of two of these values
 * first and narrow that -- never narrow the absolute value itself. */
static long long now_us(void){
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000LL + t.tv_nsec / 1000LL;
}

/* Refuse to run alongside the engine: two producers on one command ring corrupt it. */
static int engine_running(void){
    DIR *d = opendir("/proc"); if(!d) return 0;
    struct dirent *e; char path[300], comm[64]; int found = 0;
    while((e = readdir(d)) != NULL){
        if(e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        snprintf(path, sizeof path, "/proc/%s/comm", e->d_name);
        FILE *f = fopen(path, "r"); if(!f) continue;
        if(fgets(comm, sizeof comm, f)){
            comm[strcspn(comm, "\n")] = 0;
            if(strcmp(comm, "solarus-run") == 0) found = 1;
        }
        fclose(f);
        if(found) break;
    }
    closedir(d);
    return found;
}

/* Publish the frame and spin (bounded) until the fabric mirrors DONE==submit_seq.
 * The engine does exactly this; without it we would overwrite a ring the fabric is
 * still reading, which is garbage and a wedge -- not a clean over-production test. */
static int submit_and_wait(blt_emitter_t *e){
    w32(g_ddr, C_CMDCOUNT, (uint32_t)e->cmd_count);
    w32(g_ddr, C_TARGET,   (uint32_t)e->target_buf);
    w32(g_ddr, C_CLEAR,    e->clear_color);
    w32(g_ddr, C_FLAGS,    e->flags);
    w32(g_ddr, C_SRCSEL,   1u);
    __sync_synchronize();
    w32(g_ddr, C_SUBMIT,   e->submit_seq);
    for(long i = 0; i < 5000000L; i++)
        if(r32(g_ddr, C_DONE) == e->submit_seq) return 1;
    return 0;
}

static void usage(const char *p){
    fprintf(stderr,
      "usage: %s [--paced | --rate N] [--seconds N]\n"
      "  --paced      pace at the shipped cap (%ld us). GATE: pass iff published <= displayed.\n"
      "  --rate N     pace at N fps (default 120, max %d). CALIBRATION: pass iff published > displayed.\n"
      "  --seconds N  run length (default 60)\n",
      p, (long)MISTER_PACE_TARGET_US, RATE_MAX);
}

int main(int argc, char **argv){
    int paced = 0, rate = 120, seconds = 60, rate_given = 0;
    for(int i = 1; i < argc; i++){
        if(!strcmp(argv[i], "--paced")) paced = 1;
        else if(!strcmp(argv[i], "--rate") && i+1 < argc){ rate = atoi(argv[++i]); rate_given = 1; }
        else if(!strcmp(argv[i], "--seconds") && i+1 < argc) seconds = atoi(argv[++i]);
        else { usage(argv[0]); return 2; }
    }
    if(paced && rate_given){
        fprintf(stderr, "--paced and --rate are mutually exclusive: --paced pins the target to\n"
                        "the shipped cap (the GATE) and ignores --rate, which would silently\n"
                        "discard the rate you asked for. Run them as two separate invocations --\n"
                        "the gate and the calibration are different tests.\n");
        return 2;
    }
    if(!paced && (rate < 1 || rate > RATE_MAX)){
        fprintf(stderr, "rate %d out of range 1..%d — above %d you are characterising the\n"
                        "DDR3 bus, not the pacing, and a wedge must not be read as a pacing result.\n",
                rate, RATE_MAX, RATE_MAX);
        return 2;
    }
    if(seconds < 1){
        fprintf(stderr, "seconds %d out of range — need >=1, or the run measures nothing and\n"
                        "a zero-frame run would misreport as a pass.\n",
                seconds);
        return 2;
    }
    if(engine_running()){
        fprintf(stderr, "REFUSING: solarus-run is alive. Two producers on one command ring\n"
                        "corrupt it. Stop the engine first: kill -9 $(pidof solarus-run)\n");
        return 2;
    }

    const long target_us = paced ? (long)MISTER_PACE_TARGET_US : (1000000L / rate);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if(fd < 0){ perror("open /dev/mem"); return 1; }
    void *pd = mmap(NULL, BLT_DDR_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, BLT_DDR_PHYS);
    void *pv = mmap(NULL, VIDEO_SIZE,   PROT_READ|PROT_WRITE, MAP_SHARED, fd, VIDEO_PHYS);
    if(pd == MAP_FAILED || pv == MAP_FAILED){ perror("mmap"); return 1; }
    g_ddr = (volatile uint8_t*)pd; g_vid = (volatile uint8_t*)pv;

    blt_emitter_t em;
    blt_emitter_init(&em, (void*)(g_ddr+OFF_RING), RING_CAP,
                          (void*)(g_ddr+OFF_HEAP), HEAP_CAP);

    printf("frame_gen: mode=%s target=%ld us (%.2f fps) for %d s\n",
           paced ? "PACED (gate)" : "RATE (calibration)",
           target_us, 1000000.0/(double)target_us, seconds);

    /* Read the two counters back-to-back so the sampling skew between them stays far
     * below one frame (the devmem probe's two process spawns cost ~a frame of skew). */
    const uint32_t pub0  = r32(g_vid, OFF_VCTRL) >> 2;
    const uint32_t disp0 = r32(g_vid, OFF_VSYNC);

    const long long t_end = now_us() + (long long)seconds * 1000000LL;
    long long last = 0;
    long submits = 0, handshake_fail = 0;
    int bar_x = 0;

    while(now_us() < t_end){
        if(last != 0){
            /* Take the delta in 64-bit FIRST, then narrow -- the delta since the last
             * submit is always small (bounded by target_us), so it always fits in the
             * `long` mister_pace_sleep_us takes. Narrowing the absolute now_us() value
             * instead (rather than the delta) is exactly the bug this widening fixes. */
            const long long dus_ll = now_us() - last;
            const long owed = mister_pace_sleep_us((long)dus_ll, target_us);
            if(owed > 0){
                /* Normalise into tv_sec/tv_nsec rather than assuming the whole owed
                 * value fits in tv_nsec: at --rate 1, target_us=1,000,000 and owed can
                 * equal it exactly, so owed*1000 == 1e9 ns -- one past timespec's valid
                 * [0, 999999999] range (POSIX: EINVAL, sleep not guaranteed). */
                struct timespec ts;
                ts.tv_sec  = owed / 1000000L;
                ts.tv_nsec = (owed % 1000000L) * 1000L;
                nanosleep(&ts, NULL);
            }
        }
        blt_begin_frame(&em, 0, 1, COLOUR_BG);   /* constant background -- no strobe */
        /* Bar segment at bar_x; the fabric clips/culls anything past FB_W, so this
         * is safe even when bar_x + BAR_W runs off the right edge. */
        blt_fill(&em, bar_x, 0, BAR_W, FB_H, COLOUR_BAR);
        if(bar_x + BAR_W > FB_W){
            /* Draw the wrapped remainder at the left so the bar is never partly
             * missing -- a bar that vanishes at the edge would look like a glitch. */
            const int wrapped_w = (bar_x + BAR_W) - FB_W;
            blt_fill(&em, 0, 0, wrapped_w, FB_H, COLOUR_BAR);
        }
        blt_end_frame(&em);   /* emits BLT_OP_END — the fabric walks until END */
        bar_x += BAR_STEP;
        if(bar_x >= FB_W) bar_x -= FB_W;
        if(!submit_and_wait(&em)) handshake_fail++;
        submits++;
        last = now_us();      /* AFTER the sleep+submit — mirrors present() */
    }

    const uint32_t pub1  = r32(g_vid, OFF_VCTRL) >> 2;
    const uint32_t disp1 = r32(g_vid, OFF_VSYNC);

    const long published = (long)(pub1 - pub0);
    const long displayed = (long)(disp1 - disp0);

    printf("submits=%ld handshake_timeouts=%ld\n", submits, handshake_fail);
    printf("published=%ld (%.2f fps)   displayed=%ld (%.2f Hz)   difference=%+ld\n",
           published, (double)published/seconds,
           displayed, (double)displayed/seconds, published - displayed);
    if(displayed > 0)
        printf("ratio published/displayed = %.2f\n", (double)published/(double)displayed);

    if(handshake_fail){
        printf("FAIL: %ld handshake timeouts — the fabric did not complete a frame.\n"
               "Result is not interpretable; check the core is loaded.\n", handshake_fail);
        return 1;
    }
    if(submits == 0){
        printf("FAIL: submits=0 — no frame was ever produced. Result is not interpretable;\n"
               "check --seconds and that the run actually executed.\n");
        return 1;
    }
    if(displayed == 0){
        printf("FAIL: displayed=0 — the scanout counter never advanced, so the display side\n"
               "is not running. Result is not interpretable; check the core is loaded and\n"
               "scanning out.\n");
        return 1;
    }

    if(paced){
        if(published <= displayed){
            printf("PASS (gate): the cap held the producer under the scan rate.\n");
            return 0;
        }
        printf("FAIL (gate): OVER-PRODUCED by %ld frames — the sole rate guard did not\n"
               "hold. Tearing is expected. Do not ship this pacing.\n", published - displayed);
        return 1;
    }
    if(published > displayed){
        printf("PASS (calibration): over-production detected, so the counters CAN see it.\n"
               "A --paced pass on this build is now meaningful.\n"
               "OPERATOR: confirm the tear was visible on screen.\n");
        return 0;
    }
    printf("FAIL (calibration): drove %d fps but did NOT over-produce. The detector is\n"
           "not calibrated, so a --paced pass would prove nothing. Investigate before\n"
           "trusting any gate result.\n", rate);
    return 1;
}
