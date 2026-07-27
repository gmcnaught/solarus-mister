# Quest compatibility pass — design

**Date:** 2026-07-27
**Status:** Approved (brainstorm), pending implementation plan.
**Scope:** Host tooling (`scripts/`), engine (`patches/mister/`), SD-mirror packaging,
device test harness. **No RTL.** No change to the shipped RBF.

## Problem

The port is validated against exactly one quest. `README.md` says it plainly: *"Quest
compatibility is validated primarily against Mystery of Solarus DX; other quests should
work but are less tested."* Nobody knows what "less tested" means, because nothing has
measured it.

Three specific gaps sit behind that sentence:

1. **A quest that does not fit 320×240 produces a black screen with no explanation.**
   `mister_blitter_renderer.cpp:1448` (`is_fpga_target`) refuses any render target that
   is not *exactly* 320×240, and Stage 4 deleted the software present path, so there is
   no fallback and no message — just nothing on the display.
2. **A quest that binds non-default keys is unplayable on the pad.** The per-quest
   `controls.cfg` mechanism exists (2026-07-25 design), but a section must be authored by
   hand from a careful reading of the quest's Lua. Of the three quests studied so far,
   **two needed one** — so the hand-authoring cost applies to most new quests, not a few.
3. **Nothing records what was tried.** There is no matrix, so "does quest X work" is
   answered by re-deriving it every time.

## Goal and non-goals

**Goal.** A validated, reproducible compatibility matrix over a defined corpus of free
quests, where every quest either runs *and is playable on the pad out of the box*, or
fails with a reason the user can read without SSH.

**Non-goals.**

- Supporting quest resolutions **larger** than 320×240. This design builds the cheap
  rungs and a pre-registered decision gate; a banded framebuffer, if warranted, is its
  own spec (§7).
- Supporting Solarus 2.x quests. The engine is 1.6.5; a version bump is a different
  project of a different size. The survey reports the ecosystem's version distribution as
  a finding.
- Shader support. Structurally unavailable (no OpenGL, by design).
- Re-testing 320×240 behaviour already covered by the release-test gates.

## Success criteria

Chosen deliberately over the alternatives (full resolution independence; graceful
degradation only):

1. Every corpus quest has a matrix row with a verdict and, on failure, a categorised
   reason.
2. Every quest reaching `RUNNABLE` is playable with the shipped pad mapping — no manual
   `controls.cfg` authoring required by the user.
3. No corpus quest produces a silent black screen. Every refusal names itself, on screen
   and in the log.
4. The resolution decision gate is answered with evidence, and the answer is written down
   (a NO-GO doc if it is no).

## Evidence model

Per-quest evidence is **tiered**, because "never self-declare a frame visually correct"
is a standing project rule and every visual claim costs operator time.

| Tier | Applies to | Establishes |
| --- | --- | --- |
| Machine smoke | every corpus quest | launches, reaches gameplay, survives the soak, log clean, fps above floor, escape/overflow/drop counters zero, frame non-blank and *changing* |
| Frame contact sheet | every corpus quest | operator reviews captured PNGs in one sitting instead of one device session per quest |
| Operator play | shortlist + any quest the machine flags + every quest with an auto-generated keymap | visual correctness and pad usability |

The matrix records **which tier backed each row**. A machine-verified row claims liveness,
not correctness, and says so.

## Architecture

Five stages, each producing a machine-readable artifact so a failure names its own stage:

```
fetch  →  interrogate  →  package + install  →  smoke  →  matrix
└───── no device time ─────┘   └──────── device time ────────┘
```

Everything decidable by reading quest files happens **before** the device is touched:
engine version, size range, keymap needs, and shader use are all static properties.
Device time is scarce and strictly serialized (two engine instances wedge the host), so it
is spent only on quests that static analysis says should run.

### Driver — `scripts/quest_compat.sh`

Standalone, with its own lifecycle. It **imports** `scripts/lib/release_check.sh` for
result rows (`rc_pass`/`rc_fail`, `rc_fps_min`, `rc_launch_cmd`) and reuses
`release_test.sh`'s ssh recipes — including the keepalive and fd-release fixes that were
learned the hard way during v1.1.0.

