# PARKED — blend-layer Z-order: region-aware capture (Part B)

**Status:** parked 2026-07-25. Code reverted in `6b312ae` (reverts `9cba40c`,
`ad794c0`, `a898823`, `3299f09`). Nothing in this area ships until the Z-order
question below is answered.

**Read this before re-attempting the menu offload.** The diagnosis is complete and
HW-confirmed; the open question is only which fix to take.

---

## What Part B did, and why it looked right

The renderer offloads a full-screen translucent overlay to the fabric as a
`BLT_BLEND_PALPHA` layer. PR #149's predicate keyed on the SOURCE SURFACE's size,
so the quest's pause menu — one 320×240 region of the **1280×240** four-submenu
atlas `pause_submenus.png`, at opacity 216 — was never captured. Part B rekeyed
the predicate on the drawn REGION and threaded the region origin (`sx`/`sy`)
through to the fabric blit.

That part worked. On HW: `capture` 0 → 1, `escape=0`, pause-menu fps ~20 → 29-30.

## The defect

Three of the four pause submenus render with the backdrop composited **on top of**
the menu content, veiling items/minimap/text at 216 alpha. Operator-observed;
"transparency applied to more than just the background".

## Root cause (measured, not inferred)

`emit_blend_layers()` runs **after** the root overlay, unconditionally. That is
Z-correct only when every root draw FOLLOWING the captured one is also captured.

Per-submenu device probe (`[blitter blendlayer]`, one engine, ship RBF):

| submenu (index) | banner | operator verdict |
|---|---|---|
| inventory (1) | `layers=1 capture=60` | **wrong** |
| map (2) | `layers=1 capture=60` | **wrong** |
| **quest_status (3)** | **`layers=2 capture=120`** | **correct** |
| options (4) | `layers=1 capture=60` | **wrong** |

`layers=2` is the whole explanation. `pause_quest_status.lua:197` draws its content
as a single full-screen `quest_items_surface`, which ALSO matches the predicate. So
backdrop and content both become layers, are emitted in capture order, and their
relative Z survives — **correct by accident.** The other three draw content as many
small draws (item sprites, minimap `draw_region`, text surfaces) that fail the
full-screen predicate, stay in the root overlay, and are therefore emitted BEFORE
the backdrop.

All four submenus have identical paint order (`draw_background` then content), so
paint order is not the discriminator — capturability of the content is.

## This is a pre-existing flaw, and #149 has it too

`Game::draw` draws `dialog_box` **before** `get_lua_context().game_on_draw()` (the
HUD). PR #149 — merged, on master — emits the captured dialog AFTER the root
overlay, which contains that HUD. So the dialog composites above the HUD where
software order puts it below. **It passed its visual gate only because the dialog
box and the HUD do not overlap on screen.** Part B did not introduce this class of
bug; it made it visible by capturing a surface that does overlap its successors.

Any fix should address #149's case as well, or explicitly record why it is
tolerable.

## Candidate fixes (unresolved — pick one before restarting)

1. **Order-preserving emit.** Track each captured layer's position in the root
   draw sequence; emit the root overlay in segments around it. Fully correct, fixes
   #149's latent case. Costs an extra root upload whenever a layer lands
   mid-sequence — which may consume the win the capture exists to deliver. Needs a
   measurement before committing to it.
2. **Emit backdrops before the root overlay.** If a captured blend precedes all
   surviving root content, emit it *before* rather than after. Cheap, and would fix
   all four submenus **if** the pause backdrop really is the first root draw.
   UNVERIFIED: the HUD stays enabled while paused (`hud/hud.lua:144`
   `game:hud_on_paused` notifies but does not disable), so whether the backdrop or
   the HUD draws first depends on menu-stack order. **One probe answers this** —
   instrument the root draw sequence number at capture time and read it for a
   paused frame. Do that first; it decides whether this option exists.
3. **Narrow the predicate** so only a capture whose successors are also captured
   qualifies. Effectively reverts the menu widening (status quo after `6b312ae`),
   keeping #149's dialog behaviour. Menu stays ~20fps.

## What to keep from the reverted work

The reverted commits are good code with clean reviews; the flaw is in WHERE layers
are emitted, not in how the region is captured. If option 1 or 2 is chosen, revert
the revert and build on top rather than reimplementing:

- region-keyed predicate + FNV continuation (`9cba40c`) — 14-arg pure predicate,
  host-tested, and `ad794c0` adds mutation-checked y-axis bounds coverage;
- region threading `sx`/`sy` into the blit (`a898823`);
- region-scoped digest cache (`3299f09`) — avoids a ~600 KB whole-atlas reconvert
  on every submenu switch, plus a load-bearing bounds guard on the emit path.

Also still true and worth carrying forward: capturing an atlas-backed layer uploads
the WHOLE 1280×240 surface (~600 KB ARGB4444) for a 320×240 region, and the quest
atlas is probably not in `immutable_set`, so it stages into the 4 MiB INTER arena —
~15 % for one surface. Watch `[blitter inter]` occupancy; INTER overflow is the #84
failure class.

## Related

- `docs/superpowers/specs/2026-07-25-pacing-barrier-and-region-blend-capture-design.md`
  — the original design; its §4 describes Part B, and its §5 Gate B is the visual
  check that caught this.
- PR #149 — the merged dialog offload this extended.
