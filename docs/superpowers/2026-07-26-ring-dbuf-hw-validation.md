# Ring double-buffer — HW validation record (2026-07-26)

PR #154, branch `perf/ring-double-buffer`. Spec:
`docs/superpowers/specs/2026-07-26-ring-double-buffer-design.md` §7.

**Objective legs: ALL PASS. Operator visual gate: PASS (2026-07-26). Flag defaulted ON.**

> **Method caveat, recorded deliberately.** Not one of the "objective legs" below
> inspects a pixel — §1/§2 are fps and cycle counters, §3 counts publishes vs
> displays, §4 reads a counter, §5 checks the engine survived. A fabric
> compositing garbage produces all of those numbers unchanged (or better). These
> legs bound **throughput and liveness only**; correctness rests entirely on §7's
> operator gate and the §8 A/B below. Future levers should pair every objective
> leg with a pixel-level check.

## Build under test

| | value |
|---|---|
| engine `libsolarus.so.1.6.5` | sha1 `b581f44ca8333df46b2fb8a5b2f3a9c076bd7d59` |
| bitstream | `/media/fat/_Other/Solarus_ringdbuf.rbf`, sha1 `eb612b8c6df5a14f0e0edf0ac13bb0c6f7bd54e1` |
| core RBF worst setup slack | **−2.294 ns** vs master **−2.317 ns** (better than master) |

Deployed under a **distinct RBF filename** so the shipping `Solarus_20260726.rbf`
remains untouched as a fallback.

## 1. Compat leg — PASS

`SOLARUS_RINGDBUF` unset, on the **new** bitstream, map 119:
**29.4–30.1 fps** (A9 16.0–17.1 ms, `fabric_hw` 22.55–23.00 ms) against the 31.0 fps
pre-branch baseline. No regression. Banner reports `ringdbuf=off dfq_drop=0`.

## 2. A/B legs — both scenes, same session, same bitstream

### map 119 (parallax, fabric-bound)

| | fps | A9 | `fabric_hw` |
|---|---|---|---|
| `RINGDBUF=0` | 29.4 – 30.1 | 16.0 – 17.1 ms | 22.55 – 23.00 ms |
| `RINGDBUF=1` | **42.3 – 42.8** | 13.9 – 14.6 ms | 22.61 – 22.69 ms |

**+43 %.** Predicted 46.5 fps; the fabric ran slightly heavier in this capture than at
Phase 0 (22.6 vs 21.5 ms — different hero position), and 1/22.6 ms = 44 fps, so the
result matches the model.

### map 3 + dialog held (A9-bound)

| | fps | A9 | `fabric_hw` |
|---|---|---|---|
| `RINGDBUF=0` | 32.2 – 34.3 | 19.2 – 21.9 ms | 16.30 – 16.42 ms |
| `RINGDBUF=1` | **50.3 – 50.8** | 17.0 – 17.1 ms | 16.29 – 16.39 ms |

**+52 %**, slightly ahead of the +47 % prediction.

**`fabric_hw` is identical across both legs of both scenes** (22.6 ms and 16.3 ms
respectively). That is the clean-A/B proof: the fabric performs the same work, and the
gain is purely from overlapping the A9 with it — not from doing less.

## 3. Tear test — PASS

