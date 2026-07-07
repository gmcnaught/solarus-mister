#!/bin/bash
# Validate patches/series.manifest against build_engine.sh modification points:
# boundaries ascending, unique, each an actual modification close-line, and the
# last boundary equals the last modification point (nothing dropped after it).
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import re
lines=open("scripts/legacy/build_engine_patchphase.sh").read().splitlines()
mods=[]; open_tag=None
for i,l in enumerate(lines,1):
    if i>2345: break
    m=re.search(r"<<'(PY[A-Z0-9]+)'", l)
    if m: open_tag=m.group(1)
    if open_tag and l.strip()==open_tag: mods.append(i); open_tag=None
    if re.match(r'^\s*edit_inplace ', l): mods.append(i)
    if re.match(r'^\s*perl ', l): mods.append(i)
    if re.match(r'^\s*python3 scripts/patch_quadtree_fat', l): mods.append(i)
mods=sorted(mods)
bnds=[]
for l in open("patches/series.manifest"):
    l=l.split("#")[0].strip()
    if not l: continue
    cl,slug,subj=[x.strip() for x in l.split("|",2)]
    bnds.append(int(cl))
assert bnds==sorted(bnds), f"boundaries not ascending: {bnds}"
assert len(set(bnds))==len(bnds), "duplicate boundary line"
assert max(bnds)==max(mods), f"last boundary {max(bnds)} != last mod {max(mods)}"
assert all(m<=max(bnds) for m in mods), "a modification falls after the last boundary"
missing=[b for b in bnds if b not in mods]
assert not missing, f"boundary lines that are NOT modification points: {missing}"
print(f"MANIFEST OK: {len(mods)} modification points -> {len(bnds)} feature boundaries")
PY
