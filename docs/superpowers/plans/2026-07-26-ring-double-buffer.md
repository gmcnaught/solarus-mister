# Command-Ring Double-Buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pipeline depth 2 — the A9 emits frame S+1 while the fabric composites frame S, taking the frame period from `A + F` to `max(A, F, 16.69 ms)`.

**Architecture:** Seq-parity command banks (bank `b` = 8-qword ctrl block + 512 KiB ring at `0x3B000000 + b*0x80000`), a `BANK_EN` opt-in bit in `C_SUBMIT[32]`, `C_DONE = done+1` per composited frame, a fabric-side publish-spacing tear gate, host-side TL/SP half-cursors, and a deferred-free queue for the DDR bounce heap. Spec: `docs/superpowers/specs/2026-07-26-ring-double-buffer-design.md`.

**Tech Stack:** SystemVerilog (Icarus for sim), C (blitter emitter + host tests), C++17 (renderer), armhf cross-build via Docker, Quartus RBF via GitHub CI.

## Global Constraints

- `SOLARUS_RINGDBUF` default **OFF**; `=0` must be byte-identical to today's behaviour (bank 0 only, `BANK_EN=0`, old `C_DONE == S-1` fence, full-width TL/SP).
- Old engine on new RBF must work: fabric treats `C_SUBMIT[32]==0` as bank-0-always.
- Heap base moves `0x3B080000 → 0x3B100000`; fabric `SRC_QW` moves `0x07610000 → 0x07620000` **in the same change** (stage sources read from `SRC_QW + src_off`).
- Never reuse RESERVED wire constants (`OP_BGPLANE_WRITE = 8`, `BLT_F_BGCOV`).
- Renderer type-check MUST use both `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO` (see CLAUDE.md — omitting them type-checks nothing).
- Any new header the renderer includes MUST be registered in `scripts/apply_mister_files.sh` (has bitten twice; the type-check cannot catch it).
- Engine cross-build check: `scripts/docker_run.sh scripts/build_engine.sh` before declaring the branch sound.
- Host suite: `bash tests/run_tests.sh`. Sims: `fpga/sim/run_sims.sh <tb_name>`.
- Subagents do NOT inherit the parent `$PATH` — use absolute paths or `cd` into the repo and use repo-relative script paths; Docker must be invoked via `scripts/docker_run.sh`.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` + `Claude-Session: https://claude.ai/code/session_01JDoZHYk8zANp3FmfKdWgRq`.

---

### Task 0: Phase 0 HW sizing measurement (session-owner runs this, NOT a subagent — needs the device)

**Files:**
- Create: `docs/superpowers/data/ring-dbuf-phase0/README.md` (captures + arithmetic)
- Modify (spec §6): `docs/superpowers/specs/2026-07-26-ring-double-buffer-design.md` (plug in measured numbers)

**Interfaces:**
- Produces: per-scene `A` (A9 ms), `F` (fabric ms), predicted fps `1/max(A,F,16.69ms)`, predicted latency add `max(0, F−A)`; GO/NO-GO per the ≥ +15 % rule.

- [ ] **Step 1:** Device is `192.168.20.81` (up, engine not running — verified 15:27). Launch the deployed engine detached with the diag banner on, per the memory recipes (`setsid sh solarus_run.sh > /media/fat/logs/ring-phase0.log 2>&1 < /dev/null &` with `SOLARUS_BLITTER_DIAG=1`; leave `Solarus.s0` untouched — one engine only).
- [ ] **Step 2:** Drive four scenes ≥ 60 s each using the lua-console FIFO harness + joypad inject memories: (a) map 3, (b) town, (c) map 119 parallax, (d) map 40 with a dialog held open.
- [ ] **Step 3:** From the banner lines compute per scene: `F = fabric_hw`, `A = frame_period − fabwait − sleep − vblank`, predictions per the two formulas. Save raw log excerpts + a small table to `docs/superpowers/data/ring-dbuf-phase0/`.
- [ ] **Step 4:** Record GO/NO-GO in the spec §2 and paste the per-scene table into spec §6. Commit `docs(phase0): ring-dbuf sizing captures + go decision`.

---

### Task 1: Wire constants — bank 1 layout, BANK_EN, heap/SRC_QW move

