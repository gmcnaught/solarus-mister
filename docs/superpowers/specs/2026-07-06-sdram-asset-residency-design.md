# One-time SDRAM asset residency for Solarus — design

**Date:** 2026-07-06
**Branch:** `design/sdram-asset-residency`
**Status:** approved design, pre-implementation-plan

## Goal & guiding principle

Replace the current **lazy, per-scene, evict-and-reset** source-atlas staging with a
**write-once residency model**: at quest open, every immutable image asset is staged
into SDRAM exactly once and stays resident for the quest's lifetime. Mutable
intermediate surfaces (menu/text/render-target compositions) get their own recycled
region and an explicit lifecycle.

**The metric for this work is architectural simplicity.** The win is deleting the
churn / eviction / overflow-escape machinery, not fps. Perf and correctness that are
at worst a wash are acceptable outcomes; the deliverable is a simpler, more
maintainable compositing front-end.

This is the jtframe "load the ROM into SDRAM at boot" pattern applied to Solarus:
because the A9 **cannot write SDRAM directly** (the DE10-Nano second SDRAM bus is not
in the HPS memory map — only the fabric can write it), every byte is handed to the
fabric, exactly as a jtframe core streams ROM through the fabric into SDRAM. The
existing `BLT_OP_STAGE` (DDR3→SDRAM fabric copy) already *is* that mechanism in
miniature; this project changes the **policy** around it (upfront, permanent, no
eviction), not the transport.

## Background: what the code actually does today (ground truth)

- **Source atlases already live in SDRAM at composite time.** Path today:
  A9 decodes a PNG → converts to RGB565/ARGB4444 → `memcpy` into a **DDR3 bounce heap**
  (`0x3B080000`, `OFF_HEAP`) → emits `BLT_OP_STAGE`; the *fabric* copies DDR3→SDRAM
  (`SDRAM_ATLAS_BASE = 16 MiB`); subsequent blits read the source from **SDRAM** via
  the per-command `BLT_F_SRC_SDRAM` flag. So steady-state playtime already reads
  sources off the fabric's own SDRAM bus, not f2h. The DDR heap is a transient
  *bounce*, not a residency store.
- **The pain is the lazy policy, not the transport:** per-scene bump-allocation that
  leaks across scene changes, `heap_reset` + transition-reclaim (one black frame on
  scroll transitions), `scene_too_big` → `blitter_off()` software fallback, and
  `dirty_src` re-upload tracking. Plus the **pointer-keyed handle cache** whose keys
  go stale when transient surfaces are destroyed and their addresses reused — the
  render-corruption bug that opened this line of work.
- **Solarus has a path-keyed image cache** (`src/graphics/Surface.cpp`):
  `std::map<std::string, SurfaceImplPtr> image_files_cache` keyed by resolved file
  name, populated by `get_surface_from_file()`, cleared only by `empty_cache()`.
  File-based images therefore have **stable, quest-lifetime identity** — the
  `SurfaceImplPtr` is not destroyed mid-quest.
- **`SurfaceImpl` carries no path/identity** — only pixels, dims, and (on
  `SDLSurfaceImpl`) a `surface_dirty` flag. Identity today is the raw pointer.
- **Not everything is a static asset.** Menus/dialogs/text draw onto *intermediate*
  surfaces that mutate every frame and are destroyed/recreated — these are what
  `dirty_src` serves and what causes pointer reuse. They are structurally distinct
  from file-cache images.
- **bg-cache is already removed** (single-pipeline merge — `mister_blitter_renderer.cpp`
  ~L837). **Carry-forward** is a *framebuffer*-persistence mechanism (FB→FB SDRAM copy),
  already disabled on the shipped FB-in-BRAM (`SINGLEBUF`) path. Neither is a
  source-atlas mechanism; both are out of scope for this design.

## SDRAM layout (single 64 MiB chip, `SDRAM_AW = 23`)

Three disjoint regions, all reachable on the fabric SDRAM bus:

| Region | Purpose | Allocator | Sizing |
|---|---|---|---|
| **Framebuffers** (`SDRAM_FB0/1_BASE`) | scanout double-buffer | fixed | unchanged (~0.5 MiB) |
| **Immutable atlas** (new, permanent) | all quest image files, write-once | grow-only bump, never reset | bulk of chip (~40+ MiB) |
| **Intermediate** (new, recycled) | mutable target/text/menu surfaces | small allocator, lifecycle-driven free | bounded (a few MiB) |

- The **immutable region** uses a bump allocator that **only grows during preload** and
  is never reset — no free-list, no eviction, no transition reclaim.
- The **intermediate region** keeps a small allocator whose frees are driven by surface
  destruction (see below).
- Region bases become explicit constants in the renderer, matching the fabric's
  `SDRAM_ATLAS_BASE` / FB bases in `vram_defs.vh`.

## Component 1 — Immutable asset preload (the core change)

Triggered at **quest open**, after the renderer/video is initialised but before the
first composited frame.

