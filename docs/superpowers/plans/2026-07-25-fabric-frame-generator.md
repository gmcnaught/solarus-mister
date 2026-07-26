# Fabric Frame Generator + Extracted Pacing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone on-device generator that drives the FPGA compositor at a chosen frame rate, so the producer-pacing cap can be exercised and the over-production detector calibrated — neither of which any game scene can currently do.

**Architecture:** Extract the pacing arithmetic from `present()` into a pure header (`mister_pace.h`) that both the renderer and a new standalone armhf binary call, so the generator tests the *shipped* logic rather than a copy. The generator is a sibling of the existing `sdram_selftest`: libc-only, static, mmaps the blitter control block and the video region, emits trivial alternating-colour frames through the real emitter library, and compares frames *published* against frames *displayed*.

**Tech Stack:** C99 (`patches/mister/`, `tests/`), C++17 renderer, armhf cross-build in `solarus-armhf-build:bullseye`, host suite via `tests/run_tests.sh`.

## Global Constraints

- **Base:** branch `feat/fabric-frame-generator`, worktree `/Users/gmcnaught/MisterFPGA-Projects/solarus-mister-pacing`, forked from `origin/master` @ `00a23e0`. The design spec is committed there as `f3a046c`.
- **No RBF change.** Ships against `Solarus_20260724.rbf`.
- **`patches/mister/*.{c,h,cpp}` are WHOLE-FILE COPIES**, not part of the `patches/series/` git-am series. Edit directly; nothing to regenerate. This plan must not touch `patches/series/` or `work/solarus`.
- **Renderer type-check — both `-D` flags are MANDATORY.** Nearly the whole renderer is inside `#ifdef MISTER_NATIVE_VIDEO`; omitting them type-checks almost nothing and prints success on a broken file. This has already produced one falsely-passing verification on this repo.
  ```
  g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
- **A NEW header included by the renderer MUST be added to `scripts/apply_mister_files.sh`.** That script copies the whole-file MiSTer additions into the engine build tree; a header that is not listed simply does not exist there, and the engine build fails with `No such file or directory`. The local type-check **cannot** catch this — it passes `-I patches/mister`, where the header does exist. Only the engine cross-build (or CI) sees it. PR #149 hit this exact trap with `mister_blend_layer.h`, and this plan hit it again with `mister_pace.h`.
- **`-fsyntax-only` does NOT link.** A namespace/linkage error is invisible to it and to the host suite. Renderer symbols live in `namespace Solarus`; `mister_native_video.cpp`'s do not. When adding or moving a cross-file symbol, verify with a symbol check (`nm`), not a type-check. This exact class of bug shipped on the previous branch and was caught only by a whole-branch review.
- **Host suite:** `bash tests/run_tests.sh`. It does NOT compile the renderer.
- **Device:** `root@192.168.20.81`, key-authed. busybox has **no `pkill`** (use `kill -9 $(pidof solarus-run)`). Never run two producers against the command ring at once.
- **`MISTER_PACE_TARGET_US = 16689` is the sole rate guard.** The fabric has no reader acknowledgement. Do not raise it above the true scan period.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `patches/mister/mister_pace.h` | pure pacing arithmetic + the scan-period constant | 1 |
| `tests/pace_test.c` | host unit tests for the above | 1 |
| `tests/run_tests.sh` | wire in `pace_test` | 1 |
| `patches/mister/mister_blitter_renderer.cpp` | `present()` calls the extracted helper | 2 |
| `patches/mister/frame_gen/frame_gen.c` | the generator | 3 |
| `scripts/build_frame_gen.sh` | armhf cross-build | 3 |
| `docs/superpowers/plans/2026-07-25-frame-generator-runbook.md` | operator procedure + rollout | 4 |

---

## Task 1: Extract `mister_pace.h` with host unit tests

**Files:**
- Create: `patches/mister/mister_pace.h`
- Create: `tests/pace_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `#define MISTER_PACE_TARGET_US 16689`
  - `static inline long mister_pace_sleep_us(long elapsed_us, long target_us)` — microseconds still owed before the next submit may proceed; `0` if none. Negative `elapsed_us` yields `0`.

