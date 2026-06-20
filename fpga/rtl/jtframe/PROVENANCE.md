# jtframe SDRAM Vendor Provenance

## Source

- **Upstream repo:** https://github.com/jotego/jtcores (local mirror at `/Users/gmcnaught/MisterFPGA-Projects/jtcores`)
- **Upstream path:** `modules/jtframe/hdl/sdram/`
- **Commit hash at time of copy:** `32c81d1f2253f333282be52143baa84d129b9cdc`
- **Date vendored:** 2026-06-20

## Vendored Files

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

## Chip Model

`mt48lc16m16a2.v` is vendored separately into `fpga/sim/` from:
`modules/jtframe/hdl/ver/mt48lc16m16a2.v` — same upstream repo and commit.

## Regeneration

To refresh these files from upstream:
```bash
JT=/path/to/jtcores/modules/jtframe/hdl/sdram
cd fpga/rtl/jtframe
for f in jtframe_burst_sdram jtframe_burst_mode jtframe_burst_ctrl jtframe_burst_mux \
         jtframe_burst_io jtframe_sdram64_init jtframe_sdram64_rfsh jtframe_sdram64_bank; do
  cp "$JT/$f.v" "$f.v"
done
```
**Do not hand-edit vendored files.** Patch upstream and re-copy.

## Notes

- `jtframe_burst_io` uses `assign sdram_dq = dq_pad` with `dq_pad` initialized to
  `16'hzzzz` on reset and driven to `16'hzzzz` when `next_dq_oe_r == 0`. This is
  correct tristate simulation behavior for iverilog; no special handling required.
- No additional `include` files were needed — all macros/ifdefs used (`VERILATOR`,
  `SIMULATION`, `JTFRAME_SDRAM_DEBUG`) have safe defaults when undefined.
