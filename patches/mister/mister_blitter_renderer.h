//
//  MisterBlitterRenderer — a Solarus Renderer backend that offloads 2D
//  compositing to the MiSTer FPGA hardware blitter (fpga-hw-blitter #008).
//
//  IMPLEMENTATION (subclass model — supersedes the earlier decorator):
//  Solarus dispatches ALL surface drawing through the SDLRenderer SINGLETON
//  (`SDLRenderer::get()` -> `*instance`, set in the SDLRenderer ctor). A
//  decorator that merely wraps an SDLRenderer never becomes that singleton, so
//  it only ever sees present()/clear() and every sprite/tile/composite draw
//  bypasses it. To actually intercept the draw stream we must BE the singleton:
//  MisterBlitterRenderer SUBCLASSES SDLRenderer, so its ctor runs the base
//  ctor (which sets instance=this to OUR object) and `SDLRenderer::get()`
//  returns us. We override only draw/fill/clear/present and INHERIT everything
//  else (create_texture, shaders, window surface, ...).
//
//  COHERENCE: the fabric is the SOLE renderer. Every op targeting the 320x240
//  quest render-target becomes a blitter command, and present() always submits
//  the ring (the fabric composites the DDR framebuffer + bumps the video control
//  word). There is NO SDL readback fallback: fabric coverage is full, so the old
//  double-render + readback-present was removed. Base SDL still renders SDL-backed
//  source surfaces (atlases/intermediates) that the fabric uploads as sources.
//
//  When SOLARUS_BLITTER is unset or the DDR map fails, create() returns nullptr
//  and SDLRenderer::create() builds a plain SDLRenderer instead, so the same
//  binary runs on any core.
//
#ifndef SOLARUS_MISTER_BLITTER_RENDERER_H
#define SOLARUS_MISTER_BLITTER_RENDERER_H

#include <solarus/graphics/sdlrenderer/SDLRenderer.h>
#include <memory>
#include <vector>

struct SDL_Window;
struct SDL_Renderer;

namespace Solarus {

class MisterBlitterRenderer : public SDLRenderer {
public:
  // Construct a blitter renderer wrapping the given SDL software renderer.
  // Returns nullptr if SOLARUS_BLITTER is unset or the DDR map fails, in which
  // case the caller (SDLRenderer::create) builds a plain SDLRenderer instead.
  // Takes ownership semantics identical to the SDLRenderer ctor.
  static MisterBlitterRenderer* try_create(SDL_Renderer* renderer, bool shaders);

  ~MisterBlitterRenderer() override;

  // --- intercepted: render normally via base AND emit blitter commands ---
  void draw(SurfaceImpl& dst, const SurfaceImpl& src, const DrawInfos& infos) override;
  // [#52] Batched animated-tile draw: emit ONE BLT_OP_TILELIST per batch when dst is
  // the aliased camera surface and the fabric is live; else the base per-entry fallback.
  void draw_tile_batch(SurfaceImpl& dst, const SurfaceImpl& tileset_image,
                       BlendMode blend,
                       const std::vector<TileBatchEntry>& entries) override;
  // [#52 resident] Resident animated-tile list (SOLARUS_TILERESIDENT). See the base
  // Renderer decls for the protocol; defaults (software path) keep the per-frame walk.
  int  resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id) override;
  bool resident_take_patch_turn() override;
  size_t resident_pattern_count() const override;
  uintptr_t resident_pattern_token(size_t k) const override;
  void resident_update(uintptr_t token, const Rectangle& cur_src, int current_frame,
                       int frame_count, const Rectangle* frames) override;
  void resident_record_batch(int layer, int scroll_ratio,
                             const SurfaceImpl& tileset_image, BlendMode blend,
                             const std::vector<TileBatchEntry>& entries,
                             const std::vector<uintptr_t>& tokens) override;
  void resident_escape(int layer, uintptr_t tile) override;
  void resident_emit_layer(int layer) override;
  int  resident_layer_op_count(int layer) const override;
  uintptr_t resident_layer_op_tile(int layer, int i) const override;
  void resident_emit_layer_op(int layer, int i) override;
  int  resident_room_entries() const override;
  void clear(SurfaceImpl& dst) override;
  void fill(SurfaceImpl& dst, const Color& color, const Rectangle& where,
            BlendMode mode = BlendMode::BLEND) override;
  void present(SDL_Window* window) override;

  void invalidate(const SurfaceImpl& surf) override;
  std::string get_name() const override;

private:
  MisterBlitterRenderer(SDL_Renderer* renderer, bool shaders);
  void res_hw_arm_();   // [#52 Tier B] write FRT + 8-byte entries to DDR (first fast frame)
  void res_emit_bucket_(std::size_t idx);  // [#52 resident] emit one recorded bucket
  struct Impl;
  std::unique_ptr<Impl> d;
};

}  // namespace Solarus

#endif
