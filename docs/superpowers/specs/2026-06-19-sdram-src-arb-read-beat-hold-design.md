# sdram_src_arb read-beat hold — fix the S_SRC_SDRAM_WAIT wedge (#34)

Date: 2026-06-19
Branch: `feature-sdram-64mb-geometry`
Status: design approved, ready for plan

## Problem

The VRAM-relocation core wedges on HW: the blitter hard-stalls in
`S_SRC_SDRAM_WAIT` (state 31) awaiting an SDRAM **source** read beat that never
arrives. Localized on HW 2026-06-19 via the re-added probe: `probe_st 0x3A070004 =
0xFF01481F` (stuck=0xFF, blt.state=31, `rd_issued=0`, `bs_busy=1`, demux S_IDLE,
`sps_ready=1`). Reproducible on engine **relaunch** (Heisenbug on first boot — the
probe perturbs the fit). Earlier fallback-C work proved the SDRAM DQ read-capture
is innocent (honest STA slack **+2.845 ns**), so this is a **logic/handshake**
defect, not a physical-timing one.

### Root cause (read-completion / owner-release desync)

`sdram_src_arb` is a fixed-priority registered-grant arbiter (SCAN > SRC > DST) in
front of `sdram_psx`. Per-beat read data is routed to the current owner with
owner-gated strobes:

```
assign p0_dready = c_dready & (owner == 2'd2);   // P_SRC beat
assign p0_busy   = (owner != 2'd2) | c_busy;
```

A granted transaction holds `owner`/`held_txn` until **`c_ready`** (controller
line-complete), then re-arbitrates:

```
if (held_txn) begin
   if (just_granted) just_granted <= 1'b0;
   else if (c_ready)  held_txn   <= 1'b0;
end else if (!c_busy) begin ... re-arbitrate SCAN>SRC>DST ... end
```

The defect: `held_txn` (and thus `owner`) can release **before the read's data
beat (`c_dready`) is delivered**. When `c_ready` precedes `c_dready` and a
higher-priority client (SCAN) is requesting, the arbiter re-arbitrates, `owner`
leaves `P_SRC`, and the in-flight beat arrives with `owner != 2` → `p0_dready` is
gated off → **the beat is lost**. The blitter has already dropped `src_sdram_rd`
(it sees a transient `!p0_busy`) and does **not** re-request, so it waits forever
in `S_SRC_SDRAM_WAIT`.

The blitter source path is the only read client that hard-wedges because it does
**not** re-request after dropping its read. The P_DST path survives the identical
hazard only because `vram_demux` re-requests (`S_RDLAT: sd_rd = ~sd_dready`, the
bug2 fix `dc975ff`) — it keeps asking until the beat lands. That is a workaround,
not a guarantee.

## Goal

Make the arbiter deliver every granted **read's** data beat to its client before
releasing the owner — a correct-by-construction read-completion invariant —
removing the wedge and the reliance on client-side re-request.

## Approach (chosen: A — arbiter holds the read owner until the beat is delivered)

In `sdram_src_arb`, do not release a **read** transaction until its data beat has
been routed to the owner. Writes (no return beat) release on `c_ready` as today.

Rejected alternatives:
- **B — full per-transaction valid/ready handshake** across blitter + arbiter +
  demux. Most robust architecturally but touches every client + all
  `p0_*`/`dst_*`/`bs_*` wiring + every TB; memory records prior handshake attempts
  went wrong. Overkill for one missing invariant.
- **C — blitter holds `src_sdram_rd` until the beat.** Keeps `p0_rd` high, so on
  `held_txn` release the arbiter could re-grant SRC and issue a duplicate read, and
  SCAN can still preempt `owner` before the beat. Insufficient + double-read hazard.

## Design

### RTL change — `fpga/rtl/sdram_src_arb.sv`

Add two registers:
- `reg rd_held;`   — set at grant to mark the in-flight transaction as a READ:
  SCAN grant → `1`; SRC grant → `p0_rd`; DST grant → `dst_rd`; (write grants → `0`).
- `reg beat_seen;` — latches `c_dready` while `held_txn`; cleared at each grant.

Change the release condition so a read holds until its beat is delivered:

