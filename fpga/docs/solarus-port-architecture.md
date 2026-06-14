# Solarus → MiSTer: a platform-port architecture (60 fps, end-to-end)

Status: reframe (2026-06-14). Supersedes the SW-path micro-optimization track
(bg-cache / scroll-cache — shelved as wrong-layer). This treats Solarus-on-MiSTer
as a **graphics-pipeline PORT**, not an optimization of the software renderer.

## 0. Thesis (one paragraph)

Solarus is built around a **GPU-accelerated 2D renderer** (textures + render
targets + texture→texture blits). On its PC target a GPU does all compositing. On
MiSTer we forced the **software** fallback, so the dual-core Cortex-A9 does every
composite → ~15–20 fps. The fix is not to make the software composite cheaper; it
is to give Solarus the accelerator it was designed for by implementing its
`Renderer` interface as a **native FPGA-backed backend** — textures live in DDR3,
every `draw()` is an FPGA blit, the A9 only runs game logic + emits blit commands.
The Cyclone V has ample DDR bandwidth (~3.2 GB/s f2h vs ~64 MB/s needed for a 6×
overdraw frame); the only real engineering is a **properly pipelined fabric 2D
accelerator** (burst DMA, multi-pixel/cycle) — the same class of thing the PSX/DC
cores already do. This is achievable at 320×240@60.

## 1. How Solarus renders on its native (PC) target

`include/solarus/graphics/Renderer.h` is a clean GPU-style 2D abstraction:

| Renderer op | Meaning | Maps to (PC GL) | Maps to (proposed FPGA) |
|---|---|---|---|
| `create_texture(w,h)` | a **render-target** texture | GL FBO+texture | a DDR surface (allocator) |
| `create_texture(SDL_Surface)` | **static** texture from pixels | GL texture upload | DMA pixels → DDR texture |
| `create_window_surface` | the screen | default FBO | the scanout framebuffer |
| `draw(dst,src,infos)` | blit src region → dst | GL textured quad | **FPGA blit command** |
| `fill(dst,color,where,mode)` | solid fill | GL clear/quad | FPGA fill |
| `clear(dst)` | clear target | GL clear | FPGA fill 0 |
| `present(window)` | show result | swap buffers | flip scanout buffer |

`DrawInfos` (DrawProxies.h) carries: **region** (src sub-rect), **dst_position**,
**transformation_origin**, **blend_mode**, **opacity**, **rotation**, **scale**,
**color** (modulation). So a complete backend must blit a sub-region with
blend+opacity (the overwhelming majority of ops) and, more rarely, rotation /
scale / color-mod.

Render flow per frame (MainLoop.cpp:638 → Game::draw → Map::draw → Entities::draw):
`root_surface` (a texture) is the frame; `Map::draw` composites the map onto the
**camera_surface** (another texture), then blits camera_surface→root_surface;
`Video::render(root_surface)` presents. On PC every one of these surfaces is a GPU
texture and every blit is a GPU op — the CPU never touches pixels.

Solarus picks the renderer in `Video.cpp` via `create_chain<GlRenderer,
SDLRenderer>`: GL first, software (`SDLRenderer`) as fallback. `-force-software-
rendering` skips GL. **A `MisterRenderer` would slot in as a first-choice backend**
exactly like `GlRenderer`, implementing the same interface — no engine surgery.

## 2. Why the current MiSTer approach is limited (measured)

We ship the **software** path (`SDLRenderer`, `SDL_RENDERER_SOFTWARE`). Two
consequences, both HW-measured (see memory `blitter-offload-gameplay-truth`):

- **All compositing runs on the A9.** Real overworld gameplay: ~62 small tile
  draws + ~6 big static-cell blits + sprites composited **in software** every
  frame onto camera_surface → **software 20 fps, blitter 15 fps** (standing).
- **The "blitter" today is a `SDLRenderer` *subclass* that intercepts `draw()`.**
  Because surfaces are software SDL surfaces, it tries to *detect* the camera
  surface (the "promote" heuristic) and alias it to DDR. This is the wrong layer:
  it captures the wrong end of the camera_surface→root_surface→window chain, the
  alias **flips on/off non-deterministically** (first-wins pointer lottery), and
  even when it engages it just re-uploads the finished frame (`reup=60`) → it's
  *overhead on top of* the same software composite. Net: blitter < software in
  gameplay. The bg-cache/scroll-cache built on this path are therefore inert.

Root issue: we bolted an accelerator onto the *software* renderer instead of
*being* the accelerated renderer. llvmpipe/Mesa GL was the other attempt and is
too slow for the A9 (memory `fps-profiling-shaders`).

## 3. The Cyclone V / MiSTer platform (what we get to use)

- **HPS:** dual-core Cortex-A9 (asymmetric bandwidth, memory
  `mister-a9-core-affinity`). Runs Linux + the Solarus engine (game logic + Lua).
