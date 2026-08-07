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