**Files:**
- Modify: `patches/mister/blitter/blitter_ref.h` (wire-constant block)
- Modify: `fpga/rtl/blitter_defs.vh` (`SRC_QW`, new bank defines)
- Modify: `scripts/tests/test_wire_constants.py`
- Modify: `patches/mister/mister_blitter_renderer.cpp:364-370` (OFF_RING/RING_CAP/OFF_HEAP block)

**Interfaces:**
- Produces (host, `blitter_ref.h`): `BLT_OFF_CTRL1 = 0x00080000u`, `BLT_OFF_RING1 = 0x00080040u`, `BLT_BANK_STRIDE = 0x00080000u`, `BLT_SUBMIT_BANK_EN_BIT = 32`, heap base `0x00100000u`.
- Produces (fabric, `blitter_defs.vh`): `` `BANK_QW_STRIDE 29'h10000 ``, `` `SRC_QW 29'h07620000 `` (was `07610000`).
- Produces (renderer): `constexpr uint32_t OFF_CTRL1 = 0x00080000u; OFF_RING1 = 0x00080040u; OFF_HEAP = 0x00100000u;` with the contiguity static_assert updated to `OFF_RING1 + RING_CAP == OFF_HEAP`.

- [ ] **Step 1: Write the failing test.** In `scripts/tests/test_wire_constants.py`, add cross-checks (same regex style as the existing OFF_TLBUF checks): host `BLT_OFF_RING1` ↔ fabric `BLTCTRL_QW + BANK_QW_STRIDE + 8` (qword→byte ×8), host heap base `0x00100000` ↔ fabric `SRC_QW == (0x3B000000 + 0x00100000) >> 3 == 0x07620000`, and `BLT_BANK_STRIDE == 0x80000`.
- [ ] **Step 2:** Run `python3 scripts/tests/test_wire_constants.py` — expect FAIL (constants absent).
- [ ] **Step 3: Add the constants.** `blitter_ref.h`: new block next to the existing region constants:

```c
/* [ring-dbuf] Command banks: bank b = 8-qword ctrl + 512 KiB ring at
 * BLT_DDR_PHYS + b*BLT_BANK_STRIDE, identical internal layout. Bank 0 is the
 * pre-dbuf map, byte-identical. C_SUBMIT/C_DONE stay GLOBAL at bank-0
 * addresses. C_SUBMIT bit32 = BANK_EN (host opt-in; 0 => fabric uses bank 0
 * always, old-engine compatible). Heap base moved 0x80000 -> 0x100000 to make
 * room for bank 1; fabric SRC_QW moved in lockstep (stage = SRC_QW + src_off). */
#define BLT_BANK_STRIDE        0x00080000u
#define BLT_OFF_CTRL1          0x00080000u
#define BLT_OFF_RING1          0x00080040u
#define BLT_SUBMIT_BANK_EN_BIT 32
#define BLT_OFF_HEAP_DBUF      0x00100000u
```

`blitter_defs.vh`: change `` `SRC_QW `` to `29'h07620000` (update its doc comment), add `` `define BANK_QW_STRIDE 29'h10000 `` next to `BLTCTRL_QW`. Renderer block at `:364`: set `OFF_HEAP = 0x00100000u`, add `OFF_CTRL1`/`OFF_RING1`, update the static_assert, and add `static_assert(OFF_RING1 + RING_CAP == OFF_HEAP, ...)`.
- [ ] **Step 4:** Run `python3 scripts/tests/test_wire_constants.py` → PASS; `bash tests/run_tests.sh` → PASS (no behaviour change yet).
- [ ] **Step 5:** Commit `feat(wire): bank-1 ctrl/ring constants + BANK_EN bit + heap/SRC_QW move`.

---

