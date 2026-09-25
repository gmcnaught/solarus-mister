#ifndef MISTER_FRAMELOG_H
#define MISTER_FRAMELOG_H
/* [fps-dip harness] Per-iteration frame log (SOLARUS_FRAMELOG=<path>).
 *
 * One 64-byte record per MainLoop::run iteration, written in 128-record blocks to
 * <path> (put it on tmpfs: /media/fat is mounted sync, every write there is an SD
 * write). Off = one branch per iteration. Analysis: scripts/fpsdip/frames.py.
 *
 * Record timeline for iteration i (all CLOCK_MONOTONIC):
 *   t0 | input_us | update_us (num_updates x step()) | draw_us (MainLoop::draw,
 *   includes the renderer's fabric wait and present pacing) | sleep_us (MainLoop's
 *   own timestep sleep) -> t0 of iteration i+1.
 * Inside draw_us the renderer reports fab_us (ensure_frame C_DONE wait = the fabric
 * still compositing the frame two submits ago) and pace_us (present()'s scan-rate cap
 * sleep). lua_us is wall time with a Lua call on the stack, anywhere in the iteration.
 * vsync = the scanout's vblank counter (0x3A070000) read right after the submit
 * doorbell; consecutive differences give the displayed-frame cadence.
 *
 * Header is shared by MainLoop.cpp (writer, inline below) and the renderer (the
 * per-frame counters, defined in mister_blitter_renderer.cpp). */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint64_t t0_us;       /* iteration start, CLOCK_MONOTONIC us */
  uint32_t input_us;    /* check_input() */
  uint32_t update_us;   /* all step() calls this iteration */
  uint32_t draw_us;     /* draw() incl. present */
  uint32_t sleep_us;    /* MainLoop timestep sleep */
  uint32_t fab_us;      /* renderer: C_DONE wait (fabric busy) */
  uint32_t pace_us;     /* renderer: present() scan-rate cap sleep */
  uint32_t lua_us;      /* Lua VM wall time */
  uint32_t cpu_us;      /* main-thread CPU time (CLOCK_THREAD_CPUTIME_ID) */
  uint32_t vsync;       /* scanout vblank counter after the submit */
  uint32_t upload_px;   /* surface pixels uploaded/re-uploaded this frame */
  uint16_t steps;       /* num_updates */
  uint16_t nvcsw;       /* voluntary context switches (thread) */
  uint16_t nivcsw;      /* involuntary context switches (thread) */
  uint16_t minflt;
  uint16_t majflt;
  uint16_t map_idx;     /* index into the maps sidecar (<path>.maps), 0xFFFF = no map */
  uint16_t cmds;        /* blitter commands submitted this frame */
  uint16_t flags;       /* MISTER_FL_* */
} MisterFrameRec;

#define MISTER_FL_GAME       0x0001u  /* a game is running */
#define MISTER_FL_SUSPENDED  0x0002u  /* Game::is_suspended() */
#define MISTER_FL_DIALOG     0x0004u
#define MISTER_FL_PAUSED     0x0008u
#define MISTER_FL_TRANSITION 0x0010u  /* map transition in progress */
#define MISTER_FL_GAMEOVER   0x0020u
#define MISTER_FL_LAGDROP    0x0040u  /* MainLoop dropped >=200 ms of lag this iteration */
#define MISTER_FL_MAPCHANGE  0x0080u  /* map id differs from the previous iteration */
#define MISTER_FL_NOSUBMIT   0x0100u  /* no frame submitted this iteration */

/* Renderer side (mister_blitter_renderer.cpp). Returns and zeroes the per-frame
 * accumulators; *submitted = frames submitted since the last take. */
void mister_framelog_take(uint32_t* fab_us, uint32_t* pace_us, uint32_t* upload_px,
                          uint32_t* cmds, uint32_t* vsync, uint32_t* submitted);
/* Arms the renderer's framelog-only counters (and Lua VM timing). */
void mister_framelog_arm(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#ifdef __cplusplus
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <string>
#include <unordered_map>

/* Writer state for MainLoop.cpp (single TU). */
struct MisterFrameLog {
  FILE* f = nullptr;
  FILE* maps = nullptr;
  MisterFrameRec buf[128];
  int n = 0;
  std::unordered_map<std::string, uint16_t> map_ids;
  uint16_t last_map = 0xFFFFu;

  static MisterFrameLog& get() { static MisterFrameLog l; return l; }

  bool open() {
    const char* p = getenv("SOLARUS_FRAMELOG");
    if (!p || !*p) return false;
    f = fopen(p, "wb");
    if (!f) return false;
    std::string mp = std::string(p) + ".maps";
    maps = fopen(mp.c_str(), "w");
    mister_framelog_arm();
    return true;
  }
  uint16_t map_index(const std::string& id) {
    auto it = map_ids.find(id);
    if (it != map_ids.end()) return it->second;
    uint16_t idx = (uint16_t)map_ids.size();
    map_ids.emplace(id, idx);
    if (maps) { fprintf(maps, "%u %s\n", (unsigned)idx, id.c_str()); fflush(maps); }
    return idx;
  }
  void push(const MisterFrameRec& r) {
    buf[n++] = r;
    if (n == 128) flush();
  }
  void flush() {
    if (f && n) { fwrite(buf, sizeof(MisterFrameRec), (size_t)n, f); fflush(f); }
    n = 0;
  }
};

static inline uint64_t mister_fl_now_us() {
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}
static inline uint64_t mister_fl_cpu_us() {
  struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}
static inline uint16_t mister_fl_sat16(long v) {
  return v < 0 ? 0 : (v > 0xFFFF ? 0xFFFF : (uint16_t)v);
}
#endif /* __cplusplus */

#endif /* MISTER_FRAMELOG_H */