- [ ] **Step 1: Write the failing test**

Create `tests/pace_test.c`:

```c
/* pace_test — pure producer-pacing arithmetic. Build: see tests/run_tests.sh. */
#include "mister_pace.h"
#include <stdio.h>

int main(void){
  int fails=0;
  const long T = MISTER_PACE_TARGET_US;

  /* The shipped constant is the 59.9228 Hz scan period rounded UP. A value at or
     below 16687 would let the producer outrun the scanout -- the exact defect that
     shipped once (16667). Pin it. */
  if (T != 16689){ printf("FAIL: MISTER_PACE_TARGET_US is %ld, expected 16689\n", T); fails++; }

  /* Below target -> owed the remainder. */
  if (mister_pace_sleep_us(0, T)      != T)      { printf("FAIL: elapsed 0\n"); fails++; }
  if (mister_pace_sleep_us(1, T)      != T-1)    { printf("FAIL: elapsed 1\n"); fails++; }
  if (mister_pace_sleep_us(T-1, T)    != 1)      { printf("FAIL: elapsed T-1\n"); fails++; }

  /* At and above target -> nothing owed (must not return a negative sleep). */
  if (mister_pace_sleep_us(T, T)      != 0)      { printf("FAIL: elapsed == T\n"); fails++; }
  if (mister_pace_sleep_us(T+1, T)    != 0)      { printf("FAIL: elapsed T+1\n"); fails++; }
  if (mister_pace_sleep_us(1000000, T)!= 0)      { printf("FAIL: elapsed huge\n"); fails++; }

  /* Clock went backwards -> 0, NOT a huge sleep that would stall the producer. */
  if (mister_pace_sleep_us(-1, T)     != 0)      { printf("FAIL: elapsed -1\n"); fails++; }
  if (mister_pace_sleep_us(-1000000,T)!= 0)      { printf("FAIL: elapsed very negative\n"); fails++; }

  /* A non-default target behaves identically about its own boundary -- this is the
     frame generator's calibration mode (120 fps = 8333 us), which must run the SAME
     code path as the shipped cap, differing only in this constant. */
  const long T120 = 8333;
  if (mister_pace_sleep_us(0, T120)      != T120){ printf("FAIL: 120fps elapsed 0\n"); fails++; }
  if (mister_pace_sleep_us(T120-1, T120) != 1)   { printf("FAIL: 120fps boundary-1\n"); fails++; }
  if (mister_pace_sleep_us(T120, T120)   != 0)   { printf("FAIL: 120fps at boundary\n"); fails++; }
  if (mister_pace_sleep_us(T120+1, T120) != 0)   { printf("FAIL: 120fps past boundary\n"); fails++; }

  /* The calibration target MUST be shorter than the shipped one, or the control
     mode could not over-produce and the whole calibration argument collapses. */
  if (!(T120 < T)){ printf("FAIL: calibration target not faster than shipped\n"); fails++; }

  if (fails){ printf("pace_test: %d FAIL\n", fails); return 1; }
  printf("pace_test: OK\n"); return 0;
}
```

- [ ] **Step 2: Wire it into the host suite**

In `tests/run_tests.sh`, immediately before the final `echo "All host tests passed."`, add:

```bash
echo "== pace (producer pacing arithmetic: the sole rate guard) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/pace_test.c \
    -o /tmp/pace_test
/tmp/pace_test
```

- [ ] **Step 3: Run the suite to verify it fails**

Run: `bash tests/run_tests.sh 2>&1 | tail -20`
Expected: FAIL at the `pace` step — `fatal error: 'mister_pace.h' file not found`.

- [ ] **Step 4: Write the header**

Create `patches/mister/mister_pace.h`:

