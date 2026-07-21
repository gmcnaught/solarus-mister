#!/usr/bin/env python3
# host<->fabric wire-protocol constant cross-check (issue #88).
#
# Opcode / blend / format / flag / geometry / DDR-base values are defined BY HAND
# on both sides of the f2h ring:
#   host   : patches/mister/blitter/blitter_ref.h           (enums + #defines)
#            patches/mister/mister_blitter_renderer.cpp      (DDR-layout constexprs)
#   fabric : fpga/rtl/blitter_defs.vh                        (`defines + localparams)
#            fpga/rtl/blitter_top.sv                          (decode localparams)
#            fpga/rtl/vram_defs.vh                            (SDRAM FB bases)
# Only the host has static_asserts; the fabric side has nothing, so a hand-edit
# on one side that forgets the other ships silently (this already caused a real
# tint-byte bug — bytes 27/30/31). This gate greps the numeric values from BOTH
# sides and asserts every documented pair is equal. Pure regex, no deps.
#
# Exit 0 = all pairs agree; exit 1 = at least one drifted (prints the offenders).

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DDR_REGION_BASE = 0x3B000000  # blitter DDR window base; OFF_* are region-relative


def read(rel):
    p = ROOT / rel
    if not p.exists():
        sys.exit(f"FATAL: source file not found: {rel}")
    return p.read_text()


def verilog_int(tok):
    """Parse a Verilog sized literal like 27'h0400000 / 8'd5 / 8'h40 -> int."""
    m = re.match(r"\s*\d+'([hdb])([0-9a-fA-F_]+)", tok)
    if not m:
        raise ValueError(f"not a verilog literal: {tok!r}")
    base = {"h": 16, "d": 10, "b": 2}[m.group(1)]
    return int(m.group(2).replace("_", ""), base)


def c_int(tok):
    """Parse a C integer literal (hex 0x.., decimal, trailing u/U)."""
    tok = tok.strip().rstrip("uU")
    return int(tok, 0)


def grab(text, pattern, conv, label):
    """Return conv(first capture group of pattern) or record a lookup failure."""
    m = re.search(pattern, text)
    if not m:
        MISSING.append(label)
        return None
    try:
        return conv(m.group(1))
    except ValueError as e:
        MISSING.append(f"{label} ({e})")
        return None


MISSING = []

# ---- host side -----------------------------------------------------------
ref = read("patches/mister/blitter/blitter_ref.h")
rnd = read("patches/mister/mister_blitter_renderer.cpp")
wire = read("patches/mister/blitter/blt_wire.h")

H = {}
# BLT_OP_* / BLT_BLEND_* / BLT_FMT_* enumerators (all explicitly = N in the header)
for name in ("NOP", "END", "FILL", "BLIT", "STAGE", "TILELIST",
             "TILELIST_RES", "FRT_UPLOAD", "BGPLANE_WRITE", "SPRITELIST", "TILEMAP"):
    H[f"OP_{name}"] = grab(ref, rf"BLT_OP_{name}\s*=\s*(\d+)", int, f"host BLT_OP_{name}")
for name in ("COPY", "COLORKEY", "CONST_ALPHA", "PALPHA", "ADD", "MULTIPLY"):
    H[f"BLEND_{name}"] = grab(ref, rf"BLT_BLEND_{name}\s*=\s*(\d+)", int, f"host BLT_BLEND_{name}")
for name in ("RGB565", "ARGB4444"):
    H[f"FMT_{name}"] = grab(ref, rf"BLT_FMT_{name}\s*=\s*(\d+)", int, f"host BLT_FMT_{name}")
# BLT_F_* flags (#define hex) + MAXP/MAXF
for name in ("HFLIP", "VFLIP", "COLORKEY", "STAGE_DST", "SRC_SDRAM", "SRC_FB", "COLORMOD", "BGCOV"):
    H[f"F_{name}"] = grab(ref, rf"#define\s+BLT_F_{name}\s+(0x[0-9A-Fa-f]+)", c_int, f"host BLT_F_{name}")
