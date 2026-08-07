# mem_wc — a write-combining `/dev/mem`

Vendored, unmodified, from [skmp/minicast](https://github.com/skmp/minicast)
(`mem_wc/mem_wc.c`), GPL-2.0, via `gmcnaught/mamester` PR #5. Upstream exists to
give DreamSTer's Dreamcast VRAM window a write-combining mapping; we want the
same thing for the blitter command/heap window.

## Why

Every byte the fabric composites — command ring, staged atlas pixels, GRID_BUF
cells, the ARGB4444 overlay root, the CLUT — is written by the A9 into the 18 MiB
window at `0x3B000000` first.

A `/dev/mem` mmap of that window is **unconditionally Strongly-Ordered**, and no
`open()` flag changes it. ARM's `phys_mem_access_prot()` (`arch/arm/mm/mmu.c`)
returns `pgprot_noncached()` whenever `pfn_valid(pfn)` is false, and only reaches
the `O_SYNC` test when it is true. On the DE10-Nano `/proc/iomem` shows
`System RAM` ending at `0x1fefffff`, so `0x3B000000` — in the 512 MB handed to
the fabric — always takes the first branch. Dropping `O_SYNC` is a null.

Strongly-Ordered stores cannot merge: each one is its own bus transaction. This
driver never asks `pfn_valid()`; it sets `pgprot_writecombine()` unconditionally
(`L_PTE_MT_BUFFERABLE`, Normal Non-Cacheable) and calls `remap_pfn_range()`, so
the write buffer can coalesce stores into full bursts.

Measured on this hardware (`docs/superpowers/data/ddr-write-bench-2026-08-07.md`):

| pattern | `/dev/mem` | `/dev/mem_wc` | |
|---|---|---|---|
| `memcpy` (overlay root) | 91.2 MB/s | 852.8 MB/s | 9.35× |
| aligned 32-bit stores (ring) | 55.7 MB/s | 865.9 MB/s | 15.55× |
| bulk `memcpy` (GRID_BUF) | 73.9 MB/s | 719.7 MB/s | 9.74× |
| `volatile` byte stores (CLUT) | 14.0 MB/s | 249.4 MB/s | 17.88× |

## Ordering is the caller's problem

Write-combining posts and coalesces stores; ordering against **other bus
masters** (the FPGA reading the same DDR) is *not* implied. The userspace writer
must drain the write buffer before signalling the fabric.

`BLT_FENCE()` in `mister_blitter_renderer.cpp` is that barrier. It is `dsb sy`,
**not** `__sync_synchronize()` — the latter lowers to `dmb ish` on ARMv7, which
orders only within the inner-shareable domain, and the FPGA reaches DDR through
the f2h SDRAM ports *outside* that domain. Under the old Strongly-Ordered
mapping the memory type did the ordering and the fence was decorative; under
write-combining it is load-bearing.

**Invariant: every doorbell store the fabric polls is preceded by
`BLT_FENCE()`.** Violations are silent and intermittent — a torn frame every few
thousand submits — and get misattributed to the RTL.

## The mapping is split page-exactly

`map_ddr_wc()` does **not** map the window write-combining wholesale:

```
0x000000..0x001000   ctrl block + first 4032 B of ring 0    strongly-ordered
0x001000..0x080000   rest of ring 0                          write-combining
0x080000..0x081000   bank-1 ctrl + head of ring 1            strongly-ordered
0x081000..0x1200000  ring 1 tail, heap, TL/FRT/CFT/SP/CLUT/GRID  write-combining
```

Two independent reasons the control pages stay Strongly-Ordered:

- **The doorbell must not be write-combined.** `C_SUBMIT` is one 32-bit store
  with no traffic behind it to force a drain, so under WC it can sit in the write
  buffer while the fabric polls a stale sequence number. Its transaction cost is
  irrelevant; its ordering is not.
- **No page may be mapped at two memory types.** The `MAP_FIXED` overlay
  *replaces* the Strongly-Ordered pages rather than aliasing them — a mismatched
  alias is architecturally UNPREDICTABLE on ARMv7.

`OFF_RING` is `0x40`, so ring 0's first 4032 bytes share the doorbell's page and
stay Strongly-Ordered. That is ~0.8 % of a 512 KiB ring, in exchange for the
window staying one linear pointer instead of every ring cursor growing a
straddling special case.

**Trap: `MAP_FIXED` unmaps its target range before the driver's `.mmap` runs.**
A rejected overlay — `mem_wc` loaded with an allowlist that misses part of our
window returns `-EPERM` — would leave a *hole* mid-window rather than the
Strongly-Ordered mapping we started from, and the next store takes SIGSEGV. So
`map_ddr_wc()` probes every range at a kernel-chosen address first, unmaps, and
only then commits the overlays.

## Optional by design

Built out-of-tree against one MiSTer kernel's vermagic, so a MiSTer update makes
`insmod` start failing on users' machines. That must cost frame rate, not boot:

- The engine tries `/dev/mem_wc`, falls back to `/dev/mem`, and logs which it got
  (`[blitter] ddr mapping: ...`).
- `SOLARUS_NO_WC=1` forces the fallback — that is the A/B, no unload needed.
- `solarus_run.sh` insmods it restricted to this core's own window and ignores
  failure.
- `deploy.py` ships `prebuilt/mem_wc-$(uname -r).ko` when one matches the
  device's kernel, warns and continues when none does, and removes a stale
  module built for a different kernel.

## Allowlist size

**`phys_size` must cover the whole 18 MiB window** (`BLT_DDR_SIZE = 0x01200000`):

```
insmod mem_wc.ko phys_base=0x3B000000 phys_size=0x01200000
```

A shorter allowlist makes the upper range's probe return `-EPERM`, and the engine
silently takes the strongly-ordered path. A 16 MiB (`0x1000000`) allowlist is the
easy mistake — it looks right, covers the heap, and misses GRID_BUF.

## Building for a new kernel

```
make -C patches/mister/mem_wc prebuilt KDIR=/path/to/Linux-Kernel_MiSTer
```

`KDIR` must be a kernel tree that has had `make modules_prepare` run against the
device's own `/proc/config.gz`, so vermagic matches exactly. The MiSTer kernel
has `CONFIG_MODVERSIONS` and `CONFIG_MODULE_SIG` off, so no symbol-CRC matching
and no signing are needed — only the vermagic string. The `prebuilt` target names
the output for the vermagic it was built against and strips debug info.

Commit the new `prebuilt/mem_wc-<release>.ko`; `deploy.py` picks by the device's
`uname -r`, so a kernel bump is "build and commit the new file", never "the old
object silently fails to insmod in the field".