Method follows PR #151: compare frames **published** (`vctrl >> 2`, per
`blitter_top.sv:658` `vctrl = (frame_counter+1) << 2 | active_buf`) against frames
**displayed** (the reader's vsync counter at `0x3A070000`). Run on map 119 with the
flag ON at 43.4 fps, 100 windows:

```
TOTAL published=1472 displayed=1841 windows=100 over_windows=0 max_pub_per_window=17
```

- **Zero windows** where publishes exceeded displays.
- Producer stayed **below** the scan rate overall (1472 vs 1841).
- Max 17 publishes in a ~18-tick window — under one per tick.

## 4. The publish-spacing gate IS firing — and that is the point

`snap_deferred` (`C_STATUS[31:24]`) advanced **144 → 246 in 10 s ≈ 10 deferrals/s**,
roughly 20 % of frames, in ordinary steady-state play.

**Re-measured 2026-07-26, and it is far higher than that:** sampling once per second with
the flag on gave `0x01 → 0x2E → 0x40 → 0x47 → 0x66 → 0xA2 → 0xAE → 0xB2 → 0xF2 → 0x33`
(wrapping) — **~30–60 deferrals/s, i.e. most or every frame**, not 20 %. With the flag off
the counter is frozen (`0xC4` across three consecutive runs), confirming the gate is inert
when `bank_en=0`. So spec §3.5's "steady-state cost: zero / backlog recovery only" is
wrong by a wide margin and has been corrected in the spec itself; the gate routinely
phase-locks publishes to the vsync tick.

This **corrects spec §3.5**, which claims the gate "can only fire during backlog
recovery" with "steady-state cost: zero". It fires routinely — near the cap, publish
jitter alone is enough to land two completions in one scan window. The final-review
note that predicted exactly this was right and the spec's wording was too strong.

Crucially it costs nothing measurable: the flag-on dialog leg is **+52 %** with
`fabric_hw` unchanged. So each of those ~10/s deferrals is the guard doing its job —
holding back a publish that would otherwise have overwritten a buffer mid-scan — for
no throughput penalty. The gate is armed only when `bank_en` is set, so the flag-off
and old-engine paths are unaffected.

## 5. Transition soak — PASS

11 consecutive teleports across `3 → 119 → 12 → 3 → 88 → 119 → 23 → 3 → 40 → 119 → 3`
(the map-load path, which exercises the full pipeline drain before FRT/CFT/CLUT/GRID
rewrites). Engine survived every one. `dfq_drop=0` throughout; no `res_fatal`, no
`scene_too_big`. The 4 `Error:` lines in the log are Lua quest-script complaints
("another dialog is already active") caused by a dialog left open by the test harness —
not defects.

## 6. Harness lessons (cost ~3 false alarms this session)

1. **Every apparent "engine crash" was a harness artefact.** The engine exits
   *cleanly* — a tidy `AL lib: (EE) alc_cleanup` line and **no backtrace** — the moment
   the FIFO write-end holder dies and its lua console hits stdin EOF. Twice this was
   caused by two copies of the same launch script racing, each `rm -f /tmp/sol_in`
   pulling the other's FIFO out from under it. Two engines on the fabric is also the
   known host-wedge condition. **Always confirm a single engine and a live holder
   before reading a code defect into an exit.**
2. **A core reload wipes `/tmp`**, taking the drive script and the FIFO with it.
3. An ssh call that runs past the 120 s tool timeout gets backgrounded; re-running it
   is what produced the duplicate launches. Keep device calls short.

## 7. Operator visual gate — PASS (2026-07-26)

Operator ran the engine on the display with `SOLARUS_RINGDBUF=1` exported into the real
`solarus_run.sh` (no `diag.env`), on `Solarus_ringdbuf.rbf`, single engine, and confirmed
the result good.

**This closes the gate that §6 of the original record left owed**, and is the sole
correctness evidence in this document — see the method caveat at the top.

### 7.1 An earlier "failure" that was NOT one

Before this gate passed, two symptoms were reported: a loading bar apparently starved
during atlas upload, and a game that came up with sound but no visuals or with garbage
tiles. Both were chased and **neither reproduced**. Root cause was environmental —
concurrent agents driving the same device, i.e. the two-engines-on-the-fabric wedge that
harness lesson §6.1 already warns about. The investigation is retained here because the
negative evidence is worth having:

| leg | flag OFF | flag ON |
|---|---|---|
| preload wall time (log marker) | 13.75 s | **13.51 s** |
| preload completion, 3 warm-fabric restarts each | 3/3 | 3/3 |
| `banken` read back from fabric | `0x0` | `0x1` |
| bank-1 `C_CMDCOUNT` | `0xFFFFFFFF` (untouched) | tracks bank 0 |
| submit/done advance | lockstep ~63/s | lockstep ~63/s, no stall |
| map 3 frame, hero frozen at (1090,1338) | 63 distinct colours | 63, top-5 within 0.1 % |

Map-3 frames were captured by dumping the **active DDR3 scanout buffer** through
`/dev/mem` (mmap — `dd` fails on this box) and diffing per pixel: 1.53 % differ,
scattered, consistent with animation phase between two separate runs. `dfq_drop=0`, no
`TL_BUF OVERFLOW`, no `res_fatal`, no `scene_too_big`. Harness scripts left on the device
at `/media/fat/games/Solarus/rdb_{drive,probe,repro,diag,live}.sh` + `fbdump.py`.

**Lesson:** an apparent correctness failure on this device is a harness artefact until a
single-engine, single-agent run reproduces it. That is now the second time this has cost
a session (see §6.1).

## 8. Still watch for

**Animated-tile phase artefacts**, and *only* under the flag: CFT is deliberately left
unprotected (written every frame by `resident_update`, single copy, unbanked and
undrained — a per-frame drain would destroy the entire win). If such artefacts appear,
that is the suspect, and the fix shape is a **banked CFT**, never a per-frame drain.

**Engine/RBF pairing.** `OFF_HEAP` moved `0x80000`→`0x100000` unconditionally, so
`SOLARUS_RINGDBUF=0` is *not* an old-RBF rollback — the pair rolls back together. There is
no version handshake, so a mismatch degrades silently to garbage tiles rather than
failing loudly. Adding one is the obvious follow-up; it needs RTL, so it is not in this PR.
