# .62 SDRAM-source failure — next-steps plan (2026-08-06)

Companion to `2026-08-06-sdram-62-investigation-handoff.md`. Read that first.

## Change of approach vs. the handoff's §5

The handoff makes "fix `sdram_selftest`" step 1. This plan **defers that** and makes
the **MiSTer screenshot the adjudicator** instead. Reasons:

- The screenshot measures the actual symptom (garbage background, correct
  screen-space text) through the actual datapath, in the actual shipping
  configuration. `sdram_selftest` measures a proxy, and it has produced five false
  verdicts and one unexplained state dependence.
- It requires no on-device C, no handshake semantics, no memory-map constants —
  the three things that generated every false verdict.
- It costs one script. `sdram_selftest` repair is open-ended.
- It doubles as the **release-gate pixel check** the handoff calls for
  (Gate 2 currently passes a device rendering pure garbage).

`sdram_selftest` repair moves to Phase 5, and only if Phases 1–3 fail to localise.

Standing method rule, unchanged and non-negotiable: **no .62 number is accepted
without a matched .81 control on the identical configuration in the same session.**

---

## Phase 0 — build the instrument (no hardware verdicts yet)

`scripts/debug/shot_score.sh <host> <rbf|--installed> <label>`:

1. `kill -9 $(pidof solarus-run)`; `load_core`; wait for `/tmp/CORENAME == Solarus`
   (fail loudly otherwise — never score an unloaded core).
2. Re-write `Solarus.s0` **after** the core is up (MiSTer truncates it on load) and
   `touch` it — `quest_manager.sh` relaunches on mtime change only.
3. Wait for the title screen; `echo screenshot > /dev/MiSTer_cmd`; `scp` the PNG
   from `/media/fat/screenshots/Solarus/`.
4. Score with a Python/PIL compare against a stored golden: report
   `match% (exact-pixel)`, `distinct-colours-per-row median`, and
   `rows-differing-from-golden`. Emit `NO-CAPTURE` — never a score — if any step
   above failed.

**Golden capture:** taken on .81, v1.1.0 pair, title screen. The operator
validates it visually **once**; every later comparison is numeric. (Per standing
rule: no self-declared visual correctness.)

**Instrument validation before any verdict is accepted:**
- 3 runs on .81 → expect PASS all three.
- 3 runs on .62 → expect FAIL all three.
- If .81 flips across a power cycle *on screen* the way it flipped in the
  selftest, that is the single biggest finding available and it reframes the whole
  investigation (see Phase 1).

Deliverable: a judge that returns the same answer for the same hardware +
bitstream, which is precisely what the current tool does not do.

---

## Phase 1 — power-cycle / init characterisation on .81

Directly tests the handoff's leading hypothesis (§4: Solarus never gates traffic on
SDRAM init completion, `prog_en` tied low, mode register written only at power-on,
and a mode register survives FPGA reconfiguration but **not** power-off).

| leg | sequence | init hypothesis predicts |
|---|---|---|
| A | cold boot → Solarus → score | FAIL |
| B | power cycle → Maldita → Solarus → score | PASS |
| C | (no power cycle) reload Solarus → score | same as previous |

Run each ≥2×. Requires no code change and no build. If A fails and B passes, the
init gap is confirmed as *a* fault on real hardware and Phase 4 becomes the fix.

Then repeat A/B on .62. The handoff's Maldita-then-Solarus counter-evidence is
void (it reported `HANDSHAKE-TIMEOUT=3`); redo it with the screen as judge.

---

## Phase 2 — release bisect on .62 (matched engine+RBF pairs)

The engine and RBF are a **matched pair** (`OFF_HEAP` 0x80000→0x100000 moved
unconditionally at PR #154; mismatched pairs fetch atlases 512 KiB low and render
silent garbage — *which is a candidate explanation for the .62 symptom on its own
and must be excluded first*). So every rung installs a complete release zip.

| rung | pair | RTL delta vs. rung above |
|---|---|---|
| 1 | v1.1.0 | ring double-buffer, bank mux, `C_DONE=done+1`, heap move |
| 2 | v1.0.1 | — |
| 3 | v1.0.0 | (engine-only delta; same RBF era) |

Each rung: install on .62, score; install on .81, score; same session.

- **v1.0.x renders correctly on .62** ⇒ this is a *regression* in the ring-dbuf
  RTL/heap move, not a board fault. Investigation collapses to a normal bisect of
  a known 5-commit range (`75e1393`, `3b5fbdd`, `1d4cf2f`, `b2a6ab4`, `473039e`).
  This is the outcome that would make everything else unnecessary — hence running
  it early, and it is the operator's own suggestion.
- **All rungs fail on .62** ⇒ not a recent regression; proceed to Phase 3.

---

## Phase 3 — fabric-parameter bisect on .62

