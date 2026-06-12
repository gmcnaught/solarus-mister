//
//  MisterBlitterRenderer — a Solarus Renderer backend that offloads 2D
//  compositing to the MiSTer FPGA hardware blitter (fpga-hw-blitter #006).
//
//  It is a DECORATOR over SDLRenderer: it owns a real SDLRenderer (which keeps
//  the SDLRenderer singleton, surfaces, shaders), forwards everything except
//  clear/fill/draw/present, and for those emits blitter commands when the op is
//  expressible — otherwise it transparently falls back to the inner SDLRenderer
//  (per-op) and lets that frame present via the existing SDL path. When the
//  blitter core is absent, create() returns nullptr and the renderer chain
//  falls through to SDLRenderer, so the same binary runs on any core.
//
//  See docs/blitter-renderer-integration.md and the engine-agnostic emitter
//  (patches/mister/blitter/blt_emitter.h, vendored from mister-fpga-blitter).
//
#ifndef SOLARUS_MISTER_BLITTER_RENDERER_H
#define SOLARUS_MISTER_BLITTER_RENDERER_H

#include <solarus/graphics/Renderer.h>
#include <memory>

struct SDL_Window;

namespace Solarus {

class MisterBlitterRenderer : public Renderer {
public:
  // Returns nullptr (chain falls through to SDLRenderer) when the blitter core
  // is absent or this is not a MiSTer build.
  static RendererPtr create(SDL_Window* window, bool force_software);
  ~MisterBlitterRenderer() override;

  // --- forwarded to the inner SDLRenderer ---
  SurfaceImplPtr create_texture(int width, int height) override;
  SurfaceImplPtr create_texture(SDL_Surface_UniquePtr&& surface) override;
  SurfaceImplPtr create_window_surface(SDL_Window* window, int width, int height) override;
  ShaderPtr create_shader(const std::string& shader_id) override;
  ShaderPtr create_shader(const std::string& vertex_source,
                          const std::string& fragment_source, double scaling_factor) override;
  void bind_as_gl_target(SurfaceImpl& surf) override;
  void bind_as_gl_texture(const SurfaceImpl& surf) override;
  void invalidate(const SurfaceImpl& surf) override;
  void on_window_size_changed(const Rectangle& viewport) override;
  std::string get_name() const override;
  const DrawProxy& default_terminal() const override;
  bool needs_window_workaround() const override;

  // --- intercepted: emit blitter commands or fall back ---
  void draw(SurfaceImpl& dst, const SurfaceImpl& src, const DrawInfos& infos) override;
  void clear(SurfaceImpl& dst) override;
  void fill(SurfaceImpl& dst, const Color& color, const Rectangle& where,
            BlendMode mode = BlendMode::BLEND) override;
  void present(SDL_Window* window) override;

private:
  struct Impl;
  std::unique_ptr<Impl> d;
  explicit MisterBlitterRenderer(RendererPtr inner);
};

}  // namespace Solarus

#endif
