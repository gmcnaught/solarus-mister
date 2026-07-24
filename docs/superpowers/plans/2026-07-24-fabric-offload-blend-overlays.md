# Fabric-offload Blend Overlays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Composite in-game dialogs and translucent in-game menus as their own fabric layers instead of a per-frame 320×240 software blend onto the root, recovering the ~2× fps that any on-screen dialog currently costs.

**Architecture:** An engine-truth gate (dialog/pause state edges from Solarus core) arms the renderer; while armed, the renderer intercepts the full-screen software blend onto the root, captures the source surface, and re-emits it as a fabric `PALPHA` layer with a content-hash-cached upload. One contained RTL change makes the fabric's `PALPHA` blend honor the command's global opacity so the dialog's opacity-216 look is exact.

**Tech Stack:** C++17 renderer (whole-file copies under `patches/mister/`), C blitter emitter/ref (`patches/mister/blitter/`), SystemVerilog fabric (`fpga/rtl/`), Solarus engine C++ via git-am series (`patches/series/`), C host tests (`tests/`, run by `tests/run_tests.sh`).

## Global Constraints

- Renderer files `patches/mister/mister_blitter_renderer.{cpp,h}` and everything under `patches/mister/blitter/` are **whole-file copies** — edit directly; they are NOT in the git-am series.
- Engine-source changes (files under `work/solarus/`) must be delivered as a **new git-am series patch** in `patches/series/` (next number after `0044`), following the pattern of `patches/series/0044-feat-render-publish-menu-stack-transitions-to-the-Mi.patch`. All engine hooks are wrapped in `#ifdef MISTER_NATIVE_VIDEO`.
- New behavior is gated behind env flag **`SOLARUS_BLENDLAYER`, default ON**, parsed with `mister_flag_default_on("SOLARUS_BLENDLAYER")`; `SOLARUS_BLENDLAYER=0` restores the software blend-into-root path (escape hatch).
- The RTL change must be **bit-identical to today when `c_alpha == 255`** (every current PALPHA caller passes 255).
- Host tests MODEL logic against the emitter/ref; they do NOT compile the renderer. Renderer logic that needs a test must be factored into a pure header (like `mister_overlay_id.h`) so a host test can call it.
- Ships engine + new RBF together. Never self-declare visual correctness — operator gate or bit-exact test only.
- Native renderer type-check command (both `-D` flags mandatory):
  ```
  g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```

## File Structure

- **Create** `patches/mister/mister_blend_layer.h` — pure-C header: capture predicate + content-hash. Unit-tested directly.
- **Create** `tests/blend_layer_test.c` — host test for the predicate + hash + a model of layer ordering/escape.
- **Modify** `patches/mister/blitter/blitter_ref.c` — PALPHA honors global opacity (ref model).
- **Create** `tests/palpha_opacity_test.c` — bit-exact host test for the ref PALPHA×opacity math + `c_alpha==255` regression.
- **Modify** `fpga/rtl/comp_pipeline.sv` — PALPHA honors global opacity (fabric).
- **Modify** `fpga/sim/tb_blitter_palpha_pipe.sv` — add an opacity!=255 case.
- **Modify** `patches/mister/mister_blitter_renderer.cpp` / `.h` — armed flag, signal receivers, capture in `draw()`, emit in a new `emit_blend_layers()`, `SOLARUS_BLENDLAYER` flag, diag counters.
- **Create** `patches/series/0045-feat-render-publish-dialog-pause-state-to-the-MiSTer.patch` — engine hooks in `Game::start_dialog` / `Game::stop_dialog` / `Game::set_paused`.
- **Modify** `tests/run_tests.sh` — register the two new host tests.

---

## Task 1: PALPHA×opacity in the reference model (bit-exact)

**Files:**
- Create: `tests/palpha_opacity_test.c`
- Modify: `patches/mister/blitter/blitter_ref.c` (the `blit_one` PALPHA branch, ~lines 282-289)
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Consumes: `int blt_execute(uint16_t *fb, const blt_surface_heap_t*, const blt_cmd_t*, int n)` (`blitter_ref.h:309`); `blt_cmd_t` fields `blend_mode`, `format`, `alpha`, `dst_x/y`, `w`, `h`, `src_off/stride` (`blitter_ref.h:199`); `div255_round` (`blitter_ref.c:107`, already present).
- Produces: PALPHA blend where the effective per-pixel alpha is `div255_round(pa_a8 * c->alpha)` — relied on by the RTL parity in Task 2 and the renderer emit in Task 6.

- [ ] **Step 1: Write the failing test**

Create `tests/palpha_opacity_test.c`. It builds a 1×1 ARGB4444 source with alpha nibble `A4=15` (opaque, `a8=255`) over a known RGB565 dest, executes a `BLT_BLEND_PALPHA` blit at global `alpha=128`, and asserts the dest equals a straight const-alpha blend at 128 (because `a8=255` → effective alpha `= div255_round(255*128) = 128`). Also asserts `alpha=255` is byte-identical to a plain opaque-source-over (the regression guard).