Highest-value single experiment first, because it is the *matched-Maldita*
configuration and the artifact already exists:

**3a. Re-judge `exp/srcblocks2-sdram-diag` by screenshot** (CI run `31133036066`,
`SRC_BLOCKS=2` + `phase_shift3=2540` — i.e. Maldita's exact SDRAM config, on a
core that fails). It is built off master so it pairs with the **v1.1.0 engine** —
no engine hunt. Its previous 0% verdict came from the retracted instrument.
- PASS ⇒ the differentiator is `SRC_BLOCKS=128` and/or phase; split them with two
  further builds (`SRC_BLOCKS=2` @5079, `SRC_BLOCKS=128` @2540).
- FAIL ⇒ the SDRAM interface really is exonerated and the fault is upstream of it.

**3b. Local RBF ladder** (`_Other/`), if 3a is inconclusive:

| rbf | marks |
|---|---|
| `20260723` | FB→DDR3 scanout (Stage 5 Phase 2) — pairs with the v1.0.x engine |
| `20260722` | `SRC_BLOCKS=128` (Stage 5 Phase 1), on-chip SCAN banks |
| `20260721` | `RO_BLOCKS=2` small cache — the last pre-enlargement build |

`20260721`↔`20260722` isolates `SRC_BLOCKS` alone. **Cost to flag:** both predate
FB→DDR3, so they need a contemporaneous engine (CI artifact or a rebuild at that
commit); pairing them with the v1.1.0 engine is invalid and will produce a
meaningless failure on *both* devices. Budget for one engine build.

**3c. Physical check (cheap, operator-only):** confirm .62 and .81 carry the same
SDRAM module make/revision. Maldita running 128 MB XL on .62 proves the module is
functional at that geometry, but not that its margin matches .81's.

---

## Phase 4 — fix the init gap on its own merits

Independent of Phase 1's outcome — gating traffic on init completion is correct
regardless, and it is now testable in sim because `INIT_WAIT_SIM` lets a TB reach
LOAD MODE.

1. Wire `sdram_fb_cache`'s `.init()` (currently `// unused here`) through
   `jtframe_burst_sdram`.
2. Gate `jtframe_burst_ctrl`'s issue condition on init-complete, alongside the
   existing `!prog_en && !mode_busy && !rfshing`.
3. TB: assert **zero** ACT/READ/WRITE before LOAD MODE completes, with
   `INIT_WAIT_SIM` short enough to reach it. The suite currently has no such
   assertion — testbenches passed reading a chip whose `Mode_reg` was all-`x`.
4. Build, and test cold-boot-straight-to-Solarus on both devices (Phase 1 leg A).

---

## Phase 5 — instrument repair, only if 1–3 do not localise

Per handoff §3: make `HANDSHAKE-TIMEOUT` invalidate a run rather than yield a
verdict; fix or **delete** the DDR3-source control leg (it fails on both devices,
including .81 at 100%, and every real source read has gone through SDRAM since the
#66 preload — it may be testing a path this fabric does not use); establish or
verify SDRAM init inside the tool rather than inheriting machine state.

---

## Phase 6 — disposition of the working tree

**Keep and land (each stands on its own evidence):**
- jtframe re-vendor to `1be22f172` + `PROVENANCE.md` (verified byte-identical
  except the `#46` `jtframe_burst_io.v` IOB-packing delta).
- `build_solarus.sh` `DQCAP_SLACK_NS` repair — the read-capture margin has
  **never** been correctly reported; the old filter matched a deleted module and
  the unbounded awk printed the *next* report's number.
- `INIT_WAIT_SIM` plumbing, and both CAS testbenches (`tb_sdram_fb_cache`
  parameterised, `tb_sdram_fb_cache_cl3`) — the suite's only CAS coverage, keep
  even if CASLAT is dropped.

**Park on a branch, do not merge:** the CASLAT work (`B_CL3`, mode-register
fields, `.CASLAT(3)` in `Solarus.sv`). Its premise is retracted, and
`tb_sdram_fb_cache_cl3` fails with a one-16-bit-word readback shift *identically
with and without the extra wait state*, which contradicts both models of where the
latency lands. Note for whoever resumes it: CAS is `Mode_reg[6:4]`.

**Release gate:** fold Phase 0's scorer into `release_test.sh` Gate 2 as a pixel
check. Every objective Gate 2 signal was green on a device rendering pure garbage
(53 fps, `escape=0`, `overflow=0`, `dfq_drop=0`); Gate 2 inspects no pixels.

---

## Ordering rationale

Phases 1, 2 and 3a all need only the Phase 0 script and existing artifacts — no
RTL work, no CI builds, no engine rebuilds. Between them they discriminate the
three live explanations (recent-regression / board-margin / init-free-riding),
and any one of them can end the investigation before a line of RTL is written.
