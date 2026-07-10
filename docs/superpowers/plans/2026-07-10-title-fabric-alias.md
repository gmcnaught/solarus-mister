# Title/Menu Fabric Alias — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Engage the idle FPGA compositor for software-composited title/menu scenes by aliasing their full-FB intermediate surface as the DDR framebuffer, eliminating the A9 per-sprite composite and whole-surface upload.

**Architecture:** Extract the alias-target decision into a pure, host-tested header (`alias_arbitration.h`), then wire it into `MisterBlitterRenderer` as a once-per-frame arbitration that (a) accepts software-backed full-FB promote surfaces guarded by a "re-established each frame" test, and (b) lets a behaviorally-detected candidate take the alias when the deterministic camera tag is *dead* (received no draws last frame). No RTL changes.

**Tech Stack:** C++17 (renderer, host unit tests via `c++`/`g++`), armhf cross-build in Docker, MiSTer DE10-Nano HW validation via `deploy.py` + on-device diag counters.

## Global Constraints

- **Engine/renderer only — NO RTL, NO fabric changes.** (`docs/.../2026-07-10-title-fabric-alias-design.md`.)
- **The authoritative compile gate is the armhf Docker build**, not host `clang`/`g++` — host `-fsyntax-only` is a fast sanity check only (it can pass armhf-invalid code): `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh` → success line `[100%] Built target solarus-run`.
- **Feature gate:** new env `SOLARUS_NO_SWALIAS` — behavioral alias is **default ON**, opt-out by setting `SOLARUS_NO_SWALIAS=1` (mirrors the `SOLARUS_NO_CAMERA_TAG` opt-out idiom). This gate subsumes the old opt-in `SOLARUS_ALIAS_SW`.
- **Host unit tests** live in `tests/`, are pure (no SDL/engine deps), and are registered in `tests/run_tests.sh` (run: `bash tests/run_tests.sh`, expect `All host tests passed.`).
- **Pure logic headers** live in `patches/mister/blitter/` and are included with `-I patches/mister/blitter`.
- **Device:** `192.168.20.81`, deploy root `/media/fat/games/solarus/`, diag log `/media/fat/logs/Solarus/Solarus.diag.log`.
- **Do NOT run Task 3 (hardware validation) until the user explicitly approves.** Tasks 1–2 + PR creation complete first.
- Commit message trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01L2FQF2NePsYqsroienJiES`

---

### Task 1: Pure alias-arbitration decision logic (host-tested)

Extract the per-frame alias-target decision into a pure header and unit-test its truth table natively. This is the reviewable core; the renderer glue in Task 2 only feeds it observations.

**Files:**
- Create: `patches/mister/blitter/alias_arbitration.h`
- Create: `tests/alias_arbitration_test.cpp`
- Modify: `tests/run_tests.sh` (register the new test)

**Interfaces:**
- Produces (consumed by Task 2):
  - `enum alias_action_t { ALIAS_KEEP, ALIAS_ADOPT_TAG, ALIAS_ADOPT_PROMOTE };`
  - `int alias_cand_eligible(int fb_sized, int geom_ok, int reestablished, int drawn);`
  - `struct alias_obs_t { int tag_present, tag_is_alias, tag_live, cand_present, cand_is_alias; };`
  - `alias_action_t alias_decide(alias_obs_t o);`

- [ ] **Step 1: Write the failing test**

Create `tests/alias_arbitration_test.cpp`:

```cpp
/* Host unit test for the pure alias-target arbitration logic. No SDL/engine
 * deps. Build+run:
 *   c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
 *       tests/alias_arbitration_test.cpp -o /tmp/alias_arbitration_test \
 *   && /tmp/alias_arbitration_test
 * See docs/superpowers/specs/2026-07-10-title-fabric-alias-design.md.
 */
#include "alias_arbitration.h"
#include <cassert>
#include <cstdio>