### Task 2: Emitter — dbuf mode, bank/half cursors, deferred-free queue

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h` (struct + API)
- Modify: `patches/mister/blitter/blt_emitter.c` (`blt_begin_frame`, new functions)
- Create: `tests/ring_dbuf_emitter_test.c` (+ register in `tests/run_tests.sh` the same way as `blt_alloc_test.c`)

**Interfaces:**
- Consumes: Task 1 constants.
- Produces:
  - `void blt_emitter_set_dbuf(blt_emitter_t *e, int enable, void *ring1);` — arms dbuf mode with bank-1 ring pointer.
  - Struct fields: `int dbuf_en; uint8_t *ring1; int bank;` (bank of the frame being built).
  - `blt_begin_frame` (unchanged signature) additionally: `e->bank = e->dbuf_en ? (int)((e->submit_seq + 1u) & 1u) : 0;` and starts `tl_used`/`sp_used` at `bank ? tl_cap/2 : 0` / `bank ? sp_cap/2 : 0`; per-frame caps become the half end (`tl_frame_cap`, `sp_frame_cap` fields the existing overflow checks compare against instead of `tl_cap`/`sp_cap`).
  - `uint8_t *blt_frame_ring(blt_emitter_t *e);` — returns `bank ? ring1 : ring` (the buffer the current frame's commands are packed into).
  - `void blt_emitter_free_deferred(blt_emitter_t *e, uint32_t off, uint32_t size);` — queues `{off,size,seq=submit_seq+1}` (the frame being built references the heap NOW; safe to free once THAT frame is done).
  - `void blt_emitter_drain_deferred(blt_emitter_t *e, uint32_t done_seq);` — frees all entries with `(int32_t)(done_seq - seq) >= 0`. In non-dbuf mode `blt_emitter_free_deferred` calls `blt_free` immediately (today's behaviour).

- [ ] **Step 1: Write the failing test** `tests/ring_dbuf_emitter_test.c` (pure host, mirrors `blt_alloc_test.c` harness style: local buffers, `CHECK` macro, `main` returns nonzero on fail):

```c
/* ring_dbuf_emitter_test — bank/half cursor alternation + deferred-free.
 * Models the 2-deep pipeline invariants host-side (no fabric). */
#include "../patches/mister/blitter/blt_emitter.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    static uint8_t ring0[0x10000], ring1[0x10000], heap[0x40000];
    static uint8_t tl[0x8000], sp[0x6000];
    blt_emitter_t e;
    blt_emitter_init(&e, ring0, sizeof ring0, heap, sizeof heap);
    blt_tile_list_init(&e, tl, sizeof tl);
    blt_sprite_list_init(&e, sp, sizeof sp);

    /* dbuf OFF: cursors at 0, ring is ring0, frees are immediate */
    blt_begin_frame(&e, 0, 0, 0);
    CHECK(e.bank == 0, "off: bank %d exp 0", e.bank);
    CHECK(e.tl_used == 0, "off: tl_used %zu exp 0", e.tl_used);
    CHECK(blt_frame_ring(&e) == ring0, "off: ring ptr");
    uint32_t off0 = blt_alloc(&e.alloc, 256);
    blt_emitter_free_deferred(&e, off0, 256);
    uint32_t off1 = blt_alloc(&e.alloc, 256);
    CHECK(off1 == off0, "off: immediate free -> same block reused");
    blt_emitter_free_deferred(&e, off1, 256);
    blt_end_frame(&e);                       /* seq 0 -> 1 */

    /* dbuf ON: seq parity picks bank + halves */
    blt_emitter_set_dbuf(&e, 1, ring1);
    blt_begin_frame(&e, 0, 0, 0);            /* building seq 2 -> bank 0 */
    CHECK(e.bank == 0, "f2: bank %d exp 0", e.bank);
    CHECK(e.tl_used == 0, "f2: tl_used %zu exp 0", e.tl_used);
    blt_end_frame(&e);                       /* seq -> 2 */
    blt_begin_frame(&e, 0, 0, 0);            /* building seq 3 -> bank 1 */
    CHECK(e.bank == 1, "f3: bank %d exp 1", e.bank);
    CHECK(e.tl_used == sizeof tl / 2, "f3: tl_used %zu exp half", e.tl_used);
    CHECK(e.sp_used == sizeof sp / 2, "f3: sp_used %zu exp half", e.sp_used);
    CHECK(blt_frame_ring(&e) == ring1, "f3: ring1 ptr");

    /* deferred free: block NOT reusable until drain(done >= tagged seq) */
    uint32_t offA = blt_alloc(&e.alloc, 512);
    blt_emitter_free_deferred(&e, offA, 512);        /* tagged seq 3 */
    uint32_t offB = blt_alloc(&e.alloc, 512);
    CHECK(offB != offA, "deferred: freed block must NOT be reused pre-drain");
    blt_emitter_drain_deferred(&e, 2);               /* done=2 < 3: no-op */
    uint32_t offC = blt_alloc(&e.alloc, 512);
    CHECK(offC != offA, "deferred: done=2 must not release seq-3 block");
    blt_emitter_drain_deferred(&e, 3);               /* releases it */
    uint32_t offD = blt_alloc(&e.alloc, 512);
    CHECK(offD == offA, "deferred: drained block reusable");

    printf(fails ? "ring_dbuf_emitter_test: FAIL (%d)\n" : "ring_dbuf_emitter_test: PASS\n", fails);
    return fails ? 1 : 0;
}
```

- [ ] **Step 2:** Register it in `tests/run_tests.sh` (copy the `blt_alloc_test.c` compile+run stanza; it links `blt_emitter.c blt_alloc.c blitter_ref.c`). Run `bash tests/run_tests.sh` → expect compile FAIL (`blt_emitter_set_dbuf` undefined).
- [ ] **Step 3: Implement** in `blt_emitter.{h,c}`: the struct fields (`dbuf_en`, `ring1`, `bank`, `tl_frame_cap`, `sp_frame_cap`, and a deferred queue `struct { uint32_t off, size, seq; } dfq[256]; int dfq_n;` — 256 entries is ≥ any per-frame free burst; on overflow fall back to leak-until-reset + a `dfq_dropped` counter, mirroring `blt_free`'s fragment-cap behaviour). `blt_begin_frame` gains (after the existing resets):

```c
    e->bank = e->dbuf_en ? (int)((e->submit_seq + 1u) & 1u) : 0;
    e->tl_used = (e->bank && e->tl_cap) ? e->tl_cap / 2 : 0;
    e->sp_used = (e->bank && e->sp_cap) ? e->sp_cap / 2 : 0;
    e->tl_frame_cap = e->dbuf_en ? (e->bank ? e->tl_cap : e->tl_cap / 2) : e->tl_cap;
    e->sp_frame_cap = e->dbuf_en ? (e->bank ? e->sp_cap : e->sp_cap / 2) : e->sp_cap;
