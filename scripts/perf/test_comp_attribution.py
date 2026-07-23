import subprocess, sys, os, textwrap
HERE = os.path.dirname(__file__)

def run(log, args):
    p = os.path.join(HERE, "comp_attribution.py")
    return subprocess.run([sys.executable, p, log] + args,
                          capture_output=True, text=True)

def test_ranks_and_sums(tmp_path):
    # two buckets: dense layer0 (many runs, few empties), sparse layer2 (few runs, many empties)
    log = tmp_path / "g.log"
    log.write_text(textwrap.dedent("""
      GRIDSTATS layer=0 ratio=1 win=0,0-40,30 nonempty=1200 empty=0 runs=120 hist=0,0,0,0,0,0,0,0,0,10,0,0,0,0,0,110
      GRIDSTATS layer=2 ratio=2 win=0,0-40,30 nonempty=200 empty=1000 runs=200 hist=200,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    """).strip())
    r = run(str(log), ["--comp-ms","14.9","--overlay-ms","4.0",
                       "--empty-cyc","2","--run-cyc","20","--px-cyc-per-col","2"])
    assert r.returncode == 0, r.stderr
    out = r.stdout
    # all five slices present, sorted descending, and a SUM check line
    assert "slice overlay-palpha" in out
    assert "tilemap-empty-walk" in out
    assert "SUM check" in out
    # empty-walk = 1000 empties * 2 cyc / FABRIC_HZ; assert it appears as ~0.02ms
    assert "tilemap-empty-walk" in out and "0.02" in out
