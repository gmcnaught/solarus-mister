# Per-quest controller mapping — design

**Date:** 2026-07-25
**Status:** Design approved, not yet implemented
**Scope:** Engine (`patches/mister/`) + SDL2 build flags + one two-line `CONF_STR` edit
(RBF rebuild) + `deploy.py` packaging.

## Problem

The MiSTer controller is unusable on most Solarus quests. `patches/mister/mister_native_video.cpp:63`
reads the FPGA joystick word from DDR3 each frame and synthesizes SDL **keyboard** events
through one hardcoded 9-entry table:

| MiSTer input (`CONF_STR J1`) | bit | key sent | assumed meaning |
| --- | --- | --- | --- |
| Right / Left / Down / Up | `0x001`–`0x008` | arrows | movement |
| B — "Sword" | `0x010` | `c` | attack |
| A — "Action" | `0x020` | `space` | action |
| Y — "Item 1" | `0x040` | `x` | item_1 |
| X — "Item 2" | `0x080` | `v` | item_2 |
| Start — "Pause" | `0x100` | `d` | pause |

That table is stock Solarus's *default keyboard bindings*
(`work/solarus/src/core/Savegame.cpp:174`). Mystery of Solarus DX uses exactly those, so
MoSDX works. Nothing else is obliged to, and the other two quests on the device do not.

### Evidence — Patched Tunics (`patched-tunics-b007e656.sol`)

PT does not use Solarus `GameCommands` at all. `lib/bindings.lua` implements a private
input layer over raw `on_key_pressed` / `on_joypad_button_pressed`, and
`lib/zentropy.lua:730` applies `bindings.mixin(the_game)` — so the private layer covers
**gameplay as well as menus**, not just menus.

PT's keys: `attack=s`, `action=space|return`, `item_1=a`, `item_2=d`, `inventory=w`,
`map=tab`, `escape=escape`, directions = arrows.

Consequences on the device today:

- **B (Sword) does nothing** — PT's attack is `s`, we send `c`. Attack is unreachable.
- Y and X do nothing.
- **Start sends `d`, which PT reads as item_2, not pause.**
- Only the D-pad and A (`space` → action) work.

PT also ships a complete joypad map — `button 0`=attack, `1`=action, `2`=map,
`3`=inventory, `4`=item_1, `5`=item_2, `6`=escape — and would work correctly if the
bridge emitted joypad events. Two details of that map are load-bearing:

1. `bindings.mixin` defines `on_joypad_axis_moved` but **no `on_joypad_hat_moved`**, so
   PT's directions must be delivered as **axes**, never as a hat.
2. `bindings.mixin`'s `on_key_pressed` ends with an unconditional `return true`, i.e. it
   swallows every key. No keyboard route can ever reach PT beyond its own seven keys.

### Evidence — Zelda ROTH SE (`zelda-roth-se-v1.2.1.sol`)

ROTH uses stock `GameCommands` and ships its own in-game remap menu
(`scripts/menus/pause_commands.lua`) with both keyboard and joypad rows. Most of its menus
handle joypad input via `scripts/menus/lib/gui_designer.lua`.

But its **save-file select menu (`scripts/menus/savegames.lua`) handles only
`on_key_pressed`**, and only for `up`, `down`, `left`, `right`, `space` — it has no joypad
handlers at all. A pure-joypad bridge leaves the player unable to pick a save file.

### Why the obvious fixes fail

- **Pure keyboard** (today) — breaks PT, which swallows all keys it does not own.
- **Pure joypad** — fixes PT completely, breaks ROTH's file select.
- **Emit both for every input** — `GameCommands::game_command_pressed`
  (`work/solarus/src/core/GameCommands.cpp:487`) calls `game.notify_command_pressed()`
  unconditionally, with no duplicate guard. Sending a keyboard *and* a joypad event for one
  physical press double-fires the command in every stock-`GameCommands` quest (MoSDX,
  ROTH), and double-steps the cursor in any menu handling both (e.g. ROTH's
  `language.lua`). Ruled out.
