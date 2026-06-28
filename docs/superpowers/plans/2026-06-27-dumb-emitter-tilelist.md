# Dumb Emitter — Fabric Tile-List Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse ~3,758 per-frame animated-tile draws into per-tileset `BLT_OP_TILELIST` commands the fabric expands, taking the heavy-area A9 from ~137ms → ~25-35ms (~7fps → ~35-42fps).

**Architecture:** A new fixed-32-byte ring command (`BLT_OP_TILELIST`) carries shared texture+blend params and points at an N-entry array in a new double-buffered VRAM tile-list buffer; each 12-byte entry is `(src_rect, dst_xy)`. The fabric streams entries and composites each via the existing per-blit datapath. Solarus's animated-tile loop extracts `(src_rect,dst)` per tile via a draw-free `TilePattern` query and emits one batch per `(tileset_image, blend, flags)`. Bit-exactness is gated in sim against the C reference model, where `TILELIST ≡ N BLITs` by construction.

**Tech Stack:** C (vendored reference model + host emitter), SystemVerilog (`blitter_top` / `comp_pipeline`, Icarus/`tb_*` sim), C++ (Solarus engine via `build_engine.sh` idempotent patch blocks), Quartus 17.0 RBF, armhf Docker cross-build.

## Global Constraints

- **In-tree is the source of truth (decided 2026-06-27).** The upstream `../mister-fpga-blitter` `.c` files are ~2 versions stale (missing the in-tree v2 escape-elim + SDRAM/STAGE work), so "edit upstream → re-copy" would REGRESS shipped code. Therefore: edit `patches/mister/blitter/*.c` (and `.h`) **directly**; do NOT re-copy from upstream. Upstream reconciliation is deferred, separate debt. (Task 1 already reconciled the `.h` upstream + in-tree — fine, leave it.) Host tests build via a **self-contained in-tree harness** at `patches/mister/blitter/tests/` (its own Makefile compiling the in-tree `.c`), NOT the stale upstream Makefiles.
- **Command stays 32 bytes** and the `BLT_CMD_BYTES` packing is unchanged.
- **Command stays 32 bytes** (`BLT_CMD_BYTES`); the ring parser is structurally unchanged.
- **Opcode value:** `BLT_OP_TILELIST = 5` (next free after `BLT_OP_STAGE = 4`).
- **Bit-exact gate is mandatory** before any HW: new sim TB must diff `comp_fbram` against the reference model, and the full existing TB suite must still pass.
- **Engine-core edits land as idempotent `build_engine.sh` patch blocks** AFTER the existing `git checkout -- <file>` resets (Entities.cpp reset is in the move-convert block; Game.cpp in the camera-tag block). Direct edits to `work/solarus` are wiped.
- **Batching gated behind `SOLARUS_TILEBATCH` (default on)** for HW A/B and instant rollback.
- **Coupled deploy:** RBF + engine pushed together (per #52); verify deployed `libsolarus` sha1 vs `build/armhf`.
- **Seed-pinned RBF** per the STA discipline (`SEED 1` currently in `Solarus.qsf`).
- Reference C model is the golden contract; entries live in the model's `heap` byte space at `entry_off` (no `blt_execute` signature change).

---

## File Structure

**Host / reference model (upstream `../mister-fpga-blitter/`, then re-copy):**
- `refmodel/blitter_ref.h` — add `BLT_OP_TILELIST`, `blt_tile_entry_t`.
- `refmodel/blitter_ref.c` — extract `blit_one()` helper; add `TILELIST` case.
- `refmodel/test_blitter_ref.c` — TILELIST ≡ N-BLITs equivalence test.
- `host/blt_emitter.h` — `blt_tile_list()` decl + tile-list buffer fields.
- `host/blt_emitter.c` — `blt_tile_list()` impl + per-frame cursor reset.
- `host/test_emitter.c` — emitter unit test (header + entry bytes).
- `host/blt_wire.h` — entry-array packing (if wire packing is centralized here).
- Re-copy targets: `patches/mister/blitter/{blitter_ref.h,blitter_ref.c,blt_emitter.h,blt_emitter.c}`.

**RTL (in-tree, the built fabric):**
- `fpga/rtl/blitter_defs.vh` — `OP_TILELIST` localparam + tile-list buffer base/size.
- `fpga/rtl/blitter_top.sv` — `S_TL_*` FSM states + entry read + comp issue.
- `fpga/sim/tb_tilelist.sv` — bit-exact gate vs reference model.
- `fpga/sim/run_sims.sh` — register `tb_tilelist`.

**Engine (Solarus, via `scripts/build_engine.sh` patch blocks + `patches/mister/`):**
- `scripts/build_engine.sh` — new idempotent blocks: `TilePattern::get_draw_region`, `Renderer::draw_tile_batch` + `SDLRenderer` fallback, `Entities::draw` batched loop.
- `patches/mister/mister_blitter_renderer.{h,cpp}` — `MisterBlitterRenderer::draw_tile_batch` fabric emit.

**Deploy:** `deploy.py`, `games/Solarus/diag.env`.

---

## Stage 1 — Host + reference model (no hardware)

### Task 1: ABI — opcode + entry struct

**Files:**
- Modify: `../mister-fpga-blitter/refmodel/blitter_ref.h` (enum + struct)
- Modify: `fpga/rtl/blitter_defs.vh` (RTL opcode mirror)
- Re-copy: `patches/mister/blitter/blitter_ref.h`

**Interfaces:**
- Produces: `BLT_OP_TILELIST` (=5); `typedef struct { uint16_t src_x, src_y, w, h; int16_t dst_x, dst_y; } blt_tile_entry_t;` (12 bytes).

- [ ] **Step 1: Add the opcode + entry struct to the ABI header.** In `../mister-fpga-blitter/refmodel/blitter_ref.h`, in the opcode enum after `BLT_OP_STAGE = 4`:

```c
    BLT_OP_TILELIST = 5, /* batch of N tiles from one shared texture+blend.       *
                          * Header (blt_cmd_t) carries shared params; the N        *
                          * per-tile rects live in a VRAM entry array.             *
                          * Field mapping (header):                                *
                          *   src_off/src_stride = shared tileset texture base     *
                          *   src_x/src_y        = tileset texture w/h (bounds)    *
                          *   blend_mode/format/flags/alpha/colorkey = shared      *
                          *   w | h<<16          = entry count N (u32)             *
                          *   dst_x | dst_y<<16  = entry-array byte offset         *
                          * Each entry is a blt_tile_entry_t (12 bytes).           */
```

And after the `blt_cmd_t` struct:

```c
/* BLT_OP_TILELIST per-tile entry (12 bytes, on-wire little-endian). */
typedef struct {
    uint16_t src_x, src_y;   /* tile sub-rect origin in the tileset   */
    uint16_t w, h;           /* tile size (pixels)                    */
    int16_t  dst_x, dst_y;   /* signed dst origin (offscreen-cullable)*/
} blt_tile_entry_t;
```

- [ ] **Step 2: Mirror the opcode in RTL defs.** In `fpga/rtl/blitter_defs.vh`, beside the existing `OP_STAGE` localparam, add:

```verilog
localparam [7:0] OP_TILELIST = 8'd5;   // BLT_OP_TILELIST: N-tile batch
// Tile-list VRAM buffer (double-buffered, ping-ponged by target_buf).
// Placed above the command ring in the DDR control region. 2x64 KiB.
localparam [31:0] TL_BUF_BYTES = 32'h0001_0000;   // 64 KiB per buffer
```

- [ ] **Step 3: Re-copy the header in-tree.**

Run: `cp ../mister-fpga-blitter/refmodel/blitter_ref.h patches/mister/blitter/blitter_ref.h`
Expected: file copied; `grep -c BLT_OP_TILELIST patches/mister/blitter/blitter_ref.h` prints `2`.

- [ ] **Step 4: Commit.**

```bash
git add patches/mister/blitter/blitter_ref.h fpga/rtl/blitter_defs.vh
git commit -m "feat(blitter): BLT_OP_TILELIST opcode + entry ABI (#52)"
```

---

### Task 2: Reference model — `blit_one` extraction + TILELIST case + equivalence test

**Files (IN-TREE — source of truth; do NOT touch upstream):**
- Modify: `patches/mister/blitter/blitter_ref.c` — both `blt_execute` AND the existing `#ifdef BLT_REF_SELFTEST` self-test block (it already has a `main()` + `CHECK` macro; the test goes there). Uses the v2 helpers `heap_px16`/`argb4444_expand`/`div255_round`/`put_blend`/`blt_tint565`/`modch` already present.

**Interfaces:**
- Consumes: `BLT_OP_TILELIST`, `blt_tile_entry_t` (Task 1, already in the in-tree `blitter_ref.h`).
- Produces: `blt_execute` now expands `TILELIST` identically to N `BLIT`s.

**Test convention (established in-tree pattern):** `blitter_ref.c` carries its own self-test under `#ifdef BLT_REF_SELFTEST` (documented build: `cc -DBLT_REF_SELFTEST -I patches/mister/blitter patches/mister/blitter/blitter_ref.c -o /tmp/blt_ref && /tmp/blt_ref`). Extend that block — do NOT add a separate test file or Makefile.

- [ ] **Step 1: Write the failing equivalence test** INSIDE the existing `#ifdef BLT_REF_SELFTEST` block in `blitter_ref.c` (add the function + call it from that block's `main()`). Use its `CHECK(cond, ...)` macro for the assertion (replace the `assert`/`printf` below with `CHECK(memcmp(...)==0, "tilelist != N blits")`):

```c
static void test_tilelist_equals_n_blits(void) {
    /* heap: [tileset pixels 64x64 RGB565][entry array]. */
    enum { TW=64, TH=64, N=5 };
    static uint16_t fb_a[BLT_FB_PIXELS], fb_b[BLT_FB_PIXELS];
    static uint8_t heap[TW*TH*2 + N*sizeof(blt_tile_entry_t)];
    for (int i=0;i<TW*TH;i++) ((uint16_t*)heap)[i] = (uint16_t)(i*2654435761u);
    uint32_t entry_off = TW*TH*2;
    blt_tile_entry_t ents[N] = {
        {0,0, 8,8,  10,10}, {8,0, 8,8, 20,12}, {0,8, 16,16, 30,30},
        {16,16, 8,8, -4,50}, {0,0, 8,8, 315,200} /* partial offscreen */
    };
    memcpy(heap+entry_off, ents, sizeof ents);
    blt_surface_heap_t h = { heap, sizeof heap };

    /* A: one TILELIST */
    memset(fb_a, 0, sizeof fb_a);
    blt_cmd_t tl[2]; memset(tl, 0, sizeof tl);
    tl[0].opcode=BLT_OP_TILELIST; tl[0].blend_mode=BLT_BLEND_COPY; tl[0].format=BLT_FMT_RGB565;
    tl[0].src_off=0; tl[0].src_stride=TW*2; tl[0].src_x=TW; tl[0].src_y=TH;
    tl[0].w=(uint16_t)(N&0xFFFF); tl[0].h=(uint16_t)(N>>16);
    tl[0].dst_x=(int16_t)(entry_off&0xFFFF); tl[0].dst_y=(int16_t)(entry_off>>16);
    tl[1].opcode=BLT_OP_END;
    blt_execute(fb_a, &h, tl, 2);

    /* B: N expanded BLITs */
    memset(fb_b, 0, sizeof fb_b);
    blt_cmd_t bl[N+1]; memset(bl, 0, sizeof bl);
    for (int i=0;i<N;i++){ bl[i].opcode=BLT_OP_BLIT; bl[i].blend_mode=BLT_BLEND_COPY;
        bl[i].format=BLT_FMT_RGB565; bl[i].src_off=0; bl[i].src_stride=TW*2;
        bl[i].src_x=ents[i].src_x; bl[i].src_y=ents[i].src_y; bl[i].w=ents[i].w; bl[i].h=ents[i].h;
        bl[i].dst_x=ents[i].dst_x; bl[i].dst_y=ents[i].dst_y; }
    bl[N].opcode=BLT_OP_END;
    blt_execute(fb_b, &h, bl, N+1);

    assert(memcmp(fb_a, fb_b, sizeof fb_a) == 0);
    printf("ok test_tilelist_equals_n_blits\n");
}
```

Call `test_tilelist_equals_n_blits();` from the existing `BLT_REF_SELFTEST` `main()` (and have it bump `g_fail` via `CHECK`, matching the block's convention).

- [ ] **Step 2: Run to verify it fails.**

Run: `cc -DBLT_REF_SELFTEST -I patches/mister/blitter patches/mister/blitter/blitter_ref.c -o /tmp/blt_ref && /tmp/blt_ref`
Expected: FAIL — `TILELIST` is the "unknown opcode: ignore" path (no `blit_one`/TILELIST case yet), so `fb_a` stays cleared while `fb_b` has blits → `CHECK` reports FAIL / nonzero exit.

- [ ] **Step 3: Extract `blit_one` and add the TILELIST case.** In `blitter_ref.c`, refactor the `BLT_OP_BLIT` body (lines ~223-262) into a file-static helper, then call it from BLIT and from a new TILELIST loop:

```c
/* Composite one blit (shared params in `c`, rect already in c->src_x/y/w/h,dst). */
static void blit_one(uint16_t *fb, const blt_surface_heap_t *heap, const blt_cmd_t *c) {
    int hflip = (c->flags & BLT_F_HFLIP) != 0;
    int vflip = (c->flags & BLT_F_VFLIP) != 0;
    int do_mod = (c->flags & BLT_F_COLORMOD) != 0;
    uint8_t cr=c->_pad[0], cg=c->_pad[1], cb=c->_pad[2];
    int palpha = (c->blend_mode == BLT_BLEND_PALPHA) && (c->format == BLT_FMT_ARGB4444);
    for (int j=0;j<c->h;j++) for (int i=0;i<c->w;i++) {
        int dx=c->dst_x+i, dy=c->dst_y+j;
        if (dx<0||dx>=BLT_FB_WIDTH||dy<0||dy>=BLT_FB_HEIGHT) continue;
        int sx=c->src_x+(hflip?(c->w-1-i):i), sy=c->src_y+(vflip?(c->h-1-j):j);
        size_t boff=(size_t)c->src_off+(size_t)sy*c->src_stride+(size_t)sx*2u;
        uint16_t raw=heap_px16(heap, boff);
        if (palpha) {
            unsigned a8,sr,sg,sb; argb4444_expand(raw,&a8,&sr,&sg,&sb);
            if (a8==0) continue;
            if (do_mod){ sr=modch(sr,cr); sg=modch(sg,cg); sb=modch(sb,cb); }
            unsigned idx=(unsigned)dy*BLT_FB_WIDTH+(unsigned)dx; uint16_t d=fb[idx];
            unsigned dr=(d>>11)&0x1F,dg=(d>>5)&0x3F,db=d&0x1F,na=255u-a8;
            unsigned orr=div255_round(sr*a8+dr*na),og=div255_round(sg*a8+dg*na),ob=div255_round(sb*a8+db*na);
            fb[idx]=(uint16_t)(((orr&0x1F)<<11)|((og&0x3F)<<5)|(ob&0x1F)); continue;
        }
        uint16_t src=do_mod?blt_tint565(raw,cr,cg,cb):raw;
        put_blend(fb,dx,dy,src,raw,c->blend_mode,c->flags,c->colorkey,c->alpha);
    }
}
```

Replace the BLIT case body with `blit_one(fb, heap, c); continue;`. Add the TILELIST case after STAGE:

```c
        if (c->opcode == BLT_OP_TILELIST) {
            uint32_t n = (uint32_t)c->w | ((uint32_t)c->h << 16);
            uint32_t eoff = (uint32_t)(uint16_t)c->dst_x | ((uint32_t)(uint16_t)c->dst_y << 16);
            for (uint32_t k=0; k<n; k++) {
                blt_tile_entry_t e;
                memcpy(&e, heap->base + eoff + (size_t)k*sizeof(blt_tile_entry_t), sizeof e);
                blt_cmd_t b = *c;                 /* inherit shared params */
                b.opcode = BLT_OP_BLIT;
                b.src_x=e.src_x; b.src_y=e.src_y; b.w=e.w; b.h=e.h;
                b.dst_x=e.dst_x; b.dst_y=e.dst_y;
                blit_one(fb, heap, &b);
            }
            continue;
        }
```

- [ ] **Step 4: Run to verify it passes.**

Run: `cc -DBLT_REF_SELFTEST -I patches/mister/blitter patches/mister/blitter/blitter_ref.c -o /tmp/blt_ref && /tmp/blt_ref`
Expected: PASS — the self-test prints no `FAIL:` lines and exits 0 (the existing v2 self-tests still pass too).

- [ ] **Step 5: Commit (in-tree only).**

```bash
git add patches/mister/blitter/blitter_ref.c
git commit -m "feat(blitter): reference-model TILELIST = N BLITs + self-test (#52)"
```

---

### Task 3: Host emitter — tile-list buffer + `blt_tile_list()`

**Files (IN-TREE — source of truth; do NOT touch upstream):**
- Modify: `patches/mister/blitter/blt_emitter.h` (struct fields + `blt_tile_list*` decls)
- Modify: `patches/mister/blitter/blt_emitter.c` (impl + a NEW `#ifdef BLT_EMITTER_SELFTEST` self-test block, mirroring the `BLT_REF_SELFTEST` pattern in `blitter_ref.c`)

**Test convention:** add a `#ifdef BLT_EMITTER_SELFTEST` block at the end of `blt_emitter.c` with a `main()` running the test (use a `CHECK`-style macro). `blt_pack_cmd`/`blt_unpack_cmd` are header-only inlines in `blt_wire.h` (already included). Build/run with:
`cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c -o /tmp/blt_emit && /tmp/blt_emit`
(The `#ifdef` block is excluded from the engine build — `BLT_EMITTER_SELFTEST` is never defined there — so the engine never sees this `main()`.)

**Interfaces:**
- Consumes: `BLT_OP_TILELIST`, `blt_tile_entry_t`, `emit()`, `blt_pack_cmd()`.
- Produces:
  - `void blt_tile_list_init(blt_emitter_t *e, void *tl_buf, size_t tl_cap);`
  - `int blt_tile_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags, const blt_tile_entry_t *ents, int n);`
  - Per-frame reset of the tile-list cursor inside `blt_begin_frame`.

- [ ] **Step 1: Add buffer fields + API decls.** In `blt_emitter.h`, add to `blt_emitter_t`:

```c
    uint8_t *tl_buf;     /* tile-list entry buffer (VRAM region; malloc in tests) */
    size_t   tl_cap;     /* capacity in bytes                                     */
    size_t   tl_used;    /* bytes used this frame (reset in blt_begin_frame)      */
```

And declarations:

```c
/* Bind the tile-list entry buffer (separate from the command ring + source heap). */
void blt_tile_list_init(blt_emitter_t *e, void *tl_buf, size_t tl_cap);

/* Emit one BLT_OP_TILELIST: writes the N entries into tl_buf and a header command
 * into the ring. `tex` supplies the shared src_off/src_stride/format (SDRAM vs DDR3
 * mux applied like blt_blit). Returns 0, or -1 + e->overflow on ring/tl_buf full. */
int blt_tile_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                  uint16_t key, uint8_t alpha, uint8_t flags,
                  const blt_tile_entry_t *ents, int n);
```

- [ ] **Step 2: Write the failing emitter test.** In `test_emitter.c`:

```c
static void test_blt_tile_list(void) {
    uint8_t ring[4096], heap[8192], tlbuf[4096];
    blt_emitter_t e; blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_tile_list_init(&e, tlbuf, sizeof tlbuf);
    blt_begin_frame(&e, 0, 0, 0);
    blt_surface_ref_t tex = { .off=0x100, .stride=128, .w=64, .h=64,
                              .format=BLT_FMT_RGB565, .valid=1, .sdram_off=BLT_ALLOC_FAIL };
    blt_tile_entry_t ents[3] = {{0,0,8,8,10,10},{8,0,8,8,20,10},{0,8,16,16,30,30}};
    assert(blt_tile_list(&e, tex, BLT_BLEND_COPY, 0, 0, 0, ents, 3) == 0);

    blt_cmd_t c; blt_unpack_cmd(ring, &c);            /* first ring command */
    assert(c.opcode == BLT_OP_TILELIST);
    assert(c.src_off == 0x100 && c.src_stride == 128);
    uint32_t n = (uint32_t)c.w | ((uint32_t)c.h<<16);
    uint32_t eoff = (uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y<<16);
    assert(n == 3);
    assert(memcmp(tlbuf + eoff, ents, sizeof ents) == 0);
    printf("ok test_blt_tile_list\n");
}
```

Add `test_blt_tile_list();` to `main()`. (If `blt_unpack_cmd` does not exist, compare raw packed bytes via `blt_pack_cmd` of an expected header instead.)

- [ ] **Step 3: Run to verify it fails.**

Run: `cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c -o /tmp/blt_emit && /tmp/blt_emit`
Expected: FAIL — `blt_tile_list` undefined (compile/link error) before you implement it, or `CHECK` fails.

- [ ] **Step 4: Implement.** In `blt_emitter.c`:

```c
void blt_tile_list_init(blt_emitter_t *e, void *tl_buf, size_t tl_cap) {
    e->tl_buf = (uint8_t*)tl_buf; e->tl_cap = tl_cap; e->tl_used = 0;
}

int blt_tile_list(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                  uint16_t key, uint8_t alpha, uint8_t flags,
                  const blt_tile_entry_t *ents, int n) {
    if (!tex.valid || n <= 0) { e->overflow = 1; return -1; }
    size_t bytes = (size_t)n * sizeof(blt_tile_entry_t);
    if (e->tl_used + bytes > e->tl_cap) { e->overflow = 1; return -1; }
    uint32_t eoff = (uint32_t)e->tl_used;
    memcpy(e->tl_buf + e->tl_used, ents, bytes);
    e->tl_used += bytes;

    blt_cmd_t c; memset(&c, 0, sizeof c);
    c.opcode = BLT_OP_TILELIST; c.blend_mode = blend; c.flags = flags;
    c.format = tex.format;
    {   int use_sdram = (e->sdram_src && tex.sdram_off != BLT_ALLOC_FAIL);
        c.src_off = use_sdram ? tex.sdram_off : tex.off;
        if (use_sdram) c.flags |= BLT_F_SRC_SDRAM; }
    c.src_stride = tex.stride;
    c.src_x = tex.w; c.src_y = tex.h;                 /* texture bounds */
    c.w = (uint16_t)(n & 0xFFFF); c.h = (uint16_t)((unsigned)n >> 16);
    c.dst_x = (int16_t)(eoff & 0xFFFF); c.dst_y = (int16_t)(eoff >> 16);
    c.colorkey = key; c.alpha = alpha;
    return emit(e, &c);
}
```

And in `blt_begin_frame` (after `e->cmd_count = 0;`): add `e->tl_used = 0;`.

- [ ] **Step 5: Run to verify it passes.**

Run: `cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c -o /tmp/blt_emit && /tmp/blt_emit`
Expected: PASS — the self-test reports no failures / exit 0.

- [ ] **Step 6: Commit (in-tree only).**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c
git commit -m "feat(blitter): blt_tile_list emitter + tile-list buffer + self-test (#52)"
```

---

## Stage 2 — RTL + sim

### Task 4: Fabric `BLT_OP_TILELIST` FSM + bit-exact gating TB

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (command FSM)
- Create: `fpga/sim/tb_tilelist.sv`
- Modify: `fpga/sim/run_sims.sh` (register the TB)
- Reference: `fpga/rtl/blitter_defs.vh` (`OP_TILELIST`, `TL_BUF_BYTES`); existing `S_FETCH`/`S_DECODE`/`OP_STAGE` handling (`blitter_top.sv:400-470`); the `OP_BLIT` → `comp_pipeline` issue path; `comp_pipeline` instance ports (`blitter_top.sv:~616`).

**Interfaces:**
- Consumes: `OP_TILELIST`, command qword layout (`u32[0]=opcode|blend<<8|format<<16|flags<<24`, per `blitter_top.sv:19`), the existing per-blit issue handshake to `comp_pipeline`.
- Produces: a frame containing one `TILELIST` command renders `comp_fbram` identical to the same frame with the N blits expanded.

- [ ] **Step 1: Read the existing BLIT issue path.** Open `fpga/rtl/blitter_top.sv`; locate `S_DECODE` (line ~415) where `c_opcode`/`c_blend`/`c_format`/`c_flags` and the blit rect regs (`c_src_off`, `c_src_x`, `c_w`, `c_dst_x`, …) are latched from `cmd_qw`, and the state that issues a blit to `comp_pipeline` and waits for its done. Note the exact reg names and the issue/return states (these vary; the new states reuse them verbatim).

- [ ] **Step 2: Add tile-list registers + FSM states.** In the state localparam block, add `S_TL_FETCH`, `S_TL_LATCH`, `S_TL_ISSUE`, `S_TL_WAIT`. Add regs:

```verilog
reg [31:0] tl_count;      // N
reg [31:0] tl_idx;        // current entry
reg [31:0] tl_entry_ptr;  // byte offset of entry array in the tile-list buffer
reg [15:0] tl_tex_w, tl_tex_h;  // texture bounds (from c_src_x/c_src_y)
```

In `S_DECODE`, add a branch alongside `OP_STAGE`:

```verilog
else if (c_opcode==OP_TILELIST) begin
    // shared params already latched into c_src_off/c_src_stride/c_blend/
    // c_format/c_flags/c_alpha/c_colorkey by the common decode above.
    tl_count     <= cmd_qw[?][..];   // w | h<<16  (same words STAGE uses for size)
    tl_entry_ptr <= cmd_qw[?][..];   // dst_x | dst_y<<16
    tl_tex_w     <= c_src_x; tl_tex_h <= c_src_y;
    tl_idx       <= 32'd0;
    state        <= (tl_count==0) ? S_NEXT_CMD : S_TL_FETCH;
end
```

(Use the same `cmd_qw` word slices the decode already uses for `w`/`h` and `dst_x`/`dst_y`.)

- [ ] **Step 3: Read one entry, issue it as a blit, loop.** Implement the new states using the source-read master (the same one that fetches `cmd_qw`/atlas), reading 12 bytes at `TL_BUF_BASE + tl_entry_ptr + tl_idx*12`, then driving the existing comp issue with shared header params + the entry rect:

```verilog
S_TL_FETCH:  // request the 12-byte entry; on data ready -> S_TL_LATCH
S_TL_LATCH:  // c_src_x <= entry.src_x; c_src_y <= entry.src_y;
             // c_w <= entry.w; c_h <= entry.h;
             // c_dst_x <= entry.dst_x; c_dst_y <= entry.dst_y;  -> S_TL_ISSUE
S_TL_ISSUE:  // assert the SAME comp-issue handshake the OP_BLIT path uses
             //   -> S_TL_WAIT
S_TL_WAIT:   // on comp done: tl_idx<=tl_idx+1;
             //   state <= (tl_idx+1==tl_count) ? S_NEXT_CMD : S_TL_FETCH;
```

Define `TL_BUF_BASE` in `blitter_defs.vh` (placed above the command ring in the control region, double-buffered by `target_buf` exactly like the ring base selection).

- [ ] **Step 4: Write the bit-exact gating TB.** Create `fpga/sim/tb_tilelist.sv` modeled on an existing system TB (`tb_blitter_system_pipe.sv`). It must:
  1. Preload a tileset texture + an N-entry array into the simulated source/tile-list memory.
  2. Drive a frame with one `TILELIST` command; capture `comp_fbram`.
  3. Drive a second frame with the **N expanded BLIT** commands (same params); capture `comp_fbram`.
  4. `assert` the two framebuffers are identical; `$display("TB_TILELIST: PASS")` else `$fatal`.
  Cover cases (parameterized runs or sequential): N=1; N=5 overlapping dst (draw-order); a partial-offscreen entry; `BLT_BLEND_PALPHA` with an ARGB4444 texture; N large enough to span >1 source-fetch burst.

- [ ] **Step 5: Run the gate.**

Run: `cd fpga/sim && bash run_sims.sh tb_tilelist`
Expected: `TB_TILELIST: PASS`.

- [ ] **Step 6: Run the full suite (no regression).**

Run: `cd fpga/sim && bash run_sims.sh`
Expected: all pre-existing `tb_*` pass (BLIT/FILL/STAGE/snapshot unchanged).

- [ ] **Step 7: Commit.**

```bash
git add fpga/rtl/blitter_top.sv fpga/rtl/blitter_defs.vh fpga/sim/tb_tilelist.sv fpga/sim/run_sims.sh
git commit -m "feat(comp): BLT_OP_TILELIST fabric FSM + bit-exact tb_tilelist gate (#52)"
```

---

## Stage 3 — Engine batching (Solarus, software path first)

### Task 5: `TilePattern::get_draw_region` + Simple/Animated overrides

**Files:**
- Modify: `scripts/build_engine.sh` (new idempotent block, after the existing Entities/Game blocks)
- Targets (in `work/solarus`): `include/solarus/entities/TilePattern.h`, `src/entities/SimpleTilePattern.cpp`, `src/entities/AnimatedTilePattern.cpp`

**Interfaces:**
- Produces: `virtual bool TilePattern::get_draw_region(const Point& dst_position, const Tileset&, Rectangle& out_src, Point& out_dst) const;` returning `true` + `(src_rect, dst)` for batchable patterns, default `false`.

- [ ] **Step 1: Read the pattern draw bodies for exact src-rect computation.** Inspect `SimpleTilePattern::draw` (`work/solarus/src/entities/SimpleTilePattern.cpp:44-51`, uses `position_in_tileset`) and `AnimatedTilePattern::draw` (`:72-93`, computes `src` from the current frame). The override returns exactly that `src` + the passed `dst_position`.

- [ ] **Step 2: Add the `build_engine.sh` patch block.** Append after the Game.cpp tileset-timer block:

```bash
# 1g. [#52 tilelist] TilePattern::get_draw_region — draw-free (src_rect,dst) query
#     for batchable patterns (Simple/Animated). Default false (escape). Idempotent.
TPH="$SRC/include/solarus/entities/TilePattern.h"
if ! grep -q "get_draw_region" "$TPH"; then
  python3 - "$TPH" <<'PYTP'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="  virtual void draw("        # the existing pure/virtual draw decl
i=s.index(anchor)
decl=("  // [MiSTer #52] Draw-free batch query: return (src_rect,dst) without drawing.\n"
      "  // Default false = not batchable (caller draws normally).\n"
      "  virtual bool get_draw_region(const Point& dst_position, const Tileset& tileset,\n"
      "                               Rectangle& out_src, Point& out_dst) const { return false; }\n\n")
s=s[:i]+decl+s[i:]; open(p,"w").write(s)
print("TilePattern.h get_draw_region decl added")
PYTP
fi
# SimpleTilePattern override
STP="$SRC/src/entities/SimpleTilePattern.cpp"
if ! grep -q "get_draw_region" "$STP"; then
  python3 - "$STP" <<'PYSTP'
import sys
p=sys.argv[1]; s=open(p).read()
add=("\nbool SimpleTilePattern::get_draw_region(const Point& dst_position, const Tileset&,\n"
     "    Rectangle& out_src, Point& out_dst) const {\n"
     "  out_src = position_in_tileset; out_dst = dst_position; return true;\n}\n")
s=s.rstrip()+"\n"+add; open(p,"w").write(s)
print("SimpleTilePattern get_draw_region added")
PYSTP
  # mirror the decl in the class header
  sed_done=1
fi
# AnimatedTilePattern override (returns current-frame src)
ATP="$SRC/src/entities/AnimatedTilePattern.cpp"
if ! grep -q "get_draw_region" "$ATP"; then
  python3 - "$ATP" <<'PYATP'
import sys
p=sys.argv[1]; s=open(p).read()
# AnimatedTilePattern::draw computes `src` for the current frame; replicate that
# computation in a const query. The exact frame-index expression is copied from
# this file's draw() (read it; it indexes position_in_tileset[ current_frame ]).
add=("\nbool AnimatedTilePattern::get_draw_region(const Point& dst_position, const Tileset&,\n"
     "    Rectangle& out_src, Point& out_dst) const {\n"
     "  out_src = position_in_tileset[get_current_frame()];  // same src draw() uses\n"
     "  out_dst = dst_position; return true;\n}\n")
s=s.rstrip()+"\n"+add; open(p,"w").write(s)
print("AnimatedTilePattern get_draw_region added")
PYATP
fi
```

> Implementer note: add the matching override declarations to `SimpleTilePattern.h` / `AnimatedTilePattern.h` in the same block (a `grep -q get_draw_region` guard + a `sed`/python insert of `bool get_draw_region(...) const override;`). Confirm the animated frame accessor name against `AnimatedTilePattern.cpp` (`get_current_frame()` vs an internal index) before finalizing.

- [ ] **Step 3: Type-check the engine builds (no link yet).**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye bash -c 'scripts/build_engine.sh 2>&1 | tail -20'`
Expected: patch prints `TilePattern.h get_draw_region decl added` etc., and compilation of the three TUs succeeds (no errors).

- [ ] **Step 4: Commit.**

```bash
git add scripts/build_engine.sh
git commit -m "feat(engine): TilePattern::get_draw_region draw-free batch query (#52)"
```

---

### Task 6: `Renderer::draw_tile_batch` virtual + `SDLRenderer` fallback

**Files:**
- Modify: `scripts/build_engine.sh` (block targeting `include/solarus/graphics/Renderer.h`, `src/graphics/sdlrenderer/SDLRenderer.cpp`)

**Interfaces:**
- Produces:
  - `struct TileBatchEntry { Rectangle src; Point dst; };`
  - `virtual void Renderer::draw_tile_batch(const SurfaceImpl& tileset_image, BlendMode blend, const std::vector<TileBatchEntry>& entries);`
  - `SDLRenderer` override = loop `tileset_image.get_surface()->draw_region(e.src, dst_surface, e.dst)` (pixel-identical to per-tile today).

- [ ] **Step 1: Add the virtual + entry struct + software fallback** via a `build_engine.sh` block (guarded on `grep -q draw_tile_batch`). The base `Renderer::draw_tile_batch` default loops `draw_region` over `entries` against the batch's destination surface, exactly reproducing the current per-tile path; `SDLRenderer` inherits the default (no override needed unless an optimization is wanted). Declare `TileBatchEntry` in `Renderer.h`.

- [ ] **Step 2: Build + confirm the software path renders.** With `SOLARUS_BLITTER` unset (pure `SDLRenderer`) the default `draw_tile_batch` must produce identical frames to today (it's the same `draw_region` calls).

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye bash -c 'scripts/build_engine.sh 2>&1 | tail -5'`
Expected: build succeeds.

- [ ] **Step 3: Commit.**

```bash
git add scripts/build_engine.sh
git commit -m "feat(engine): Renderer::draw_tile_batch virtual + SDL fallback (#52)"
```

---

### Task 7: `MisterBlitterRenderer::draw_tile_batch` — fabric emit

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.h` (override decl)
- Modify: `patches/mister/mister_blitter_renderer.cpp` (impl + tile-list buffer wiring in the ctor)

**Interfaces:**
- Consumes: `blt_tile_list()`, `blt_tile_list_init()`, `blt_tile_entry_t`, `Renderer::draw_tile_batch`, the existing `upload()`/`map_blend()`/`alias_off_x/y` machinery.
- Produces: one `BLT_OP_TILELIST` per call (or per-entry `emit_draw` fallback on escape/upload-fail).

- [ ] **Step 1: Reserve the tile-list VRAM buffer.** In the ctor (where `OFF_RING`/`OFF_HEAP` and `blt_emitter_init` are set up, `mister_blitter_renderer.cpp:~136,576`), carve a double-buffered tile-list region from the DDR map and call `blt_tile_list_init(&em, ddr + OFF_TLBUF + target_buf*TL_BUF_BYTES, TL_BUF_BYTES)` at frame begin (re-point per `target_buf` like the ring). Add `constexpr uint32_t OFF_TLBUF = …;` above the heap so it never overlaps ring/heap.

- [ ] **Step 2: Implement `draw_tile_batch`.**

```cpp
void MisterBlitterRenderer::draw_tile_batch(const SurfaceImpl& tileset_image,
        BlendMode blend, const std::vector<TileBatchEntry>& entries) {
  if (d->blitter_off() || entries.empty()) {           // pass-through / scene_too_big
    Renderer::draw_tile_batch(tileset_image, blend, entries); return;
  }
  uint8_t bl, fl, want_fmt; uint16_t key; uint8_t cr,cg,cb; int why=0;
  if (!d->map_blend_for_tiles(tileset_image, blend, bl, key, fl, want_fmt)) {  // no transform/colormod
    d->draw_tile_batch_fallback(tileset_image, blend, entries); return;        // loop emit_draw
  }
  blt_surface_ref_t tex = d->upload(tileset_image, want_fmt);
  if (!tex.valid) { d->draw_tile_batch_fallback(tileset_image, blend, entries); return; }
  d->ensure_frame();
  std::vector<blt_tile_entry_t> es; es.reserve(entries.size());
  for (auto& e : entries) {
    int dx=e.dst.x + d->alias_off_x, dy=e.dst.y + d->alias_off_y;
    es.push_back({(uint16_t)e.src.get_x(),(uint16_t)e.src.get_y(),
                  (uint16_t)e.src.get_width(),(uint16_t)e.src.get_height(),
                  (int16_t)dx,(int16_t)dy});
  }
  blt_tile_list(&d->em, tex, bl, key, 255, fl, es.data(), (int)es.size());
  if (d->diag) d->g_alias_blits += es.size();
}
```

(`map_blend_for_tiles` is a thin wrapper over the existing `map_blend` for the tile case — opaque/colorkey/const-alpha/palpha only, no rotation/scale/colormod; on anything else return false → fallback. `draw_tile_batch_fallback` loops the existing `emit_draw` per entry.)

- [ ] **Step 3: Type-check the renderer (native, fast).** Use the `fpga-renderer-native-typecheck` recipe (`g++ -fsyntax-only` with the generated config + glm paths) to validate `mister_blitter_renderer.cpp` without the full Docker build.

Expected: no syntax errors.

- [ ] **Step 4: Full engine build.**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye bash -c 'scripts/build_engine.sh 2>&1 | tail -5'`
Expected: `build/armhf/libsolarus.so.1.6.5` rebuilt; `nm -D` shows no undefined `blt_tile_list`.

- [ ] **Step 5: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h
git commit -m "feat(comp): MisterBlitterRenderer::draw_tile_batch -> BLT_OP_TILELIST (#52)"
```

---

### Task 8: `Entities::draw` batched loop + `SOLARUS_TILEBATCH` gate

**Files:**
- Modify: `scripts/build_engine.sh` (block targeting `src/entities/Entities.cpp`, the `tiles_in_animated_regions` loop at `:1216-1241`)

**Interfaces:**
- Consumes: `TilePattern::get_draw_region` (Task 5), `Renderer::draw_tile_batch` (Task 6), `tileset.get_tiles_image()`.
- Produces: when `SOLARUS_TILEBATCH` is set (default), the animated-tile loop collects per-`(tileset_image, blend, flags)` batches with flush-on-break and emits via `draw_tile_batch`; otherwise the unchanged per-tile `tile.draw()` path.

- [ ] **Step 1: Add the `build_engine.sh` block** (after Task 5's block; guarded on `grep -q SOLARUS_TILEBATCH "$ENT"`). It replaces the animated-tile loop body with the collect-then-flush form from the spec (Section "Engine-side batching"), keyed on `tile.get_tile_pattern().get_draw_region(...)`, flushing open batches before any escape `tile.draw()` or bucket change, and a final `flush_all_batches()` after the loop. Read the env once: `static const bool tilebatch = (std::getenv("SOLARUS_TILEBATCH")==nullptr) || std::atoi(std::getenv("SOLARUS_TILEBATCH"));` (default on; `=0` disables). When `!tilebatch`, take the original `tile.draw(*camera)` path verbatim.

- [ ] **Step 2: Build.**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye bash -c 'scripts/build_engine.sh 2>&1 | tail -8'`
Expected: prints `Entities.cpp tilebatch loop injected`; build succeeds.

- [ ] **Step 3: Software-path A/B (host, no fabric).** Build the engine and run a short headless software session (`SOLARUS_SW=1`, dummy video) twice — `SOLARUS_TILEBATCH=1` vs `=0` — dumping a frame hash. They must match (the `draw_tile_batch` default == per-tile `draw_region`). If a headless frame-hash harness is unavailable, defer this to the HW A/B in Task 9 and note it.

- [ ] **Step 4: Commit.**

```bash
git add scripts/build_engine.sh
git commit -m "feat(engine): Entities::draw animated-tile batching (SOLARUS_TILEBATCH) (#52)"
```

---

## Stage 4 — RBF + HW bring-up

### Task 9: RBF build, coupled deploy, A/B + success-metric capture

**Files:**
- Use: `deploy.py`, `games/Solarus/diag.env`
- Reference: memory `fpga-deploy-refresh-from-build-armhf` (refresh `deploy/` from `build/armhf`), `solarus-ssh-launch-dies-on-disconnect` (user launches via OSD), the `[blitter drawcat]`/`[blitter engcpp]`/`[blitter timing]` banners.

**Interfaces:**
- Consumes: the RTL (Task 4), the engine (Tasks 5-8).

- [ ] **Step 1: Build the RBF (seed-pinned).** Trigger the CI/Quartus build with `SEED 1` (per `Solarus.qsf`). Confirm timing closes (clk_sys + pll_hdmi non-negative slack) before deploying.

- [ ] **Step 2: Refresh deploy artifacts.**

```bash
cp build/armhf/libsolarus.so.1.6.5 build/armhf/solarus-run deploy/libs/ deploy/   # per the layout
strings build/armhf/libsolarus.so.1.6.5 | grep -c "blitter drawcat"   # expect 1
```

- [ ] **Step 3: Coupled deploy (RBF + engine).** Push together via `deploy.py` (or the staged scp + stop/swap recipe). Verify deployed `libsolarus` sha1 == `build/armhf` sha1; verify the new RBF is the loaded core.

- [ ] **Step 4: HW A/B — identical pixels.** With the user launching via OSD (ssh launch dies on disconnect): in a **static** heavy-area spot, screenshot with `SOLARUS_TILEBATCH=1`, then `=0` (set in `diag.env`, relaunch), and diff. Expected: pixel-identical (or within the known scanout tolerance). A mismatch = a draw-order/escape bug → do not ship.

- [ ] **Step 5: Success-metric capture.** With `SOLARUS_TILEBATCH=1` + `SOLARUS_BLITTER_DIAG=1`, park in the heavy area ~15s and read the banner. Expected (per spec):

| Signal | Before | Target |
|---|---|---|
| `emit` | ~112ms | ~5-15ms |
| `[blitter drawcat]` host tile-list cmds | 3,758 draws | ~1-3 cmds |
| `A9` | ~137ms | ~25-35ms |
| `fps` | ~6.7 | ~35-42 |

Cross-check fps with `C_SUBMIT` delta. Ship criterion: A/B-identical **and** measured A9/emit drop near the fabric floor.

- [ ] **Step 6: Commit results + update issue #52.** Record the measured before/after in an issue #52 comment and the `solarus-blackscreen-engine-hang-diagnosis` memory. If fps stalls short of ~40 with `emit` collapsed, the next limiter is the fabric floor (deferred animated-region-caching lever), not this work.

```bash
git add docs/superpowers/plans/2026-06-27-dumb-emitter-tilelist.md
git commit -m "docs(comp): tile-list HW results (#52)"
```

---

## Self-review notes (addressed)

- **Spec coverage:** ABI (T1), reference model + golden (T2), emitter + VRAM buffer (T3), fabric FSM + sim gate (T4), engine query/virtual/fallback/loop (T5-8), RBF/deploy/measure (T9). All spec sections mapped.
- **Flip-flags** batch key handled in T7/T8 (flags in the bucket key; non-batchable patterns escape).
- **Vendoring** enforced in T1-3 (upstream edit + re-copy, both repos committed).
- **Known soft spots flagged for the implementer:** the exact `AnimatedTilePattern` current-frame src accessor (T5), the precise `cmd_qw` word slices for `w|h`/`dst` in `S_DECODE` (T4), and the `blt_unpack_cmd` availability (T3) — each step says to confirm against the file before finalizing rather than assuming.