```
if (held_txn) begin
   if (c_dready) beat_seen <= 1'b1;          // remember the beat arrived
   if (just_granted) just_granted <= 1'b0;
   else if (c_ready && (!rd_held || beat_seen || c_dready))
      held_txn <= 1'b0;                       // write: c_ready; read: + beat delivered
end else if (!c_busy) begin ... re-arbitrate ... end
```

- **Write** (`rd_held=0`): releases on `c_ready` — unchanged behavior.
- **Read**: releases only once the beat is delivered (`beat_seen`, or `c_dready`
  this same cycle). If `c_ready` precedes `c_dready`, `held_txn` now **waits**, so
  `owner` stays fixed and `p0_dready`/`dst_dready`/`scan_dready` (`= c_dready &
  owner==N`) reaches the client. The beat is captured the cycle `c_dready` pulses
  (owner unchanged), and `held_txn` clears the following cycle.
- Set `beat_seen <= 1'b0` and `rd_held <= <read?>` in every grant branch; reset
  both to `0` on `reset`.
- Re-arbitration stays gated on `!c_busy`; the `just_granted` stale-ready mask is
  unchanged. The `c_dready`-this-cycle term in the release covers the case where a
  controller asserts `c_ready` and `c_dready` on the same cycle (registered
  `beat_seen` would otherwise lag one cycle — still correct, just one extra hold
  cycle; the live-`c_dready` term avoids even that).

This is keyed on `rd_held`, so it **hardens all three read clients** (P_SRC, P_DST,
P_SCAN) against the same beat-loss — not just the source path. Cost: at most ~1
extra hold cycle per read.

No changes to `blitter_top.sv`, `vram_demux.sv`, `openbor_video_reader.sv`,
`Solarus.sv` wiring, or any TB port list.

### RED directed sim — `fpga/sim/tb_sdram_src_arb_beatloss.sv` (new)

The faithful full-system sims (`tb_vram_contention`, `tb_blitter_system`, the
disproven `tb_blitter_src_desync`) never reproduced this because the real
`sdram_psx` tends to align `c_ready`/`c_dready`. The directed sim drives
`sdram_src_arb` with a **controller stub** that separates the strobes:

- On a read grant (`c_rd`), the stub asserts `c_ready` (controller line-complete)
  **one or more cycles BEFORE** `c_dready` (the data beat) — the HW separation.
- A **SCAN client requests continuously** (`scan_rd=1`) so the instant `held_txn`
  releases, SCAN is granted and `owner` leaves the read's client before its beat.
- A **P_SRC client** issues a read (`p0_rd`) and, mirroring `blitter_top`
  `S_SRC_SDRAM_WAIT`, drops `p0_rd` on `!p0_busy` and waits for `p0_dready`.

Assertion: the P_SRC client receives a `p0_dready` (with the correct `p0_dout64`)
for its issued read within a bounded window; a watchdog fails on starvation.
- With current RTL → **FAIL** (owner taken by SCAN, `p0_dready` never pulses).
- With Approach A → **PASS**.

Add a second case sweeping the `c_ready`→`c_dready` gap (0..N cycles) and the SCAN
request phase, and a DST-client variant (proves the fix covers P_DST too). Register
in `run_sims.sh` (gating; short bucket). Keep it RED-first: write the test, watch it
fail on current RTL, then apply the fix.

## End-to-end same-class audit (read-completion / beat-delivery / busy-drop desyncs)

