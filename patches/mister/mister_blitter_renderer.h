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
  // [#52 resident, Task 7] Resident animated-tile list (SOLARUS_TILERESIDENT) is now the
  // SOLE fabric tile path — the non-resident per-frame batched-tile virtual (Task 6's
  // addition, since removed from the base Renderer class entirely) is gone; the engine's
  // animated-tile walk only ever calls resident_record_batch now. See the base Renderer
  // decls for the resident protocol.
  int  resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id, int min_layer) override;
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
  // [static tile-list] Non-animated tile buckets, parallel to resident_record_batch/
  // resident_layer_op_count/resident_emit_layer_op but for the direct BLT_OP_TILELIST path
  // (12-byte entries, no FRT/pattern indirection). See mister_blitter_renderer.cpp.
  void resident_record_static(int layer, int scroll_ratio,
                              const SurfaceImpl& tileset_image, BlendMode blend,
                              const std::vector<TileBatchEntry>& entries) override;
  int  resident_static_op_count(int layer) const override;
  void resident_emit_static_op(int layer, int i) override;
  // [Phase 3b, generalized Task 6] One call replacing the per-op static replay
  // loop above: emits a single windowed COPY from THIS layer's own baked
  // background plane when it's ready (bgplane_enabled && this layer has a
  // valid entry in d->bg_planes), else falls back to replaying every static
  // bucket via res_emit_static_bucket_ (the same work
  // resident_static_op_count/resident_emit_static_op used to drive from the
  // engine side). See mister_blitter_renderer.cpp.
  void resident_emit_static_layer(int layer) override;
  // [Phase 3b, generalized Task 6] Background-plane bake (SOLARUS_BGPLANE):
  // advance ONE layer's one-time cell-by-cell bake of that layer's static
  // tiles into its own permanent SDRAM plane, by one cell per call --
  // sequenced across however many layers (d->bg_planes) currently have a bake
  // in progress. NOT a Renderer override -- called directly (via the same
  // free-function/engine-glue pattern as mister_preload_quest_assets) once
  // per present() and gates its per-frame static-bucket replacement on the
  // result. Returns true once no layer is (still) baking -- either every
  // eligible layer's plane is valid, or this map had no baking-eligible layer
  // at all; a no-op returning true when nothing is in progress.
  bool bake_background_plane_step();
  void clear(SurfaceImpl& dst) override;
  void fill(SurfaceImpl& dst, const Color& color, const Rectangle& where,
            BlendMode mode = BlendMode::BLEND) override;
  void present(SDL_Window* window) override;

  void invalidate(const SurfaceImpl& surf) override;
  std::string get_name() const override;

  // [residency] Public forward-decl so the file-scope `g_active_impl` (Impl*) and the
  // free functions (mister_preload_quest_assets / mister_forget_surface) can name the
  // type. The definition stays private to the .cpp; `d` below remains private.
  struct Impl;

private:
  MisterBlitterRenderer(SDL_Renderer* renderer, bool shaders);
  void res_arm_();      // [#52 resident, Task 7] write FRT + 8-byte entries to DDR (first fast frame)
  void res_emit_bucket_(std::size_t idx);  // [#52 resident] emit one recorded bucket
  void res_emit_static_bucket_(std::size_t idx);  // [static tile-list] emit one static bucket
  std::unique_ptr<Impl> d;
};

// [residency] One-time whole-quest asset preload; call at quest-open (from MainLoop::run).
// [#84 Tier-2] `rp` (may be null) lets the preload stage each TILESET's SHARED
// get_tiles_image() surface (via ResourceProvider::get_tileset) — the exact
// SurfaceImpl* gameplay draws — so gameplay tiles HIT the preloaded paletted copy
// instead of re-staging their own into the 4 MiB INTER region.
class ResourceProvider;   // fwd (these free fns are already inside namespace Solarus)
void mister_preload_quest_assets(Solarus::ResourceProvider* rp);

// [residency] Called from ~SurfaceImpl so the blitter cache never serves a freed-and-
// reused surface address (root cause of the render-corruption stale-pointer bug).
void mister_forget_surface(const Solarus::SurfaceImpl* p);

// [OSD] True exactly once when the OSD "Restart Quest" toggle transitions off->on
// (edge-detection state lives in the renderer). Call once per frame from
// MainLoop::run(); false (never triggers) if the blitter renderer isn't active
// (SOLARUS_BLITTER unset / DDR map failed).
bool mister_osd_restart_requested();

// [OSD] Feed the current rolling FPS value to the renderer so it can draw the
// lower-right FPS overlay when the OSD "FPS Overlay" option is on. No-op if the
// blitter renderer isn't active.
void mister_set_fps(double fps);

}  // namespace Solarus

#endif
