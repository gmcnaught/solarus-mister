# Quest GLSL shader census — what a fabric offload would have to implement

**Date:** 2026-08-07. **Evidence tier: static source analysis of published quests.**
Nothing here has been run on the engine or the device. Shader sources were read from
their upstream repositories; no quest was launched.

This supersedes the null result in `docs/quest-compatibility.md` ("Zero quests use
`sol.shader`"). That statement is correct **for its 7-quest corpus** and wrong as a
statement about the ecosystem: a GitHub code search for the Solarus builtin uniform
`sol_texture` in `*.glsl` returns **107 files across 20 repositories**.

## Where shaders attach (engine truth, Solarus 1.6.5)

Exactly two attach points, and they matter because they land in different places in
this port's datapath:

| API | Engine site | What it shades | Fabric insertion point |
|---|---|---|---|
| `sol.video.set_shader(s)` | `Video.cpp:374-397` | the final screen composite | the linear pixel stream at `fb_ddr_writer` / scanout |
| `drawable:set_shader(s)` | `Drawable.h:84`, `Drawable.cpp:445` (the shader **becomes** the `DrawProxy`) | one surface's draw | before the overlay blit, or per-blit |

The common quest idiom is the second one applied to the **camera surface**
(`map:get_camera():get_surface():set_shader(s)`) — deliberately, so the effect
distorts the world but not the HUD or dialog box. In this port the camera surface's
content is the WORK framebuffer at the moment before the overlay is composited last,
so both attach points reduce to *a stage over a linear pixel stream*. That is the
useful structural finding: neither requires per-blit shading.

Uniform surface a shader can use: `set_uniform` 1b/1i/1f/2f/3f/4f and
`set_uniform_texture`, plus builtins `sol_texture`, `sol_input_size`,
`sol_output_size`, `sol_time`, `sol_opacity`, `sol_mvp_matrix`, `sol_uv_matrix`
(`Shader.h:41-81`, `ShaderApi.cpp:42-56`).

## The blocker that shapes the whole design

Shaders are off **before GL is even considered**:

```cpp
// work/solarus/src/graphics/sdlrenderer/SDLRenderer.cpp:74
bool shaders = not force_software and SDLShader::initialize();
```

We always launch `-force-software-rendering`, and separately the armhf build has no
libGL at all (`SDLShader` is a `Gl::load()` context hack). So `sol.shader.create`
cannot succeed today by any route.

**Consequence: the offload cannot be a GLSL compiler.** It has to be
*recognition-based* — a `MisterShader : Shader` returned from
`MisterBlitterRenderer::create_shader()` that matches the shader id and a hash of its
source against a table of effects the fabric implements, and falls back to
**unshaded passthrough** (not a crash, not a black screen) on anything unrecognized.
Every design decision below follows from that.

## Effect classes, ordered by fabric cost

### Class A — per-pixel color transform, no taps, no state
Constant (or per-frame-constant) per-channel gain/bias, or a colour LUT. **The
compositor already has this datapath** (`colormod`, pipelined at stage s3).

`sepia`, `grayscale`, `toon`, `chroma`, `flashing_rgb`, `fr_to_normal_colors`,
`normal_to_fr_colors`, `fr_white_filter`, `index_palette_shader`, `hurt`,
`poisoned_effect`, and the tint half of `heatwave`.

Worked example — `heatwave`'s tint reduces to a **constant per-channel gain**:
`mix(c, c*TINT*2, 0.35)` with `TINT=(1.0,0.25,0.05)` is `c * (0.65 + 0.7*TINT)` =
`c * (1.35, 0.825, 0.685)`, plus a per-frame additive `sin` glow of ≤0.06. No
per-pixel work beyond what `colormod` already does.

### Class B — per-row (or per-column) UV displacement
A raster/line-scroll effect: source X biased by a value that depends only on `y` and
time. Costs a small addend in span setup; no extra memory, no extra bandwidth.

`heatwave` ripple, `distorsion`/`distort`, `heat_wave`, `fire_dist`,
`pixellisation` (coordinate quantize), `radial_fade_out`, `shockwave`.

> **Sub-pixel caveat, measured:** `heatwave`'s displacement is `RIPPLE_AMOUNT/100` =
> 0.002 in normalized coords — **0.64 px at 320 wide, 0.83 px at zbom's native 416**.
> Without sub-pixel filtering it quantizes to 0 or ±1 px. The visible part of that
> shader is overwhelmingly its Class A tint and glow pulse, not its ripple. Do not
> build sub-pixel interpolation for it before checking that against the operator's eye.

### Class C — neighborhood taps, multi-pass, or render-target feedback
Needs new datapath and on-chip storage. Not a first target.

`blur`, `median_blur`, `heavy_bloom`, `edge-detection`, `curvature`,
`noise_dither`, `water_effect` (three samplers: `sol_texture`, `fsa_texture`,
`reflection`, plus a 5-key colour-match), `mode_7`.

**`cast_shadow1d` + `make_shadow1d` are the hard case and the most *essential* one.**
This is the `light_manager.lua` dynamic-lighting system shared by zelda-hsa,
zelda-alttd, defi_zeldo and labors_zeldo. It is two passes over per-light render
targets: `make_shadow1d` ray-marches a `for (y=0; y<resolution.y; y++)` loop with an
early break to build a 1-D shadow map, then `cast_shadow1d` does a 9-tap angular blur
plus a cone/halo term with six live uniforms (`resolution`, `lcolor`, `dir`,
`aperture`, `halo`, `cut`, `oscillate`). A fabric equivalent is a purpose-built
light-cone unit, not a shader stage. Scope it separately or not at all.

### Class D — screen post-process family (user-selectable, never essential)
`hq2x`/`hq4x`/`6xbrz`/`scale2x`, `ntsc2pal`/`pal2ntsc`, `CRT-interlaced`, `lcd`,
`gb`, `tft`, `waterpaint`, `film_grain`. These are the "pick a filter" menu family
and map to MiSTer's shared `video_mixer`/scanline chain rather than to the
compositor — see `docs/video-mixer-integration.md` on branch
`claude/solarus-fpga-shader-feasibility-23ser4`, where **Phase 1 (scanlines +
shadow mask) is implemented but unmerged** and **Phase 2 (`video_mixer`: gamma +
HQ2x) was reverted because it overflows the Cyclone V** (`1e20e24`).

## Corpus

| Repo | Shaders | Uses a shader as an essential visual element? |
|---|---|---|
| `team-zhsa/zelda-hsa` | 38 | Yes — `light_manager.lua` (Class C shadow casting), plus gb/tft map effects |
| `KaKaShUruKioRa/The-Only-One-Project` | 20 | Filter family (Class D) + colour remap (A) |
| `aruffie/zelda-alttd-local-fork` | 20 | Yes — same `light_manager.lua` lighting system |
| `hydralerna/ZL-project` (Skylands of Solarus) | 16 | Yes — `index_palette_shader` (A), gb_effect |
| `wrightmat/zbom` (Book of Mudora) | 10 | **Yes — exactly one:** `heatwave` |
| `ZeldoRetro/defi_zeldo_chap_2`, `ZeldoRetro/labors_zeldo` | 8 each | Yes — `light_manager.lua` + `fsa_effect` |
| `Zunashy/ZeldaFallenRealm` | 6 | Yes — `obscurity`, `poisoned_effect`, `shockwave` |
| `KaKaShUruKioRa/A-Link-to-the-Past-Project` | 2 | Colour remap on one map (A) |
| resource packs (`Zunashy/GameboyRessourcePack`, `Numherilab/*`, `AlisdairPage/ProjectOhros`) | 2 each | Filter family only (D) |

(Five further hits — `Kangie/solarus`, `capsterx/solarus`, `Shin2W/solarus`,
`Cpasjuste/solarus`, `xinus-game/solarus` — are forks of the **engine**, matching on
its `tests/testing_quest` `scale2x`/`sepia` samples, not quests.)

## The two named targets

### `wrightmat/zbom` — Zelda: Book of Mudora

The shader picture is better than the 10-file count suggests. `shader_manager.lua`
is a **user-cycled full-screen filter menu** (`switch_shader()` walks
`sol.main.get_resource_ids("shader")`), and `game_manager.lua:41-43` merely restores
the player's saved pick. All of that is Class D and cosmetic — a quest that ignores
it looks correct.

The one gameplay-essential use is `data/maps/9.lua:38-39`:

```lua
local shader = sol.shader.create("heatwave")
camera_surface:set_shader(shader)   -- cleared again at :58
```

`heatwave.dat` declares only `fragment_file`; the shader takes **no uniforms except
`sol_texture` and `sol_time`** (every tunable is a `#define`). It is Class A + Class
B — the cheapest possible first target.

**But zbom is blocked on two things that have nothing to do with shaders**, from its
`quest.dat`:
- `solarus_version = "2.0"` → needs the opt-in 2.x engine line (`docs/solarus2.md`),
  which is HW-validated for a static scene only.
- `normal/min/max_quest_size = "416x240"` — min == max, so `-quest-size` cannot
  negotiate it down. Our framebuffer is `BLT_FB_WIDTH 320` / `BLT_FB_HEIGHT 240`
  (`patches/mister/blitter/blitter_ref.h:38-39`). This is the `TOO_LARGE` rung the
  compat gate declared NO-GO when 0/7 corpus quests needed it. zbom needs it.
  Stage 5 Phase 2 freed ~158 M10K (89% → 61% BRAM), so a 416-wide WORK FB plausibly
  fits now — **unverified**, and it touches the wire ABI, the compositor and scanout.

### Ocean's Heart — surveyed from the retail quest

Read from `depots/1393751/12056360/data.solarus` (a stored-compression zip, 865 Lua
files). `quest.dat`:

```
solarus_version = "1.6",
normal_quest_size = "416x240",  min = max = "416x240",
```

**It declares 1.6, so it runs on the ship engine — and it needs the same 416×240
framebuffer zbom does, with min == max.** The resolution rung, not the engine line
and not shaders, is what blocks this game.

It ships **exactly two shader uses, neither of them load-bearing**:

1. **`noise_reducer`** (`shaders/noise_reducer.frag.glsl`) — applied to *sprites*,
   not the screen: `sprite:set_shader(sol.shader.create("noise_reducer"))` on the
   `windmill_blades` entities of three Fykonos maps (`pirate_fort.lua:12`,
   `west_trail.lua:12`, `lone_windmill.lua:12`). Those sprites are being spun by a
   `sprite:set_rotation()` timer, so the shader is a 4-tap rotated-grid supersample
   (offsets scaled by `dFdx`/`dFdy`) that exists to hide rotation aliasing. Without
   it the blades are aliased, not absent. Its `.dat` also carries
   `scaling_factor = 1.72453e-307` — an uninitialised denormal, harmless here only
   because the per-drawable path never consults it (`Video.cpp:377` does).
2. **`swipe_fade`** (`scripts/fx/swipe_fade.lua`, Llamazing, GPL-3.0) — built **from
   inline source** via `sol.shader.create{fragment_source=[[...]]}`, driven by a live
   `position` uniform from a 10 ms timer, and applied to the map-name banner's
   `text_surface` (`scripts/menus/map_banner.lua:176`). The whole shader is
   `alpha = 1.0 - 4.0*clamp(position - x, 0.0, 0.25)` — a **per-column alpha ramp**,
   Class A/B, and about as cheap as an effect gets.

Two consequences for the design. First, a recognition-based dispatcher **must key on
a hash of the source, not only on the shader id**, because `swipe_fade` has no id.
Second, it must handle a shader bound to an ordinary **sprite**, not just to the
camera surface or the screen — so the "one stage over a linear pixel stream" framing
above covers the screen and camera cases but not this one, which needs the effect
attached to a single blit.

## Implication for the offload design

1. Recognition, not compilation: id + source-hash → effect table; unknown → passthrough.
2. Both attach points reduce to one stage over a linear pixel stream; build the stage
   once and let the engine choose where it is inserted.
3. Class A first (it reuses `colormod`), Class B second (a per-row X bias in span
   setup). Class C is a separate project. Class D belongs to the `video_mixer` track,
   which is device-limited and already assessed.
4. `heatwave` is the natural first effect — one essential shader, no uniforms, and it
   exercises A and B together.
5. **The resolution rung outranks all of it for the two named targets.** zbom
   (`2.0`, 416×240) and Ocean's Heart (`1.6`, 416×240) both declare `min == max ==
   416x240`, so neither can be negotiated down with `-quest-size` and neither renders
   at any shader-completeness level until `BLT_FB_WIDTH` grows. And of the three
   shaders those two games actually use, one is essential (`heatwave`) and two are
   polish (`noise_reducer` anti-aliases spinning windmill blades; `swipe_fade` fades
   a map-name banner). Shader offload is not what stands between this port and either
   game.
