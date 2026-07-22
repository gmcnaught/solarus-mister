#!/usr/bin/env python3
"""Offline hit-rate model for the P_SRC atlas cache (Stage 5 Phase 1).
Feed the block-id access sequence (from the engine fetch-trace diag); sweep cache sizes to
find the knee that captures most of the win. cyc/px via the tb_profile transfer function.

IMPORTANT — the vendored jtframe_cache is NOT fully associative. jtframe_cache_ctrl.sv:
    WAYS = BLOCKS < 4 ? BLOCKS : 4      # 4-way for BLOCKS>=4
    SETS = BLOCKS / WAYS
    set(block_id) = block_id % SETS     # line_base_uaddr: set bits sit just above the
                                        # 256B block offset -> consecutive blocks round-robin
and jtframe_cache_tags.sv replaces via a per-set `repl_ptr` advanced past the filled way
(victim_way = repl_ptr[set]) — i.e. ROUND-ROBIN / FIFO, not LRU.
So `saa_fifo_hitrate` (4-way set-assoc, FIFO) is the REAL model. `saa_hitrate` (4-way LRU)
is a mild upper bound on it; `lru_hitrate` (fully-associative) is the loosest upper bound.
Size the cache from `saa_fifo_hitrate`. See docs/superpowers/data/stage5/cache-knee.md."""
from collections import OrderedDict, deque

def lru_hitrate(block_seq, n_blocks):
    """Fully-associative LRU of n_blocks blocks. Returns hits/accesses.
    OPTIMISTIC upper bound only — the real cache is 4-way set-assoc (see saa_hitrate)."""
    if not block_seq: return 0.0
    cache = OrderedDict()           # block_id -> None, MRU at end
    hits = 0
    for b in block_seq:
        if b in cache:
            hits += 1
            cache.move_to_end(b)
        else:
            cache[b] = None
            if len(cache) > n_blocks:
                cache.popitem(last=False)   # evict LRU
    return hits / len(block_seq)

def saa_hitrate(block_seq, n_blocks, max_ways=4):
    """REAL jtframe_cache model: WAYS=min(n_blocks,4), SETS=n_blocks//WAYS, per-set LRU,
    set=block_id % SETS. Matches jtframe_cache_ctrl.sv exactly. Returns hits/accesses."""
    if not block_seq: return 0.0
    ways = n_blocks if n_blocks < max_ways else max_ways
    sets = max(1, n_blocks // ways)
    cache = [OrderedDict() for _ in range(sets)]   # per-set LRU (MRU at end)
    hits = 0
    for b in block_seq:
        c = cache[b % sets]
        if b in c:
            hits += 1
            c.move_to_end(b)
        else:
            c[b] = None
            if len(c) > ways:
                c.popitem(last=False)   # evict this set's LRU
    return hits / len(block_seq)

def saa_fifo_hitrate(block_seq, n_blocks, max_ways=4):
    """REAL jtframe_cache model: 4-way set-assoc with FIFO (round-robin repl_ptr)
    replacement — no reorder on hit. WAYS=min(n_blocks,4), SETS=n_blocks//WAYS,
    set=block_id % SETS. Matches jtframe_cache_ctrl/_tags exactly."""
    if not block_seq: return 0.0
    ways = n_blocks if n_blocks < max_ways else max_ways
    sets = max(1, n_blocks // ways)
    resident = [set() for _ in range(sets)]
    fifo     = [deque() for _ in range(sets)]   # insertion order per set
    hits = 0
    for b in block_seq:
        s = b % sets
        if b in resident[s]:
            hits += 1                    # FIFO: a hit does NOT reorder
        else:
            if len(fifo[s]) >= ways:
                ev = fifo[s].popleft(); resident[s].discard(ev)
            fifo[s].append(b); resident[s].add(b)
    return hits / len(block_seq)

def cycpx_for(hitrate):
    """tb_profile transfer fn: all-hit ~2.2 cyc/px, all-miss ~9.2 (2.2 + miss*7)."""
    return 2.2 + (1.0 - hitrate) * 7.0

def sweep(block_seq, sizes, model=saa_fifo_hitrate):
    """Sweep cache sizes. Defaults to the REAL 4-way set-assoc FIFO model."""
    return [(B, model(block_seq, B), cycpx_for(model(block_seq, B))) for B in sizes]

def blocks_for_tile(src_off, src_x, src_y, w, h, stride, blksize=256):
    """Atlas byte addresses a tile's source region touches -> distinct 256B block ids."""
    blocks = set()
    for row in range(h):
        row_base = src_off + (src_y + row) * stride + src_x * 2   # RGB565 = 2 B/px
        for col_byte in range(0, w * 2, blksize):
            blocks.add((row_base + col_byte) // blksize)
    return sorted(blocks)

if __name__ == "__main__":
    import sys, re
    # stdin: lines "FETCH src_off src_x src_y w h stride" from the engine diag.
    seq = []
    for line in sys.stdin:
        m = re.search(r"FETCH (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)", line)
        if m:
            seq += blocks_for_tile(*(int(x) for x in m.groups()))
    sizes = [2, 8, 16, 32, 48, 64, 96, 128, 256]
    print(f"total accesses={len(seq)} distinct blocks={len(set(seq))}")
    print("  SRC_BLOCKS   4way-FIFO(REAL) cyc/px |  4way-LRU  |  full-assoc(bound)")
    for B in sizes:
        fr = saa_fifo_hitrate(seq, B); hr = saa_hitrate(seq, B); lr = lru_hitrate(seq, B)
        print(f"  {B:8d}   {fr*100:6.1f}%  {cycpx_for(fr):5.2f}      | {hr*100:6.1f}%   | {lr*100:6.1f}%")