It is deliberately *not* a gate inside `release_test.sh`: that harness wipes the device to
validate one build's packaging, whereas this one installs many quests against one
known-good build. Sharing the libraries banks the hard-won fixes; sharing the driver would
tangle two purposes and couple release cadence to third-party quest hosting.

### Corpus manifest — `scripts/quests.tsv`

Committed: quest id, source URL, pinned tag/branch, expected `solarus_version`, license,
redistribution status. Quest **data** stays out of git, per the existing project rule;
`scripts/fetch_corpus.sh` clones each entry at its pinned ref.

Pinning matters and is already load-bearing: `scripts/fetch_quest.sh` pins MoSDX to
`release-1.12.3` precisely because master/dev target Solarus 2.0 and will not load.

## Component 1 — static interrogator (`scripts/quest_interrogate.py`)

A pure function of a quest directory, emitting one JSON record. No device, no engine, no
network.

**Reads:**

- `quest.dat` → `solarus_version`, `normal_quest_size`, `min_quest_size`,
  `max_quest_size`. (Defaults per `QuestProperties.cpp`: sizes default to `320x240`, and
  min/max default to normal.)
- Quest Lua → input surface: `on_key_pressed`, `on_joypad_*`,
  `game:set_value("keyboard_…")`, `map_joypad_to_keyboard`, and stock `GameCommands`
  usage. Reports the set of keys the quest actually binds, with the action name each is
  bound to where the source names it.
- Quest Lua → `sol.shader` references.

**Emits a verdict:**

| Verdict | Meaning |
| --- | --- |
| `RUNNABLE` | 1.6-compatible, fits 320×240 (directly or via `-quest-size`), no shaders |
| `RUNNABLE_WITH_KEYMAP` | as above, and a generated `controls.cfg` section is required |
| `NEEDS_LARGER_FB` | 1.6-compatible but cannot render at ≤320×240 |
| `WRONG_ENGINE` | `solarus_version` is not 1.6-compatible |
| `NEEDS_SHADERS` | uses `sol.shader` |

Verdicts are not mutually exclusive in principle; the record carries all findings and the
reported verdict is the highest-severity one, in this fixed order:

```
WRONG_ENGINE > NEEDS_SHADERS > NEEDS_LARGER_FB > RUNNABLE_WITH_KEYMAP > RUNNABLE
```

so a quest is never reported as merely "needs a keymap" when it also cannot load.

## Component 2 — keymap generator

Folded into the interrogator. It **generates a real `controls.cfg` section**, not a
suggestion for a human to finish. The existing file format layers built-in defaults →
`[default]` → `[<quest-id>]`, later winning, so a generated section states only its
differences. Quest id is the `.sol` filename without extension.

Three tiers of decreasing confidence:

1. **Stock `GameCommands` quests** (MoSDX-shaped). Fully deterministic: the engine's own
   defaults (`Savegame.cpp` `set_default_keyboard_controls`) are already `[default]`.
   These need no section, and the matrix says so.
2. **Named quest-private bindings** (Patched Tunics- and ROTH-shaped). The quest names its
   own actions — PT's `lib/bindings.lua` has `attack`/`action`/`item_1`/`item_2`/
   `inventory`/`map`/`escape`; ROTH's are literally `set_value("keyboard_run", …)`,
   `keyboard_save`, `keyboard_map`. Those names resolve to pad inputs through **one
   committed priority table**:

   | Pad input | Action, in priority order |
   | --- | --- |
   | `right/left/down/up` | directions |
   | `a` | action |
   | `b` | attack |
   | `y` | item_1 |
   | `x` | item_2 |
   | `start` | pause |
   | `select`, `l`, `r` | highest-priority remaining named action (e.g. save, run, map, inventory, escape) |

   The priority order for the spare three is committed alongside the table, so generation
   is deterministic and reviewable.
3. **Unnameable or over-subscribed bindings.** A quest binds more actions than there are
   inputs (ROTH has six private commands for three spare inputs), or binds keys the
   scanner cannot attribute to a named action. These are **left unmapped and reported**,
   never guessed. The generated section carries a header comment naming what was dropped
   and why; `controls.cfg` is user-editable text on the SD card.

