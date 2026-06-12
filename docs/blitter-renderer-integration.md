# Solarus ↔ FPGA blitter integration (MisterBlitterRenderer)

How the Solarus engine drives the FPGA hardware blitter, by mapping its
`Renderer` interface onto the engine-agnostic host emitter
(`mister-fpga-blitter/host/blt_emitter.h`). This is the **engine-specific
binding** (the emitter + protocol + RTL are engine-agnostic and live in the
`mister-fpga-blitter` repo).

> Status: design + code sketch. Compiling this needs the armhf engine toolchain
> (see this repo's CLAUDE.md) and is gated on the blitter RTL landing on hardware
> (fpga-hw-blitter #003/#004/#005). The emitter it calls is already implemented
> and unit-tested against the reference model.

## Where it plugs in

Solarus picks a renderer via `create_chain<GlRenderer, SDLRenderer>`. We add a
third, tried first on MiSTer when the blitter core is present:

```
create_chain<MisterBlitterRenderer, SDLRenderer>   // GL compiled out already
```

`MisterBlitterRenderer` implements `Renderer` (draw/fill/clear/present/…). It is a
**graceful accelerator**: anything it can't express this frame makes the whole
frame fall back to the existing SDL software path + `native_video_writer`. So
correctness never depends on blitter coverage — only performance does.

## Capability probe (fallback when absent)

At construction, probe for the blitter core (e.g. a known magic in the DDR
blitter control region, or the core ID). If absent, `create()` returns null and
the chain falls through to `SDLRenderer` — same binary runs on any core.

## Surface model

Each Solarus `Surface` that becomes a blit source gets an associated
`blt_surface_ref_t`, uploaded lazily and cached on the `SurfaceImpl`:

```cpp
// in create_texture(SDL_Surface_UniquePtr&& s):  (static textures: tiles/sprites)
auto impl = make_blitter_impl(std::move(s));
impl->blt = {};                       // uploaded on first use, then cached
// on first draw():
if (!impl.blt.valid) {
    convert_to_rgb565(impl.sdl_surface, scratch);          // engine is RGBA
    impl.blt = blt_upload(&em, scratch, w, h, w*2);        // upload ONCE
}
```

Static atlases (tilesets, sprite sheets) upload once and persist (the emitter
heap is a persistent bump allocator). A surface modified on the CPU invalidates
its handle → re-upload (the #005 dirty-tracking path). Intermediate **render
targets** (`create_texture(w,h)` used as a draw destination) are not a v1 blitter
target — drawing *to* an offscreen surface forces SDL fallback for that frame.

## Method mapping

| `Renderer` method | Blitter action |
|---|---|
| `clear(screen)` | `blt_begin_frame(target, clear=1, 0x0000)` |
| `fill(screen, color, where, mode)` | `blt_fill(x,y,w,h, to_rgb565(color))` (NONE/BLEND solid) |
| `draw(screen, src, infos)` | `blt_blit(src.blt, region, dst, blend, key, alpha, flags)` |
| `present(window)` | `blt_end_frame()` → publish ring + control block to DDR → bump doorbell |
| `draw`/`fill` to a **non-screen** dst | mark frame `escaped`, fall back to SDL |

Frame boundaries: Solarus has no explicit "begin frame", so `clear(screen)`
starts a blitter frame; if a frame's first screen op isn't a clear, lazily
`blt_begin_frame(..., clear=0)`. `present()` ends it.

### BlendMode / opacity → blend opcode

`DrawInfos` carries `opacity` (0..255) and a `BlendMode`:

```cpp
uint8_t blend, alpha = infos.opacity; uint8_t flags = 0; uint16_t key = 0;
switch (infos.blend_mode) {
  case BlendMode::NONE:  blend = BLT_BLEND_COPY; break;
  case BlendMode::BLEND:
     if (src_has_colorkey)      { blend = BLT_BLEND_COLORKEY; key = src_colorkey_565; }
     else if (alpha < 255)      { blend = BLT_BLEND_CONST_ALPHA; }
     else if (src_has_per_pixel_alpha) { goto fallback; }  // v2: ARGB source
     else                       { blend = BLT_BLEND_COPY; }
     if (alpha < 255 && blend == BLT_BLEND_COLORKEY)
        { blend = BLT_BLEND_CONST_ALPHA; flags |= BLT_F_COLORKEY; }  // keyed + faded
     break;
  case BlendMode::ADD:
  case BlendMode::MULTIPLY: goto fallback;                 // not in v1
}
// transforms: flips -> BLT_F_HFLIP/VFLIP; rotation/non-integer scale -> fallback
//             (integer zoom is reserved in the protocol for v2)
```

`infos` region → `src_x/src_y/w/h`; `infos` dst x/y → `dst_x/dst_y` (signed; the
fabric clips + culls). Anything reaching `fallback:` sets the frame `escaped`.

## present(): publishing the frame

`present()` is the DDR hand-off. It replaces the per-frame work
`native_video_writer` does today; the blitter composites and writes the video
control word itself (drop-in producer):

```cpp
void MisterBlitterRenderer::present(SDL_Window*) {
  if (frame_escaped || em.overflow) { sdl_fallback_present(); return; }
  blt_end_frame(&em);
  ddr_copy(BLT_RING_ADDR,  em.ring, em.cmd_count * 32);   // commands
  ddr_write_ctrl(em.cmd_count, em.target_buf, em.flags, em.clear_color);
  ddr_write_u32(BLT_SUBMIT, em.submit_seq);               // doorbell (last!)
  // optional: wait/poll done_seq before reusing this target buffer
  swap_target_buf();
}
```

Ordering matches the existing writer's rule: all ring/control writes commit
before the `submit_seq` store (strongly-ordered device memory via `/dev/mem`
`O_SYNC`+`MAP_SHARED`, as `native_video_writer.c` already documents).

## Why this is the right altitude

The win isn't only cheaper pixels — it's removing the A9-side per-draw traversal
and SDL call overhead. A Solarus frame is tens-to-hundreds of `draw()` calls;
each becomes a ~32-byte command emit (a struct fill + pack) instead of an
`SDL_RenderCopy` + software blit. The fabric then sweeps the list. The SDL path
stays as the always-correct fallback.

## Open items (tracked elsewhere)
- Render-to-texture targets, `ADD`/`MULTIPLY`, per-pixel alpha, rotation/scale →
  SDL fallback in v1; candidates for v2 (per-pixel alpha + zoom are reserved in
  the protocol command word).
- Dirty-tracking of changed dynamic surfaces → fpga-hw-blitter #005.
- HW bring-up of this binding → fpga-hw-blitter #003/#004 + a real armhf build.
