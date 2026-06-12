//
//  MisterBlitterRenderer — see mister_blitter_renderer.h.
//
//  Decorator over SDLRenderer. clear/fill/draw to the FPGA target surface are
//  translated into hardware blitter commands (engine-agnostic emitter); every
//  other op, and anything the blitter can't express this frame, transparently
//  falls back to the inner SDLRenderer. present() publishes the blitter command
//  ring to DDR on success, or forwards to the SDL path (which carries the
//  existing native_video_writer DDR hook) on fallback.
//
#include "mister_blitter_renderer.h"

#ifdef MISTER_NATIVE_VIDEO

#include "blitter/blt_emitter.h"

#include <solarus/graphics/sdlrenderer/SDLRenderer.h>
#include <solarus/graphics/SurfaceImpl.h>
#include <solarus/graphics/DrawProxies.h>
#include <solarus/graphics/Color.h>
#include <solarus/core/Rectangle.h>
#include <solarus/core/Point.h>

#include <SDL_surface.h>
#include <SDL_pixels.h>

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <unordered_map>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace Solarus {

// ---- DDR layout for the blitter region.
// MUST MATCH the fabric's fpga/rtl/blitter_defs.vh. The fabric reads control/ring/
// source from 0x3A0E0000 — the tail of the already-proven 1 MiB f2h region at
// 0x3A000000 (native_video_writer), just past the audio ring. (An earlier draft
// used 0x3B000000/8 MiB, but that region's reserved-DDR safety was never confirmed,
// so the fabric deliberately stayed inside 0x3A000000. Keep both sides here.)
//   BLTCTRL 0x3A0E0000 | RING 0x3A0E0040 | SRC heap 0x3A0E8000 | end 0x3A100000
// NOTE (follow-up): the SRC heap is only 96 KiB here — fine for tiles/sprites, too
// small for full-screen source surfaces (a 320x240 RGB565 surface is 150 KiB). A
// larger region (confirm 0x3B000000 safety, or burst-DMA #005) is needed for those.
namespace {
constexpr uint32_t BLT_DDR_PHYS = 0x3A0E0000u;   // = BLTCTRL_QW 0x0741C000
constexpr size_t   BLT_DDR_SIZE = 0x00020000u;   // 128 KiB: ctrl + ring + heap
constexpr uint32_t OFF_RING      = 0x00000040u;  // = RING_QW (BLTCTRL + 0x40)
constexpr uint32_t RING_CAP      = 0x00007FC0u;  // ring spans 0x40..0x8000 (~32 KiB)
constexpr uint32_t OFF_HEAP      = 0x00008000u;  // = SRC_QW 0x3A0E8000
// control-block byte offsets — QWORD-spaced (fabric reads qword fields), low 32 used
constexpr uint32_t C_SUBMIT = 0x00, C_CMDCOUNT = 0x08, C_TARGET = 0x10,
                   C_CLEAR  = 0x18, C_FLAGS    = 0x20, C_DONE = 0x28;

constexpr int FB_W = 320, FB_H = 240;

inline uint16_t to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
}  // namespace

// =====================================================================
struct MisterBlitterRenderer::Impl {
  RendererPtr inner;
  SurfaceImpl* screen = nullptr;     // the create_window_surface result (excluded)

  volatile uint8_t* ddr = nullptr;
  int mem_fd = -1;
  blt_emitter_t em{};

  // per-frame state
  bool frame_active  = false;
  bool frame_escaped = false;
  int  target_buf    = 0;

  // cache: SurfaceImpl -> uploaded source handle (static atlases upload once)
  std::unordered_map<const SurfaceImpl*, blt_surface_ref_t> handles;

  bool map_ddr() {
    mem_fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) return false;
    void* p = ::mmap(nullptr, BLT_DDR_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                     mem_fd, BLT_DDR_PHYS);
    if (p == MAP_FAILED) { ::close(mem_fd); mem_fd = -1; return false; }
    ddr = static_cast<volatile uint8_t*>(p);
    blt_emitter_init(&em, (void*)(ddr + OFF_RING), RING_CAP,
                     (void*)(ddr + OFF_HEAP), BLT_DDR_SIZE - OFF_HEAP);
    return true;
  }

  void ddr_w32(uint32_t off, uint32_t v) {
    *reinterpret_cast<volatile uint32_t*>(ddr + off) = v;
  }

  // Is `dst` the surface we accelerate? Heuristic: a 320x240 render target that
  // is NOT the screen (that is the quest compositing surface). Exact target
  // selection is a HW-tuning item — see docs/blitter-renderer-integration.md.
  bool is_fpga_target(const SurfaceImpl& dst) const {
    return ddr && &dst != screen &&
           dst.get_width() == FB_W && dst.get_height() == FB_H;
  }

  void escape() { frame_escaped = true; }

  void ensure_frame(uint16_t clear_color, bool do_clear) {
    if (!frame_active) {
      blt_begin_frame(&em, target_buf, do_clear ? 1 : 0, clear_color);
      frame_active = true;
      frame_escaped = false;
    }
  }

  // Upload (once) a SurfaceImpl's pixels as RGB565 into the heap; cache by ptr.
  blt_surface_ref_t upload(const SurfaceImpl& src) {
    auto it = handles.find(&src);
    if (it != handles.end()) return it->second;

    blt_surface_ref_t r{};
    SDL_Surface* s = src.get_surface();
    if (!s) return r;
    SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
    if (!c) return r;
    r = blt_upload(&em, static_cast<const uint16_t*>(c->pixels),
                   c->w, c->h, c->pitch);
    SDL_FreeSurface(c);
    if (r.valid) handles[&src] = r;
    return r;
  }

  // Map Solarus blend/opacity/colorkey -> blitter blend. Returns false if the
  // op cannot be expressed by the v1 blitter (caller escapes).
  bool map_blend(const SurfaceImpl& src, const DrawInfos& infos,
                 uint8_t& blend, uint16_t& key, uint8_t& flags) {
    flags = 0;
    if (std::fabs(infos.rotation) > 1e-3) return false;          // no rotation
    if (std::fabs(std::fabs(infos.scale.x) - 1.f) > 1e-3 ||
        std::fabs(std::fabs(infos.scale.y) - 1.f) > 1e-3) return false; // no zoom
    uint8_t cr, cg, cb, ca; infos.color.get_components(cr, cg, cb, ca);
    if (cr != 255 || cg != 255 || cb != 255) return false;        // no tint (v1)
    if (infos.scale.x < 0) flags |= BLT_F_HFLIP;
    if (infos.scale.y < 0) flags |= BLT_F_VFLIP;

    // source colorkey -> COLORKEY (skip-write)
    uint32_t k; key = 0;
    bool has_key = SDL_GetColorKey(src.get_surface(), &k) == 0;
    if (has_key) {
      uint8_t r, g, b; SDL_GetRGB(k, src.get_surface()->format, &r, &g, &b);
      key = to_rgb565(r, g, b);
    }

    switch (infos.blend_mode) {
      case BlendMode::NONE:
        blend = has_key ? BLT_BLEND_COLORKEY : BLT_BLEND_COPY; break;
      case BlendMode::BLEND:
        if (infos.opacity < 255) { blend = BLT_BLEND_CONST_ALPHA;
                                   if (has_key) flags |= BLT_F_COLORKEY; }
        else if (has_key)        { blend = BLT_BLEND_COLORKEY; }
        else return false;   // per-pixel alpha needs ARGB source (v2) -> escape
        break;
      case BlendMode::ADD:
      case BlendMode::MULTIPLY:
      default: return false;                                      // not in v1
    }
    return true;
  }
};

