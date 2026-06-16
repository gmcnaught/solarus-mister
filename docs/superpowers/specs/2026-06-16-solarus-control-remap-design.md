# Solarus control remap (OSD "Define buttons") — design

**Date:** 2026-06-16. **Status:** designed. **Productionization feature 1 of 3**
(feature 2 = OSD quest select, merged + HW-validated; feature 3 = core-change exit, merged).

## Problem / goal

Let the player remap which gamepad buttons map to Solarus' in-game commands, the way
most MiSTer cores do — via the framework's native **OSD → Define buttons** menu. No
custom remap UI.

## Background: the input path (verified)

```
USB pad ─> MiSTer hps_io ─> joystick_0 [31:0] bitmask ─> FPGA (openbor_video_top)
        writes bitmask to DDR3 (off 0x08) ─> engine mister_poll_input()
        edge-detects bits ─> synthesizes SDL keyboard events (fixed bit->key table)
        ─> Solarus default keyboard bindings ─> game command
```

- The MiSTer framework's **Define buttons** OSD is driven by the core's `CONF_STR`
  `J1,...` line. When the user redefines, the framework reorders `joystick_0` so each
  named button's bit reflects the chosen physical button. Our core passes `joystick_0`
  straight to DDR, so a per-core remap flows through to the engine unchanged.
- Engine bit→key table (`patches/mister/mister_native_video.cpp:95`, copied into the
  build by `scripts/build_engine.sh:29`) is already ordered:

  | joystick bit | engine key | Solarus command |
  |---|---|---|
  | 4 (0x010) | `c` | Sword (attack) |
  | 5 (0x020) | `SPACE` | Action |
  | 6 (0x040) | `x` | Item 1 |
  | 7 (0x080) | `v` | Item 2 |
  | 8 (0x100) | `d` | Pause |

## Gap

The `J1` line carries leftover OpenBOR-style names that don't match Solarus:

```
fpga/Solarus.sv:261   "J1,Attack,Jump,Special,Attack2,Start;"
```

So the Define-buttons OSD shows meaningless labels (`Jump`, `Special`, `Attack2`), and
the per-core remap has never been HW-verified to reach the engine through the DDR bridge.

## Change

**One line.** Rename the `J1` button list to match the engine table order:

```
fpga/Solarus.sv:261   "J1,Sword,Action,Item 1,Item 2,Pause;"
```

- Button order matches the bit→key table exactly (bit4=Sword … bit8=Pause), so the OSD
  labels are honest and **no engine/script change is needed**.
- Default out-of-box mapping is unchanged (B=Sword, A=Action, Y=Item 1, X=Item 2,
  Start=Pause) — a Zelda-like default.
- CONF_STR change → the RBF must be rebuilt (CI) and redeployed.

## Validation (the real work — front-loaded; this is the risk)

The native per-core remap reordering `joystick_0` through our DDR passthrough is the
unverified assumption. Test order on HW after the rebuilt RBF is deployed:

1. **Labels:** OSD → Define buttons lists `Sword / Action / Item 1 / Item 2 / Pause`.
2. **Default play:** with no redefine, in Mystery of Solarus DX — Sword swings the sword,
   Action talks/lifts, Item 1/2 use items, Pause opens the pause menu.
3. **GATING TEST:** redefine a button in the OSD (e.g. swap the physical buttons for
   Sword and Action), return to the game, and confirm the *new* physical button now
   triggers the remapped command. This proves the framework remap reorders `joystick_0`
   all the way to the engine.

**If the gating test fails** (redefine doesn't change in-game behavior): the native path
can't express a per-core remap for a DDR-passthrough core. **Stop, report the findings,
and re-brainstorm a custom approach as a separate effort** (per decision 2026-06-16). Do
not expand scope here.

## Out of scope
- Analog stick (Solarus is digital dpad only; `joystick_l_analog_0` stays unused).
- Per-quest in-engine rebinding (Solarus has its own quest-controlled input config).
- Players 2–4 (single-player quests).
- Any custom CONF_STR options or engine-side config file (only if the gating test fails,
  and then as a separate effort).

## Testing summary
- **Host:** none meaningful (the change is a CONF_STR string literal; no logic).
- **Device:** the 3-step validation above; gating test (#3) is the acceptance criterion.