```

Then change every `> e->tl_cap` / `> e->sp_cap` overflow comparison in `blt_emitter.c` (tile-list append, sprite append at `:493-497`, sprite flush at `:525`) to the `_frame_cap` fields. `blt_frame_ring` returns the bank ring; the internal `emit()` writes through `blt_frame_ring(e)` instead of `e->ring` (single-site change if `emit()` is the only ring writer — verify with `grep -n 'e->ring' blt_emitter.c` and route any others through the helper).
- [ ] **Step 4:** `bash tests/run_tests.sh` → all PASS (new test + no regressions — the suite exercises the old paths with `dbuf_en=0`).
- [ ] **Step 5:** Commit `feat(emitter): seq-parity banks, TL/SP half cursors, deferred-free queue`.

---

### Task 3: RTL — bank mux, BANK_EN, C_DONE = done+1 (the frame-collapse fix)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (FSM: `S_POLL_DONE`, `S_CHK_NEW`, the 5 per-frame control reads, `S_FETCH` ring base, `S_WR_DONE`)
- Create: `fpga/sim/tb_ring_dbuf.sv`
- Modify: `fpga/sim/run_sims.sh` (timeout entry if > default)

**Interfaces:**
- Consumes: Task 1 `` `BANK_QW_STRIDE ``.
- Produces: fabric behaviour later tasks and the host rely on: `bank = bank_en ? (done_reg+1)&1 : 0` applied to per-frame ctrl reads + ring fetch; `C_DONE` low32 written as `done_reg + 1` (one increment per composited frame, both modes); `bank_en` latched from `C_SUBMIT[32]` each poll.

