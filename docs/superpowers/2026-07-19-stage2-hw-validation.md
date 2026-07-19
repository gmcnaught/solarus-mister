# Stage 2 — Sprite channel (`OP_SPRITELIST`): HW validation record

**Date:** 2026-07-19
**Device:** MiSTer @ 192.168.20.81, core **`Solarus_20260719.rbf`**, quest Mystery of Solarus DX
**Branch:** `feat/retained-scene-stage2-spritech`
**Session end:** cut short — another core was inadvertently started from the OSD, so the
engine was stopped. **The session is INCOMPLETE** (see "What is NOT established").

## Verdict

**Mechanically healthy; visually unvalidated.** The channel and the new fabric op ran clean
across ~16,000 frames with zero drops, zero overflow, zero escapes. **No visual verdict was
recorded**, and the planned A/Bs did not happen. Nothing here establishes correctness of
pixels. `SOLARUS_SPRITECH` stays **default OFF**.

## Deployed artifacts (on-device sha1, all verified against local)

| Artifact | sha1 |
|---|---|
| `solarus-run` | `fb9d2f1fc39747bd3c4ac66ac94dc9794c2b06cb` |
| `libsolarus.so.1.6.5` | `ef07e197cf51749d35b5dbe32c4a233c8178e65f` |
| `Solarus_20260719.rbf` | `c3e7a714ae410ff6843e266b29a6c0c0218db24b` |

