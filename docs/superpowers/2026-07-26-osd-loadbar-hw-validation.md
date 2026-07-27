# OSD-style loading bar — HW validation

**Date:** 2026-07-26
**Branch:** `feat/osd-style-loadbar`
**Plan:** `docs/superpowers/plans/2026-07-26-osd-style-loading-bar.md`
**Spec:** `docs/superpowers/specs/2026-07-26-osd-style-loading-bar-design.md`
**Result:** **PASS** — operator visual gate passed, no geometry tuning needed.

## What shipped

Engine-only. No RTL, no new RBF. The `#72` progress bar was restyled from three
`blt_fill` rects (black clear, 200×12 grey track, white fill) to a MiSTer
OSD-style panel: a 256×64 centred box with a 1px border, a `Loading...` label
drawn from a 1bpp bitmap at 2× scale, and a 32-cell blocky progress bar.

Commits: `e0862ba` (cell math), `c16346b` (bitmap + run extractor), `341f9cb`
(renderer), `b42af6f` (citation fix).

## Setup

| | |
|---|---|
| Device | 192.168.20.81 |
| Core | `Solarus_20260726.rbf` (unchanged — this change needs no RBF) |
| Quest | Mystery of Solarus DX |
| Deploy | `./deploy.py --no-rbf`, sha1-verified |
| Engine | `libsolarus.so.1.6.5`, 3761536 bytes, cross-built via `SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh` |
| Flags | stock (`SOLARUS_LOADBAR` default-on) |

## Objective legs

| Leg | Result |
|---|---|
| Engine cross-build (armhf, Docker) | PASS — `loadbar.h` registration held; no `No such file or directory` |
| Renderer type-check (both `-D` flags) | PASS — clean, no output |
| Host suite (`bash tests/run_tests.sh`) | PASS — all sections, incl. `loadbar: all checks passed` |
| Bar renders during preload | PASS — box, border, label and cells all present from the first captured frame |
| Bar advances monotonically | PASS — 3/32 → 8/32 → 29/32 across the load |
| No regression past preload | PASS — MoSDX title screen renders correctly (`20260726_221043`) |

## Operator visual gate

The user compared captures against the MiSTer OSD and returned **PASS — ship it
as is**. Specifically: the box reads as a MiSTer OSD panel, `Loading...` is
legible at 2× on their display, the cell bar advances visibly and monotonically,
and the box size and position needed **no** tuning.

This is worth noting because the spec explicitly anticipated one or two geometry
iterations — `osd_buffer` is 256×64 but composites in *output* space with
`multiscan` scaling, so a 256×64 box in the core's 320×240 framebuffer was a
guess, not a derivation. It happened to land.

The derived red tint (`OSD_COLOR = 3'd4` puts the tint bit on red, giving box
background `0x2000` and content `0xE618`) was accepted as-is.

Captures: `20260726_214954` (3/32), `20260726_214955` (8/32), `20260726_215004`
(29/32), `20260726_221043` (title, post-preload).

## Incidental finding — preload duration

Not a goal of this work, but measured in passing and relevant to the **parked**
`BLT_OP_STAGE_BULK` lever (spec §"Bulk-STAGE performance work"):

- Whole-quest preload for MoSDX moves **31.74 MiB** into permanent SDRAM
  (`perm used 33285192 bytes, base 0x01000000 end 0x02fbe448`).
- It takes **longer than 14 s** — at 14 s the bar was still only ~29/32.

**Attribution is unmeasured.** The split between A9 work (PNG decode, format
conversion, PAL8 packing, memcpy into the bounce heap) and fabric work (the
`burstcnt=1` STAGE dribble, one full DDR3 read round-trip per 8 bytes) was
deliberately not measured — the user directed that the cosmetic issue was the
real motivation and parked the perf work. Do not assume the fabric leg dominates
without measuring first.

## Gotcha recorded

The first launch attempt failed silently: the engine initialised fully, logged
its whole banner, then exited, and screenshots landed in
`/media/fat/screenshots/MENU/`. Cause: the **Solarus core was not loaded** — a
prior `deploy.py` run had left the device on the menu core. `/tmp/CORENAME` read
`Solarus` from an earlier check and was stale.

Always `echo "load_core …" > /dev/MiSTer_cmd` and re-read `/tmp/CORENAME`
immediately before launching the engine; a running engine without its fabric
exits without an error message.