Reviewed every handshake in the SDRAM/blitter pipeline of this class
("completion/owner-release gated on the wrong signal, so a beat is lost or a
transaction is mis-accepted"):

| Site | Class instance | Status |
|---|---|---|
| `sdram_src_arb` **P_SRC read** | owner released before beat → beat masked off; blitter doesn't re-request → hard wedge | **FIXED by this design** |
| `sdram_src_arb` **P_DST read** | identical owner-release hazard | latently present; masked today by `vram_demux` re-request (`S_RDLAT sd_rd=~sd_dready`, `dc975ff`). **Now made correct-by-construction** by the same `rd_held` fix (no longer relies on the workaround) |
| `sdram_src_arb` **P_SCAN read** | identical owner-release hazard | latently present; masked today by the reader's per-beat re-issue (`74294bc`). **Now hardened** by the same fix |
| `vram_demux` **S_RDLAT** (dst read) | demux dropping `sd_rd` before beat | already FIXED (bug2, `dc975ff`); complementary to this fix |
| `vram_demux` **S_WWAIT** (partial-write drain) | blitter mis-reads `blt_busy=0` as its read accepted | already FIXED (bug1, `71f5c85`) |
| `vram_demux` **S_BWAIT** + `blitter_top` **S_WR_WAIT** | **WRITE-behind-write**: blitter pipelines the next coalesced flush while the demux drains the prior burst; `blt_busy` drop is mis-read as the new write being accepted → a qword is dropped | **OPEN, SAME CLASS, OUT OF SCOPE here.** This is the write-side twin (surfaced by the dq_ff +1-latency work; the one-line guard broke PHASE2). It needs a per-write **accept** handshake (demux signals "your specific write accepted" ≠ "bus free"). Tracked separately; only manifests under the +1 read-latency that this project is NOT adding. Flagged so it isn't forgotten |
| `blitter_top` **S_RD_WAIT** (dst read via demux) | drops `mem_rd` (per-cycle default L317), relies on demux hold | OK — demux `S_RDLAT` holds; safe |
| `blitter_top` **S_SRC_SDRAM_WAIT** | drops `src_sdram_rd` on transient `!p0_busy`, no re-request | the trigger for the wedge; made harmless by the arbiter fix (owner held until beat). Left as-is (no blitter change) |
| `blt_dout_ready` capture mux (`rd_on_sdram ? sd_dready : ddr_dout_ready`) | single-cycle capture race | DISCONFIRMED earlier (sim + HW `missed_ever=0`); not this class |

**Audit conclusions:**
1. The single `rd_held` arbiter fix closes the SRC wedge **and** removes the latent
   same-class hazard on the DST and SCAN read paths (previously only masked by
   client-side re-request workarounds). This is the right, minimal place to fix the
   whole read side.
2. One same-class issue remains on the **write** path (S_BWAIT / S_WR_WAIT
   write-behind-write). It is out of scope here (it only manifests under the +1
   read-latency we are not adding) but is explicitly tracked so a future
   latency-changing effort addresses it with a per-write accept handshake.

## Validation / done-bar

(User choice: directed-sim repro→green primary, then HW.)
1. **RED**: new `tb_sdram_src_arb_beatloss` FAILS on current RTL (proves the bug).
2. **GREEN**: same sim PASSES after the fix.
3. **No regression**: full suite stays **19/19** — especially `tb_sdram_src_arb`
   (writes + existing reads), `tb_blitter_system` (all phases, write-coalesce),
   `tb_vram_contention` (3-client), `tb_demux_preempt`, `tb_scanout_sdram`.
4. **HW relaunch-soak**: build the probe core, boot mystery with
   `SOLARUS_SDRAM_SRC=1`, and confirm **multiple relaunches run clean** (frame ctr
   `0x3A000000` advancing, probe `0x3A070004` never `0xFF...`, no `0xFF01481F`).
   The probe stays in for this check; strip at #34 close.

## Risks

- **Holding too long / new deadlock.** If a read's `c_dready` never arrives,
  `held_txn` never clears. Mitigation: this matches the controller contract
  (BURST_BEATS=1 → exactly one `c_dready` per read; `sps_ready` follows). The
  directed sim's watchdog + the no-regression suite guard it. Re-arb still gated on
  `!c_busy` so we never issue early.
- **Multi-beat reads.** Today every arbiter read transaction is one beat
  (`sdram_psx` BURST_BEATS=1 instance). `beat_seen` latched on `c_dready` + release
  on `c_ready` is multi-beat-safe (c_ready follows the last beat), so the fix does
  not assume single-beat.
- **Write path unchanged.** `rd_held=0` preserves exact write-release timing — must
  be confirmed by `tb_blitter_system` PHASE write coalescing staying green.

## Out of scope

- The write-behind-write S_BWAIT / S_WR_WAIT per-write accept handshake (tracked above).
- The fallback-C honest-SDC / phase plumbing (already committed; orthogonal).
- Stripping the debug probe (do at #34 close, after this fix is HW-confirmed).
