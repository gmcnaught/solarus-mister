# Session handoff — compositor throughput/timing optimization (2026-06-25)

Branch **`v2-blitter-base`**. Everything below is **committed + pushed**, the RBF is
**deployed to the DE10 (192.168.20.81)** and **HW-validated**. Safe to compact context.

## What shipped (commits, oldest→newest on top of 27c421c)
1. `6daac58` test(sim): rebuilt `fpga/sim/tb_profile.sv` as a full-datapath per-phase
   cycle profiler (SKIP-listed; run manually). Proved compositor is **memory-bound,
   not ALU-bound** (wide blits ~6 cyc/px, comp only ~17%).
2. `a2a28f7` perf(comp): **pipeline colormod (tint)** — split the per-channel
   multiply from the /255 reduce across a new `s3` stage in `comp_pipeline.sv`
   (II=1, PIPE_DEPTH 5→6). Was THE clk_sys critical path.
3. `3a9573f` perf(comp_burst): **write FSM 3→2 cyc/beat** — combinational `wr_beat`
   + combinational `wr_take` (`S_WRWAIT & !mem_busy`) so the FIFO head advances the
   same cycle a beat is accepted.
4. `34a8142` feat(perf): **HW perf counters** — `blitter_top` `perf_frame_cyc`
   (fabric-busy) + `perf_pipe_cyc` (compositor-busy) per frame, published in
   `C_DONE[63:32]` / `C_STATUS[63:32]` (be widened 0x0F→0xFF). Host renderer reads
   `C_DONE+4`/`C_STATUS+4` under `SOLARUS_BLITTER_DIAG`.
5. `0e03cf9` perf(comp): **skip band-LOAD RMW for opaque, fully-covered spans** —
   `comp_opaque = (mix_mode==COMP_COPY)&&!b_palpha`; in `P_LOAD_RD` skip the preload
   when `comp_opaque && dst_x%4==0 && len%4==0`. ALPHA/ADD/MUL/KEY/PALPHA still preload.
6. `9e3e8ca` fix(renderer): define host `C_STATUS=0x30` (engine cross-build broke;
   native `g++ -fsyntax-only` missed it — different include order).
7. `318e6e6` feat(launch): `diag.env` hook in `solarus_run.sh` (`set -a; . diag.env`).
8. `3614be4` fix(launch): when DIAG set, redirect engine to
   `/media/fat/logs/Solarus/Solarus.diag.log` (daemon launches engine with
   stdout+stderr on /dev/null, so DIAG output was discarded).

## Results (tb_profile, cyc/px) + timing (clk_sys = general[0] setup slack)
| blit | start → end | | build | slack |
|---|---|---|---|---|
| COPY wide | 6.08 → **4.56** (−25%) | | baseline 27c421c | **−3.359 ns** |
| FILL wide | 4.57 → **3.06** (−33%) | | +colormod+writeFSM+ctrs | −0.075 ns |
| FILL sprite | 5.88 → 4.35 | | **+opaque-skip (deployed)** | **+0.286 ns (CLOSED)** |

ALPHA/PALPHA unchanged (correctly still RMW). The opaque-skip removed enough logic
to close timing at the committed **SEED 10** — seed sweeps were cancelled as moot.

## HW validation (live, Mystery of Solarus DX overworld)
- Deployed `Solarus_20260625.rbf` + matching engine. Overworld renders **clean**
  (screenshot, no corruption → opaque-skip/colormod/writeFSM bit-exact on silicon).
- `[blitter hwperf]` line works end-to-end and cross-checks the host timer
  (`fabric_hw≈host fabric`): menu fps=58.9 fabric=9.9ms **comp=7%**; overworld
  fps=19.9 fabric=36.6ms **comp=75%** — all **FABRIC-bound**.
