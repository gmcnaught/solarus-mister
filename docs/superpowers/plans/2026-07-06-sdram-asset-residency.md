# SDRAM Asset Residency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace lazy per-scene atlas staging with a one-time, whole-quest, permanent SDRAM residency model, and give mutable intermediate surfaces their own recycled region + destruction hook.

**Architecture:** At quest open, walk the quest data tree and stage every image file once into a permanent (never-freed) SDRAM region via the existing `BLT_OP_STAGE` fabric copy. File-cache surfaces (stable, quest-lifetime pointers) are classified immutable; everything else (menu/text/render-target intermediates) stages into a small recycled region and is reclaimed on surface destruction. This lets us delete `scene_too_big`/escape, `heap_reset`/transition-reclaim, and static `dirty_src`. No new RTL in v1.

**Tech Stack:** C (emitter/allocator, host-tested), C++17 (Solarus renderer, type-checked natively + HW-validated), MiSTer FPGA fabric (`BLT_OP_STAGE`, unchanged), Solarus 1.6.5 (`Surface`/`QuestFiles` APIs).

## Global Constraints

- **Pixel formats:** sources are 16bpp — RGB565 (opaque/colorkey/const-alpha) or ARGB4444 (per-pixel alpha). Size test is format-independent: `w*h*2` bytes.
- **SDRAM:** single 64 MiB chip, `SDRAM_AW = 23`. Region bases in the renderer MUST match `fpga/rtl/vram_defs.vh` / fabric (`SDRAM_ATLAS_BASE`, `SDRAM_FB0/1_BASE`). **No RTL change in v1.**
- **Transport:** the A9 CANNOT write SDRAM. Every byte goes A9 → DDR3 bounce heap → `BLT_OP_STAGE` fabric copy → SDRAM. Reuse `BLT_OP_STAGE`; do not invent a new transport.
- **Overflow:** permanent-region exhaustion is a **loud fatal abort** (no runtime fallback). DDR3 bounce exhaustion during preload is **recoverable** (drain + reset bounce + retry).
- **Blits always read sources from SDRAM** via the per-command `BLT_F_SRC_SDRAM` flag (`r.sdram_off`); the DDR3 `off` is only a transient bounce.
- **Verification convention:**
  - Emitter/allocator (C, host-buildable): true TDD — failing test → implement → passing test, via `bash tests/run_tests.sh`.
  - Renderer (`mister_blitter_renderer.cpp`, only cross-builds): per-task gate is a clean native **type-check** (recipe below); the phase-end HW deploy is the real behavioral validation. This is the documented reality for this TU — do not claim behavioral success from a type-check alone.
- **Renderer type-check command** (exit 0 = clean; run from repo root; inline the `-I` flags — zsh does not word-split unquoted `$VAR`):
  ```
  g++ -std=c++17 -fsyntax-only \
    -I patches/mister -I work/solarus/include -I build/armhf/include \
    -I work/solarus/libraries/win32/mingw32/include \
    -I/opt/homebrew/include -I/opt/homebrew/include/SDL2 -D_THREAD_SAFE \
    patches/mister/mister_blitter_renderer.cpp
  ```

---

## File Structure

**Created:**
- `tests/blt_sdram_regions_test.c` — host test for the permanent/intermediate allocator split.

**Modified:**
- `patches/mister/blitter/blt_emitter.h` — `sdram_perm` allocator + `perm_overflow` field; `blt_sdram_regions_init` / `blt_stage_surface_perm` decls.
- `patches/mister/blitter/blt_emitter.c` — implement the two new functions.
- `tests/run_tests.sh` — register the new test.
- `patches/mister/mister_blitter_renderer.cpp` — region constants, immutable classification, preload driver, `submit_and_drain()` helper, `mister_forget_surface`, deletions.
- `patches/mister/mister_blitter_renderer.h` — export `mister_forget_surface`.
- `scripts/build_engine.sh` — `edit_inplace` to call `mister_forget_surface` from `~SurfaceImpl`.

---

## Phase A — Emitter permanent-region allocator (host-TDD)

### Task 1: Split SDRAM into permanent + intermediate allocators

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h` (struct ~L44-49; decls ~L171-181)
- Modify: `patches/mister/blitter/blt_emitter.c` (`blt_sdram_init` ~L232; add new fns after)
- Create: `tests/blt_sdram_regions_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Consumes: `blt_alloc_t`, `blt_alloc_init`, `blt_alloc`, `blt_stage_to`, `blt_surface_ref_t{off,size,sdram_off,valid}`, `BLT_ALLOC_FAIL` (existing).
- Produces:
  - `void blt_sdram_regions_init(blt_emitter_t *e, uint32_t perm_base, uint32_t perm_size, uint32_t inter_base, uint32_t inter_size);` — inits both allocators, sets `sdram_src=1`.
  - `int blt_stage_surface_perm(blt_emitter_t *e, blt_surface_ref_t *r);` — alloc from `sdram_perm` (never freed); on region-full sets `e->perm_overflow=1` and returns `-1`; else emits the DDR3→SDRAM stage and returns `0`.
  - New field `int perm_overflow;` on `blt_emitter_t` (distinct from `overflow`, which stays the bounce/ring signal).