int main() {
  /* Eligibility: all four conditions required. */
  assert(alias_cand_eligible(1, 1, 1, 1) == 1);
  assert(alias_cand_eligible(0, 1, 1, 1) == 0);  /* not FB-sized */
  assert(alias_cand_eligible(1, 0, 1, 1) == 0);  /* geometry not a 1:1 promote */
  assert(alias_cand_eligible(1, 1, 0, 1) == 0);  /* not re-established this frame */
  assert(alias_cand_eligible(1, 1, 1, 0) == 0);  /* received no draws */

  /* 1. Live tag is authoritative: adopt when not already the alias (gameplay). */
  {
    alias_obs_t o = { /*tag_present=*/1, /*tag_is_alias=*/0, /*tag_live=*/1,
                      /*cand_present=*/0, /*cand_is_alias=*/0 };
    assert(alias_decide(o) == ALIAS_ADOPT_TAG);
  }
  /* 2. Live tag already the alias -> keep (steady gameplay, no thrash). */
  {
    alias_obs_t o = { 1, 1, 1, 0, 0 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }
  /* 3. Live tag wins even when a candidate also exists (never steal from a
   *    live camera). */
  {
    alias_obs_t o = { 1, 0, 1, 1, 0 };
    assert(alias_decide(o) == ALIAS_ADOPT_TAG);
  }
  /* 4. Dead tag + live candidate + candidate not yet alias -> adopt candidate
   *    (THE title fix: dead camera tag no longer hijacks the alias). */
  {
    alias_obs_t o = { /*tag_present=*/1, /*tag_is_alias=*/1, /*tag_live=*/0,
                      /*cand_present=*/1, /*cand_is_alias=*/0 };
    assert(alias_decide(o) == ALIAS_ADOPT_PROMOTE);
  }
  /* 5. Dead tag + candidate already the alias -> keep (steady title, stable). */
  {
    alias_obs_t o = { 1, 0, 0, 1, 1 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }
  /* 6. No tag + live candidate -> adopt candidate. */
  {
    alias_obs_t o = { 0, 0, 0, 1, 0 };
    assert(alias_decide(o) == ALIAS_ADOPT_PROMOTE);
  }
  /* 7. No tag + no candidate -> keep. */
  {
    alias_obs_t o = { 0, 0, 0, 0, 0 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }
  /* 8. Dead tag + no candidate -> keep (stays broken/software until a candidate
   *    is detected; harmless — Component 4 emits the promote normally). */
  {
    alias_obs_t o = { 1, 1, 0, 0, 0 };
    assert(alias_decide(o) == ALIAS_KEEP);
  }

  std::printf("alias_arbitration_test: all cases passed\n");
  return 0;
}
```

- [ ] **Step 2: Run the test to verify it fails (header missing)**

Run:
```bash
c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/alias_arbitration_test.cpp -o /tmp/alias_arbitration_test
```
Expected: FAIL — `fatal error: 'alias_arbitration.h' file not found`.

- [ ] **Step 3: Write the pure header**

Create `patches/mister/blitter/alias_arbitration.h`:

```c
#ifndef ALIAS_ARBITRATION_H
#define ALIAS_ARBITRATION_H
/* Pure decision logic for choosing the fabric alias target each frame.
 * Host-testable (no SDL/engine deps). See
 * docs/superpowers/specs/2026-07-10-title-fabric-alias-design.md.
 *
 * The renderer aliases ONE full-FB surface as the DDR framebuffer so per-sprite
 * draws composite on the fabric. Two candidate sources exist:
 *   - the deterministic camera TAG (Game::draw) — authoritative for gameplay;
 *   - a behaviorally-detected full-FB "promote" surface (menus/title) — used
 *     when the tag is absent or DEAD (received no draws last frame).
 * alias_decide() picks, from LAST frame's observations, what the alias should
 * be for the new frame. It never steals the alias from a LIVE tagged camera, so
 * gameplay is unchanged (at most a 1-frame adoption lag, which only occurs at
 * map-change/transition boundaries where aliasing is already disabled). */

typedef enum {
  ALIAS_KEEP = 0,       /* leave alias_target unchanged */
  ALIAS_ADOPT_TAG,      /* set alias_target := tagged camera surface */
  ALIAS_ADOPT_PROMOTE   /* set alias_target := detected promote surface */
} alias_action_t;

typedef struct {
  /* camera tag (deterministic, from Game::draw) */
  int tag_present;   /* camera_tag enabled AND g_tagged_camera != NULL */
  int tag_is_alias;  /* g_tagged_camera == current alias_target */
  int tag_live;      /* tagged surface received >=1 draw LAST frame */
  /* behavioral promote candidate (detected LAST frame) */
  int cand_present;  /* a qualifying full-FB promote candidate exists */
  int cand_is_alias; /* candidate == current alias_target */
} alias_obs_t;

/* A promote candidate qualifies only if it is FB-sized, geometrically a 1:1
 * opaque full-frame copy, was re-established this frame (hw-cleared OR covered
 * by a leading full-FB opaque draw) before its incremental draws, AND actually
 * received draws. */
static inline int alias_cand_eligible(int fb_sized, int geom_ok,
                                      int reestablished, int drawn) {
  return (fb_sized && geom_ok && reestablished && drawn) ? 1 : 0;
}

static inline alias_action_t alias_decide(alias_obs_t o) {
  /* 1. A LIVE tag is authoritative (unchanged gameplay): adopt if not already
   *    the alias. */
  if (o.tag_present && o.tag_live && !o.tag_is_alias)
    return ALIAS_ADOPT_TAG;
  /* 2. Tag absent or DEAD: if a behavioral candidate is live and not already
   *    the alias, adopt it (fixes the title's dead-tag hijack). */
  if ((!o.tag_present || !o.tag_live) && o.cand_present && !o.cand_is_alias)
    return ALIAS_ADOPT_PROMOTE;
  /* 3. Otherwise keep the current alias. */
  return ALIAS_KEEP;
}

#endif /* ALIAS_ARBITRATION_H */
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/alias_arbitration_test.cpp -o /tmp/alias_arbitration_test \
  && /tmp/alias_arbitration_test
```
Expected: PASS — prints `alias_arbitration_test: all cases passed`, exit 0.

- [ ] **Step 5: Register the test in the harness**

In `tests/run_tests.sh`, immediately before the final `echo "All host tests passed."` line, add:

```bash
echo "== alias_arbitration (title/menu fabric alias decision) =="
c++ -std=c++17 -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/alias_arbitration_test.cpp -o /tmp/alias_arbitration_test
/tmp/alias_arbitration_test
```

- [ ] **Step 6: Run the full host harness**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/alias_arbitration.h tests/alias_arbitration_test.cpp tests/run_tests.sh
git commit -m "$(cat <<'EOF'
feat(render): pure alias-arbitration decision logic + host test

Extracts the per-frame alias-target choice (live camera tag vs a
behaviorally-detected full-FB promote candidate) into a pure header so
the truth table is host-tested independent of SDL/engine. No behavior
change yet — wired into the renderer in the next task.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01L2FQF2NePsYqsroienJiES
EOF
)"
```

---

### Task 2: Wire behavioral alias into the renderer

Feed per-frame observations into `alias_decide` and act on it: track tag liveness + a full-FB promote candidate, replace the eager mid-frame tag adoption with a single frame-boundary arbitration, and default the software-alias gate ON.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes (from Task 1): `alias_arbitration.h` (`alias_decide`, `alias_obs_t`, `alias_action_t`, `alias_cand_eligible`).
- Produces: no new public symbols. Behavioral change gated by `SOLARUS_NO_SWALIAS`.

Context anchors (current line numbers, verify before editing):
- Impl alias fields declared ~430–444.
- `alias_allow_sw` init ~1615 (`try_create`).
- `looks_like_promote` ~1549–1568 (geometry + sw-gate predicate — reused as `geom_ok`).
- `ensure_frame` per-frame reset block ~1004–1008.
- `clear()` SDL-backed branch ~1732–1733.
- `draw()` eager tag adoption ~1799–1805; branch-1 promote/first-wins ~1820–1870; branch-2 alias ~1876–1883; branch-3 offtarget ~1885–1906.
- `resident_begin_frame` mirror tag adoption ~1917–1921.

- [ ] **Step 1: Include the pure header**

Near the other project includes at the top of `mister_blitter_renderer.cpp` (after the existing `#include "blitter/..."` lines), add:

```cpp
#include "blitter/alias_arbitration.h"
```

- [ ] **Step 2: Add per-frame observation state to Impl**

Immediately after the `bool alias_drawn_this_frame = false;` field (~444), add:

```cpp
  // [swalias] Behavioral full-FB alias observation state (see
  // blitter/alias_arbitration.h + the 2026-07-10 title-fabric-alias spec).
  bool sw_alias = true;             // SOLARUS_NO_SWALIAS opt-out; default ON
  int  tag_draws = 0;               // draws onto g_tagged_camera THIS frame
  bool tag_live_prev = false;       // g_tagged_camera drawn during the LAST frame
  // Current-frame FB-sized off-target candidate (the menu/title composite target):
  const SurfaceImpl* otf_surf = nullptr;  // first FB-sized off-target surface seen
  int  otf_draws = 0;                     // draws onto otf_surf this frame
  bool otf_reest = false;                 // otf_surf hw-cleared OR full-FB opaque cover this frame
  // Qualifying promote candidate detected at LAST frame's promote site:
  const SurfaceImpl* cand = nullptr;
  int  cand_off_x = 0, cand_off_y = 0;
  bool cand_eligible = false;
```

- [ ] **Step 3: Default the software-alias gate ON**

Replace the `alias_allow_sw` init line in `try_create` (~1615):

```cpp
  self->d->alias_allow_sw = (std::getenv("SOLARUS_ALIAS_SW") != nullptr);
```

with:

```cpp
  // [swalias] Behavioral full-FB alias (title/menu offload) is default ON;
  // opt out with SOLARUS_NO_SWALIAS=1. Subsumes the old opt-in SOLARUS_ALIAS_SW,
  // which is still honored as a force-on for back-compat.
  self->d->sw_alias = (std::getenv("SOLARUS_NO_SWALIAS") == nullptr);
  self->d->alias_allow_sw = self->d->sw_alias ||
                            (std::getenv("SOLARUS_ALIAS_SW") != nullptr);
```

- [ ] **Step 4: Count draws onto the tagged surface (tag liveness)**

At the very top of `MisterBlitterRenderer::draw(...)`, immediately after `d->mark_render();` (~1793), add:

```cpp
  // [swalias] Tag-liveness: count draws onto the deterministic camera tag,
  // regardless of which branch handles them, so a DEAD tag can be detected.
  if (g_tagged_camera && &dst == g_tagged_camera) d->tag_draws++;
```

- [ ] **Step 5: Remove the eager mid-frame tag adoption in draw()**

Delete the eager adoption block (~1799–1805):

```cpp
  if (d->camera_tag && g_tagged_camera && !g_transition_scroll && d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;   // full-screen camera composites at (0,0)
    if (d->diag)
      std::fprintf(stderr, "[blitter alias] camera TAGGED=%p (deterministic)\n",
                   (const void*)g_tagged_camera);
  }
```

(Adoption now happens once per frame in `ensure_frame` via `alias_decide`; Step 9.)

- [ ] **Step 6: Remove the mirror tag adoption in resident_begin_frame()**

Delete the mirror block (~1917–1921):

```cpp
  if (d->camera_tag && g_tagged_camera && !g_transition_scroll &&
      d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;
  }
```

(The resident batch composites onto whatever `alias_target` the frame-boundary arbitration set; no separate adoption needed.)

- [ ] **Step 7: Capture the promote candidate in branch 1**

In `draw()` branch 1 (`is_fpga_target(dst)`), replace the old first-wins alias block (~1849–1858):

```cpp
    if (!d->alias_target && !g_transition_scroll && d->looks_like_promote(src, infos)) {
      d->alias_target = &src;
      Rectangle dr = infos.dst_rectangle();
      d->alias_off_x = dr.get_x();
      d->alias_off_y = dr.get_y();
      if (d->diag)
        std::fprintf(stderr,
          "[blitter alias] camera surface=%p aliased -> DDR fb at offset (%d,%d)\n",
          (const void*)&src, d->alias_off_x, d->alias_off_y);
    }
```

with promote-candidate capture (recorded for next frame's arbitration):

```cpp
    // [swalias] Record a qualifying full-FB promote candidate: the FB-sized
    // off-target surface composited this frame (otf_surf), re-established and
    // drawn, now promoted 1:1 opaque onto the root. Arbitration adopts it next
    // frame IFF the camera tag is dead (alias_arbitration.h).
    if (d->sw_alias && !g_transition_scroll && &src == d->otf_surf &&
        d->otf_reest && d->otf_draws > 0 && d->looks_like_promote(src, infos)) {
      Rectangle dr = infos.dst_rectangle();
      d->cand = &src;
      d->cand_off_x = dr.get_x();
      d->cand_off_y = dr.get_y();
      d->cand_eligible = true;
    }
```

- [ ] **Step 8: Track the FB-sized off-target candidate + re-establish in branch 3 and clear()**

(8a) In `draw()` branch 3 (SDL-backed off-target), immediately before `SDLRenderer::draw(dst, src, infos);` (~1900), add:

```cpp
  // [swalias] Track the FB-sized off-target surface being composited this frame
  // as the promote-candidate source. First FB-sized surface wins for the frame;
  // a leading full-FB opaque draw counts as a re-establish (covers prior pixels).
  if (d->sw_alias && dst.get_width() == FB_W && dst.get_height() == FB_H) {
    Rectangle dr = infos.dst_rectangle();
    bool full_cover = (dr.get_x() == 0 && dr.get_y() == 0 &&
                       dr.get_width() == FB_W && dr.get_height() == FB_H &&
                       infos.blend_mode == BlendMode::NONE);
    if (!d->otf_surf) {                 // first FB-sized off-target this frame
      d->otf_surf = &dst;
      d->otf_reest = full_cover;        // clear() may also have set this
    }
    if (&dst == d->otf_surf) {
      if (d->otf_draws == 0 && full_cover) d->otf_reest = true;  // leading cover
      d->otf_draws++;
    }
  }
```

(8b) In `clear()`, in the SDL-backed branch (~1732, the path that runs `SDLRenderer::clear(dst)` for a non-backed surface), immediately before `d->mark_src_dirty(&dst);` (~1733), add:

```cpp
  // [swalias] A clear() of an FB-sized off-target surface re-establishes it (its
  // prior pixels are gone), qualifying it as a promote candidate this frame.
  if (d->sw_alias && dst.get_width() == FB_W && dst.get_height() == FB_H) {
    if (!d->otf_surf || &dst == d->otf_surf) { d->otf_surf = &dst; d->otf_reest = true; }
  }
```

- [ ] **Step 9: Frame-boundary arbitration in ensure_frame**

In `ensure_frame`, replace the per-frame reset line (~1007):

```cpp
      alias_drawn_this_frame = false;   // reset per-frame alias-coverage tracking
```

with the arbitration + reset:

```cpp
      // [swalias] Once-per-frame alias-target arbitration from the JUST-ENDED
      // frame's observations (blitter/alias_arbitration.h). A live camera tag is
      // authoritative (gameplay unchanged); a dead tag yields to a behavioral
      // full-FB promote candidate (title/menu offload).
      if (sw_alias) {
        alias_obs_t o;
        o.tag_present  = (camera_tag && g_tagged_camera) ? 1 : 0;
        o.tag_is_alias = (g_tagged_camera == alias_target) ? 1 : 0;
        o.tag_live     = tag_live_prev ? 1 : 0;
        o.cand_present = cand_eligible ? 1 : 0;
        o.cand_is_alias = (cand && cand == alias_target) ? 1 : 0;
        switch (alias_decide(o)) {
          case ALIAS_ADOPT_TAG:
            alias_target = g_tagged_camera; alias_off_x = 0; alias_off_y = 0;
            if (diag) std::fprintf(stderr, "[blitter alias] adopt TAG=%p\n",
                                   (const void*)g_tagged_camera);
            break;
          case ALIAS_ADOPT_PROMOTE:
            alias_target = cand; alias_off_x = cand_off_x; alias_off_y = cand_off_y;
            if (diag) std::fprintf(stderr,
              "[blitter alias] adopt PROMOTE=%p off=(%d,%d) [dead-tag]\n",
              (const void*)cand, cand_off_x, cand_off_y);
            break;
          case ALIAS_KEEP: default: break;
        }
      }
      // Snapshot liveness for next frame, then reset per-frame observation state.
      tag_live_prev = (tag_draws > 0);
      tag_draws = 0;
      otf_surf = nullptr; otf_draws = 0; otf_reest = false;
      cand = nullptr; cand_eligible = false;
      alias_drawn_this_frame = false;   // reset per-frame alias-coverage tracking
```

- [ ] **Step 10: Re-run the host test harness (guard against regressions)**

Run: `bash tests/run_tests.sh`
Expected: ends with `All host tests passed.`, exit 0. (The pure test is unchanged; this confirms nothing else broke.)

- [ ] **Step 11: Host syntax sanity check (fast, non-authoritative)**

Run:
```bash
g++ -std=c++17 -fsyntax-only \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include \
  -I/opt/homebrew/include -I/opt/homebrew/include/SDL2 -D_THREAD_SAFE \
  patches/mister/mister_blitter_renderer.cpp
```
Expected: exit 0, no output. If `work/solarus`/`build/armhf` are absent, skip to Step 12 (the real gate). This is a sanity check only — not authoritative.

- [ ] **Step 12: armhf Docker build (the authoritative compile gate)**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
```
Expected: ends with `[100%] Built target solarus-run`; produces `build/armhf/solarus-run` and `build/armhf/libsolarus.so.1.6.5`.

- [ ] **Step 13: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "$(cat <<'EOF'
feat(render): behavioral full-FB alias for title/menu fabric offload

Software-composited title/menu scenes ran ~20fps A9-bound while the
fabric sat ~70% idle: a DEAD camera tag (map camera drawn 0x/frame)
hijacked the alias, and looks_like_promote rejected the real software
composite target. Now: (1) accept software-backed full-FB promote
surfaces guarded by a re-established-each-frame test; (2) once-per-frame
alias arbitration (alias_arbitration.h) yields a dead tag to a
behaviorally-detected candidate, never stealing from a live camera.
Default ON, opt-out SOLARUS_NO_SWALIAS=1. Engine-only, no RTL.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01L2FQF2NePsYqsroienJiES
EOF
)"
```

---

### Task 3: Hardware validation on DE10-Nano  ⛔ GATED — do NOT start until the user approves

**Files:** none (validation only). Uses `deploy.py` + on-device diag/screenshots.

**Interfaces:** consumes `build/armhf/` artifacts from Task 2.

- [ ] **Step 1: Refresh deploy artifacts + push engine (engine-only, no RBF)**

```bash
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/
cp build/armhf/solarus-run         deploy/
./deploy.py --no-rbf --host 192.168.20.81
```
Verify the pushed `.so` matches the build (FAT can't overwrite an open exe — kill+rm first if refused):
```bash
ssh root@192.168.20.81 'md5sum /media/fat/games/solarus/libs/libsolarus.so.1.6.5'
```
must equal `md5sum build/armhf/libsolarus.so.1.6.5`.

- [ ] **Step 2: Relaunch and capture the animated title diag (feature ON)**

Load the Solarus core from the OSD (fabric live), pick MoSDX, land on the animated title. Then read the diag block:
```bash
ssh root@192.168.20.81 'grep -aE "\[blitter (timing|a9split|diag|hwperf|cvt)\]" /media/fat/logs/Solarus/Solarus.diag.log | tail -20'
```
**Expected (vs the ~19fps baseline):** `alias_blits` 0 → ~10/fr; `offtarget` ~690 → ~0; `cvt dyn_reup` 8.79 MB → ~0; `A9` ~31ms → ~6ms; `fps` ~19 → ~55–60; `escape` stays 0; a `[blitter alias] adopt PROMOTE=... [dead-tag]` line appears.

- [ ] **Step 3: Screenshot the title (visual correctness)**

```bash
ssh root@192.168.20.81 'echo screenshot > /dev/MiSTer_cmd'
```
Pull/inspect. Expected: clouds, logo, and the menu box all render correctly — no smear, no black frame, no missing layers.

- [ ] **Step 4: Gameplay regression (feature ON)**

Navigate title → overworld → the parallax map. Read the diag:
```bash
ssh root@192.168.20.81 'grep -aE "\[blitter (timing|diag)\]" /media/fat/logs/Solarus/Solarus.diag.log | tail -12'
```
Expected: overworld `alias_blits` and fps unchanged vs pre-change baseline; the live camera tag is adopted (`adopt TAG=...`), never a PROMOTE during gameplay; screenshot correct. (Parallax fps stays fabric-bound — unchanged; that is a separate track.)

- [ ] **Step 5: Opt-out sanity (feature OFF)**

Relaunch with `SOLARUS_NO_SWALIAS=1` in the launch env and confirm the title reverts to the old software-composite behavior (`alias_blits=0`, ~19fps) — proving the gate cleanly disables the new path.

- [ ] **Step 6: Record results**

Append measured before/after metrics to the PR description and note HW validation status.

---

## Self-Review

**Spec coverage:**
- Component 1 (software-tolerant, re-established-guarded detection) → Task 2 Steps 7, 8 + `alias_cand_eligible` (Task 1).
- Component 2 (live-target arbitration, dead tag can't win) → `alias_decide` (Task 1) + Task 2 Step 9; eager adoptions removed (Steps 5, 6).
- Component 3 (per-frame tally + reset) → Task 2 Steps 2, 4, 9.
- Component 4 (skip-promote guard) → unchanged existing code (lines ~1828–1848), left intact by Steps 5–7; verified by Task 3 Step 2 (`offtarget→0`).
- Rollout gate `SOLARUS_NO_SWALIAS` default ON → Task 2 Step 3; opt-out proven Task 3 Step 5.
- Validation plan (title A/B, gameplay regression, menu correctness, visual) → Task 3 Steps 2–5.
- Non-goal (parallax throughput) → explicitly out; Task 3 Step 4 only confirms no regression.

**Placeholder scan:** none — all steps carry concrete code/commands and expected output.

**Type consistency:** `alias_obs_t` fields (`tag_present`, `tag_is_alias`, `tag_live`, `cand_present`, `cand_is_alias`), `alias_action_t` enumerators, and `alias_cand_eligible(fb_sized, geom_ok, reestablished, drawn)` are used identically in Task 1 (definition + test) and Task 2 (Step 9 construction). `otf_surf`/`otf_draws`/`otf_reest`/`cand`/`cand_off_x`/`cand_off_y`/`cand_eligible`/`tag_draws`/`tag_live_prev`/`sw_alias` are declared in Step 2 and used consistently in Steps 3–9.

**Open item carried from spec:** confirm the animated-title promote is a clean full-frame 1:1 blit of the composite surface — validated implicitly by Task 3 Step 2 (if it weren't, `cand_eligible` would never fire and `alias_blits` would stay 0; that is the go/no-go signal).
