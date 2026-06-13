//
//  MisterBlitterRenderer — see mister_blitter_renderer.h.
//
//  SUBCLASS of SDLRenderer (the draw-dispatch singleton). The base class still
//  renders every frame normally; in parallel we translate clear/fill/draw on
//  the 320x240 render-target into hardware blitter commands. present() submits
//  the blitter ring when the whole frame was expressible (the fabric composites
//  the DDR framebuffer), otherwise it falls back to the proven base present
//  (software readback -> native_video_writer -> DDR).
//
#include "mister_blitter_renderer.h"

#ifdef MISTER_NATIVE_VIDEO

#include "blitter/blt_emitter.h"

#include <solarus/graphics/sdlrenderer/SDLSurfaceImpl.h>
#include <solarus/graphics/SurfaceImpl.h>
#include <solarus/graphics/DrawProxies.h>
#include <solarus/graphics/Color.h>
#include <solarus/core/Rectangle.h>
#include <solarus/core/Point.h>

#include <SDL_render.h>
#include <SDL_surface.h>
#include <SDL_pixels.h>

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cmath>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace Solarus {

// ---- DDR layout for the blitter region.
// MUST MATCH the fabric's fpga/rtl/blitter_defs.vh. The fabric reads control/ring/
// source from 0x3A0E0000 — the tail of the already-proven 1 MiB f2h region at
// 0x3A000000 (native_video_writer), just past the audio ring.
//   BLTCTRL 0x3A0E0000 | RING 0x3A0E0040 | SRC heap 0x3A0E8000 | end 0x3A100000
// NOTE: the SRC heap is only 96 KiB — fine for tiles/sprites, too small for full
// 320x240 source surfaces (150 KiB). Larger sources ESCAPE to the SDL path.
namespace {
constexpr uint32_t BLT_DDR_PHYS = 0x3A0E0000u;
constexpr size_t   BLT_DDR_SIZE = 0x00020000u;   // 128 KiB: ctrl + ring + heap
constexpr uint32_t OFF_RING      = 0x00000040u;
constexpr uint32_t RING_CAP      = 0x00007FC0u;  // ring spans 0x40..0x8000 (~32 KiB)
constexpr uint32_t OFF_HEAP      = 0x00008000u;
// control-block byte offsets — QWORD-spaced (fabric reads qword fields), low 32 used
constexpr uint32_t C_SUBMIT = 0x00, C_CMDCOUNT = 0x08, C_TARGET = 0x10,
                   C_CLEAR  = 0x18, C_FLAGS    = 0x20, C_DONE = 0x28;

constexpr int FB_W = 320, FB_H = 240;

// Video control word @ 0x3A000000 (shared with native_video_writer):
//   frame_counter[31:2] | active_buf[1:0]. The fabric bumps this itself on a
//   blitter submit, but native_video_writer keeps a *separate* internal toggle.
//   We read/seed it so blitter-frames and escape-frames advance one buffer at a
//   time without colliding.
constexpr uint32_t VIDEO_CTRL_PHYS = 0x3A000000u;

inline uint16_t to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
}  // namespace

// =====================================================================
struct MisterBlitterRenderer::Impl {
  volatile uint8_t* ddr = nullptr;
  int mem_fd = -1;
  blt_emitter_t em{};

  // Optional second mapping of the VIDEO framebuffer region (0x3A000000) so we
  // can read back what the fabric composited and compare it, IN-PROCESS, to the
  // software frame. In-process is the only reliable readback: a separate
  // devmem/dd process gets a fresh cached mapping of normal DDR and reads stale
  // zeros (confirmed: even the proven pure-SDL baseline reads 0 via devmem).
  bool verify = false;
  volatile uint8_t* vid = nullptr;
  int vid_fd = -1;
  SDL_Renderer* sdl = nullptr;          // base SDL renderer, for software readback
  long g_verify_n = 0; double g_verify_match = 0.0; long g_verify_nz = 0;

  // The 320x240 render-target surface we accelerate (the quest root surface).
  // Locked on the first 320x240 non-screen target we see drawn to, so we don't
  // mistake a transient same-size buffer for the root.
  const SurfaceImpl* fpga_target = nullptr;

  // per-frame state
  bool frame_active  = false;
  bool frame_escaped = false;
  int  target_buf    = 0;

  // env-gated diagnostics (SOLARUS_BLITTER_DIAG=1): per-window tallies.
  bool diag = false;
  long g_fills = 0, g_blits = 0, g_escapes = 0, g_offtarget_draw = 0;
  long g_frames_emit = 0, g_frames_escape = 0, g_uploads = 0;
  long g_esc_rot = 0, g_esc_scale = 0, g_esc_tint = 0, g_esc_alpha = 0,
       g_esc_mode = 0, g_esc_upload = 0, g_esc_overflow = 0, g_esc_toobig = 0;
  int  diag_n = 0;

  // cache: SurfaceImpl -> uploaded source handle (static atlases upload once)
  std::unordered_map<const SurfaceImpl*, blt_surface_ref_t> handles;
  // surfaces too large to ever fit the 96 KiB heap: remember so we escape them
  // cheaply (one verdict) instead of re-trying SDL convert + a poisoning
  // blt_upload overflow every single frame.
  std::unordered_set<const SurfaceImpl*> too_big;

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
  uint32_t ddr_r32(uint32_t off) {
    return *reinterpret_cast<volatile uint32_t*>(ddr + off);
  }

  bool map_video() {
    vid_fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (vid_fd < 0) return false;
    void* p = ::mmap(nullptr, 0x00100000u, PROT_READ | PROT_WRITE, MAP_SHARED,
                     vid_fd, VIDEO_CTRL_PHYS);
    if (p == MAP_FAILED) { ::close(vid_fd); vid_fd = -1; return false; }
    vid = static_cast<volatile uint8_t*>(p);
    return true;
  }

  // In-process verification: wait (bounded) for the fabric DONE==submit, then
  // read back the framebuffer the fabric composited and compare it pixel-wise to
  // the software-rendered frame. Logs running match% + nonzero-pixel count.
  void verify_committed(struct SDL_Window* /*window*/, int submitted_buf) {
    if (!verify || !vid || !sdl) return;
    // Wait for the fabric to finish this submission (DONE mirrors submit_seq).
    for (int i = 0; i < 100000; ++i) {
      if (ddr_r32(C_DONE) == em.submit_seq) break;
    }
    const uint32_t buf_off = submitted_buf ? 0x00040040u : 0x00000040u;
    const volatile uint16_t* fb =
        reinterpret_cast<volatile uint16_t*>(vid + buf_off);

    static std::vector<uint16_t> sw;
    if (sw.size() < (size_t)FB_W * FB_H) sw.resize((size_t)FB_W * FB_H);
    if (SDL_RenderReadPixels(sdl, nullptr, SDL_PIXELFORMAT_RGB565,
                             sw.data(), FB_W * 2) != 0)
      return;

    long match = 0, nz = 0;
    for (int i = 0; i < FB_W * FB_H; ++i) {
      uint16_t f = fb[i];
      if (f != 0) nz++;
      if (f == sw[(size_t)i]) match++;
    }
    g_verify_n++;
    double mpct = 100.0 * match / (FB_W * FB_H);
    g_verify_match += mpct;
    g_verify_nz += nz;
    if ((g_verify_n % 10) == 0) {
      std::fprintf(stderr,
        "[blitter verify] committed=%ld  this-frame match=%.1f%% nonzero=%ld  "
        "| 10-frame mean match=%.1f%% mean nonzero=%ld/%d\n",
        g_verify_n, mpct, nz, g_verify_match / 10.0, g_verify_nz / 10,
        FB_W * FB_H);
      g_verify_match = 0.0; g_verify_nz = 0;
    }
  }

  // Is `dst` the FPGA target render surface? A render texture (texture() != null,
  // i.e. not the window/screen surface) sized exactly 320x240. Lock onto the
  // first such surface so later transient targets don't steal acceleration.
  bool is_fpga_target(const SurfaceImpl& dst) {
    if (!ddr) return false;
    if (dst.get_width() != FB_W || dst.get_height() != FB_H) return false;
    const SDLSurfaceImpl* s = dynamic_cast<const SDLSurfaceImpl*>(&dst);
    if (!s || !s->get_texture()) return false;  // window/screen surface -> not us
    if (!fpga_target) fpga_target = &dst;        // first wins
    return &dst == fpga_target;
  }

  void escape() { frame_escaped = true; }

  void ensure_frame() {
    if (!frame_active) {
      blt_begin_frame(&em, target_buf, /*clear=*/1, /*clear_color=*/0x0000);
      frame_active = true;
      frame_escaped = false;
    }
  }

  // Upload (once) a SurfaceImpl's pixels as RGB565 into the heap; cache by ptr.
  // Returns invalid handle on heap overflow (caller escapes the frame).
  blt_surface_ref_t upload(const SurfaceImpl& src) {
    auto it = handles.find(&src);
    if (it != handles.end()) return it->second;
    if (too_big.count(&src)) return blt_surface_ref_t{};   // known-unfittable

    blt_surface_ref_t r{};
    SDL_Surface* s = src.get_surface();
    if (!s) return r;
    // A surface bigger than the whole heap can NEVER fit: remember + escape
    // without invoking blt_upload (which would set the per-frame overflow flag
    // and poison the small blits already emitted this frame).
    if ((size_t)s->w * (size_t)s->h * 2u > em.heap_cap) {
      too_big.insert(&src);
      return r;
    }
    if (diag) g_uploads++;
    SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
    if (!c) return r;
    r = blt_upload(&em, static_cast<const uint16_t*>(c->pixels),
                   c->w, c->h, c->pitch);
    SDL_FreeSurface(c);
    if (r.valid) handles[&src] = r;
    return r;
  }

  // Map Solarus blend/opacity/colorkey -> blitter blend. Returns false (caller
  // escapes) if the op can't be expressed by the v1 blitter. `why` (diag) names
  // the first unsupported feature.
  bool map_blend(const SurfaceImpl& src, const DrawInfos& infos,
                 uint8_t& blend, uint16_t& key, uint8_t& flags, int& why) {
    flags = 0; why = 0;
    if (std::fabs(infos.rotation) > 1e-3) { why = 1; return false; }     // rotation
    if (std::fabs(std::fabs(infos.scale.x) - 1.f) > 1e-3 ||
        std::fabs(std::fabs(infos.scale.y) - 1.f) > 1e-3) { why = 2; return false; } // zoom
    uint8_t cr, cg, cb, ca; infos.color.get_components(cr, cg, cb, ca);
    if (cr != 255 || cg != 255 || cb != 255) { why = 3; return false; }  // tint
    if (infos.scale.x < 0) flags |= BLT_F_HFLIP;
    if (infos.scale.y < 0) flags |= BLT_F_VFLIP;

    SDL_Surface* ss = src.get_surface();
    uint32_t k; key = 0;
    bool has_key = ss && SDL_GetColorKey(ss, &k) == 0;
    if (has_key) {
      uint8_t r, g, b; SDL_GetRGB(k, ss->format, &r, &g, &b);
      key = to_rgb565(r, g, b);
    }

    switch (infos.blend_mode) {
      case BlendMode::NONE:
        blend = has_key ? BLT_BLEND_COLORKEY : BLT_BLEND_COPY; break;
      case BlendMode::BLEND:
        if (infos.opacity < 255) { blend = BLT_BLEND_CONST_ALPHA;
                                   if (has_key) flags |= BLT_F_COLORKEY; }
        else if (has_key)        { blend = BLT_BLEND_COLORKEY; }
        else { why = 4; return false; }   // per-pixel alpha needs ARGB src (v2)
        break;
      case BlendMode::ADD:
      case BlendMode::MULTIPLY:
      default: why = 5; return false;                                    // not in v1
    }
    return true;
  }
};

// =====================================================================
MisterBlitterRenderer::MisterBlitterRenderer(SDL_Renderer* renderer, bool shaders)
    : SDLRenderer(renderer, shaders), d(new Impl()) {}

MisterBlitterRenderer::~MisterBlitterRenderer() {
  if (d->ddr) ::munmap((void*)d->ddr, BLT_DDR_SIZE);
  if (d->mem_fd >= 0) ::close(d->mem_fd);
  if (d->vid) ::munmap((void*)d->vid, 0x00100000u);
  if (d->vid_fd >= 0) ::close(d->vid_fd);
}

MisterBlitterRenderer* MisterBlitterRenderer::try_create(SDL_Renderer* renderer,
                                                         bool shaders) {
  if (std::getenv("SOLARUS_BLITTER") == nullptr) return nullptr;

  auto* self = new MisterBlitterRenderer(renderer, shaders);
  self->d->diag = (std::getenv("SOLARUS_BLITTER_DIAG") != nullptr);
  self->d->verify = (std::getenv("SOLARUS_BLITTER_VERIFY") != nullptr);
  self->d->sdl = self->renderer;       // base SDL renderer (befriended access)
  if (self->d->verify && !self->d->map_video()) {
    std::fprintf(stderr, "[MiSTer blitter] verify: video-region map failed\n");
    self->d->verify = false;
  }
  if (!self->d->map_ddr()) {
    std::fprintf(stderr, "[MiSTer blitter] /dev/mem map failed; reverting to SDL\n");
    // The base ctor already set the SDLRenderer singleton to `self`; we cannot
    // simply delete and re-create (the caller does that). Returning nullptr here
    // and deleting would leave a dangling singleton, so we instead keep `self`
    // but with ddr==null, which makes is_fpga_target() always false -> every
    // frame escapes to the base present path (functionally a plain SDLRenderer).
    std::fprintf(stderr, "[MiSTer blitter] running as pass-through SDLRenderer\n");
    return self;
  }
  std::fprintf(stderr, "[MiSTer blitter] renderer active (DDR @ 0x%08x)\n",
               BLT_DDR_PHYS);
  return self;
}

std::string MisterBlitterRenderer::get_name() const { return "mister_blitter"; }

void MisterBlitterRenderer::invalidate(const SurfaceImpl& surf) {
  d->handles.erase(&surf);             // drop a cached upload if freed/changed
  d->too_big.erase(&surf);
  if (&surf == d->fpga_target) d->fpga_target = nullptr;
  SDLRenderer::invalidate(surf);
}

// ---- intercepted ops: ALWAYS render via base, AND emit blitter commands ----
void MisterBlitterRenderer::clear(SurfaceImpl& dst) {
  SDLRenderer::clear(dst);             // keep the software frame correct
  if (d->is_fpga_target(dst)) {
    d->frame_active = false;           // a clear starts a fresh blitter frame
    d->ensure_frame();                 // begin frame with hardware clear
  }
}

void MisterBlitterRenderer::fill(SurfaceImpl& dst, const Color& color,
                                 const Rectangle& where, BlendMode mode) {
  SDLRenderer::fill(dst, color, where, mode);   // keep the software frame correct
  if (d->is_fpga_target(dst)) {
    if (mode == BlendMode::ADD || mode == BlendMode::MULTIPLY) {
      d->escape(); if (d->diag) { d->g_escapes++; d->g_esc_mode++; }
      return;
    }
    d->ensure_frame();
    uint8_t r, g, b, a; color.get_components(r, g, b, a);
    blt_fill(&d->em, where.get_x(), where.get_y(),
             where.get_width(), where.get_height(), to_rgb565(r, g, b));
    if (d->diag) d->g_fills++;
  }
}

void MisterBlitterRenderer::draw(SurfaceImpl& dst, const SurfaceImpl& src,
                                 const DrawInfos& infos) {
  SDLRenderer::draw(dst, src, infos);  // keep the software frame correct

  if (!d->is_fpga_target(dst)) {
    if (d->diag && d->ddr) d->g_offtarget_draw++;
    return;
  }

  uint8_t blend, flags; uint16_t key; int why = 0;
  blt_surface_ref_t h = d->upload(src);
  if (!h.valid) {
    d->escape();
    if (d->diag) {
      d->g_escapes++;
      if (d->too_big.count(&src)) d->g_esc_toobig++;
      else { d->g_esc_upload++; if (d->em.overflow) d->g_esc_overflow++; }
    }
    return;
  }
  if (!d->map_blend(src, infos, blend, key, flags, why)) {
    d->escape();
    if (d->diag) {
      d->g_escapes++;
      switch (why) { case 1: d->g_esc_rot++; break; case 2: d->g_esc_scale++; break;
        case 3: d->g_esc_tint++; break; case 4: d->g_esc_alpha++; break;
        default: d->g_esc_mode++; }
    }
    return;
  }
  d->ensure_frame();
  const Rectangle& r = infos.region;
  Rectangle dr = infos.dst_rectangle();
  blt_blit(&d->em, h, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
           dr.get_x(), dr.get_y(), blend, key, infos.opacity, flags);
  if (d->diag) d->g_blits++;
}

void MisterBlitterRenderer::present(SDL_Window* window) {
  bool committed = (d->frame_active && !d->frame_escaped && !d->em.overflow);

  if (d->diag) {
    if (committed) d->g_frames_emit++; else d->g_frames_escape++;
    if (++d->diag_n >= 60) {
      std::fprintf(stderr,
        "[blitter diag] /60fr: emit=%ld escape=%ld | fills=%ld blits=%ld "
        "uploads=%ld offtarget=%ld | esc: rot=%ld scale=%ld tint=%ld alpha=%ld "
        "mode=%ld upload=%ld ovf=%ld toobig=%ld | cmdcnt=%d heap=%zu/%zu "
        "overflow=%d target_locked=%d\n",
        d->g_frames_emit, d->g_frames_escape, d->g_fills, d->g_blits,
        d->g_uploads, d->g_offtarget_draw,
        d->g_esc_rot, d->g_esc_scale, d->g_esc_tint, d->g_esc_alpha,
        d->g_esc_mode, d->g_esc_upload, d->g_esc_overflow, d->g_esc_toobig,
        d->em.cmd_count, d->em.heap_used, d->em.heap_cap, d->em.overflow,
        d->fpga_target ? 1 : 0);
      d->g_frames_emit = d->g_frames_escape = 0;
      d->g_fills = d->g_blits = d->g_escapes = d->g_offtarget_draw = 0;
      d->g_uploads = 0;
      d->g_esc_rot = d->g_esc_scale = d->g_esc_tint = d->g_esc_alpha = 0;
      d->g_esc_mode = d->g_esc_upload = d->g_esc_overflow = d->g_esc_toobig = 0;
      d->diag_n = 0;
    }
  }

  if (committed) {
    // The fabric composites the DDR framebuffer directly. Submit the ring and
    // ring the doorbell; the fabric bumps the shared video control word itself.
    int submitted_buf = d->em.target_buf;
    blt_end_frame(&d->em);
    d->ddr_w32(C_CMDCOUNT, (uint32_t)d->em.cmd_count);
    d->ddr_w32(C_TARGET,   (uint32_t)d->em.target_buf);
    d->ddr_w32(C_CLEAR,    d->em.clear_color);
    d->ddr_w32(C_FLAGS,    d->em.flags);
    __sync_synchronize();                 // commit ring+ctrl before the doorbell
    d->ddr_w32(C_SUBMIT,   d->em.submit_seq);
    d->target_buf ^= 1;                   // next frame composites the other buffer
    d->verify_committed(window, submitted_buf);
  } else {
    // Fall back to the proven base present (software readback -> DDR write).
    SDLRenderer::present(window);
  }
  d->frame_active = false;
  d->frame_escaped = false;
}

}  // namespace Solarus

#else  // !MISTER_NATIVE_VIDEO — stub so non-MiSTer builds fall through to SDL

namespace Solarus {
MisterBlitterRenderer* MisterBlitterRenderer::try_create(struct SDL_Renderer*, bool) {
  return nullptr;
}
}

#endif
