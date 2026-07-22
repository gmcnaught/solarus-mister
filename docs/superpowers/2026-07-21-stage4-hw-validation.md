# Stage 4 — Delete Dead Paths — HW validation (2026-07-21)

**Result: PASS (operator-confirmed).** Engine-only deploy (`--no-rbf`) on the deployed
B2 tilemap RBF (`Solarus_20260721.rbf`, unchanged); device `192.168.20.81`.

## What was deployed
- `libsolarus.so.1.6.5` = the Task-4 armhf build, sha1 `8a56d13f1fe3415e254f173fe067ba0a8d21b6b1`
  (device sha1 verified identical after upload).
- Symbol check on the shipped `.so`: `mister_present_frame` **absent** (Stage 4 removal applied);
  input path symbols present.
- Quest: `mystery_of_solarus_dx.sol`. Launched directly via `S0_FILE` override (quest_manager
  idle on empty `Solarus.s0`, no two-engine wedge), logged to `/media/fat/logs/solarus_stage4.log`.

## Objective signals (controller-side)
- Engine ran clean (pid 25143); **no** error/segfault/undefined-symbol/missing-lib in the boot log.
- Frame counter `@0x3A000000` advancing (`0x13D994 → 0x13DB78`) — video live.
- Audio: `Connected to audio device 'Loopback'`, DDR3 ring + core-1 mix thread.
- **Key Stage-4 invariant confirmed in the log:** `[MiSTer] NativeVideoWriter_Init (from input poll) -> OK`
  — the live controller-input path (`NativeVideoWriter_Init`/`ReadJoystick` via `mister_poll_input`),
  which Task 4 **retained** while removing the SW-video present, initialised successfully after the
  removal. This is the exact path the plan's scope-correction was written to protect.
- Retained channels all enabled at boot: resident tile-list, scroll fabric (`SOLARUS_SCROLLFAB`),
  tilemap channel (`SOLARUS_TILEMAPCH`), paletted composition (`SOLARUS_PALETTE`, default-ON,
  322 surfaces 8bpp / 0 CLUT-overflow). Correctly **no** `overlay/sprite channel ENABLED` startup
  line — those flags were removed (channels hardwired ON), as designed.

## Operator visual confirmation (2026-07-21)
Operator confirmed **all good** on the HDMI output:
- Title/intro + menu/dialog render (unconditional Overlay channel).
- Overworld walk — player + sprites render and move (unconditional Sprite channel).
- Map transition renders cleanly (Scroll-fabric + Tilemap untouched).
- Audio playing + controller responsive (shared `0x3A000000` region + retained input path intact).

## Verdict
Stage 4 (delete dead paths) is **behavior-neutral on HW** — the SW-video-present removal, the
Overlay/Sprite hardwires, and the diagnostic removals changed nothing observable on the shipping
path, and the retained live-input path works. Ready to merge.
