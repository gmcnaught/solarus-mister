# Per-quest controller mapping — design

**Date:** 2026-07-25
**Status:** Approved. Revised 2026-07-25 after implementation — see "Revision: joypad
path dropped" below.
**Scope:** Engine (`patches/mister/`) + one two-line `CONF_STR` edit (RBF rebuild via CI)
+ `deploy.py` packaging.

## Problem

The MiSTer controller is unusable on most Solarus quests. `patches/mister/mister_native_video.cpp`
reads the FPGA joystick word from DDR3 each frame and synthesizes SDL **keyboard** events
through one hardcoded 9-entry table:

| MiSTer input (`CONF_STR J1`) | bit | key sent | assumed meaning |
| --- | --- | --- | --- |
| Right / Left / Down / Up | `0x001`–`0x008` | arrows | movement |
| 1st button | `0x010` | `c` | attack |
| 2nd button | `0x020` | `space` | action |
| 3rd button | `0x040` | `x` | item_1 |
| 4th button | `0x080` | `v` | item_2 |
| 5th button | `0x100` | `d` | pause |

That table is stock Solarus's *default keyboard bindings*
(`work/solarus/src/core/Savegame.cpp:174`). Mystery of Solarus DX uses exactly those, so
MoSDX works. Nothing else is obliged to.

### Evidence — Patched Tunics (`patched-tunics-b007e656.sol`)

PT does not use Solarus `GameCommands` at all. `lib/bindings.lua` implements a private
input layer over raw `on_key_pressed` / `on_joypad_button_pressed`, and
`lib/zentropy.lua:730` applies `bindings.mixin(the_game)` — so the private layer covers
**gameplay as well as menus**.

PT's own keyboard bindings, from `lib/bindings.lua`:

| action | key |
| --- | --- |
| attack | `s` |
| action | `space`, `return`, `kp return` |
| item_1 | `a` |
| item_2 | `d` |
| inventory | `w` |
| map | `tab` |
| escape | `escape` |
| directions | arrows |

Consequences of the hardcoded table on the device today:

- **Attack is unreachable** — PT's attack is `s`, we send `c`.
- The item_1 and item_2 buttons do nothing — PT wants `a` and `d`, we send `x` and `v`.
- **The pause button sends `d`, which PT reads as item_2**, not pause.
- Only the D-pad and `space` → action work.

**Every PT action has a keyboard binding.** The bug is purely that the table sends the
wrong keys. A per-quest table of the *right* keys fixes PT completely.

Two further details of PT's input layer, recorded because they were load-bearing in an
earlier draft of this design: `bindings.mixin` defines `on_joypad_axis_moved` but no
`on_joypad_hat_moved`, and its `on_key_pressed` ends with an unconditional `return true`
(it swallows keys it does not own — which is harmless, since it owns a key for every
action).

### Evidence — Zelda ROTH SE (`zelda-roth-se-v1.2.1.sol`)

ROTH uses stock `GameCommands` for movement/attack/action/items/pause, so [default]'s
stock keyboard bindings reach those. Its save-file menu (`scripts/menus/savegames.lua`)
handles `up`/`down`/`left`/`right`/`space` directly, and also mixes in
`gui_designer:map_joypad_to_keyboard` (`lib/gui_designer.lua:235-276`). It ships its own
remap menu (`scripts/menus/pause_commands.lua`) with both keyboard and joypad rows, so a
player can rebind the keyboard side in game.

**Correction (found during final review, 2026-07-25): ROTH is NOT profile-free.**
`scripts/game_manager.lua:27-32` sets six quest-private keyboard commands via
`game:set_value("keyboard_*", ...)` that live entirely OUTSIDE `GameCommands` and are
read back by direct key comparison, not through the command system: `keyboard_save =
"escape"`, `keyboard_run = "left shift"`, `keyboard_map = "p"`, `keyboard_monsters =
"m"`, `keyboard_look = "left control"`, `keyboard_commands = "f1"`. `escape` is the sole
entry point to `game:save()` (the save/quit dialog around `game_manager.lua:216-234`),
so without a mapping for it a player on the pad cannot save or quit. ROTH therefore has
its own `[zelda-roth-se-v1.2.1]` section in `controls.cfg.default`, mapping the three
highest-value commands (save, run, map) onto the three spare pad inputs (select, l, r);
the other three (monsters, look, commands) are reachable only by editing the file.

### Evidence — Mystery of Solarus DX

Stock `GameCommands` with stock keyboard defaults — identical to the built-in fallback.
The only one of the three quests that genuinely needs no section of its own.

## Approach

Keep synthesizing **keyboard** events from the FPGA joystick word, but replace the one
hardcoded table with a **per-quest table read from a config file**. Each MiSTer input
resolves to one SDL key, or to nothing.