- **Joypad first, keyboard only if Lua reports the event unhandled** — the `handled` flag
  does propagate (`LuaContext::notify_input` → `MainLoop::notify_input:660`), but many Lua
  handlers act on an event and still return `nil`. PT's do. `nil` reads as unhandled, so
  this scheme injects spurious keyboard input precisely on the quest it is meant to fix.
  Ruled out.

## Approach

Present the MiSTer controller to the engine as a **real SDL virtual joystick**, and let a
small **per-quest profile** decide, for each MiSTer input *independently*, whether that
input is delivered as a joypad event or as a keyboard event — never both. One input, one
target: double-fire is structurally impossible.

This makes each quest's own control-remap screen the mapping UI wherever the quest has one
(the chosen UX), and confines the awkward cases to a few lines of config.

### Data flow

Today:

```
FPGA joystick_0 ──DDR3 0x008──> ReadJoystick() ──> fixed 9-entry key table ──> SDL_PushEvent(KEYDOWN)
```

Proposed:

```
                                     ┌─ mister_controls (profile) ─┐
FPGA joystick_0 ──DDR3──> ReadJoystick() ──> resolve each input ───┤
                                                                   ├─> SDL_JoystickSetVirtualButton/Axis/Hat
                                                                   └─> SDL_PushEvent(KEYDOWN/KEYUP)
```

### Components

**`patches/mister/mister_controls.{cpp,h}`** — pure profile loader. No SDL, no DDR, no
engine dependency. Parses `controls.cfg`, selects a section, and exposes a 12-entry table
mapping each MiSTer input to exactly one target. Host-testable in isolation.

**`patches/mister/mister_input.{cpp,h}`** — the SDL side. On first poll it calls
`SDL_JoystickAttachVirtualEx` (2 axes, 8 buttons, 1 hat, name `"MiSTer Controller"`), then
each frame edge-detects the DDR joystick word and, per the active profile, either updates
the virtual joystick's state or pushes a synthesized key event. Replaces `k_mister_keymap`
and `mister_poll_input()` in `mister_native_video.cpp`.

Both are whole-file copies under `patches/mister/`, not series patches — edit directly.

### Why a virtual joystick rather than hand-pushed joypad events

A device attached with `SDL_JoystickAttachVirtual` is a real `SDL_Joystick`: SDL generates
the events itself, *and* Solarus's polling APIs return true state —
`InputEvent::is_joypad_button_down` (`InputEvent.cpp:436`), `get_joypad_axis_state` (`:477`)
and `get_joypad_hat_direction` (`:501`) all call `SDL_JoystickGet*(joystick, …)` and return
false/0 when `joystick == nullptr`. Hand-pushed `SDL_JOYBUTTONDOWN` events would satisfy
event-driven code but silently fail every polling call.

Cost: `scripts/build_sdl2.sh:60` currently passes `--disable-joystick-virtual`. Flip to
`--enable-joystick-virtual` and rebuild SDL2 (~46 s).

### Quest identity

`games/Solarus/solarus_run.sh` already resolves the OSD pick from `Solarus.s0`, so it
exports `SOLARUS_QUEST_ID=<.sol basename>`. The loader falls back to the quest's
`write_dir` from `quest.dat` when the env var is absent (manual launches), then to
`[default]`.

## Config format

**File:** `/media/fat/games/Solarus/controls.cfg`. Shipped by `deploy.py`, editable in
place on the SD card, read at engine startup. No rebuild needed to fix or add a quest.

Left side is a MiSTer input; right side is exactly one target. The target vocabulary
mirrors Solarus's own joypad-string grammar (`GameCommands.cpp:241`) so profiles read the
same way quests write bindings:

```
<up|down|left|right|a|b|x|y|l|r|select|start> = button N
                                              | axis N +|-
                                              | hat up|down|left|right
                                              | key <sdl key name>
                                              | none
```

`key` names are resolved with `SDL_GetKeyFromName`, which accepts the same spellings Solarus
Lua uses (`space`, `escape`, `up`, `tab`, `s`). Comments start with `;` and run to end of
line. Section headers are `[quest-id]`. Whitespace around `=` is insignificant.

Diagonals need no special handling: two axis targets held at once (e.g. `up` and `right`)
produce a diagonal in both stock `GameCommands` and PT's `axis_commands` table.