- [ ] **Step 1: Write the failing test** — `tests/blt_sdram_regions_test.c`

```c
/* [residency] Host test: permanent vs intermediate SDRAM allocator split.
 * perm is grow-only (never freed); intermediate frees on evict; regions disjoint. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include "blt_alloc.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

int main(void){
    static uint8_t  ring[64*BLT_CMD_BYTES];
    static uint8_t  heap[64*1024];
    static uint16_t px[16*16];
    for (int i=0;i<16*16;i++) px[i]=(uint16_t)(0x1000+i);

    blt_emitter_t e;
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    /* perm [0, 64KiB), intermediate [64KiB, 128KiB) — disjoint */
    blt_sdram_regions_init(&e, 0u, 0x10000u, 0x10000u, 0x10000u);
    CHECK(e.sdram_src == 1, "regions_init enables sdram_src");
    blt_begin_frame(&e, 0, 0, 0);

    /* two permanent stages: land in perm range, distinct, non-overlapping */
    blt_surface_ref_t a = blt_upload(&e, px, 16, 16, 16*2);
    blt_surface_ref_t b = blt_upload(&e, px, 16, 16, 16*2);
    CHECK(blt_stage_surface_perm(&e, &a) == 0, "perm stage a ok");
    CHECK(blt_stage_surface_perm(&e, &b) == 0, "perm stage b ok");
    CHECK(a.sdram_off < 0x10000u && b.sdram_off < 0x10000u, "perm offsets in perm range");
    CHECK(a.sdram_off != b.sdram_off, "perm offsets distinct");
    CHECK(e.perm_overflow == 0, "no perm overflow yet");

    /* intermediate stage lands in intermediate range, above perm */
    blt_surface_ref_t c = blt_upload(&e, px, 16, 16, 16*2);
    CHECK(blt_stage_surface(&e, &c) == 0, "intermediate stage ok");
    CHECK(c.sdram_off >= 0x10000u && c.sdram_off < 0x20000u, "intermediate offset in inter range");

    /* intermediate frees and reuses; perm never returns to the intermediate pool */
    uint32_t coff = c.sdram_off;
    blt_sdram_free(&e, &c);
    CHECK(c.sdram_off == BLT_ALLOC_FAIL, "freed intermediate ref reset");
    blt_surface_ref_t d = blt_upload(&e, px, 16, 16, 16*2);
    blt_stage_surface(&e, &d);
    CHECK(d.sdram_off == coff, "intermediate slot reused after free");

    /* perm exhaustion: loud signal via perm_overflow, returns -1, does NOT touch e.overflow */
    e.overflow = 0;
    int rc = 0;
    for (int i=0;i<200 && rc==0;i++){
        blt_surface_ref_t big = blt_upload(&e, px, 16, 16, 16*2); /* 512 B each in perm */
        big.sdram_off = BLT_ALLOC_FAIL;
        rc = blt_stage_surface_perm(&e, &big);
    }
    CHECK(rc == -1, "perm overflow returns -1");
    CHECK(e.perm_overflow == 1, "perm overflow sets perm_overflow flag");
    CHECK(e.overflow == 0, "perm overflow does NOT set bounce overflow flag");

    printf(failures ? "FAILED (%d)\n" : "ok blt_sdram_regions\n", failures);
    return failures ? 1 : 0;
}
```

- [ ] **Step 2: Register the test in `tests/run_tests.sh`**

Insert after the `blt_sdram_vram` block (after its `/tmp/blt_sdram_vram_test` run line):

```bash
echo "== blt_sdram_regions (residency: perm vs intermediate split) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_sdram_regions_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_sdram_regions_test
/tmp/blt_sdram_regions_test
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/run_tests.sh 2>&1 | sed -n '/blt_sdram_regions/,$p'`
Expected: FAIL — link error `undefined reference to 'blt_sdram_regions_init'` / `blt_stage_surface_perm` (and `perm_overflow` unknown field → compile error).

- [ ] **Step 4: Add struct field + decls to `blt_emitter.h`**

In the `blt_emitter_t` struct, immediately after `blt_alloc_t sdram_alloc;` and `int sdram_src;` (~L49-50) add:

