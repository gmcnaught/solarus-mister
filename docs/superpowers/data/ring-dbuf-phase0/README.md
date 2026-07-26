# Phase 0 — ring double-buffer sizing captures (2026-07-26)

Gate for the RTL work in `docs/superpowers/specs/2026-07-26-ring-double-buffer-design.md` §2.
**Verdict: GO** (three of four scenes predict ≥ +15 %; two predict ~+50 %).

## Setup

- Device 192.168.20.81, core `Solarus_20260726.rbf`, quest Mystery of Solarus DX.
- Engine: **freshly cross-built from master this session**, `libsolarus.so.1.6.5`
  sha1 `ad5793778ec8bff6ecef3451e99930c7c7cf6fc8`, deployed engine-only.
- `diag.env`: `SOLARUS_BLITTER_DIAG=1`, `SOLARUS_LUACONSOLE=0` (stdin lua console).
- Driven over a held-open FIFO (`/tmp/sol_in`), save1 loaded, teleports by map id.
- Raw banner lines: `banners-raw.txt` (whole session, contaminated run included —
  see the trap below; the numbers in the table are from the clean run only).

### Trap hit and corrected — read this before re-running

The engine **already deployed on the device was PRE-#151** (no `SOLARUS_VSYNC_BARRIER`
string in the shipped `libsolarus.so.1.6.5`; the retired vblank barrier was still
running: `fastpace=on skips=8..12/60`, `sleep=11-14 ms`). Measuring against it would
have reproduced exactly the barrier contamination PR #151 warned about — map 3 read
**31.5 fps** instead of its true **55.7 fps**.

Two further traps in the same loop:
1. `deploy.py` **deletes `diag.env` on every deploy** — the first post-deploy launch
   silently ran with no diagnostics and no lua console (`lua-console=no`). Recreate
   `diag.env` *after* deploying.
2. `deploy/libs/` held a **stale** `libsolarus.so.1.6.5` (`ca3331a2…`) while
   `build/armhf/` had the fresh one — `deploy.py` ships from `deploy/`, so refresh it
   from `build/armhf` and verify by sha1 (the known stale-artifact trap).

## Measurements (clean run, post-#151 pacing, `skips=0/60`)

`A` = A9 busy (banner `A9=`), `F` = fabric busy from the fabric's own clk_sys counter
(`[blitter hwperf] fabric_hw=`, the on-silicon ground truth — **not** the banner's
`fabric=`, which is only the host-polled residual wait).

Predicted pipelined period = `max(A, F, 16.69 ms)` (16.69 ms = the `present()` cap at
the core's real 59.9237 Hz). Predicted added latency = `max(0, F − A)`.

| scene | fps now | period | A | F | pred. period | **pred. fps** | **gain** | latency add |
|---|---|---|---|---|---|---|---|---|
| map 3, standing | 55.7 | 17.9 ms | 9.8 | 13.0 | 16.69 ms (cap) | 59.9 | +7.5 % | **0** (cap-limited) |
| map 3 + dialog held | 39.4 | 25.4 ms | 17.3 | 14.4 | 17.3 ms | 57.9 | **+47 %** | **0** (A ≥ F) |
| map 119 parallax | 31.0 | 32.3 ms | 16.4 | 21.5 | 21.5 ms | 46.5 | **+50 %** | 5.1 ms |
| map 119 + dialog | 33.4 | 30.0 ms | 15.4 | 19.6 | 19.6 ms | 51.0 | **+53 %** | 4.2 ms |

Each row is the mean of the last two 60-frame banner windows in a ≥ 10 s steady hold.

## Reading

- **The two halves are now genuinely balanced** (A 9.8-17.4 ms vs F 13.0-21.5 ms), which
  is precisely the condition the PR #54-era "ring double-buffer is dead" conclusion
  lacked — that verdict held only while heavy scenes were A9-bound with an idle fabric.
  It is now stale, as the spec's Appendix A records.
- **Dialog is A9-bound** (A 17.3 > F 14.4) and **map 119 is fabric-bound** (F 21.5 > A 16.4).
  A single lever that overlaps the two halves is the right shape for both — neither an
  A9-only nor a fabric-only lever helps both scenes.
- **The banner's own `pipeline_ceiling` understates this lever** because it adds the
  *old* sleep on top of `max(A9, fabric)`. Use the formula above instead.

## Latency answer (spec §6)

No scene reaches or exceeds the ~60 fps cap, so the "scenes achieving 100 fps" case does
not exist on this hardware — the `present()` cap holds the producer just under 59.92 Hz.

- **Cap-limited scenes** (map 3 standing): the queue never forms; the A9 is released by
  the cap long after the fabric finished. **Zero added latency.**
- **A9-bound scenes** (dialog): `F − A` is negative, so **zero added latency** — and
  +47 % fps.
- **Fabric-bound scenes** (map 119): **+5.1 ms** worst case measured, while the frame
  period drops 32.3 → 21.5 ms. Bounded at one in-flight frame by the `C_DONE ≥ S−2`
  fence, structurally.

## Go/no-go

**GO.** Three scenes clear the ≥ +15 % bar with large margin; the fourth is already at
the cap and loses nothing. Predicted post-lever: dialog ~58 fps, map 119 ~46-51 fps.