- [ ] **Step 1: Write the failing TB** `fpga/sim/tb_ring_dbuf.sv`. Reuse the DDR-model + blitter_top instantiation pattern from an existing top-level TB (`tb_tilemap.sv` is the closest current-gen harness — copy its module wiring/clock/ddr-model preamble verbatim). Scenario:
  1. Write bank-0 ctrl (cmdcount=1, a 1-command ring: one OP_FILL + END) and bank-1 ctrl (different fill colour, ring at `RING_QW + BANK_QW_STRIDE`), `C_SUBMIT = {32'h1, 32'd2}` (BANK_EN=1, two frames pending: seq 1 in bank 1, seq 2 in bank 0 — note seq1→bank1 per parity).
  2. Wait for `C_DONE` low32 == 1: assert exactly one frame composited so far and its fill colour is bank 1's (proves bank mux + done+1; the old `submit_reg` copy would jump straight to 2).
  3. Wait for `C_DONE` == 2: assert the second colour landed (no frame collapse).
  4. Repeat with BANK_EN=0 and seqs 3,4 both staged in bank 0: assert both frames read bank 0 (compat).
  Print `RESULT: PASS` / `FAIL:` markers per suite convention.
- [ ] **Step 2:** `fpga/sim/run_sims.sh tb_ring_dbuf` → FAIL (done jumps 0→2 on the two-pending scenario against current RTL).
- [ ] **Step 3: Implement** in `blitter_top.sv`:

