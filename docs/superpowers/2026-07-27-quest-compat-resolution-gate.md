# Resolution rung 3 (larger than 320×240) — decision

**Date:** 2026-07-27
**Decision: NO-GO.** Do not open a banded-framebuffer spec.

## The pre-registered criterion

From `docs/superpowers/specs/2026-07-27-quest-compatibility-design.md` §"Decision gate —
Rung 3", committed **before the survey ran**, specifically so the answer could not be
rationalised after seeing the data:

> Open a banded-framebuffer spec **only if ≥2 corpus quests are 1.6-compatible,
> shader-free, and cannot be satisfied at ≤320×240.** Otherwise write the NO-GO, document
> the limitation in `README.md`, and close it.

## The measured count: 0

`scripts/quest_interrogate.py` over all seven corpus quests reports `normal_quest_size`
exactly `320×240` for every single one — not "fits via `-quest-size`", not "smaller than
320×240 with a border," but exactly the native framebuffer size, in every row. The two
larger-`max_quest_size` quests (`mystery_of_solarus_dx`, `mystery_of_solarus_xd`, both
`max_size` 400×240, `min_size` 320×200) already resolve to `FITS` because their declared
range brackets 320×240 — rung 1 (`-quest-size 320x240`) covers them with zero code.
Nothing in the corpus reaches rung 3's precondition. The pre-registered threshold was
"≥2 quests"; the count is 0. This is not close.

## Conclusion

**NO-GO.** No banded WORK BRAM, no partial-frame framebuffer, no parameterized video
timing, no new PLL configuration.

## What that work would have cost (recorded so the decision stays legible)

A banded WORK framebuffer means the compositor can no longer treat a frame as one
composite pass over one on-chip `comp_fbram`. It walks the command ring **once per
band**, re-clipping and re-issuing every blit against each band's window — a blit
spanning N bands is emitted/clipped N times, not once. That is real, recurring per-frame
cost, not a one-time setup cost, and it interacts directly with the machinery this
project just spent an arc validating:

- The **command-ring double-buffer** (`SOLARUS_RINGDBUF`, default ON since 2026-07-26,
  HW-validated +43% map119 / +52% map3+dialog) exists specifically so the A9 can build
  ring S+1 while the fabric composites ring S. A banded compositor re-walks that same
  ring multiple times per frame, which changes the timing budget the double-buffer's
  overlap was measured against — the "walk the ring once" assumption baked into that
  win no longer holds.
- Add parameterized video timing (bands imply a scanout that isn't simply "whole frame,
  same as always") and a new PLL configuration for whatever timing that requires, and
  this is a Stage-6-sized undertaking in its own right — exactly why the design doc
  pre-committed to not letting it ride along on a compatibility pass.

None of that cost is justified by a benefit of zero.

## The honest limit of this evidence

The corpus is **the freely-redistributable quests reachable via `scripts/quests.tsv`** —
seven quests, chosen because they are legally fetchable and worth surveying, not because
they are an exhaustive sample of every Solarus quest that exists. This result shows that
**no quest a user of this port can readily obtain needs a larger framebuffer.** It does
not show that no Solarus quest anywhere needs one. Larger-canvas quests are known to
exist in the wider ecosystem (some fan projects target higher resolutions); none happen
to be in this corpus.

**What would reopen this question:** a quest entering the corpus (or a user request)
whose declared `min_quest_size` exceeds 320×240 in both dimensions — i.e., a quest that
`quest_interrogate.py` would classify `TOO_LARGE` rather than `FITS`/`FITS_VIA_QUEST_SIZE`
even after allowing rung 1's `-quest-size` accommodation. At that point the ≥2-quest
threshold is a live count again, not a hypothetical, and the gate should be re-evaluated
against whatever the corpus looks like then — not answered from this document.

## What already made this moot for now

The cheap rungs did their job before rung 3 was ever in play:

- **Rung 0** — a quest whose `normal_quest_size` is already 320×240 needs nothing. Five
  of the seven corpus quests land here outright.
- **Rung 1** — a quest whose declared `min_quest_size`…`max_quest_size` range brackets
  320×240 is launched with `-quest-size 320x240` and fits with zero code and zero RTL.
  `mystery_of_solarus_dx` and `mystery_of_solarus_xd` (max 400×240) are covered by this
  rung.

Rung 2 (quests genuinely *smaller* than 320×240) also remains unexercised by this
corpus — no row needed it — but stays a cheap, renderer-only option if a smaller-canvas
quest shows up later. Rung 3 is the only rung this decision closes.

## References

- `docs/superpowers/specs/2026-07-27-quest-compatibility-design.md` — the design that
  pre-registered this gate, before any survey data existed.
- `docs/quest-compatibility.md` — the full per-quest matrix this decision is drawn from.
- CLAUDE.md — command-ring double-buffer (`SOLARUS_RINGDBUF`) HW-validation numbers cited
  above.