- **FPGA fabric:** the 2D accelerator lives here (we already have a working
  single-beat blitter; memories `fpga-blitter-design`, `blitter-qword-cache-perf`).
- **Shared DDR3 (1 GB):** HPS owns it; the fabric reaches it via the **FPGA-to-HPS
  SDRAM bridge (MPFE)** — **up to 128-bit @ 200 MHz ≈ 3.2 GB/s**. Our framebuffers
  + textures live here (0x3A000000 video region, 0x3B000000 command/heap region).
- **Video scanout:** a fabric reader streams the DDR framebuffer → HDMI/analog at
  ~60 Hz (`openbor_video_reader`, already working; analog is timing-sensitive —
  memory `burst-dma-timing-outcome`).
- **State of the art on this exact platform:**
  - PSX / Dreamcast cores implement the **entire GPU in fabric** (rasterizer,
    texture cache, framebuffer) — zero A9 graphics. Proof the fabric can sustain
    far more than 320×240@60 of 2D work.
  - OpenBOR (hybrid) = A9 game logic + FPGA video out + DDR3 I/O rings (memory
    `mister-ddr-input-audio`) — our same hybrid class.

## 4. Budget: bandwidth is free; cycles are the lever

One 320×240×16bpp surface = **153.6 KB**. A heavy frame ≈ 6× overdraw composite:
read ~6 source layers + write the result ≈ 7 × 153.6 KB ≈ **1.07 MB/frame** →
**~64 MB/s at 60 fps**. Against ~3.2 GB/s f2h that is **~2% of bandwidth** (50×
headroom). Even 20× overdraw is ~215 MB/s.

So 60 fps is **not** bandwidth-bound. It is bound by the blitter's **cycles per
pixel**. At ~100 MHz the per-frame budget is ~1.67 M cycles; a 6× overdraw frame
is ~1.06 M composited px, so we need **< ~1.5 cyc/px**. The current naive
single-beat blitter is ~7–24 cyc/px (memory `blitter-compute-bound`,
`blitter-qword-cache-perf`) → too slow *as-is*. The fix is architectural and
well-trodden (memory `fpga-blitter-prior-art`, CV1000/Cave): **burst-DMA source
reads + write-coalescing + a pipeline that emits ≥1 px/cycle**, optionally with
on-chip line buffers. Bandwidth headroom is exactly what makes wide bursts free.
Reducing overdraw (static-bg flatten) further relaxes the budget but is secondary.

## 5. Proposed architecture: a native FPGA-accelerated `Renderer`

Replace the `SDLRenderer`-subclass hack with `MisterRenderer : Solarus::Renderer`
(peer of `GlRenderer`), plus a `MisterSurfaceImpl : SurfaceImpl`:

1. **All surfaces are DDR textures.** `MisterSurfaceImpl` holds `{ddr_off, stride,
   w, h, format}` (a handle into a DDR texture allocator) + an optional lazily-
   materialized SDL surface for CPU readback. `create_texture` allocates DDR;
   `create_texture(SDL_Surface)` DMAs pixels in. No software SDL surfaces in the
   hot path → no "promote"/alias heuristics, ever.
2. **Every `draw()` is one fabric blit command.** dst DDR ← src DDR sub-region,
   with blend_mode + opacity. Because dst is *any* DDR texture (render target),
   `Map::draw` composites directly onto the camera_surface **in DDR on the
   fabric** — the A9 issues commands, never touches pixels. This is the offload,
   by construction (no lottery).
3. **`fill`/`clear`** → fabric fill. **`present`** → flip the scanout buffer to the
   `root_surface` texture (it already lives in DDR).
4. **Transform fast-path / fallback.** 1:1 blits (region→dst, blend+opacity) =
   the ~99% fast path on fabric. rotation / non-1.0 scale / color-mod (rare:
   transitions, a few effects) either (a) get a small fabric path later, or (b)
   fall back to a CPU composite into a scratch DDR texture, then blit — correct,
   just not accelerated. **Action: instrument op frequency to size this.**
5. **Readback path.** Some engine code reads surface pixels (`get_surface`,
   pixel collision, screenshots). Provide DDR→CPU copy on demand + a dirty flag;
   keep it off the hot path.
6. **Shaders:** GL-only; unavailable on this backend (already the case under
   force-software). Acceptable.

This is the same shape as the existing blitter *emitter* (command ring + DDR heap)
— we keep the transport (`blt_emitter`, the ring at 0x3B000000, the DDR video
region) and the scanout, and replace the *renderer integration* (stop subclassing
SDLRenderer; implement Renderer directly) and *upgrade the fabric blitter* to the
pipelined accelerator.

## 6. FPGA 2D accelerator upgrade (the cycles work)

Target < ~1.5 cyc/px sustained. Levers (from prior-art memories):
- **Burst source reads** (multi-px per DDR beat) + **write coalescing** (full
  qword/cacheline writes) — already prototyped (readcache/burst branches; note
  the SDRAM-burst analog-vsync regression in `burst-dma-timing-outcome`, must be
  re-integrated analog-safely).
