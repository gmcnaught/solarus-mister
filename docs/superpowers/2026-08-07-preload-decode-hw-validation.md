# Preload decode levers — HW validation (`.81`, 2026-08-07)

Engine-only; no RBF change. Device `192.168.20.81`, installed
`Solarus_20260807.rbf`, quest `mystery_of_solarus_dx.sol`.

## What shipped

| # | Lever | Flag |
|---|---|---|
| 1 | Walk prune: skip `logos/` and non-active `languages/*` | (always on) |
| 2 | Always-PAL8: dedup on quantized `(RGB565, A4)` | (always on) |
| 3 | Decode-ahead worker, ≤6 files in front of staging | `SOLARUS_PRELOADTHREAD` |
| 4 | No RGBA32 round-trip: palette taken from the INDEX8 decode | `SOLARUS_PRELOADTHREAD` |

Levers 3 and 4 share a flag because 4 happens inside 3's worker.

## Census that drove the design

Shipping quest: 335 PNGs, 1.62 MiB compressed → 32.19 MiB / 31.61 Mpx raw;
317 palette / 18 RGBA; **98.2 % of scanlines are filter type 0 (None)**.

> **DEAD LEVER — do not build it.** libpng ARM-NEON unfiltering looks like the
> obvious win (Debian armhf ships NEON compiled out). It would optimise 1.8 % of
> the work. The cost is zlib inflate and the palette round-trip, not unfiltering.

Prune removes 64 files / 5.01 Mpx (**31.61 → 26.60 Mpx, −16 %**):
`logos/` 1.54 Mpx (window-icon art, a no-op under `SDL_VIDEODRIVER=dummy`) and
7 of 8 `languages/` dirs 3.43 Mpx (`QuestFiles.cpp:289` resolves language files
through `languages/<current_language>/` only).

## Results

    TAG                     wall-clock   config
    A_on_1                    9.45 s
    B_off_1                  13.56 s     SOLARUS_PRELOADTHREAD=0
    A_on_2                    9.45 s
    B_off_2                  13.56 s     SOLARUS_PRELOADTHREAD=0

**−30.3 %**, reproducible to 0.01 s. Measured launch → `preload complete`, so it
includes constant engine-startup overhead; the preload-only share is larger. The
prune is active in BOTH legs, so this isolates levers 3+4.

Leg A census:

    preload prune: logos/ skipped, languages/ -> en
    PAL8: CLUT bankset uploaded (24 banks touched)
    PAL8 residency: 271 surfaces 8bpp-paletted, 0 CLUT-overflow->16bpp, 0 truecolor->16bpp
    preload decode-ahead: on, 200 prefetch hits, 51 inline decodes;
        palette from native decode 230, from ABGR32 re-derive 41, unclaimed 13
    preload complete: perm used 26597896 bytes (25.37 MiB)

Leg B differs only in: `0 prefetch hits, 251 inline decodes; palette from native
decode 0, from ABGR32 re-derive 271`.

`0 truecolor->16bpp` is always-PAL8 landing: `9.tiles.png` used to be the one
asset that fell back (258 distinct RGBA8888 → **90** distinct `(RGB565, A4)`).

## Equivalence evidence

The risky change is taking alpha from palette entries (tRNS) instead of from the
converted RGBA32. Four independent checks:

1. **Offline, exhaustive.** Resolving every pixel natively (palette RGB + tRNS
   → RGB565/A4) matches the ABGR8888 round-trip **bit-for-bit across all 270
   paletted assets, 0 pixels differing**; 259 carry tRNS. Alpha levels quest-wide
   are exactly `{0, 7, 11, 15}`.
2. **Identical residency on HW.** `perm used 26597896 bytes` in BOTH legs, and
   the same `271 / 0 / 0` PAL8 census.
3. **Footer textmatch 100 %** on all 3 captures, scored against the other leg.
4. **Pixel diff below the animation floor.** Best cross-config frame pair differs
   by 1960 px; **same-config pairs differ by 13860–17801 px**. Differences sit
   only in rows 39–149 and 169–182 (animated sky/water and a menu element), max
   49 px in any single row, and **0 in the static footer band** — scattered, not
   the contiguous blocks a palette error produces.

> Check 4 is *evidence*, not proof: the title screen animates too much for a
> bit-exact HW frame comparison. The bit-exact proof is check 1, at the data
> level.

5. **Operator visual gate: PASS** (2026-08-07, gmcnaught, `.81`). Also reported
   loading "felt faster", consistent with the −30 % measurement. This is the
   check that closes the alpha question in the real renderer — checks 1–4 bound
   the data and the static bands, but only eyes cover the 259 tRNS-carrying
   assets in motion.

## Reproducing

    ssh root@192.168.20.81 'sh /tmp/preload_leg.sh A'
    ssh root@192.168.20.81 'sh /tmp/preload_leg.sh B SOLARUS_PRELOADTHREAD=0'

    ENGINE_ENV="SOLARUS_PRELOADTHREAD=0" QUEST=games/solarus/quests/mystery_of_solarus_dx.sol \
      WAIT_TITLE=45 bash scripts/debug/shot_capture.sh 192.168.20.81 ctrl --installed

`shot_capture.sh` gained an `ENGINE_ENV` passthrough so both configurations run
through one binary and one datapath — a pixel diff then isolates the flag.

## Still open

`SOLARUS_PRELOADTHREAD=0` costs 41 of 271 palettes to the re-derive path even
with the worker on (the main thread wins the race on early files). Raising
`PREFETCH_AHEAD` above 6 would close some of that, at proportional memory.

The prune's own contribution is unmeasured — it has no flag, so there is no A/B
leg for it. Its −16 % is a pixel count, not a timing.