// =====================================================================
MisterBlitterRenderer::MisterBlitterRenderer(RendererPtr inner)
    : d(new Impl()) { d->inner = std::move(inner); }

MisterBlitterRenderer::~MisterBlitterRenderer() {
  if (d->ddr) ::munmap((void*)d->ddr, BLT_DDR_SIZE);
  if (d->mem_fd >= 0) ::close(d->mem_fd);
}

RendererPtr MisterBlitterRenderer::create(SDL_Window* window, bool force_software) {
  // Opt-in for now (safe default): only engage when explicitly enabled. On HW
  // this becomes a probe of the blitter core's DDR magic.
  if (std::getenv("SOLARUS_BLITTER") == nullptr) return nullptr;

  RendererPtr inner = SDLRenderer::create(window, force_software);
  if (!inner) return nullptr;

  auto* self = new MisterBlitterRenderer(std::move(inner));
  if (!self->d->map_ddr()) {
    std::fprintf(stderr, "[MiSTer blitter] /dev/mem map failed; using SDL path\n");
    delete self;
    return nullptr;
  }
  std::fprintf(stderr, "[MiSTer blitter] renderer active (DDR @ 0x%08x)\n", BLT_DDR_PHYS);
  return RendererPtr(self);
}

// ---- forwarders ----
SurfaceImplPtr MisterBlitterRenderer::create_texture(int w, int h) {
  return d->inner->create_texture(w, h);
}
SurfaceImplPtr MisterBlitterRenderer::create_texture(SDL_Surface_UniquePtr&& surface) {
  return d->inner->create_texture(std::move(surface));
}
SurfaceImplPtr MisterBlitterRenderer::create_window_surface(SDL_Window* w, int width, int height) {
  SurfaceImplPtr s = d->inner->create_window_surface(w, width, height);
  d->screen = s.get();   // exclude the screen from blitter targeting
  return s;
}
ShaderPtr MisterBlitterRenderer::create_shader(const std::string& id) {
  return d->inner->create_shader(id);
}
ShaderPtr MisterBlitterRenderer::create_shader(const std::string& vs, const std::string& fs, double sf) {
  return d->inner->create_shader(vs, fs, sf);
}
void MisterBlitterRenderer::bind_as_gl_target(SurfaceImpl& s)  { d->inner->bind_as_gl_target(s); }
void MisterBlitterRenderer::bind_as_gl_texture(const SurfaceImpl& s) { d->inner->bind_as_gl_texture(s); }
void MisterBlitterRenderer::invalidate(const SurfaceImpl& s) {
  d->handles.erase(&s);   // drop a cached upload if the surface is freed/changed
  d->inner->invalidate(s);
}
void MisterBlitterRenderer::on_window_size_changed(const Rectangle& v) { d->inner->on_window_size_changed(v); }
std::string MisterBlitterRenderer::get_name() const { return "mister_blitter"; }
const DrawProxy& MisterBlitterRenderer::default_terminal() const { return d->inner->default_terminal(); }
bool MisterBlitterRenderer::needs_window_workaround() const { return d->inner->needs_window_workaround(); }

