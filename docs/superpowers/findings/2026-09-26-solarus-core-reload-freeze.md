# Solarus core reload: DDR3 freeze (2026-09-26, .81)

Found during the mister-hybrid-platform migration (branch `platform-migration`).
Not caused by the migration: it reproduces with the stock `/media/fat/MiSTer`,
no `main=`, no engine and no mem_wc loaded.

## Root cause (resolved 2026-09-26, RBF `Solarus_20260926.rbf`, commit dc760d7)

A DDR3 **write burst left partly delivered on the HPS f2sdram port**. The port
then waits for write data that never arrives. `fpgaportrst` does not clear it,
so every later core on that port writes nothing to DDR3 until the HPS reboots.
Verified across bitstreams: in the frozen state the OpenBOR core (engine
stopped) also stops rewriting JOY0 at `0x3A000008` every frame, which it does
on a healthy boot.

How the burst gets cut: Main asserts the core reset while the fabric is
streaming 80-beat snapshot writes. The core sees `reset` directly;
`f2sdram_safe_terminator` sees it double-registered (sysmem.sv), 2 cycles
later. All of the core's DDR masters sit on RESET and drop `write`
immediately. The upstream terminator counts every non-waitrequest cycle of a
burst as a beat (`state_write && !waitrequest`), so it counts those cycles,
judges the burst finished early, and sends too few dummy beats. Its
termination also stopped on the count alone, dropping the last beat whenever
waitrequest was high.

Why it looked random: an idle fabric (C_DONE == C_SUBMIT) issues only
single-beat polls, so a core switch is safe. A switch wedges the port only
while bursts are in flight, which means a live game or a **runaway fabric**.
Every freeze in the table below came right after a runaway session.

The same terminator also had the reset-**exit** hole that the Maldita fork
already fixed: the core leaves reset about 3 cycles before the terminator
unlocks, and a read issued in that window is "accepted" and then dropped.
After reconfiguration the core runs for a couple of cycles before the reset
latches, so the terminator is armed at every core start. A dropped blitter
read leaves `ddr_blitter_arb` in G_BLT_RD indefinitely, and the reader never
publishes vsync. That matches the main= first-load freeze with vsync 0.

### Evidence (.81, stock Main 260912, kernel 6.18.38)

| Test | Old RBF (0818) | Fixed RBF (0926) |
|---|---|---|
| Runaway forced (C_SUBMIT=0x7FFFFFFF, CMDCOUNT 0), still running at the core switch | next load frozen, 3/3 | 0/6 frozen |
| Same runaway, quiesced (C_SUBMIT = C_DONE+200) before the switch | 0/4 frozen | — |
| Idle reload loop, ctrl zeroed at MENU | spontaneous runaway ~1 in 5 loads, each followed by a freeze | 0/15 runaways, 0 freezes |
| main=MiSTer_hybrid: load, OSD pick, engine to "Simulation started", switch to MENU mid-game | first load frozen (run C) | 5/5 booted with C_SUBMIT/C_DONE/vsync advancing, 0 wedges |

Sim: `fpga/sim/tb_f2sdram_terminator_reset.sv` sweeps the reset cycle over
back-to-back 80-beat bursts (waitrequest 0/30/60 %, gaps 0/25 %). Old logic
leaves the port mid-burst 2370/2400 times, fixed logic 0/2400.

### Still open

- **Unrequested read beats.** `0x3A070004` now carries the arbiter's health
  word: `[31:16]` counts drift_clr firing with beats still owed, `[15:0]`
  counts read beats arriving with nothing outstanding for the grant holder.
  drift_clr stayed at 0 in every run. The orphan count is 0 on idle sessions
  but reaches 0x10–0xE1 per ~20 s of gameplay. The counter definition has not
  been sim-checked against legitimate beat timing yet, so check it before
  treating this as a defect. It is the remaining candidate for the old
  spontaneous runaway, which did not recur in 15 loads.
- **Timing.** The 0926 build fails setup on `comp_src_linebuf -> s3_cm_pb`
  (colormod), clk_sys TNS -2.139, which looks like placement roulette. Tinted
  draws are not visually validated on it. A ship build needs a seed sweep.
- The GM-fabric cores (Maldita fork terminator) have the reset-exit fix but
  not the write-burst fix.

## Symptom

After a Solarus core load:

- The scanout vsync counter at `0x3A070000` stops advancing. The OpenBOR
  reader writes it every vblank, so the core is not writing DDR3 at all.
  Some freezes read `0x00000000`, meaning the counter never started.
- `C_DONE` (`0x3B000028`) stays fixed. An engine that is running keeps
  advancing `C_SUBMIT` (`0x3B000000`) and hangs in its asset preload
  ("preload prune" is the last log line; "Simulation started" never comes).
- The state persists. Every later Solarus load freezes the same way, under
  any Main binary, until the device reboots. dmesg shows nothing.

A related mode: `C_DONE` runs past `C_SUBMIT` and keeps counting. Here the
fabric executes a stale ring from a control block left in DDR3. The control
block survives core loads and warm reboots. The engine hangs in preload, and
the launcher's fabric gate reads "advancing" and passes. Zeroing both
control blocks (`0x3B000000`, `0x3B080000`, 64 B each) while MENU is loaded
prevents this mode; `Scripts/Solarus.sh` does that (dist/scripts-extra.sh).
It does not prevent the freeze.

## Environment

- DE10-Nano .81, kernel `6.18.38-MiSTer`, stock Main release 20260912
  (`/media/fat/MiSTer`, "260912").
- Core `_Other/Solarus_20260818.rbf`, loaded through `_Other/Solarus.mgl`
  (`<rbf>_Other/Solarus</rbf>`) or the RBF path directly.
- Engine: shipping `solarus-run`, 2026-09-24 build (md5 bd4a7e2b...).
  Not needed for the repro.

## Repro recipe ("run A")

With `games/Solarus/NOENGINE` present, and no `main=` line in `[Solarus]`
(or `main=` commented out), so that nothing but the core runs:

1. Reboot the MiSTer and wait for MENU.
2. `echo "load_core /media/fat/_Other/Solarus.mgl" > /dev/MiSTer_cmd`,
   wait 10 s, then read `busybox devmem 0x3A070000 32` twice, 1 s apart.
3. `echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd`, wait 6 s.
4. Repeat steps 2–3. Frozen = the two reads are equal.

Observed, each sequence starting from a fresh reboot, no engine in any of them:

| Sequence | Loads (OK / FROZEN) | Notes |
|---|---|---|
| A: no main= | OK, FROZEN | after load 1, ctrl read `C_SUBMIT=0 C_DONE=0x17489`: the fabric ran with no engine |
| B: ctrl zeroed at MENU before each load | OK (no main=), OK (no main=), OK (main=stock), FROZEN (main=stock) | |
| C: main=MiSTer_hybrid (3380931), engine + pick, ctrl zeroed | FROZEN on the first load (vsync 0) | |
| Earlier, stock, Scripts start + engine | 3 of 3 OK, then 4 of 4 OK in the A/B | after a clean reboot |

Rate: roughly 1 in 2–4 reloads once a device has done a few loads. First
loads after a clean reboot were OK under stock Main 3 of 3 times; under
MiSTer_hybrid, 0 of 1.

## Ruled out

- **Launcher / platform path:** reproduces with nothing but Main and the core.
- **main= re-exec and the hook build:** reproduces without main=. Builds
  from both 3380931 and 47221c1 (20260912) freeze.
- **mem_wc:** not loaded in run A (`lsmod` empty). When loaded, its window
  is `0x3B000000+0x01200000` from both the old and new launchers, exactly
  the solarus-fabric profile's `[mem_wc]`.
- **Stale control block alone:** B zeroes it before every load and still froze.

## Where to look next

- Fabric reset: does `blitter_top` / `ddr_blitter_arb` start issuing DDR3
  (f2sdram) transactions before reset is released, or act on the DDR3
  control block before the engine sets an origin? A burst that is
  outstanding when the FPGA is reconfigured would leave the HPS port hung,
  which would explain why the hang persists across loads until reboot.
- Kernel 6.18 vs 5.15: whether the FPGA-to-SDRAM bridge ports are reset on
  reconfiguration (`fpga2sdram` reset / `fpgaportrst`).
- The GM-fabric core wedged similarly on .62 during the same session
  (C_SUBMIT = C_DONE, core reloads don't clear it). This points to a
  device/kernel/bridge problem shared by the fabric cores.
- Fabric init should ignore the DDR3 control block until the engine writes
  an origin (instead of relying on zeroing at MENU).