```c
    /* [residency] permanent immutable-atlas allocator over the SDRAM perm region.
     * Grow-only: blt_stage_surface_perm allocates; nothing ever frees it (whole-quest
     * assets are resident for the quest lifetime). Disjoint from sdram_alloc. */
    blt_alloc_t sdram_perm;
    int         perm_overflow;  /* set when the perm region is exhausted (loud-fatal upstream) */
```

Alongside the existing `blt_sdram_init` decl (~L171) add:

```c
/* [residency] Init BOTH SDRAM sub-allocators: perm (immutable, never freed) and
 * inter (recycled intermediates). Enables sdram_src. Supersedes blt_sdram_init. */
void blt_sdram_regions_init(blt_emitter_t *e, uint32_t perm_base, uint32_t perm_size,
                            uint32_t inter_base, uint32_t inter_size);

/* [residency] Stage `r` into the PERMANENT region (idempotent on re-stage). On perm
 * exhaustion sets e->perm_overflow and returns -1. Otherwise emits DDR3->SDRAM stage. */
int  blt_stage_surface_perm(blt_emitter_t *e, blt_surface_ref_t *r);
```

- [ ] **Step 5: Implement both functions in `blt_emitter.c`**

Immediately after the existing `blt_sdram_init` definition (~L236) add:

```c
/* [residency] Two disjoint SDRAM allocators: perm (grow-only) + inter (recycled). */
void blt_sdram_regions_init(blt_emitter_t *e, uint32_t perm_base, uint32_t perm_size,
                            uint32_t inter_base, uint32_t inter_size)
{
    blt_alloc_init(&e->sdram_perm,  perm_base,  perm_size);
    blt_alloc_init(&e->sdram_alloc, inter_base, inter_size);
    e->perm_overflow = 0;
    e->sdram_src = 1;
}

/* [residency] Stage into the permanent region. Never freed; perm_overflow on exhaustion. */
int blt_stage_surface_perm(blt_emitter_t *e, blt_surface_ref_t *r)
{
    if (!r->valid) { e->overflow = 1; return -1; }
    if (r->sdram_off == BLT_ALLOC_FAIL) {
        uint32_t soff = blt_alloc(&e->sdram_perm, r->size);
        if (soff == BLT_ALLOC_FAIL) { e->perm_overflow = 1; return -1; }
        r->sdram_off = soff;
    }
    return blt_stage_to(e, r->off, r->sdram_off, r->size);
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/run_tests.sh 2>&1 | sed -n '/blt_sdram_regions/,$p'`
Expected: `ok blt_sdram_regions` and the whole suite still green (no regression in existing `blt_sdram_vram`/`blt_stage` tests, which still use `blt_sdram_init`).

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c \
        tests/blt_sdram_regions_test.c tests/run_tests.sh
git commit -m "feat(emitter): permanent + intermediate SDRAM allocator split"
```

---

## Phase B — Renderer region wiring & classification (type-check gate)

### Task 2: Define SDRAM regions and switch the renderer to `blt_sdram_regions_init`

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (constants ~L251-252; init call ~L1288)

**Interfaces:**
- Consumes: `blt_sdram_regions_init` (Task 1); existing `SDRAM_CAP`, `SDRAM_ATLAS_BASE`.
- Produces: constants `SDRAM_PERM_BASE/SIZE`, `SDRAM_INTER_BASE/SIZE` used by later tasks.

- [ ] **Step 1: Add region constants** after `SDRAM_ATLAS_BASE` (~L252):

```cpp
// [residency] Split the atlas space [SDRAM_ATLAS_BASE, SDRAM_CAP) into a large
// PERMANENT immutable region (whole-quest file assets, never freed) and a small
// recycled INTERMEDIATE region (mutable menu/text/target surfaces). Disjoint; both
// on the fabric SDRAM bus. Must not overlap the FB bases (< SDRAM_ATLAS_BASE).
constexpr uint32_t SDRAM_PERM_BASE  = SDRAM_ATLAS_BASE;                 // 16 MiB
constexpr uint32_t SDRAM_INTER_SIZE = 0x00400000u;                     // 4 MiB intermediates
constexpr uint32_t SDRAM_INTER_BASE = SDRAM_CAP - SDRAM_INTER_SIZE;    // 60 MiB
constexpr uint32_t SDRAM_PERM_SIZE  = SDRAM_INTER_BASE - SDRAM_PERM_BASE; // ~44 MiB
static_assert(SDRAM_INTER_BASE > SDRAM_PERM_BASE, "perm region must be non-empty");
```

- [ ] **Step 2: Switch the init call** at ~L1288. Replace:

```cpp
  blt_sdram_init(&self->d->em, SDRAM_ATLAS_BASE, SDRAM_CAP - SDRAM_ATLAS_BASE);
