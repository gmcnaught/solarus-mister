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
//  COHERENCE: the base SDLRenderer still renders every frame normally (so the
//  existing readback->DDR present path always has a correct frame). In parallel
//  we emit blitter commands for the expressible ops targeting the 320x240
//  render-target. In present(): if the frame was fully expressible we submit
//  the blitter ring (the fabric composites the DDR framebuffer + bumps the
//  video control word) and skip the readback; otherwise we fall back to the
//  proven base present. So the screen is ALWAYS correct and we can measure how
//  many frames the fabric rendered.
//
//  When SOLARUS_BLITTER is unset or the DDR map fails, create() returns nullptr
//  and SDLRenderer::create() builds a plain SDLRenderer instead, so the same
//  binary runs on any core.
//
#ifndef SOLARUS_MISTER_BLITTER_RENDERER_H
#define SOLARUS_MISTER_BLITTER_RENDERER_H

#include <solarus/graphics/sdlrenderer/SDLRenderer.h>
#include <memory>

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
  void clear(SurfaceImpl& dst) override;
  void fill(SurfaceImpl& dst, const Color& color, const Rectangle& where,
            BlendMode mode = BlendMode::BLEND) override;
  void present(SDL_Window* window) override;

  void invalidate(const SurfaceImpl& surf) override;
  std::string get_name() const override;

private:
  MisterBlitterRenderer(SDL_Renderer* renderer, bool shaders);
  struct Impl;
  std::unique_ptr<Impl> d;
};

}  // namespace Solarus

#endif
