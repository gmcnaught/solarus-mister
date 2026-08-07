# A9 -> blitter-DDR store bandwidth, 2026-08-07

Device 192.168.20.81, kernel `5.15.1-MiSTer`, engine killed, RBF loaded.
Tool: `patches/mister/ddr_write_bench/ddr_write_bench.c`
(`bash scripts/build_ddr_write_bench.sh`).

Scratch region `0x3B100000` + 4 MiB — inside `OFF_HEAP`, so the control block,
the command ring and the doorbell are never touched by the bench.

`mem_wc.ko` was already loaded on this device from the mamester work, with
`phys_base=0x3B000000 phys_size=0x1000000`.

## Raw

```
  mapping         overlay   ring-b   ring-w     grid     clut   (MB/s)
  ------------------------------------------------------------------
  cached RAM        827.2    517.5    695.9    437.9    241.8
  /dev/mem           91.2     13.9     55.7     73.9     14.0
  /dev/mem_wc       852.8    477.9    865.9    719.7    249.4

  store-width lever (no driver): ring bytewise -> word = 4.02x on /dev/mem
  write-combining lever: overlay 9.35x  ring-w 15.55x  grid 9.74x  clut 17.88x
  VERDICT: /dev/mem_wc is write-combining (bulk arms >= 3.0x).
```

Arms map to real call sites:

| arm | bytes | call site |
|---|---|---|
| overlay | 153,600 | `mister_blitter_renderer.cpp:2232` `reupload_in_place()` |
| ring-b | 32/cmd | `blt_wire.h:44-46` `blt_wr32()` — 4 byte stores, x8 per `blt_pack_cmd()` |
| ring-w | 32/cmd | the same commands as aligned 32-bit stores (the no-driver alternative) |
| grid | 1,292,688 | `mister_blitter_renderer.cpp:3940` GRID_BUF, per map transition |
| clut | 65,536 | `mister_blitter_renderer.cpp:2024-2028`, volatile byte stores, at preload |

## What it means

`/dev/mem` overlay at 91.2 MB/s independently reproduces mamester's 89.5 MB/s
figure for the same silicon through a different window, so the baseline is not a
measurement artefact. `/dev/mem_wc` reaches or beats cached RAM on every arm —
the mapping penalty is essentially removed, not merely reduced.

Why `/dev/mem` is Strongly-Ordered regardless of `open()` flags: ARM's
`phys_mem_access_prot()` returns `pgprot_noncached()` whenever `pfn_valid(pfn)`
is false and only reaches the `O_SYNC` test when it is true. `/proc/iomem` on
this device shows `System RAM` ending at `0x1fefffff`, so `0x3B000000` always
takes the first branch. Dropping `O_SYNC` is therefore a null, and
`docs/blitter-renderer-integration.md:87-90` — which attributes the ordering
guarantee to "`O_SYNC`+`MAP_SHARED`" — is describing the right behaviour for the
wrong reason.

Per-call-site cost at the measured rates:

| site | SO today | WC | delta |
|---|---|---|---|
| ring, per command | 2.30 us | 0.037 us | |
| ring, 1000-cmd frame | 2.30 ms | 0.07 ms | ~2.2 ms/frame |
| overlay reupload | 1.61 ms | 0.17 ms | ~1.4 ms/frame |
| GRID_BUF, per map | 16.7 ms | 1.7 ms | ~15 ms/transition |
| CLUT, preload | 4.46 ms | 0.25 ms | one-shot |

The ring result is the one that was not on any prior list. At 13.9 MB/s the
bytewise emitter is 6.5x slower than the same window's `memcpy`, because every
byte is its own bus transaction. Command count scales with scene complexity,
which fits the moving-correlated `present` residual (6.1 -> 7.7 ms) that
`docs/superpowers/2026-07-22-stage5-a9-decision.md` recorded as unattributed.
That is a hypothesis consistent with these rates, NOT yet a demonstrated
attribution — confirming it needs an A/B of `present` with the store-width
change alone.

## Two independent levers

1. **Store width.** `blt_wr32()` bytewise -> aligned 32-bit is **4.02x** on
   plain `/dev/mem`, with no kernel module involved. Portable to any kernel and
   it also speeds up the write-combining fallback path.
2. **Write-combining.** A further 15.55x on the ring on top of (1), 9.35x on
   the overlay, 9.74x on the grid.

They compose; (1) is the one that cannot be switched off by a kernel update.

## HW A/B RESULT, 2026-08-07 — the fps lever is a NULL; the load win is 2.4%

`scripts/perf/wc_ab.sh` (interleaved arms, order alternating), map 119 at the
fixed `from_dungeon_10` spot, `Solarus_20260726.rbf`.

NOTE ON WHAT IS BEING COMPARED: `SOLARUS_NO_WC=1` disables only the write-combining
MAPPING. The `blt_wire.h` store-width change is present in BOTH arms. So this A/B
isolates the WC lever on top of already-fixed store width. The store-width lever
has NOT been isolated separately.

