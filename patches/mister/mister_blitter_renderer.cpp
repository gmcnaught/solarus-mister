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
#include <functional>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace Solarus {

// ---- DDR layout for the blitter region.
// MUST MATCH the fabric's fpga/rtl/blitter_defs.vh. The fabric reads control/ring/
// source from 0x3A070000 — the FREE GAP between BUF1 (~0x3A066000) and the audio
// ring (0x3A0D0000), inside the already-proven 1 MiB f2h region at 0x3A000000
// (native_video_writer). The gap was HW-verified untouched by the running engine.
//   BLTCTRL 0x3A070000 | RING 0x3A070040 | SRC heap 0x3A078000 | end 0x3A0D0000
// The SRC heap is now 352 KiB (BLT_DDR_SIZE-OFF_HEAP) — enough for TWO full
// 320x240 RGB565 sources (150 KiB each), so full-frame intermediates no longer
// ESCAPE on size. (Was 96 KiB @ 0x3A0E8000 -> toobig=60/frame.)
namespace {
constexpr uint32_t BLT_DDR_PHYS = 0x3A070000u;
constexpr size_t   BLT_DDR_SIZE = 0x00060000u;   // 384 KiB: ctrl + ring + 352 KiB heap
constexpr uint32_t OFF_RING      = 0x00000040u;
constexpr uint32_t RING_CAP      = 0x00007FC0u;  // ring spans 0x40..0x8000 (~32 KiB)
constexpr uint32_t OFF_HEAP      = 0x00008000u;  // heap @ 0x3A078000 (352 KiB to end)
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

  // --- render-target aliasing (the offtarget=454 fix) -----------------------
  // Solarus does NOT composite sprites/tiles straight onto the root (fpga_target)
  // surface. Map::draw() composites the whole visible frame onto the CAMERA
  // surface (a separate full-quest-size texture), then Game::draw() blits that
  // camera surface 1:1 onto the root. So the ~454 per-frame sprite/tile draws
  // land on the camera surface and are "offtarget" w.r.t. the root.
  //
  // We detect the camera surface as the source of the camera->root promote-blit
  // (a full-frame, unrotated, unscaled, opaque 1:1 copy onto fpga_target) and
  // remember it as an ALIAS of the DDR framebuffer at the camera's screen
  // offset. From the next frame on, draws onto the camera surface emit blitter
  // commands into the SAME DDR framebuffer (dst += alias offset), and the
  // promote-blit itself is skipped (its content is already composited in DDR).
  // Root-level HUD/menu draws then composite on top. Net effect: the bulk of the
  // frame composites on the fabric instead of escaping. (Detection persists
  // across frames — "first wins" like fpga_target — so the within-frame ordering
  // problem, camera draws BEFORE the promote-blit, resolves on the next frame.)
  const SurfaceImpl* alias_target = nullptr;
  int alias_off_x = 0, alias_off_y = 0;

  // per-frame state
  bool frame_active  = false;
  bool frame_escaped = false;
  int  target_buf    = 0;
  // STEP 1: 1-frame-latency double-render gate. When the PREVIOUS frame
  // committed cleanly on the fabric, we trust this frame will too and SKIP the
  // base SDLRenderer software composite on blitter-backed ops (the offload).
  // When the previous frame escaped (an unsupported op forced the readback
  // fallback), we run the base SDL composite for ALL ops THIS frame so present()
  // has a correct software_screen if it escapes again. Escapes in steady
  // gameplay (rotation/zoom/ADD) are occasional, so we pay the double-render
  // only on/around those frames. Starts true (no escapes yet) but the very
  // first frames may double-render harmlessly until the steady state settles.
  bool double_render = true;   // this-frame: also composite via base SDL
  bool prev_committed = false; // previous frame presented from the fabric
  bool heap_reset_pending = false;   // a frame overflowed -> reclaim heap next frame
  bool did_reset_last     = false;   // we reclaimed the heap at the start of this frame
  bool scene_too_big      = false;   // a reset did NOT clear overflow -> one frame's
                                     // working set genuinely exceeds the heap; stop
                                     // resetting (avoid per-frame re-upload thrash)
                                     // until the scene changes (see invalidate()).