```

with:

```cpp
  blt_sdram_regions_init(&self->d->em, SDRAM_PERM_BASE, SDRAM_PERM_SIZE,
                         SDRAM_INTER_BASE, SDRAM_INTER_SIZE);
```

- [ ] **Step 3: Type-check** — run the renderer type-check command (Global Constraints). Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(renderer): carve permanent + intermediate SDRAM regions"
```

### Task 3: Classify surfaces immutable vs intermediate at stage time

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (`dirty_src` decls ~L652-653; `upload()` stage site ~L1019)

**Interfaces:**
- Consumes: `blt_stage_surface_perm` (Task 1); `blt_stage_surface` (existing); the `upload(const SurfaceImpl& src, uint8_t fmt)` function.
- Produces: `std::unordered_set<const SurfaceImpl*> immutable_set;` and `bool is_immutable(const SurfaceImpl* p) const;` used by the preload driver (Task 5) and forget hook (Task 6).

- [ ] **Step 1: Add the immutable set + predicate** next to `dirty_src` (~L652):

```cpp
  // [residency] Surfaces classified IMMUTABLE (whole-quest file assets, staged once
  // into the permanent region by the preload driver). Members are quest-lifetime
  // (Solarus image_files_cache keeps them alive), so their pointer identity is stable
  // and they are never re-staged or dirty-tracked. Everything NOT in this set is a
  // mutable intermediate (staged into the recycled region, refreshed on dirty, freed
  // on destruction).
  std::unordered_set<const SurfaceImpl*> immutable_set;
  bool is_immutable(const SurfaceImpl* p) const { return immutable_set.count(p) != 0; }
```

- [ ] **Step 2: Branch the stage call** at ~L1019. Replace:

```cpp
      if (stage_enabled) blt_stage_surface(&em, &r);  // [#33] alloc + stage to a distinct SDRAM offset
```

with:

```cpp
      if (stage_enabled) {
        // [residency] immutable file assets go to the permanent region; everything
        // else to the recycled intermediate region.
        if (is_immutable(&src)) blt_stage_surface_perm(&em, &r);
        else                    blt_stage_surface(&em, &r);
      }
```

- [ ] **Step 3: Guard dirty-tracking to intermediates only.** In `mark_src_dirty` (~L653) replace:

```cpp
  void mark_src_dirty(const SurfaceImpl* p) { if (p) dirty_src.insert(p); }
```

with:

```cpp
  // [residency] immutable file assets never mutate; only track intermediates.
  void mark_src_dirty(const SurfaceImpl* p) { if (p && !is_immutable(p)) dirty_src.insert(p); }
```

- [ ] **Step 4: Type-check** — expected exit 0.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(renderer): classify immutable file assets to permanent region"
```

---

## Phase C — Preload driver (type-check gate; HW at phase end)

### Task 4: Extract a `submit_and_drain()` helper from `present()`

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (`present()` submit tail ~L2174-2185; add helper method on the impl struct)

**Interfaces:**
- Consumes: `blt_end_frame`, `ddr_w32`, `ddr_r32`, control-block offsets (`C_CMDCOUNT/C_TARGET/C_CLEAR/C_FLAGS/C_SRCSEL/C_SUBMIT/C_DONE`), `em`, `throttle_val` (all existing).
- Produces: `void submit_and_drain();` — publishes the current command batch to the control block, rings the doorbell, and blocks until the fabric sets `C_DONE == em.submit_seq`. Used by the preload driver.

- [ ] **Step 1: Add the helper** (place it near `ensure_frame()`, on the same impl struct). It factors the publish sequence currently inline at ~L2174-2185 plus a bounded C_DONE poll (mirrors the drain loop at ~L756-761):

```cpp
  // [residency] Publish the current command batch and block until the fabric finishes
  // it. Used by the preload driver to drain a staging batch before reusing the DDR3
  // bounce heap. Mirrors present()'s doorbell (control-block writes + fence + C_SUBMIT)
  // and ensure_frame()'s C_DONE handshake.
  void submit_and_drain() {
    blt_end_frame(&em);
    ddr_w32(C_CMDCOUNT, (uint32_t)em.cmd_count);
    ddr_w32(C_TARGET,   (uint32_t)em.target_buf);
    ddr_w32(C_CLEAR,    em.clear_color);
    ddr_w32(C_FLAGS,    em.flags);
    ddr_w32(C_SRCSEL,   1u | ((throttle_val & 0xFFu) << 8));
    __sync_synchronize();                 // commit ring+ctrl before the doorbell
    ddr_w32(C_SUBMIT,   em.submit_seq);
    struct timespec ts{0, 200000};        // 0.2 ms between polls
    for (int spin = 0; spin < 5000 && ddr_r32(C_DONE) != em.submit_seq; ++spin)
      nanosleep(&ts, nullptr);            // up to ~1 s, then give up (fabric wedged)
  }
