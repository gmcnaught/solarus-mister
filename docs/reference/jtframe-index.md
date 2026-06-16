# jtframe — framework index (one-page map)

A whistle-stop map of **jotego/jtcores `modules/jtframe`** (GPLv3), the reference
MiSTer/MiST/Pocket framework, so we can find prior art fast. Relevance column is
scored for **this** project (software-rendered Solarus → MiSTer DDR framebuffer;
FPGA work is SDRAM atlas source + scanout).

Upstream: `https://github.com/jotego/jtcores/tree/master/modules/jtframe`
Deep dive on the high-relevance bits: [SDRAM & scanout](./jtframe-sdram-scanout.md).

Relevance: 🔥 high (touches active work) · ◐ medium (useful pattern) · ○ low (not our path).

## HDL subsystems (`hdl/`)

| Area | Path | What it is | Rel. |
|---|---|---|---|
| **SDRAM** | `hdl/sdram/` | 3 controllers + burst: `jtframe_sdram64` (current, 4-bank), `jtframe_sdram_bank` (interleaved), `jtframe_sdram` (legacy), `jtframe_burst_sdram` (single-consumer). Caches, ROM/RAM slot arbiters, IOCTL download. | 🔥 |
| **Line frame buffer** | `hdl/video/jtframe_lfbuf_*` | Render→off-chip-RAM→scanout via 2 line buffers (4× BRAM), backends for DDR/SDRAM/SRAM/CRAM/BRAM. Zoom + rotation base. | 🔥 |
| **Scandoubler + rotate** | `hdl/video/rotate/` | `scandoubler_sdram.v`, `scandoubler_rotate.v`, `scandoubler_rgb_interp.v`, pixel/frac interp, unsigned division. SDRAM-backed scaler/rotator. | 🔥 |
| **Video timing/misc** | `hdl/video/` | `jtframe_vtimer`, `jtframe_resync`, `jtframe_scan2x`, `jtframe_blank`, `jtframe_framebuf`, `jtframe_credits`, `jtframe_logo`, tilemap/objscan/objdraw. | ◐ |
| **RAM primitives** | `hdl/ram/` | Dual-port RAM (`jtframe_dual_ram{,16,32}`), NVRAM, PROM, obj buffers, BRAM-as-ROM, MMR register file. | ◐ |
| **PSRAM** | `hdl/psram/` | Pseudo-static / cellular RAM controller (Pocket etc.). | ○ |
| **Clocking** | `hdl/clocking/` | `jtframe_frac_cen` (fractional clock-enable), `cen24/48/96`, `pxlcen`, cross-clock strobes, `jtframe_sync`, RTC. The `cen` discipline jtframe uses everywhere. | ◐ |
| **Board glue** | `hdl/jtframe_board*.v`, `jtframe_coremod.v` | Top-level board wiring, `core_mod` options bus, reset/watchdog, debug bus. | ○ |
| **Inputs** | `hdl/keyboard/` | `jtframe_inputs`, joysticks, mouse, dial/paddle, 4-way joy, PS/2 decode, pause. | ○ (we map inputs in SDL) |
| **Sound** | `hdl/sound/` | FIR/IIR filters, DC-removal, 1-bit/PWM DACs, gain mux, audio mixing nets. | ○ (audio is OpenAL→ALSA) |
| **CPUs** | `hdl/cpu/` | Wrappers: M68k, Z80, 6502/6809, 6801/6805 MCUs, 8051, Kabuki. | ○ |
| **Debug** | `hdl/debug/` | `jtframe_debug_bus`, sys info overlay, sim dumper, hex overlay. | ◐ (debug-bus pattern useful for our scanout bring-up) |
| **Cheat/lightgun/analogizer** | `hdl/{cheat,lightgun,analogizer}/` | Cheat engine, lightgun, Analogizer adapter. | ○ |

## Docs (`doc/`)

| File | Topic | Rel. |
|---|---|---|
| `sdram.md` | IOCTL indexes, `mem.yaml` generator, SDRAM timing/controllers, **MiSTer electrical gotchas** (slew rate, clock shift), catalogue. | 🔥 |
| `burst_sdram.md` | `jtframe_burst_sdram` runtime burst interface. | 🔥 |
| `jtframe-mem.md` | `mem.yaml` schema (banks vs cache-lanes, BRAM, clocks, audio). | ◐ |
| `clocks.md` | Clocking & clock-enable model. | ◐ |
| `macros.md` | All `JTFRAME_*` compile macros. | ◐ |
| `osd.md`, `jtframe-cfgstr.md`, `core_mod.md` | OSD menu, CONF_STR generation, core options. | ◐ (cf. our CONF_STR work) |
| `jtframe-mra.md`, `ip.md`, `folders.md`, `compilation.md` | MRA arcade ROM packaging, IP, repo layout, build flow. | ○ |
| `sim.md`, `simunit.md`, `debug.md`, `debug_list.md` | Simulation harness + unit tests, debug bus. | ◐ |
| `inputs.md`, `audio.md`, `cpus.md`, `mist.md` | Inputs, audio, CPU integration, MiST notes. | ○ |

## Tooling & targets

| Path | What |
|---|---|
| `bin/`, `src/jtframe` (Go), `src/jtutil` | The `jtframe` CLI: `mem`, `mra`, `cfgstr`, sim drivers, scaffolding. |
| `target/{mister,mist,pocket,sidi,sidi128,neptuno}/` | Per-platform top levels + constraints. **`target/mister/`** is our platform. |
| `syn/`, `ver/`, `verilator/`, `cc/` | Synthesis scripts, RTL testbenches, Verilator + C++ sim, C helpers. |
| `cfg/`, `mame/`, `asm/`, `devops/` | Core configs, MAME XML tooling, assemblers, CI/devops. |

## How we'd use it

We **don't** build on the jtframe core skeleton — our renderer is software in the
HPS writing DDR. So jtframe is a **pattern & RTL-snippet source**, not a dependency:

- For **#31 / SDRAM atlas source** → §1 of [the deep dive](./jtframe-sdram-scanout.md):
  `jtframe_sdram64` geometry/banking, HBlank refresh, `jtframe_burst_sdram`.
- For **scanout contention** → §2: `jtframe_lfbuf_*` line-buffer ping-pong;
  `hdl/video/rotate/scandoubler_sdram.v` if we ever scale/rotate in fabric.
- For **clean fabric clocking** → `hdl/clocking/jtframe_frac_cen` `cen` model.
- For **bring-up visibility** → `hdl/debug/jtframe_debug_bus` overlay pattern.

License: GPLv3 (compatible with our GPLv3 engine). Attribute jotego on any lift.
Memory pointer: [[fpga-jtframe-reference]].