1. **Enumerate** the quest data tree recursively (`QuestFiles::data_file_list_dir`)
   for every image file (`.png`, plus font bitmap images).
   - **Decision: filesystem walk, not the resource DB.** The DB (`QuestDatabase::
     get_resource_elements`) omits ad-hoc `sol.surface.create("menus/…​.png")` images
     loaded from Lua by path. A filesystem walk is complete. The accepted cost is
     preloading assets a given play session may never use (bounded by total quest art).
2. For each file, `Surface::create(file, base_dir)` → populates `image_files_cache`
   with a **stable, quest-lifetime `SurfaceImplPtr`** → drive the existing
   upload + `blt_stage_surface` path once, allocating into the **permanent immutable
   region**.
3. **Identity = the cache-stable pointer.** Because these surfaces live for the whole
   quest, the renderer's existing `(SurfaceImpl*, fmt)` handle cache is safe *for
   them* — no stale-pointer risk, no content hashing.

Reuses the **existing `BLT_OP_STAGE` primitive** end-to-end — **no new RTL for v1.**
The DDR3 bounce heap is used only transiently during preload and per-batch thereafter.

## Component 2 — Mutable intermediate region + destruction hook

Everything **not** resident in `image_files_cache` — render targets, text surfaces,
dynamically composed menu layers — is transient and mutates. These:

- stage into the **intermediate region**, keyed by pointer;
- are reclaimed by a **destruction hook** `mister_forget_surface(const SurfaceImpl*)`
  wired into `~SurfaceImpl` / `~SDLSurfaceImpl`, which frees the surface's intermediate
  slot and evicts its handle-cache entry. **This is the actual fix for the
  stale-pointer render-corruption bug** — the pointer-keyed cache can no longer serve a
  freed-and-reused address.
- re-stage on the `surface_dirty` flag (already present on `SDLSurfaceImpl`). This is
  the **only** place per-frame re-staging survives.

## Component 3 — Deletions (the simplification payoff)

Remove from the renderer / emitter:

- `scene_too_big` state, `escape()`, `blitter_off()` software-fallback path;
- `heap_reset` + transition-reclaim (`was_in_transition`, `g_transition_scroll`
  scroll-edge resets, `heap_reset_pending`);
- bump-heap eviction / leak-across-scenes handling on the immutable path;
- `dirty_src` **for static assets** (retained only for the intermediate region);
- vestigial bg-cache env-var reads / comments.

**Out of scope (separate cleanup):** carry-forward (`blt_blit_fb_copy`) — a framebuffer
mechanism already disabled on the FB-in-BRAM path.

## Overflow policy & capacity lever

- Preload sums the decoded footprint. If it **exceeds the immutable region, abort with a
  loud fatal** naming footprint vs cap. **No runtime fallback** — the absence of a
  fallback is precisely what permits deleting the `scene_too_big` / escape path.
- Mystery of Solarus DX is validated to fit during first HW bring-up.
- **Escape valve for a future over-cap quest:** bump `SDRAM_AW` 23 → 24 to enable
  jtframe **XL mode → 128 MiB** on the **primary** SDRAM bus
  (`jtframe_burst_sdram.v`: `localparam XL = AW == 24; prog_chip = XL ? prog_addr[AW-1]
  : 0` — the top address bit selects the upper 64 MiB half of the MiSTer 128 MiB
  module), then extend the atlas allocator + address decode into the upper half.
  **No analog-VGA cost** (this is the primary bus, *not* the VGA-muxed `SDRAM2_*` /
  `MISTER_DUAL_SDRAM` secondary bus). Documented as a future lever, not v1.

## Validation

- **Host / sim (no HW):**
  - unit-test the preload enumerator: asset list → summed footprint;
  - unit-test the intermediate allocator against a fake staging backend: alloc, free on
    destruction, no leak, no double-free, address-reuse does not resurrect a stale
    handle.
- **Hardware (MoSDX on 192.168.20.81):**
  - quest opens; preload completes within a stated load-time budget; measured immutable
    footprint recorded vs region cap;
  - steady-state overworld and a **scroll transition** render correctly with
    `scene_too_big` / escape / heap-reset code removed;
  - title / menu intermediates (the former stale-pointer repro) render clean across
    repeated open/close cycles;
  - fps at least neutral vs the pre-change engine.

## Key risks

1. **Enumeration completeness** — a runtime-generated image path not present as a file
   falls to the intermediate path (correct behaviour, just un-preloaded). Acceptable.
2. **Footprint headroom** — needs the real MoSDX decoded total (RGB565/ARGB4444) vs
   region size; measured at first HW bring-up. XL (128 MiB) is the backstop.
3. **Preload load-time** — decoding + staging every PNG up front lengthens quest open;
   bounded and one-time.

## Follow-up (post-merge, not this project)

- Correct the `mister-ddr-and-sdram-hw-access` memory: the extra 64 MiB is reachable via
  jtframe **XL** on the **primary** bus (`AW=24`), not via the VGA-muxed `SDRAM2_*`
  secondary bus. The "2nd chip on SDRAM2 / costs analog VGA" framing is wrong for the XL
  path.
- Separate cleanup of the retired carry-forward framebuffer path.
