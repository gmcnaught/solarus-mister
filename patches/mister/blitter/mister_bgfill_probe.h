#ifndef MISTER_BGFILL_PROBE_H
#define MISTER_BGFILL_PROBE_H
/* [Phase 0 probe] Pure helper for SOLARUS_BGFILLPROBE. Given a static bucket's
 * entries, pick the pid covering the largest total area and its bounding box, so
 * the renderer can collapse a big single-pattern background fill (ground / parallax
 * sky) into one BLT_OP_FILL for a fabric-time attribution measurement. Area-based
 * (not count-based) so it is robust whether entries are per-8px-cell or coalesced
 * into larger rects. Header-only: no renderer/SDL deps, unit-testable on the host. */
#include <stddef.h>

typedef struct { int dx, dy, w, h; unsigned short pid; } bgfill_ent_t;

static inline int bgfill_pick(const bgfill_ent_t *ents, unsigned long n,
                              unsigned long area_min, unsigned short *out_pid,
                              int *x0, int *y0, int *x1, int *y1) {
    /* Two-pass over pids without a hash map: find the max-total-area pid by scanning.
     * n is small (a few thousand); O(n) per distinct pid is fine for a diagnostic. */
    unsigned long best_area = 0; int have_best = 0; unsigned short best_pid = 0;
    for (unsigned long i = 0; i < n; ++i) {
        unsigned short pid = ents[i].pid;
        if (pid == 0xFFFFu) continue;                 /* tokenless: never a fill */
        /* Only tally a pid the first time we see it (avoid double-counting). */
        int seen = 0;
        for (unsigned long j = 0; j < i; ++j)
            if (ents[j].pid == pid) { seen = 1; break; }
        if (seen) continue;
        unsigned long area = 0;
        for (unsigned long j = i; j < n; ++j)
            if (ents[j].pid == pid)
                area += (unsigned long)ents[j].w * (unsigned long)ents[j].h;
        if (!have_best || area > best_area) { have_best = 1; best_area = area; best_pid = pid; }
    }
    if (!have_best || best_area < area_min) return 0;
    int bx0 = 0, by0 = 0, bx1 = 0, by1 = 0, first = 1;
    for (unsigned long i = 0; i < n; ++i) {
        if (ents[i].pid != best_pid) continue;
        int ex0 = ents[i].dx, ey0 = ents[i].dy;
        int ex1 = ents[i].dx + ents[i].w, ey1 = ents[i].dy + ents[i].h;
        if (first) { bx0=ex0; by0=ey0; bx1=ex1; by1=ey1; first=0; }
        else {
            if (ex0 < bx0) bx0 = ex0;
            if (ey0 < by0) by0 = ey0;
            if (ex1 > bx1) bx1 = ex1;
            if (ey1 > by1) by1 = ey1;
        }
    }
    *out_pid = best_pid; *x0 = bx0; *y0 = by0; *x1 = bx1; *y1 = by1;
    return 1;
}
#endif /* MISTER_BGFILL_PROBE_H */