// ---- intercepted ops ----
void MisterBlitterRenderer::clear(SurfaceImpl& dst) {
  if (d->is_fpga_target(dst)) {
    d->frame_active = false;          // a clear starts a fresh blitter frame
    d->ensure_frame(0x0000, /*do_clear=*/true);
    return;
  }
  d->inner->clear(dst);
}

void MisterBlitterRenderer::fill(SurfaceImpl& dst, const Color& color,
                                 const Rectangle& where, BlendMode mode) {
  if (d->is_fpga_target(dst) && mode != BlendMode::ADD && mode != BlendMode::MULTIPLY) {
    d->ensure_frame(0x0000, false);
    uint8_t r, g, b, a; color.get_components(r, g, b, a);
    blt_fill(&d->em, where.get_x(), where.get_y(),
             where.get_width(), where.get_height(), to_rgb565(r, g, b));
    return;
  }
  if (d->is_fpga_target(dst)) d->escape();
  d->inner->fill(dst, color, where, mode);
}

void MisterBlitterRenderer::draw(SurfaceImpl& dst, const SurfaceImpl& src,
                                 const DrawInfos& infos) {
  if (d->is_fpga_target(dst)) {
    uint8_t blend, flags; uint16_t key;
    blt_surface_ref_t h = d->upload(src);
    if (h.valid && d->map_blend(src, infos, blend, key, flags)) {
      d->ensure_frame(0x0000, false);
      const Rectangle& r = infos.region;
      Rectangle dr = infos.dst_rectangle();
      blt_blit(&d->em, h, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
               dr.get_x(), dr.get_y(), blend, key, infos.opacity, flags);
      return;
    }
    d->escape();          // unsupported op -> whole frame falls back to SDL
  }
  d->inner->draw(dst, src, infos);
}

void MisterBlitterRenderer::present(SDL_Window* window) {
  if (d->frame_active && !d->frame_escaped && !d->em.overflow) {
    blt_end_frame(&d->em);
    d->ddr_w32(C_CMDCOUNT, (uint32_t)d->em.cmd_count);
    d->ddr_w32(C_TARGET,   (uint32_t)d->em.target_buf);
    d->ddr_w32(C_CLEAR,    d->em.clear_color);
    d->ddr_w32(C_FLAGS,    d->em.flags);
    __sync_synchronize();                 // commit ring+ctrl before the doorbell
    d->ddr_w32(C_SUBMIT,   d->em.submit_seq);
    d->target_buf ^= 1;                   // next frame composites the other buffer
  } else {
    d->inner->present(window);            // SDL path carries the existing DDR hook
  }
  d->frame_active = false;
  d->frame_escaped = false;
}

}  // namespace Solarus

#else  // !MISTER_NATIVE_VIDEO — stub so non-MiSTer builds fall through to SDL

#include <solarus/graphics/Renderer.h>
namespace Solarus {
RendererPtr MisterBlitterRenderer::create(SDL_Window*, bool) { return nullptr; }
}

#endif