### Input names and FPGA bits

The left-hand input names bind to `joystick_0` bits **in `CONF_STR J1` entry order** —
`0x001`–`0x008` are always the D-pad (Right, Left, Down, Up), and buttons start at `0x010`.

After M2 (`J1,A,B,X,Y,L,R,Select,Start`): `a`=`0x010`, `b`=`0x020`, `x`=`0x040`,
`y`=`0x080`, `l`=`0x100`, `r`=`0x200`, `select`=`0x400`, `start`=`0x800`.

**During M1 the core still ships the old five-entry `J1` list**, so only five button slots
exist. The loader binds `a`, `b`, `x`, `y`, `start` to `0x010`, `0x020`, `0x040`, `0x080`,
`0x100` in that order, and `l`, `r`, `select` are unreachable — any profile line targeting
them is parsed, logged as unreachable, and ignored. The profiles above are authored for the
M2 layout and need no edit at M2; only the OSD labels the user sees during M1 are the stale
semantic ones.

### `[default]` — all joypad, stock Solarus layout

Byte-for-byte the stock `set_default_joypad_controls()` (`Savegame.cpp:191`), so any
unauthored quest using stock `GameCommands` works with no profile written.

```ini
[default]
up    = axis 1 -
down  = axis 1 +
left  = axis 0 -
right = axis 0 +
a     = button 0   ; action
b     = button 1   ; attack
y     = button 2   ; item_1
x     = button 3   ; item_2
start = button 4   ; pause
l     = button 5   ; spare, remappable in-quest
r     = button 6   ; spare
select = button 7  ; spare
```

### `[mystery_of_solarus_dx]` — today's exact key table

Deliberately identical to the current hardcoded table, giving the quest the whole port was
validated against a zero-regression path. Any behavior change here means the bridge itself
broke.

```ini
[mystery_of_solarus_dx]
up = key up      down = key down    left = key left   right = key right
b  = key c       ; attack
a  = key space   ; action
y  = key x       ; item_1
x  = key v       ; item_2
start = key d    ; pause
l = none         r = none           select = none
```

### `[patched-tunics-b007e656]` — all joypad, PT's own numbering

Axes for movement (PT has no hat handler). All seven PT actions reachable — the thing the
current five-button table cannot do.

```ini
[patched-tunics-b007e656]
up    = axis 1 -
down  = axis 1 +
left  = axis 0 -
right = axis 0 +
b     = button 0   ; attack
a     = button 1   ; action
l     = button 2   ; map
r     = button 3   ; inventory
y     = button 4   ; item_1
x     = button 5   ; item_2
start = button 6   ; escape / save menu
select = none
```

### `[zelda-roth-se-v1.2.1]` — mixed; the case that justifies per-input targets

`savegames.lua` handles only `up/down/left/right/space` and has no joypad handlers, so those
five inputs must be keyboard. Everything else goes joypad so ROTH's `pause_commands` menu
can rebind it in-game. `key space` doubles as the stock `_keyboard_action` binding, so it
works in gameplay too.

```ini
[zelda-roth-se-v1.2.1]
up = key up      down = key down    left = key left   right = key right
a  = key space   ; file-select confirm AND stock _keyboard_action
b  = button 1    ; attack
y  = button 2    ; item_1
x  = button 3    ; item_2
start = button 4 ; pause
l = button 5     r = button 6       select = button 7
```

### Failure behavior

Never abort the engine over a config typo.

- Missing file → built-in `[default]`.
- Unknown quest id → `[default]`.
- Unparseable line or unknown key name → log a warning naming the offending line, treat that
  input as `none`.

## `CONF_STR` change

The core names only five buttons (`fpga/Solarus.sv:267`). Patched Tunics has seven distinct
actions, so five buttons cannot reach them however good the profile is. Extend to eight
quest-neutral names — the OSD "Define buttons" screen should describe the *physical* pad,
and `controls.cfg` assigns per-quest meaning.

```systemverilog
"J1,A,B,X,Y,L,R,Select,Start;",
"jn,A,B,X,Y,L,R,Select,Start;",
```