### Steady state, map 119 — null

| arm | standing fps | present |
|---|---|---|
| write-combined | 41.4, 41.4 | 7.1, 7.0 ms |
| strongly-ordered | 41.7, 41.3 | 7.0, 7.3 ms |

Indistinguishable, and the reason is in `[blitter cvt]`: steady-state
`dyn_reup` is 768,000 px per 60 frames = **~25 KB/frame**. At the measured SO
rates that is ~0.3 ms of a 14.5 ms A9 -- below this scene's noise. With 32-bit
stores the ring costs ~0.57 us/command, so even a couple thousand commands adds
only ~1 ms. The bench rates are real; the per-frame VOLUME is too small for them
to matter.

### Preload (31.74 MiB whole-quest atlas stage) — 354 ms, 2.4%

Three interleaved reps, engine start -> "preload complete":

| arm | reps (ms) | mean |
|---|---|---|
| write-combined | 14201, 14481, 14345 | 14342 |
| strongly-ordered | 14744, 14665, 14679 | 14696 |

Every WC rep beats every SO rep, so the separation is clean. The 354 ms delta
matches 31.74 MiB at 91.2 vs 852.8 MB/s (~330 ms) closely enough to confirm the
mechanism. It also shows preload is dominated by PNG decode and file I/O, not by
DDR stores -- the store portion is ~0.36 s of 14.3 s.

### Why this does not reproduce mamester's +15%

mamester's present path wrote a full 384 KB frame into DDR every frame, so a
~9.6x store speedup landed directly on frame time. Solarus moved the scanout
framebuffer write into the fabric (Stage 5 Phase 2), and OVERLAYSKIP suppresses
the overlay re-upload on most frames, so the A9's per-frame DDR volume is ~25 KB
-- roughly a 20th. The same speedup on a 20th of the volume is a null.

### Store-width isolated — also null on this scene

Same spot, WC on in BOTH arms, swapping libsolarus between a word-store and a
bytewise `blt_pack_cmd` build (interleaved, order alternating):

| arm | fps | emit | present |
|---|---|---|---|
| word stores | 41.8, 42.0, 41.7, 40.9 | 2.88 ms | 7.03 ms |
| bytewise | 41.6, 41.0, 41.2, 41.5 | 2.98 ms | 6.83 ms |

Expected to be small: under write-combining, bytewise (477.9 MB/s) and word
(865.9) are only 1.8x apart, so this arm pair cannot expose the 13.9 MB/s
strongly-ordered byte rate at all.

### MAP 119 IS THE WRONG SCENE FOR THIS — read the nulls with that in mind

Both A/Bs above ran at the fixed map-119 parallax spot, and that scene does not
exercise the paths this change touches:

- **Parallax composites through its own path**, not the general command stream.
- **The resident/animated tile path writes TL_BUF ENTRIES** (8-byte
  `blt_tile_entry_res_t`, `mister_blitter_renderer.cpp:3810-3818`), NOT 32-byte
  ring commands through `blt_pack_cmd` — so the `blt_wire.h` store-width change
  does not even apply to the dominant traffic here.
- `emit` is only ~2.9 ms of a ~14.5 ms A9 on this scene; the frame is split
  between `lua` (~4.4 ms) and `present` (~7.0 ms), with `fabric` at ~9.6 ms.

So these nulls say "not a lever ON MAP 119", NOT "not a lever". A scene that is
A9/emit-bound with a high 32-byte-command count (a town/overworld, or a dialog
frame) would be the honest test, and has not been run.

### Verdict

- **KEEP.** The mapping reduces per-write latency on the DDR channel — that is a
  property of the memory type, confirmed directly by the bench (91.2 -> 852.8
  MB/s, and 13.9 -> 477.9 MB/s for byte stores), independent of whether any
  particular scene happens to be bound by it. It is free, carries a kill switch,
  falls back cleanly, and measurably speeds the 31.74 MiB preload by 2.4%.
- Still unmeasured: the combined shipping config (WC + word) against the master
  baseline (strongly-ordered + bytewise) on an emit-bound scene. That is the leg
  where the 13.9 MB/s byte rate is actually exposed.
- Not yet done: any visual gate.

## Visual gate — PASS (operator, 2026-08-07)

Captured on .81 with `Solarus_20260726.rbf`, engine reporting
`[blitter] ddr mapping: write-combined (/dev/mem_wc)`, via MiSTer's own
`screenshot` command (real scanout, 320x240 — not an engine-side dump):

- `shots/1-title.png` — title
- `shots/2-gameplay-map60.png` — gameplay, map 60 (A9-bound scene)
- `shots/3-parallax-map119.png` — parallax, map 119 (fabric-bound; the scene
  where the C_DONE handshake actually spins, so fence-ordering damage would
  show here first)

Operator verdict: **PASS**. This closes the last open item on
`feat/ddr-write-combining`; per the standing rule the verdict is the operator's,
never self-declared.