```c
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
 * THIS IS THE SOLE RATE GUARD. Since the host-side vblank barrier was retired
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

#endif /* MISTER_PACE_H */
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `bash tests/run_tests.sh 2>&1 | tail -6`
Expected: `pace_test: OK` and `All host tests passed.`

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_pace.h tests/pace_test.c tests/run_tests.sh
git commit -m "feat(pace): extract producer pacing into a pure, unit-tested header

The cap in present() is the sole rate guard since the vblank barrier was retired,
yet it was an inline block with its scan-rate derivation only in a comment -- and
it shipped once with the wrong constant (16667 for a 59.9228 Hz scan). Extracting
it puts the value in one named place with its derivation attached, makes it
reachable by unit tests, and lets the frame generator exercise the SHIPPED logic
rather than a copy.

The target is a parameter so the generator's calibration mode drives a
deliberately-too-fast rate through the identical code path."
```

---

## Task 2: Route `present()` through the extracted helper

Behaviour must be **identical**. This touches code that merged HW-validated days ago; the only acceptable outcome is a pure refactor.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (include block; pacing block at `:4426-4447`)

**Interfaces:**
- Consumes: `MISTER_PACE_TARGET_US`, `mister_pace_sleep_us` (Task 1)
- Produces: nothing new

- [ ] **Step 1: Add the include**

Find the block of `#include "mister_*.h"` lines near the top of `patches/mister/mister_blitter_renderer.cpp` (alongside `mister_blend_layer.h`) and add:

```cpp
#include "mister_pace.h"
```

- [ ] **Step 2: Replace the inline pacing arithmetic**

Find:

```cpp
      // free-running ~60 fps cap (vsync disabled)
      static struct timespec last = {0, 0};
      struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
      if (last.tv_sec != 0 || last.tv_nsec != 0) {
        long dus = (now.tv_sec - last.tv_sec) * 1000000L
                 + (now.tv_nsec - last.tv_nsec) / 1000L;
        // [pacing] The scanout is 59.9228 Hz, NOT 60.00 Hz. Full precision, from
        // fpga/rtl/openbor_video_timing.sv:12-13 (pixel clock 53,693,182 Hz, H total
        // 3420, V total 262 lines): period = 1e6*3420*262/53,693,182 = 16,688.15 us,
        // rounded UP -> 16689. (Deriving from the RTL comment's rounded 15,700 Hz
        // H-freq instead gives 16,687.9 -> 16,688, which is 0.25 us SHORT and would
        // reintroduce drift -- see patches/mister/mister_pace.h.) The old 16,667
        // (60.00 Hz) let the producer gain ~21 us/frame on the scanout, slipping a
        // whole frame every ~795 cap-limited frames -> two snapshots inside one scan
        // period -> a one-frame tear on a ~13 s beat.
        const long target_us = 16689;   // 59.9228 Hz scan period, rounded up
        if (dus >= 0 && dus < target_us) {
          struct timespec ts{0, (target_us - dus) * 1000L};
          nanosleep(&ts, nullptr);
          // [pacing-split] counts toward the timing banner's sleep= but NOT toward
          // t_sleep_barrier_ns: this fires after present-entry, i.e. outside the
          // window t_draw_ns measures.
          d->t_sleep_ns += (long long)(target_us - dus) * 1000LL;
        }
      }
      clock_gettime(CLOCK_MONOTONIC, &last);
```

Replace with:

```cpp
      // free-running scan-rate cap (the SOLE rate guard; see mister_pace.h for the
      // 16689 us derivation and why it must not be raised). The arithmetic lives in
      // that header so the standalone frame generator exercises this exact logic
      // rather than a copy, and so the host suite can unit-test it.
      static struct timespec last = {0, 0};
      struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
      if (last.tv_sec != 0 || last.tv_nsec != 0) {
        const long dus = (now.tv_sec - last.tv_sec) * 1000000L
                       + (now.tv_nsec - last.tv_nsec) / 1000L;
        const long owed = mister_pace_sleep_us(dus, MISTER_PACE_TARGET_US);
        if (owed > 0) {
          struct timespec ts{0, owed * 1000L};
          nanosleep(&ts, nullptr);
          // [pacing-split] counts toward the timing banner's sleep= but NOT toward
          // t_sleep_barrier_ns: this fires after present-entry, i.e. outside the
          // window t_draw_ns measures.
          d->t_sleep_ns += (long long)owed * 1000LL;
        }
      }
      clock_gettime(CLOCK_MONOTONIC, &last);
```