```c
/* palpha_opacity_test — PALPHA must honor the command's global opacity:
 * effective per-pixel alpha = div255_round(pa_a8 * cmd.alpha).
 * Build: see tests/run_tests.sh. */
#include "blitter_ref.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned d255(unsigned t){ unsigned m=t+128u; return (m+(m>>8))>>8; }

/* reference const-alpha channel blend at RGB565 widths */
static uint16_t blend565(uint16_t s, uint16_t d, unsigned a){
  unsigned na=255u-a;
  unsigned sr=(s>>11)&0x1F, sg=(s>>5)&0x3F, sb=s&0x1F;
  unsigned dr=(d>>11)&0x1F, dg=(d>>5)&0x3F, db=d&0x1F;
  unsigned rr=d255(sr*a+dr*na), rg=d255(sg*a+dg*na), rb=d255(sb*a+db*na);
  return (uint16_t)((rr<<11)|(rg<<5)|rb);
}

/* pack ARGB4444 {A4,R4,G4,B4} */
static uint16_t argb4444(unsigned a4,unsigned r4,unsigned g4,unsigned b4){
  return (uint16_t)((a4<<12)|(r4<<8)|(g4<<4)|b4);
}

int main(void){
  int fails=0;
  /* Source heap: one ARGB4444 pixel, fully opaque (A4=15), color R4=15,G4=0,B4=0. */
  uint16_t src_px = argb4444(15,15,0,0);
  blt_surface_heap_t heap; memset(&heap,0,sizeof heap);
  heap.base=(uint8_t*)&src_px; heap.size=sizeof src_px;

  uint16_t fb[1];
  const uint16_t DST = 0x8410; /* mid grey */

  /* expanded opaque source in RGB565: R4=15 -> R5 = (15<<1)|(15>>3)=31; G,B=0 */
  uint16_t src565 = (uint16_t)((31u<<11)|(0u<<5)|0u);

  /* Case A: alpha=128, A4=15 -> effective alpha 128 */
  blt_cmd_t c; memset(&c,0,sizeof c);
  c.opcode=BLT_OP_BLIT; c.blend_mode=BLT_BLEND_PALPHA; c.format=BLT_FMT_ARGB4444;
  c.src_off=0; c.src_stride=2; c.src_x=0; c.src_y=0; c.w=1; c.h=1;
  c.dst_x=0; c.dst_y=0; c.alpha=128;
  fb[0]=DST; blt_execute(fb,&heap,&c,1);
  uint16_t expA = blend565(src565, DST, 128);
  if (fb[0]!=expA){ printf("FAIL A: got %04x want %04x\n", fb[0], expA); fails++; }

  /* Case B (regression): alpha=255 -> opaque source-over (dest = src) */
  c.alpha=255; fb[0]=DST; blt_execute(fb,&heap,&c,1);
  if (fb[0]!=src565){ printf("FAIL B: got %04x want %04x\n", fb[0], src565); fails++; }

  if (fails){ printf("palpha_opacity_test: %d FAIL\n", fails); return 1; }
  printf("palpha_opacity_test: OK\n"); return 0;
}
```

- [ ] **Step 2: Register and run the test to verify it fails**

Add to `tests/run_tests.sh` (after the `gridov_equiv` block near line 172):

```bash
echo "== palpha_opacity (PALPHA honors global opacity) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/palpha_opacity_test.c \
    patches/mister/blitter/blitter_ref.c \
    -o /tmp/palpha_opacity_test
/tmp/palpha_opacity_test
```

Run: `cc -Wall -Wextra -O2 -I patches/mister/blitter tests/palpha_opacity_test.c patches/mister/blitter/blitter_ref.c -o /tmp/palpha_opacity_test && /tmp/palpha_opacity_test`
Expected: **FAIL A** — current ref ignores `c->alpha` for PALPHA, so `fb[0]` equals `src565` (opaque) instead of the 128-blended value. (Case B already passes.)

- [ ] **Step 3: Implement the ref change**

In `patches/mister/blitter/blitter_ref.c`, the `blit_one` PALPHA branch currently reads (~lines 282-289):

```c
        if (palpha) {
            unsigned a8,sr,sg,sb; argb4444_expand(raw,&a8,&sr,&sg,&sb);
            if (a8==0) continue;
            if (do_mod){ sr=modch(sr,cr); sg=modch(sg,cg); sb=modch(sb,cb); }
            unsigned idx=(unsigned)dy*BLT_FB_WIDTH+(unsigned)dx; uint16_t d=fb[idx];
            unsigned dr=(d>>11)&0x1F,dg=(d>>5)&0x3F,db=d&0x1F,na=255u-a8;
            unsigned orr=div255_round(sr*a8+dr*na),og=div255_round(sg*a8+dg*na),ob=div255_round(sb*a8+db*na);
            fb[idx]=(uint16_t)(((orr&0x1F)<<11)|((og&0x3F)<<5)|(ob&0x1F)); continue;
        }
```

Change it to fold the command's global opacity into the per-pixel alpha:

```c
        if (palpha) {
            unsigned a8,sr,sg,sb; argb4444_expand(raw,&a8,&sr,&sg,&sb);
            if (a8==0) continue;
            /* [blend-layer] fold command global opacity into the per-pixel alpha
             * so a translucent overlay (e.g. the dialog box at opacity 216)
             * composites at its true opacity. c->alpha==255 (every legacy PALPHA
             * caller) is a true no-op: div255_round(a8*255)==a8. */
            if (c->alpha != 255) a8 = div255_round(a8 * (unsigned)c->alpha);
            if (a8==0) continue;
            if (do_mod){ sr=modch(sr,cr); sg=modch(sg,cg); sb=modch(sb,cb); }
            unsigned idx=(unsigned)dy*BLT_FB_WIDTH+(unsigned)dx; uint16_t d=fb[idx];
            unsigned dr=(d>>11)&0x1F,dg=(d>>5)&0x3F,db=d&0x1F,na=255u-a8;
            unsigned orr=div255_round(sr*a8+dr*na),og=div255_round(sg*a8+dg*na),ob=div255_round(sb*a8+db*na);
            fb[idx]=(uint16_t)(((orr&0x1F)<<11)|((og&0x3F)<<5)|(ob&0x1F)); continue;
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cc -Wall -Wextra -O2 -I patches/mister/blitter tests/palpha_opacity_test.c patches/mister/blitter/blitter_ref.c -o /tmp/palpha_opacity_test && /tmp/palpha_opacity_test`
Expected: `palpha_opacity_test: OK`