```

- [ ] **Step 2: Type-check** — expected exit 0. (This task only ADDS a method; `present()` is unchanged, so no behavior risk. It is validated behaviorally when the preload driver exercises it in Task 5 on HW.)

- [ ] **Step 3: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(renderer): extract submit_and_drain() for batch staging"
```

### Task 5: Preload driver — enumerate + batch-stage all image files at quest open

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (add includes; add `preload_quest_assets()`; add pin vector + guard; call at `present()` entry ~L1792)

**Interfaces:**
- Consumes: `Solarus::QuestFiles::data_file_list_dir`, `Solarus::QuestFiles::data_file_is_dir`, `Solarus::Surface::create`, `Surface::DIR_DATA`, `Surface::get_impl`; `upload()`, `is_immutable`/`immutable_set` (Task 3), `submit_and_drain()` (Task 4), `blt_begin_frame`, `blt_heap_reset`, `em.overflow`, `em.perm_overflow`, `SurfacePtr`.
- Produces: `void preload_quest_assets();` invoked once, before the first composited frame.

- [ ] **Step 1: Add includes** near the existing Solarus includes (~L92):

```cpp
#include <solarus/core/QuestFiles.h>
#include <solarus/graphics/Surface.h>
```

- [ ] **Step 2: Add state** next to `immutable_set` (Task 3):

```cpp
  // [residency] Keep every preloaded SurfacePtr alive for the quest so its SurfaceImpl
  // pointer stays valid + resident (belt-and-braces alongside Solarus's own
  // image_files_cache). Also the one-shot guard for the preload pass.
  std::vector<Solarus::SurfacePtr> preload_pins;
  bool preloaded = false;
```

- [ ] **Step 3: Add the preload driver** (method on the impl struct):

```cpp
  static bool ends_with_png(const std::string& p) {
    return p.size() >= 4 && p.compare(p.size() - 4, 4, ".png") == 0;
  }

  // [residency] One-time whole-quest asset residency. Walks the quest data tree for
  // every image file, forces Solarus to load+cache it (stable SurfaceImplPtr), marks
  // it immutable, and stages it into the PERMANENT SDRAM region — batching through the
  // DDR3 bounce (drain + reset between batches). On permanent-region exhaustion: loud
  // fatal (no runtime fallback — that absence is what lets us delete scene_too_big).
  void preload_quest_assets() {
    if (preloaded) return;
    preloaded = true;
    if (!ddr) return;   // no fabric (software path) — nothing to stage

    blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);

    // Recursive data-tree walk (iterative; data-relative paths).
    std::vector<std::string> stack{ std::string() };
    while (!stack.empty()) {
      std::string dir = stack.back(); stack.pop_back();
      for (const std::string& name : Solarus::QuestFiles::data_file_list_dir(dir)) {
        std::string path = dir.empty() ? name : dir + "/" + name;
        if (Solarus::QuestFiles::data_file_is_dir(path)) { stack.push_back(path); continue; }
        if (!ends_with_png(path)) continue;

        Solarus::SurfacePtr surf =
            Solarus::Surface::create(path, Solarus::Surface::DIR_DATA);
        if (!surf) continue;                       // not a loadable image; skip
        const SurfaceImpl& impl = surf->get_impl();
        preload_pins.push_back(surf);
        immutable_set.insert(&impl);

        // Stage this asset (RGB565 default; upload() picks ARGB4444 when needed via its
        // own format decision at blit time — for preload we stage the opaque RGB565
        // form; the ARGB variant, if ever needed, stages on first alpha use into the
        // permanent region too because the surface is immutable).
        preload_stage_one(impl);
      }
    }
    submit_and_drain();   // flush the final batch
    blt_heap_reset(&em);  // reclaim the DDR3 bounce (perm SDRAM allocations persist)
  }

  // Stage one immutable surface, draining + resetting the bounce when it fills.
  void preload_stage_one(const SurfaceImpl& impl) {
    em.overflow = 0;
    (void)upload(impl, BLT_FMT_RGB565);   // convert -> bounce -> stage-perm -> cache
    if (em.perm_overflow) {
      Solarus::Debug::die("[residency] permanent SDRAM region exhausted during preload; "
                          "quest asset footprint exceeds the region cap");
    }
    if (em.overflow) {
      // DDR3 bounce full: drain this batch, reset the bounce, retry this asset once.
      em.overflow = 0;
      handles.erase(SurfKey{ &impl, BLT_FMT_RGB565 });   // drop the failed cache entry
      submit_and_drain();
      blt_heap_reset(&em);
      blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
      (void)upload(impl, BLT_FMT_RGB565);
      if (em.perm_overflow)
        Solarus::Debug::die("[residency] permanent SDRAM region exhausted during preload");
      if (em.overflow)   // a single asset larger than the whole bounce — cannot happen
        Solarus::Debug::die("[residency] single asset exceeds the DDR3 bounce heap");
    }
  }
```

