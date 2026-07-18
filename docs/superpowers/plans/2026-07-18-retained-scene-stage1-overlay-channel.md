# Retained-Scene Stage 1 — Overlay Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every screen-space draw (HUD, dialog, menu, title, and scroll-transition map blits) through a single **overlay channel** — software-rendered by stock base SDL into the root surface, uploaded as ARGB4444, and composited **last** over the fabric frame with per-pixel alpha — so that no draw can silently vanish.

**Architecture:** Host-only. **No RTL, no bitstream rebuild, no STA risk.** The fabric already supports exactly this composite: `OP_BLIT` + `BLT_BLEND_PALPHA` + `BLT_FMT_ARGB4444` is the same command the bgplane path emits today (`patches/mister/mister_blitter_renderer.cpp:3735-3736`), and the ring executes strictly in order, so "composited last" means "emitted last, immediately before `blt_end_frame`". The root surface is already a valid per-pixel-alpha source because `SDLRenderer::clear()` zeroes it to a fully transparent `(0,0,0,0)` ARGB buffer (`work/solarus/src/graphics/sdlrenderer/SDLRenderer.cpp:147`).

**Tech Stack:** C++17 (engine/renderer, whole-file copies under `patches/mister/`), C (host emitter model tests), the `patches/mister/build_host_tests.sh` CI suite, `scripts/export_patches.sh` for the engine patch series.

## Global Constraints