  // env-gated diagnostics (SOLARUS_BLITTER_DIAG=1): per-window tallies.
  bool diag = false;
  long g_fills = 0, g_blits = 0, g_alias_blits = 0, g_escapes = 0, g_offtarget_draw = 0;
  long g_frames_emit = 0, g_frames_escape = 0, g_uploads = 0;
  long g_esc_rot = 0, g_esc_scale = 0, g_esc_tint = 0, g_esc_alpha = 0,
       g_esc_mode = 0, g_esc_upload = 0, g_esc_overflow = 0, g_esc_toobig = 0;
  int  diag_n = 0;
  int  g_upload_log = 0;   // one-shot upload-size trace (first 40 uploads)

  // cache key: a surface may be uploaded in two formats (RGB565 for opaque /
  // colorkey / const-alpha, ARGB4444 for per-pixel alpha) — cache per (ptr,fmt).
  struct SurfKey {
    const SurfaceImpl* p; uint8_t fmt;
    bool operator==(const SurfKey& o) const { return p == o.p && fmt == o.fmt; }
  };
  struct SurfKeyHash {
    size_t operator()(const SurfKey& k) const {
      return std::hash<const void*>()(k.p) ^ (size_t)k.fmt * 0x9E3779B97F4A7C15ull;
    }
  };
  // cache: (SurfaceImpl,fmt) -> uploaded source handle (static atlases upload once)
  std::unordered_map<SurfKey, blt_surface_ref_t, SurfKeyHash> handles;
  // surfaces too large to ever fit the heap: remember so we escape them
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

  // STEP 2: when a scene's source working set genuinely exceeds the heap
  // (scene_too_big — confirmed by a reset that did NOT clear overflow), the
  // blitter can never composite this scene. Trying anyway costs a futile
  // SDL_ConvertSurfaceFormat + heap memcpy of every atlas EVERY frame (the
  // 535x298 hero sheet alone is 311 KiB), which dropped overflow-gameplay to
  // ~4 fps — WORSE than the ~19 fps pure-SDL baseline. While scene_too_big we
  // therefore disable the blitter entirely and run as a plain SDLRenderer: the
  // backed-surface ops fall through to base SDL and present() uses the readback
  // fallback. invalidate() clears scene_too_big on a scene change so the next
  // (fitting) scene re-enables the offload. Net: blitter >= baseline always.
  bool blitter_off() const { return !ddr || scene_too_big; }

  void ensure_frame() {
    if (!frame_active) {
      // Heap churn / scene-transition fix. Source uploads are bump-allocated and
      // LEAK across scene changes: invalidate() drops only the cache entry, not
      // the heap bytes, so a transition's fresh atlases overflow the heap while
      // the old scene's stale atlases still occupy it. When a frame overflowed we
      // RECLAIM the whole heap at the next frame boundary (reset + drop the cache)
      // so this frame re-uploads ONLY its own working set into an empty heap —
      // the stale scene is gone, so the new scene fits and escape resumes at 0.
      // Steady state keeps the upload-once cache (no per-frame re-upload cost);
      // only a transition pays a one-frame full re-upload.
      if (heap_reset_pending) {
        blt_heap_reset(&em);
        handles.clear();
        heap_reset_pending = false;
        did_reset_last = true;  // so present() can tell if the reset cleared overflow
      }
      em.overflow = 0;          // clear any stale poison from the previous frame
      blt_begin_frame(&em, target_buf, /*clear=*/1, /*clear_color=*/0x0000);
      frame_active = true;
      frame_escaped = false;
    }
  }

  // Convert an SDL surface (any format) to packed ARGB4444 {A4,R4,G4,B4} into
  // `out` (w*h uint16). Done by hand because SDL2 lacks an ARGB4444 pixel format
  // that matches our {A4,R4,G4,B4} bit order on all builds — we read each pixel's
  // RGBA8888 components and pack the high nibbles. Returns false on failure.
  static bool to_argb4444(SDL_Surface* s, std::vector<uint16_t>& out) {
    SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_ARGB8888, 0);
    if (!c) return false;
    out.resize((size_t)c->w * c->h);
    SDL_LockSurface(c);
    const uint8_t* base = static_cast<const uint8_t*>(c->pixels);
    for (int y = 0; y < c->h; ++y) {
      const uint32_t* row =
          reinterpret_cast<const uint32_t*>(base + (size_t)y * c->pitch);
      for (int x = 0; x < c->w; ++x) {
        uint32_t px = row[x];
        uint8_t a, r, g, b;
        SDL_GetRGBA(px, c->format, &r, &g, &b, &a);
        out[(size_t)y * c->w + x] = (uint16_t)(
            ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
      }
    }
    SDL_UnlockSurface(c);
    SDL_FreeSurface(c);
    return true;
  }