That is the whole design. It is deliberately smaller than the first draft.

### Revision: joypad path dropped

The first version of this design presented the MiSTer pad to Solarus as an **SDL virtual
joystick** (`SDL_JoystickAttachVirtual`), with each input resolving to either a joypad
target or a key. It was implemented, reviewed, and reverted. Recorded here so the
reasoning is not rediscovered:

**Why it was proposed:** the belief that PT could not be reached by keyboard at all,
because its `on_key_pressed` swallows keys.

**Why that was wrong:** PT owns a key for every one of its seven actions (table above).
Keyboard reaches it completely. The premise was false.

**What the joypad path cost.** Every defect found during implementation was on the joypad
side, and none had a keyboard-side equivalent:

- A physical `Xbox 360 Controller` enumerates in SDL on the device (confirmed by an
  on-device probe), and Solarus binds to the *first* joystick it sees
  (`InputEvent.cpp:316`), so a virtual device could lose the race and be invisible to the
  polling APIs.
- Fixing that required patching `InputEvent::get_event()` — the engine's core input
  dispatch — including restructuring its event loop. The single riskiest change on the
  branch.
- `SDL_QuitSubSystem(SDL_INIT_JOYSTICK)`, reachable from Lua via
  `sol.input.set_joypad_enabled(false)`, frees every open joystick, leaving a dangling
  virtual-device pointer.
- The parser accepts `button 0..31` and `axis 0..7` while a virtual device has 8 buttons
  and 2 axes, so out-of-range targets parsed cleanly, logged cleanly, and did nothing.

**Why there is no double-fire risk to mitigate.** The concern was that the physical Xbox
pad might deliver events to SDL *in addition to* our synthesized input. It does not, and
the shipped build already proves it: `InputEvent::initialize` calls
`set_joypad_enabled(true)` unconditionally (`InputEvent.cpp:219`) and nothing in
`solarus_run.sh` disables it, so the existing keyboard bridge has always run with joypad
support live and that pad enumerated. Stock `GameCommands` binds keyboard *and* joypad by
default, so if events flowed, every press would fire twice and menu cursors would jump two
rows. Months of gameplay and repeated HW validation show no such symptom. Main_MiSTer
holds the device; SDL enumerates it but receives nothing.

**What is given up.** Quests' in-game *joypad* remap rows become unusable; their keyboard
remap rows still work (ROTH has both). A future quest with joypad-only bindings would need
this decision revisited. Neither costs anything on the three quests that exist here.

### Data flow

```
FPGA joystick_0 ──DDR3 0x008──> ReadJoystick() ──> per-quest key table ──> SDL_PushEvent(KEYDOWN/KEYUP)
```

Unchanged from today except that the table is loaded from config rather than compiled in.

### Components

**`patches/mister/mister_controls.h`** — pure, header-only, C-compatible profile parser.
No SDL, no DDR, no engine dependency; host-testable with plain `cc`. Parses `controls.cfg`,
selects a section, and exposes a 12-entry table mapping each MiSTer input to one target.

**`patches/mister/mister_native_video.cpp`** — the existing input bridge. Its hardcoded
`k_mister_keymap` is replaced by a lookup through the parsed profile; emission stays
edge-driven `SDL_PushEvent`, exactly as it is today. No new translation unit, so the CMake
source list inside `patches/series/0001-*.patch` is untouched.

**No changes to any upstream Solarus file.** There is no series patch in this design.

### Quest identity

`games/Solarus/solarus_run.sh` resolves the OSD pick from `Solarus.s0`, so it exports
`SOLARUS_QUEST_ID=<.sol basename>`. The loader falls back to `[default]` when the variable
is absent or the section is missing.

## Config format

**File:** `/media/fat/games/Solarus/controls.cfg`. Shipped by `deploy.py`, editable in
place on the SD card, read once at engine startup.

```
<up|down|left|right|a|b|x|y|l|r|select|start> = key <sdl key name> | none
```

`key` names resolve with `SDL_GetKeyFromName`, which accepts the same spellings Solarus
Lua uses (`space`, `escape`, `up`, `tab`, `s`). Comments start with `;` and run to end of
line. Section headers are `[quest-id]`. Whitespace around `=` is insignificant. CRLF is
tolerated (the SD card is FAT).

Layering: built-in defaults → `[default]` → `[<quest_id>]`. Later assignment wins, so a
quest section need only state its differences.

### `[default]` — stock Solarus keyboard bindings

Byte-for-byte `set_default_keyboard_controls()` (`Savegame.cpp:174`), which is also
byte-for-byte today's hardcoded table. Any quest whose input is *entirely* stock
`GameCommands` — MoSDX — works with no section of its own. ROTH's standard commands are
covered here too, but it still needs a section for the quest-private keys it reads
outside `GameCommands` (see its Evidence section above).

