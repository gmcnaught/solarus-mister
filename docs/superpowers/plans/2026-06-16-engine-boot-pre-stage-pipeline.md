# Engine Boot Pre-Stage Pipeline (Task #33) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Load the whole quest's static image atlas into SDRAM once, with each source at an SDRAM offset **independent of the 16MB DDR3 heap**, so blits read sources off the SDRAM bus (`C_SRCSEL=1`) and the f2h DDR3 bus carries only scanout + framebuffer writes.

**Architecture — two phases by testability:**
- **Phase 1 (host, pure C, TDD here):** give the emitter a *second* offset allocator over the SDRAM space (reuse `blt_alloc_t`), a per-source `sdram_off`, a `blt_stage_surface()` that allocates an SDRAM offset and emits `blt_stage_to(ddr_bounce, sdram_off, size)` (from #32), and a `sdram_src` mode where `blt_blit` emits `c.src_off = sdram_off`. This is the mechanism, unit-testable against the emitter with no hardware.
- **Phase 2 (engine C++, on-device validated under #34):** wire `mister_blitter_renderer.cpp` to drive Phase 1 — enumerate the quest's tileset/sprite resources at mount, decode to RGB565, and for each: upload to a small DDR3 *bounce*, `blt_stage_surface`, then free the DDR3 bounce (DDR3 holds one source at a time; the resident set lives in SDRAM). All under the boot screen → no STAGE during gameplay frames.

**Tech Stack:** C (host emitter + `tests/run_tests.sh` native cc), C++ (Solarus renderer, armhf Docker cross-build — not natively buildable here, so Phase 2 is on-device validated). Reuses #32's `blt_stage_to` + `BLT_F_STAGE_DST`.

**Why the emitter owns the SDRAM allocator:** the emitter already owns the DDR3 heap allocator (`blt_alloc`) and builds blit commands (`blt_blit` picks `src_off`), so the SDRAM offset space + source-select belong at the same layer — and that layer is host-testable, unlike the C++ renderer.

**Backward-compat:** the SDRAM allocator + `sdram_src` are opt-in (`blt_sdram_init`); unused → `sdram_off = BLT_ALLOC_FAIL`, `blt_blit` uses `s.off`, byte-identical to today. `blt_stage` (#19) and `blt_stage_to` (#32) unchanged.

---

## File Structure

- `patches/mister/blitter/blt_emitter.h` — **modify**: `sdram_alloc`+`sdram_src` in `blt_emitter_t`; `sdram_off` in `blt_surface_ref_t`; declare `blt_sdram_init`, `blt_stage_surface`.
- `patches/mister/blitter/blt_emitter.c` — **modify**: `blt_sdram_init`; `blt_stage_surface`; init `sdram_off=BLT_ALLOC_FAIL` in `blt_upload`/`blt_upload_argb4444`; source-select in `blt_blit`.
- `tests/blt_sdram_vram_test.c` — **create**: TDD for allocate/stage/resolve.
- `tests/run_tests.sh` — **modify**: build+run the new test.
- `patches/mister/mister_blitter_renderer.cpp` — **modify (Phase 2)**: boot enumerate+decode+stage; switch the lazy `blt_stage` path to `blt_stage_surface`; DDR3 bounce free policy.

---

## Phase 1 — Host-testable emitter SDRAM-VRAM core

### Task 1: Failing test — allocate distinct SDRAM offset, stage, resolve

**Files:** Create `tests/blt_sdram_vram_test.c`; add to `tests/run_tests.sh`.

- [ ] **Step 1: Write the failing test**

`tests/blt_sdram_vram_test.c`:
```c
/* [MiSTer #33] Host test: emitter SDRAM-VRAM allocator + decoupled staging +
 * blit source-select. Pure C, no device. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

static blt_cmd_t ring_read(const blt_emitter_t *e, int n){
    blt_cmd_t c; memset(&c,0,sizeof c); blt_unpack_cmd(e->ring + (size_t)n*BLT_CMD_BYTES, &c); return c;
}

int main(void){
    static uint8_t ring[64*BLT_CMD_BYTES];
    static uint8_t heap[64*1024];
    static uint16_t px[16*16];
    for (int i=0;i<16*16;i++) px[i]=(uint16_t)(0x1000+i);

    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_sdram_init(&e, 1u<<20);             /* 1 MiB SDRAM space for the test */
    blt_begin_frame(&e, 0, 0, 0);

    /* upload two surfaces into the DDR3 heap */
    blt_surface_ref_t a = blt_upload(&e, px, 16, 16, 16*2);
    blt_surface_ref_t b = blt_upload(&e, px, 16, 16, 16*2);
    CHECK(a.valid && b.valid, "uploads valid");
    CHECK(a.sdram_off == BLT_ALLOC_FAIL, "fresh upload is unstaged (sdram_off=FAIL)");

    /* stage each to SDRAM: distinct, non-overlapping sdram offsets */
    int rs = blt_stage_surface(&e, &a);
    CHECK(rs == 0, "stage a returns 0");
    int before = e.cmd_count;
    blt_stage_surface(&e, &b);
    CHECK(a.sdram_off != BLT_ALLOC_FAIL && b.sdram_off != BLT_ALLOC_FAIL, "both staged");
    CHECK(a.sdram_off != b.sdram_off, "distinct SDRAM offsets");
    CHECK(b.sdram_off >= a.sdram_off + a.size || a.sdram_off >= b.sdram_off + b.size, "non-overlapping");

    /* the stage command for b: STAGE_DST flag, src_off=b.off (DDR bounce),
     * u32[2]=b.sdram_off, size=b.size */
    blt_cmd_t sc = ring_read(&e, before);
    CHECK(sc.opcode == BLT_OP_STAGE,        "stage cmd opcode");
    CHECK(sc.flags & BLT_F_STAGE_DST,       "stage cmd has STAGE_DST");
    CHECK(sc.src_off == b.off,              "stage cmd src_off = DDR bounce off");
    CHECK(((uint32_t)sc.src_x<<16 | sc.src_stride) == b.sdram_off, "stage cmd u32[2] = sdram off");

    /* with sdram_src on (set by blt_sdram_init), a blit reads from sdram_off */
    int bi = e.cmd_count;
    blt_blit(&e, a, 0,0, 16,16, 5,5, BLT_BLEND_COPY, 0, 255, 0);
    blt_cmd_t bc = ring_read(&e, bi);
    CHECK(bc.opcode == BLT_OP_BLIT,         "blit opcode");
    CHECK(bc.src_off == a.sdram_off,        "blit src_off = SDRAM offset (sdram_src mode)");
    CHECK(bc.src_stride == a.stride,        "blit stride preserved");

    if (failures==0){ printf("ALL PASS\n"); return 0; }
    printf("%d FAILURE(S)\n", failures); return 1;
}
```

- [ ] **Step 2: Add to `tests/run_tests.sh`**

After the `blt_stage` block, add:
```bash
echo "== blt_sdram_vram (issue #33 SDRAM-VRAM allocator + staging) =="
cc -I patches/mister/blitter \
    tests/blt_sdram_vram_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_sdram_vram_test
/tmp/blt_sdram_vram_test
```

- [ ] **Step 3: Run — expect FAIL (undeclared `blt_sdram_init`/`blt_stage_surface`, no `sdram_off`)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
cc -I patches/mister/blitter tests/blt_sdram_vram_test.c patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c -o /tmp/blt_sdram_vram_test 2>&1 | grep -iE 'sdram_off|blt_sdram_init|blt_stage_surface|error' | head
```
Expected: compile errors — `blt_sdram_init`, `blt_stage_surface` undeclared; `sdram_off` not a member.

### Task 2: Implement the emitter SDRAM-VRAM core

**Files:** `patches/mister/blitter/blt_emitter.h`, `blt_emitter.c`.

- [ ] **Step 1: Header — struct fields + declarations**

In `blt_emitter.h`, add to `blt_emitter_t` (after the `blt_alloc_t alloc;` member):
```c
    blt_alloc_t sdram_alloc;  /* [#33] SDRAM VRAM offset space (decoupled from DDR3 heap) */
    int         sdram_src;    /* [#33] 1 = blits read sources from SDRAM (C_SRCSEL=1)     */
```
Add to `blt_surface_ref_t` (after `uint32_t size;`):
```c
    uint32_t sdram_off;  /* [#33] this surface's SDRAM offset, or BLT_ALLOC_FAIL if unstaged */
```
Declare (near `blt_stage_to`):
```c
/* [MiSTer #33] Enable SDRAM-VRAM mode: init the SDRAM offset allocator over
 * [0, sdram_cap) and route blit source reads to staged SDRAM offsets. */
void blt_sdram_init(blt_emitter_t *e, uint32_t sdram_cap);

/* [MiSTer #33] Allocate an SDRAM offset for `r` and emit blt_stage_to to copy it
 * DDR3(r->off bounce) -> SDRAM(r->sdram_off). Sets r->sdram_off (and the caller's
 * registry copy). Returns 0, or -1 + e->overflow on SDRAM-full / ring-full. */
int  blt_stage_surface(blt_emitter_t *e, blt_surface_ref_t *r);
```

- [ ] **Step 2: blt_emitter.c — implement + wire source-select**

Add `#include "blt_alloc.h"` if not present. Implement:
```c
void blt_sdram_init(blt_emitter_t *e, uint32_t sdram_cap)
{
    blt_alloc_init(&e->sdram_alloc, 0u, sdram_cap);
    e->sdram_src = 1;
}

int blt_stage_surface(blt_emitter_t *e, blt_surface_ref_t *r)
{
    if (!r->valid) { e->overflow = 1; return -1; }
    uint32_t soff = blt_alloc(&e->sdram_alloc, r->size);
    if (soff == BLT_ALLOC_FAIL) { e->overflow = 1; return -1; }
    r->sdram_off = soff;
    return blt_stage_to(e, r->off, soff, r->size);
}
```
In `blt_upload` AND `blt_upload_argb4444`, set the new field on the returned ref (where `r.off`/`r.size` are set):
```c
    r.sdram_off = BLT_ALLOC_FAIL;   /* [#33] unstaged until blt_stage_surface */
```
In `blt_blit`, replace the `c.src_off = s.off;` assignment with the source-select:
```c
    c.src_off = (e->sdram_src && s.sdram_off != BLT_ALLOC_FAIL) ? s.sdram_off : s.off;
    c.src_stride = s.stride;
```
(`blt_emitter_init` already `memset`s the emitter to 0, so `sdram_src=0` and `sdram_alloc` is inert until `blt_sdram_init` — existing callers unchanged.)

- [ ] **Step 3: Run the test — expect ALL PASS**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
cc -I patches/mister/blitter tests/blt_sdram_vram_test.c patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c -o /tmp/blt_sdram_vram_test && /tmp/blt_sdram_vram_test
```
Expected: `ALL PASS`.

- [ ] **Step 4: Full host suite (regression — blt_stage/blt_alloc/etc. unaffected)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash tests/run_tests.sh 2>&1 | tail -20
```
Expected: every block `ALL PASS` (the `sdram_off` field + source-select don't disturb the DDR3-default path).

- [ ] **Step 5: Commit Phase 1**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c tests/blt_sdram_vram_test.c tests/run_tests.sh docs/superpowers/plans/2026-06-16-engine-boot-pre-stage-pipeline.md
git commit -m "feat(#33): emitter SDRAM-VRAM allocator + decoupled staging (host core)

blt_sdram_init opens a 2nd blt_alloc over the SDRAM offset space; blt_stage_surface
allocates an SDRAM offset and emits blt_stage_to (DDR3 bounce -> SDRAM); blt_blit
reads from sdram_off in sdram_src mode. Opt-in: unused = byte-identical DDR3 path.
Host test tests/blt_sdram_vram_test.c. Engine wiring + boot enumerate is Phase 2.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — Engine integration (C++ renderer; on-device validated under #34)

NOT natively buildable here (Solarus + SDL armhf cross-build), so these are design-level steps implemented in `mister_blitter_renderer.cpp` and validated on hardware in #34. Each follows the existing #19 stage path (`stage_enabled`, the `handles` map, `blt_upload`+`blt_stage`).

- [ ] **P2.1 — SDRAM-VRAM mode wiring.** On init when `SOLARUS_SDRAM_SRC` is set, call `blt_sdram_init(&em, SDRAM_CAP)` (SDRAM_CAP = 64MB = `0x4000000`, the AS4C32M16 single-chip max from #31). The existing `C_SRCSEL=1` publish (renderer L1505) already matches `sdram_src`.
- [ ] **P2.2 — Switch lazy staging to decoupled.** Replace the `if (stage_enabled) blt_stage(&em, r.off, r.size);` calls (renderer L853/L810) with `blt_stage_surface(&em, &r);` so each staged source gets a distinct SDRAM offset (and the `handles` map records `sdram_off`). This alone converts the existing lazy-stage path to the decoupled model (Approach B fallback).
- [ ] **P2.3 — Boot bulk pre-stage (Approach A).** At quest mount, enumerate every staging-eligible static image source and stage it. Concrete Solarus API (verified in `work/solarus`, `include/solarus/core/CurrentQuest.h`):
  - `Solarus::CurrentQuest::get_resources(ResourceType::TILESET)` → `const std::map<std::string,std::string>&` of all tileset ids (no map instantiation). Same for `ResourceType::SPRITE`. This is the enumerator (satisfies "without running each map").
  - For each tileset id: load its tiles image `tilesets/<id>.tiles.png` as a `Surface` (`src/entities/Tileset.cpp` loads exactly this); for each sprite id: its animation-set images (`sprites/<id>.dat` references the PNGs — `src/graphics/Sprite.cpp`/`AnimationSet`). Decode each to RGB565.
  - Per image: `blt_upload` into a DDR3 *bounce*, `blt_stage_surface(&em,&r)`, then `blt_emitter_free(&em, r.off, r.size)` so the 16MB DDR3 heap holds one source at a time; the resident set lives in 64MB SDRAM. Record the handle→`r` (with `sdram_off`) in a registry the runtime blit path resolves against (so gameplay blits of that surface reuse the staged `sdram_off`).
  - Run before the first gameplay frame (boot/black screen) → no STAGE during gameplay.
  - **Interplay caveat (must handle when compiling):** the existing bg-cache path (`bg_handle`, `BGCACHE_HEAP_OFF`, the `C_TARGET=2` compose + `blt_stage` chunks at renderer L699-702) is a render *target* read back as a source — it is NOT an upload-once atlas source and must keep its current same-region staging (or get its own `sdram_off`), NOT go through `blt_stage_surface`. Reconcile this before flipping the lazy path (P2.2).
- [ ] **P2.4 — Eligibility + residency.** Stage only upload-once-never-written surfaces (tileset/sprite atlases). Dynamic render targets (camera/root, bg-cache, rendered text) stay in DDR3. Confirm the Solarus resource API enumerates all tileset/sprite ids at mount without instantiating each map.
- [ ] **P2.5 — On-device (under #34).** Real game renders from SDRAM in a dynamic scrolling scene with no black-screen starvation; measure staged-atlas size (<< 64MB), fps, boot time.

---

## Self-Review notes (author)

- **Spec coverage:** #33 AC "SDRAM bump allocator, non-overlapping monotonic offsets, handle→{sdram_off,w,h,stride}" → Phase 1 (`sdram_alloc` + `sdram_off` on the ref, which already carries w/h/stride). "Per source memcpy→DDR3 bounce→stage" → Phase 1 `blt_stage_surface` (mechanism) + Phase 2 P2.3 (boot loop). "Emitter resolves handle→SDRAM offset" → Phase 1 `blt_blit` source-select. "Enumerate at mount / boot-only / eligibility" → Phase 2 P2.3/P2.4. "Host test" → Task 1.
- **Testability honesty:** only Phase 1 is verifiable here (pure C). Phase 2 lives in the C++ renderer (no native build) → on-device validated under #34. The plan does not pretend otherwise.
- **Consistency:** `sdram_off` sentinel = `BLT_ALLOC_FAIL` (set in `blt_upload`); `SDRAM_CAP=0x4000000` matches #31's 64MB; `blt_stage_to`/`BLT_F_STAGE_DST` from #32 unchanged.
