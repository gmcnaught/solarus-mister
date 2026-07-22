import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from cache_hitrate import lru_hitrate, cycpx_for

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

def test_cycpx_transfer():
    approx(cycpx_for(1.0), 2.2)                 # all hits -> floor
    approx(cycpx_for(0.0), 9.2)                 # all miss -> 2.2 + 7

if __name__ == "__main__":
    for name in [n for n in dir() if n.startswith("test_")]:
        globals()[name](); print(f"OK: {name}")
