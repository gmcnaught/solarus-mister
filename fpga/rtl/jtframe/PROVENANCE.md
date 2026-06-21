# jtframe SDRAM Vendor Provenance

## Source

- **Upstream repo:** https://github.com/jotego/jtcores (local mirror at `/Users/gmcnaught/MisterFPGA-Projects/jtcores`)
- **Upstream paths:** `modules/jtframe/hdl/sdram/` and `modules/jtframe/hdl/ram/`
- **Commit hash at time of copy (burst_sdram stack):** `32c81d1f2253f333282be52143baa84d129b9cdc`
- **Commit hash at time of copy (cache stack):** `03176bfd1c32ffa2b137df50c63fca64f4018fbd`
- **Date burst_sdram vendored:** 2026-06-20
- **Date cache stack vendored:** 2026-06-21

## Vendored Files — burst_sdram stack

| File | Purpose |
|------|---------|
| `jtframe_burst_sdram.v` | Top-level burst SDRAM controller |
| `jtframe_burst_io.v` | IO pad stage (two-stage pipeline; DDIO/tristate DQ handling) |
| `jtframe_burst_ctrl.v` | Burst state machine (ACT / TRCD / READ / WRITE / PRE) |
| `jtframe_burst_mux.v` | Mux between init / mode / refresh / prog / burst paths |
| `jtframe_burst_mode.v` | Mode register write sequencer (switches BL on prog_en toggle) |
| `jtframe_sdram64_init.v` | SDRAM power-on initialisation sequence |
| `jtframe_sdram64_rfsh.v` | Auto-refresh arbiter |
| `jtframe_sdram64_bank.v` | Per-bank open-row state machine (used by prog path) |

## Vendored Files — cache stack (commit 03176bfd1c32ffa2b137df50c63fca64f4018fbd)

Dependency tree: `jtframe_cache.sv` → {`jtframe_cache_ctrl.sv` → `jtframe_cache_req.sv`,
`jtframe_cache_data.sv` → `jtframe_dual_ram16.v` + `jtframe_dual_ram32.v`,
`jtframe_cache_tags.sv` → `jtframe_dual_ram.v`}; plus `jtframe_cache_mux.v` +
`jtframe_cache_mux_arb.v` + `jtframe_cache_mux_flush.v`.

| File | Source path | Purpose |
|------|-------------|---------|
| `jtframe_cache.sv` | `hdl/sdram/` | Top-level cache (BLOCKS/BLKSIZE/AW/DW/EW parameterised) |
| `jtframe_cache_ctrl.sv` | `hdl/sdram/` | FSM: lookup/fill/writeback/flush/invalidate |
| `jtframe_cache_req.sv` | `hdl/sdram/` | Rising-edge request capture + pending queue |
| `jtframe_cache_data.sv` | `hdl/sdram/` | Data RAM mux (16/32/64/128-bit width) |
| `jtframe_cache_tags.sv` | `hdl/sdram/` | Tag RAM (valid/dirty/tag per way/set) |
| `jtframe_cache_mux.v` | `hdl/sdram/` | Multi-client cache mux (top) |
| `jtframe_cache_mux_arb.v` | `hdl/sdram/` | Arbitration for cache_mux |
| `jtframe_cache_mux_flush.v` | `hdl/sdram/` | Flush coordination for cache_mux |
| `jtframe_dual_ram.v` | `hdl/ram/` | Single-port dual-clock RAM (used by cache_tags) |
| `jtframe_dual_ram16.v` | `hdl/ram/` | 16-bit dual-port RAM (used by cache_data DW<32) |
| `jtframe_dual_ram32.v` | `hdl/ram/` | 32-bit dual-port RAM (used by cache_data DW>=32) |

Do not hand-edit vendored files; regenerate by re-copying from upstream.

## Chip Model

`mt48lc16m16a2.v` is vendored separately into `fpga/sim/` from:
`modules/jtframe/hdl/ver/mt48lc16m16a2.v` — same upstream repo and commit.

## Regeneration

To refresh burst_sdram stack:
```bash
JT=/path/to/jtcores/modules/jtframe/hdl/sdram
cd fpga/rtl/jtframe
for f in jtframe_burst_sdram jtframe_burst_mode jtframe_burst_ctrl jtframe_burst_mux \
         jtframe_burst_io jtframe_sdram64_init jtframe_sdram64_rfsh jtframe_sdram64_bank; do
  cp "$JT/$f.v" "$f.v"
done
```

To refresh cache stack:
```bash
JT=/path/to/jtcores/modules/jtframe/hdl
cd fpga/rtl/jtframe
for f in jtframe_cache jtframe_cache_ctrl jtframe_cache_req jtframe_cache_data jtframe_cache_tags; do
  cp "$JT/sdram/$f.sv" "$f.sv"
done
for f in jtframe_cache_mux jtframe_cache_mux_arb jtframe_cache_mux_flush; do
  cp "$JT/sdram/$f.v" "$f.v"
done
for f in jtframe_dual_ram jtframe_dual_ram16 jtframe_dual_ram32; do
  cp "$JT/ram/$f.v" "$f.v"
done
```
**Do not hand-edit vendored files.** Patch upstream and re-copy.

## Notes

- `jtframe_burst_io` uses `assign sdram_dq = dq_pad` with `dq_pad` initialized to
  `16'hzzzz` on reset and driven to `16'hzzzz` when `next_dq_oe_r == 0`. This is
  correct tristate simulation behavior for iverilog; no special handling required.
- No additional `include` files were needed — all macros/ifdefs used (`VERILATOR`,
  `SIMULATION`, `JTFRAME_SDRAM_DEBUG`) have safe defaults when undefined.
