# Static (non-animated) Tile-List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render non-animated map tiles via a direct fabric `BLT_OP_TILELIST` read from the resident perm atlas, retiring `NonAnimatedRegions` cell-intermediate SDRAM staging (the source of the overworld title-fragment garbage).

**Architecture:** A "static tile-list" parallels the existing animated `BLT_OP_TILELIST_RES` path, reusing its build/fast-frame, camera-bias, bucketing and alias machinery — but with the 12-byte direct-source `blt_tile_entry_t` (own src rect; no `BLT_MAXP=128` pattern limit, no FRT/CFT). Whole-map, camera-independent: entries store map-coord dsts; the fabric adds a per-frame header bias. When active, the engine stops calling `NonAnimatedRegions::draw_on_map()`, so cells are never built or staged.

**Tech Stack:** SystemVerilog (fabric, icarus/`run_sims.sh`), C (emitter + C reference model, host selftest), C++ (armhf renderer via `solarus-armhf-build:bullseye` Docker), Python-in-`build_engine.sh` (upstream engine patches), MiSTer HW (SSH `root@192.168.20.81`).

## Global Constraints

- Renderer/engine C++ compiles **only** inside Docker: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh` (host `clang -fsyntax-only` is NOT a valid gate). Success line: `[100%] Built target solarus-run`.
- Deploy: daemon respawns `solarus-run` on death → stop watchers first; FAT cannot overwrite an open exe → `rm` then `mv`; verify md5. Full recipe in Task 5.
- Bit-exactness: any fabric change MUST be matched in the C golden (`blitter_ref.c`) and proven by a gating sim TB before HW.
- Keep the uncommitted inter-region relocation (`SDRAM_INTER_BASE = 0x05000000`) — do not revert.
- No silent fallbacks: an unbatchable static bucket is a loud `res_fatal` (mirror the animated path).
- New behavior is gated behind `SOLARUS_TILESTATIC` (default ON) for A/B.

---

### Task 1: Fabric — apply header bias to the direct `BLT_OP_TILELIST`

Make the 12-byte direct tile-list camera-independent (map-coord entries + per-frame header bias), matching what `TILELIST_RES` already does. Reference model first (host, fast), then RTL, proven bit-exact by a gating sim.

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.c` (direct `OP_TILELIST` loop, ~260-273)
- Modify: `fpga/rtl/blitter_top.sv` (`OP_TILELIST` decode ~528-540; `S_TL_LATCH` ~658-667)
- Modify/Test: `fpga/sim/tb_tilelist.sv` (add a biased-entry case)
- Runner: `fpga/sim/run_sims.sh`

**Interfaces:**
- Produces: direct `BLT_OP_TILELIST` now reads `bias_x=(int16)c.src_x`, `bias_y=(int16)c.src_y` from the header and adds them to every entry's dst — identical convention to `BLT_OP_TILELIST_RES`. Entry layout unchanged (`blt_tile_entry_t{u16 src_x,src_y,w,h; i16 dst_x,dst_y}`).

- [ ] **Step 1: Extend the C reference to apply bias on direct TILELIST**

In `patches/mister/blitter/blitter_ref.c`, replace the `BLT_OP_TILELIST` block (currently ~260-273):

```c
        if (c->opcode == BLT_OP_TILELIST) {
            uint32_t n = (uint32_t)c->w | ((uint32_t)c->h << 16);
            uint32_t eoff = (uint32_t)(uint16_t)c->dst_x | ((uint32_t)(uint16_t)c->dst_y << 16);
            /* [static tile-list] header src_x/src_y carry a signed per-batch dst bias
             * (map-coord -> screen), added to every entry's dst — same convention as
             * BLT_OP_TILELIST_RES. */
            int16_t bias_x = (int16_t)c->src_x;
            int16_t bias_y = (int16_t)c->src_y;
            for (uint32_t k=0; k<n; k++) {
                blt_tile_entry_t e;
                memcpy(&e, heap->base + eoff + (size_t)k*sizeof(blt_tile_entry_t), sizeof e);
                blt_cmd_t b = *c;                 /* inherit shared params */
                b.opcode = BLT_OP_BLIT;
                b.src_x=e.src_x; b.src_y=e.src_y; b.w=e.w; b.h=e.h;
                b.dst_x=(int16_t)(e.dst_x + bias_x); b.dst_y=(int16_t)(e.dst_y + bias_y);
                blit_one(fb, heap, &b);
            }
            continue;
        }
```