```ini
[default]
right = key right    left = key left    down = key down    up = key up
b     = key c        ; attack
a     = key space    ; action
y     = key x        ; item_1
x     = key v        ; item_2
start = key d        ; pause
l = none    r = none    select = none
```

### `[patched-tunics-b007e656]` — PT's own keys

```ini
right = key right    left = key left    down = key down    up = key up
b     = key s        ; attack
a     = key space    ; action
l     = key tab      ; map
r     = key w        ; inventory
y     = key a        ; item_1
x     = key d        ; item_2
start = key escape   ; escape / save menu
select = none
```

All seven PT actions reachable — the thing the hardcoded table cannot do.

### Input names and FPGA bits

Input names bind to `joystick_0` bits in `CONF_STR J1` entry order. `0x001`–`0x008` are
always the D-pad (Right, Left, Down, Up); buttons start at `0x010`.

After the `CONF_STR` change below: `a`=`0x010`, `b`=`0x020`, `x`=`0x040`, `y`=`0x080`,
`l`=`0x100`, `r`=`0x200`, `select`=`0x400`, `start`=`0x800`.

Note this regularizes an inconsistency in the old core, which named its first `J1` entry
"Sword" while its `jn` line mapped that entry to gamepad **A**. Under the new names, bit
`0x010` is physical A and carries `action`; `0x020` is physical B and carries `attack` —
the classic Zelda/LTTP layout. Players re-run "Define buttons" after the core change
regardless.

### Failure behavior

Never abort the engine over a config typo. Missing file → built-in defaults. Unknown quest
id → `[default]`. Unparseable line or unknown key name → log a warning naming the offending
line, treat that input as `none`.

## `CONF_STR` change

The core names only five buttons (`fpga/Solarus.sv:267`). Patched Tunics has seven distinct
actions, so five slots cannot reach them. Extend to eight quest-neutral names — the OSD
"Define buttons" screen should describe the *physical* pad, and `controls.cfg` assigns
per-quest meaning.

```systemverilog
"J1,A,B,X,Y,L,R,Select,Start;",
"jn,A,B,X,Y,L,R,Select,Start;",
```

**This is the only RBF edit**, and it is string-only:
`fpga/rtl/openbor_video_reader.sv:574` already writes the full 32-bit `joystick_0` to DDR3
(`ddr_din <= {32'd0, joystick_0}`), so buttons 6–8 reach the A9 with no datapath work.
Built via the existing `.github/workflows/build-rbf.yml` CI.

**Migration note for `docs/deploy-recipe.md`:** renaming and reordering the `J1` list
invalidates any existing `Solarus_input.map` in `/media/fat/config`. Re-run "Define buttons"
once after installing the new core.

## Testing

**Host tests** (`bash tests/run_tests.sh`) — the parser is pure and SDL-free:

- grammar: every target form parses; malformed lines, unknown key names and unknown
  sections degrade to `none`/`[default]` with a warning rather than aborting
- section selection: env var wins, `[default]` fallback
- the shipped profiles are asserted against their expected tables, reading the real
  `controls.cfg.default`, so a typo fails CI rather than the operator's evening

**Renderer type-check** — `g++ -fsyntax-only` with the mandatory
`-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`. Omitting them type-checks almost nothing and
has already produced one falsely-passing verification on this branch.

**Build plumbing — two traps that have bitten this project:**

- `scripts/apply_mister_files.sh` must copy `mister_controls.h` into the engine tree. This
  is the exact omission that recurred with `mister_pace.h` in PR #149, and it recurred
  again during this implementation.
- `deploy.py` must ship `controls.cfg.default` every deploy but seed `controls.cfg` only
  when absent, so SD-card edits survive.

**HW validation:**

1. **MoSDX regression gate** — it falls through to `[default]`, which is today's exact
   table, so any behavior change means the bridge rewrite itself broke.
2. **ROTH** — file-select, gameplay, and rebinding a key in its `pause_commands` menu.
3. **PT** — all seven actions, explicitly including map, inventory and escape, which are
   unreachable today.

`SOLARUS_INPUTDBG=1` traces every MiSTer bit edge and the key it emitted, so validation
rests on a log plus the operator's confirmation on screen. Per project rule, a frame is
never self-declared correct.

## Open risks

**Physical-pad double input.** Argued above to be a non-issue, on the strength of the
existing shipped build. Task 7 has the operator at the device, so it self-checks: if double
input appears, the fix is one call to `InputEvent::set_joypad_enabled(false)`.

**Unknown future quests.** Covered only by `[default]` (stock keyboard). A quest with
joypad-only bindings would need the joypad path reconsidered — see the revision note.