Bits become `0x010`=A, `0x020`=B, `0x040`=X, `0x080`=Y, `0x100`=L, `0x200`=R, `0x400`=Select,
`0x800`=Start.

**This is the only RBF edit.** `fpga/rtl/openbor_video_reader.sv:574` already writes the full
32-bit `joystick_0` to DDR3 (`ddr_din <= {32'd0, joystick_0}`), so buttons 6–8 reach the A9
with no datapath change — the two-line string edit plus a rebuild is the whole cost.

**Migration note, to be added to `docs/deploy-recipe.md`:** renaming and reordering the J1
list invalidates any existing `Solarus_input.map` in `/media/fat/config`. The user must
re-run "Define buttons" once after the reflash.

## Testing

**Host tests** (`bash tests/run_tests.sh`) — `mister_controls` is pure and SDL-free:

- grammar: every target form parses; malformed lines, unknown key names and unknown sections
  degrade to `none`/`[default]` with a warning rather than aborting
- section selection: env var wins, `write_dir` fallback, `[default]` fallback
- the four shipped profiles are asserted against their expected tables, so a typo in
  `controls.cfg` fails CI rather than the operator's evening

**Renderer type-check** — `g++ -fsyntax-only` with the mandatory
`-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`. Omitting them type-checks almost nothing and
has already produced one falsely-passing verification on this branch (see CLAUDE.md).

**Build plumbing — two traps to close explicitly, both of which have bitten this project:**

- `scripts/apply_mister_files.sh` must list `mister_controls.{cpp,h}` and
  `mister_input.{cpp,h}`. This is the exact omission that recurred with `mister_pace.h` in
  PR #149.
- `deploy.py` must ship the config but must not clobber a user-edited one: ship
  `controls.cfg.default` and copy to `controls.cfg` only when absent.

**HW validation, in order:**

1. **Enumeration probe, before building any mitigation.** Log `SDL_NumJoysticks()` and every
   joystick name at startup on the device. See "Open risks" below. No mitigation is written
   on speculation.
2. **MoSDX zero-regression gate.** Its profile is today's exact key table.
3. **ROTH.** File-select cursor and confirm (the keyboard route), then gameplay, then
   `pause_commands` rebinding a face button to a different joypad button and confirming it
   takes effect.
4. **PT.** All seven actions, explicitly including map, inventory and escape, which are
   unreachable today.

**Objective evidence.** `SOLARUS_INPUTDBG=1` traces every MiSTer bit edge and the target it
emitted, so validation rests on a log showing e.g. `bit 0x100 → button 2 (map)` plus the
operator's confirmation on screen. Per project rule, a frame is never self-declared correct.

## Milestones

Engine and RBF ship together in one deploy; these are validation milestones, not separate
ships.

- **M1 — engine + SDL2.** `--enable-joystick-virtual` rebuild, profile loader, virtual
  joypad, four profiles, against the current five buttons. Validates MoSDX no-regression and
  ROTH in full; PT reaches five of seven actions.
- **M2 — `CONF_STR`.** The two-line J1/`jn` edit plus RBF rebuild. Unlocks PT's remaining two
  actions and requires the one-time "Define buttons" re-run.

## Open risks

**Joystick enumeration race.** SDL also enumerates physical `/dev/input/event*` devices
(the device has `event0`–`event2` and `js0`), and Solarus binds to the *first* joystick it
sees — `InputEvent.cpp:316`, `if (joystick == nullptr)`. If a physical pad wins that race,
our virtual device's *events* still flow (event-driven `GameCommands` is unaffected) but
*polling* reads the wrong device. Main_MiSTer very likely `EVIOCGRAB`s those devices, making
them silent, but that is not assumed. M1's probe answers it; if a physical device does
appear, the mitigation is a small series patch making `InputEvent` prefer the joystick named
`"MiSTer Controller"`.

**SDL virtual-joystick backend on armhf.** SDL2 is built with `--disable-libudev`; the
virtual driver is independent of udev, but this is unproven on this toolchain. First smoke
test of M1.

**Axis deadzone.** Virtual axes must be driven to full ±32767. Solarus's default
`joypad_deadzone` is 10000 (`InputEvent.cpp:41`, applied at `:486`); anything smaller is
silently swallowed.
