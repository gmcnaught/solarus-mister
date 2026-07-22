import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from cache_hitrate import lru_hitrate, saa_hitrate, saa_fifo_hitrate, cycpx_for

def approx(a, b, e=1e-6): assert abs(a-b) < e, f"{a} != {b}"

def test_fully_assoc_capacity():
    # cyclic access to N distinct blocks: LRU cache of B<N blocks -> 0 hits
    # (every block evicted before reuse); B>=N -> all-hit after the cold fill.
    seq = [i % 5 for i in range(100)]         # 5 distinct blocks, cyclic
    assert lru_hitrate(seq, 4) == 0.0          # 4<5: thrash, 0 hits
    hr5 = lru_hitrate(seq, 5)                   # 5>=5: only the first 5 are cold
    approx(hr5, 95/100)                         # 95 hits / 100 accesses

def test_reuse_locality():
    # a hot block reused with small reuse-distance hits even in a small cache.
    seq = [0,1,0,1,0,1,0,1]                     # 2 distinct, distance 1
    approx(lru_hitrate(seq, 2), 6/8)           # first 2 cold, rest hit

def test_saa_matches_full_assoc_single_set():
    # BLOCKS<4 -> WAYS=BLOCKS, SETS=1 -> saa is exactly fully-associative.
    seq = [0,1,0,1,0,1,0,1]
    approx(saa_hitrate(seq, 2), lru_hitrate(seq, 2))   # 2 blocks: 1 set, 2-way == full
    approx(saa_hitrate(seq, 2), 6/8)

def test_saa_conflict_miss_vs_full_assoc():
    # Two hot blocks that COLLIDE into the same set thrash a 4-way/1-victim set even
    # though a fully-associative cache of the same size holds both. With SETS=2 (BLOCKS=8),
    # blocks 0 and 2 both map to set 0 (0%2==2%2==0); interleaving 5 such colliders that
    # all land in set 0 exceeds its 4 ways -> conflict misses full-assoc never has.
    seq = ([0,2,4,6,8] * 20)                   # all even -> all map to set 0 (%2), 5 distinct
    hr_saa = saa_hitrate(seq, 8)               # 4-way set 0 holds only 4 of the 5 -> thrash
    hr_full = lru_hitrate(seq, 8)              # 8>=5 distinct -> ~all hit after cold
    assert hr_saa < hr_full, f"saa {hr_saa} should be < full {hr_full} (conflict misses)"
    assert hr_full > 0.7 and hr_saa < 0.1      # full-assoc ~all-hit; set-assoc thrashes

def test_saa_even_spread_hits():
    # Same 5 blocks but spread across sets (BLOCKS=32 -> SETS=8): 0,1,2,3,4 land in
    # distinct sets, each 4-way set easily holds its lone block -> ~all hit.
    seq = [i % 5 for i in range(200)]
    assert saa_hitrate(seq, 32) > 0.95

def test_fifo_no_reorder_on_hit_vs_lru():
    # FIFO evicts by INSERTION order, ignoring hits. A block reused just before it would
    # age out still gets evicted (LRU would keep it). Single set (ways=4), 5 blocks:
    # fill 0,1,2,3; touch 0 (FIFO: 0 still oldest); insert 4 -> FIFO evicts 0, LRU evicts 1.
    seq = [0,1,2,3, 0, 4, 0]                    # last 0: FIFO miss (evicted), LRU hit
    hf = saa_fifo_hitrate(seq, 4)               # 1 set, 4 ways
    hl = saa_hitrate(seq, 4)
    assert hf < hl, f"FIFO {hf} should be <= LRU {hl} on recency-favoring stream"

def test_fifo_matches_lru_when_no_reuse_pressure():
    # If every distinct block fits in its set, FIFO == LRU (no eviction happens).
    seq = [i % 5 for i in range(200)]
    approx(saa_fifo_hitrate(seq, 32), saa_hitrate(seq, 32))

def test_cycpx_transfer():
    approx(cycpx_for(1.0), 2.2)                 # all hits -> floor
    approx(cycpx_for(0.0), 9.2)                 # all miss -> 2.2 + 7

if __name__ == "__main__":
    for name in [n for n in dir() if n.startswith("test_")]:
        globals()[name](); print(f"OK: {name}")