- A9 never the limiter; its cost is engine C++ (`eng_cpp 7.7ms`), NOT LuaJIT
  (`lua_vm 0.7–2.3ms`) nor emit (~2ms). `pipeline_ceiling ~25–31fps` even if
  double-buffered → the win is INSIDE the compositor.

## OPEN — next levers (not started)
1. **Primary: overlap SRCFILL(span N+1) with composite(N)** via a double-buffered
   `comp_src_linebuf`. WB+SRCFILL are cache-handshake-bound (P_SRC jtframe cache is
   strictly single-request, 3-cyc/hit — read-ahead INFEASIBLE, see memory). Composite
   (W cyc, no P_SRC) hides the next span's serial fetch. Biggest remaining win
   (~20–25% on wide). Delicate span-loop pipelining + linebuf ping-pong.
2. **Secondary: per-frame fabric fixed cost** — `comp%` exposed ~9 ms/frame of
   NON-compositor fabric work on light scenes (ring walk / atlas STAGE / clear).

## Key recipes / gotchas for resuming
- Profiler: `cd fpga/sim && iverilog -g2012 -o /tmp/p.vvp -I ../rtl -I ../rtl/jtframe
  -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_profile.sv
  && vvp /tmp/p.vvp`. Sweepable: `+define+PROF_SRC_LAT/PROF_DST_LAT/COMP_BAND_H/COMP_MAXBURST`.
- Sims: `cd fpga/sim && ./run_sims.sh [tb...]`; gating-failures=0 required. The 2
  non-gating fails (tb_comp_replay, tb_comp_banding_scanout) are pre-existing 30s-cap
  timeouts.
- RBF build: push `fpga/**` → CI (self-hosted Windows Quartus). `gh run download <id>
  -n solarus-rbf` / `-n quartus-reports`. Timing: `Solarus.sta.summary`,
  `general[0].gpll...divclk` = clk_sys (~98.44MHz). RBF builds even with neg slack.
- Engine build: `docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye
  scripts/build_engine.sh` → `build/armhf/`. Copies `patches/mister/*` in. Renderer
  type-check recipe in memory `fpga-renderer-native-typecheck` (but it MISSED C_STATUS
  — Docker build is the real check).
- Deploy: `./deploy.py [--no-rbf] --host 192.168.20.81`. **First** `cp build/armhf/
  {libsolarus.so.1.6.5,solarus-run} deploy/{libs/,}` (deploy/ is stale-prone; device
  engine == build/armhf == 639460ae). deploy.py ships engine from deploy/, RBF from
  newest `_Other/Solarus_*.rbf`.
- **Activate new RBF:** `echo "load_core /media/fat/_Other/Solarus_20260625.rbf" >
  /dev/MiSTer_cmd`. load_core loads fabric but NOT the engine, and transiently clears
  `Solarus.s0` (quest pick). **The USER must relaunch** (OSD/Scripts) — an
  ssh-launched engine DIES on disconnect ("Simulation finished"). Read-only ssh
  (devmem, screenshots via `echo screenshot > /dev/MiSTer_cmd`, log tail) is fine.
- **HW counters via devmem:** `busybox devmem 0x3B00002C` = fabric_busy_cyc,
  `0x3B000034` = pipe_busy_cyc, `0x3B000028` = done_seq, `0x3A070000` = vsync.
  clk_sys=98.4375MHz → ms = cyc/98.4375e6.
- **DIAG on device:** `/media/fat/games/Solarus/diag.env` = `SOLARUS_BLITTER_DIAG=1`
  (created). Engine log → `/media/fat/logs/Solarus/Solarus.diag.log` on next launch.
  grep `blitter hwperf|blitter timing|blitter a9split|blitter luasplit`.

Full state also in auto-memory `fpga-throughput-optimization-arc.md` (+ supporting
notes: `fpga-comp-pipeline-cycle-profile`, `fpga-colormod-pipeline-timing`,
`fpga-psrc-cache-single-request`, `solarus-ssh-launch-dies-on-disconnect`).
