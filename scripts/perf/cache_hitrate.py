#!/usr/bin/env python3
"""Offline fully-associative LRU hit-rate model for the P_SRC atlas cache (Stage 5 Phase 1).
Feed the block-id access sequence (from the engine fetch-trace diag); sweep cache sizes to
find the knee that captures most of the win. cyc/px via the tb_profile transfer function."""
from collections import OrderedDict

def lru_hitrate(block_seq, n_blocks):
    """Fully-associative LRU of n_blocks blocks. Returns hits/accesses."""
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

def cycpx_for(hitrate):
    """tb_profile transfer fn: all-hit ~2.2 cyc/px, all-miss ~9.2 (2.2 + miss*7)."""
    return 2.2 + (1.0 - hitrate) * 7.0

def sweep(block_seq, sizes):
    return [(B, lru_hitrate(block_seq, B), cycpx_for(lru_hitrate(block_seq, B))) for B in sizes]

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
    for B, hr, cp in sweep(seq, sizes):
        print(f"  SRC_BLOCKS={B:4d}  hit={hr*100:5.1f}%  cyc/px={cp:.2f}")
