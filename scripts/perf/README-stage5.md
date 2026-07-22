# Stage 5 — map-119 capture: the fixed reproducible spot

**Scene:** MoSDX map **119** (the quest's only real parallax scene; `outside_world`,
tileset 1, layers 0–2), loaded from **save1.dat**.

**Fixed teleport destination:** `from_dungeon_10` (a stable standing spot in map 119;
valid destinations are `from_dungeon_10`, `from_dungeon_10_5f`, `from_ending`).
**Moving window:** hold dpad **DOWN** (`0x04` on `0x3A000008`).

Rationale: `from_dungeon_10` lands the hero idle in the parallax area; standing = pure
fabric composite, moving = adds scroll + sprite churn. Same spot every run → byte-repro A/B.

**Prereqs:** engine sha1 `8a56d13f` (TILEMAPCH default-on) deployed; `Solarus_20260721.rbf`
loaded; `SOLARUS_BLITTER_DIAG=1`. Run `bash scripts/perf/capture_map119.sh`.