**On the heuristic risk.** This project's history says heuristics break and engine truth
wins. There is no engine truth here — the quest's binding table *is* the closest available
signal — so the mitigations are: derive only from the quest's own action names, never from
inferred intent; regression-test against two known-correct hand-authored sections (§8);
and put every auto-generated section in front of the operator. The baseline it replaces is
one hardcoded table that is wrong for two of the three known quests, so a wrong
auto-binding is strictly better than the status quo and is user-editable besides.

## Component 3 — device smoke harness

One quest at a time; two engine instances wedge the host.

Per quest: install → launch detached (`setsid … </dev/null &`, log under
`/media/fat/logs`, `Solarus.s0` left empty with an `S0_FILE` override) → wait for atlas
preload to complete → inject pad input via the devmem hammer to get past the title into
gameplay → soak → collect.

**PASS requires all of:**

- process alive at the end (pid-based crash signal, as release Gate 2 does)
- no fatal patterns in the log
- fps above a **liveness floor**, not a performance target — this is a compatibility pass,
  and a quest that renders correctly at 20 fps is compatible. The floor exists to catch
  "running but not actually drawing"; performance is recorded in the matrix as data, never
  as a pass criterion.
- escape / ring-overflow / dropped-frame counters at zero
- frame grabs non-blank, plausible entropy, and **changing between samples**

Soak duration and the exact fps floor are harness parameters with committed defaults, set
once during harness bring-up against MoSDX and held constant across the corpus so rows
stay comparable.

### Frame grab

Since Stage 5 Phase 2 the finished frame lands in a DDR3 double-buffer at
`0x3A000040` / `0x3A040040` in RGB565 — HPS-addressable, the same memory the engine
already writes. The harness reads the fabric's published bank indicator (the control word
the reader polls once per vblank), dumps the **inactive** buffer, and converts to PNG at
several points per run.

This is load-bearing for the evidence model. It gives a machine check honest about its
limits — blankness, entropy, and frame-to-frame change catch the black-screen and
frozen-frame classes without claiming the pixels are *correct* — and it converts the
operator gate from one device session per quest into one contact sheet, which is what
makes tier-3 review affordable across a corpus.

## Component 4 — failure UX

Two layers. Neither may fail open.

**Deploy-time sidecar.** The interrogator writes `quest.info` beside each `.sol` in the SD
mirror: version, size range, verdict, keymap section name. `solarus_run.sh` reads that
plain text file at launch — no unzip, no Lua parsing under busybox — and refuses to launch
an incompatible quest, naming the reason. Generated by `scripts/package_quest.sh`.

**On-screen message.** `fps_overlay.h` already proves the renderer can draw before a quest
is live (7-segment digits as `blt_fill` rects). A new `patches/mister/mister_msgscreen.h`
extends that to a minimal 5×7 bitmap font rendered the same way — a few hundred fills for
a static screen that is never re-drawn, so cost is irrelevant. It covers failures the
launcher cannot foresee. The difference it buys is between a black screen and
`THIS QUEST NEEDS SOLARUS 2.0`.

