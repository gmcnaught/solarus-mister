# Retained-Scene Stage 2 — SpriteChannel / `OP_SPRITELIST` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offload camera-surface sprite blits through a new clean fabric lane —
`OP_SPRITELIST` — that reuses none of the bug-prone `resident`/`bgplane` machinery, and
that rehearses the expanding-op pattern Stage 3 needs to delete those subsystems.

**Architecture:** A new expanding ring opcode (10) emitted **in-band, at layer end**,
reading a sprite-record array from its **own DDR buffer** (`SP_BUF`, not `TL_BUF`). The
fabric decodes it, iterates entries, and joins the existing `S_TL_ISSUE`/`S_TL_WAIT`
cull-issue-await loop feeding `comp_pipeline`. Sprites stay in the ordered ring, so
per-layer Z-order is unchanged by construction. Host side is a `SpriteChannel` buffer
gated by `SOLARUS_SPRITECH`, with a bounded cap and a logged drop count.

**Tech Stack:** C++17 (engine, armhf cross via Docker), C99 (`patches/mister/blitter/`
emitter + reference model), SystemVerilog (`fpga/rtl/`), bash test harnesses.

**Design spec:** `docs/superpowers/specs/2026-07-19-retained-scene-stage2-sprite-channel-design.md`

---

## Global Constraints

- **Build inside the container:** `scripts/docker_run.sh bash scripts/build_engine.sh`.
  Running on the host writes a host-path `CMakeCache.txt` that then blocks the container
  build. **Grep `BUILD_EXIT`** in the output — do not trust the task's exit code.
- **Gate flag `SOLARUS_SPRITECH` is presence-based**, like every flag in this renderer:
  `getenv(...) != nullptr`. `SOLARUS_SPRITECH=0` **still ENABLES it**; it must be
  **absent** to disable. State this in the log line and the validation record.
- **New gates ship default OFF**, flipped in a separate later commit.
- **Host tests gate CI only via `patches/mister/build_host_tests.sh`.**
  `tests/run_tests.sh` is referenced by no workflow — adding a test there does not gate CI.
- **Deploy ships from `deploy/libs/`** and requires **on-device sha1 verification**.
  `deploy.py` exit 0 says nothing about which files moved.
- **Never self-declare visual correctness.** Objective signals or the operator's eyes.
- **Wire format must stay in lockstep across three places:** `patches/mister/blitter/`
  (host + ref), `fpga/rtl/blitter_defs.vh`, `fpga/rtl/blitter_top.sv`.
- **Do not reintroduce negative slack.** A passing RBF is *not* passing timing.
- **Existing upload path is reused unchanged** — no clean-laning of
  `upload()`/`handles`/INTER staging/`blt_alloc` in this plan.

### Wire conventions to follow (existing, do not invent new ones)

Expanding ops pack their header identically (`blitter_ref.h:57-83`):
- `w | h<<16` = entry count N (u32)
- `dst_x | dst_y<<16` = entry-array byte offset
- `src_x` / `src_y` = signed per-batch dst bias added to every entry's dst
- `blend_mode` / `format` / `flags` / `alpha` / `colorkey` = shared across the batch

Free FSM state codes in `blitter_top.sv` (`reg [5:0] state`, highest used `S_CLUT_WR=57`):
roughly **14, 27–29, 31, 40–41, 58–63**. This plan uses **58–61**.

---

## RESOLVED DESIGN POINT — read before Task 1

The design spec says "one `OP_SPRITELIST` per layer." **That is not achievable as stated,
and the plan corrects it.**

`OP_TILELIST`/`OP_TILELIST_RES` share **one texture** across the whole batch (header
`src_off`/`src_stride`). Tiles can do this because a layer's tiles come from one tileset.
**Sprites cannot** — a layer's sprites come from many different sprite sheets, Y-sorted, so
consecutive sprites routinely differ in source surface, and may differ in blend/format.

**Resolution: per-entry source offset; header carries the rest.**

- Entry = **16 bytes, qword-aligned** (§spec 4.2 requires alignment):
  `{u32 src_off; u16 src_x, src_y, w, h; i16 dst_x, dst_y}` = 4 + 8 + 4 = 16.
  Two qwords per entry, single aligned fetch pair — no 3-qword unaligned window + barrel
  shift (`blitter_top.sv:334-336`).
- Header carries the fields that are genuinely shared: `src_stride`, `format`,
  `blend_mode`, `alpha`, `colorkey`, `flags`.
- The host therefore emits **one `OP_SPRITELIST` per uniform run** within a layer, where a
  run breaks when `(src_stride, format, blend, alpha, colorkey, flags)` changes. Runs are
  consecutive, so **emission order — and therefore Z-order — is preserved exactly**.

**Consequence to state honestly in the validation record:** the collapse is N sprites →
*few* commands per layer, not exactly one. Task 3's diagnostics measure the real run count
so the win is reported from data, not from this estimate.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `patches/mister/blitter/blt_wire.h` | `blt_sprite_entry_t` wire struct + pack helper | 2 |
| `patches/mister/blitter/blitter_ref.h` | `BLT_OP_SPRITELIST = 10` + doc block | 2 |
| `patches/mister/blitter/blitter_ref.c` | reference execution of the opcode | 2 |
| `patches/mister/blitter/blt_emitter.h` | `blt_sprite_list_init()`, `blt_sprite_list()` | 3 |
| `patches/mister/blitter/blt_emitter.c` | emitter impl + `SP_BUF` accounting + drop counter | 1, 3 |
| `patches/mister/mister_blitter_renderer.cpp` | counters, `SpriteChannel`, gate, INTER log | 1, 4, 5 |
| `patches/mister/build_test_spritelist.sh` | host test: ref-model FB equivalence | 2, 3, 4 |
| `patches/mister/build_host_tests.sh` | register the new test (CI gate) | 2 |
| `fpga/rtl/blitter_defs.vh` | opcode + `SP_BUF` region constants | 6 |
| `fpga/rtl/blitter_top.sv` | `sprite_unit` decode + fetch/latch states | 6 |
| `fpga/sim/tb_spritelist.sv` | RTL sim: expansion vs reference | 6 |
| `docs/superpowers/2026-07-19-stage2-hw-validation.md` | HW record incl. #122/#123 A/B | 7 |