H["MAXP"] = grab(ref, r"#define\s+BLT_MAXP\s+(\d+)", int, "host BLT_MAXP")
H["MAXF"] = grab(ref, r"#define\s+BLT_MAXF\s+(\d+)", int, "host BLT_MAXF")
# DDR-layout constexprs (renderer)
H["OFF_TLBUF"] = grab(rnd, r"OFF_TLBUF\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host OFF_TLBUF")
H["TL_BUF_BYTES"] = grab(rnd, r"TL_BUF_BYTES\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host TL_BUF_BYTES")
H["FB0_BASE"] = grab(rnd, r"SDRAM_FB0_BASE\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host SDRAM_FB0_BASE")
H["FB1_BASE"] = grab(rnd, r"SDRAM_FB1_BASE\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host SDRAM_FB1_BASE")
# [Stage 2] SP_BUF (BLT_OP_SPRITELIST entry region). Both host constants are
# SYMBOLIC expressions, not literals, so they are RECOMPUTED here from the literals
# they are built out of rather than hardcoded — the whole point of this gate is that
# neither side is a copy of an expectation written into the test.
#   OFF_SPBUF    = OFF_CLUTBUF + CLUT_BANKS*CLUT_ENTRIES*8
#   SP_BUF_BYTES = 128 * 1024
_clutbuf = grab(rnd, r"OFF_CLUTBUF\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host OFF_CLUTBUF")
_banks = grab(rnd, r"CLUT_BANKS\s*=\s*(\d+)u?", int, "host CLUT_BANKS")
_ents = grab(rnd, r"CLUT_ENTRIES\s*=\s*(\d+)u?", int, "host CLUT_ENTRIES")
if None not in (_clutbuf, _banks, _ents):
    # sanity: the recomputation must match how the source spells CLUTBUF_BYTES,
    # so a change to that formula surfaces here instead of being silently ignored.
    if not re.search(r"CLUTBUF_BYTES\s*=\s*CLUT_BANKS\s*\*\s*CLUT_ENTRIES\s*\*\s*8u?", rnd):
        MISSING.append("host CLUTBUF_BYTES formula changed (SP_BUF base recompute stale)")
    H["OFF_SPBUF"] = _clutbuf + _banks * _ents * 8
else:
    H["OFF_SPBUF"] = None
_sp = re.search(r"SP_BUF_BYTES\s*=\s*(\d+)u?\s*\*\s*(\d+)u?", rnd)
if _sp:
    H["SP_BUF_BYTES"] = int(_sp.group(1)) * int(_sp.group(2))
else:
    MISSING.append("host SP_BUF_BYTES")
    H["SP_BUF_BYTES"] = None
# Guard the symbolic definition itself: if OFF_SPBUF stops being
# "OFF_CLUTBUF + CLUTBUF_BYTES", the recompute above is silently wrong.
if not re.search(r"OFF_SPBUF\s*=\s*OFF_CLUTBUF\s*\+\s*CLUTBUF_BYTES", rnd):
    MISSING.append("host OFF_SPBUF definition changed (no longer OFF_CLUTBUF+CLUTBUF_BYTES)")
# [Stage 2] Sprite-entry stride. This is the constant that changed 16->24 mid-branch
# and is precisely the drift class this gate exists to catch: the emitter/ref/wire
# struct size vs the fabric's per-entry advance (`tl_entry_stride` when tl_spr is
# set) must agree, or the fabric desyncs from entry #2 onward while entry #1 (and
# any single-entry test) still passes.
H["SPRITE_ENTRY_BYTES"] = grab(wire, r"#define\s+BLT_SPRITE_ENTRY_BYTES\s+(\d+)", int,
                                "host BLT_SPRITE_ENTRY_BYTES")