*(Note for implementer: `Solarus::Debug::die` is the engine's fatal-abort — confirm the include `solarus/core/Debug.h` is already pulled in this TU; add it if the type-check reports it missing. `SurfKey` is the existing cache key struct.)*

- [ ] **Step 4: Call it once at the top of `present()`** (~L1792, first statement of the function body):

```cpp
  d->preload_quest_assets();   // [residency] one-time; no-op after the first frame
```

- [ ] **Step 5: Type-check** — expected exit 0. Fix any missing-include/symbol errors it reports (`QuestFiles`, `Surface`, `Debug`, `SurfacePtr`).

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(renderer): one-time whole-quest asset preload into permanent SDRAM"
```

- [ ] **Step 7: Phase-C HW smoke gate** — cross-build + deploy + boot MoSDX (full recipe in Task 10). Confirm: quest opens, preload completes (no fatal), title + overworld render. `SOLARUS_BLITTER_DIAG=1` shows `uploads` climbing during preload then flat in gameplay. **Do not proceed to deletions until this passes** — the deletions assume preload guarantees residency.

---

## Phase D — Destruction hook (fixes the stale-pointer bug)

### Task 6: `mister_forget_surface` — reclaim intermediate slots on surface destruction

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.h` (export the free function)
- Modify: `patches/mister/mister_blitter_renderer.cpp` (define it; reach the active impl)
- Modify: `scripts/build_engine.sh` (`edit_inplace` to call it from `~SurfaceImpl`)

**Interfaces:**
- Consumes: `handles` (cache), `immutable_set`, `dirty_src`, `too_big`, `blt_sdram_free`, `blt_emitter_free` (existing), the active impl instance pointer.
- Produces: `void mister_forget_surface(const Solarus::SurfaceImpl* p);` — evicts every cache entry keyed on `p`, frees its intermediate SDRAM slot + DDR bounce block, and drops it from the tracking sets. Safe to call for unknown pointers.

- [ ] **Step 1: Declare in `mister_blitter_renderer.h`** (free function, outside the class, in the appropriate namespace guard — match the header's existing `extern "C++"`/namespace style):

```cpp
namespace Solarus { class SurfaceImpl; }
// [residency] Called from ~SurfaceImpl so the blitter cache never serves a freed-and-
// reused surface address (root cause of the render-corruption stale-pointer bug).
void mister_forget_surface(const Solarus::SurfaceImpl* p);
```

- [ ] **Step 2: Define it in `mister_blitter_renderer.cpp`.** The renderer already keeps a way to reach the live impl (the same mechanism `mister_tag_camera_surface` at ~L144-145 uses a file-scope pointer). Follow that idiom: keep a file-scope `static MisterBlitterRenderer::Impl* g_active_impl = nullptr;` set when the impl is constructed/`map_ddr()` succeeds, and:

```cpp
void mister_forget_surface(const Solarus::SurfaceImpl* p) {
  if (!p || !g_active_impl) return;
  g_active_impl->forget_surface(p);
}
```

Add the member `forget_surface` on the impl struct:

```cpp
  // [residency] Evict a destroyed surface from all caches and free its recycled slot.
  // Immutable file assets are never destroyed mid-quest, but guard anyway.
  void forget_surface(const SurfaceImpl* p) {
    for (uint8_t fmt : { (uint8_t)BLT_FMT_RGB565, (uint8_t)BLT_FMT_ARGB4444 }) {
      auto it = handles.find(SurfKey{ p, fmt });
      if (it == handles.end()) continue;
      if (!is_immutable(p)) {                 // permanent slots are never freed
        blt_sdram_free(&em, &it->second);     // return the intermediate SDRAM slot
        blt_emitter_free(&em, it->second.off, it->second.size);  // return the DDR bounce block
      }
      handles.erase(it);
    }
    dirty_src.erase(p);
    too_big.erase(p);
    immutable_set.erase(p);
  }
```

*(Implementer: wire `g_active_impl = this;` where the impl is created and `g_active_impl = nullptr;` in its destructor, mirroring the `mister_tag_camera_surface`/`g_tagged_camera` pattern already in this file.)*

- [ ] **Step 3: Inject the call into `~SurfaceImpl` via `build_engine.sh`.** `SurfaceImpl.cpp`'s destructor is `SurfaceImpl::~SurfaceImpl()`. Add near the other `edit_inplace` patches (the block around L107-116 / L225 patches upstream graphics files):

```bash
# [residency] Notify the blitter when a surface is destroyed so its cache/slots are
# reclaimed (fixes stale-pointer reuse). Idempotent: only patch once.
SIMPL="$SRC/src/graphics/SurfaceImpl.cpp"
if ! grep -q "mister_forget_surface" "$SIMPL"; then
  edit_inplace "$SIMPL" '1s|^|#include "solarus/graphics/sdlrenderer/mister_blitter_renderer.h"\n|'
  edit_inplace "$SIMPL" 's|SurfaceImpl::~SurfaceImpl() *{|SurfaceImpl::~SurfaceImpl() {\n  mister_forget_surface(this);|'
fi
```

*(Implementer: verify the exact destructor signature in `work/solarus/src/graphics/SurfaceImpl.cpp` — if it is defaulted in the header rather than defined in the .cpp, move the hook to `SDLSurfaceImpl.cpp`'s destructor instead, which the build already patches near L225. The header shows `virtual ~SurfaceImpl();` declared, so a .cpp definition exists.)*

- [ ] **Step 4: Type-check** the renderer — expected exit 0.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.h patches/mister/mister_blitter_renderer.cpp scripts/build_engine.sh
git commit -m "fix(renderer): forget destroyed surfaces (kill stale-pointer reuse)"
```

---

## Phase E — Deletions (type-check gate; HW at phase end)

> All three tasks are pure removal enabled by guaranteed residency. Each ends with a clean type-check; behavior is validated by the Phase-F HW run. Delete carefully — some symbols are read in `present()`'s diag block; remove their uses too.

### Task 7: Remove `scene_too_big` / `escape` / `blitter_off` / `too_big`

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`.

- [ ] **Step 1:** Remove the `too_big` set (~L638), the `escape()` method (~L703), the `scene_too_big` state, and `blitter_off()` (~L717). Replace `blitter_off()` call sites with `!ddr` (the only remaining reason to fall back is no-fabric). Remove the `too_big.count/insert` early-out in `upload()` (~L975, L984-987) — with residency, no fitting scene is "too big"; a genuine oversize asset is caught by the preload loud-fatal.

- [ ] **Step 2:** Remove `frame_escaped`/`escape()` bookkeeping and the diag counters `g_esc_*` (~L461) and their `present()` readouts. Grep to confirm no dangling refs:

```bash
grep -nE 'scene_too_big|blitter_off|too_big|frame_escaped|g_esc_|escape\(' patches/mister/mister_blitter_renderer.cpp
```
Expected: no matches (or only the removed-comment tombstones you choose to keep).

- [ ] **Step 3:** Type-check — exit 0. **Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(renderer): drop scene_too_big/escape/blitter_off (residency guarantees fit)"
```

### Task 8: Remove `heap_reset` / transition-reclaim

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`.

- [ ] **Step 1:** In `ensure_frame()` (~L719-745) remove the `heap_reset_pending` / `was_in_transition` / `g_transition_scroll` scroll-edge reset block and the `blt_heap_reset(&em); handles.clear();` it performs. The DDR3 bounce is now reset only by the preload driver (Task 5); steady-state gameplay never resets it (nothing new stages after preload except intermediates, which fit the 4 MiB region).

- [ ] **Step 2:** Remove `did_reset_last` and any `present()` logic that used it to detect "reset cleared overflow" (dead with Task 7). Grep:

```bash
grep -nE 'heap_reset|was_in_transition|did_reset_last|heap_reset_pending' patches/mister/mister_blitter_renderer.cpp
```
Expected: only the preload driver's single `blt_heap_reset` calls (Task 5) remain.

- [ ] **Step 3:** Type-check — exit 0. **Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(renderer): drop heap-reset/transition-reclaim (bounce reset only at preload)"
```

### Task 9: Remove bg-cache vestiges and static `dirty_src` churn

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`.

- [ ] **Step 1:** Remove the vestigial bg-cache env reads/comments (`SOLARUS_BGCACHE` ~L1239-1241 and any `bg_cache` remnants). Confirm none are load-bearing:

```bash
grep -niE 'bgcache|bg_cache|SOLARUS_BGCACHE' patches/mister/mister_blitter_renderer.cpp
```
Expected: no functional references remain.

- [ ] **Step 2:** `dirty_src` now only ever holds intermediates (Task 3 guard). Keep the intermediate refresh path (~L947-962) but confirm it can no longer run for an immutable surface (the `is_immutable` guard in `mark_src_dirty` ensures the set never contains one). No code change if Task 3 is in place — this step is a verification + comment update marking the path intermediate-only.

- [ ] **Step 3:** Type-check — exit 0. **Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(renderer): remove bg-cache vestiges; dirty_src is intermediate-only"
```

---

## Phase F — Cross-build, deploy, hardware validation

### Task 10: Build the armhf engine, deploy, and validate on HW

**Files:** none (build/deploy/validate).

**Interfaces:** Consumes the full renderer + emitter from Phases A-E.

- [ ] **Step 1: Host test suite green**

Run: `bash tests/run_tests.sh`
Expected: all blocks pass, including `ok blt_sdram_regions`.

- [ ] **Step 2: Renderer type-check clean** — run the type-check command. Expected: exit 0.

- [ ] **Step 3: Cross-build the armhf engine**

Run: `scripts/build_engine.sh`
Expected: `build/armhf/solarus-run` + `libsolarus.so.1.6.5` produced; the `edit_inplace` for `mister_forget_surface` applied (grep the staged `work/solarus/src/graphics/SurfaceImpl.cpp` for `mister_forget_surface`).

- [ ] **Step 4: Refresh deploy artifacts** (per the `fpga-deploy-refresh-from-build-armhf` memory — `deploy/` is NOT auto-refreshed):

```bash
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/
cp build/armhf/solarus-run         deploy/games/Solarus/
strings deploy/libs/libsolarus.so.1.6.5 | grep -c mister_forget_surface   # sanity: >0
```

- [ ] **Step 5: Deploy** (device 192.168.20.81; FAT gotchas — rm the open exe first, verify sha1):

```bash
./deploy.py --no-rbf --host 192.168.20.81
```
(No RBF change in v1 — engine-only deploy.)

- [ ] **Step 6: HW validation against the spec checklist.** Launch MoSDX (relaunch via `touch /media/fat/config/Solarus.s0`, or OSD load_core + `solarus_run.sh`), with `SOLARUS_BLITTER_DIAG=1`:
  - **Preload:** quest opens; no `[residency]` fatal; record the immutable footprint (perm-region bytes used) vs `SDRAM_PERM_SIZE`. Note preload wall-time (load stall).
  - **Steady state:** standing overworld renders correctly; `uploads` flat after preload; no per-frame re-upload churn.
  - **Transition:** walk through a **scroll** map transition — renders correctly with `heap_reset`/`scene_too_big` gone (no black frame).
  - **Stale-pointer repro:** open/close the title + a menu/dialog repeatedly — the former corruption (garbage from freed-and-reused intermediate addresses) does NOT appear.
  - **Perf:** fps at least neutral vs the pre-change engine (capture via the diag banner or the video frame counter at `0x3A000000`).
  - Screenshot: `echo screenshot > /dev/MiSTer_cmd` (load_core Solarus first so the fabric is live).

- [ ] **Step 7: Record results + commit any doc/notes**, then hand back for the finishing-a-development-branch step.

---

## Self-review notes (author)

- **Spec §3 (preload/enumeration):** Tasks 5. Filesystem walk via `QuestFiles::data_file_list_dir`, `Surface::create(path, DIR_DATA)`, pointer identity via `image_files_cache` + `immutable_set`. ✓
- **Spec §4 (intermediate region + destruction hook):** Tasks 2 (region), 3 (classification), 6 (forget hook). ✓ (the stale-pointer fix is Task 6.)
- **Spec §5 (deletions):** Tasks 7-9. Carry-forward explicitly NOT touched (out of scope, per spec). ✓
- **Spec §6 (loud-fatal overflow):** Task 1 `perm_overflow` + Task 5 `Debug::die`. XL capacity lever is documented-future, no task (correct — spec marks it non-v1). ✓
- **Spec §7 (validation):** Task 1 host tests (enumerator footprint is exercised implicitly via the perm allocator; the intermediate alloc/free-on-destroy is the Task 1 reuse test + Task 6). Task 10 HW checklist mirrors the spec. ✓
- **Type consistency:** `blt_sdram_regions_init`, `blt_stage_surface_perm`, `perm_overflow`, `immutable_set`, `is_immutable`, `submit_and_drain`, `preload_quest_assets`, `forget_surface`, `mister_forget_surface` — names used identically across tasks. ✓
- **Known implementer verifications flagged inline:** `Debug::die`/`Debug.h` include; `~SurfaceImpl` vs `~SDLSurfaceImpl` hook site; `g_active_impl` wiring mirrors `g_tagged_camera`. These are explicitly called out rather than assumed.