Note the timestamp stays **after** the sleep. That ordering is what makes successive submits ≥ `target_us` apart *by construction*; moving it would silently break the guarantee.

- [ ] **Step 3: Confirm behavioural identity by inspection**

The old branch slept when `dus >= 0 && dus < target_us`, for `target_us - dus`. The new helper returns `0` for `dus < 0`, `0` for `dus >= target_us`, else `target_us - dus`; the caller sleeps only when `owed > 0`. These agree on every input, including `dus == target_us` (no sleep in both). Record this reasoning in the commit.

Inspection is necessary but **not sufficient** for a change to the sole rate guard: **Task 5 Step 5 re-runs the engine A/B on hardware** to prove the refactor is behaviour-neutral. Do not treat this task as fully validated until that step passes.

- [ ] **Step 4: Type-check the renderer**

Run the Global Constraints type-check command. Expected: no output, exit 0.

- [ ] **Step 5: Verify no stray copy of the constant survives**

```bash
grep -n "16689\|16667" patches/mister/mister_blitter_renderer.cpp
```

Expected: **no hits.** The value must exist only in `mister_pace.h`; a second copy is exactly the drift this task removes.

- [ ] **Step 6: Run the host suite**

Run: `bash tests/run_tests.sh 2>&1 | tail -4`
Expected: `All host tests passed.`

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(pace): present() calls the extracted pacing helper

Pure refactor, behaviour identical: the old branch slept when
dus >= 0 && dus < target_us for (target_us - dus); the helper returns 0 for
negative elapsed, 0 at or past target, else the remainder, and the caller sleeps
only when owed > 0. Agrees on every input including dus == target_us.

The timestamp stays AFTER the sleep -- that ordering is what makes successive
submits >= target_us apart by construction.

The constant now exists only in mister_pace.h; verified no copy remains here."
```

---

## Task 3: The frame generator

**Files:**
- Create: `patches/mister/frame_gen/frame_gen.c`
- Create: `scripts/build_frame_gen.sh`

**Interfaces:**
- Consumes: `mister_pace_sleep_us`, `MISTER_PACE_TARGET_US` (Task 1); `blt_emitter_init`, `blt_begin_frame` from `patches/mister/blitter/`
- Produces: `build/armhf/frame_gen`, CLI `frame_gen [--paced | --rate N] [--seconds N]`, exit 0 on PASS / 1 on FAIL

- [ ] **Step 1: Write the generator**

Create `patches/mister/frame_gen/frame_gen.c`:

```c
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

/* Maximum contrast in RGB565: a torn frame shows as a hard horizontal split. */
#define COLOUR_A 0xF800u   /* red  */
#define COLOUR_B 0x001Fu   /* blue */

/* Above this the DDR3 snapshot traffic leaves the regime any real workload occupies;
 * a wedge there is more likely a bus artifact than a pacing finding. */
#define RATE_MAX 240

static volatile uint8_t *g_ddr, *g_vid;

static inline void w32(volatile uint8_t *b, uint32_t o, uint32_t v){ *(volatile uint32_t*)(b+o)=v; }
static inline uint32_t r32(volatile uint8_t *b, uint32_t o){ return *(volatile uint32_t*)(b+o); }

static long now_us(void){
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000000L + t.tv_nsec / 1000L;
}