# [Stage 3b Phase B1 Task 3] GRID_BUF (BLT_OP_TILEMAP cell array region). Both
# constants are plain literals in the renderer (unlike OFF_SPBUF's symbolic
# expression), so a direct grab suffices, matching OFF_TLBUF/TL_BUF_BYTES above.
H["OFF_GRIDBUF"] = grab(rnd, r"OFF_GRIDBUF\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host OFF_GRIDBUF")
H["GRID_BUF_BYTES"] = grab(rnd, r"GRID_BUF_BYTES\s*=\s*(0x[0-9A-Fa-f]+u?)", c_int, "host GRID_BUF_BYTES")

# ---- fabric side ---------------------------------------------------------
defs = read("fpga/rtl/blitter_defs.vh")
top = read("fpga/rtl/blitter_top.sv")
vram = read("fpga/rtl/vram_defs.vh")

F = {}
# opcodes: NOP..STAGE decode in blitter_top.sv; TILELIST.. in blitter_defs.vh
for name in ("NOP", "END", "FILL", "BLIT", "STAGE"):
    F[f"OP_{name}"] = grab(top, rf"OP_{name}\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, f"fabric OP_{name}")
for name in ("TILELIST", "TILELIST_RES", "FRT_UPLOAD", "BGPLANE_WRITE", "SPRITELIST", "TILEMAP"):
    F[f"OP_{name}"] = grab(defs, rf"OP_{name}\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, f"fabric OP_{name}")
# blend modes: canonical `defines in blitter_defs.vh
for name in ("COPY", "COLORKEY", "CONST_ALPHA", "PALPHA", "ADD", "MULTIPLY"):
    F[f"BLEND_{name}"] = grab(defs, rf"`define\s+BLT_BLEND_{name}\s+(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, f"fabric BLT_BLEND_{name}")
# formats + flags: decode localparams in blitter_top.sv
for name in ("RGB565", "ARGB4444"):
    F[f"FMT_{name}"] = grab(top, rf"FMT_{name}\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, f"fabric FMT_{name}")
for name in ("HFLIP", "VFLIP", "COLORKEY", "STAGE_DST", "SRC_SDRAM", "SRC_FB", "COLORMOD"):
    F[f"F_{name}"] = grab(top, rf"F_{name}\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, f"fabric F_{name}")
# geometry
F["MAXP"] = grab(defs, r"localparam\s+integer\s+MAXP\s*=\s*(\d+)", int, "fabric MAXP")
F["MAXF"] = grab(defs, r"localparam\s+integer\s+MAXF\s*=\s*(\d+)", int, "fabric MAXF")
# DDR bases (qword-addressed on the fabric; x8 -> byte)
F["TL_BUF_QW"] = grab(defs, r"`define\s+TL_BUF_QW\s+(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric TL_BUF_QW")
F["TL_BUF_BYTES"] = grab(defs, r"TL_BUF_BYTES\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric TL_BUF_BYTES")
F["FB0_BASE"] = grab(vram, r"`define\s+SDRAM_FB0_BASE\s+(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric SDRAM_FB0_BASE")
F["FB1_BASE"] = grab(vram, r"`define\s+SDRAM_FB1_BASE\s+(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric SDRAM_FB1_BASE")
F["SP_BUF_QW"] = grab(defs, r"`define\s+SP_BUF_QW\s+(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric SP_BUF_QW")
F["SP_BUF_BYTES"] = grab(defs, r"SP_BUF_BYTES\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric SP_BUF_BYTES")
# [Stage 3b Phase B1 Task 3] GRID_BUF (BLT_OP_TILEMAP cell array region). Declaration
# only on the fabric side (no FSM yet -- B2 adds it); the base/size still cross-check
# here so host and fabric numbering never silently drift, same as every other region.
F["GRID_BUF_QW"] = grab(defs, r"`define\s+GRID_BUF_QW\s+(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric GRID_BUF_QW")
F["GRID_BUF_BYTES"] = grab(defs, r"GRID_BUF_BYTES\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, "fabric GRID_BUF_BYTES")
# [Stage 2] the tl_spr arm of the shared entry-stride mux (blitter_top.sv) is the
# fabric's per-entry advance for SPRITELIST; must equal the host's sizeof(entry).
F["SPRITE_ENTRY_BYTES"] = grab(top, r"tl_entry_stride\s*=\s*tl_spr\s*\?\s*(\d+'[hdb][0-9a-fA-F_]+)",
                                verilog_int, "fabric tl_entry_stride (tl_spr arm)")

# ---- comparison spec: (label, host value, fabric value) ------------------
checks = []
for name in ("NOP", "END", "FILL", "BLIT", "STAGE", "TILELIST",
             "TILELIST_RES", "FRT_UPLOAD", "BGPLANE_WRITE", "SPRITELIST", "TILEMAP"):
    checks.append((f"opcode {name}", H[f"OP_{name}"], F[f"OP_{name}"]))
for name in ("COPY", "COLORKEY", "CONST_ALPHA", "PALPHA", "ADD", "MULTIPLY"):
    checks.append((f"blend {name}", H[f"BLEND_{name}"], F[f"BLEND_{name}"]))
for name in ("RGB565", "ARGB4444"):
    checks.append((f"format {name}", H[f"FMT_{name}"], F[f"FMT_{name}"]))
for name in ("HFLIP", "VFLIP", "COLORKEY", "STAGE_DST", "SRC_SDRAM", "SRC_FB", "COLORMOD"):
    checks.append((f"flag {name}", H[f"F_{name}"], F[f"F_{name}"]))
checks.append(("geometry MAXP", H["MAXP"], F["MAXP"]))
checks.append(("geometry MAXF", H["MAXF"], F["MAXF"]))
# DDR bases: host is region-relative bytes; fabric TL_BUF is qwords. Normalise
# both to absolute byte addresses before comparing.
if H["OFF_TLBUF"] is not None and F["TL_BUF_QW"] is not None:
    checks.append(("TL_BUF base (abs byte)",
                   DDR_REGION_BASE + H["OFF_TLBUF"], F["TL_BUF_QW"] * 8))
checks.append(("TL_BUF size (bytes)", H["TL_BUF_BYTES"], F["TL_BUF_BYTES"]))
# [Stage 2] SP_BUF: same normalisation as TL_BUF (host region-relative bytes vs
# fabric qwords). This pair is what stops the sprite lane from silently aliasing
# FRT/CFT/CLUT if either side's base is edited alone.
if H["OFF_SPBUF"] is not None and F["SP_BUF_QW"] is not None:
    checks.append(("SP_BUF base (abs byte)",
                   DDR_REGION_BASE + H["OFF_SPBUF"], F["SP_BUF_QW"] * 8))
checks.append(("SP_BUF size (bytes)", H["SP_BUF_BYTES"], F["SP_BUF_BYTES"]))
checks.append(("sprite entry stride (bytes)", H["SPRITE_ENTRY_BYTES"], F["SPRITE_ENTRY_BYTES"]))
# [Stage 3b Phase B1 Task 3] GRID_BUF: same normalisation as TL_BUF/SP_BUF (host
# region-relative bytes vs fabric qwords).
if H["OFF_GRIDBUF"] is not None and F["GRID_BUF_QW"] is not None:
    checks.append(("GRID_BUF base (abs byte)",
                   DDR_REGION_BASE + H["OFF_GRIDBUF"], F["GRID_BUF_QW"] * 8))
checks.append(("GRID_BUF size (bytes)", H["GRID_BUF_BYTES"], F["GRID_BUF_BYTES"]))

# [Stage 3b Phase B2] Cell bitfield positions: grid_cell.h shifts <-> blitter_defs.vh localparams.
gc = read("patches/mister/blitter/grid_cell.h")
H["CELL_SUBX_LSB"]   = grab(gc, r"sub_x\s*&\s*0x0Fu\)\s*<<\s*(\d+)", c_int, "host cell sub_x shift")
H["CELL_SUBY_LSB"]   = grab(gc, r"sub_y\s*&\s*0x0Fu\)\s*<<\s*(\d+)", c_int, "host cell sub_y shift")
H["CELL_RUN_LSB"]    = grab(gc, r"run_m1\s*&\s*0x0Fu\)\s*<<\s*(\d+)", c_int, "host cell run shift")
H["CELL_PID_EMPTY"]  = grab(gc, r"BLT_GRID_PID_EMPTY\s+(0x[0-9A-Fa-f]+)u?", c_int, "host cell PID_EMPTY")
F["CELL_SUBX_LSB"]   = grab(defs, r"GRID_CELL_SUBX_LSB\s*=\s*(\d+)", int, "fabric cell sub_x LSB")
F["CELL_SUBY_LSB"]   = grab(defs, r"GRID_CELL_SUBY_LSB\s*=\s*(\d+)", int, "fabric cell sub_y LSB")
F["CELL_RUN_LSB"]    = grab(defs, r"GRID_CELL_RUN_LSB\s*=\s*(\d+)", int, "fabric cell run LSB")
F["CELL_PID_EMPTY"]  = grab(defs, r"GRID_CELL_PID_EMPTY\s*=\s*\d+'[hH]([0-9A-Fa-f]+)", lambda s: int(s, 16), "fabric cell PID_EMPTY")
checks.append(("cell sub_x LSB", H["CELL_SUBX_LSB"], F["CELL_SUBX_LSB"]))
checks.append(("cell sub_y LSB", H["CELL_SUBY_LSB"], F["CELL_SUBY_LSB"]))
checks.append(("cell run LSB",   H["CELL_RUN_LSB"],  F["CELL_RUN_LSB"]))
checks.append(("cell PID_EMPTY", H["CELL_PID_EMPTY"], F["CELL_PID_EMPTY"]))

# [Stage 3b Phase B3 Task 3] Cell-bitfield FULL-SLICE host<->RTL cross-check
# (B1->B2 handoff item #2). The B2 block above cross-checks each field's LSB
# between grid_cell.h and blitter_defs.vh's GRID_CELL_* localparams, but two gaps
# remain: (1) a coordinated edit that moves a field on BOTH sides equally still
# passes (nothing anchors to the frozen encoding), and (2) it never checks the
# actual DECODE consumer, so a decode that hardcodes a wrong literal or width
# slips past a localparam-only check. This block closes both: it reconstructs
# every field's full [hi:lo] slice on both sides and hard-asserts
#   (a) the host encoding equals the FROZEN tuple, and
#   (b) the RTL decode equals the host.
# NB: the design's `tilemap_unit` decode is INLINED into blitter_top.sv on this
# branch (no standalone fpga/rtl/tilemap_unit.sv), and it resolves the
# GRID_CELL_* localparams rather than using literal slices -- so the RTL slices
# are reconstructed from blitter_top.sv's grid_cell_word decode (the `grid_pid`/
# `grid_sub_x`/`grid_sub_y`/`grid_run` wires), resolving the localparam operands
# against blitter_defs.vh.
#
# Frozen encoding (grid_cell.h header block): pid[11:0] sub_x[15:12]
# sub_y[19:16] run_m1[23:20] spare[31:24].
EXPECTED_CELL_SLICES = {
    "pid_lo":  0, "pid_hi":  11,
    "subx_lo": 12, "subx_hi": 15,
    "suby_lo": 16, "suby_hi": 19,
    "run_lo":  20, "run_hi":  23,
}


def _mask_width(mask):
    """Width of a contiguous-from-bit-0 mask (the frozen cell masks all are)."""
    w = 0
    while mask & 1:
        w += 1
        mask >>= 1
    return w


def host_cell_slices():
    """Reconstruct each field's [hi:lo] from grid_cell.h's packer masks+shifts."""
    # blt_grid_cell_pack: (pid & 0x0FFFu) | (sub_x & 0x0Fu)<<12 | (sub_y..)<<16 | (run_m1..)<<20
    pid_m  = grab(gc, r"pid\s*&\s*(0x[0-9A-Fa-f]+)u",    c_int, "host cell pid mask")
    subx_m = grab(gc, r"sub_x\s*&\s*(0x[0-9A-Fa-f]+)u",  c_int, "host cell sub_x mask")
    suby_m = grab(gc, r"sub_y\s*&\s*(0x[0-9A-Fa-f]+)u",  c_int, "host cell sub_y mask")
    run_m  = grab(gc, r"run_m1\s*&\s*(0x[0-9A-Fa-f]+)u", c_int, "host cell run mask")
    subx_s, suby_s, run_s = H["CELL_SUBX_LSB"], H["CELL_SUBY_LSB"], H["CELL_RUN_LSB"]
    if None in (pid_m, subx_m, suby_m, run_m, subx_s, suby_s, run_s):
        return None

    def field(lo, mask):
        return lo, lo + _mask_width(mask) - 1

    d = {}
    d["pid_lo"],  d["pid_hi"]  = field(0,      pid_m)   # pid has no shift term (lo=0)
    d["subx_lo"], d["subx_hi"] = field(subx_s, subx_m)
    d["suby_lo"], d["suby_hi"] = field(suby_s, suby_m)
    d["run_lo"],  d["run_hi"]  = field(run_s,  run_m)
    return d


def rtl_cell_slices():
    """Reconstruct each field's [hi:lo] from blitter_top.sv's grid_cell_word
    decode, resolving the GRID_CELL_* localparam operands from blitter_defs.vh."""
    pid_w    = grab(defs, r"GRID_CELL_PID_W\s*=\s*(\d+)", int, "rtl GRID_CELL_PID_W")
    subx_lsb, suby_lsb, run_lsb = F["CELL_SUBX_LSB"], F["CELL_SUBY_LSB"], F["CELL_RUN_LSB"]
    if None in (pid_w, subx_lsb, suby_lsb, run_lsb):
        return None
    # Confirm the decode CONSUMES those localparams at the expected widths: pid is
    # [GRID_CELL_PID_W-1:0]; the other three are indexed part-selects
    # [GRID_CELL_<F>_LSB+3 -: 4]. A hardcoded literal or a changed width fails here.
    forms = {
        "pid":   r"grid_pid\s*=\s*grid_cell_word\[\s*GRID_CELL_PID_W\s*-\s*1\s*:\s*0\s*\]",
        "sub_x": r"grid_sub_x\s*=\s*grid_cell_word\[\s*GRID_CELL_SUBX_LSB\s*\+\s*3\s*-:\s*4\s*\]",
        "sub_y": r"grid_sub_y\s*=\s*grid_cell_word\[\s*GRID_CELL_SUBY_LSB\s*\+\s*3\s*-:\s*4\s*\]",
        "run":   r"grid_run\s*=\s*grid_cell_word\[\s*GRID_CELL_RUN_LSB\s*\+\s*3\s*-:\s*4\s*\]",
    }
    for fld, pat in forms.items():
        if not re.search(pat, top):
            MISSING.append(f"rtl blitter_top.sv grid_cell_word decode ({fld}) form changed")
            return None
    return {
        "pid_lo":  0,        "pid_hi":  pid_w - 1,
        "subx_lo": subx_lsb, "subx_hi": subx_lsb + 3,
        "suby_lo": suby_lsb, "suby_hi": suby_lsb + 3,
        "run_lo":  run_lsb,  "run_hi":  run_lsb + 3,
    }


host_cell = host_cell_slices()
rtl_cell = rtl_cell_slices()
assert host_cell == EXPECTED_CELL_SLICES, \
    f"grid_cell.h bitfields drifted from frozen encoding: host={host_cell} expected={EXPECTED_CELL_SLICES}"
assert rtl_cell == host_cell, \
    f"RTL cell decode slices disagree with host: rtl={rtl_cell} host={host_cell}"
print(f"  ok  cell bitfields (host==rtl==frozen)  = {host_cell}")

checks.append(("SDRAM FB0 base", H["FB0_BASE"], F["FB0_BASE"]))
checks.append(("SDRAM FB1 base", H["FB1_BASE"], F["FB1_BASE"]))

# ---- tint byte positions (the real bug this gate exists to catch) --------
# TWO-SIDED: neither side is hardcoded (issue #88 reviewer follow-up — a one-sided
# check with a hardcoded host expectation would miss a host-only repack).
#
# HOST byte offsets are parsed from the authoritative packer blt_pack_cmd() in
# blt_wire.h: each `c->_pad[IDX] << SHIFT` is governed by the nearest preceding
# `blt_wr32(out+OFF, ...)`, so the wire byte = OFF + SHIFT/8. The _pad-slot ->
# channel map (_pad[2]=cb, _pad[0]=cr, _pad[1]=cg) is likewise parsed from the file.
# FABRIC byte offsets come from the c_cmod_{ch} bit-slices of cmd_qw[3] (bytes
# 24..31): byte = 24 + hi/8. If EITHER side moves a channel, the pair drifts.
def host_tint_bytes():
    # map _pad slot -> channel letter, from "_pad[2]=cb ... _pad[0]=cr ... _pad[1]=cg"
    slot_ch = {int(i): c for i, c in re.findall(r"_pad\[(\d+)\]\s*=\s*c([brg])", wire)}
    if len(slot_ch) < 3:
        return None, "host _pad->channel map"
    # every blt_wr32(out+OFF, with its position, to attribute each _pad<<SHIFT
    writes = [(m.start(), int(m.group(1)))
              for m in re.finditer(r"blt_wr32\(\s*out\+(\d+)\s*,", wire)]
    if not writes:
        return None, "host blt_wr32(out+..) sites"
    out = {}
    for m in re.finditer(r"c->_pad\[(\d+)\]\s*<<\s*(\d+)", wire):
        slot, shift = int(m.group(1)), int(m.group(2))
        if slot not in slot_ch:
            continue
        off = max((o for pos, o in writes if pos < m.start()), default=None)
        if off is None:
            return None, "host _pad write offset"
        out[slot_ch[slot]] = off + shift // 8
    return out, None

host_bytes, err = host_tint_bytes()
if err:
    MISSING.append(err)
for ch in ("b", "r", "g"):
    m = re.search(rf"c_cmod_{ch}\s*<=\s*cmd_qw\[3\]\[(\d+):(\d+)\]", top)
    fabric_byte = 24 + int(m.group(1)) // 8 if m else None
    if m is None:
        MISSING.append(f"fabric c_cmod_{ch} slice")
    host_byte = host_bytes.get(ch) if host_bytes else None
    if host_byte is None and host_bytes is not None:
        MISSING.append(f"host tint byte c{ch}")
    checks.append((f"tint byte c{ch}", host_byte, fabric_byte))

# ---- report --------------------------------------------------------------
fails = []
for label, hv, fv in checks:
    if hv is None or fv is None:
        fails.append(f"  {label:<26} : MISSING (host={hv} fabric={fv})")
    elif hv != fv:
        fails.append(f"  {label:<26} : DRIFT  host=0x{hv:X}({hv})  fabric=0x{fv:X}({fv})")
    else:
        print(f"  ok  {label:<26} = 0x{hv:X} ({hv})")

if MISSING:
    print("\nCONSTANTS THAT COULD NOT BE PARSED (regex/source drift):")
    for m in MISSING:
        print(f"  - {m}")

if fails or MISSING:
    print("\nWIRE-CONSTANT CROSS-CHECK FAILED:")
    for f in fails:
        print(f)
    sys.exit(1)

print(f"\nWIRE-CONSTANTS OK — {len(checks)} host<->fabric pairs agree")
