/*
 * [MiSTer #26] Lua-VM time profiler — splits the per-frame update() tick into
 * "time inside the Lua VM" vs "pure C++ engine work".
 *
 * The a9split "lua" phase in mister_blitter_renderer.cpp actually measures the
 * WHOLE update() tick (C++ entity/collision/movement + Lua callbacks). To learn
 * which dominates the residual ~22ms standing A9 cost, we time the wall-clock
 * spent with at least one Lua call on the stack.
 *
 * All per-frame Lua dispatch funnels through LuaTools::call_function ->
 * lua_pcall (other lua_pcall sites are load-time only: quest/map/savegame data).
 * We bracket that single pcall. A thread-local depth guard ensures only the
 * OUTERMOST call measures, so nested Lua->C-API->Lua re-entries are counted once
 * (as "wall time with >=1 Lua frame live") rather than double-counted.
 *
 * Zero cost when diag is off (one branch on g_mister_lua_diag, set by the
 * renderer from SOLARUS_BLITTER_DIAG at construction).
 */
#ifndef MISTER_LUA_PROF_H
#define MISTER_LUA_PROF_H

#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Sum of wall-ns spent inside the outermost Lua call (per process; the renderer
 * snapshots a per-60fr-window delta). Defined in mister_blitter_renderer.cpp. */
extern volatile long long g_mister_lua_vm_ns;
/* Set to 1 by the renderer when SOLARUS_BLITTER_DIAG is enabled. */
extern volatile int       g_mister_lua_diag;

#ifdef __cplusplus
}  /* extern "C" */

/* One thread-local re-entrancy depth, shared by enter/exit. */
inline int& mister_lua_prof_depth() { static thread_local int d = 0; return d; }

/* Call immediately before lua_pcall. Writes *t0 and returns true iff this is the
 * outermost Lua call (the one that should measure). */
inline bool mister_lua_prof_enter(struct timespec* t0) {
  if (!g_mister_lua_diag) return false;
  if (mister_lua_prof_depth()++ == 0) {
    clock_gettime(CLOCK_MONOTONIC, t0);
    return true;
  }
  return false;
}

/* Call immediately after lua_pcall, passing the enter() result + the same t0. */
inline void mister_lua_prof_exit(bool outer, const struct timespec* t0) {
  if (!g_mister_lua_diag) return;
  if (--mister_lua_prof_depth() == 0 && outer) {
    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    g_mister_lua_vm_ns += (long long)(t1.tv_sec - t0->tv_sec) * 1000000000LL
                        + (long long)(t1.tv_nsec - t0->tv_nsec);
  }
}
#endif /* __cplusplus */

#endif /* MISTER_LUA_PROF_H */