- **Stage 1 adds NO RTL.** Do not create, modify, or delete anything under `fpga/`. If a task seems to need fabric work, stop and escalate — the design's `overlay_unit` is a later optimization, not a Stage-1 prerequisite.
- **Scanout is untouched.** `comp_fbram` → `openbor_video_reader`/`_timing` → VGA live stream → framework HDMI scaling. There is no `MISTER_FB`, no ascal, no `fb_writeout`, no DDR3 framebuffer. See spec §3.
- **`SOLARUS_OVERLAY` ships default OFF** (`=1` opts in). It is a new, unvalidated path. Flipping it default-on is Task 5 and is **contingent on the user's hardware validation** — never on the agent's assessment. This mirrors the `SOLARUS_BGPLANE` precedent (opt-in → HW-validated → flipped in PR #121).
- **Never self-declare visual correctness.** No task may claim the render "looks right". Acceptance is the user's eyes plus an objective signal (`perf_pipe_cyc`, command counts, mrext screenshot). See memory `solarus-no-self-declared-visual-validation`.
- **`patches/mister/mister_blitter_renderer.{cpp,h}` are whole-file copies — edit them DIRECTLY.** They are NOT in the patch series; there is nothing to regenerate for them. Engine files under `work/solarus/` ARE in the series and require `scripts/export_patches.sh`.
- **`patches/mister/mister_blitter_renderer.cpp` and `work/solarus/src/graphics/sdlrenderer/mister_blitter_renderer.cpp` are byte-identical** and must stay so. Edit the `patches/mister/` copy, then copy it into `work/solarus/` before any build (`scripts/apply_mister_files.sh` does this).
- **PATH:** `export PATH=/opt/homebrew/bin:$PATH` before any test/type-check command on macOS, or `sdl2-config` is missing and you get a misleading `'SDL_render.h' file not found`.
- **Alpha precision is ARGB4444 — 16 levels, RGB444.** There is no ARGB8888 source format in the fabric. Do **not** route translucent `fill()` (fades) through the overlay surface; fades stay on `blt_fill_alpha` (`OP_FILL` + `CONST_ALPHA`, 8-bit alpha) where they work today and do not band.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `patches/mister/mister_blitter_renderer.cpp` | Modify | `g_tagged_root` + setter; `is_fpga_target` prefers the tag; `overlay_enabled`/`overlay_touched` state; overlay routing in `draw()` case (1); `emit_overlay_composite()`; `present()` emit site. |
| `patches/mister/mister_blitter_renderer.h` | Modify | Declare `mister_tag_root_surface(const SurfaceImpl*)`. |
| `work/solarus/src/core/MainLoop.cpp` | Modify | One call tagging `root_surface` after creation. Enters the build via the patch series. |
| `patches/mister/test_target_lock.cpp` | Create | Models the root-target lock contract: engine tag beats first-wins heuristic, with a negative self-test. |
| `patches/mister/build_test_target_lock.sh` | Create | Build+run wrapper (CI-gating). |
| `patches/mister/test_overlay_emit.c` | Create | Models the overlay emit contract against the REAL emitter: overlay blit is last, full-screen, PALPHA/ARGB4444; absent when untouched. |
| `patches/mister/build_test_overlay_emit.sh` | Create | Build+run wrapper (CI-gating). |
| `patches/mister/build_host_tests.sh` | Modify | Register both new tests so they gate in CI. |

**Why `patches/mister/` and not `tests/`:** `tests/run_tests.sh` is **not referenced by any CI workflow** (`grep -rn "run_tests.sh" .github/ scripts/` → nothing). The `host-tests` job runs `patches/mister/build_host_tests.sh` (`.github/workflows/host-tests.yml:41-42`). A test placed in `tests/` gates nothing.

**Expect `patch-series-ci` to run.** Touching `patches/**` fires `gates` + `patch-only-seam`, and the latter builds the armhf container. It is slow; it is not a failure.

---

## Task 1: Root-surface engine tag

Replaces the first-wins `fpga_target` lottery with engine truth. Today any transient 320×240 texture-backed surface drawn before the real root steals the lock, sending every subsequent root draw down the case-3 fallthrough where it is rendered but never presented. The overlay channel's entire routing rule keys off "is this the root", so this must be exact before Task 2 builds on it.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:158-159` (tag), `:1012-1019` (`is_fpga_target`)
- Modify: `patches/mister/mister_blitter_renderer.h`
- Modify: `work/solarus/src/core/MainLoop.cpp:188-190`
- Create/Test: `patches/mister/test_target_lock.cpp`, `patches/mister/build_test_target_lock.sh`
- Modify: `patches/mister/build_host_tests.sh`

**Interfaces:**
- Produces: `void mister_tag_root_surface(const SurfaceImpl* s)` (namespace `Solarus`) — publishes the root surface pointer; `static const SurfaceImpl* g_tagged_root` consumed by `Impl::is_fpga_target`. Task 3 reads `g_tagged_root` to pick the overlay upload source.

- [ ] **Step 1: Write the failing test**

Create `patches/mister/test_target_lock.cpp`:

```cpp
// Models the root-target lock contract (retained-scene Stage 1, Task 1).
// Host-only, no engine link, no SDL -- a faithful model of
// mister_blitter_renderer.cpp's Impl::is_fpga_target(). Proves the engine tag
// beats the first-wins heuristic, and (negative self-test) that dropping the
// tag check is actually caught.
#include <cstdio>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ std::printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

static const int FB_W = 320, FB_H = 240;

// Model of a SurfaceImpl: only the properties is_fpga_target inspects.
struct Surf { int w, h; bool has_texture; };

// Model of the lock. `use_tag` lets the negative self-test simulate the fix
// being dropped.
struct Lock {
    const Surf* tagged_root = nullptr;   // g_tagged_root
    const Surf* fpga_target = nullptr;   // first-wins fallback
    bool use_tag = true;

    bool is_fpga_target(const Surf& dst) {
        if (dst.w != FB_W || dst.h != FB_H) return false;
        if (!dst.has_texture) return false;              // screen surface -> not us
        if (use_tag && tagged_root) return &dst == tagged_root;
        if (!fpga_target) fpga_target = &dst;
        return &dst == fpga_target;
    }
};

int main() {
    Surf real_root{FB_W, FB_H, true};
    Surf decoy{FB_W, FB_H, true};            // transient 320x240 render texture
    Surf screen{FB_W, FB_H, false};          // window surface: null texture
    Surf small{160, 120, true};

    // (a) Tagged: the real root wins even though the decoy was drawn FIRST.
    {
        Lock l; l.tagged_root = &real_root;
        CHECK(!l.is_fpga_target(decoy),     "tagged: decoy drawn first is NOT the target");
        CHECK( l.is_fpga_target(real_root), "tagged: real root IS the target");
        CHECK(!l.is_fpga_target(decoy),     "tagged: decoy still rejected after root seen");
    }

    // (b) Untagged fallback preserves today's first-wins behaviour.
    {
        Lock l;   // no tag
        CHECK( l.is_fpga_target(decoy),     "untagged: first 320x240 texture wins");
        CHECK(!l.is_fpga_target(real_root), "untagged: real root loses to the decoy");
    }

    // (c) Non-candidates are rejected under both modes.
    {
        Lock l; l.tagged_root = &real_root;
        CHECK(!l.is_fpga_target(screen), "screen surface (null texture) rejected");
        CHECK(!l.is_fpga_target(small),  "wrong-size surface rejected");
    }

    // (d) NEGATIVE SELF-TEST: dropping the tag check must reintroduce the
    //     mis-lock. If this passes, the test is not actually gating anything.
    {
        Lock l; l.tagged_root = &real_root; l.use_tag = false;
        bool decoy_stole = l.is_fpga_target(decoy) && !l.is_fpga_target(real_root);
        CHECK(decoy_stole, "negative self-test: without the tag check the decoy steals the lock");
    }

    std::printf(failures ? "FAILED (%d)\n" : "ok target_lock (tag beats first-wins)\n", failures);
    return failures ? 1 : 0;
}
```

- [ ] **Step 2: Create the build wrapper and register it**

Create `patches/mister/build_test_target_lock.sh`:

```bash
#!/usr/bin/env bash
# Build + run the root-target lock test (retained-scene Stage 1, Task 1).
# Host-only, no engine link, no SDL -- a faithful model of Impl::is_fpga_target().
# Proves the MainLoop root tag beats the first-wins heuristic, and (negative
# self-test) that dropping the tag check is caught.
set -euo pipefail
cd "$(dirname "$0")"
CXXFLAGS="-std=c++11 -O2 -Wall -Wextra"

echo "== root-target lock (tag beats first-wins, positive + negative) =="
# shellcheck disable=SC2086
c++ $CXXFLAGS test_target_lock.cpp -o /tmp/test_target_lock
/tmp/test_target_lock
```

Make it executable and register it in `patches/mister/build_host_tests.sh` — add the `bash build_test_target_lock.sh` line after `bash build_test_alloc_leak.sh`, and add this bullet to the header comment block:

```
#   - build_test_target_lock.sh : root-target lock, engine tag vs first-wins
```

```bash
chmod +x patches/mister/build_test_target_lock.sh
```

- [ ] **Step 3: Run the test and confirm it PASSES**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
export PATH=/opt/homebrew/bin:$PATH
bash patches/mister/build_test_target_lock.sh
```
Expected: `ok target_lock (tag beats first-wins)`, exit 0. **This was verified before the plan was written — if it fails, the test source was transcribed wrong; fix the transcription, not the model.**

**This is a contract model, not a red-green TDD cycle, and that is deliberate.** Host tests cannot compile `mister_blitter_renderer.cpp` (no engine link, no SDL — see `build_test_drawcache.sh` for the same pattern), so the test cannot fail-then-pass against the real renderer. What it gates is the *contract*: case (d), the negative self-test, sets `use_tag = false` to simulate the fix being dropped and asserts the decoy then steals the lock. That case is what makes this test more than a tautology — if someone later removes the tag check from `is_fpga_target`, the model no longer matches the renderer, and only the HW gate (Task 4) would catch it. This mirrored-logic drift risk is disclosed in the plan's self-review and was previously accepted on PR #121.

- [ ] **Step 4: Implement the tag in the renderer**

In `patches/mister/mister_blitter_renderer.cpp`, at `:158-159`, alongside the existing camera tag, add:

```cpp
// [Stage 1] The ROOT surface, published by MainLoop as engine truth. Mirrors
// mister_tag_camera_surface. Without this, is_fpga_target locks onto the FIRST
// 320x240 texture-backed surface ever drawn to -- a transient render texture can
// steal the lock and send every real root draw down the case-3 fallthrough,
// where it is rendered by SDL but never presented.
static const SurfaceImpl* g_tagged_root = nullptr;
void mister_tag_root_surface(const SurfaceImpl* s) { g_tagged_root = s; }
```

Replace `Impl::is_fpga_target` at `:1012-1019` with:

```cpp
  bool is_fpga_target(const SurfaceImpl& dst) {
    if (!ddr) return false;
    if (dst.get_width() != FB_W || dst.get_height() != FB_H) return false;
    const SDLSurfaceImpl* s = dynamic_cast<const SDLSurfaceImpl*>(&dst);
    if (!s || !s->get_texture()) return false;  // window/screen surface -> not us
    // [Stage 1] Engine truth beats the first-wins lottery. When MainLoop has
    // tagged the root, ONLY that surface is the target -- a transient 320x240
    // render texture can no longer steal the lock. Untagged (older engine, or
    // the tag not yet published at first draw) falls back to first-wins.
    if (g_tagged_root) return &dst == g_tagged_root;
    if (!fpga_target) fpga_target = &dst;       // first wins
    return &dst == fpga_target;
  }
```

In `patches/mister/mister_blitter_renderer.h`, next to the existing `mister_tag_camera_surface` declaration, add:

```cpp
/** Publish the root (quest) surface. Called once by MainLoop after the root
 *  surface is created; makes the root-target lock engine truth rather than a
 *  first-wins heuristic. Passing nullptr restores the heuristic. */
void mister_tag_root_surface(const SurfaceImpl* s);
```

- [ ] **Step 5: Add the engine call site**

In `work/solarus/src/core/MainLoop.cpp`, immediately after the root surface is created at `:188-190`, add the tag call. `MainLoop.cpp:1` already includes `solarus/graphics/sdlrenderer/mister_blitter_renderer.h`, so no forward declaration is needed:

```cpp
  // Create the quest surface.
  root_surface = Surface::create(
      Video::get_quest_size()
  );

  // [MiSTer Stage 1] Publish the root surface so the blitter's target lock is
  // engine truth instead of a first-wins heuristic (see mister_tag_root_surface).
  Solarus::mister_tag_root_surface(&root_surface->get_impl());
```

- [ ] **Step 6: Run the test to verify it PASSES**

Run:
```bash
export PATH=/opt/homebrew/bin:$PATH
bash patches/mister/build_test_target_lock.sh
```
Expected: `ok target_lock (tag beats first-wins)` and exit 0.

- [ ] **Step 7: Type-check the renderer and re-export the patch series**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
export PATH=/opt/homebrew/bin:$PATH
cp patches/mister/mister_blitter_renderer.cpp work/solarus/src/graphics/sdlrenderer/mister_blitter_renderer.cpp
cp patches/mister/mister_blitter_renderer.h   work/solarus/include/solarus/graphics/sdlrenderer/mister_blitter_renderer.h
g++ -fsyntax-only -std=c++17 \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp
```
Expected: exit 0, no output.

Then commit the engine change inside `work/solarus` and re-export the series:
```bash
cd work/solarus && git commit -am "fix(render): publish the root surface to the MiSTer blitter target lock" && cd ../..
scripts/export_patches.sh
bash scripts/verify_patches.sh
```
Expected: `[export] regenerated 39 patches from work/solarus on v1.6` (38 → 39), and `verify_patches.sh` exits 0.

- [ ] **Step 8: Run the full CI-gating host suite**

```bash
export PATH=/opt/homebrew/bin:$PATH
bash patches/mister/build_host_tests.sh
```
Expected: ends with `== all host tests passed ==`.

- [ ] **Step 9: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h \
        patches/mister/test_target_lock.cpp patches/mister/build_test_target_lock.sh \
        patches/mister/build_host_tests.sh patches/series/
git commit -m "fix(render): make the root-target lock engine truth (mister_tag_root_surface)

is_fpga_target locked onto the first 320x240 texture-backed surface ever drawn
to, so a transient render texture could steal the lock and send every real root
draw down the case-3 fallthrough -- rendered by SDL but never presented, since
present() never calls SDLRenderer::present(). MainLoop now publishes the root
surface the same way Game::draw publishes the camera, and the tag wins when set
(first-wins retained as the untagged fallback).

Prerequisite for the Stage 1 overlay channel, whose routing rule keys entirely
off 'is this the root'.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

## Task 2: `SOLARUS_OVERLAY` flag + overlay routing in `draw()`

Routes every root draw that is **not** the camera promote-blit into base SDL, marking the root dirty. Nothing is emitted to the fabric on this path, so an unexpressible op can no longer silently vanish — it lands in the root surface, which Task 3 composites.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — `Impl` state (near `:453`), `try_create()` flag block (`:2172` region), `draw()` case (1) (`:2401-2455`)

**Interfaces:**
- Consumes: `g_tagged_root` (Task 1).
- Produces: `bool Impl::overlay_enabled`, `bool Impl::overlay_touched`, `long Impl::g_overlay_draws`. Task 3 consumes all three.

**Why fills are deliberately NOT routed here:** translucent `fill()` on the root is how fades render today (`TransitionFade` → `dst.fill_with_color` → `blt_fill_alpha`, 8-bit alpha, on-fabric, working). Routing fades through the ARGB4444 overlay would cut fade alpha to 16 levels and risk visible banding, and would change a currently-working path. `fill()` is left completely untouched by this plan.

**What this DOES capture, for free:** during a scroll transition `g_transition_scroll` is true, which disables the camera alias, so `TransitionScrolling`'s two full-frame map blits arrive as case-(1) root draws with `src != alias_target`. They therefore route to the overlay automatically. That is the mechanism by which #122/#123 are expected to disappear — to be **confirmed by the user in Task 4**, not assumed here.

- [ ] **Step 1: Add the flag and state**

In `patches/mister/mister_blitter_renderer.cpp`, in the `Impl` struct near the `fpga_target`/`alias_target` declarations (`:453-473`), add:

```cpp
  // [Stage 1] Overlay channel (SOLARUS_OVERLAY). When enabled, every root draw
  // that is not the camera promote-blit is rendered by stock base SDL into the
  // root surface and composited LAST as one ARGB4444 per-pixel-alpha blit.
  bool overlay_enabled = false;
  bool overlay_touched = false;   // root was painted this frame -> composite it
  long g_overlay_draws = 0;       // diag: draws routed to the overlay
  long g_overlay_blits = 0;       // diag: overlay composites emitted
  long g_overlay_esc   = 0;       // diag: composites dropped (upload failed)
```

In `try_create()`, alongside the other flags (after the `SOLARUS_BGPLANE` block at `:2172-2174`), add:

```cpp
  // [Stage 1] Overlay channel. NEW and not yet HW-validated, so it ships OFF and
  // is opt-in; the default-on flip follows hardware validation (the SOLARUS_BGPLANE
  // precedent). Deliberately NOT mister_flag_default_on, which is reserved for
  // already-HW-validated defaults.
  self->d->overlay_enabled = (std::getenv("SOLARUS_OVERLAY") != nullptr);
  if (self->d->overlay_enabled)
    std::fprintf(stderr, "[MiSTer blitter] overlay channel ENABLED (SOLARUS_OVERLAY)\n");
```

- [ ] **Step 2: Add the routing branch in `draw()` case (1)**

In `patches/mister/mister_blitter_renderer.cpp`, inside `draw()` case (1), insert immediately **before** the line `bool emitted = d->emit_draw(src, infos, 0, 0);` (`:2441`):

```cpp
    // [Stage 1 / SOLARUS_OVERLAY] Overlay channel. Every root draw that is NOT
    // the camera promote-blit (skipped above) is screen-space content: HUD,
    // dialog, menu, title, Lua main_on_draw -- and, because g_transition_scroll
    // disables the camera alias, the scroll-transition map blits too. Render it
    // with stock base SDL into the root surface and mark it dirty; present()
    // uploads the root once as ARGB4444 and composites it LAST with per-pixel
    // alpha. SDLRenderer::clear() zeroes the root to a fully TRANSPARENT
    // (0,0,0,0) ARGB buffer every frame (SDLRenderer.cpp:147), so untouched
    // pixels have alpha 0 and the fabric's mixer skips their writes entirely.
    // Nothing is emitted on this path, so an op the emitter could not express
    // can no longer silently vanish -- it is simply drawn in software.
    if (d->overlay_enabled) {
      SDLRenderer::draw(dst, src, infos);
      d->mark_src_dirty(&dst);      // root pixels changed -> refresh its upload
      d->overlay_touched = true;
      if (d->diag) d->g_overlay_draws++;
      return;
    }
```

- [ ] **Step 3: Type-check**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
export PATH=/opt/homebrew/bin:$PATH
g++ -fsyntax-only -std=c++17 \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp
```
Expected: exit 0, no output.

- [ ] **Step 4: Verify the flag is inert when unset**

```bash
export PATH=/opt/homebrew/bin:$PATH
bash patches/mister/build_host_tests.sh
grep -n "overlay_enabled" patches/mister/mister_blitter_renderer.cpp
```
Expected: host suite ends `== all host tests passed ==`, and every `overlay_enabled` read is guarded so that with the env var unset the routing branch is skipped and `draw()` behaves exactly as before (the only reads are the `try_create` assignment, the `draw()` guard, and — after Task 3 — the `present()` guard).

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "feat(render): SOLARUS_OVERLAY routing -- root draws to the overlay channel

Every case-(1) root draw that is not the camera promote-blit now renders via
stock base SDL into the root surface and marks it dirty, instead of being
emitted to the fabric. The root is cleared to transparent (0,0,0,0) each frame,
so it is a valid per-pixel-alpha overlay source; Task 3 composites it last.

Scroll transitions are captured for free: g_transition_scroll disables the
camera alias, so TransitionScrolling's map blits arrive as non-promote root
draws and route here.

Ships OFF (SOLARUS_OVERLAY=1 opts in); default-on follows HW validation.
Translucent fill() is deliberately untouched -- fades stay on blt_fill_alpha's
8-bit alpha rather than ARGB4444's 16 levels.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

## Task 3: Composite the overlay last in `present()`

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — new `Impl::emit_overlay_composite()`, call site in `present()` at `:4177`, per-frame reset at `:4227`
- Create/Test: `patches/mister/test_overlay_emit.c`, `patches/mister/build_test_overlay_emit.sh`
- Modify: `patches/mister/build_host_tests.sh`

**Interfaces:**
- Consumes: `overlay_enabled`, `overlay_touched`, `g_tagged_root` (Tasks 1–2); `Impl::upload(const SurfaceImpl& src, uint8_t fmt) -> blt_surface_ref_t` (`:1677`); `blt_blit(blt_emitter_t*, blt_surface_ref_t, int sx, int sy, int w, int h, int dx, int dy, uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags)` (`blt_emitter.h:137-139`).
- Produces: `void Impl::emit_overlay_composite()`.

**Critical design point — composite EVERY frame, upload only when dirty.** The DDR framebuffer is hardware-cleared each frame (`clear()` sets `clear_requested`, `:2274-2276`). If the composite were gated on a dirty flag, a static HUD would be re-cleared and never re-composited, and would vanish. So the composite is unconditional whenever the root was painted this frame; `overlay_touched` only skips a pointless full-screen pass when the root was never drawn to at all. Re-upload cost is already handled inside `upload()`, which refreshes in place only when `dirty_src` contains the pointer (`:1686-1701`) — that is the existing "upload when dirty" mechanism and needs no new tracking. Because Solarus clears and fully repaints the root every frame (`MainLoop::draw()`, `MainLoop.cpp:669-673`), `overlay_touched` is true on every frame that has any UI.

- [ ] **Step 1: Write the failing test**

Create `patches/mister/test_overlay_emit.c`:

```c
/* Models the Stage 1 overlay emit contract against the REAL emitter.
 * The overlay composite must be the LAST command in the frame, full-screen at
 * (0,0), PALPHA over ARGB4444 -- and must be absent when the root was never
 * painted. Mirrors Impl::emit_overlay_composite(); the renderer itself is not
 * compiled by host tests. */
#include "blitter_ref.h"
#include "blt_emitter.h"
#include "blt_wire.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

#define FB_W 320
#define FB_H 240

/* Decode the nth command from the ring. */
static blt_cmd_t ring_read(const blt_emitter_t *e, int n)
{
    blt_cmd_t c;
    memset(&c, 0, sizeof(c));
    blt_unpack_cmd(e->ring + (size_t)n * BLT_CMD_BYTES, &c);
    return c;
}

/* Model of Impl::emit_overlay_composite(): composite iff the root was painted. */
static void emit_overlay_composite(blt_emitter_t *e, blt_surface_ref_t root,
                                   int overlay_enabled, int overlay_touched)
{
    if (!overlay_enabled || !overlay_touched) return;
    if (!root.valid) return;
    blt_blit(e, root, 0, 0, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
}

static uint8_t ring[64 * BLT_CMD_BYTES];
static uint8_t heap[512 * 1024];
static uint16_t overlay_px[FB_W * FB_H];

/* Emit `nworld` world blits, then the overlay. Returns the emitter by pointer. */
static void run_frame(blt_emitter_t *e, int nworld, int enabled, int touched,
                      blt_surface_ref_t *out_root)
{
    blt_emitter_init(e, ring, sizeof(ring), heap, sizeof(heap));
    blt_begin_frame(e, 0, 0, 0);

    blt_surface_ref_t root =
        blt_upload_argb4444(e, overlay_px, FB_W, FB_H, FB_W * 2);
    CHECK(root.valid, "overlay upload succeeds");
    CHECK(root.format == BLT_FMT_ARGB4444, "overlay handle tagged ARGB4444");

    for (int i = 0; i < nworld; i++)
        blt_fill(e, i * 8, 0, 8, 8, 0x1234);

    emit_overlay_composite(e, root, enabled, touched);
    *out_root = root;
}

static void test_overlay_is_last(void)
{
    blt_emitter_t e; blt_surface_ref_t root;
    run_frame(&e, 3, 1, 1, &root);

    CHECK(e.cmd_count == 4, "3 world fills + 1 overlay blit");
    CHECK(e.overflow == 0,  "no ring overflow");

    for (int i = 0; i < 3; i++)
        CHECK(ring_read(&e, i).opcode == BLT_OP_FILL, "world commands come first");

    blt_cmd_t ov = ring_read(&e, e.cmd_count - 1);
    CHECK(ov.opcode     == BLT_OP_BLIT,      "overlay is the LAST command");
    CHECK(ov.blend_mode == BLT_BLEND_PALPHA, "overlay uses per-pixel alpha");
    CHECK(ov.format     == BLT_FMT_ARGB4444, "overlay source is ARGB4444");
    CHECK(ov.w == FB_W && ov.h == FB_H,      "overlay is full-screen");
    CHECK(ov.dst_x == 0 && ov.dst_y == 0,    "overlay lands at (0,0)");
    CHECK(ov.src_x == 0 && ov.src_y == 0,    "overlay reads from the surface origin");
}

static void test_absent_when_untouched(void)
{
    blt_emitter_t e; blt_surface_ref_t root;
    run_frame(&e, 3, 1, 0, &root);          /* enabled, but root never painted */
    CHECK(e.cmd_count == 3, "no overlay command when the root was not painted");
    for (int i = 0; i < e.cmd_count; i++)
        CHECK(ring_read(&e, i).opcode == BLT_OP_FILL, "only world commands present");
}

static void test_absent_when_disabled(void)
{
    blt_emitter_t e; blt_surface_ref_t root;
    run_frame(&e, 3, 0, 1, &root);          /* flag off: must be inert */
    CHECK(e.cmd_count == 3, "no overlay command when SOLARUS_OVERLAY is off");
}

int main(void)
{
    test_overlay_is_last();
    test_absent_when_untouched();
    test_absent_when_disabled();
    printf(failures ? "FAILED (%d)\n" : "ok overlay_emit (last, full-screen, PALPHA)\n", failures);
    return failures ? 1 : 0;
}
```

Create `patches/mister/build_test_overlay_emit.sh`:

```bash
#!/usr/bin/env bash
# Build + run the Stage 1 overlay emit test. Host-only, no engine link, no SDL --
# models Impl::emit_overlay_composite() against the REAL emitter and asserts the
# overlay composite is the last command, full-screen, PALPHA over ARGB4444, and
# absent when the root was not painted or the flag is off.
set -euo pipefail
cd "$(dirname "$0")"
CFLAGS="-O2 -Wall -Wextra"

echo "== overlay emit (last / full-screen / PALPHA, positive + negative) =="
# shellcheck disable=SC2086
cc $CFLAGS -I blitter test_overlay_emit.c blitter/blt_emitter.c blitter/blt_alloc.c \
   -o /tmp/test_overlay_emit
/tmp/test_overlay_emit
```

Register it in `patches/mister/build_host_tests.sh` (add `bash build_test_overlay_emit.sh` after the Task 1 line, plus a header bullet), and:

```bash
chmod +x patches/mister/build_test_overlay_emit.sh
```

- [ ] **Step 2: Run the test to verify it PASSES against the emitter**

```bash
export PATH=/opt/homebrew/bin:$PATH
bash patches/mister/build_test_overlay_emit.sh
```
Expected: `ok overlay_emit (last, full-screen, PALPHA)` and exit 0.

This test gates the *contract* (ordering, geometry, blend, absence). If it fails, the emitter does not behave as the renderer implementation in Step 3 assumes — resolve that before writing the renderer code, since the renderer cannot be compiled by the host suite.

- [ ] **Step 3: Implement `emit_overlay_composite()`**

In `patches/mister/mister_blitter_renderer.cpp`, add to `Impl` near the other emit helpers (adjacent to `emit_fps_overlay_fills()` at `:1324`):

```cpp
  // [Stage 1] Composite the overlay LAST: one full-screen ARGB4444 per-pixel-alpha
  // blit of the root surface over the finished fabric frame. The ring executes in
  // order, so "last" is purely a matter of emitting this immediately before
  // blt_end_frame().
  //
  // Composited EVERY frame the root was painted, NOT only when dirty: the DDR
  // framebuffer is hardware-cleared each frame (clear_requested), so a dirty-gated
  // composite would make a static HUD vanish on the first frame it wasn't redrawn.
  // Re-upload is already dirty-driven inside upload(), which refreshes in place
  // only when mark_src_dirty() flagged the pointer -- no extra tracking needed.
  void emit_overlay_composite() {
    if (!overlay_enabled || !overlay_touched) return;
    const SurfaceImpl* root = g_tagged_root ? g_tagged_root : fpga_target;
    if (!root) return;
    blt_surface_ref_t ref = upload(*root, BLT_FMT_ARGB4444);
    if (!ref.valid) {           // heap/stage failure: logged, bounded, never wrong
      if (diag) g_overlay_esc++;
      return;
    }
    blt_blit(&em, ref, 0, 0, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
    if (diag) g_overlay_blits++;
  }
```

In `present()`, at the submit block (`:4176-4177`), add the call **before** the FPS overlay so the FPS counter stays on top of the UI:

```cpp
  if (d->frame_active) {
    d->emit_overlay_composite();                                  // [Stage 1] UI last
    if (d->fps_overlay_enabled()) d->emit_fps_overlay_fills();    // FPS on top of that
    blt_end_frame(&d->em);
```

At the end of `present()`, alongside the existing per-frame resets (`:4227-4228`), add:

```cpp
  d->overlay_touched = false;   // [Stage 1] re-armed by next frame's root draws
```

- [ ] **Step 4: Add the diagnostic line**

In the `if (d->diag)` block in `present()`, next to the other counter banners, add:

```cpp
    if (d->overlay_enabled)
      std::fprintf(stderr, "[blitter overlay] draws=%ld composites=%ld dropped=%ld\n",
                   d->g_overlay_draws, d->g_overlay_blits, d->g_overlay_esc);
```

and reset the three counters in the same window-reset group as the other `g_*` counters.

- [ ] **Step 5: Type-check and run the full suite**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
export PATH=/opt/homebrew/bin:$PATH
g++ -fsyntax-only -std=c++17 \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp
bash patches/mister/build_host_tests.sh
```
Expected: type-check exit 0 with no output; suite ends `== all host tests passed ==`.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/test_overlay_emit.c \
        patches/mister/build_test_overlay_emit.sh patches/mister/build_host_tests.sh
git commit -m "feat(render): composite the overlay last (full-screen ARGB4444 PALPHA)

present() now emits one full-screen per-pixel-alpha blit of the root surface
immediately before blt_end_frame, so screen-space UI lands on top of the fabric
frame. No RTL: this is the same OP_BLIT + PALPHA + ARGB4444 command the bgplane
path already emits, and the ring executes in order.

Composited every frame the root was painted rather than only when dirty -- the
DDR framebuffer is hardware-cleared each frame, so a dirty-gated composite would
make a static HUD vanish. Re-upload stays dirty-driven inside upload().

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YTKoioGE2kBeHM8Gdp2ppe"
```

---

## Task 4: Hardware validation gate

**No code.** This task produces evidence and hands it to the user. Nothing here may be self-assessed: per memory `solarus-no-self-declared-visual-validation`, the agent has been wrong three times claiming a frame looked correct.

**Files:** none modified. Produces `docs/superpowers/2026-07-18-stage1-overlay-hw-validation.md`.

- [ ] **Step 1: Build and deploy**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
bash scripts/build_engine.sh
cp build/armhf/solarus-run build/armhf/libsolarus.so.1.6.5 deploy/
./deploy.py --no-rbf
```
Expected: build succeeds; `deploy.py` reports the upload. Verify the sha1 of the uploaded binary matches the local one — a partial scp leaves a truncated file (see the deploy gotchas in CLAUDE.md).

- [ ] **Step 2: Capture the A/B baseline (flag OFF)**

Launch detached with the flag off and capture the objective counters:
```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  setsid sh solarus_run.sh > /tmp/solarus_off.log 2>&1 </dev/null &'
# after reaching a scene with HUD + a scroll transition:
ssh root@192.168.20.81 'busybox devmem 0x3B00002C; busybox devmem 0x3B000034'
```
Record `perf_frame_cyc` (`0x3B00002C`) and `perf_pipe_cyc` (`0x3B000034`).

- [ ] **Step 3: Capture the overlay run (flag ON)**

```bash
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run); cd /media/fat/games/solarus && \
  SOLARUS_OVERLAY=1 SOLARUS_BLITTER_DIAG=1 setsid sh solarus_run.sh > /tmp/solarus_on.log 2>&1 </dev/null &'
ssh root@192.168.20.81 'busybox devmem 0x3B00002C; busybox devmem 0x3B000034'
ssh root@192.168.20.81 'grep "blitter overlay" /tmp/solarus_on.log | tail -5'
```
Expected in the log: the `[MiSTer blitter] overlay channel ENABLED` banner, and `[blitter overlay] draws=… composites=… dropped=0`. **`dropped` must be 0**; a non-zero value means overlay uploads are failing and the UI is missing, which fails this gate outright.

- [ ] **Step 4: Have the USER inspect four scenes**

Ask the user to look at, and report on, each of these with `SOLARUS_OVERLAY=1`:

| Scene | What to check | Why |
|---|---|---|
| Title / menu | UI present, correct colors | The aliased-surface loss class |
| Gameplay HUD (hearts, rupees) | Present every frame, not flickering | Catches a dirty-gated-composite regression |
| **Translucent UI** (dialog box background, any faded-in menu element) | **A/B the brightness against `SOLARUS_OVERLAY=0`. Too dark = premultiplication bug.** | See below — the most likely false pass |
| **Fade transition** | Smooth, no banding | Fades must be UNCHANGED — they stay on `blt_fill_alpha` |
| **Scroll transition** | No hold frame (#122), no black frame (#123) | The two issues Stage 1 is expected to delete |

Record their verbatim response. Do not paraphrase a "looks fine" into a pass.

**Why the translucent-UI row is a named acceptance criterion.** `SDLRenderer::clear()` zeroes the root to `(0,0,0,0)`, and `SDLRenderer::draw()` then blends into it with non-premultiplied `SDL_BLENDMODE_BLEND`. Over a fully transparent destination that yields `dstRGB = srcRGB * srcA` with `dstA = srcA` — the RGB is **already multiplied by alpha**. The fabric's `BLT_BLEND_PALPHA` then multiplies by alpha a second time. Opaque content (`srcA = 255`) is unaffected, which is most of the HUD — so this bug can hide behind a HUD that looks perfect while every translucent element is wrong. Symptoms: translucent dialog/menu backgrounds too dark, dark halos on anti-aliased text edges, sprites drawn at opacity < 255 too dark.

If it reproduces, do **not** patch it blind. The two candidate fixes are (a) un-premultiply in `to_argb4444` for the root — lossy at 4 alpha bits, or (b) a premultiplied-alpha blend mode in the fabric (`out = src.rgb + dst.rgb*(1-a)`), which is RTL and therefore **out of scope for Stage 1**. Bring the observation back and decide with the user.

**Also pre-register the expected cost** so a counter delta isn't misdiagnosed as a regression. Each composited frame does an `SDL_RenderReadPixels` of 320×240×4 (307 KB), an `mpix::to_argb4444` over 76,800 px, a 150 KB memcpy into the heap, a `blt_stage_surface` DDR3→SDRAM copy of 150 KB, and a full-screen `PALPHA` blit. `perf_pipe_cyc` and the `dyn_reup` MB figure in `[blitter cvt]` **should** rise noticeably with the flag on. That is expected, not a defect.

**One semantic change to note in the record:** with the flag on, every root `draw()` composites above every root `fill()` regardless of engine issue order, because fills stay on the fabric FB while draws go to the overlay. The in-engine call sites were checked and are safe (`Game::draw` orders bg-fill → promote → fade-fill → dialog-draw). The exposure is quest Lua that draws to the screen and then fills a translucent dim rect over it.

- [ ] **Step 5: Write the validation record**

Create `docs/superpowers/2026-07-18-stage1-overlay-hw-validation.md` containing: the two counter readings and their delta, the `[blitter overlay]` log lines, the user's verbatim per-scene verdict, and an explicit statement of whether #122 and #123 are resolved. If either is still present, file the follow-up rather than closing it.

- [ ] **Step 6: Commit the record**

```bash
git add docs/superpowers/2026-07-18-stage1-overlay-hw-validation.md
git commit -m "docs: record Stage 1 overlay channel HW validation"
```

---

## Task 5: Flip `SOLARUS_OVERLAY` default-on — GATED

**Do not start this task until Task 4 is complete and the user has explicitly confirmed the overlay path is correct on hardware.** If any scene in Task 4 regressed, stop and fix instead.

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp` (the `try_create()` flag block), `CLAUDE.md`.

- [ ] **Step 1: Flip the default**

Replace the flag read added in Task 2 with the default-on form:

```cpp
  // [HW-validated 2026-…] Overlay channel ships ON; SOLARUS_OVERLAY=0 opts out.
  self->d->overlay_enabled = mister_flag_default_on("SOLARUS_OVERLAY");
  if (self->d->overlay_enabled)
    std::fprintf(stderr, "[MiSTer blitter] overlay channel ENABLED (SOLARUS_OVERLAY)\n");
```

- [ ] **Step 2: Verify the opt-out works**

```bash
export PATH=/opt/homebrew/bin:$PATH
bash patches/mister/build_host_tests.sh
```
Then on device confirm `SOLARUS_OVERLAY=0` still produces the pre-Stage-1 behaviour (banner absent, `[blitter overlay]` line absent).

- [ ] **Step 3: Update CLAUDE.md**

Add the overlay channel to the "Rendering architecture (current)" section, describing it as the screen-space channel composited last, default ON since this change, `SOLARUS_OVERLAY=0` to opt out — matching how `SOLARUS_BGPLANE` is documented.

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp CLAUDE.md
git commit -m "feat(render): SOLARUS_OVERLAY default-on -- ship the overlay channel"
```

---

## Self-review notes

**Spec coverage (§ by §).** §2's overlay primitive ("everything else — HUD, menu, dialog, intro, title, transitions, arbitrary Lua `surface:draw`… one ARGB overlay surface, base-SDL software rendered, uploaded when dirty, composited last, per-pixel alpha") → Tasks 2–3. §4's OverlayChannel row → Tasks 2–3; the `overlay_unit` fabric row is explicitly deferred, since the existing `OP_BLIT`+PALPHA path already does the job. §6's classification rule ("root/screen-surface draws = UI → OverlayChannel") → Task 1 (making "is root" exact) + Task 2 (the routing). §6's overflow row ("overlay surface uploaded to DDR3 before the doorbell; composited within the frame, no scanout race") → satisfied structurally: the overlay's STAGE+BLIT are emitted into the same ring before `blt_end_frame`, and the WORK→SCAN snapshot only runs after the ring drains. §7's Stage 1 row and `SOLARUS_OVERLAY` gate → Tasks 2 and 5.

**Deliberate deviations from the spec, both narrowing scope:**
1. **Fades are NOT routed to the overlay.** §6 lists "transitions and fades are overlay effects", but fades currently composite on-fabric via `blt_fill_alpha` with 8-bit alpha and work correctly; ARGB4444 would cut them to 16 alpha levels. Scroll transitions — the ones that actually carry #122/#123 — are captured anyway, because `g_transition_scroll` disables the alias and their blits arrive as non-promote root draws.
2. **Default OFF, flipped only after HW validation.** §7 writes the gate as `SOLARUS_OVERLAY=0`, implying default-on. Shipping a brand-new path default-on contradicts this repo's own convention (`mister_flag_default_on` is documented as being for already-HW-validated gates) and the `SOLARUS_BGPLANE` precedent.

**Open items from §8 that this plan does NOT need:** sprite cap, scratch arena sizing, index-grid encoding, and `tilemap_unit` cyc/px all belong to Stages 2–3.

**Known risk carried forward.** Host tests mirror renderer logic rather than compiling it (`patches/mister/test_*.cpp` re-implement contracts by hand), so the models in Tasks 1 and 3 can drift from the renderer silently. The mirrored surface was kept deliberately small — `is_fpga_target`'s ~6 lines and `emit_overlay_composite`'s ~10 — and the emit test exercises the real emitter rather than a model of it. The renderer type-check (`g++ -fsyntax-only`) is the only check that reads the actual renderer source, and it verifies syntax, not behaviour.

**Follow-on stages** (each gets its own plan): Stage 2 sprite channel, Stage 3 tilemap channel + `tilemap_unit`, Stage 4 dead-path deletion.

## References
- `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md` — the design this implements.
- `docs/frame-dataflow.md` — current architecture.
- `patches/mister/mister_blitter_renderer.cpp:3735-3736` — the existing full-screen PALPHA blit proving no RTL is needed.
- `work/solarus/src/graphics/sdlrenderer/SDLRenderer.cpp:147` — the transparent root clear.
- `work/solarus/src/core/MainLoop.cpp:669-673` — clear + full repaint of the root every frame.
- Issues #122 (bgplane hold frame on scroll), #123 (pre-existing scroll black frame).