  // Upload (once) a SurfaceImpl's pixels into the heap; cache by ptr. `fmt` picks
  // the heap format: BLT_FMT_RGB565 (opaque/colorkey/const-alpha) or
  // BLT_FMT_ARGB4444 (per-pixel alpha). Surfaces are cached per (ptr,fmt) so a
  // surface drawn both opaquely and alpha-blended gets one upload of each form.
  // Returns invalid handle on heap overflow (caller escapes the frame).
  blt_surface_ref_t upload(const SurfaceImpl& src, uint8_t fmt) {
    SurfKey kkey{&src, fmt};
    auto it = handles.find(kkey);
    if (it != handles.end()) return it->second;
    if (too_big.count(&src)) return blt_surface_ref_t{};   // known-unfittable

    blt_surface_ref_t r{};
    SDL_Surface* s = src.get_surface();
    if (!s) return r;
    // A surface bigger than the whole heap can NEVER fit: remember + escape
    // without invoking blt_upload (which would set the per-frame overflow flag
    // and poison the small blits already emitted this frame). Both formats are
    // 16bpp so the size test is format-independent.
    if ((size_t)s->w * (size_t)s->h * 2u > em.heap_cap) {
      too_big.insert(&src);
      return r;
    }
    if (diag) {
      g_uploads++;
      if (g_upload_log < 40) {
        std::fprintf(stderr, "[blitter upload] %dx%d fmt=%u bytes=%zu heap_used=%zu/%zu\n",
                     s->w, s->h, fmt, (size_t)s->w * s->h * 2u, em.heap_used, em.heap_cap);
        g_upload_log++;
      }
    }
    if (fmt == BLT_FMT_ARGB4444) {
      std::vector<uint16_t> px;
      if (!to_argb4444(s, px)) return r;
      r = blt_upload_argb4444(&em, px.data(), s->w, s->h, s->w * 2);
    } else {
      SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
      if (!c) return r;
      r = blt_upload(&em, static_cast<const uint16_t*>(c->pixels),
                     c->w, c->h, c->pitch);
      SDL_FreeSurface(c);
    }
    if (r.valid) handles[kkey] = r;
    return r;
  }

  // Map Solarus blend/opacity/colorkey -> blitter blend. Returns false (caller
  // escapes) if the op can't be expressed by the v1 blitter. `why` (diag) names
  // the first unsupported feature.
  // `want_fmt` (out): the source heap format the chosen blend needs —
  // BLT_FMT_RGB565 for opaque/colorkey/const-alpha, BLT_FMT_ARGB4444 for the
  // per-pixel-alpha (BLEND_PALPHA) path.
  bool map_blend(const SurfaceImpl& src, const DrawInfos& infos,
                 uint8_t& blend, uint16_t& key, uint8_t& flags, uint8_t& want_fmt,
                 int& why) {
    flags = 0; why = 0; want_fmt = BLT_FMT_RGB565;
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
    // Does the source carry a real per-pixel alpha channel? (Solarus sprite PNGs
    // do: BLEND + full opacity + an alpha channel.)
    bool has_alpha = ss && ss->format && SDL_ISPIXELFORMAT_ALPHA(ss->format->format);

    switch (infos.blend_mode) {
      case BlendMode::NONE:
        blend = has_key ? BLT_BLEND_COLORKEY : BLT_BLEND_COPY; break;
      case BlendMode::BLEND:
        if (infos.opacity < 255) { blend = BLT_BLEND_CONST_ALPHA;
                                   if (has_key) flags |= BLT_F_COLORKEY; }
        else if (has_alpha)      { blend = BLT_BLEND_PALPHA;   // v2 per-pixel alpha
                                   want_fmt = BLT_FMT_ARGB4444; }
        else if (has_key)        { blend = BLT_BLEND_COLORKEY; }
        else                     { blend = BLT_BLEND_COPY; }   // opaque, no alpha
        break;
      case BlendMode::ADD:
      case BlendMode::MULTIPLY:
      default: why = 5; return false;                                    // not in v1
    }
    return true;
  }

