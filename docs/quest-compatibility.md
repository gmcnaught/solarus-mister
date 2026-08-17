# Quest compatibility matrix

**Evidence tier: static analysis only. No quest in this table has been launched on
hardware.** Every row below comes from `scripts/quest_interrogate.py` reading each
quest's `quest.dat` and Lua source — no device, no engine, no network. This establishes
that a quest *should* load, fit the framebuffer, and have a usable pad mapping; it does
not establish that it renders correctly or plays well. The device smoke harness that
would upgrade these rows to a liveness-checked tier (launch, soak, fps floor, non-blank
and changing frames) is a separate, not-yet-written plan
(`docs/superpowers/specs/2026-07-27-quest-compatibility-design.md`, Component 3). Treat
`RUNNABLE` here as "the static evidence gives no reason this should fail to load and be
playable on the pad," not as "confirmed working on a MiSTer."

## The engine-version rule

The shipped engine is Solarus 1.6.5. Its own `MainLoop.cpp` states the acceptance rule
in a comment: *"1.5 quests can be run by Solarus 1.6."* Concretely: a quest's declared
`solarus_version` major component must be exactly `1`, and the minor component must be
`5` or `6`; the patch component is ignored. Two quests in this corpus declare `1.5`
(`patched_tunics`, `zelda_olb_se`) and both are genuinely runnable under this rule — they
are not edge cases or exceptions, they are exactly what the rule is for.

## The matrix

| Quest ID | Source repo | Pinned ref | Declared version | Normal size | Verdict | Controller mapping | Dropped actions |
|---|---|---|---|---|---|---|---|
| `children_of_solarus` | `solarus-games/games/children-of-solarus.git` | `7bfc18fd2493` (commit SHA, no tags exist) | 1.6 | 320×240 | RUNNABLE | not needed | — |
| `mystery_of_solarus_dx` | `solarus-games/zsdx.git` | `release-1.12.3` | 1.6 | 320×240 | RUNNABLE | not needed | — |
| `mystery_of_solarus_xd` | `solarus-games/games/zsxd.git` | `v1.12.2` | 1.6 | 320×240 | RUNNABLE | not needed | — |
| `zelda_xd2_mercuris_chess` | `solarus-games/games/zelda-xd2-mercuris-chess.git` | `v1.1.2` | 1.6 | 320×240 | RUNNABLE | not needed | — |
| `patched_tunics` | `syllan-games/patched-tunics.git` | `0.3` | 1.5 | 320×240 | RUNNABLE_WITH_KEYMAP | generated, 7 bound actions → 11 config rows | 0 |
| `zelda_olb_se` | `solarus-games/games/zelda-olb-se.git` | `148402831136` (commit SHA, no tags exist) | 1.5 | 320×240 | RUNNABLE_WITH_KEYMAP | generated, 3 of 5 bound actions mapped | 2 (`monsters`, `commands`) |
| `zelda_roth_se` | `solarus-games/games/zelda-roth-se.git` | `v1.2.1` | 1.6 | 320×240 | RUNNABLE_WITH_KEYMAP | hand-authored (kept, not regenerated); generator would emit the same 3 of 6 bound actions on different spare slots | 3 (`monsters`, `look`, `commands`) |

**7/7 runnable.** Zero quests use `sol.shader`. Every quest's `normal_quest_size` is
exactly 320×240 — nothing in this corpus exercises the resolution rungs beyond rung 0.

Note on the "Controller mapping" column: `patched_tunics`'s 7 *bound actions* (the
distinct quest actions with a recognised private key) expand to 11 *config rows*
(4 direction rows restated plus 7 action rows) because a `private_layer` quest
restates the direction inputs too — these are different quantities, not a
discrepancy. `zelda_roth_se` is the one exception to "sections are generated":
`games/Solarus/controls.cfg.default` ships a **hand-authored**
`[zelda-roth-se-v1.2.1]` section (a considered spare-slot choice from reading the
quest's source) that this file's own header comment says must not be regenerated
over — what ships is not what `scripts/quest_interrogate.py` would currently emit
for this quest, though both reach the same 3 of 6 private actions.

Two of the seven corpus quests (`children_of_solarus`, `zelda_olb_se`) have no release
tags at all, so `scripts/quests.tsv` pins them by commit SHA (the `master` head at
survey time) rather than a tag. `scripts/fetch_corpus.sh` handles both forms — tags via
a shallow `--branch` clone, bare SHAs via a full clone plus `checkout --detach`.

## A signature worth re-checking: key handler present, nothing recognised

Four of the seven corpus quests — `children_of_solarus`, `mystery_of_solarus_dx`,
`mystery_of_solarus_xd`, `zelda_xd2_mercuris_chess` — report `has_key_handler: true`
(some scanned Lua file installs `on_key_pressed`) with zero recognised private
bindings. That is the *exact* signature Patched Tunics had before its nested-table
binding shape (`action = { keys={...} }`) was found and added to the scanner — a quest
that looks, from this one signal, like it might have a private input layer the scanner
failed to parse.

These four have been inspected and are genuine: their key handlers belong to menu,
console, and logo-screen code, not a private gameplay input layer, and they all use
stock GameCommands for gameplay (hence "not needed" in the table above). But the
interrogator cannot yet *tell the difference* between "stock GameCommands quest whose
menu code happens to install a key handler" and "quest with a private input layer in a
form the scanner doesn't recognise" — both currently look identical once
`private_bindings` is empty. If a future corpus quest is ever suspected of losing input
bindings to the scanner, `has_key_handler: true` with an empty `private_bindings` is the
signature to check first.

## The ecosystem finding

The most consequential result here isn't any single row — it's that **the Solarus 2.x
migration lives on `dev` branches, not on `master` or release tags.** `zsdx` (Mystery of
Solarus DX's upstream) declares `solarus_version = "2.0"` on its `dev` branch, but
`"1.6"` on both `master` and the pinned tag `v1.12.3`. In other words: the engine-version
wall this port worried about is largely avoidable by pinning practice, not a hard
ecosystem ceiling. Every quest in this corpus that ships a tagged release is 1.6-family;
the 2.x work is opt-in (`dev`) rather than the default checkout. A manifest that pinned
`master`/`dev` unconditionally would have painted a much bleaker picture than the one the
corpus actually shows.

This is also why `scripts/quests.tsv` documents pinning as load-bearing, not incidental:
an unpinned or wrongly-pinned clone of `zsdx` would silently fetch a 2.0 quest and report
`WRONG_ENGINE` for a game that is, at its released version, fully compatible.

## Reproducing this survey

```bash
bash scripts/fetch_corpus.sh
python3 scripts/quest_interrogate.py deploy/quests/*/
```

The first command clones each manifest entry (`scripts/quests.tsv`) at its pinned ref
into `deploy/quests/` (never committed — quest data stays out of git). The second reads
each cloned quest directory and prints one JSON record per quest: `quest_id`,
`solarus_version`, `normal_size`/`min_size`/`max_size`, `size_classification`, `verdict`,
`controls_section` (the generated `controls.cfg` section text, or `null` if none is
needed), `dropped_actions` (private-binding actions that couldn't be reached for
lack of spare pad inputs), `has_key_handler` (a scanned Lua file installs
`on_key_pressed` — see the signature note above), and `unrecognized_keys` (rejected
action/value candidates the scanner found but couldn't validate as a real binding).
