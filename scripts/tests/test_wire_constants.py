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

H = {}
# BLT_OP_* / BLT_BLEND_* / BLT_FMT_* enumerators (all explicitly = N in the header)
for name in ("NOP", "END", "FILL", "BLIT", "STAGE", "TILELIST",
             "TILELIST_RES", "FRT_UPLOAD", "BGPLANE_WRITE"):
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

# ---- fabric side ---------------------------------------------------------
defs = read("fpga/rtl/blitter_defs.vh")
top = read("fpga/rtl/blitter_top.sv")
vram = read("fpga/rtl/vram_defs.vh")

F = {}
# opcodes: NOP..STAGE decode in blitter_top.sv; TILELIST.. in blitter_defs.vh
for name in ("NOP", "END", "FILL", "BLIT", "STAGE"):
    F[f"OP_{name}"] = grab(top, rf"OP_{name}\s*=\s*(\d+'[hdb][0-9a-fA-F_]+)", verilog_int, f"fabric OP_{name}")
for name in ("TILELIST", "TILELIST_RES", "FRT_UPLOAD", "BGPLANE_WRITE"):
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

# ---- comparison spec: (label, host value, fabric value) ------------------
checks = []
for name in ("NOP", "END", "FILL", "BLIT", "STAGE", "TILELIST",
             "TILELIST_RES", "FRT_UPLOAD", "BGPLANE_WRITE"):
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
checks.append(("SDRAM FB0 base", H["FB0_BASE"], F["FB0_BASE"]))
checks.append(("SDRAM FB1 base", H["FB1_BASE"], F["FB1_BASE"]))

# ---- tint byte positions (the real bug this gate exists to catch) --------
# Host packs: cb -> byte27, cr -> byte30, cg -> byte31 (blt_wire.h). Fabric reads
# each channel from a bit slice of cmd_qw[3] (bytes 24..31); byte = 24 + hi/8.
tint_expect = {"b": 27, "r": 30, "g": 31}
for ch, want in tint_expect.items():
    m = re.search(rf"c_cmod_{ch}\s*<=\s*cmd_qw\[3\]\[(\d+):(\d+)\]", top)
    if not m:
        MISSING.append(f"fabric c_cmod_{ch} slice")
        continue
    hi = int(m.group(1))
    got = 24 + hi // 8
    checks.append((f"tint byte c_cmod_{ch}", want, got))

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