  // Express one draw (src -> dst at dst+offset) as a blitter command. Returns
  // true if emitted, false if the op had to ESCAPE (caller has already set
  // frame_escaped via escape() and tallied the reason). `off_x/off_y` shift the
  // destination so an alias surface (the camera) composites at its screen offset
  // in the DDR framebuffer. Shared by the fpga_target and alias_target paths.
  bool emit_draw(const SurfaceImpl& src, const DrawInfos& infos,
                 int off_x, int off_y) {
    uint8_t blend, flags, want_fmt; uint16_t key; int why = 0;
    if (!map_blend(src, infos, blend, key, flags, want_fmt, why)) {
      escape();
      if (diag) {
        g_escapes++;
        switch (why) { case 1: g_esc_rot++; break; case 2: g_esc_scale++; break;
          case 3: g_esc_tint++; break; case 4: g_esc_alpha++; break;
          default: g_esc_mode++; }
      }
      return false;
    }
    blt_surface_ref_t h = upload(src, want_fmt);
    if (!h.valid) {
      escape();
      if (diag) {
        g_escapes++;
        if (too_big.count(&src)) g_esc_toobig++;
        else { g_esc_upload++; if (em.overflow) g_esc_overflow++; }
      }
      return false;
    }
    ensure_frame();
    const Rectangle& r = infos.region;
    Rectangle dr = infos.dst_rectangle();
    blt_blit(&em, h, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
             dr.get_x() + off_x, dr.get_y() + off_y, blend, key,
             infos.opacity, flags);
    return true;
  }

