#!/usr/bin/env python3
"""Analyse an fps-dip capture (scripts/fpsdip/run.sh output directory).

  frames.py <capture dir> [--prof] [--top N] [--csv long.csv]

Active gameplay = a game is running and it is not suspended, in a dialog, paused,
in a map transition or on the game-over screen (MISTER_FL_* flags).

Metrics
  osd fps      the on-screen counter: frames / period over 30-iteration windows
               (MainLoop's [OSD-fps] accumulator), tiled.
  presented    submits per 1-second wall window.
  displayed    new frames per 60 scanout frames, from the scanout vblank counter
               read at each submit (a frame submitted twice inside one scanout
               frame is overwritten unseen; a scanout frame with no new submit
               repeats the previous one).
  long frame   iteration period > 1.1 x the 16,689 us scan period; attributed to
               the phase that grew most versus that map's median frame.
"""
import collections, gzip, pathlib, statistics, struct, sys, argparse

REC = struct.Struct("<Q10I8H")
FIELDS = ("t0 input update draw sleep fab pace lua cpu vsync upload "
          "steps nvcsw nivcsw minflt majflt map cmds flags").split()
FL = dict(GAME=0x1, SUSPENDED=0x2, DIALOG=0x4, PAUSED=0x8, TRANSITION=0x10,
          GAMEOVER=0x20, LAGDROP=0x40, MAPCHANGE=0x80, NOSUBMIT=0x100)
SCAN_US = 16688.15
LONG_US = SCAN_US * 1.1
PHASES = ("input", "upd_cpp", "lua", "emit", "fab", "pace", "sleep")


