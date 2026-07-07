#!/usr/bin/env python3
"""Symbolize a glibc LD_PROFILE .profile file (GMON_SHOBJ_VERSION layout,
see glibc elf/dl-profile.c) into an sprof-like flat profile + call pairs.

Layout (all little-endian, 32-bit ARM):
  0   : struct gmon_hdr   { char cookie[4]="gmon"; u32 version=0x1ffff; u8 spare[12]; }  (20 B)
  20  : u32 tag = GMON_TAG_TIME_HIST (0)
  24  : struct gmon_hist_hdr { u32 low_pc; u32 high_pc; u32 hist_size; u32 prof_rate;
                               char dimen[15]; char dimen_abbrev; }                      (32 B)
  56  : u16 kcount[hist_size]
  ... : u32 tag = GMON_TAG_CG_ARC (1)
  ... : u32 narcs  (via atomic counter; capacity = fromlimit)
  ... : struct here_cg_arc_record { u32 from_pc; u32 self_pc; u32 count; } []
"""
import struct, sys, bisect

profile_path, nm_path, flat_out, pairs_out = sys.argv[1:5]

d = open(profile_path, 'rb').read()
assert d[:4] == b'gmon', 'bad magic'
version = struct.unpack('<I', d[4:8])[0]
assert version == 0x1ffff, f'unexpected version {version:#x}'
tag0 = struct.unpack('<I', d[20:24])[0]
assert tag0 == 0, f'expected TIME_HIST tag, got {tag0}'
low, high, hist_size, rate = struct.unpack('<IIII', d[24:40])
kcount_off = 56
kcount_bytes = hist_size * 2
binsize = (high - low) / hist_size
kcount = struct.unpack(f'<{hist_size}H', d[kcount_off:kcount_off + kcount_bytes])

arc_tag_off = kcount_off + kcount_bytes
tag1 = struct.unpack('<I', d[arc_tag_off:arc_tag_off+4])[0]
if tag1 != 1:
    raise ValueError(f'expected CG_ARC tag (1) at offset {arc_tag_off}, got {tag1}')
narcs = struct.unpack('<I', d[arc_tag_off+4:arc_tag_off+8])[0]
arc_data_off = arc_tag_off + 8
cap = (len(d) - arc_data_off) // 12
n = min(narcs, cap)
arcs = [struct.unpack('<III', d[arc_data_off+i*12:arc_data_off+i*12+12]) for i in range(n)]

# Symbol table from `nm -S --defined-only | grep ' [tTwW] ' | c++filt`
syms = []  # (addr, size, name)
for line in open(nm_path):
    parts = line.rstrip('\n').split(None, 3)
    if len(parts) == 4:
        addr, size, typ, name = parts
    elif len(parts) == 3:
        addr, typ, name = parts; size = '0'
    else:
        continue
    try:
        syms.append((int(addr, 16), int(size, 16), name))
    except ValueError:
        continue
syms.sort()
addrs = [s[0] for s in syms]

def lookup(pc):
    i = bisect.bisect_right(addrs, pc) - 1
    if i < 0:
        return None
    a, sz, name = syms[i]
    if sz and pc >= a + sz:
        return None  # in a gap past the symbol's extent
    return name

# --- flat profile from histogram ---
per_sym = {}
unmapped = 0
total = 0
for i, c in enumerate(kcount):
    if not c:
        continue
    total += c
    pc = int(low + i * binsize + binsize / 2)
    name = lookup(pc)
    if name is None:
        unmapped += c
        name = f'<unmapped:{pc:#x}>'
    per_sym[name] = per_sym.get(name, 0) + c

with open(flat_out, 'w') as f:
    f.write(f'Flat profile of libsolarus.so.1 (LD_PROFILE, symbolized by sprof_parse.py; '
            f'glibc sprof broken by dlmopen assertion)\n')
    f.write(f'total samples: {total}  rate: {rate} Hz  => {total/rate:.2f} s of libsolarus self-time\n')
    f.write(f'text range: {low:#x}..{high:#x}  bins: {hist_size} x {binsize:.0f} B  '
            f'unmapped samples: {unmapped} ({100.0*unmapped/max(total,1):.2f}%)\n\n')
    f.write('  %   cumulative   self              self\n')
    f.write(' time   seconds   seconds    calls  name\n')
    cum = 0.0
    for name, c in sorted(per_sym.items(), key=lambda kv: -kv[1]):
        secs = c / rate
        cum += secs
        f.write(f'{100.0*c/total:6.2f} {cum:10.2f} {secs:9.2f}        -  {name}\n')

# --- call pairs ---
pair = {}
for frm, to, cnt in arcs:
    key = (lookup(frm) or f'<{frm:#x}>', lookup(to) or f'<{to:#x}>')
    pair[key] = pair.get(key, 0) + cnt
with open(pairs_out, 'w') as f:
    f.write(f'Call pairs (mcount arcs) of libsolarus.so.1 — narcs={narcs} (capacity {cap})\n\n')
    f.write('   calls  caller -> callee\n')
    for (a, b), c in sorted(pair.items(), key=lambda kv: -kv[1]):
        f.write(f'{c:9d}  {a} -> {b}\n')

print(f'total_samples={total} seconds={total/rate:.2f} unmapped_pct={100.0*unmapped/max(total,1):.2f} narcs={narcs}')
