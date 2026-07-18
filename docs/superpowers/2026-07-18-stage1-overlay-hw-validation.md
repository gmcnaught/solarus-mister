# Stage 1 — Overlay channel: HW validation record

**Date:** 2026-07-18
**Device:** MiSTer @ 192.168.20.81, core `Solarus_20260713.rbf`, quest Mystery of Solarus DX
**Branch:** `feat/retained-scene-stage1-overlay` (11 commits, unmerged)
**Engine:** armhf container build, `mpix::to_argb4444_unpremultiplied` + `mister_tag_root_surface`
verified present in the deployed `libsolarus.so.1.6.5` (on-device sha1 `d5b154c7…`).

## Verdict

**Accepted with a known residual.** Operator judgement: the overlay-ON path is the least-bad of
the two currently available. One new defect filed (#124). `SOLARUS_OVERLAY` remains **default OFF**
pending a decision on the flip.

## Objective signals (overlay ON, gameplay scene)

| Signal | Value | Reading |
|---|---|---|
| `[blitter overlay]` | `draws=480 composites=60 dropped=0` | 8 UI draws/frame routed, exactly 1 composite/frame, **zero drops** |
| `reup` | 60 | 1 dirty re-upload/frame, as designed |
| `escape` / `overflow` | 0 / 0 | No unexpressible ops, no ring overflow |
| `target_locked` | 1 | Root tag working (read 0 permanently before the Task 1 fix) |
| `perf_frame_cyc` | `0x190D50` = 1,641,296 cyc | ≈16.7 ms @ 98.44 MHz — frame-paced |
| `perf_pipe_cyc` | `0xF03D3` = 984,019 cyc | ≈10.0 ms compositing, ~60% of frame |

### A/B against `SOLARUS_OVERLAY` absent

| | OFF | ON |
|---|---|---|
| `blits` (root draws → fabric) | 420 | 0 |
| `[blitter overlay] draws` | — | 480 |
| `fills` | 60 | 60 |
| `[blitter p0]` blend histogram | `NONE=120 BLEND=900 ADD=0 MUL=0` | — |

7–8 root draws/frame move cleanly from the fabric path to the overlay path. Rerouting is healthy.

> **Flag is presence-based** (`getenv(...) != nullptr`): `SOLARUS_OVERLAY=0` still ENABLES it.
> It must be **absent** to disable. The A/B baseline was taken with the line removed from `diag.env`.

## Operator visual observations

| Scene | Verdict |
|---|---|
| **Intro screen** | Visually verified OK — a design-goal case (previously in the "not offloaded → vanishes" class) |
| **Parallax room** | Visually verified OK |
| **Scroll transition** | "Might have been fine" — **not a confirmation**; see below |
| **Translucent menu** | **Under-dims** the still-visible overworld (issue #124) |
| **Same menu, overlay OFF** | **Over-dims** — "definitely too dark" |

## What is NOT established

- **#122 (bgplane hold frame on scroll) and #123 (scroll-path black frame) are NOT verified fixed.**
  The design predicted Stage 1 would structurally delete both. Scroll transitions were observed
  only in passing ("might have been fine"). Both issues stay OPEN and unmeasured; closing them
  requires a deliberate scroll-transition A/B.
- **The premultiply correctness question is unresolved**, not passed. Menus visibly under-dim
  (#124). Two hypotheses were refuted by data (draw-vs-fill reordering; a destination-reading
  blend the overlay can't express — the `p0` histogram shows no MULTIPLY/ADD at all). Two
  candidates remain untested: ARGB4444 alpha truncation `(a>>4)` always rounding down (up to
  6.7% low → systematically less dimming), and the un-premultiply over-brightening RGB.
- **Map transitions and Lua-created surfaces** (HUD/dialogs/menus beyond the one menu observed)
  were not systematically A/B'd, despite the un-premultiply fix reaching every
  `Surface::create(w,h)`.

## Process notes worth keeping

- **Two concurrent engines make the host mostly unresponsive.** Writing the quest pick to
  `Solarus.s0` before `load_core` arms `quest_manager`'s auto-launch; launching manually as well
  gives two `solarus-run` processes on the fabric. Operator restarted the device. Safe recipe:
  leave `Solarus.s0` empty, load the core, then launch with a private `S0_FILE` override.
- **Log to `/media/fat/logs/Solarus/`, never `/tmp`** — a restart wipes `/tmp` and destroys the
  evidence of the run being diagnosed. Also: the lua-console path `exec`s with its own redirect to
  `Solarus.diag.log`, so engine output does not land in the shell log you redirected.
- **Do not blind-inject joypad input.** Hammering confirm walked a menu into quit, and later
  navigated the MiSTer OSD into loading an unrelated core.
- **`deploy.py` exit 0 says nothing about which files moved.** A run reported success having
  updated only `solarus-run`; the library was still the previous day's build because it was copied
  to `deploy/` root instead of `deploy/libs/`. Always sha1-verify on device.
- **`build_engine.sh` runs inside the container** — `scripts/docker_run.sh bash scripts/build_engine.sh`.
  Running it on the host produces a host-path `CMakeCache.txt` that then blocks the container build.

## Device state left

Engine running with overlay ON. Added: `/media/fat/games/Solarus/diag.env` (delete to revert) and
`/tmp/overlay_s0`. The real `/media/fat/config/Solarus.s0` is left **empty** so nothing auto-launches.

## Refs
- Plan: `docs/superpowers/plans/2026-07-18-retained-scene-stage1-overlay-channel.md`
- Design: `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md`
- Issue #124 — overlay under-dims translucent menus
- Issues #122 / #123 — scroll-transition items, still open and unverified