- [ ] **Step 5: Run the whole host suite (no regressions)**

Run: `bash tests/run_tests.sh`
Expected: all tests pass, including the existing `gridov_equiv` (which links the same `blitter_ref.c` and exercises PALPHA at alpha 255 via the tile/sprite paths — proves the no-op).

- [ ] **Step 6: Commit**

```bash
git add patches/mister/blitter/blitter_ref.c tests/palpha_opacity_test.c tests/run_tests.sh
git commit -m "feat(blitter-ref): PALPHA honors command global opacity (bit-exact no-op at 255)"
```

---

## Task 2: PALPHA×opacity in the fabric (comp_pipeline)

**Files:**
- Modify: `fpga/rtl/comp_pipeline.sv:252`
- Modify: `fpga/sim/tb_blitter_palpha_pipe.sv`

**Interfaces:**
- Consumes: `c_alpha` (`comp_pipeline.sv:52`), `pa_a8` (per-pixel expanded alpha), `b_palpha` (`comp_pipeline.sv:231`). Must match Task 1's ref math (`div255_round(pa_a8*c_alpha)`).
- Produces: fabric-composited PALPHA that equals `blitter_ref.c` bit-for-bit at any opacity — the parity the whole design rests on.

- [ ] **Step 1: Add the failing sim case**

In `fpga/sim/tb_blitter_palpha_pipe.sv`, the existing TB blits a 2×2 ARGB4444 sprite at (implicit) full command alpha. Add a second blit of the SAME sprite at a reduced command alpha (e.g. `216`) into a fresh background, and compute the expected via the TB's `ref_blend4444` helper but with the per-pixel alpha pre-scaled by `div255_round(a8*216)`. Mirror the existing per-pixel expected-value block; add a `216` scaling to the `a8` fed into the reference for the four pixels (A4 = 0/15/8/4). Assert equality for all four.

(The TB already documents its reference reduction in its header; replicate that block with the extra scale. Keep the existing full-alpha case unchanged as the alpha==255 regression.)

- [ ] **Step 2: Run the sim to verify it fails**