  // Detect the camera->root promote-blit: a full-quest-size, texture-backed
  // source drawn 1:1 (no rotation/scale/flip, fully opaque, plain copy) onto the
  // fpga_target. Its source is the camera surface, which we then alias. We DON'T
  // require src dims == FB exactly (a quest could use a slightly larger camera)
  // — full-cover at the dst rect is the real signal — but for the 320x240 quests
  // we care about it is exactly FB-sized. Conservative to avoid false positives.
  bool looks_like_promote(const SurfaceImpl& src, const DrawInfos& infos) {
    const SDLSurfaceImpl* s = dynamic_cast<const SDLSurfaceImpl*>(&src);
    if (!s || !s->get_texture()) return false;        // must be a render texture
    if (src.get_width() != FB_W || src.get_height() != FB_H) return false;
    if (std::fabs(infos.rotation) > 1e-3) return false;
    if (std::fabs(infos.scale.x - 1.f) > 1e-3 ||
        std::fabs(infos.scale.y - 1.f) > 1e-3) return false;   // also rejects flips
    if (infos.opacity != 255) return false;
    // covers the whole source region (the full camera frame), not a sub-rect.
    if (infos.region.get_width() != FB_W || infos.region.get_height() != FB_H)
      return false;
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
  d->handles.erase(Impl::SurfKey{&surf, BLT_FMT_RGB565});   // drop both cached
  d->handles.erase(Impl::SurfKey{&surf, BLT_FMT_ARGB4444});  // upload variants
  d->too_big.erase(&surf);
  d->scene_too_big = false;   // a surface was freed -> scene changing -> re-allow
                              // a churn reset (the working set may now fit again)
  if (&surf == d->fpga_target) d->fpga_target = nullptr;
  if (&surf == d->alias_target) d->alias_target = nullptr;  // camera surface freed
  SDLRenderer::invalidate(surf);
}

// ---- intercepted ops -------------------------------------------------------
// STEP 1 (perf-offload): kill the double-render. For an op that targets a
// blitter-BACKED surface (the root fpga_target or the aliased camera surface,
// whose content lives in the DDR framebuffer) we emit the blitter command and,
// only when `double_render` is set, ALSO run the base SDLRenderer software
// composite. `double_render` mirrors the PREVIOUS frame's escape state (see the
// Impl::double_render comment): in steady committed gameplay it is false, so the
// bulk sprite/tile/fill draws cost ONE blitter emit and NO A9 composite — the
// offload. It flips true for the frame after an escape so present()'s readback
// fallback sees a correct software_screen.
//
// Ops on SDL-backed surfaces (sprite/tile atlases, off-screen HUD intermediates)
// ALWAYS run on the base SDL renderer — they hold real pixel content that the
// blitter later reads as an uploaded source, or that gets read back.
void MisterBlitterRenderer::clear(SurfaceImpl& dst) {
  if (!d->blitter_off() && d->is_fpga_target(dst)) {
    d->frame_active = false;           // a clear starts a fresh blitter frame
    d->ensure_frame();                 // begin frame with hardware clear
    if (d->double_render) SDLRenderer::clear(dst);
    return;
  }
  SDLRenderer::clear(dst);             // SDL-backed surface (or blitter off)
}

void MisterBlitterRenderer::fill(SurfaceImpl& dst, const Color& color,
                                 const Rectangle& where, BlendMode mode) {
  // Fills target the root (offset 0) OR the aliased camera surface (offset to
  // its screen position) — both composite into the same DDR framebuffer.
  bool root  = !d->blitter_off() && d->is_fpga_target(dst);
  bool alias = !d->blitter_off() && !root && d->alias_target == &dst &&
               dst.get_width() == FB_W;
  if (root || alias) {
    if (mode == BlendMode::ADD || mode == BlendMode::MULTIPLY) {
      d->escape(); if (d->diag) { d->g_escapes++; d->g_esc_mode++; }
      SDLRenderer::fill(dst, color, where, mode);   // escaped -> need software
      return;
    }
    d->ensure_frame();
    int ox = alias ? d->alias_off_x : 0, oy = alias ? d->alias_off_y : 0;
    uint8_t r, g, b, a; color.get_components(r, g, b, a);
    blt_fill(&d->em, where.get_x() + ox, where.get_y() + oy,
             where.get_width(), where.get_height(), to_rgb565(r, g, b));
    if (d->diag) d->g_fills++;
    if (d->double_render) SDLRenderer::fill(dst, color, where, mode);
    return;
  }
  SDLRenderer::fill(dst, color, where, mode);   // SDL-backed surface
}

void MisterBlitterRenderer::draw(SurfaceImpl& dst, const SurfaceImpl& src,
                                 const DrawInfos& infos) {
  if (d->blitter_off()) {               // pass-through SDLRenderer (or scene too big)
    SDLRenderer::draw(dst, src, infos);
    if (d->diag) d->g_offtarget_draw++;
    return;
  }

  // (1) Draw onto the locked root target (fpga_target).
  if (d->is_fpga_target(dst)) {
    // Is this the camera->root promote-blit? If so, register the camera surface
    // (src) as an alias of the DDR framebuffer and SKIP its blit: the camera's
    // content is already composited in DDR by the aliased per-sprite draws (from
    // the next frame on). On the FIRST frame the alias isn't known yet, so we let
    // the promote-blit through as one full-frame blit — the frame is still
    // correct, just not yet decomposed onto the fabric.
    if (&src == d->alias_target) {
      // camera content already in DDR. For the software_screen we still need the
      // promote-blit when double-rendering (it composites the camera onto root).
      if (d->double_render) SDLRenderer::draw(dst, src, infos);
      return;
    }
    if (!d->alias_target && d->looks_like_promote(src, infos)) {
      d->alias_target = &src;
      Rectangle dr = infos.dst_rectangle();
      d->alias_off_x = dr.get_x();
      d->alias_off_y = dr.get_y();
      if (d->diag)
        std::fprintf(stderr,
          "[blitter alias] camera surface aliased -> DDR fb at offset (%d,%d)\n",
          d->alias_off_x, d->alias_off_y);
      // This first-time promote still composites correctly as a full-frame blit.
    }
    bool emitted = d->emit_draw(src, infos, 0, 0);
    if (emitted && d->diag) d->g_blits++;
    // Run base SDL when double-rendering OR when this op escaped (so the
    // software frame is correct for the fallback present).
    if (d->double_render || !emitted) SDLRenderer::draw(dst, src, infos);
    return;
  }

  // (2) Draw onto the aliased camera surface -> composite into the same DDR
  //     framebuffer at the camera's screen offset. This is where the bulk of the
  //     per-frame sprite/tile draws (formerly offtarget) now land on-fabric.
  if (dst.get_width() == FB_W && d->alias_target == &dst) {
    bool emitted = d->emit_draw(src, infos, d->alias_off_x, d->alias_off_y);
    if (emitted && d->diag) d->g_alias_blits++;
    if (d->double_render || !emitted) SDLRenderer::draw(dst, src, infos);
    return;
  }

  // (3) SDL-backed surface (sprite/tile intermediate, HUD off-screen, etc.).
  //     Render normally on the A9; the result may later be uploaded as a
  //     blitter source or read back.
  SDLRenderer::draw(dst, src, infos);
  if (d->diag) d->g_offtarget_draw++;
}

void MisterBlitterRenderer::present(SDL_Window* window) {
  bool committed = (d->frame_active && !d->frame_escaped && !d->em.overflow);

  // Heap-churn handling. An overflow means stale (old-scene) atlases are crowding
  // out the new scene -> reclaim the heap next frame so it re-uploads fresh (see
  // ensure_frame). BUT if we already reset at the start of THIS frame and it STILL
  // overflowed, the scene's working set genuinely exceeds the heap; resetting again
  // can't help and would thrash (full re-upload every frame), so suppress further
  // resets until the scene changes (invalidate() clears scene_too_big). A frame
  // that fits clears it too. The screen is always correct via the SDL fallback.
  if (d->em.overflow) {
    if (d->did_reset_last)        d->scene_too_big = true;   // reset didn't help
    else if (!d->scene_too_big)   d->heap_reset_pending = true;
  } else if (d->frame_active) {
    // A frame that actually USED the blitter fit -> churn recovery can resume.
    // (Only clear when the blitter ran: a scene_too_big frame routes everything
    // to base SDL and never sets overflow, so it must NOT clear scene_too_big
    // here or we'd oscillate between blitter-off and overflowing every frame.)
    d->scene_too_big = false;
  }
  d->did_reset_last = false;

  if (d->diag) {
    if (committed) d->g_frames_emit++; else d->g_frames_escape++;
    if (++d->diag_n >= 60) {
      std::fprintf(stderr,
        "[blitter diag] /60fr: emit=%ld escape=%ld | fills=%ld blits=%ld "
        "alias_blits=%ld uploads=%ld offtarget=%ld | esc: rot=%ld scale=%ld "
        "tint=%ld alpha=%ld mode=%ld upload=%ld ovf=%ld toobig=%ld | cmdcnt=%d "
        "heap=%zu/%zu overflow=%d target_locked=%d alias_locked=%d\n",
        d->g_frames_emit, d->g_frames_escape, d->g_fills, d->g_blits,
        d->g_alias_blits, d->g_uploads, d->g_offtarget_draw,
        d->g_esc_rot, d->g_esc_scale, d->g_esc_tint, d->g_esc_alpha,
        d->g_esc_mode, d->g_esc_upload, d->g_esc_overflow, d->g_esc_toobig,
        d->em.cmd_count, d->em.heap_used, d->em.heap_cap, d->em.overflow,
        d->fpga_target ? 1 : 0, d->alias_target ? 1 : 0);
      d->g_frames_emit = d->g_frames_escape = 0;
      d->g_fills = d->g_blits = d->g_alias_blits = 0;
      d->g_escapes = d->g_offtarget_draw = 0;
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
  } else if (d->double_render) {
    // We escaped AND we ran the base SDL composite this frame, so software_screen
    // is correct: fall back to the proven base present (readback -> DDR write).
    SDLRenderer::present(window);
  } else {
    // We escaped but did NOT double-render, so software_screen is incomplete.
    // Re-presenting it would show garbage. Instead drop this frame: the fabric
    // keeps displaying the last committed buffer (one stale frame, never wrong).
    // The next frame double-renders (double_render is set below), so it recovers.
  }

  // 1-frame-latency gate for STEP 1: if THIS frame escaped, the NEXT frame must
  // double-render so the readback fallback has a correct software_screen. If
  // this frame committed cleanly we trust the next to as well and skip the base
  // composite on backed ops (the offload). Steady committed gameplay therefore
  // runs single-render; only frames on/after an escape pay the A9 composite.
  // When the blitter is off (scene_too_big) every backed op already ran on base
  // SDL, so software_screen is complete and the SDL fallback present is always
  // correct — keep double_render true so the drop-frame branch never triggers.
  d->double_render = !committed;

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