> **`mister_msgscreen.h` MUST be registered in `scripts/apply_mister_files.sh`, and the
> branch verified with `scripts/docker_run.sh scripts/build_engine.sh`.** Per CLAUDE.md
> this exact omission has shipped twice (PR #149, PR #152); neither the native
> `-fsyntax-only` check nor code review can catch it, because the header exists under
> `-I patches/mister` but not in the engine tree.

## Resolution rungs

Three rungs land here:

- **Rung 0** — quest is 320×240. Nothing to do.
- **Rung 1** — quest's `min_quest_size` ≤ 320×240 ≤ `max_quest_size`. Launch with
  `-quest-size 320x240`. Zero code, zero RTL, and it may absorb much of the corpus.

  **The eligibility decision belongs to the interrogator, not the launcher.** If the
  requested size falls outside the quest's declared range, `Video.cpp`
  (`set_quest_size_range`) **silently falls back to `normal_quest_size`** — no error, no
  log line. So passing `-quest-size 320x240` unconditionally would turn an unsupported
  quest back into the black screen this design exists to eliminate. The flag is passed
  only for quests the interrogator has already confirmed eligible.
- **Rung 2** — quest is *smaller* than 320×240 (256×224 and friends). Already fits the
  framebuffer. Relax `is_fpga_target` from `== FB_W/FB_H` to "fits within", composite at
  an offset, accept a border. Renderer-only; no RTL, no video-timing change.

**Runtime size change.** `set_quest_size_range` is reachable from Lua, and Rung 2's
relaxed target lock makes a mid-run size change actually reachable. The locked fabric
target does not contemplate it today. This design handles it explicitly — re-lock on a
size change, or escape the frame — rather than leaving a latent black-screen path.

## Decision gate — Rung 3 (larger than 320×240)

**Pre-registered before the survey runs**, so the answer cannot be rationalised afterwards:

> Open a banded-framebuffer spec **only if ≥2 corpus quests are 1.6-compatible,
> shader-free, and cannot be satisfied at ≤320×240.** Otherwise write the NO-GO, document
> the limitation in `README.md`, and close it.

The gate is cost/benefit, not a bare count. A banded WORK framebuffer means the compositor
processes each frame as horizontal bands, which means **the command ring is walked once
per band** — every blit clipped and re-issued for each band it touches. That is the real
expense, and it interacts directly with the ring double-buffer that just bought +43–52%.
Add parameterized video timing and a new PLL configuration and it is a Stage-6-sized piece
of work, which is why it must not ride along on a compatibility pass.

## Testing

**Host, no device:**

- Fixture quest tree per verdict class (stock-commands, private-bindings,
  wrong-engine-version, oversize, shader-using) drives the interrogator.
- **Golden test for the keymap generator:** it must regenerate the two existing
  hand-authored `controls.cfg.default` sections — `[zelda-roth-se-v1.2.1]` and the Patched
  Tunics section — byte-for-byte. Those were written by hand from careful source reading
  and are the closest thing to ground truth available.
- `mister_controls.h`'s parser already has host tests; extend for generated sections.
- `mister_msgscreen.h` gets a render-to-buffer test against `blitter_ref`, matching how the
  host suite already models engine logic.
- Launcher pre-flight: shell test over fixture `quest.info` files, asserting it fails
  **closed**.

**Every new test must be demonstrated failing on a mutated fixture before it counts** —
the retrospective's own lesson, *prove a verification can fail before trusting that it
passes*, learned from a `-fsyntax-only` check that silently checked nothing.

**Device:** the harness self-tests against MoSDX (known good) and against a deliberately
corrupted sidecar, proving a FAIL row is reachable. A compat matrix in which nothing can
fail is worthless.

## Risks

1. **The corpus may be mostly Solarus 2.x.** If the ecosystem has moved on, the matrix
   comes back largely `WRONG_ENGINE`. That is a legitimate and valuable result, but it
   reframes the port's roadmap entirely. The pass pre-commits to reporting it plainly
   rather than treating it as a failed outcome.
2. **Runtime quest-size change** — handled explicitly (above) rather than left latent.
3. **Auto-keymap heuristic error** — mitigated by golden tests and the operator gate over
   every auto-generated section.
4. **Corpus availability and licensing** — the manifest pins refs and records
   redistribution status. Nothing is redistributed; quests are fetched.
5. **Device serialization** remains the throughput limit; the contact sheet is what keeps
   the operator gate affordable.

## Deliverables

- `scripts/quests.tsv` — committed corpus manifest.
- `scripts/fetch_corpus.sh` — pinned fetch.
- `scripts/quest_interrogate.py` — static interrogator + keymap generator.
- `scripts/quest_compat.sh` — device harness and matrix driver.
- `patches/mister/mister_msgscreen.h` — on-screen failure message (registered in
  `apply_mister_files.sh`).
- `is_fpga_target` relaxation + runtime size-change handling.
- `quest.info` sidecar generation and `solarus_run.sh` pre-flight.
- `games/Solarus/controls.cfg.default` — regenerated, corpus-wide.
- `docs/quest-compatibility.md` — the matrix, with evidence tier per row.
- `README.md` — "Known limitations" updated to state the measured position rather than
  "should work but are less tested".
- A NO-GO or a follow-on spec for Rung 3, per the gate.