Run (from `fpga/sim/`, using the project's sim runner — check `fpga/sim/` for the Makefile/run target that builds `tb_blitter_palpha_pipe`):
`make tb_blitter_palpha_pipe` (or the equivalent target in the sim harness)
Expected: FAIL — the RTL still uses `pa_a8` directly, so the reduced-alpha sprite composites fully opaque, mismatching the scaled reference.

- [ ] **Step 3: Implement the RTL change**

In `fpga/rtl/comp_pipeline.sv`, line 252 currently:

```systemverilog
  wire  [7:0] feed_alpha = b_palpha ? pa_a8        : c_alpha;
```

Change so PALPHA's fed alpha is the per-pixel alpha scaled by the command global opacity, using a divide-free `/255` reduction identical to `div255_round` (mirror the reduction already used elsewhere in this file, e.g. the colour-mod `/255`):

```systemverilog
  // [blend-layer] PALPHA fold: effective alpha = round(pa_a8 * c_alpha / 255).
  // c_alpha==255 (every legacy PALPHA caller) reduces to pa_a8 exactly, so this
  // is bit-identical to the pre-change behavior for the root overlay and sprites.
  wire [15:0] pa_scaled_m = pa_a8 * c_alpha + 16'd128;
  wire  [7:0] pa_scaled   = (pa_scaled_m + (pa_scaled_m >> 8)) >> 8;
  wire  [7:0] feed_alpha  = b_palpha ? pa_scaled : c_alpha;
```

(If `feed_alpha` participates in a timing-critical path, register `pa_scaled` in the existing s3 capture stage — see `s3_alpha <= feed_alpha;` at ~line 875 — rather than adding comb depth. Prefer the simplest form first and let STA in Task 9 decide.)

- [ ] **Step 4: Run the sim to verify it passes**

Run: `make tb_blitter_palpha_pipe` (or equivalent)
Expected: PASS — all four reduced-alpha pixels match the scaled reference AND the existing full-alpha case still passes.

- [ ] **Step 5: Commit**

```bash
git add fpga/rtl/comp_pipeline.sv fpga/sim/tb_blitter_palpha_pipe.sv
git commit -m "feat(comp_pipeline): PALPHA honors command global opacity (bit-exact no-op at 255)"
```

---

## Task 3: Capture predicate + content-hash header (pure, unit-tested)

**Files:**
- Create: `patches/mister/mister_blend_layer.h`
- Create: `tests/blend_layer_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Produces:
  - `int mister_blend_layer_is_capture(int armed, int dst_is_root, int src_w, int src_h, int fb_w, int fb_h, int blend_mode, int opacity)` → 1 if this root draw is a capturable full-screen blend overlay.
  - `uint64_t mister_blend_layer_hash(const void *px, size_t nbytes)` → FNV-1a content hash.
  - `#define MISTER_BLEND_LAYER_MAX 4`
  - Consumed by the renderer in Tasks 5 and 6.

- [ ] **Step 1: Write the failing test**

Create `tests/blend_layer_test.c`:

```c
/* blend_layer_test — pure predicate + content-hash for the blend-overlay
 * fabric layer. Build: see tests/run_tests.sh. */
#include "mister_blend_layer.h"
#include <stdio.h>
#include <string.h>

int main(void){
  int fails=0;
  const int W=320,H=240;
  /* BLT_BLEND_COPY==0, BLT_BLEND_PALPHA==3 (mirror blitter_ref.h) */
  const int COPY=0, PALPHA=3;

  /* Armed + full-screen + opacity 216 -> capture */
  if (!mister_blend_layer_is_capture(1,1, W,H, W,H, PALPHA,216)){ printf("FAIL: dialog not captured\n"); fails++; }
  /* Not armed -> never capture (deterministic gate) */
  if ( mister_blend_layer_is_capture(0,1, W,H, W,H, PALPHA,216)){ printf("FAIL: captured while disarmed\n"); fails++; }
  /* dst not root -> no capture */
  if ( mister_blend_layer_is_capture(1,0, W,H, W,H, PALPHA,216)){ printf("FAIL: captured non-root\n"); fails++; }
  /* sub-screen source (a HUD blit) -> no capture */
  if ( mister_blend_layer_is_capture(1,1, 64,16, W,H, PALPHA,255)){ printf("FAIL: captured HUD sub-blit\n"); fails++; }
  /* full-screen opaque COPY -> no capture (that is a promote, handled elsewhere) */
  if ( mister_blend_layer_is_capture(1,1, W,H, W,H, COPY,255)){ printf("FAIL: captured opaque promote\n"); fails++; }

  /* hash: identical buffers match, one-byte change differs */
  unsigned char a[128], b[128];
  memset(a,0xAB,sizeof a); memcpy(b,a,sizeof b);
  if (mister_blend_layer_hash(a,sizeof a)!=mister_blend_layer_hash(b,sizeof b)){ printf("FAIL: equal buffers hash differ\n"); fails++; }
  b[77]^=0x01;
  if (mister_blend_layer_hash(a,sizeof a)==mister_blend_layer_hash(b,sizeof b)){ printf("FAIL: changed buffer hash equal\n"); fails++; }

  if (fails){ printf("blend_layer_test: %d FAIL\n", fails); return 1; }
  printf("blend_layer_test: OK\n"); return 0;
}
```

- [ ] **Step 2: Register and run to verify it fails**

Add to `tests/run_tests.sh` (after the Task 1 block):

```bash
echo "== blend_layer (capture predicate + content hash) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/blend_layer_test.c \
    -o /tmp/blend_layer_test
/tmp/blend_layer_test
```

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/blend_layer_test.c -o /tmp/blend_layer_test`
Expected: FAIL — `mister_blend_layer.h` does not exist (compile error).

- [ ] **Step 3: Create the header**

Create `patches/mister/mister_blend_layer.h`:

```c
#ifndef MISTER_BLEND_LAYER_H
#define MISTER_BLEND_LAYER_H
/* Pure logic for the blend-overlay fabric layer (dialogs + translucent in-game
 * menus). Kept header-only + dependency-free so a host test can exercise the
 * predicate and hash directly (the renderer .cpp is never compiled by the host
 * suite). Mirrors the mister_overlay_id.h convention. */
#include <stdint.h>
#include <stddef.h>

/* Max simultaneous blend-overlay layers captured per frame (dialog + a menu, say).
 * A fixed small cap keeps the renderer registry allocation-free. */
#define MISTER_BLEND_LAYER_MAX 4

/* Is this root draw a capturable full-screen blend overlay?
 *   armed       : engine-truth gate (dialog active OR game paused)
 *   dst_is_root : the draw targets the tagged root/fpga target
 *   src_w/h     : source surface dimensions
 *   fb_w/h      : framebuffer (quest) dimensions
 *   blend_mode  : BLT_BLEND_* of the draw (COPY==0, PALPHA==3)
 *   opacity     : draw global opacity 0..255
 * Gated by `armed` so the predicate is never evaluated on unrelated frames —
 * there is no first-wins lock to strand. A full-screen OPAQUE COPY is a promote
 * (handled by the menu-alias path), not a blend overlay. */
static inline int mister_blend_layer_is_capture(
    int armed, int dst_is_root,
    int src_w, int src_h, int fb_w, int fb_h,
    int blend_mode, int opacity) {
  if (!armed || !dst_is_root) return 0;
  if (src_w != fb_w || src_h != fb_h) return 0;      /* full-screen source only */
  if (opacity >= 255 && blend_mode == 0 /*COPY*/) return 0; /* opaque promote */
  return 1;
}

/* FNV-1a content hash over a pixel buffer. Cheap content-identity signal so a
 * static/fully-revealed dialog re-uploads nothing. ~150 KB/frame worst case;
 * sub-millisecond, negligible vs the ~20 ms software blend it replaces. */
static inline uint64_t mister_blend_layer_hash(const void *px, size_t nbytes) {
  const unsigned char *p = (const unsigned char *)px;
  uint64_t h = 1469598103934665603ull;      /* FNV offset basis */
  for (size_t i = 0; i < nbytes; i++) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}
#endif /* MISTER_BLEND_LAYER_H */
```

- [ ] **Step 4: Run to verify it passes**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/blend_layer_test.c -o /tmp/blend_layer_test && /tmp/blend_layer_test`
Expected: `blend_layer_test: OK`

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blend_layer.h tests/blend_layer_test.c tests/run_tests.sh
git commit -m "feat(render): pure capture-predicate + content-hash header for blend overlays"
```

---

## Task 4: Renderer signal receivers + armed state (no behavior change yet)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.h` (declare the two free functions near line 126, beside `mister_notify_menu_transition`)
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Produces (free functions, called by the engine patch in Task 6-adjacent / Task 8):
  - `void mister_notify_dialog_state(bool active);`
  - `void mister_notify_pause_state(bool active);`
- Produces (Impl state, consumed in Tasks 5-6): `bool blend_layer_on;`, `bool blend_overlay_armed;`, and `#include "mister_blend_layer.h"`.

- [ ] **Step 1: Include the header and add Impl state**

At the top includes of `patches/mister/mister_blitter_renderer.cpp`, add:

```cpp
#include "mister_blend_layer.h"   // [blend-layer] capture predicate + content hash
```

In the `Impl` struct, next to `menualias_on` / `notify_menu_transition()` (around lines 679-680), add:

```cpp
  // [blend-layer] Fabric-offload of full-screen software blends onto the root
  // (dialog box, translucent in-game menus). Armed by engine-truth dialog/pause
  // state; while armed, the full-screen blend onto root is captured as its own
  // fabric PALPHA layer instead of composited in software. SOLARUS_BLENDLAYER=0
  // restores the software blend-into-root path.
  bool blend_layer_on = true;          // real default set in ctor (default_on)
  bool blend_overlay_armed = false;    // engine-truth: dialog active OR paused
  int  dialog_active = 0;              // separate latches so either source arms
  int  pause_active  = 0;
  void set_dialog_state(bool a){ dialog_active = a?1:0; refresh_armed(); }
  void set_pause_state (bool a){ pause_active  = a?1:0; refresh_armed(); }
  void refresh_armed(){ blend_overlay_armed = blend_layer_on && (dialog_active || pause_active); }
```

- [ ] **Step 2: Add the free-function receivers**

Next to `mister_notify_menu_transition()` (around line 2453) add:

```cpp
// [blend-layer] Engine-truth dialog/pause state edges (published from
// Game::start_dialog/stop_dialog and Game::set_paused). Arm/disarm the
// blend-overlay capture. No-op when SOLARUS_BLENDLAYER=0 (blend_layer_on false
// keeps refresh_armed() from arming).
void mister_notify_dialog_state(bool active) {
  if (g_active_impl) g_active_impl->set_dialog_state(active);
}
void mister_notify_pause_state(bool active) {
  if (g_active_impl) g_active_impl->set_pause_state(active);
}
```

- [ ] **Step 3: Parse the flag in the ctor**

Next to the `menualias_on` parse (line 2492) add:

```cpp
  self->d->blend_layer_on = mister_flag_default_on("SOLARUS_BLENDLAYER");  // [blend-layer] fabric-offload dialogs/blend menus
  self->d->refresh_armed();
```

- [ ] **Step 4: Declare the free functions in the header**

In `patches/mister/mister_blitter_renderer.h`, next to `void mister_notify_menu_transition();` (line 126) add:

```cpp
// [blend-layer] Engine-truth dialog/pause state edges → arm blend-overlay capture.
void mister_notify_dialog_state(bool active);
void mister_notify_pause_state(bool active);
```

- [ ] **Step 5: Type-check the renderer**

Run the native type-check command from Global Constraints.
Expected: no errors from the renderer file.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h
git commit -m "feat(render): blend-layer signal receivers + armed state (no behavior change)"
```

---

## Task 5: Capture the blend overlay in draw() (suppress software composite)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (the `draw()` case-1 overlay path, ~lines 2884-2897; the `Impl` struct for the layer registry)

**Interfaces:**
- Consumes: `mister_blend_layer_is_capture(...)`, `MISTER_BLEND_LAYER_MAX`, `blend_overlay_armed` (Task 4), `is_fpga_target()`, `FB_W`/`FB_H`, `infos` (`DrawInfos`: `region`, `dst_rectangle()`, `opacity`, `blend_mode`).
- Produces (Impl state, consumed by Task 6):
  - `struct BlendLayer { const SurfaceImpl* src; int dx, dy, w, h; uint8_t opacity; uint64_t hash; bool have_hash; };`
  - `BlendLayer blend_layers[MISTER_BLEND_LAYER_MAX]; int n_blend_layers;`
  - counters `g_bl_capture`, `g_bl_escape`.

- [ ] **Step 1: Add the layer registry to Impl**

In the `Impl` struct, near the Task 4 state, add:

```cpp
  struct BlendLayer {
    const SurfaceImpl* src;
    int dx, dy, w, h;
    uint8_t opacity;
    uint8_t blend;          // BLT_BLEND_* of the original draw
    uint64_t hash;          // content hash of the last upload of `src`
    bool have_hash;
  };
  BlendLayer blend_layers[MISTER_BLEND_LAYER_MAX];
  int  n_blend_layers = 0;                     // captured THIS frame, in draw order
  long g_bl_capture = 0, g_bl_escape = 0;      // diag counters
  // Persistent per-source hash across frames (survives the per-frame list reset).
  std::unordered_map<const SurfaceImpl*, uint64_t> bl_src_hash;
```

- [ ] **Step 2: Capture in the case-1 overlay path**

In `MisterBlitterRenderer::draw()`, the case-1 block (`if (d->is_fpga_target(dst))`) currently falls to the overlay channel at ~line 2884 with:

```cpp
    SDLRenderer::draw(dst, src, infos);
    d->mark_src_dirty(&dst);      // root pixels changed -> refresh its upload
    d->overlay_touched = true;
```

Immediately **before** that `SDLRenderer::draw(dst, src, infos);`, insert the capture check:

```cpp
    // [blend-layer] While armed (engine-truth dialog/pause), a full-screen
    // non-opaque blit onto root is a blend overlay (dialog box / translucent
    // menu). Capture it as its own fabric PALPHA layer instead of compositing it
    // into the root in software (the 320x240 A9 blend we are eliminating). HUD
    // sub-region draws fail the predicate and stay on root. On registry overflow
    // we fall through to the software path so an overlay is never lost.
    {
      Rectangle dr0 = infos.dst_rectangle();
      const int opacity = (int)infos.opacity;
      if (mister_blend_layer_is_capture(
              d->blend_overlay_armed ? 1 : 0, /*dst_is_root=*/1,
              (int)src.get_width(), (int)src.get_height(), FB_W, FB_H,
              (int)infos.blend_mode, opacity)) {
        if (d->n_blend_layers < MISTER_BLEND_LAYER_MAX) {
          Impl::BlendLayer& L = d->blend_layers[d->n_blend_layers++];
          L.src = &src; L.dx = dr0.get_x(); L.dy = dr0.get_y();
          L.w = (int)src.get_width(); L.h = (int)src.get_height();
          L.opacity = (uint8_t)opacity; L.blend = (uint8_t)infos.blend_mode;
          auto it = d->bl_src_hash.find(&src);
          L.have_hash = (it != d->bl_src_hash.end());
          L.hash = L.have_hash ? it->second : 0ull;
          if (d->diag) d->g_bl_capture++;
          return;   // suppress the software composite into root
        }
        if (d->diag) d->g_bl_escape++;   // overflow -> software fallback below
      }
    }
```

Note: the `return` skips `SDLRenderer::draw` + `mark_src_dirty(root)` + `overlay_touched=true` for this draw only — root keeps just its HUD content. On overflow we do NOT return, so the existing software path runs (escape fallback, guard #2).

- [ ] **Step 3: Reset the per-frame list**

Find where per-frame overlay state resets (the `written_this_frame.clear()` site, ~line 4266, and/or `overlay_touched=false` at frame start). Add, at the frame-begin reset alongside `overlay_touched`:

```cpp
    d->n_blend_layers = 0;   // [blend-layer] fresh capture list each frame
```

(Locate the exact frame-begin site by searching for `overlay_touched = false`. The list must be cleared once per frame BEFORE draws are processed. Do NOT clear `bl_src_hash` — it persists across frames for cache hits.)

- [ ] **Step 4: Type-check the renderer**

Run the native type-check command.
Expected: no errors. (Behavior is inert until Task 6 emits the captured layers — capturing then returning means the dialog temporarily does not render; that is expected mid-implementation and fixed in Task 6. Do not deploy between Task 5 and Task 6.)

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): capture full-screen blend overlays in draw() (suppress SW composite)"
```

---

## Task 6: Emit captured layers as fabric PALPHA layers (content-hash cached)

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (new `emit_blend_layers()`; call it after `emit_overlay_composite()`)

**Interfaces:**
- Consumes: `blend_layers[]`, `n_blend_layers`, `bl_src_hash` (Task 5); `upload()`, `mark_src_dirty()`, `dirty_src`, `handles`, `SurfKey`, `em`, `blt_blit`, `BLT_BLEND_PALPHA`, `mister_blend_layer_hash` (Task 3); the source pixel accessor used inside `upload()`.
- Produces: fabric blits emitted after the root overlay, one per captured layer, at each layer's opacity.

- [ ] **Step 1: Add a source-pixel hash helper**

`emit_blend_layers()` must hash the CURRENT pixels of each layer's source (the same buffer `upload()` converts from). Inspect `upload()` in this file to see how it reads a `SurfaceImpl`'s pixels (the ARGB4444 conversion source — an `SDL_Surface*` via the surface's accessor). Add a small method on `Impl`:

```cpp
  // [blend-layer] Hash a source surface's current CPU pixels for content-identity.
  // Uses the SAME pixel buffer upload() reads (see upload()); guards null/locked.
  uint64_t hash_surface_pixels(const SurfaceImpl& s) {
    SDL_Surface* sf = /* same accessor upload() uses, e.g. */ s.get_surface().get();
    if (!sf || !sf->pixels) return 0ull;
    size_t nbytes = (size_t)sf->h * (size_t)sf->pitch;
    return mister_blend_layer_hash(sf->pixels, nbytes);
  }
```

(Replace `s.get_surface().get()` with the exact accessor `upload()` uses in this file — match it verbatim so the hash covers precisely the bytes that get converted.)

- [ ] **Step 2: Add emit_blend_layers()**

Add next to `emit_overlay_composite()` (after line ~1571):

```cpp
  // [blend-layer] Composite the captured blend overlays (dialog box / translucent
  // menus) as their own fabric PALPHA layers, in capture order, AFTER the root
  // overlay -> preserves the software HUD-then-dialog Z-order. Each layer's
  // upload is content-hash cached: a static/fully-revealed dialog re-uploads
  // nothing. On upload failure the layer is dropped for this frame (counted);
  // correctness of never-losing-an-overlay is handled at capture time (registry
  // overflow falls back to the software path there).
  void emit_blend_layers() {
    for (int i = 0; i < n_blend_layers; i++) {
      BlendLayer& L = blend_layers[i];
      if (!L.src) continue;
      if (L.src->get_width() != FB_W || L.src->get_height() != FB_H) continue; // size-guard
      uint64_t h = hash_surface_pixels(*L.src);
      bool changed = !L.have_hash || h != L.hash;
      if (changed) {
        mark_src_dirty(L.src);          // force upload() to reconvert
      } else if (handles.count(SurfKey{L.src, BLT_FMT_ARGB4444})) {
        dirty_src.erase(L.src);         // ensure upload() returns the cached ref
      }
      blt_surface_ref_t ref = upload(*L.src, BLT_FMT_ARGB4444);
      if (!ref.valid) { if (diag) g_bl_escape++; continue; }  // drop this frame
      bl_src_hash[L.src] = h;           // remember for next frame's cache decision
      // PALPHA + global opacity: Task 1/2 make the fabric fold opacity into the
      // per-pixel alpha, so the dialog's 216 look is exact.
      blt_blit(&em, ref, 0, 0, L.w, L.h, L.dx, L.dy,
               BLT_BLEND_PALPHA, 0, L.opacity, 0);
      if (diag) g_bl_blits++;
    }
  }
```

Add `long g_bl_blits = 0;` to the Impl counters.

- [ ] **Step 3: Call it after the root overlay composite**

Find the call site of `emit_overlay_composite()` (grep for `emit_overlay_composite()` — it is called once per frame in the flush/present path). Immediately AFTER that call, add:

```cpp
    d->emit_blend_layers();   // [blend-layer] dialog/menu layers composite last, over the root overlay
```

(If `emit_overlay_composite()` is called as `emit_overlay_composite();` inside an Impl method, call `emit_blend_layers();` there; if from the outer renderer via `d->`, use `d->emit_blend_layers();`. Match the surrounding call style.)

- [ ] **Step 4: Type-check the renderer**

Run the native type-check command.
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): emit blend overlays as fabric PALPHA layers (content-hash cached)"
```

---

## Task 7: Diagnostics banner

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (the `SOLARUS_BLITTER_DIAG` reporting path)

**Interfaces:**
- Consumes: `g_bl_capture`, `g_bl_blits`, `g_bl_escape`, `blend_overlay_armed`, `n_blend_layers`.

- [ ] **Step 1: Emit a diag line**

Find an existing per-second diag banner (grep for `[blitter overlay]` or `[blitter diag]`). Add, alongside those (guarded by `if (d->diag)` / the same cadence):

```cpp
      std::fprintf(stderr,
        "[blitter blendlayer] armed=%d layers=%d capture=%ld blits=%ld escape=%ld\n",
        d->blend_overlay_armed ? 1 : 0, d->n_blend_layers,
        d->g_bl_capture, d->g_bl_blits, d->g_bl_escape);
```

Reset the accumulators where the sibling counters reset (match the existing banner's reset cadence).

- [ ] **Step 2: Type-check the renderer**

Run the native type-check command.
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "chore(render): blend-layer diag banner (armed/layers/capture/blits/escape)"
```

---

## Task 8: Engine-truth gate — dialog/pause state edges (git-am series patch)

**Files:**
- Modify (in `work/solarus/`, then export as a patch): `work/solarus/src/core/Game.cpp` (`Game::start_dialog` line 859, `Game::stop_dialog` line 878, `Game::set_paused` line 937)
- Create: `patches/series/0045-feat-render-publish-dialog-pause-state-to-the-MiSTer.patch`

**Interfaces:**
- Consumes: `mister_notify_dialog_state(bool)`, `mister_notify_pause_state(bool)` (Task 4).
- Produces: engine-truth arm/disarm edges — the gate the renderer capture (Task 5) reads.

- [ ] **Step 1: Add the forward declarations**

Near the top of `work/solarus/src/core/Game.cpp` (after includes), add (mirroring patch 0044's MenuApi.cpp block):

```cpp
#ifdef MISTER_NATIVE_VIDEO
namespace Solarus {
  void mister_notify_dialog_state(bool active);
  void mister_notify_pause_state(bool active);
}
#endif
```

- [ ] **Step 2: Publish the dialog edges**

In `Game::start_dialog` (~line 859), after `dialog_box.open(dialog_id, info_ref, callback_ref);` (~line 868):

```cpp
#ifdef MISTER_NATIVE_VIDEO
  // [blend-layer] A dialog is now active: arm the MiSTer blend-overlay capture so
  // the full-screen dialog surface composites as a fabric layer, not a per-frame
  // 320x240 software blend onto the root. No-op off the blitter path.
  mister_notify_dialog_state(true);
#endif
```

In `Game::stop_dialog` (~line 878), after `dialog_box.close(status_ref);` (~line 880):

```cpp
#ifdef MISTER_NATIVE_VIDEO
  mister_notify_dialog_state(false);   // [blend-layer] dialog ended: disarm
#endif
```

- [ ] **Step 3: Publish the pause edge**

In `Game::set_paused(bool paused)` (~line 937), after the state is applied inside the function (place it after the existing body sets the paused flag / fires `on_paused`; put it at the end of the function so `is_paused()` already reflects the new value):

```cpp
#ifdef MISTER_NATIVE_VIDEO
  mister_notify_pause_state(paused);   // [blend-layer] arm/disarm on pause toggle
#endif
```

- [ ] **Step 4: Export the series patch**

Regenerate the patch from the engine tree (the build applies `patches/series/*.patch` onto pristine upstream via git-am). From the engine working copy used by `scripts/build_engine.sh`, produce `patches/series/0045-feat-render-publish-dialog-pause-state-to-the-MiSTer.patch` covering exactly the `src/core/Game.cpp` changes above, following the format of `patches/series/0044-*.patch` (a `From`/`Subject` git-am header + unified diff). Verify:

Run: `grep -l "mister_notify_dialog_state" patches/series/0045-*.patch`
Expected: the file is listed (the hook is in the series, not lost).

- [ ] **Step 5: Verify the patch applies cleanly**

Rebuild the engine (or dry-run the series application) per `scripts/build_engine.sh` so the new patch is exercised in-sequence. If a full armhf Docker build is unavailable in this environment, at minimum confirm the patch applies with `git apply --check` against the pristine upstream tree the build uses.
Expected: applies with no reject; engine compiles with the two hooks.

- [ ] **Step 6: Commit**

```bash
git add patches/series/0045-feat-render-publish-dialog-pause-state-to-the-MiSTer.patch
git commit -m "feat(engine): publish dialog/pause state edges to the MiSTer renderer (series 0045)"
```

---

## Task 9: Model test for interception ordering + escape; full verification

**Files:**
- Modify: `tests/blend_layer_test.c` (add an ordering + escape model)
- Verify: full host suite, renderer type-check, RTL STA/seed, HW gate

**Interfaces:**
- Consumes: `mister_blend_layer_is_capture`, `MISTER_BLEND_LAYER_MAX`.

- [ ] **Step 1: Add an ordering + escape model test**

Append to `tests/blend_layer_test.c`'s `main()` a small model of the renderer's capture loop: feed a sequence of draws `{is HUD (sub-rect), is dialog (full-screen 216), is second overlay}` and assert (a) only the full-screen non-opaque draws are captured, in order; (b) a `MISTER_BLEND_LAYER_MAX+1`-th capturable draw is reported as escape (not captured), modeling the software fallback. Use a tiny local array mirroring the renderer registry.

```c
  /* --- ordering + overflow(escape) model --- */
  {
    struct Draw { int full; int blend; int op; } seq[] = {
      {0,3,255}, /* HUD sub-blit  -> skip */
      {1,3,216}, /* dialog        -> capture[0] */
      {1,3,200}, /* menu          -> capture[1] */
    };
    int cap_order[MISTER_BLEND_LAYER_MAX]; int n=0;
    for (unsigned i=0;i<sizeof seq/sizeof seq[0];i++){
      int full=seq[i].full;
      int c = mister_blend_layer_is_capture(1,1, full?320:64, full?240:16, 320,240, seq[i].blend, seq[i].op);
      if (c && n<MISTER_BLEND_LAYER_MAX) cap_order[n++]=(int)i;
    }
    if (n!=2 || cap_order[0]!=1 || cap_order[1]!=2){ printf("FAIL: capture order wrong (n=%d)\n",n); fails++; }

    /* overflow -> escape */
    int captured=0, escaped=0;
    for (int i=0;i<MISTER_BLEND_LAYER_MAX+1;i++){
      int c = mister_blend_layer_is_capture(1,1, 320,240, 320,240, 3, 216);
      if (c){ if (captured<MISTER_BLEND_LAYER_MAX) captured++; else escaped++; }
    }
    if (captured!=MISTER_BLEND_LAYER_MAX || escaped!=1){ printf("FAIL: overflow escape wrong (cap=%d esc=%d)\n",captured,escaped); fails++; }
  }
```

- [ ] **Step 2: Run the host suite**

Run: `bash tests/run_tests.sh`
Expected: all pass, including `palpha_opacity`, `blend_layer`, and the pre-existing suite.

- [ ] **Step 3: Type-check the renderer**

Run the native type-check command from Global Constraints.
Expected: no errors.

- [ ] **Step 4: RTL sign-off**

Run the comp_pipeline PALPHA sim (Task 2) plus STA and a seed sweep on a fabric build (the change is one multiply + `/255` reduce in an existing stage — expected low timing risk; confirm, don't assume).
Expected: sim PASS; STA meets timing (or is folded into the s3 register per Task 2 Step 3's note); no seed-dependent failure.

- [ ] **Step 5: Commit the test additions**

```bash
git add tests/blend_layer_test.c
git commit -m "test(render): blend-layer capture ordering + overflow-escape model"
```

- [ ] **Step 6: HW validation gate (operator — never self-declared)**

Build engine + RBF together and deploy (`./deploy.py`). With `SOLARUS_BLITTER_DIAG=1`, drive a scene with a dialog (sign/NPC) and capture:
- **Visual (operator):** the dialog box looks identical to the shipped build (opacity-216 translucency preserved); HUD unaffected; no Z-order inversion (dialog over HUD); the `#124` translucent-menu under-dim is checked and reported (secondary — verify, don't assume fixed).
- **Perf (A/B):** `[blitter blendlayer]` shows `armed=1`, `capture>0`, `blits>0`, `escape=0` during a dialog; `[MiSTer draw] game=` drops sharply while a dialog is up; standing fps with a dialog recovers toward the dialog-dismissed baseline (map-40 reference ~53 fps). A/B against `SOLARUS_BLENDLAYER=0` (software path) confirms the delta.
- Record results in `docs/superpowers/YYYY-MM-DD-blend-layer-hw-validation.md` and, only on operator PASS, keep `SOLARUS_BLENDLAYER` default ON.

---

## Self-Review

**Spec coverage:**
- General blend-overlay layer (dialogs + in-game blend menus) → Tasks 5-6 (capture + emit), gated by Task 8 (dialog AND pause edges). ✓
- Engine-truth gate, no quest-Lua dependency → Task 8 hooks `Game::start_dialog/stop_dialog/set_paused` (C++ truth). ✓
- Renderer capture + content-hash cache → Tasks 5, 6. ✓
- PALPHA×opacity RTL, bit-exact no-op at 255, #124 primitive → Tasks 1 (ref), 2 (fabric). ✓
- Correctness guards: Z-order (Task 6 emit-after-root), escape fallback (Task 5 overflow → SW path; Task 6 upload-fail drop), disarm safety (Task 8 stop_dialog/set_paused(false) → disarm), content-hash staleness (Task 6). ✓
- Diagnostics → Task 7. ✓
- `SOLARUS_BLENDLAYER` default-ON + escape hatch → Task 4. ✓
- Testing: host bit-exact (Task 1), RTL sim (Task 2), predicate/hash unit (Task 3), model ordering/escape (Task 9), operator HW gate (Task 9). ✓
- Open items from spec (PALPHA-caller audit; predicate keys on source size; content-hash hook point; pause blend-vs-promote) → PALPHA-caller no-op guaranteed by the `c_alpha==255` branch (Tasks 1-2); predicate keys on `src_w/h == fb_w/h` (Task 3); hash hook = `hash_surface_pixels` at emit (Task 6 Step 1); pause blend-vs-promote resolved at the HW gate (Task 9 Step 6). ✓

**Placeholder scan:** No TBD/TODO. Two spots delegate to a grep-and-match against the live file (the `overlay_touched=false` reset site in Task 5 Step 3; the exact `upload()` pixel accessor in Task 6 Step 1) — these are deliberate "match the existing pattern" instructions with the search term given, not missing content.

**Type consistency:** `mister_blend_layer_is_capture` / `mister_blend_layer_hash` signatures match across Tasks 3, 5, 9. `BlendLayer` fields (`src,dx,dy,w,h,opacity,blend,hash,have_hash`) defined in Task 5, consumed unchanged in Task 6. `mister_notify_dialog_state/pause_state` signatures identical in Tasks 4 (define) and 8 (call). `emit_blend_layers()` defined and called in Task 6. Counters `g_bl_capture/g_bl_blits/g_bl_escape` introduced in Tasks 5-6, reported in Task 7.