```systemverilog
// [ring-dbuf] bank_en latched from C_SUBMIT[32] (0 for old engines -> bank 0
// always). The bank belongs to the frame being STARTED (= done_reg+1), never
// to submit_reg: the host may already be a frame ahead.
reg bank_en; reg frame_bank;
wire [28:0] bank_qw = frame_bank ? `BANK_QW_STRIDE : 29'd0;
```

`S_POLL_DONE`: `submit_reg<=rd_data[31:0]; bank_en<=rd_data[32];`. `S_CHK_NEW` work-exists branch adds:

```systemverilog
// bank of the frame being STARTED: (done+1) parity, gated by bank_en
frame_bank <= bank_en & ((rd_data[31:0] + 32'd1) & 32'd1) != 32'd0;
```

(or equivalently `frame_bank <= bank_en & ~rd_data[0];` since `(done+1)&1 == ~done&1` — pick the explicit form and let the TB prove it). The five per-frame control reads (`S_CHK_NEW`→cmdcount, `S_GOT_CMDCNT`→target, `S_GOT_TARGET`→flags, `S_GOT_FLAGS`→srcsel, `S_GOT_SRCSEL`→clear) change `` `BLTCTRL_QW+`C_X `` to `` `BLTCTRL_QW+bank_qw+`C_X `` — **except** the `C_SUBMIT`/`C_DONE` polls which stay global. `S_FETCH`'s ring base `` `RING_QW `` becomes `` `RING_QW+bank_qw ``. `S_WR_DONE`:

```systemverilog
S_WR_DONE: begin
    // [ring-dbuf] done+1, NOT submit_reg: with two frames in flight a
    // submit-copy collapses the second (composited never, done skips it).
    bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_DONE;
    bm_din<={perf_frame_cyc, done_reg + 32'd1};
    done_reg<=done_reg + 32'd1;
    wr_ret<=S_WR_STATUS; state<=S_WR_WAIT;
end
```

(Keep `done_reg<=rd_data[31:0]` in `S_POLL_DONE` — the DDR word is still the source of truth on reset/reload; the increment keeps them coherent between polls.)
- [ ] **Step 4:** `fpga/sim/run_sims.sh tb_ring_dbuf` → PASS.
- [ ] **Step 5:** Run the neighbouring gate TBs to catch regressions: `fpga/sim/run_sims.sh tb_tilemap tb_blitter_blend_pipe` → PASS.
- [ ] **Step 6:** Commit `feat(rtl): seq-parity command banks + BANK_EN + done+1 C_DONE semantics`.

---

### Task 4: RTL — publish-spacing gate + snap_deferred counter

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (snapshot trigger path + C_STATUS write)
- Create: `fpga/sim/tb_snap_gate.sv`

**Interfaces:**
- Consumes: Task 3 state (two frames can now complete back-to-back).
- Produces: at most one WORK→DDR3 snapshot start per scanout vblank tick; 8-bit wrapping `snap_deferred_cnt` published in `C_STATUS` low32 bits `[31:24]` (bits 0/1/20 keep their current meanings).

- [ ] **Step 1: Write the failing TB** `fpga/sim/tb_snap_gate.sv` (same harness base as Task 3's TB, plus the vsync/vblank stimulus the existing scanout TBs use — copy the `vs` toggling block from `tb_scan_qworddup.sv`). Scenario: submit two 1-command frames back-to-back with BANK_EN=1 while holding vsync static; assert the second frame's snapshot does NOT start (watch `snap_start`) until the TB pulses the next vsync edge; then assert `C_STATUS[31:24]` == 1. Also assert steady-state no-op: with vsync ticking normally between two spaced frames, `C_STATUS[31:24]` stays 0 and no extra latency cycles appear between `p_blit_done` and `snap_start` (compare cycle counts with a control run).
- [ ] **Step 2:** `fpga/sim/run_sims.sh tb_snap_gate` → FAIL (second snapshot fires in the same window).
- [ ] **Step 3: Implement.** In `blitter_top.sv`, find where `snap_start` is pulsed (the composite-done → snapshot handoff; grep `snap_start <= 1'b1`). Add:

```systemverilog
// [ring-dbuf tear-guard] At most ONE WORK->DDR3 snapshot per reader vblank
// window. This is NOT the retired S_SNAP_WAIT (which gated EVERY frame,
// ~16.7ms in the critical path): it can only defer during backlog recovery
// (two composites finishing inside one scan window), where the fabric was
// already >1 frame behind. vsync_tick_cnt comes from the existing vs_sync
// 3-FF chain's rising-edge pulse.
reg [15:0] snap_last_vs;      // vsync count at the last snapshot start
reg [7:0]  snap_deferred_cnt; // published in C_STATUS[31:24]
wire snap_window_free = (vsync_cnt != snap_last_vs);
```

Gate the pulse: where the FSM would set `snap_start<=1'b1`, instead enter a wait-for-`snap_window_free` micro-state (new state `S_SNAP_GATE`, structured exactly like the existing `S_STAGE_BARRIER` wait pattern) that increments `snap_deferred_cnt` once on entry if the window is occupied; on `snap_window_free` it pulses `snap_start` and latches `snap_last_vs <= vsync_cnt`. If no `vsync_cnt` counter exists in `blitter_top`, add a 16-bit counter incremented on the existing `vs_rise` pulse. Extend the `S_WR_STATUS` `bm_din` low32 to include `snap_deferred_cnt` in bits `[31:24]` (mask them out of whatever currently occupies low32 — verify bits 24-31 are unused by grepping the C_STATUS readers in the renderer: bits 0, 1, 20 only).
- [ ] **Step 4:** `fpga/sim/run_sims.sh tb_snap_gate tb_ring_dbuf` → PASS both.
- [ ] **Step 5:** Commit `feat(rtl): publish-spacing snapshot gate + snap_deferred counter (tear guard)`.

---

### Task 5: Renderer wiring — flag, fence, bank doorbell, deferred frees, drains

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`
- Modify: `docs/env-variables.md` (SOLARUS_RINGDBUF entry)

**Interfaces:**
- Consumes: Tasks 1-2 APIs (`blt_emitter_set_dbuf`, `blt_frame_ring`, `blt_emitter_free_deferred`, `blt_emitter_drain_deferred`, `OFF_CTRL1`/`OFF_RING1`).
- Produces: `SOLARUS_RINGDBUF` (default 0) end-to-end behaviour; banner field `fence=`.

- [ ] **Step 1: Flag + init.** In the ctor's env-parse block (near the `vsync_pace` parse, `:1087-1095`): `ring_dbuf = env_flag("SOLARUS_RINGDBUF", false);`. In the mmap/init function (`:1230-1262`), after `blt_emitter_init`: `if (ring_dbuf) blt_emitter_set_dbuf(&em, 1, (void*)(ddr + OFF_RING1));`. Write the BANK_EN high word once here: `ddr_w32(C_SUBMIT + 4, ring_dbuf ? 1u : 0u);`.
- [ ] **Step 2: Fence.** In `ensure_frame()` (`:1337-1360`), replace the spin condition. Current: `ddr_r32(C_DONE) != em.submit_seq`. New (wrap-safe, both modes):

```cpp
        // [ring-dbuf] 2-deep fence: before building frame S (seq submit_seq+1)
        // into bank S&1, its previous occupant (seq S-2) must be DONE. Non-dbuf
        // keeps the old serialize (done == S-1). uint32 wrap-safe signed diff.
        const uint32_t need = ring_dbuf ? (em.submit_seq >= 1 ? em.submit_seq - 1u : 0u)
                                        : em.submit_seq;
        for (; spin < 5000 && (int32_t)(ddr_r32(C_DONE) - need) < 0; ++spin)
          nanosleep(&ts, nullptr);
```

(`need = submit_seq - 1` because the frame about to be built is seq `submit_seq+1` = S; S−2 = `submit_seq−1`.) Keep timing accumulation; add a separate `f_wait_fence_ns` accumulator and a `fence=` column where `fabwait` is printed in the banner (grep `fabwait` for the print site). After the fence, drain: `blt_emitter_drain_deferred(&em, ddr_r32(C_DONE));`.
- [ ] **Step 3: Bank-relative doorbell.** In `present()`'s doorbell (`:4398-4409`) and `submit_and_drain()` (`:1479-1490`): per-frame control words write to the frame's bank base:

```cpp
    const uint32_t cb = (ring_dbuf && d->em.bank) ? OFF_CTRL1 : 0u;  // ctrl block base
    d->ddr_w32(cb + C_CMDCOUNT, (uint32_t)d->em.cmd_count);
    d->ddr_w32(cb + C_TARGET,   (uint32_t)d->em.target_buf);
    d->ddr_w32(cb + C_CLEAR,    d->em.clear_color);
    d->ddr_w32(cb + C_FLAGS,    d->em.flags);
    d->ddr_w32(cb + C_SRCSEL,   1u | ((d->throttle_val & 0xFFu) << 8));
    __sync_synchronize();
    d->ddr_w32(C_SUBMIT, d->em.submit_seq);   // GLOBAL: doorbell stays at bank 0
```

`submit_and_drain`'s trailing spin keeps `== em.submit_seq` (it is a full drain by design — comment that).
- [ ] **Step 4: Deferred frees.** Convert the three DDR-bounce free sites (`:1218`, `:2051`, `:2769` — `blt_emitter_free(&em, ...)`) to `blt_emitter_free_deferred(...)`. Leave `blt_sdram_free` sites untouched (SDRAM mutations travel in-ring, ordered — spec §4.3).
- [ ] **Step 5: Full drains before shared-table rewrites.** Add a helper next to `submit_and_drain()`:

```cpp
  // [ring-dbuf] Shared single-copy tables (FRT/CFT/CLUT/GRID) may be read by the
  // in-flight frame; a frame that REWRITES them must first drain the pipeline.
  // One deliberately serialized frame, only on map/tileset transitions.
  void drain_pipeline() {
    if (!ring_dbuf || em.submit_seq == 0) return;
    struct timespec ts{0, 200000};
    for (int spin = 0; spin < 5000 && ddr_r32(C_DONE) != em.submit_seq; ++spin)
      nanosleep(&ts, nullptr);
    blt_emitter_drain_deferred(&em, ddr_r32(C_DONE));
  }
```

Call it before: the `blt_frt_upload` site (`:3693`), the CLUT upload site (`:1805`), the grid-build DDR writes (the `res_arm_` grid write path — grep `OFF_GRIDBUF` write sites), and every `blt_heap_reset` call (`:1685`, `:1795`, `:1891`, `:1924` — a heap reset while a frame is in flight would hand out extents the fabric is still staging from).
- [ ] **Step 6: Type-check** (both `-D` flags mandatory):

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
```

Expected: clean. Then `bash tests/run_tests.sh` → PASS.
- [ ] **Step 7:** Add the `SOLARUS_RINGDBUF` entry to `docs/env-variables.md` (default OFF, what it does, rollback semantics, the `fence=` banner field, the FASTPACE-style caveat that `=0` on the new RBF is the compat leg).
- [ ] **Step 8:** Commit `feat(render): SOLARUS_RINGDBUF — 2-deep fence, bank doorbell, deferred frees, table drains`.

---

### Task 6: Host-suite pipeline model test + TL/SP capacity check

**Files:**
- Create: `tests/ring_dbuf_pipeline_test.c` (+ register in `tests/run_tests.sh`)

**Interfaces:**
- Consumes: Task 2 emitter APIs.
- Produces: an executable model of the invariants HW validation will probe.

- [ ] **Step 1: Write the test.** Model a fake fabric consuming frames with a lag (an array standing in for DDR; "execute" frame S = record which ring bank + which TL half + which heap extents it read). Drive 6 frames with `dbuf_en=1`, fabric always one behind. Assert per frame: (a) the bank being written != the bank being "read" by the lagging fabric; (b) TL/SP cursors never cross their half boundary (emit tile-list entries until `overflow` trips — assert it trips at the HALF cap, not the full cap, and that `dropped` accounting still works); (c) a deferred-freed extent is never handed back while the lagging fabric still holds its frame. Same CHECK/main structure as Task 2's test file (self-contained; copy the harness top).
- [ ] **Step 2:** Run → FAIL only if Task 2's implementation has a bug; otherwise PASS immediately is acceptable here (this is a model-invariant test, written after the implementation exists — its value is regression protection for HW-probe invariants).
- [ ] **Step 3:** Capacity math as a static check in the same file: `CHECK(11764u * 8u < TL_HALF, ...)` with `TL_HALF = 0x80000/2` and a comment citing map 119's 11,764 resident entries (memory `solarus-map119-gridov-nogo`) — the heavy-map highwater fits a half with ~2.8× headroom.
- [ ] **Step 4:** `bash tests/run_tests.sh` → PASS. Commit `test(host): ring-dbuf pipeline invariants + TL half capacity check`.

---

### Task 7: Docs + builds + PR

**Files:**
- Modify: `docs/frame-dataflow.md` (handshake section: 2-deep fence, banks, publish gate)
- Modify: `CLAUDE.md` (one paragraph in the rendering-architecture bullet list: flag name, default OFF, spec pointer)

**Interfaces:** none (docs + verification).

- [ ] **Step 1:** Update `docs/frame-dataflow.md`'s handshake/dataflow description with the bank diagram (ctrl0/ring0 @ 0x3B000000, ctrl1/ring1 @ 0x3B080000, heap @ 0x3B100000, global C_SUBMIT/C_DONE, done+1, publish gate).
- [ ] **Step 2:** Engine cross-build: `scripts/docker_run.sh scripts/build_engine.sh` → must produce `build/armhf/solarus-run` + `libsolarus.so.1.6.5` cleanly (per CLAUDE.md this is the only pre-CI check that catches missing-header registration).
- [ ] **Step 3:** Full local gates: `bash tests/run_tests.sh`, `python3 scripts/tests/test_wire_constants.py`, `fpga/sim/run_sims.sh tb_ring_dbuf tb_snap_gate tb_tilemap` → all PASS.
- [ ] **Step 4:** Push branch, open PR (title `perf(pipeline): command-ring double-buffer — overlap A9 emit with fabric composite`; body: spec link, Phase 0 numbers, flag default OFF, rollback = unset/`=0`, HW-validation plan checklist from spec §7, PR trailer per Global Constraints). CI builds the RBF + runs sims/tests.
- [ ] **Step 5:** Commit any doc fixups; verify CI green. Report ready-for-review.

---

### Task 8: HW validation (session-owner + operator; after CI RBF exists)

**Files:**
- Create: `docs/superpowers/data/ring-dbuf-ab/` (captures)
- Create: `docs/superpowers/2026-07-XX-ring-dbuf-hw-validation.md` (record)

- [ ] **Step 1:** Refresh `deploy/` from `build/armhf` (memory `fpga-deploy-refresh-from-build-armhf`), fetch the CI RBF artifact, `./deploy.py` (ships engine+RBF together; sha1-verify per the device gotchas).
- [ ] **Step 2:** Compat leg first: `SOLARUS_RINGDBUF` unset on the NEW RBF — banner + visual identical to Phase 0 baseline (operator confirm).
- [ ] **Step 3:** A/B per scene (the four Phase 0 scenes): flag on vs off — fps, `fence=`, `fabric_hw` unchanged-check.
- [ ] **Step 4:** Tear probes: #151's published-vs-displayed counter method (60 s aggregate + 250 ms fine windows, ≥ +2 = fail) and the backlog probe on map 119 while reading `snap_deferred` (C_STATUS[31:24]) to see the gate fire.
- [ ] **Step 5:** Wedge soak: ≥ 30 map transitions (the drain path) + the lua-console teleport harness, noting the pre-existing teleport race (do not misattribute).
- [ ] **Step 6:** Operator visual gate (standing rule: never self-declared). Record everything in the validation doc; only then flip the default in a follow-up commit/PR per spec §4.5.