RBF built by CI run `29702887930` at commit `d4934ec`. The only `fpga/` change since is
`5afe1a3`, entirely inside `` `ifdef FABRIC_ASSERT `` (sim-only, never set by synthesis), so
the bitstream is functionally identical to branch HEAD.

Engine confirmed to carry the Stage 2 code: `SOLARUS_SPRITECH`, `blt_sprite_channel_push`,
`blt_sprite_list`, `sprite_channel_flush` all present in the deployed library.

Flags in effect, from the engine's own log:
```
[MiSTer blitter] overlay channel ENABLED (SOLARUS_OVERLAY)
[MiSTer blitter] sprite channel ENABLED (SOLARUS_SPRITECH)
```

## Objective signals — 266 windows × 60 frames ≈ 15,960 frames

| Signal | Value | Reading |
|---|---|---|
| `spr_drop` | **0** across 218,272 sprites | cap never reached; `SP_BUF` never exhausted |
| `dropped` (ring overflow) | **0**, every window | no commands silently lost |
| `overflow` / `escape` | **0** / **0** | nothing unexpressible, no ring overflow |
| `[blitter inter] used` | peak **0.75 / 4.00 MiB**, `leaked=0` | see §Arena |
| `sprite_blits` | **0** | correct: the SPRITECH-off counter, inactive while the channel is on |

The fabric executed opcode 10 across ~16,000 frames without escape or overflow — the RTL is
live and stable. **This says nothing about what it drew.**

## The sprite cap — CLOSED with a measured number

| | sprites/frame |
|---|---|
| **Peak observed** | **122.6** |
| Mean | 13.7 |

The figure this plan inherited (~450/frame, from `alias_blits=27039`) was **unsourced** and
is high by ~4×. The shipped cap (4096/flush; `SP_BUF` holds 5461/frame at 24 B) has **~44×
headroom** over the observed peak. Design §8's open item is closed — *for the scenes visited
this session*, which did not include the parallax room (see gaps).

## Collapse ratio — the batching win, by scene load

`spr_rec / spr_runs` = sprites per emitted `OP_SPRITELIST` command.

| Scene load | Windows | Sprites/frame | Ratio (mean) | Ratio (max) |
|---|---|---|---|---|
| **Busy** ≥30/fr | 38 | 56.8 | **9.38×** | 26.14× |
| Mid 5–30/fr | 70 | 14.3 | 2.54× | 6.59× |
| Light <5/fr | 154 | 3.1 | 1.01× | 1.32× |
| **Aggregate** | 262 | — | **3.25×** | — |

**Read this by load, not by median.** The all-window median ratio is 1.00 and 53% of windows
show no batching — but those are *light* windows averaging 3.1 sprites/frame, where there is
nothing to batch and nothing to gain. Where load exists, batching scales with it. That is the
desirable shape: the mechanism costs nothing when idle and pays 9–26× when busy.

### Hypothesis for the light-scene ratio of 1.0 — NOT verified

A run breaks when any shared header field changes: `src_stride`, `format`, `blend`, `alpha`,
`colorkey`, `flags`. **`src_stride` is per-sprite-sheet**, and sprites are Y-sorted across many
sheets, so consecutive sprites routinely differ in stride and break the run even when
everything else matches.

If that is the dominant cause, the fix is cheap: the 24-byte entry has a spare `_rsvd` u16
that could carry `src_stride` per entry, leaving runs to break only on
format/blend/alpha/colorkey/flags. **Do not act on this without evidence** — the log records
that runs broke, not *why*. Attributing it needs a small diagnostic counting break causes by
field. Note the same reasoning already moved palette per-entry in Task 4b, so there is
precedent that header-shared fields are the binding constraint.

## Arena

`[blitter inter]` peaked at **0.75 / 4.00 MiB** with `leaked=0`. This is the first time INTER
occupancy has been observable at all — the 4 MiB sizing previously rested on an uncited
"~2 MiB working set (measured)" comment. The measured peak here is well under both that claim
and the region size. Not conclusive for Stage 3's scratch-arena sizing: this session did not
visit the heaviest scenes.

## What is NOT established

- **No visual verdict of any kind.** No operator observation of sprite rendering was recorded
  before the session ended. Counters cannot establish this: Stage 1 reported
  `draws=480 composites=60 dropped=0` while visibly under-dimming menus (#124).
- **No `SOLARUS_SPRITECH=0` A/B.** The planned sanity check — `spr_rec` (on) ≈ `sprite_blits`
  (off), same sprites routed differently — was not captured. Without it, "the same sprites are
  being routed" is inferred, not shown.
- **#122 / #123 not assessed.** No scroll-transition A/B was recorded. Both remain OPEN and
  unmeasured, as they have been since Stage 1. (Note: Stage 2 is gated behind
  `!g_transition_scroll`, so that A/B measures the software fallback, not this channel.)
- **Heaviest scenes not visited.** The parallax room and town — the two busiest on record —
  were not confirmed visited. Peak 122.6 sprites/frame is a floor on the true worst case, not
  a ceiling. The cap has enormous headroom either way, but the census is not complete.
- **Frame-rate / perf impact unmeasured.** No `perf_frame_cyc` / `perf_pipe_cyc` comparison
  was taken, so whether the 3.25× command reduction moves fps is unknown.

## Process notes

- **Another core was started from the OSD mid-session**, ending the run. This is the second
  time OSD navigation has disrupted a validation session (Stage 1: hammered input walked a
  menu into quit, then into loading an unrelated core). Worth treating OSD interaction as a
  hazard during validation.
- **Both RBFs remain on the device** (`Solarus_20260713.rbf` = old, no `sprite_unit`;
  `Solarus_20260719.rbf` = correct). Loading the old core with `SOLARUS_SPRITECH=1` would send
  opcode 10 to fabric with no arm for it — it falls through the decode chain to the default
  FILL/BLIT branch where `c_w`/`c_h` hold the *entry count*, producing visible garbage that
  would look like a Stage 2 bug. **Confirm the core before the next session.**
- `diag.env` now ships via `deploy.py --diag` and is sourced on presence alone; the launcher
  echoes the flags in effect, which is how this session proved SPRITECH was actually on.
- Raw log preserved at `docs/superpowers/stage2-hw-2026-07-19/Solarus.diag.log`
  (1,515,256 bytes, pulled before the device was disturbed).

## Device state left

Engine stopped. `/media/fat/config/Solarus.s0` does not exist, so nothing auto-launches.
`diag.env` present with `SOLARUS_BLITTER_DIAG=1` + `SOLARUS_SPRITECH=1` — delete it, or launch
with `SOLARUS_NO_DIAG_ENV=1`, to revert to a pristine run.

## Refs

- Plan: `docs/superpowers/plans/2026-07-19-retained-scene-stage2-sprite-channel.md`
- Design: `docs/superpowers/specs/2026-07-19-retained-scene-stage2-sprite-channel-design.md`
- Baseline fitter/STA: CI run `29701340705`; post-RTL: `29702887930`
- Issues #122 / #123 (still open, still unmeasured), #124 (Stage 1 residual)