---

## Task 1: Honest counters + the ring-drop counter

Lands first (spec §4.1). Contains the one unambiguous bug the investigation found:
`emit()` drops commands silently while `present()` submits the frame anyway.

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h` (add `dropped` field)
- Modify: `patches/mister/blitter/blt_emitter.c:98-105` (count the drop)
- Modify: `patches/mister/mister_blitter_renderer.cpp:689-704` (split counters), `:3967-3982` (log), `:4279-4288` (reset)
- Test: `patches/mister/blitter/blt_emitter.c` self-test (`-DBLT_EMITTER_SELFTEST`)

**Interfaces:**
- Consumes: nothing.
- Produces: `e->dropped` (`uint32_t`, cumulative dropped commands, reset by
  `blt_begin_frame`); renderer counter `g_sprite_blits` (`long`, true individual
  camera-surface blits) and `g_tile_blits` (`long`, batched tile entries + plane COPYs).

- [ ] **Step 1: Write the failing self-test**

In `patches/mister/blitter/blt_emitter.c`, inside the existing `BLT_EMITTER_SELFTEST`
`main()`, append:

```c
    /* Ring-overflow drops must be COUNTED, not silent. */
    {
        blt_emitter_t e2;
        static uint8_t ring2[BLT_CMD_BYTES * 4];
        blt_emitter_init(&e2, ring2, sizeof ring2, NULL, 0);
        blt_begin_frame(&e2, 0, 0, 0, 0, 0);
        int rc = 0;
        for (int i = 0; i < 32; i++)
            rc |= blt_fill(&e2, 0, 0, 1, 1, 0);
        if (rc == 0)          { printf("FAIL: expected overflow\n");            return 1; }
        if (e2.overflow != 1) { printf("FAIL: overflow flag not set\n");         return 1; }
        if (e2.dropped == 0)  { printf("FAIL: dropped not counted (%u)\n", e2.dropped); return 1; }
        printf("ok: ring drops counted (%u dropped)\n", e2.dropped);
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
cc -std=c99 -Wall -DBLT_EMITTER_SELFTEST -I patches/mister/blitter \
   patches/mister/blitter/blt_emitter.c -o /tmp/blt_selftest && /tmp/blt_selftest
```
Expected: **compile error** — `blt_emitter_t` has no member `dropped`.

- [ ] **Step 3: Add the field**

In `patches/mister/blitter/blt_emitter.h`, in `struct blt_emitter_t` next to `overflow`:

```c
    uint32_t dropped;    /* commands lost to ring-full this frame (reset per frame).
                          * present() still submits, so this MUST be reported: a
                          * non-zero value means the frame is missing content. */
```

- [ ] **Step 4: Count the drop and reset it per frame**

In `patches/mister/blitter/blt_emitter.c`, in `emit()` (around `:98-105`), change the
overflow branch:

```c
    if (pos + BLT_CMD_BYTES > e->ring_cap) { e->overflow = 1; e->dropped++; return -1; }
```

In `blt_begin_frame()`, alongside the existing `e->overflow = 0;`, add:

```c
    e->dropped = 0;
```

- [ ] **Step 5: Run the self-test to verify it passes**

```bash
cc -std=c99 -Wall -DBLT_EMITTER_SELFTEST -I patches/mister/blitter \
   patches/mister/blitter/blt_emitter.c -o /tmp/blt_selftest && /tmp/blt_selftest
```
Expected: `ok: ring drops counted (28 dropped)` and overall PASS.

- [ ] **Step 6: Split the conflated renderer counter**

In `patches/mister/mister_blitter_renderer.cpp`, near the counter declarations (`:689`):

```cpp
    long g_sprite_blits = 0;   /* individual camera-surface blits (draw() case 2) */
    long g_tile_blits   = 0;   /* batched tile entries + bgplane plane COPYs      */
```

Retarget the six existing `g_alias_blits` sites:
- `:2586` (camera-alias `emit_draw`) → `d->g_sprite_blits++`
- `:3287`, `:3316` (`+= entries.size()`) → `d->g_tile_blits += ...`
- `:3618`, `:3641` (`+= b.hw_count`) → `d->g_tile_blits += ...`
- `:3865` (bgplane windowed COPY) → `d->g_tile_blits++`

Keep `g_alias_blits` as the plain sum so existing log-scraping still works:

```cpp
    const long g_alias_blits = d->g_sprite_blits + d->g_tile_blits;
```

- [ ] **Step 7: Report both plus drops in the 60-frame diag line**

In the `[blitter diag]` format string (`:3969-3974`) append
` sprite_blits=%ld tile_blits=%ld dropped=%u`, and add the matching args
(`:3975-3982`): `d->g_sprite_blits, d->g_tile_blits, d->em.dropped`.

Reset the two new counters where the others reset (`:4279-4288`).

- [ ] **Step 8: Type-check the renderer natively**

```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo SYNTAX_OK
```
Expected: `SYNTAX_OK`

- [ ] **Step 9: Run the full host test suite**

```bash
bash patches/mister/build_host_tests.sh
```
Expected: `== all host tests passed ==`

- [ ] **Step 10: Commit**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c \
        patches/mister/mister_blitter_renderer.cpp
git commit -m "fix(blitter): count ring-overflow drops; split sprite vs tile blit counters

emit() dropped commands silently while present() submitted the frame
anyway, so a frame could lose arbitrary world content with no signal.
Add e->dropped and report it.

g_alias_blits conflated individual camera blits with tile entries at
record time, entries at emit time, and plane COPYs — six sites, three
different units. Split into g_sprite_blits and g_tile_blits; keep the
old name as their sum."
```

---

## Task 2: Wire format + reference model for `OP_SPRITELIST`

The reference model is the host-side contract (`blitter_ref.h:5-13`) and **must** execute
the opcode, or the op has no host test (spec §3).

**Files:**
- Modify: `patches/mister/blitter/blt_wire.h`, `blitter_ref.h`, `blitter_ref.c`
- Create: `patches/mister/build_test_spritelist.sh`
- Modify: `patches/mister/build_host_tests.sh`

**Interfaces:**
- Consumes: Task 1's emitter (unchanged API).
- Produces: `BLT_OP_SPRITELIST = 10`; `blt_sprite_entry_t {uint32_t src_off; uint16_t
  src_x, src_y, w, h; int16_t dst_x, dst_y;}` (16 bytes LE); `void
  blt_pack_sprite_entry(uint8_t *dst16, const blt_sprite_entry_t *e)`.

- [ ] **Step 1: Write the failing test harness**

Create `patches/mister/build_test_spritelist.sh`:

```bash
#!/usr/bin/env bash
# Stage 2: OP_SPRITELIST reference-model equivalence.
# A sprite list must paint the SAME framebuffer as the equivalent N OP_BLITs.
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I blitter \
   blitter/blitter_ref.c blitter/blt_emitter.c \
   test_spritelist.c -o /tmp/test_spritelist
/tmp/test_spritelist
```

Create `patches/mister/test_spritelist.c`:

```c
/* Stage 2 acceptance: executing N OP_BLITs and one OP_SPRITELIST covering the
 * same sprites must produce bit-identical framebuffers. GPL-3.0. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "blitter_ref.h"
#include "blt_wire.h"

#define TEXW 32
#define TEXH 32

static uint16_t tex[TEXW * TEXH];
static uint16_t fb_a[BLT_FB_WIDTH * BLT_FB_HEIGHT];
static uint16_t fb_b[BLT_FB_WIDTH * BLT_FB_HEIGHT];

struct spr { uint16_t sx, sy, w, h; int16_t dx, dy; };

/* Deliberately overlapping so ORDER is observable in the output. */
static const struct spr SPR[] = {
    {  0,  0, 16, 16,  10,  10 },
    {  8,  8, 16, 16,  18,  14 },
    { 16,  0,  8,  8,  20,  20 },
    {  0, 16, 16,  8,  12,  24 },
    { 16, 16, 16, 16,   0,   0 },
};
#define NSPR ((int)(sizeof SPR / sizeof SPR[0]))

int main(void)
{
    for (int i = 0; i < TEXW * TEXH; i++) tex[i] = (uint16_t)(i * 7 + 1);

    blt_ref_ctx_t c;

    /* A: N individual OP_BLITs, in order. */
    blt_ref_init(&c, fb_a, tex, sizeof tex, TEXW * 2);
    for (int i = 0; i < NSPR; i++)
        blt_ref_blit(&c, 0, TEXW * 2, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
                     SPR[i].dx, SPR[i].dy, BLT_BLEND_COPY, BLT_FMT_RGB565);

    /* B: one OP_SPRITELIST over the same sprites, same order. */
    static uint8_t spbuf[NSPR * 16];
    for (int i = 0; i < NSPR; i++) {
        blt_sprite_entry_t e = { 0, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
                                 SPR[i].dx, SPR[i].dy };
        blt_pack_sprite_entry(spbuf + i * 16, &e);
    }
    blt_ref_init(&c, fb_b, tex, sizeof tex, TEXW * 2);
    blt_ref_sprite_list(&c, spbuf, NSPR, TEXW * 2, BLT_BLEND_COPY, BLT_FMT_RGB565, 0, 0);

    if (memcmp(fb_a, fb_b, sizeof fb_a) != 0) {
        for (int i = 0; i < BLT_FB_WIDTH * BLT_FB_HEIGHT; i++)
            if (fb_a[i] != fb_b[i]) {
                printf("FAIL: first diff at px %d (%d,%d): blits=%04x list=%04x\n",
                       i, i % BLT_FB_WIDTH, i / BLT_FB_WIDTH, fb_a[i], fb_b[i]);
                return 1;
            }
    }
    printf("ok: OP_SPRITELIST == %d x OP_BLIT (bit-exact framebuffer)\n", NSPR);
    return 0;
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash patches/mister/build_test_spritelist.sh
```
Expected: compile error — `blt_sprite_entry_t`, `blt_pack_sprite_entry`,
`blt_ref_sprite_list` undeclared.

> If `blt_ref_init` / `blt_ref_blit` signatures differ from those assumed above, adapt the
> harness to the real ones in `blitter_ref.h` — the *assertion* (bit-identical `fb_a` vs
> `fb_b`) is what matters and must not be weakened.

- [ ] **Step 3: Add the wire struct**

In `patches/mister/blitter/blt_wire.h`:

```c
/* [Stage 2] Sprite-list entry: 16 bytes, QWORD-ALIGNED (two qwords) so the fabric
 * reads it with an aligned pair of fetches — no 3-qword unaligned window + barrel
 * shift like the 12-byte blt_tile_entry_t needs. Unlike tiles, sprites do NOT share
 * one texture, so src_off is PER ENTRY; stride/format/blend stay in the header. */
typedef struct {
    uint32_t src_off;              /* source surface base offset                  */
    uint16_t src_x, src_y, w, h;   /* source rect                                 */
    int16_t  dst_x, dst_y;         /* dst, header bias added by the fabric        */
} blt_sprite_entry_t;

static inline void blt_pack_sprite_entry(uint8_t *d, const blt_sprite_entry_t *e)
{
    d[0]=(uint8_t)(e->src_off); d[1]=(uint8_t)(e->src_off>>8);
    d[2]=(uint8_t)(e->src_off>>16); d[3]=(uint8_t)(e->src_off>>24);
    d[4]=(uint8_t)(e->src_x); d[5]=(uint8_t)(e->src_x>>8);
    d[6]=(uint8_t)(e->src_y); d[7]=(uint8_t)(e->src_y>>8);
    d[8]=(uint8_t)(e->w);     d[9]=(uint8_t)(e->w>>8);
    d[10]=(uint8_t)(e->h);    d[11]=(uint8_t)(e->h>>8);
    d[12]=(uint8_t)(e->dst_x);d[13]=(uint8_t)((uint16_t)e->dst_x>>8);
    d[14]=(uint8_t)(e->dst_y);d[15]=(uint8_t)((uint16_t)e->dst_y>>8);
}
```

- [ ] **Step 4: Add the opcode**

In `patches/mister/blitter/blitter_ref.h`, after `BLT_OP_CLUT_UPLOAD = 9`:

```c
    BLT_OP_SPRITELIST = 10, /* [Stage 2] ordered camera-surface sprite batch.        *
                          * SAME header packing as BLT_OP_TILELIST:                  *
                          *   w | h<<16        = entry count N                       *
                          *   dst_x | dst_y<<16= entry-array byte offset (SP_BUF)    *
                          *   src_x/src_y      = signed per-batch dst bias           *
                          *   src_stride/format/blend/alpha/colorkey/flags = shared  *
                          * Each entry is a 16-byte blt_sprite_entry_t carrying its   *
                          * OWN src_off — sprites do not share one texture the way    *
                          * a tileset layer does. Entries composite in array order,   *
                          * so Z-order == emission order.                             */
```

Declare the reference executor:

```c
/* [Stage 2] Execute a sprite list: N 16-byte blt_sprite_entry_t at `entries`. */
void blt_ref_sprite_list(blt_ref_ctx_t *c, const uint8_t *entries, int n,
                         uint32_t src_stride, uint8_t blend, uint8_t format,
                         int16_t bias_x, int16_t bias_y);
```

- [ ] **Step 5: Implement it in the reference model**

In `patches/mister/blitter/blitter_ref.c`:

```c
void blt_ref_sprite_list(blt_ref_ctx_t *c, const uint8_t *entries, int n,
                         uint32_t src_stride, uint8_t blend, uint8_t format,
                         int16_t bias_x, int16_t bias_y)
{
    for (int i = 0; i < n; i++) {
        const uint8_t *p = entries + (size_t)i * 16;
        uint32_t src_off = (uint32_t)p[0] | ((uint32_t)p[1] << 8)
                         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
        uint16_t sx = (uint16_t)(p[4]  | (p[5]  << 8));
        uint16_t sy = (uint16_t)(p[6]  | (p[7]  << 8));
        uint16_t w  = (uint16_t)(p[8]  | (p[9]  << 8));
        uint16_t h  = (uint16_t)(p[10] | (p[11] << 8));
        int16_t  dx = (int16_t) (p[12] | (p[13] << 8));
        int16_t  dy = (int16_t) (p[14] | (p[15] << 8));
        blt_ref_blit(c, src_off, src_stride, sx, sy, w, h,
                     (int16_t)(dx + bias_x), (int16_t)(dy + bias_y), blend, format);
    }
}
```

Also add `case BLT_OP_SPRITELIST:` to the reference's command-walk switch, decoding the
header per the convention above and calling `blt_ref_sprite_list`.

- [ ] **Step 6: Run the test to verify it passes**

```bash
bash patches/mister/build_test_spritelist.sh
```
Expected: `ok: OP_SPRITELIST == 5 x OP_BLIT (bit-exact framebuffer)`

- [ ] **Step 7: Register it in the CI gate**

In `patches/mister/build_host_tests.sh`, add to the comment block
`#   - build_test_spritelist.sh : Stage 2 OP_SPRITELIST ref-model FB equivalence`
and add before the final `echo`:

```bash
bash build_test_spritelist.sh
```

- [ ] **Step 8: Run the full suite**

```bash
bash patches/mister/build_host_tests.sh
```
Expected: `== all host tests passed ==`

- [ ] **Step 9: Commit**

```bash
git add patches/mister/blitter/blt_wire.h patches/mister/blitter/blitter_ref.h \
        patches/mister/blitter/blitter_ref.c patches/mister/test_spritelist.c \
        patches/mister/build_test_spritelist.sh patches/mister/build_host_tests.sh
git commit -m "feat(blitter): OP_SPRITELIST wire format + reference model

Opcode 10, same header packing as OP_TILELIST. Entries are 16-byte
qword-aligned blt_sprite_entry_t carrying a PER-ENTRY src_off, because
sprites do not share one texture the way a tileset layer does.

Acceptance test asserts a sprite list paints a bit-identical framebuffer
to the equivalent N OP_BLITs, with overlapping sprites so order is
observable. Registered in build_host_tests.sh (the CI gate)."
```

---

## Task 3: Emitter API + `SP_BUF` region

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h`, `blt_emitter.c`
- Modify: `patches/mister/mister_blitter_renderer.cpp` (DDR offset constant, init)
- Modify: `patches/mister/test_spritelist.c` (extend)

**Interfaces:**
- Consumes: `blt_sprite_entry_t`, `BLT_OP_SPRITELIST` (Task 2).
- Produces:
  - `void blt_sprite_list_init(blt_emitter_t *e, void *sp_buf, size_t sp_cap);`
  - `int blt_sprite_list(blt_emitter_t *e, uint32_t src_stride, uint8_t format, uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags, uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);`
    returns 0, or −1 with `e->overflow` set on ring-full.
  - `e->sp_used` (`size_t`, bytes used this frame, reset in `blt_begin_frame`), `e->sp_cap`.
  - `OFF_SPBUF` = `0x3BFC0000`, 256 KiB — **immediately after** `TL_BUF`
    (`0x3BF40000` + 512 KiB = `0x3BFC0000`), inside the DDR3 aperture.

- [ ] **Step 1: Write the failing test extension**

Append to `main()` in `patches/mister/test_spritelist.c`, before `return 0;`:

```c
    /* Emitter: header packing round-trips through the reference walker. */
    {
        blt_emitter_t e;
        static uint8_t ring[BLT_CMD_BYTES * 16];
        static uint8_t spb[NSPR * 16];
        blt_emitter_init(&e, ring, sizeof ring, NULL, 0);
        blt_sprite_list_init(&e, spb, sizeof spb);
        blt_begin_frame(&e, 0, 0, 0, 0, 0);
        for (int i = 0; i < NSPR; i++) {
            blt_sprite_entry_t se = { 0, SPR[i].sx, SPR[i].sy, SPR[i].w, SPR[i].h,
                                      SPR[i].dx, SPR[i].dy };
            blt_pack_sprite_entry(spb + i * 16, &se);
        }
        e.sp_used = NSPR * 16;
        if (blt_sprite_list(&e, TEXW * 2, BLT_FMT_RGB565, BLT_BLEND_COPY,
                            0, 255, 0, 0, NSPR, 0, 0) != 0) {
            printf("FAIL: blt_sprite_list returned error\n"); return 1;
        }
        if (e.cmd_count != 1) {
            printf("FAIL: expected 1 command, got %d\n", e.cmd_count); return 1;
        }
        printf("ok: emitter packs one OP_SPRITELIST for %d sprites\n", NSPR);
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash patches/mister/build_test_spritelist.sh
```
Expected: compile error — `blt_sprite_list_init` / `blt_sprite_list` undeclared,
no member `sp_used`.

- [ ] **Step 3: Add the emitter state**

In `patches/mister/blitter/blt_emitter.h`, in `struct blt_emitter_t` beside `tl_used`:

```c
    uint8_t *sp_buf;     /* [Stage 2] sprite-entry buffer (own region, NOT tl_buf) */
    size_t   sp_cap;     /* capacity in bytes                                      */
    size_t   sp_used;    /* bytes used this frame (reset in blt_begin_frame)       */
```

- [ ] **Step 4: Declare and implement the API**

Declaration in `blt_emitter.h`:

```c
/* [Stage 2] Bind the sprite-entry buffer (separate from ring, source heap, and TL_BUF). */
void blt_sprite_list_init(blt_emitter_t *e, void *sp_buf, size_t sp_cap);

/* [Stage 2] Emit a header-only BLT_OP_SPRITELIST pointing at `entry_off` (N 16-byte
 * blt_sprite_entry_t already resident in sp_buf). Each entry carries its own src_off;
 * `src_stride`/`format`/`blend`/`key`/`alpha`/`flags` are shared across the batch, so the
 * caller must start a new list when any of them changes. bias_x/bias_y are a signed
 * per-batch dst bias added to every entry's dst by the fabric.
 * Returns 0, or -1 + e->overflow on ring full. */
int blt_sprite_list(blt_emitter_t *e, uint32_t src_stride, uint8_t format, uint8_t blend,
                    uint16_t key, uint8_t alpha, uint8_t flags,
                    uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);
```

Implementation in `blt_emitter.c`:

```c
void blt_sprite_list_init(blt_emitter_t *e, void *sp_buf, size_t sp_cap)
{
    e->sp_buf = (uint8_t *)sp_buf;
    e->sp_cap = sp_cap;
    e->sp_used = 0;
}

int blt_sprite_list(blt_emitter_t *e, uint32_t src_stride, uint8_t format, uint8_t blend,
                    uint16_t key, uint8_t alpha, uint8_t flags,
                    uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y)
{
    blt_cmd_t c;
    memset(&c, 0, sizeof c);
    c.opcode     = BLT_OP_SPRITELIST;
    c.blend_mode = blend;
    c.format     = format;
    c.flags      = flags;
    c.alpha      = alpha;
    c.colorkey   = key;
    c.src_stride = src_stride;
    c.src_x      = (uint16_t)bias_x;      /* header bias slots, per convention */
    c.src_y      = (uint16_t)bias_y;
    c.w          = (uint16_t)(n & 0xFFFF);        /* w | h<<16 = entry count   */
    c.h          = (uint16_t)((unsigned)n >> 16);
    c.dst_x      = (int16_t)(entry_off & 0xFFFF); /* dst_x | dst_y<<16 = offset */
    c.dst_y      = (int16_t)(entry_off >> 16);
    return emit(e, &c);
}
```

In `blt_begin_frame()`, next to `e->tl_used = 0;`, add `e->sp_used = 0;`.

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash patches/mister/build_test_spritelist.sh
```
Expected: both `ok:` lines, exit 0.

- [ ] **Step 6: Wire the DDR region into the renderer**

In `patches/mister/mister_blitter_renderer.cpp`, beside `OFF_TLBUF` (`:264-265`):

```cpp
    /* [Stage 2] Sprite-entry buffer: its own region, deliberately NOT TL_BUF —
     * the clean lane shares no storage with the resident/bgplane machinery.
     * Sits immediately after TL_BUF (0x3BF40000 + 512 KiB). */
    static constexpr uint32_t OFF_SPBUF   = 0x3BFC0000;
    static constexpr size_t   SP_BUF_BYTES = 256 * 1024;   /* 16384 sprites/frame */
```

Where `blt_tile_list_init` is called, add alongside:

```cpp
    blt_sprite_list_init(&em, ddr_ptr(OFF_SPBUF), SP_BUF_BYTES);
```

Add `static_assert`s for both hazards — overlap **and** running off the end of the mapped
DDR3 window. `SP_BUF` ends at `0x3C000000`, so confirm the mapping actually extends that
far before trusting it (check the `map_ddr()` length and `docs/frame-dataflow.md:30`); if
it does not, place `SP_BUF` inside the existing window instead and shrink it.

```cpp
    static_assert(OFF_SPBUF >= OFF_TLBUF + TL_BUF_BYTES, "SP_BUF overlaps TL_BUF");
    static_assert(OFF_SPBUF + SP_BUF_BYTES <= DDR_BASE + DDR_MAP_BYTES,
                  "SP_BUF runs past the mapped DDR3 window");
```

Use whatever the real base/length constants are named in this file. **If the second
assertion cannot be written because no such constant exists, stop and report it** — a
buffer past the end of the mapping would fault or corrupt at runtime, and is exactly the
class of bug that cost this project the #84 investigation.

- [ ] **Step 7: Type-check + full suite**

```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo SYNTAX_OK
bash patches/mister/build_host_tests.sh
```
Expected: `SYNTAX_OK`, then `== all host tests passed ==`

- [ ] **Step 8: Commit**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c \
        patches/mister/mister_blitter_renderer.cpp patches/mister/test_spritelist.c
git commit -m "feat(blitter): blt_sprite_list emitter + dedicated SP_BUF region

SP_BUF is its own 256 KiB DDR region immediately after TL_BUF, not a
share of it — the clean lane deliberately holds no storage in common
with the resident/bgplane machinery."
```

---

## Task 4: Host `SpriteChannel` behind `SOLARUS_SPRITECH`

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — flag parse (`~:2264`), `draw()`
  case 2 (`:2583-2590`), new flush hook, diag log (`:3967-3982`)
- Modify: `patches/mister/test_spritelist.c` (run-grouping + cap/drop tests)

**Interfaces:**
- Consumes: Task 3's emitter API; Task 1's counters.
- Produces: `bool spritech` (gate); `void sprite_channel_flush(int layer)` — emits all
  buffered sprites for `layer` as one-or-more `OP_SPRITELIST` runs and clears the buffer;
  counters `g_spr_records`, `g_spr_runs`, `g_spr_dropped` (`long`).

- [ ] **Step 1: Write the failing grouping/cap test**

Append to `main()` in `patches/mister/test_spritelist.c`, before `return 0;`:

```c
    /* Run grouping: a change of blend/format/stride must start a NEW list,
     * and runs must stay in emission order so Z-order is preserved. */
    {
        struct { uint8_t blend; uint32_t stride; } S[] = {
            { BLT_BLEND_COPY, 64 }, { BLT_BLEND_COPY, 64 },
            { BLT_BLEND_PALPHA, 64 },                      /* break: blend  */
            { BLT_BLEND_PALPHA, 128 },                     /* break: stride */
            { BLT_BLEND_PALPHA, 128 },
        };
        int runs = 1;
        for (int i = 1; i < 5; i++)
            if (S[i].blend != S[i-1].blend || S[i].stride != S[i-1].stride) runs++;
        if (runs != 3) { printf("FAIL: expected 3 runs, got %d\n", runs); return 1; }
        printf("ok: run grouping breaks on blend/stride change (%d runs)\n", runs);
    }

    /* Cap: overflow drops the TAIL (preserving the earliest sprites) and counts. */
    {
        const int cap = 4, offered = 7;
        int taken = offered > cap ? cap : offered;
        int dropped = offered - taken;
        if (taken != 4 || dropped != 3) {
            printf("FAIL: cap accounting taken=%d dropped=%d\n", taken, dropped);
            return 1;
        }
        printf("ok: cap drops tail (%d taken, %d dropped)\n", taken, dropped);
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash patches/mister/build_test_spritelist.sh
```
Expected: FAIL on the first block if `BLT_BLEND_PALPHA` is not in scope, otherwise these
two blocks pass trivially — they pin the *contract* the renderer must implement. Proceed
either way; the renderer-side assertion is Step 6.

- [ ] **Step 3: Parse the gate**

Beside the other flag parses (`~:2264`) in `mister_blitter_renderer.cpp`:

```cpp
    /* [Stage 2] PRESENCE-based like every flag here: SOLARUS_SPRITECH=0 still
     * ENABLES it. It must be ABSENT to disable. Default OFF (flipped separately). */
    d->spritech = (std::getenv("SOLARUS_SPRITECH") != nullptr);
```

- [ ] **Step 4: Buffer instead of emitting, in `draw()` case 2**

Replace the body at `:2583-2590`:

```cpp
    if (dst.get_width() == FB_W && d->alias_target == &dst && !g_transition_scroll) {
        d->alias_drawn_this_frame = true;
        if (d->spritech) {
            if (d->sprite_channel_push(src, infos, d->alias_off_x, d->alias_off_y))
                d->g_spr_records++;
            else
                d->g_spr_dropped++;      /* cap reached: drop the TAIL, keep order */
            return;
        }
        bool emitted = d->emit_draw(src, infos, d->alias_off_x, d->alias_off_y);
        if (emitted) d->g_sprite_blits++;
        return;
    }
```

`sprite_channel_push` resolves the source exactly as `emit_draw` does (same `map_blend`
and `upload()` path — the upload path is reused unchanged per the design), then appends a
`blt_sprite_entry_t` to `SP_BUF` plus its run key `(src_stride, format, blend, alpha,
colorkey, flags)`. It returns `false` once the cap is reached.

- [ ] **Step 5: Flush at layer end**

`sprite_channel_flush(layer)` walks the buffered records, and for each maximal run of
consecutive records sharing a run key calls `blt_sprite_list(...)` once, incrementing
`g_spr_runs` per emitted command. Call it from the same place per-layer entity drawing
completes, so that the `OP_SPRITELIST` commands land **after** that layer's tile commands
and **before** the next layer's — preserving `Entities.cpp:1509-1695` order.

- [ ] **Step 6: Report the channel in diag**

Append to the `[blitter diag]` line (Task 1, Step 7):
` spr_rec=%ld spr_runs=%ld spr_drop=%ld`, args `d->g_spr_records, d->g_spr_runs,
d->g_spr_dropped`. Reset all three with the other counters (`:4279-4288`).

`spr_rec / spr_runs` is the measured collapse ratio — the number the validation record
reports instead of the plan's estimate.

- [ ] **Step 7: Type-check + full suite**

```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo SYNTAX_OK
bash patches/mister/build_host_tests.sh
```
Expected: `SYNTAX_OK`, then `== all host tests passed ==`

- [ ] **Step 8: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/test_spritelist.c
git commit -m "feat(render): SpriteChannel behind SOLARUS_SPRITECH (default OFF)

Buffers camera-surface blits per layer and flushes them at layer end as
one OP_SPRITELIST per uniform run, preserving emission order and thus
Z-order. Bounded cap drops the TAIL and counts drops.

Flag is PRESENCE-based: SOLARUS_SPRITECH=0 still enables it."
```

---

## Task 5: INTER arena occupancy log

Groundwork for parent §6.2. `blt_alloc_used` is called on `sdram_perm` (`:1556`) and the
DDR3 bounce heap (`:1598`) but never on `sdram_inter`, so the "~2 MiB working set"
justifying the 4 MiB arena (`:318-324`) has no evidence anywhere in the repo.

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp` (`:3989-3994` region)

**Interfaces:** Consumes `blt_alloc_used()` (`blt_alloc.h:58`). Produces a
`[blitter inter]` diag line.

- [ ] **Step 1: Add the log line**

Next to the `[blitter cvt]` block (`:3989-3994`):

```cpp
        /* [Stage 2] INTER occupancy: the 4 MiB sizing rests on a "~2 MiB working set
         * (measured)" comment with no log line anywhere. Make it observable. */
        std::fprintf(stderr,
                     "[blitter inter] /60fr: used=%zu/%zu bytes (%.2f/%.2f MiB) leaked=%zu\n",
                     blt_alloc_used(&d->em.sdram_inter), (size_t)SDRAM_INTER_SIZE,
                     blt_alloc_used(&d->em.sdram_inter) / 1048576.0,
                     SDRAM_INTER_SIZE / 1048576.0,
                     blt_alloc_leaked(&d->em.sdram_inter));
```

- [ ] **Step 2: Type-check**

```bash
g++ -fsyntax-only -std=c++17 -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo SYNTAX_OK
```
Expected: `SYNTAX_OK`

- [ ] **Step 3: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "diag(blitter): log INTER arena occupancy per 60-frame window

The 4 MiB INTER sizing rests on a '~2 MiB working set (measured)'
comment with no cited log line in the repo, and blt_alloc_used was never
called on sdram_inter — the only INTER signal was failure-shaped."
```

---

## Task 6: `sprite_unit` RTL + simulation

**Files:**
- Modify: `fpga/rtl/blitter_defs.vh` (opcode + `SP_BUF` base)
- Modify: `fpga/rtl/blitter_top.sv` (`:655` dispatch chain; new states 58–61)
- Create: `fpga/sim/tb_spritelist.sv`

**Interfaces:**
- Consumes: the Task 2 wire format (16-byte entries, header packing).
- Produces: fabric execution of opcode 10. No new host API.

- [ ] **Step 1: Pull the current fitter/timing baseline BEFORE touching RTL**

```bash
gh run list --workflow=fpga --limit 5
gh run download <id> -n quartus-reports -D /tmp/qbase
grep -iE 'slack|Total RAM Blocks|logic utilization' /tmp/qbase/Solarus.sta.summary /tmp/qbase/Solarus.fit.summary
```
Record the numbers in the task notes. **The design spec's 435/553 and −3.359 ns figures
are quoted from dated planning docs and are not in-tree** — this step replaces them with
real ones. Without a baseline there is no way to show the new op did not regress timing.

- [ ] **Step 2: Add the opcode + region constants**

In `fpga/rtl/blitter_defs.vh`, mirroring the host:

```systemverilog
localparam [7:0] OP_SPRITELIST = 8'd10;   // [Stage 2] ordered sprite batch
// SP_BUF: 0x3BFC0000, 256 KiB. Qword address = byte >> 3.
localparam [28:0] SP_BUF_QW = 29'h077F8000;
```

- [ ] **Step 3: Write the failing testbench**

Create `fpga/sim/tb_spritelist.sv` asserting that a 5-entry `OP_SPRITELIST` produces the
**same sequence of `comp_pipeline` issue transactions** (`c_src_off`, `c_src_x/y`,
`c_w/c_h`, `c_dst_x/y` at each `pipe_start`) as five equivalent `OP_BLIT` commands, using
the same overlapping sprite set as `test_spritelist.c` so the two layers of the acceptance
test agree. Follow the structure of the existing tile-list testbenches in `fpga/sim/`.

- [ ] **Step 4: Run it to verify it fails**

```bash
cd fpga/sim && ./run_tb.sh tb_spritelist
```
Expected: FAIL — `OP_SPRITELIST` falls through the `S_SETUP` chain into the default
FILL/BLIT branch (`blitter_top.sv:733-740`) and is misinterpreted as a single rect.

> Match the actual runner's name/flags in `fpga/sim/`. Note the suite has known-slow
> testbenches where CI timeouts have historically been slowness, not RTL bugs.

- [ ] **Step 5: Add the dispatch arm**

In `blitter_top.sv` `S_SETUP` (`:655`), alongside the `OP_TILELIST` arm at `:671`, add an
`OP_SPRITELIST` arm. It must sit **before** the `empty` clip test at `:733`, because
`c_w`/`c_h` are the entry count here, not a rect — the same reason documented at
`:675-676`. Latch:

```systemverilog
    spr_n        <= {c_h, c_w};                  // w | h<<16 = entry count
    spr_byte     <= {c_dst_y, c_dst_x};          // dst_x | dst_y<<16 = byte offset
    spr_bias_x   <= $signed(c_src_x);
    spr_bias_y   <= $signed(c_src_y);
    spr_stride   <= c_src_stride;                // shared across the batch
    spr_idx      <= '0;
    state        <= S_SPR_FETCH;                 // 6'd58
```

- [ ] **Step 6: Implement fetch/latch/issue**

Add states `S_SPR_FETCH = 6'd58`, `S_SPR_FETCH2 = 6'd59`, `S_SPR_LATCH = 6'd60`:

- `S_SPR_FETCH` / `S_SPR_FETCH2` — read the entry's **two aligned qwords** at
  `SP_BUF_QW + ((spr_byte + spr_idx*16) >> 3)`. Aligned by construction (16-byte entries
  at a 16-byte-aligned base), so **no barrel shift is needed** — this is why the entry was
  sized to 16 bytes rather than 12.
- `S_SPR_LATCH` — slice the two qwords into `c_src_off`, `c_src_x`, `c_src_y`, `c_w`,
  `c_h`, and `c_dst_x <= $signed(dst_x) + spr_bias_x`, `c_dst_y <= $signed(dst_y) +
  spr_bias_y`; set `c_src_stride <= spr_stride`; then `state <= S_TL_ISSUE`.

Reusing `S_TL_ISSUE`/`S_TL_WAIT` (`:837-857`) inherits the existing cull, `pipe_start`
handoff, and `p_blit_done` wait — exactly as `S_TLR_SLICE` does at `:918`. In `S_TL_WAIT`,
advance by 16 and loop back to `S_SPR_FETCH` when the active op is `OP_SPRITELIST`
(mirroring how it advances by 12 or 8 today).

- [ ] **Step 7: Run the testbench to verify it passes**

```bash
cd fpga/sim && ./run_tb.sh tb_spritelist
```
Expected: PASS — issue transactions identical to the 5 `OP_BLIT` baseline.

- [ ] **Step 8: Run the full sim suite for regressions**

```bash
cd fpga/sim && ./run_all.sh
```
Expected: no NEW failures versus the Step 1 baseline.

- [ ] **Step 9: Commit**

```bash
git add fpga/rtl/blitter_defs.vh fpga/rtl/blitter_top.sv fpga/sim/tb_spritelist.sv
git commit -m "feat(fpga): sprite_unit — OP_SPRITELIST expanding op

New clean lane: decodes opcode 10, fetches 16-byte qword-aligned sprite
entries from its own SP_BUF region, and joins the existing
S_TL_ISSUE/S_TL_WAIT loop feeding comp_pipeline — the same convergence
S_TLR_SLICE uses.

Reuses none of the resident/bgplane machinery and no TL_BUF storage.
Entries are 16 bytes specifically so each is an aligned qword pair,
avoiding the 3-qword unaligned window + barrel shift OP_TILELIST needs."
```

- [ ] **Step 10: Confirm timing did not regress**

After CI produces an RBF, download `quartus-reports` again and compare slack and RAM
blocks against the Step 1 baseline. **A built RBF is not evidence of passing timing** —
`2026-06-25-compositor-throughput-session.md:68` records that RBFs build with negative
slack. If slack regressed below the baseline, stop and report before any HW session.

---

## Task 7: Build, deploy, HW validation (incl. #122/#123 scroll A/B)

**Files:** Create `docs/superpowers/2026-07-19-stage2-hw-validation.md`

**Interfaces:** Consumes everything above. Produces the validation record.

- [ ] **Step 1: Build the engine in the container**

```bash
scripts/docker_run.sh bash scripts/build_engine.sh 2>&1 | tee /tmp/stage2_build.log
grep BUILD_EXIT /tmp/stage2_build.log
```
Expected: `BUILD_EXIT=0`. **Do not trust the task's exit code — grep for this line.**

- [ ] **Step 2: Refresh `deploy/` and verify the library actually moved**

```bash
cp build/armhf/solarus-run deploy/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
shasum deploy/libs/libsolarus.so.1.6.5
```
Note the sha1. The library goes in **`deploy/libs/`**, not `deploy/` root — a Stage 1 run
reported success having copied it to the wrong place and shipped the previous day's build.

- [ ] **Step 3: Deploy and sha1-verify ON DEVICE**

```bash
./deploy.py --no-rbf --host 192.168.20.81
ssh root@192.168.20.81 'shasum /media/fat/games/Solarus/libs/libsolarus.so.1.6.5'
```
Expected: **identical** to Step 2. `deploy.py` exit 0 says nothing about which files moved.

- [ ] **Step 4: Arm a safe launch**

```bash
ssh root@192.168.20.81 'cat /media/fat/config/Solarus.s0'   # MUST be empty
ssh root@192.168.20.81 'mkdir -p /media/fat/logs/Solarus'
```
Leave `Solarus.s0` **empty**, load the core from the OSD, then launch with a private
`S0_FILE` override. Two concurrent `solarus-run` processes make the host mostly
unresponsive and require a device restart. Log to `/media/fat/logs/Solarus/` — **never
`/tmp`**, which a restart wipes, destroying the evidence of the run being diagnosed.
The lua-console path `exec`s with its own redirect to `Solarus.diag.log`.

- [ ] **Step 5: Capture the A/B**

Run the same scene twice — `SOLARUS_SPRITECH` **absent** (baseline), then **present**.
Remember `=0` still enables it; it must be removed from `diag.env` to disable.

Record from `[blitter diag]`: `sprite_blits`, `tile_blits`, `dropped`, `spr_rec`,
`spr_runs`, `spr_drop`, `cmdcnt`, `overflow`; from `[blitter inter]`: `used`.

Acceptance:
- `spr_rec` (ON) ≈ `sprite_blits` (OFF) — the same sprites are being routed
- `spr_drop = 0` at the chosen cap, `dropped = 0`
- `cmdcnt` materially lower with the channel ON — the collapse, measured
- Report the real `spr_rec / spr_runs` ratio, not the plan's estimate

- [ ] **Step 6: Census the cap (spec §5 — cap is chosen HERE, not earlier)**

With the channel ON, visit the **parallax map** and the **town** — the two busiest scenes
on record (`60fps-bottleneck-hunt.md:44-48`,
`2026-07-13-bgplane-default-on-design.md:14-18`). Use the lua-console teleport harness
(`2026-07-12-issue84-root-cause-and-paletted-composition-brief.md` §2); note its route is a
*tileset* sweep and does not include either scene, so extend it.

Record peak `spr_rec`/frame. **Set the cap from that measurement with headroom**, and write
the measured number into the validation record. Do not carry forward the unsourced
~450/frame figure.

- [ ] **Step 7: #122 / #123 scroll-transition A/B (folded in per operator)**

The parent design predicted Stage 1 would structurally delete both; that was **never
verified** — scroll was observed only in passing ("might have been fine"). Close it now.

Trigger a **scroll map transition** deliberately, four ways: `SOLARUS_OVERLAY` absent vs
present, crossed with `SOLARUS_SPRITECH` absent vs present. For each, capture an mrext
screenshot and the operator's observation of (a) a held/duplicated frame (#122) and (b) a
black frame on the scroll path (#123).

Record per issue: still reproducing / fixed / changed. **If either still reproduces, say so
plainly** — the Stage 1 record's value came from listing what was *not* established.

- [ ] **Step 8: Write the validation record**

Create `docs/superpowers/2026-07-19-stage2-hw-validation.md` following
`2026-07-18-stage1-overlay-hw-validation.md`: verdict, objective signals table, A/B table,
operator visual observations, **a "What is NOT established" section**, process notes,
device state left, refs.

State explicitly that counters alone do not establish correctness — Stage 1 reported
`draws=480 composites=60 dropped=0` while visibly under-dimming menus (#124).

- [ ] **Step 9: Commit the record**

```bash
git add docs/superpowers/2026-07-19-stage2-hw-validation.md
git commit -m "docs: Stage 2 sprite-channel HW validation record

Includes the deliberate #122/#123 scroll-transition A/B that Stage 1
predicted would be fixed but never verified, and the measured sprite
census that sets the cap."
```

---

## Deferred (explicitly NOT in this plan)

- **Flipping `SOLARUS_SPRITECH` default ON** — separate commit after HW validation.
- **Clean-laning the source/upload path** and parent §6.2's scratch arena (spec §6).
- **#124 un-premultiply experiment** — flagged in spec §9; operator did not fold it in.
- **Stage 3 tilemap grid op** — gated on re-measuring the `comp_pipeline` ceiling
  (spec §7), which the Task 6 Step 1 baseline begins to serve.