- [ ] **Step 2: Latch bias at `OP_TILELIST` decode (RTL)**

In `fpga/rtl/blitter_top.sv`, in the `else if (c_opcode==OP_TILELIST)` decode block (~528-540), add the two bias latches (the header's `src_x/src_y` slots are otherwise unused for this op) alongside the existing `tl_res <= 1'b0;`:

```systemverilog
                else if (c_opcode==OP_TILELIST) begin
                    tl_count     <= {c_h, c_w};
                    tl_entry_ptr <= {c_dst_y, c_dst_x};
                    tl_idx       <= 32'd0;
                    tl_byte      <= 32'd0;
                    tl_res       <= 1'b0;
                    // [static tile-list] latch the header per-batch dst bias (src_x/src_y
                    // slots) so S_TL_LATCH can bias each 12-byte entry's map-coord dst.
                    res_bias_x   <= $signed(c_src_x);
                    res_bias_y   <= $signed(c_src_y);
                    state        <= ({c_h, c_w} == 32'd0) ? S_NEXT_CMD : S_TL_FETCH0;
                end
```

- [ ] **Step 3: Add bias at `S_TL_LATCH` (RTL)**

`S_TL_LATCH` (~658-667) is reached only by the direct (non-res) path. Add the bias to the dst assignments:

```systemverilog
            S_TL_LATCH: begin
                c_src_x <= tl_window[15:0];
                c_src_y <= tl_window[31:16];
                c_w     <= tl_window[47:32];
                c_h     <= tl_window[63:48];
                // [static tile-list] map-coord dst + per-batch header bias -> screen dst.
                c_dst_x <= $signed(tl_window[79:64]) + res_bias_x;
                c_dst_y <= $signed(tl_window[95:80]) + res_bias_y;
                state   <= S_TL_ISSUE;
            end
```

- [ ] **Step 4: Add a biased-entry case to `tb_tilelist.sv`**

Open `fpga/sim/tb_tilelist.sv` and read its existing structure (how it loads a command + entries into the ring/TL buffer, runs the DUT, and compares the framebuffer against `blitter_ref`). Add a new sub-test that emits an `OP_TILELIST` header with a non-zero `src_x/src_y` bias (e.g. `bias=(-4,+3)`) and ≥2 entries at known map-coord dsts, then asserts the DUT framebuffer equals the `blitter_ref` output (which now applies the same bias from Step 1). Follow the exact assertion/reporting idiom already in the file so a mismatch prints and sets the fail flag.

- [ ] **Step 5: Run the tile-list sims — expect PASS (bit-exact)**

Run: `cd fpga/sim && ./run_sims.sh tb_tilelist` (or the file-scoped invocation `run_sims.sh` uses; if it runs all, `./run_sims.sh` and confirm `tb_tilelist` and `tb_tilelist_res` both pass).
Expected: `tb_tilelist` PASS including the new biased case; `tb_tilelist_res` still PASS (regression — its bias path is untouched).

- [ ] **Step 6: Commit**

```bash
git add patches/mister/blitter/blitter_ref.c fpga/rtl/blitter_top.sv fpga/sim/tb_tilelist.sv
git commit -m "feat(fabric): apply header bias to direct BLT_OP_TILELIST (camera-independent static tiles)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Emitter — `blt_tile_list_static`

Add the host-side emitter for a direct-`TILELIST` header (opcode 5) carrying the per-frame bias, mirroring `blt_tile_list_res`. `tl_emit_header` is already opcode-parameterized and packs the bias into the header src slots, so this is a thin wrapper + a selftest.

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h` (declare after `blt_tile_list_res`, ~207)
- Modify: `patches/mister/blitter/blt_emitter.c` (impl after `blt_tile_list_res`, ~333; selftest ~427)

**Interfaces:**
- Produces: `int blt_tile_list_static(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend, uint16_t key, uint8_t alpha, uint8_t flags, uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);` — emits a `BLT_OP_TILELIST` header pointing at `entry_off` (N 12-byte `blt_tile_entry_t` already resident in `tl_buf`), with `bias_x/bias_y` in the header. Returns 0 on success, -1 (+`e->overflow`) on invalid tex / `n<=0`. Consumed by Task 3.

- [ ] **Step 1: Write the failing selftest**

In `patches/mister/blitter/blt_emitter.c`, inside the `#ifdef BLT_EMITTER_SELFTEST` block, add after `test_blt_tile_list_res` and call it from `main`:

```c
/* [static tile-list] blt_tile_list_static emits a header-only BLT_OP_TILELIST
 * (12-byte direct entries) with N, entry byte-offset, and the dst bias. */
static void test_blt_tile_list_static(void) {
    blt_emitter_t e; uint8_t ring[4096]; uint8_t heap[4096]; uint8_t tlbuf[4096];
    blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_tile_list_init(&e, tlbuf, sizeof tlbuf);
    blt_surface_ref_t tex = { .valid=1, .off=0x2000, .sdram_off=BLT_ALLOC_FAIL,
                              .stride=1024, .format=BLT_FMT_RGB565, .w=512, .h=512 };
    const uint32_t eoff = 96; const int n = 7;
    CHECK(blt_tile_list_static(&e, tex, BLT_BLEND_COPY, 0, 255, 0, eoff, n, -4, 3) == 0,
          "blt_tile_list_static returned non-zero");
    blt_cmd_t c; memcpy(&c, ring, sizeof c);
    CHECK(c.opcode == BLT_OP_TILELIST, "opcode %u exp %u", c.opcode, BLT_OP_TILELIST);
    CHECK(((uint32_t)c.w | ((uint32_t)c.h<<16)) == (uint32_t)n, "N mismatch");
    CHECK(((uint32_t)(uint16_t)c.dst_x | ((uint32_t)(uint16_t)c.dst_y<<16)) == eoff, "eoff mismatch");
    CHECK((int16_t)c.src_x == -4 && (int16_t)c.src_y == 3, "bias mismatch");
    printf("ok test_blt_tile_list_static\n");
}
```

Add `test_blt_tile_list_static();` to `main()` next to the existing `test_blt_tile_list_res();`.

- [ ] **Step 2: Build the selftest to verify it FAILS (undeclared function)**

Run:
```bash
cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter \
   patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c \
   -o /tmp/blt_emit
```
Expected: compile FAIL — `implicit declaration of function 'blt_tile_list_static'`.

- [ ] **Step 3: Declare + implement**

In `blt_emitter.h`, after the `blt_tile_list_res` prototype (~207):

```c
/* [static tile-list] Emit a header-only BLT_OP_TILELIST pointing at `entry_off`
 * (N 12-byte blt_tile_entry_t already resident in tl_buf). bias_x/bias_y are a
 * signed per-batch dst bias (map-coord -> screen), carried in the header. */
int blt_tile_list_static(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                         uint16_t key, uint8_t alpha, uint8_t flags,
                         uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y);
```

In `blt_emitter.c`, after `blt_tile_list_res` (~333):

```c
int blt_tile_list_static(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend,
                         uint16_t key, uint8_t alpha, uint8_t flags,
                         uint32_t entry_off, int n, int16_t bias_x, int16_t bias_y)
{
    if (!tex.valid || n <= 0) { e->overflow = 1; return -1; }
    return tl_emit_header(e, BLT_OP_TILELIST, tex, blend, key, alpha, flags,
                          entry_off, n, bias_x, bias_y);
}
```

- [ ] **Step 4: Build + run the selftest — expect PASS**

Run:
```bash
cc -DBLT_EMITTER_SELFTEST -I patches/mister/blitter \
   patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c \
   -o /tmp/blt_emit && /tmp/blt_emit
```
Expected: `ok test_blt_tile_list_res` and `ok test_blt_tile_list_static`, no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c
git commit -m "feat(emitter): blt_tile_list_static — direct 12-byte TILELIST header with bias

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Renderer — static tile-list record / arm / emit

Add the static bucket path parallel to the RES path. Static entries (12-byte) share `TL_BUF`, laid down after the 8-byte RES entries by a combined `res_arm_`. Validated by armhf build-clean here; behavior proven on HW in Task 5.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (structs ~430-448; `resident_begin_frame` clear ~1762; `res_arm_` ~1885; new record/emit methods; op-count/emit accessors ~1971-1990)
- Modify: `patches/mister/mister_blitter_renderer.h` (declare the new public methods used by the engine walk)
- Modify: `scripts/build_engine.sh` (add virtual method decls to `Renderer.h`, ~1758-1795 block)

**Interfaces:**
- Consumes: `blt_tile_list_static(...)` (Task 2).
- Produces (public `MisterBlitterRenderer` methods, called from the Task 4 engine walk):
  - `void resident_record_static(int layer, int scroll_ratio, const SurfaceImpl& tileset_image, BlendMode blend, const std::vector<TileBatchEntry>& entries);`
  - `int  resident_static_op_count(int layer) const;`
  - `void resident_emit_static_op(int layer, int i);`

- [ ] **Step 1: Add static structures + clear on rebuild**

In `mister_blitter_renderer.cpp`, after the `ResBucket`/`ResOp` structs (~447) add:

```cpp
  // [static tile-list] 12-byte direct-src entry (map-coord dst) + its bucket. Parallel
  // to ResBucket/ResEnt but for BLT_OP_TILELIST (no pattern indirection, no BLT_MAXP cap).
  struct StaticEnt { uint16_t sx, sy, w, h; int16_t dx, dy; };   // matches blt_tile_entry_t
  struct StaticBucket {
    const SurfaceImpl* tsimg; uint8_t blend, flags, fmt; uint16_t key;
    int layer; int scroll_ratio;
    uint32_t hw_off; int hw_count;              // 12-byte entries written at arm
    std::vector<StaticEnt> ent;
  };
  std::vector<StaticBucket> res_static_buckets;
  std::vector<ResOp>        res_static_ops;      // (bucket idx, layer) in paint order
```

In `resident_begin_frame` where the RES stores are cleared for a rebuild (~1762, alongside `d->res_buckets.clear(); d->res_ops.clear();`) add:

```cpp
  d->res_static_buckets.clear(); d->res_static_ops.clear();
```

- [ ] **Step 2: Extend `res_arm_` to lay static 12-byte entries after the RES entries**

Replace the capacity check + entry-write tail of `res_arm_` (~1886-1921) so it does a **combined byte-budget** check and appends static entries after the RES entries (shared `cur` byte cursor):

```cpp
void MisterBlitterRenderer::res_arm_() {
  size_t res_bytes  = 0;
  for (const auto& b : d->res_buckets)        res_bytes  += b.hw.size()  * sizeof(blt_tile_entry_res_t);
  size_t stat_bytes = 0;
  for (const auto& b : d->res_static_buckets) stat_bytes += b.ent.size() * sizeof(blt_tile_entry_t);
  if (res_bytes + stat_bytes > d->em.tl_cap) {
    d->res_fatal = true;
    std::fprintf(stderr,
        "[blitter resident] TL_BUF OVERFLOW: need %zu (res %zu + static %zu) > cap %zu bytes\n",
        res_bytes + stat_bytes, res_bytes, stat_bytes, d->em.tl_cap);
    d->res_armed = true;
    return;
  }
  // FRT: FRT[slot*MAXF + f] = {src_x, src_y, w, h} (LE), one qword each.  (UNCHANGED)
  for (size_t s = 0; s < d->res_patterns.size() && s < (size_t)BLT_MAXP; ++s) {
    const Impl::ResPattern& rp = d->res_patterns[s];
    for (int f = 0; f < rp.frame_count && f < BLT_MAXF; ++f) {
      volatile uint8_t* p = d->ddr + OFF_FRTBUF + (s * BLT_MAXF + f) * 8u;
      const uint16_t sx=(uint16_t)rp.frames[f].get_x(), sy=(uint16_t)rp.frames[f].get_y(),
                     w=(uint16_t)rp.frames[f].get_width(), h=(uint16_t)rp.frames[f].get_height();
      p[0]=(uint8_t)sx; p[1]=(uint8_t)(sx>>8); p[2]=(uint8_t)sy; p[3]=(uint8_t)(sy>>8);
      p[4]=(uint8_t)w;  p[5]=(uint8_t)(w>>8);  p[6]=(uint8_t)h;  p[7]=(uint8_t)(h>>8);
    }
  }
  uint32_t cur = 0;
  // 8-byte RES entries first (UNCHANGED layout).
  for (auto& b : d->res_buckets) {
    b.hw_off = cur; b.hw_count = (int)b.hw.size();
    for (const auto& e : b.hw) {
      volatile uint8_t* p = d->ddr + OFF_TLBUF + cur;
      p[0]=(uint8_t)e.pid; p[1]=(uint8_t)(e.pid>>8);
      p[2]=(uint8_t)e.dx;  p[3]=(uint8_t)((uint16_t)e.dx>>8);
      p[4]=(uint8_t)e.dy;  p[5]=(uint8_t)((uint16_t)e.dy>>8);
      p[6]=0; p[7]=0;
      cur += 8;
    }
  }
  // 12-byte static entries appended after; record per-bucket byte offset/count.
  for (auto& b : d->res_static_buckets) {
    b.hw_off = cur; b.hw_count = (int)b.ent.size();
    for (const auto& e : b.ent) {
      volatile uint8_t* p = d->ddr + OFF_TLBUF + cur;
      p[0]=(uint8_t)e.sx; p[1]=(uint8_t)(e.sx>>8);
      p[2]=(uint8_t)e.sy; p[3]=(uint8_t)(e.sy>>8);
      p[4]=(uint8_t)e.w;  p[5]=(uint8_t)(e.w>>8);
      p[6]=(uint8_t)e.h;  p[7]=(uint8_t)(e.h>>8);
      p[8]=(uint8_t)e.dx; p[9]=(uint8_t)((uint16_t)e.dx>>8);
      p[10]=(uint8_t)e.dy;p[11]=(uint8_t)((uint16_t)e.dy>>8);
      cur += 12;
    }
  }
  d->res_armed = true;
}
```

- [ ] **Step 3: Add `resident_record_static` + `res_emit_static_bucket_` + op accessors**

Add near the RES equivalents. `resident_record_static` (public), after `resident_record_batch` (~1863):

```cpp
void MisterBlitterRenderer::resident_record_static(int layer, int scroll_ratio,
        const SurfaceImpl& tileset_image, BlendMode blend,
        const std::vector<TileBatchEntry>& entries) {
  d->mark_render();
  if (!d->res_building || entries.empty()) return;
  blt_surface_ref_t tex; uint8_t bl, fl, fmt; uint16_t key;
  if (!d->res_bucket_params(tileset_image, blend, tex, bl, key, fl, fmt)) {
    d->res_fatal = true;
    std::fprintf(stderr,
        "[blitter resident] FATAL: unbatchable STATIC bucket (blend/tex) layer=%d n=%zu\n",
        layer, entries.size());
    return;
  }
  d->ensure_frame();
  Impl::StaticBucket bk{ &tileset_image, bl, fl, fmt, key, layer, scroll_ratio, 0u, 0, {} };
  bk.ent.reserve(entries.size());
  for (const auto& e : entries)
    bk.ent.push_back({ (uint16_t)e.src.get_x(), (uint16_t)e.src.get_y(),
                       (uint16_t)e.src.get_width(), (uint16_t)e.src.get_height(),
                       (int16_t)e.dst.x, (int16_t)e.dst.y });
  d->res_static_buckets.push_back(std::move(bk));
  d->res_static_ops.push_back({(uint32_t)(d->res_static_buckets.size() - 1), layer});
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_alias_blits += (long)entries.size();
}
```

Private emit, after `res_emit_bucket_` (~1958):

```cpp
void MisterBlitterRenderer::res_emit_static_bucket_(size_t idx) {
  if (idx >= d->res_static_buckets.size()) return;
  d->mark_render();
  d->ensure_frame();
  if (!d->res_armed) res_arm_();
  if (d->res_fatal) return;
  const Impl::StaticBucket& b = d->res_static_buckets[idx];
  if (b.hw_count == 0) return;
  blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
  if (!tex.valid) return;
  const int cx = mister_camera_x(), cy = mister_camera_y();
  int16_t bx, by;
  if (b.scroll_ratio <= 1) { bx = (int16_t)(-cx); by = (int16_t)(-cy); }
  else { bx = (int16_t)(cx / b.scroll_ratio - cx); by = (int16_t)(cy / b.scroll_ratio - cy); }
  blt_tile_list_static(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                       b.hw_off, b.hw_count, bx, by);
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_alias_blits += b.hw_count;
}
```

Public op accessors, next to `resident_layer_op_count`/`resident_emit_layer_op` (~1971-1990):

```cpp
int MisterBlitterRenderer::resident_static_op_count(int layer) const {
  int n = 0;
  for (const auto& o : d->res_static_ops) if (o.layer == layer) ++n;
  return n;
}
void MisterBlitterRenderer::resident_emit_static_op(int layer, int i) {
  int k = 0;
  for (const auto& o : d->res_static_ops)
    if (o.layer == layer) { if (k == i) { res_emit_static_bucket_(o.bk); return; } ++k; }
}
```

- [ ] **Step 4: Declare the methods (renderer header + base `Renderer` virtuals)**

In `patches/mister/mister_blitter_renderer.h`, declare the three public methods + the private `res_emit_static_bucket_(size_t)` on `MisterBlitterRenderer` (match the style of the existing `resident_record_batch`/`resident_emit_layer_op` declarations).

In `scripts/build_engine.sh`, in the Python block that injects the resident virtuals into `Renderer.h` (~1758-1795), add matching **base virtuals** so the engine can call them polymorphically (default no-op / return 0):

```
"  virtual void resident_record_static(int /*layer*/, int /*scroll_ratio*/,\n"
"                                      const SurfaceImpl& /*tileset_image*/,\n"
"                                      BlendMode /*blend*/,\n"
"                                      const std::vector<TileBatchEntry>& /*entries*/) {}\n"
"  virtual int  resident_static_op_count(int /*layer*/) const { return 0; }\n"
"  virtual void resident_emit_static_op(int /*layer*/, int /*i*/) {}\n"
```

- [ ] **Step 5: armhf build-clean**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh`
Expected: `[100%] Built target solarus-run`, no `error:`. (This compiles the renderer with the new static path; the engine walk in Task 4 will exercise it.)

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h scripts/build_engine.sh
git commit -m "feat(renderer): static tile-list record/arm/emit (direct BLT_OP_TILELIST from perm atlas)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Engine walk + cell suppression + `SOLARUS_TILESTATIC` gate

Walk the non-animated tiles into the static list on build frames; emit static ops (background) before animated ops on fast frames; stop calling the cell path when the gate is ON.

**Files:**
- Modify: `scripts/build_engine.sh` — the `Entities.cpp` resident-walk Python block (~1856-2100) and a new `NonAnimatedRegions.cpp` walk method.

**Interfaces:**
- Consumes: `resident_record_static`, `resident_static_op_count`, `resident_emit_static_op` (Task 3); `mister_flag_default_on("SOLARUS_TILESTATIC")`.

- [ ] **Step 1: Read the non-animated tile iteration API**

Read `work/solarus/include/solarus/entities/NonAnimatedRegions.h`, `NonAnimatedTilesData.h`, and the `TileInfo` type used by `NonAnimatedRegions::build_cell` (`non_animated_tiles.get_elements(cell_index)` returns `const std::vector<TileInfo>&`; `non_animated_tiles.get_num_cells()`). Note the exact `TileInfo` accessors for the tile's `TilePattern`, its map position (top-left x/y), and size — these feed `get_draw_region`. Also note `NonAnimatedRegions` holds a `Map& map` and knows its `layer`.

- [ ] **Step 2: Add `NonAnimatedRegions::record_static(Renderer&)`**

In the `build_engine.sh` `NonAnimatedRegions.cpp` patch section (near the existing opaque-cell patch, ~603-653), add a Python edit that appends a method which walks **all** cells' tiles once and records them into the static list, in map coords, expanding repeated/fill tiles per-cell exactly as the animated walk does (mirror the batchable/`get_draw_region` + per-cell expansion logic in the `Entities.cpp` animated walk, ~1953-2094). Bucket by `{tileset image, blend, scroll_ratio}`; a non-batchable tile calls the renderer's fatal path (do NOT silently draw). Signature:

```cpp
// [static tile-list] Record every non-animated tile of this layer into the renderer's
// static tile-list (map coords), replacing the per-cell optimized_tiles_surfaces path.
void NonAnimatedRegions::record_static(Renderer& renderer);
```

Declare it in `NonAnimatedRegions.h` (Python edit). Reuse `map.get_tileset()`, `TileInfo`'s pattern/box, and `pattern.get_draw_region(...)`; accumulate `TileBatchEntry{src,dst}` (dst = tile map top-left, camera-independent) per bucket and flush via `renderer.resident_record_static(layer, ratio, tsimg->get_impl(), tsimg->get_blend_mode(), entries)`.

- [ ] **Step 3: Call `record_static` on build frames; skip `draw_on_map` when gated**

In the `Entities.cpp` draw path (the resident walk block, ~1886-1913 for fast, and the layer loop that calls `non_animated_regions[layer]->draw_on_map()`), gate on a cached flag read once (e.g. `static const bool _tilestatic = mister_flag_default_on("SOLARUS_TILESTATIC");`):

- BUILD frame (`rmode == 1`) and `_tilestatic`: call `non_animated_regions[layer]->record_static(R);` (in addition to the animated walk).
- When `_tilestatic` (any frame): **do not** call `non_animated_regions[layer]->draw_on_map()` (and skip `->update()` cell eviction). When not set: unchanged legacy cell path.
- FAST frame (`rmode == 2`) and `_tilestatic`: before the animated op loop, emit the static background:

```cpp
      const int _nsops = R.resident_static_op_count(layer);
      for (int _si = 0; _si < _nsops; ++_si) R.resident_emit_static_op(layer, _si);
```

(Ensure `mister_flag_default_on` is declared/included in `Entities.cpp` — it is already used elsewhere in the patched engine; reuse the same include.)

- [ ] **Step 4: armhf build-clean**

Run: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh`
Expected: `[100%] Built target solarus-run`, no `error:`. (Because `build_engine.sh` re-clones/patches upstream, this proves the Python anchors matched and the walk compiles.)

- [ ] **Step 5: Commit**

```bash
git add scripts/build_engine.sh
git commit -m "feat(engine): walk non-animated tiles into static tile-list; suppress cell path (SOLARUS_TILESTATIC)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: HW validation (RBF + engine) + A/B

Prove on device: overworld background renders from the perm atlas, title-fragment garbage gone (standing AND moving), no `res_fatal`, title/menu/HUD unregressed.

**Files:** none (build + deploy + observe). Requires the RBF rebuilt from Task 1's RTL (see Step 1).

- [ ] **Step 1: Build the RBF (Task 1 changed RTL)**

The fabric bias change needs a new bitstream. Kick the CI RBF build for this branch (the repo's usual Quartus CI), or a local Quartus build if configured. Retrieve the `.rbf` artifact. (If iterating engine-only before the RBF lands, the static path will emit `OP_TILELIST` with a bias the OLD RBF ignores → wrong dsts; so the RBF MUST be the Task-1 build before trusting HW output.)

- [ ] **Step 2: armhf build + deploy engine**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
scp -O build/armhf/libsolarus.so.1.6.5 root@192.168.20.81:/tmp/newlib.so
ssh root@192.168.20.81 'md5sum /tmp/newlib.so build/... ' # verify equal to local md5sum build/armhf/libsolarus.so.1.6.5
ssh root@192.168.20.81 'for p in $(ps | grep -E "solarus_daemon|solarus-run|core_watch|quest_manager" | grep -v grep | awk "{print \$1}"); do kill -9 $p 2>/dev/null; done; sleep 1; LIB=/media/fat/games/solarus/libs/libsolarus.so.1.6.5; rm -f "$LIB"; mv /tmp/newlib.so "$LIB"; md5sum "$LIB"'
```
Deploy the new RBF to `/media/fat/_Other/Solarus_<date>.rbf` and `load_core` it (the fabric change is required). Relaunch: `ssh root@192.168.20.81 'SOLARUS_BLITTER_DIAG=1 setsid sh /media/fat/games/Solarus/solarus_run.sh >/tmp/solarus.log 2>&1 </dev/null &'`.

- [ ] **Step 3: Drive to the overworld + screenshot**

Use joypad injection (hammer + release; bits Right=0x01 Left=0x02 Down=0x04 Up=0x08 Sword=0x10 Action=0x20 Pause=0x100). From title: several `0x20` (Action) then a save pick. Verify overworld via diag: `[blitter resident] ... valid=1 fatal=0`. Screenshot: `echo screenshot > /dev/MiSTer_cmd`; pull newest `/media/fat/screenshots/Solarus/*.png`; Read it.

- [ ] **Step 4: Verify success criteria (evidence, not assertion)**

From `/media/fat/logs/Solarus/Solarus.diag.log` and the screenshots:
- Background tiles read from the **perm atlas**: `[blitmap]` (already present) shows tile source `off=0x01……`/`0x04……`, **no `0x05……` inter reads** for the overworld field.
- `res_fatal=0` and no `TL_BUF OVERFLOW` line in the log.
- Overworld screenshot: title-screen fragments **gone** — standing.
- Walk the hero (hammer a dpad bit for sustained scroll) and screenshot mid-move: background still correct (proves camera-independent bias), no fragments.
- Title screen + pause/options menu + HUD (hearts/rupees) still render.

- [ ] **Step 5: A/B the gate**

Relaunch with `SOLARUS_TILESTATIC=0` (legacy cell path). Confirm the overworld reverts to the cell path (inter reads reappear; the pre-fix garbage returns on the affected map region), then relaunch default (ON) and confirm clean. This isolates the fix to the new path.

- [ ] **Step 6: Reconcile diagnostics + commit any doc/log updates**

Remove or gate any leftover `[stalechk]`/`[blitmap]` diagnostic spam not wanted in the shipped engine (the cache-probe agent's 4 gated edits in `mister_blitter_renderer.cpp` + the `[blitmap]`/`[preloadmap]`/`[promote]` diag logs — keep only what earns its place behind `diag`). Commit.

```bash
git add -p patches/mister/mister_blitter_renderer.cpp
git commit -m "chore(renderer): trim static-tile-list bringup diagnostics

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** Fabric bias (spec §Components 1) → Task 1. Ref model (2) → Task 1 Step 1. Emitter (3) → Task 2. Renderer static path (4) → Task 3. Engine walk + suppression (5) → Task 4. Gating → Task 4 Step 3. Capacity/`res_fatal` → Task 3 Step 2. Testing (sim/emitter/HW) → Tasks 1,2,5. Success criteria → Task 5 Step 4. Kept relocation, menu/title out of scope → respected (no revert; only cell path touched). All spec sections covered.

**Placeholder scan:** Task 4 Steps 1-2 intentionally include a *read-the-API* step because `TileInfo`/`NonAnimatedTilesData` accessors must be taken from upstream at implementation time (they live in the build-time clone, not the repo); the surrounding code, signature, bucketing rule, and integration points are fully specified. No other TBD/TODO.

**Type consistency:** `resident_record_static` / `resident_static_op_count` / `resident_emit_static_op` / `res_emit_static_bucket_` used identically in Tasks 3 and 4. `StaticEnt` layout matches `blt_tile_entry_t` (u16 sx,sy,w,h; i16 dx,dy) and the `res_arm_` 12-byte packing. `blt_tile_list_static` signature matches between Task 2 (def) and Task 3 (call).