def load(d):
    raw = (d / "frames.bin").read_bytes()
    fr = [dict(zip(FIELDS, REC.unpack_from(raw, i * REC.size))) for i in range(len(raw) // REC.size)]
    maps = {}
    mp = d / "maps.txt"
    if mp.exists():
        for line in mp.read_text().splitlines():
            k, _, v = line.partition(" ")
            maps[int(k)] = v
    for i, f in enumerate(fr):
        f["i"] = i
        f["period"] = (fr[i + 1]["t0"] - f["t0"]) if i + 1 < len(fr) else None
        # Lua runs inside update (game/map/entity callbacks) and inside draw
        # (on_draw callbacks); attribute it to its own bucket and take it out of
        # update first, the larger consumer. Clamp so buckets stay >= 0.
        lua_in_upd = min(f["lua"], f["update"])
        f["upd_cpp"] = f["update"] - lua_in_upd
        f["emit"] = max(0, f["draw"] - f["fab"] - f["pace"] - (f["lua"] - lua_in_upd))
        f["mapname"] = maps.get(f["map"], "-") if f["map"] != 0xFFFF else "-"
        fl = f["flags"]
        f["active"] = bool(fl & FL["GAME"]) and not (fl & (FL["SUSPENDED"] | FL["DIALOG"] | FL["PAUSED"] | FL["TRANSITION"] | FL["GAMEOVER"]))
    return fr[:-1], maps


def pct(v, p):
    if not v:
        return 0
    v = sorted(v)
    return v[min(len(v) - 1, int(p / 100 * len(v)))]


def segments(fr):
    """Contiguous runs of active frames."""
    seg, cur = [], []
    for f in fr:
        if f["active"]:
            cur.append(f)
        elif cur:
            seg.append(cur); cur = []
    if cur:
        seg.append(cur)
    return seg


def osd_windows(seg):
    out = []
    for s in seg:
        for k in range(0, len(s) - 29, 30):
            w = s[k:k + 30]
            per = sum(f["period"] for f in w)
            out.append((1e6 * 30 / per, w))
    return out


def presented_windows(seg):
    out = []
    for s in seg:
        t_end = s[-1]["t0"]
        t = s[0]["t0"]
        j = 0
        while t + 1e6 <= t_end:
            n = 0
            while j < len(s) and s[j]["t0"] < t + 1e6:
                if not s[j]["flags"] & FL["NOSUBMIT"]:
                    n += 1
                j += 1
            out.append(n)
            t += 1e6
    return out


def displayed(seg):
    """Per active segment: vsync counter at each submit -> new frames per 60 scanout frames,
    repeated scanout frames, frames overwritten unseen."""
    wins, repeats, unseen, deltas = [], 0, 0, collections.Counter()
    for s in seg:
        v = [f["vsync"] for f in s if not f["flags"] & FL["NOSUBMIT"] and f["vsync"]]
        if len(v) < 2:
            continue
        for a, b in zip(v, v[1:]):
            dv = (b - a) & 0xFFFFFFFF
            deltas[min(dv, 9)] += 1
            if dv == 0:
                unseen += 1
            elif dv > 1:
                repeats += dv - 1
        # new frames per 60 scanout frames: distinct vsync values seen per block
        seen = collections.Counter()
        for x in v:
            seen[(x - v[0]) // 60] += 0
        vals = sorted(set(v))
        base = vals[0]
        blocks = collections.defaultdict(set)
        for x in vals:
            blocks[(x - base) // 60].add(x)
        nb = (vals[-1] - base) // 60
        for b in range(nb):
            wins.append(len(blocks.get(b, ())))
    return wins, repeats, unseen, deltas


def attribute(f, base):
    grow = {p: f[p] - base[p] for p in PHASES}
    return max(grow, key=grow.get), grow


def fmt_ms(us):
    return f"{us / 1000:.1f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--prof", action="store_true")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--csv")
    a = ap.parse_args()
    d = pathlib.Path(a.dir)
    fr, maps = load(d)
    act = [f for f in fr if f["active"]]
    seg = segments(fr)
    total_s = (fr[-1]["t0"] - fr[0]["t0"]) / 1e6 if fr else 0
    act_s = sum(f["period"] for f in act) / 1e6
    print(f"# {d.name}: {len(fr)} iterations, {total_s:.0f} s, active {act_s:.0f} s in {len(seg)} segments, {len(maps)} maps")

    osd = osd_windows(seg)
    ov = [x for x, _ in osd]
    if ov:
        lt = lambda t: sum(1 for x in ov if x < t)
        print(f"osd fps (30-frame windows, n={len(ov)}): min {min(ov):.1f}  p1 {pct(ov, 1):.1f}  p5 {pct(ov, 5):.1f}  median {pct(ov, 50):.1f}"
              f"  | <55: {lt(55)} ({100 * lt(55) / len(ov):.1f}%)  <58: {lt(58)}  <50: {lt(50)}")
    pw = presented_windows(seg)
    if pw:
        c = collections.Counter(pw)
        print(f"presented fps (1-s windows, n={len(pw)}): " + "  ".join(f"{k}:{c[k]}" for k in sorted(c)))
    dw, rep, unseen, deltas = displayed(seg)
    if dw:
        c = collections.Counter(dw)
        print(f"displayed new frames / 60 scanout (n={len(dw)}): " + "  ".join(f"{k}:{c[k]}" for k in sorted(c))
              + f"  | repeated scanout frames {rep}, overwritten unseen {unseen}")
        print("vsync delta between submits: " + "  ".join(f"{k}:{deltas[k]}" for k in sorted(deltas)))

    per = [f["period"] for f in act]
    print(f"active period us: mean {statistics.mean(per):.0f}  p50 {pct(per, 50)}  p99 {pct(per, 99)}  p99.9 {pct(per, 99.9)}  max {max(per)}"
          f"  | > {LONG_US:.0f}: {sum(p > LONG_US for p in per)} ({100 * sum(p > LONG_US for p in per) / len(per):.2f}%)")
    st = collections.Counter(f["steps"] for f in act)
    print("steps per iteration: " + "  ".join(f"{k}:{st[k]}" for k in sorted(st))
          + f"  mean {statistics.mean(f['steps'] for f in act):.3f}")
    paced = [f for f in act if f["pace"] > 0]
    sub = [f["period"] for f in act if f["pace"] > 0]
    if paced:
        print(f"pace sleep: {len(paced)} frames ({100 * len(paced) / len(act):.0f}%), mean {statistics.mean(f['pace'] for f in paced):.0f} us;"
              f" paced-frame period mean {statistics.mean(sub):.1f} us vs scan {SCAN_US} (p99 {pct(sub, 99)})")
    print("mean us/iteration (active): " + "  ".join(f"{p} {statistics.mean(f[p] for f in act):.0f}" for p in PHASES)
          + f"  cpu {statistics.mean(f['cpu'] for f in act):.0f}")

    # Per-map table
    by = collections.defaultdict(list)
    for f in act:
        by[f["mapname"]].append(f)
    base = {}
    print("\nper map (active):  map  s  osd<55%  long%  p50/p99 period ms  | mean ms: upd_cpp lua emit fab pace  steps")
    osd_by = collections.defaultdict(list)
    for x, w in osd:
        osd_by[w[0]["mapname"]].append(x)
    rows = []
    for m, fs in by.items():
        base[m] = {p: statistics.median(f[p] for f in fs) for p in PHASES}
        pp = [f["period"] for f in fs]
        o = osd_by.get(m, [])
        rows.append((sum(pp) / 1e6, m, 100 * sum(x < 55 for x in o) / len(o) if o else 0,
                     100 * sum(p > LONG_US for p in pp) / len(pp), pct(pp, 50), pct(pp, 99),
                     [statistics.mean(f[p] for f in fs) for p in ("upd_cpp", "lua", "emit", "fab", "pace")],
                     statistics.mean(f["steps"] for f in fs)))
    for r in sorted(rows, key=lambda r: -r[2] * r[0]):
        print(f"  {r[1]:>5} {r[0]:6.0f} {r[2]:7.1f} {r[3]:6.2f}  {fmt_ms(r[4]):>5}/{fmt_ms(r[5]):<5}  | "
              + " ".join(f"{fmt_ms(x):>5}" for x in r[6]) + f"  {r[7]:.2f}")

    # Long frames
    longs = [f for f in act if f["period"] > LONG_US]
    cause = collections.Counter()
    excess = collections.Counter()
    rowsl = []
    for f in longs:
        c, grow = attribute(f, base[f["mapname"]])
        if f["majflt"]:
            c = "majflt"
        elif f["upload"] > 20000 and grow["emit"] > 2000:
            c = "upload"
        cause[c] += 1
        for p in PHASES:
            excess[p] += max(0, grow[p])
        rowsl.append((f, c))
    if longs:
        print(f"\nlong frames: {len(longs)}  cause: " + "  ".join(f"{k}:{v}" for k, v in cause.most_common()))
        print("summed growth over map median (ms): " + "  ".join(f"{p} {excess[p] / 1000:.0f}" for p in PHASES))
        pre = collections.Counter()
        for f in longs:
            nxt = fr[f["i"] + 1] if f["i"] + 1 < len(fr) else None
            if nxt:
                pre[nxt["steps"]] += 1
        print("steps in the iteration AFTER a long frame: " + "  ".join(f"{k}:{pre[k]}" for k in sorted(pre)))
        print(f"\nworst {a.top}:  t(s)  map  period  steps | input upd_cpp lua emit fab pace sleep | cpu nivcsw nvcsw minflt majflt upload cmds -> cause")
        for f, c in sorted(rowsl, key=lambda r: -r[0]["period"])[:a.top]:
            print(f"  {(f['t0'] - fr[0]['t0']) / 1e6:7.1f} {f['mapname']:>5} {fmt_ms(f['period']):>6} {f['steps']} | "
                  + " ".join(f"{fmt_ms(f[p]):>5}" for p in PHASES)
                  + f" | {fmt_ms(f['cpu']):>5} {f['nivcsw']:3} {f['nvcsw']:3} {f['minflt']:4} {f['majflt']} {f['upload']:6} {f['cmds']:5} -> {c}")
    # Dip episodes (osd < 55)
    dips = [(x, w) for x, w in osd if x < 55]
    if dips:
        print(f"\nosd dips < 55 ({len(dips)} windows): per-window excess over map median, summed (ms)")
        agg = collections.defaultdict(collections.Counter)
        for x, w in dips:
            m = w[0]["mapname"]
            for f in w:
                for p in PHASES:
                    agg[m][p] += max(0, f[p] - base[m][p])
            agg[m]["_n"] += 1
            agg[m]["_steps"] += sum(f["steps"] for f in w)
        for m, c in sorted(agg.items(), key=lambda kv: -kv[1]["_n"]):
            print(f"  map {m:>5}: {c['_n']} windows, steps/frame {c['_steps'] / (30 * c['_n']):.2f} | "
                  + "  ".join(f"{p} {c[p] / 1000 / c['_n']:.1f}" for p in PHASES))
    # Transition hitches (not active, but user-visible)
    mc = [f for f in fr if f["flags"] & FL["MAPCHANGE"]]
    if mc:
        hp = sorted((max(fr[j]["period"] or 0 for j in range(max(0, f["i"] - 2), min(len(fr), f["i"] + 3))), f["mapname"]) for f in mc)
        print(f"\nmap changes: {len(mc)}; worst iteration period around each (ms): "
              + ", ".join(f"{m}:{p / 1000:.0f}" for p, m in hp[-10:]))
    if a.csv:
        with open(a.csv, "w") as out:
            out.write("t_s,map,period," + ",".join(PHASES) + ",steps,cpu,nivcsw,minflt,majflt,upload,cmds,cause\n")
            for f, c in rowsl:
                out.write(f"{(f['t0'] - fr[0]['t0']) / 1e6:.3f},{f['mapname']},{f['period']}," + ",".join(str(f[p]) for p in PHASES)
                          + f",{f['steps']},{f['cpu']},{f['nivcsw']},{f['minflt']},{f['majflt']},{f['upload']},{f['cmds']},{c}\n")
    if a.prof:
        prof(d, fr, longs)
    if (d / "cpu.txt.gz").exists():
        preempt(d, fr, longs)


def prof(d, fr, longs):
    p = d / "prof.txt.gz"
    if not p.exists():
        print("no prof.txt.gz")
        return
    samples = []
    for line in gzip.open(p, "rt", errors="replace"):
        parts = line.split()
        if len(parts) < 3 or not parts[0].endswith(":"):
            continue
        t = float(parts[0][:-1]) * 1e6
        sym = parts[2] if len(parts) >= 3 else "?"
        dso = parts[-1].strip("()").rsplit("/", 1)[-1]
        samples.append((t, sym, dso))
    samples.sort()
    ts = [s[0] for s in samples]
    import bisect
    def agg(frames):
        c = collections.Counter()
        for f in frames:
            lo = bisect.bisect_left(ts, f["t0"])
            hi = bisect.bisect_left(ts, f["t0"] + f["period"])
            for s in samples[lo:hi]:
                c[f"{s[1]} [{s[2]}]"] += 1
        return c
    act = [f for f in fr if f["active"]]
    ca, cl = agg(act), agg(longs)
    na, nl = sum(ca.values()) or 1, sum(cl.values()) or 1
    print(f"\nprofile: {na} samples in active frames, {nl} in long frames")
    print("  share-all  share-long  symbol")
    for k, v in cl.most_common(40):
        print(f"  {100 * ca[k] / na:8.2f}%  {100 * v / nl:9.2f}%  {k}")


def preempt(d, fr, longs):
    """SCHED=1 trace: who ran on the main thread's CPU while a long frame was off-CPU."""
    import re, bisect
    info = (d / "info.txt").read_text().split()
    main_tid = info[2] if len(info) > 2 else ""
    rx = re.compile(r"^\s*(.+?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+):\s+(.*)$")
    runs = collections.defaultdict(list)   # cpu -> [(start, end, comm)]
    irqs = collections.defaultdict(list)
    cur = {}
    open_irq = {}
    main_cpu = collections.Counter()
    for line in gzip.open(d / "cpu.txt.gz", "rt", errors="replace"):
        m = rx.match(line)
        if not m:
            continue
        cpu, t, ev, tr = int(m[3]), float(m[4]) * 1e6, m[5], m[6]
        if ev == "sched:sched_switch":
            nm = re.search(r"next_comm=(.+?) next_pid=(\d+)", tr)
            if cpu in cur:
                c0, t0 = cur[cpu]
                runs[cpu].append((t0, t, c0))
            if nm:
                comm = nm[1] if nm[2] != main_tid else "MAIN"
                if nm[2] == "0":
                    comm = "idle"
                cur[cpu] = (comm, t)
                if comm == "MAIN":
                    main_cpu[cpu] += 1
        elif ev == "irq:irq_handler_entry":
            nm = re.search(r"name=(\S+)", tr)
            open_irq[cpu] = (t, nm[1] if nm else "?")
        elif ev == "irq:irq_handler_exit" and cpu in open_irq:
            t0, n = open_irq.pop(cpu)
            irqs[cpu].append((t0, t, n))
    mcpu = main_cpu.most_common(1)[0][0] if main_cpu else 0
    r = runs[mcpu]
    starts = [x[0] for x in r]
    tot, tot_irq = collections.Counter(), collections.Counter()
    for f in longs:
        a, b = f["t0"], f["t0"] + f["period"]
        i = max(0, bisect.bisect_left(starts, a) - 1)
        while i < len(r) and r[i][0] < b:
            s0, e0, c = r[i]
            ov = min(b, e0) - max(a, s0)
            if ov > 0 and c not in ("MAIN", "idle"):
                tot[c] += ov
            i += 1
        for s0, e0, n in irqs[mcpu]:
            if s0 >= a and s0 < b:
                tot_irq[n] += e0 - s0
    print(f"\nCPU{mcpu} (main thread's CPU) during {len(longs)} long frames: other tasks (ms)")
    for c, v in tot.most_common(15):
        print(f"  {v / 1000:8.1f}  {c}")
    print("  hard IRQs (ms): " + "  ".join(f"{n} {v / 1000:.1f}" for n, v in tot_irq.most_common(8)))


if __name__ == "__main__":
    main()