/* Refuse to run alongside the engine: two producers on one command ring corrupt it. */
static int engine_running(void){
    DIR *d = opendir("/proc"); if(!d) return 0;
    struct dirent *e; char path[64], comm[64]; int found = 0;
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
    int paced = 0, rate = 120, seconds = 60;
    for(int i = 1; i < argc; i++){
        if(!strcmp(argv[i], "--paced")) paced = 1;
        else if(!strcmp(argv[i], "--rate") && i+1 < argc) rate = atoi(argv[++i]);
        else if(!strcmp(argv[i], "--seconds") && i+1 < argc) seconds = atoi(argv[++i]);
        else { usage(argv[0]); return 2; }
    }
    if(!paced && (rate < 1 || rate > RATE_MAX)){
        fprintf(stderr, "rate %d out of range 1..%d — above %d you are characterising the\n"
                        "DDR3 bus, not the pacing, and a wedge must not be read as a pacing result.\n",
                rate, RATE_MAX, RATE_MAX);
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

    const long t_end = now_us() + (long)seconds * 1000000L;
    long last = 0, submits = 0, handshake_fail = 0;
    int colour_is_a = 1;

    while(now_us() < t_end){
        if(last != 0){
            const long owed = mister_pace_sleep_us(now_us() - last, target_us);
            if(owed > 0){
                struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = owed * 1000L;
                nanosleep(&ts, NULL);
            }
        }
        blt_begin_frame(&em, 0, 1, colour_is_a ? COLOUR_A : COLOUR_B);
        blt_end_frame(&em);   /* emits BLT_OP_END — the fabric walks until END */
        colour_is_a = !colour_is_a;
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
```

- [ ] **Step 2: Write the build script**

Create `scripts/build_frame_gen.sh`, modelled on `scripts/build_sdram_selftest.sh`:

```bash
#!/usr/bin/env bash
# Cross-build the on-device fabric frame generator for MiSTer armhf.
# Tiny libc-only binary (no SDL/Solarus deps) -> build/armhf/frame_gen.
#
#   bash scripts/build_frame_gen.sh
#
# Then deploy + run on the device (RBF must be loaded; engine must NOT be running):
#   scp build/armhf/frame_gen root@192.168.20.81:/tmp/
#   ssh root@192.168.20.81 /tmp/frame_gen --rate 120     # calibration (tears: expected)
#   ssh root@192.168.20.81 /tmp/frame_gen --paced        # the gate
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/armhf/frame_gen"
mkdir -p build/armhf

bash scripts/docker_run.sh bash -lc '
  set -e
  arm-linux-gnueabihf-gcc -Wall -Wextra -O2 -static \
    -I patches/mister -I patches/mister/frame_gen -I patches/mister/blitter \
    patches/mister/frame_gen/frame_gen.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o '"$OUT"'
'
echo "built $OUT"
file "$OUT" || true
```

- [ ] **Step 3: Make the build script executable and build**

```bash
chmod +x scripts/build_frame_gen.sh
bash scripts/build_frame_gen.sh
```

Expected: `built build/armhf/frame_gen` and a `file` line reporting `ELF 32-bit LSB executable, ARM, ... statically linked`.

- [ ] **Step 4: Verify the argument guards without hardware**

The binary is armhf so it cannot run on the host. Verify the guards by inspection instead, and confirm the constant is not duplicated:

```bash
grep -n "RATE_MAX\|engine_running\|MISTER_PACE_TARGET_US" patches/mister/frame_gen/frame_gen.c
grep -c "16689" patches/mister/frame_gen/frame_gen.c
```

Expected: `RATE_MAX` bounds `--rate`; `engine_running()` is called before any mmap; `MISTER_PACE_TARGET_US` is used rather than a literal. The second command must print **0** — the generator must never carry its own copy of the scan period.

- [ ] **Step 5: Run the host suite (nothing should regress)**

Run: `bash tests/run_tests.sh 2>&1 | tail -4`
Expected: `All host tests passed.`

- [ ] **Step 6: Commit**

```bash
git add patches/mister/frame_gen/frame_gen.c scripts/build_frame_gen.sh
git commit -m "feat(test): fabric frame generator — drive the compositor at a chosen rate

Standalone armhf binary, sibling of sdram_selftest: libc-only, static, mmaps the
blitter control block and video region, emits alternating full-screen fills
through the real emitter, and compares frames published (vctrl) against frames
displayed (vsync_count).

Two modes on ONE code path differing only in the pacing target: --rate N
(calibration, PASSES on over-production) and --paced (gate, PASSES on
published <= displayed). The inverted calibration verdict is the point: if
driving faster than the scanout does not over-produce, the detector is broken and
a gate pass proves nothing.

Honours the C_DONE handshake as the engine does — without it we would overwrite a
ring the fabric is still reading, producing a wedge rather than a clean test.
Refuses to run alongside solarus-run. Rate ceiling 240."
```

---

## Task 4: Operator runbook and rollout

**Files:**
- Create: `docs/superpowers/plans/2026-07-25-frame-generator-runbook.md`
- Modify: `docs/superpowers/plans/2026-07-25-pacing-and-region-capture-runbook.md`

**Interfaces:**
- Consumes: `build/armhf/frame_gen` (Task 3)
- Produces: the documented procedure that later pacing changes are required to follow

- [ ] **Step 1: Write the runbook**

Create `docs/superpowers/plans/2026-07-25-frame-generator-runbook.md` covering:

**Prerequisites.** Solarus core loaded from `_Other/Solarus_20260724.rbf`. Engine **not** running (`kill -9 $(pidof solarus-run)`; busybox has no `pkill`). Binary deployed: `scp build/armhf/frame_gen root@192.168.20.81:/tmp/`.

**Step 1 — calibration (MUST run first).**
```
ssh root@192.168.20.81 /tmp/frame_gen --rate 120 --seconds 60
```
Expect `published ≈ 7200`, `displayed ≈ 3595`, `ratio ≈ 2.0`, exit 0 and `PASS (calibration)`.
**OPERATOR: confirm the tear is visible** — a hard horizontal split between red and blue. This is the one and only time the visual is tied to the counters; record it. If the tear is *not* visible while the counters report over-production, stop: either the observation or the measurement is wrong, and the gate cannot be trusted until that is resolved.

**Step 2 — the gate.**
```
ssh root@192.168.20.81 /tmp/frame_gen --paced --seconds 60
```
Expect `published ≤ displayed`, exit 0, `PASS (gate)`. Screen should be a clean alternating flash with no tear.

**Interpretation.** A gate pass counts **only** on a build whose calibration passed. State plainly that the counters cannot prove a frame is untorn — a torn frame is still exactly one published frame — so the calibration run's visual confirmation is what licenses the counter verdict to stand in later.

**Failure routing.** Gate FAIL ⇒ the sole rate guard is not holding; do not ship that pacing, and `SOLARUS_VSYNC_BARRIER=1` restores the old barrier as an escape hatch. Calibration FAIL ⇒ the detector is broken; fix that before reading any gate result. Handshake timeouts ⇒ core not loaded or fabric wedged; the run is not interpretable.

**Aftermath.** `--rate` deliberately tears and leaves the display mid-pattern; relaunch the engine. No persistent state — the next `blt_begin_frame` resets the ring.

Record results in `docs/superpowers/data/pacing-ab/` following the format of `overproduction-2026-07-25.md`.

- [ ] **Step 2: Make the gate a required step for future pacing changes**

In `docs/superpowers/plans/2026-07-25-pacing-and-region-capture-runbook.md`, add a section stating that any change touching `mister_pace.h`, `present()`'s pacing, or the scanout timing in `fpga/rtl/openbor_video_timing.sv` must run the frame-generator calibration and gate, and must re-run `scripts/perf/capture_pacing_ab.sh` to confirm the engine-side numbers are unchanged. Note explicitly that this is the mechanical check that would have caught the 16667/16689 error without anyone re-deriving the scan rate from RTL.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/
git commit -m "docs(runbook): frame-generator procedure + make it a required pacing gate

Calibration before gate, with the operator tying the visible tear to the counters
once so the counter verdict can stand in for the visual on later regressions.
Records the limit plainly: the counters cannot prove a frame is untorn.

Makes the generator a required step for any future change to mister_pace.h,
present()'s pacing, or the scanout timing -- the mechanical check that would have
caught the wrong scan-period constant without an RTL review."
```

---

## Task 5: On-device validation

Runs the procedure Task 4 documents. This is the task that closes PR #151's recorded gap.

**Files:**
- Create: `docs/superpowers/data/pacing-ab/frame-gen-validation-2026-07-25.md`

**Interfaces:**
- Consumes: everything above
- Produces: the validation record

- [ ] **Step 1: Build and deploy the binary**

```bash
bash scripts/build_frame_gen.sh
scp build/armhf/frame_gen root@192.168.20.81:/tmp/
```

- [ ] **Step 2: Ensure the core is loaded and the engine is stopped**

```bash
ssh root@192.168.20.81 'pidof solarus-run && kill -9 $(pidof solarus-run); ls /media/fat/_Other/Solarus_20260724.rbf'
```

If the core is not currently loaded, load it (`echo "load_core /media/fat/_Other/Solarus_20260724.rbf" > /dev/MiSTer_cmd`) and allow it to settle.

- [ ] **Step 3: Run the calibration**

```bash
ssh root@192.168.20.81 '/tmp/frame_gen --rate 120 --seconds 60'; echo "exit=$?"
```

Expected: `ratio ≈ 2.0`, `PASS (calibration)`, exit 0. **Ask the operator to confirm the tear was visible** — this cannot be self-declared.

- [ ] **Step 4: Run the gate**

```bash
ssh root@192.168.20.81 '/tmp/frame_gen --paced --seconds 60'; echo "exit=$?"
```

Expected: `published ≤ displayed`, `PASS (gate)`, exit 0.

- [ ] **Step 5: Prove the Task 2 extraction is behaviour-neutral (engine A/B)**

Task 2 refactored the **sole rate guard**; inspection alone is not sufficient evidence for that. Rebuild and deploy the engine, then re-run the A/B and compare against the pre-extraction record in `docs/superpowers/data/pacing-ab/leg-B-freerun.txt`:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister-pacing
scripts/apply_patch_series.sh
scripts/docker_run.sh scripts/build_engine.sh
cp build/armhf/solarus-run deploy/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
./deploy.py --no-rbf
scripts/perf/capture_pacing_ab.sh
```

Expected, unchanged from the pre-extraction capture: leg B `fps ≈ 37.5`, `sleep=0.0`, `clear≈0.2`, `vblank=0.0`; leg A `fps ≈ 26.3`, `sleep ≈ 10 ms`. Also confirm `[blitter hwperf] fabric_hw` is ≈16.4-16.9 ms in both legs.

**If leg B's fps or `sleep` moved, STOP** — the refactor changed the sole rate guard and must be reverted or corrected before anything else on this branch is trusted. A moved `fabwait` is expected and is not by itself a failure (removing a sleep makes the A9 reach the handshake earlier); `fabric_hw` is the invariant.

- [ ] **Step 6: Record the results**

Write `docs/superpowers/data/pacing-ab/frame-gen-validation-2026-07-25.md` with both runs' full output, the operator's visual verdict on the calibration run, the engine sha1 and RBF name, and an explicit statement of whether PR #151's recorded gap ("the cap has never clamped anything") is now closed.

If the gate passes, this is the first evidence that the cap actually clamps. Say so plainly, and update `docs/superpowers/data/pacing-ab/overproduction-2026-07-25.md`'s "KNOWN GAP" section to point at this file.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/data/pacing-ab/
git commit -m "data(hw): frame-generator validation — cap clamping exercised

First evidence that the pacing cap actually clamps: every scene measured
previously sat below the scan rate, so safety came from the engine not being fast
enough rather than from the guard under test. Calibration run confirms the
counters detect over-production (and the operator confirmed the tear is visible),
which is what licenses the gate result."
```

---

## Post-implementation

Use `superpowers:finishing-a-development-branch` to decide on merge/PR. The PR body should state that this closes the gap recorded in PR #151 and that the generator is now a required gate for pacing changes.

If the gate FAILS, that is a significant finding, not a task failure: it would mean the sole rate guard does not hold at rates the engine may eventually reach. Stop, record the evidence, and treat it as a defect in the shipped pacing rather than in this harness.