- **Pixel pipeline ≥1 px/cycle** for COPY and BLEND/PALPHA fast paths.
- **On-chip line buffer** for the dst row to amortize read-modify-write blends.
- Keep the f2h arbiter fair with the scanout reader (`ddr_blitter_arb`).
Bandwidth headroom (≥50×) means we can spend it on wide bursts.

## 7. Risks / unknowns (to resolve early, cheaply, with the test harness)

- **Transform-op frequency** (rotation/scale/color-mod): decides fast-path vs
  fallback scope. Instrument `draw()` `DrawInfos` over real gameplay.
- **Texture churn / allocator pressure:** Solarus creates many transient
  surfaces; need a DDR allocator with reuse/eviction (the current heap overflowed
  on scene transitions — sizing matters).
- **Readback frequency:** if the engine reads pixels often, DDR→CPU cost matters.
- **Per-frame command count vs ring/serialization:** the ring currently
  serializes A9+fabric; with a fast fabric, double-buffer the ring.
- **Analog video safety:** any fabric/RBF change risks analog vsync — VISUAL
  validation mandatory (hard lesson, `burst-dma-timing-outcome`). Use the
  screenshot harness + a monitor pass before trusting counters.

## 8. Phased plan (each phase independently measurable on the test harness)

- **P0 — Profiling (no RBF change):** instrument the existing renderer to log, over
  driven real gameplay (scripted-input harness), the full `draw()`/`fill()` op
  mix: counts, blend modes, transform usage, distinct textures, readbacks. Output:
  the exact op profile the backend must serve + the realistic 60 fps cycle budget.
- **P1 — `MisterRenderer` skeleton (engine-only, runs on the working RBF):**
  implement Renderer/SurfaceImpl with DDR textures; route create/draw/fill/present
  through the existing emitter+fabric (current blitter speed). Correctness-first
  (fast-path blits; CPU fallback for transforms). Validate render == software via
  screenshots; expect ≈ current fps but with the A9 freed (measure A9 idle %).
- **P2 — Fabric accelerator upgrade (RBF):** burst/pipelined blitter to hit the
  cycle budget; re-integrate burst analog-safely. Measure fps → target 60.
- **P3 — Overdraw + ring pipelining:** static-bg flatten (now on the *correct*
  fabric path) + double-buffer the command ring if A9 emit becomes the tail.
- **P4 — Generalize:** the same `Renderer`-on-fabric pattern is the reusable
  offload for gmloader/OpenBOR (the strategic goal).

## 8a. P0 op-profile RESULT (2026-06-14, issue #13)

Measured over driven real gameplay (scripted-input, 10× 60-frame windows, multiple
scenes via a 4-direction walk), via `[blitter p0]`:
- **Blend modes used: NONE + BLEND only.** ADD=0, MULTIPLY=0 in every window. The
  fabric fast path needs exactly two modes (opaque copy + alpha blend).
- **Transforms: rotation=0, scale=0, color-mod=0 in EVERY window.** Gameplay uses
  no rotation/scale/color-mod → the CPU fallback (FR5/tasks #15-16) is effectively
  never hit in gameplay; it can be minimal/lazy (menus/effects may still use it).
- **Opacity:** mostly full (255); partial-alpha is a present-but-minority case →
  per-blit opacity required (already supported via the PALPHA path).
- **Distinct textures: 3–9 per 60-frame window** → tiny working set; the DDR
  texture allocator (task #14) is easy to size.
- draws 2–10/frame (large-area camera/tile/sprite blits); the cost is per-pixel
  area (the 512×512/512×256 cell + 16×16 tile mix from the drawn-region histogram),
  not op count → confirms the cycle lever is a pipelined blitter (task #19), and the
  fast path only needs COPY + BLEND(+opacity).
- GAP: readback (`get_surface`) frequency not yet measured (it lives in SurfaceImpl,
  not the renderer) — folded into task #14 when MisterSurfaceImpl is built.
=> Backend fast path = 1:1 region blit, {NONE,BLEND}, per-blit opacity. Everything
else is rare-fallback. This materially de-risks tasks #15/#16.

## 9. What we keep from the SW-optimization phase

- **Black-screen fix** (`bg_handle.valid`) — committed.
- **Autonomous test harness** — the scripted-input driver (`SOLARUS_INPUT_SCRIPT`)
  + mrext screenshot validation. This is how we'll validate every phase headlessly.
- **Transport + scanout** — `blt_emitter`, DDR map (0x3A video / 0x3B command),
  `openbor_video_reader`, the f2h arbiter.
- **Corrected perf model** (`blitter-offload-gameplay-truth`).
Shelved: bg-cache / scroll-cache (wrong layer; revisit only as P3 overdraw cuts on
the proper fabric path).
