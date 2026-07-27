# Quest Compatibility — Static Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the host-only half of the quest-compatibility pass — a static interrogator that reads a Solarus quest directory and reports whether this port can run it, plus a generator that emits a working per-quest `controls.cfg` section — and run it over a corpus of free quests to answer the resolution decision gate.

**Architecture:** Pure-Python analysis library (`scripts/lib/quest_survey.py`) with a thin CLI (`scripts/quest_interrogate.py`), tested against committed fixture quest trees. No device, no engine, no network at test time. A committed TSV manifest plus a fetch script supply the real corpus. The final task runs the survey for real and writes the matrix and the gate answer.

**Tech Stack:** Python 3 (standard library only — matching `scripts/tests/test_wire_constants.py`, which is deliberately "pure regex, no deps"), POSIX shell, git.

## Global Constraints

- **Python 3 standard library only.** No pip installs, no third-party imports. The repo's existing Python tooling (`scripts/tests/test_wire_constants.py`, `scripts/lib/wf_pathspec.py`) holds this line.
- **Quest data never enters git.** Only the manifest (`scripts/quests.tsv`) and small synthetic fixtures are committed. This is an existing project rule from `CLAUDE.md`: *"Keep engine binaries + quest data OUT of git; `scripts/` re-fetches."*
- **The target framebuffer is 320×240.** `BLT_FB_WIDTH` / `FB_W` / `FB_H`. Never hardcode a different value.
- **Engine is Solarus 1.6.5.** A quest is engine-compatible only if its `solarus_version` has major.minor `1.6`.
- **This plan touches no RTL and no `patches/series/*.patch`.** It changes no engine behaviour. The one shipped file it rewrites is `games/Solarus/controls.cfg.default`.
- **Every new test must be demonstrated failing before it is trusted.** Each task's "run it to verify it fails" step is mandatory, not ceremonial — this repo has already shipped one falsely-passing verification.
- **Branch:** `feature/quest-compatibility`.

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/lib/quest_survey.py` (create) | All analysis logic as pure functions: quest.dat parsing, size classification, Lua input-surface scanning, shader scanning, verdict resolution, `controls.cfg` section generation and parsing. No I/O beyond reading a quest directory. |
| `scripts/quest_interrogate.py` (create) | CLI wrapper. Walks quest dirs, calls the library, emits JSON. No logic of its own. |
| `scripts/tests/test_quest_survey.py` (create) | Host test for the library, including the golden test against the shipped `controls.cfg.default`. |
| `scripts/tests/fixtures/quests/*/` (create) | Synthetic minimal quest trees, one per verdict class. |
| `scripts/quests.tsv` (create) | Committed corpus manifest. |
| `scripts/fetch_corpus.sh` (create) | Clones each manifest entry at its pinned ref into `deploy/quests/`. |
| `games/Solarus/controls.cfg.default` (modify) | Regenerated from the corpus survey. |
| `docs/quest-compatibility.md` (create) | The matrix. |
| `.github/workflows/patch-series-ci.yml` (modify) | Adds the survey test to CI. |

The split matters: the library is a pure function of a directory, so every behaviour in this plan is testable without a device, a network, or a real quest.

---

### Task 1: quest.dat parsing and size classification

**Files:**
- Create: `scripts/lib/quest_survey.py`
- Create: `scripts/tests/test_quest_survey.py`
- Create: `scripts/tests/fixtures/quests/stock_320/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/wrong_engine/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/via_quest_size/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/smaller/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/oversize/data/quest.dat`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `parse_quest_dat(text: str) -> dict` with keys `solarus_version: str|None`, `normal_size: tuple[int,int]`, `min_size: tuple[int,int]`, `max_size: tuple[int,int]`
  - `parse_size(s: str|None) -> tuple[int,int]|None`
  - `engine_compatible(version: str|None) -> bool`
  - `size_classification(sizes: dict) -> str` returning one of `FITS`, `FITS_VIA_QUEST_SIZE`, `FITS_SMALLER`, `TOO_LARGE`
  - constant `FB_SIZE = (320, 240)`

- [ ] **Step 1: Create the fixture quest trees**

`quest.dat` is Lua source. The real format, copied from `deploy/quests/mystery_of_solarus_dx/data/quest.dat`, is a `quest{ ... }` call with `key = "value"` fields.

`scripts/tests/fixtures/quests/stock_320/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "stock320",
  title = "Stock 320 fixture",
  normal_quest_size = "320x240",
}
```

`scripts/tests/fixtures/quests/wrong_engine/data/quest.dat`:
```lua
quest{
  solarus_version = "2.0",
  write_dir = "wrongengine",
  title = "Wrong engine fixture",
  normal_quest_size = "320x240",
}
```

`scripts/tests/fixtures/quests/via_quest_size/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "viaquestsize",
  title = "Resizable fixture",
  normal_quest_size = "400x240",
  min_quest_size = "320x240",
  max_quest_size = "400x240",
}
```

`scripts/tests/fixtures/quests/smaller/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "smaller",
  title = "Sub-320 fixture",
  normal_quest_size = "256x224",
}
```

`scripts/tests/fixtures/quests/oversize/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "oversize",
  title = "Oversize fixture",
  normal_quest_size = "640x480",
  min_quest_size = "640x480",
  max_quest_size = "640x480",
}
```

- [ ] **Step 2: Write the failing test**

Create `scripts/tests/test_quest_survey.py`:

```python
#!/usr/bin/env python3
# Host tests for the quest compatibility interrogator (no device, no network).
# Run: python3 scripts/tests/test_quest_survey.py

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import quest_survey as qs

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "quests"

FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append("%s: got %r, want %r" % (label, got, want))


def quest_dat(name):
    return (FIXTURES / name / "data" / "quest.dat").read_text()


def test_parse_quest_dat():
    d = qs.parse_quest_dat(quest_dat("stock_320"))
    check("stock version", d["solarus_version"], "1.6")
    check("stock normal", d["normal_size"], (320, 240))
    # min/max default to normal when absent (QuestProperties.cpp behaviour)
    check("stock min", d["min_size"], (320, 240))
    check("stock max", d["max_size"], (320, 240))

    d = qs.parse_quest_dat(quest_dat("via_quest_size"))
    check("via normal", d["normal_size"], (400, 240))
    check("via min", d["min_size"], (320, 240))
    check("via max", d["max_size"], (400, 240))


def test_parse_size():
    check("parse 320x240", qs.parse_size("320x240"), (320, 240))
    check("parse spaces", qs.parse_size(" 400x240 "), (400, 240))
    check("parse junk", qs.parse_size("wide"), None)
    check("parse none", qs.parse_size(None), None)


def test_engine_compatible():
    check("1.6 ok", qs.engine_compatible("1.6"), True)
    check("1.6.5 ok", qs.engine_compatible("1.6.5"), True)
    check("2.0 no", qs.engine_compatible("2.0"), False)
    check("1.5 no", qs.engine_compatible("1.5"), False)
    check("missing no", qs.engine_compatible(None), False)
    check("junk no", qs.engine_compatible("banana"), False)


def test_size_classification():
    check("stock", qs.size_classification(qs.parse_quest_dat(quest_dat("stock_320"))), "FITS")
    check("via", qs.size_classification(qs.parse_quest_dat(quest_dat("via_quest_size"))), "FITS_VIA_QUEST_SIZE")
    check("smaller", qs.size_classification(qs.parse_quest_dat(quest_dat("smaller"))), "FITS_SMALLER")
    check("oversize", qs.size_classification(qs.parse_quest_dat(quest_dat("oversize"))), "TOO_LARGE")


def main():
    test_parse_quest_dat()
    test_parse_size()
    test_engine_compatible()
    test_size_classification()
    if FAILURES:
        print("FAIL (%d)" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `ModuleNotFoundError: No module named 'quest_survey'`

- [ ] **Step 4: Write the minimal implementation**

Create `scripts/lib/quest_survey.py`:

```python
#!/usr/bin/env python3
"""Static compatibility analysis for Solarus quests, for the MiSTer port.

Pure functions over a quest directory. No device, no engine, no network, no
third-party imports. Everything decidable by reading quest files lives here so
it can be decided before any scarce device time is spent.
"""

import re

# The port composites into a fixed 320x240 framebuffer (BLT_FB_WIDTH / FB_W / FB_H).
FB_SIZE = (320, 240)

# This port ships Solarus 1.6.5. Quests declaring any other major.minor will not load.
ENGINE_MAJOR_MINOR = (1, 6)


def parse_size(s):
    """'320x240' -> (320, 240). None/malformed -> None."""
    if not s:
        return None
    m = re.fullmatch(r"\s*(\d+)\s*x\s*(\d+)\s*", s)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)))


def _field(text, name):
    """Extract a quoted `name = "value"` field from quest.dat Lua source."""
    m = re.search(r"\b" + re.escape(name) + r"\s*=\s*\"([^\"]*)\"", text)
    return m.group(1) if m else None


def parse_quest_dat(text):
    """Parse quest.dat source into version + size range.

    Mirrors QuestProperties.cpp: normal_quest_size defaults to 320x240, and
    min/max default to normal when absent.
    """
    normal = parse_size(_field(text, "normal_quest_size")) or FB_SIZE
    return {
        "solarus_version": _field(text, "solarus_version"),
        "normal_size": normal,
        "min_size": parse_size(_field(text, "min_quest_size")) or normal,
        "max_size": parse_size(_field(text, "max_quest_size")) or normal,
    }


def engine_compatible(version):
    """True if this quest's declared solarus_version loads on our 1.6.5 engine."""
    if not version:
        return False
    m = re.match(r"(\d+)\.(\d+)", version)
    if not m:
        return False
    return (int(m.group(1)), int(m.group(2))) == ENGINE_MAJOR_MINOR


def size_classification(sizes, fb=FB_SIZE):
    """Which resolution rung this quest lands on.

    FITS                -- already our framebuffer size, nothing to do
    FITS_VIA_QUEST_SIZE -- launch with -quest-size 320x240 (declared range allows it)
    FITS_SMALLER        -- smaller than the framebuffer; composite with a border
    TOO_LARGE           -- needs a framebuffer we do not have
    """
    normal, lo, hi = sizes["normal_size"], sizes["min_size"], sizes["max_size"]
    if normal == fb:
        return "FITS"
    if lo[0] <= fb[0] <= hi[0] and lo[1] <= fb[1] <= hi[1]:
        return "FITS_VIA_QUEST_SIZE"
    if normal[0] <= fb[0] and normal[1] <= fb[1]:
        return "FITS_SMALLER"
    return "TOO_LARGE"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS`

- [ ] **Step 6: Prove the test can fail**

Temporarily change `ENGINE_MAJOR_MINOR` in `scripts/lib/quest_survey.py` to `(2, 0)`.
Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `FAIL (4)` listing the four `engine_compatible` checks.
Revert the change and confirm `PASS` again.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/quest_survey.py scripts/tests/test_quest_survey.py scripts/tests/fixtures/
git commit -m "feat(compat): quest.dat parsing and resolution-rung classification"
```

---

### Task 2: Lua input-surface scanning

**Files:**
- Modify: `scripts/lib/quest_survey.py`
- Modify: `scripts/tests/test_quest_survey.py`
- Create: `scripts/tests/fixtures/quests/private_layer/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/private_layer/data/lib/bindings.lua`
- Create: `scripts/tests/fixtures/quests/keyboard_values/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/keyboard_values/data/scripts/game_manager.lua`

**Interfaces:**
- Consumes: `FB_SIZE` from Task 1.
- Produces:
  - `scan_input_surface(quest_dir: pathlib.Path) -> dict` with keys `private_bindings: dict[str,str]` (action name → SDL key name), `has_key_handler: bool`, `private_layer: bool`
  - constant `ACTION_VOCAB: tuple[str, ...]`

The scanner recognises exactly two shapes, because those are the two that real quests use (per the 2026-07-25 controller-mapping design):

1. **Savegame keyboard values** — `game:set_value("keyboard_run", "left shift")`. This is ROTH SE's shape.
2. **Private binding tables** — `attack = "s",` inside a file that also defines `on_key_pressed`. This is Patched Tunics' shape.

Action names are matched against a **closed vocabulary**. An unrecognised name is not guessed at; it is simply not bound. This is deliberate — the spec's whole position on the heuristic risk is that we derive only from names the quest itself uses, and report rather than invent.

- [ ] **Step 1: Create the fixture quest trees**

`scripts/tests/fixtures/quests/private_layer/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "privatelayer",
  title = "Private input layer fixture",
  normal_quest_size = "320x240",
}
```

`scripts/tests/fixtures/quests/private_layer/data/lib/bindings.lua` — modelled on Patched Tunics' `lib/bindings.lua`, which binds every action on its own keys:
```lua
-- Fixture: a quest that runs its own input layer instead of GameCommands.
local bindings = {}

bindings.keys = {
  attack = "s",
  action = "space",
  item_1 = "a",
  item_2 = "d",
  inventory = "w",
  map = "tab",
  escape = "escape",
}

function bindings.mixin(game)
  function game:on_key_pressed(key, modifiers)
    return true
  end
end

return bindings
```

`scripts/tests/fixtures/quests/keyboard_values/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "keyboardvalues",
  title = "Savegame keyboard values fixture",
  normal_quest_size = "320x240",
}
```

`scripts/tests/fixtures/quests/keyboard_values/data/scripts/game_manager.lua` — modelled on ROTH SE's `scripts/game_manager.lua:27-32`:
```lua
-- Fixture: a quest using stock GameCommands PLUS quest-private keyboard values.
local game_manager = {}

function game_manager:initialize(game)
  game:set_value("keyboard_save", "escape")
  game:set_value("keyboard_run", "left shift")
  game:set_value("keyboard_map", "p")
  game:set_value("keyboard_monsters", "m")
  game:set_value("keyboard_look", "left control")
  game:set_value("keyboard_commands", "f1")
end

return game_manager
```

- [ ] **Step 2: Write the failing test**

Add to `scripts/tests/test_quest_survey.py`, before `main()`:

```python
def test_scan_private_layer():
    scan = qs.scan_input_surface(FIXTURES / "private_layer")
    check("pl has_key_handler", scan["has_key_handler"], True)
    check("pl private_layer", scan["private_layer"], True)
    check("pl bindings", scan["private_bindings"], {
        "attack": "s",
        "action": "space",
        "item_1": "a",
        "item_2": "d",
        "inventory": "w",
        "map": "tab",
        "escape": "escape",
    })


def test_scan_keyboard_values():
    scan = qs.scan_input_surface(FIXTURES / "keyboard_values")
    check("kv has_key_handler", scan["has_key_handler"], False)
    # Stock GameCommands still serve attack/action/items, so this is NOT a private layer.
    check("kv private_layer", scan["private_layer"], False)
    check("kv bindings", scan["private_bindings"], {
        "save": "escape",
        "run": "left shift",
        "map": "p",
        "monsters": "m",
        "look": "left control",
        "commands": "f1",
    })


def test_scan_stock_quest_has_no_bindings():
    scan = qs.scan_input_surface(FIXTURES / "stock_320")
    check("stock bindings", scan["private_bindings"], {})
    check("stock private_layer", scan["private_layer"], False)
```

And add these three calls inside `main()` before the `if FAILURES:` block:

```python
    test_scan_private_layer()
    test_scan_keyboard_values()
    test_scan_stock_quest_has_no_bindings()
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `AttributeError: module 'quest_survey' has no attribute 'scan_input_surface'`

- [ ] **Step 4: Write the minimal implementation**

Append to `scripts/lib/quest_survey.py`:

```python
# Action names we will bind. A quest-private action outside this vocabulary is
# reported but never guessed at -- see the design's position on heuristic risk.
ACTION_VOCAB = (
    "action", "attack", "item_1", "item_2", "pause",
    "save", "escape", "run", "map", "inventory",
    "monsters", "look", "commands",
)

# The four actions stock GameCommands owns. A quest that privately binds ALL of
# them has replaced GameCommands outright (Patched Tunics); a quest that binds
# none or some of them is still served by [default] for the rest (ROTH SE).
_CORE_ACTIONS = ("attack", "action", "item_1", "item_2")

# game:set_value("keyboard_run", "left shift")
_KEYBOARD_VALUE_RE = re.compile(
    r"set_value\s*\(\s*[\"']keyboard_(\w+)[\"']\s*,\s*[\"']([^\"']+)[\"']"
)

# attack = "s",   (inside a private binding table)
_TABLE_BINDING_RE = re.compile(r"^\s*(\w+)\s*=\s*[\"']([a-z0-9]+(?: [a-z0-9]+)*)[\"']\s*,?\s*$")


def _lua_files(quest_dir):
    return sorted(quest_dir.rglob("*.lua"))


def scan_input_surface(quest_dir):
    """Report which keys a quest binds outside stock GameCommands defaults."""
    bindings = {}
    has_key_handler = False

    for path in _lua_files(quest_dir):
        text = path.read_text(errors="replace")
        file_has_handler = "on_key_pressed" in text
        has_key_handler = has_key_handler or file_has_handler

        # Shape 1: savegame keyboard values (works in any file).
        for action, key in _KEYBOARD_VALUE_RE.findall(text):
            if action in ACTION_VOCAB:
                bindings.setdefault(action, key)

        # Shape 2: a private binding table -- only trusted in a file that also
        # installs a key handler, so ordinary data tables cannot be mistaken
        # for an input map.
        if file_has_handler:
            for line in text.splitlines():
                m = _TABLE_BINDING_RE.match(line)
                if m and m.group(1) in ACTION_VOCAB:
                    bindings.setdefault(m.group(1), m.group(2))

    private_layer = all(a in bindings for a in _CORE_ACTIONS)
    return {
        "private_bindings": bindings,
        "has_key_handler": has_key_handler,
        "private_layer": private_layer,
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS`

- [ ] **Step 6: Prove the test can fail**

Temporarily remove `"map"` from `ACTION_VOCAB`.
Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `FAIL (2)` — both `pl bindings` and `kv bindings` lose their `map` entry.
Revert and confirm `PASS`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/quest_survey.py scripts/tests/test_quest_survey.py scripts/tests/fixtures/
git commit -m "feat(compat): scan quest Lua for private key bindings"
```

---

### Task 3: Shader detection and verdict resolution

**Files:**
- Modify: `scripts/lib/quest_survey.py`
- Modify: `scripts/tests/test_quest_survey.py`
- Create: `scripts/tests/fixtures/quests/shader_user/data/quest.dat`
- Create: `scripts/tests/fixtures/quests/shader_user/data/main.lua`

**Interfaces:**
- Consumes: `parse_quest_dat`, `engine_compatible`, `size_classification`, `scan_input_surface` from Tasks 1-2.
- Produces:
  - `scan_shaders(quest_dir) -> list[str]` (sorted relative paths of files referencing `sol.shader`)
  - `interrogate(quest_dir) -> dict` — the full per-quest record
  - `VERDICT_SEVERITY: tuple[str, ...]` — most severe first

Verdict severity, from the spec, most severe first:
`WRONG_ENGINE > NEEDS_SHADERS > NEEDS_LARGER_FB > RUNNABLE_WITH_KEYMAP > RUNNABLE`

- [ ] **Step 1: Create the shader fixture**

`scripts/tests/fixtures/quests/shader_user/data/quest.dat`:
```lua
quest{
  solarus_version = "1.6",
  write_dir = "shaderuser",
  title = "Shader fixture",
  normal_quest_size = "320x240",
}
```

`scripts/tests/fixtures/quests/shader_user/data/main.lua`:
```lua
-- Fixture: a quest that requires a shader, which this port cannot provide.
function sol.main:on_started()
  local shader = sol.shader.create("scanlines")
  sol.video.set_shader(shader)
end
```

- [ ] **Step 2: Write the failing test**

Add to `scripts/tests/test_quest_survey.py` before `main()`:

```python
def test_scan_shaders():
    check("shader found", qs.scan_shaders(FIXTURES / "shader_user"), ["data/main.lua"])
    check("no shader", qs.scan_shaders(FIXTURES / "stock_320"), [])


def test_interrogate_verdicts():
    def verdict_of(name):
        return qs.interrogate(FIXTURES / name)["verdict"]

    check("stock verdict", verdict_of("stock_320"), "RUNNABLE")
    check("wrong engine verdict", verdict_of("wrong_engine"), "WRONG_ENGINE")
    check("shader verdict", verdict_of("shader_user"), "NEEDS_SHADERS")
    check("oversize verdict", verdict_of("oversize"), "NEEDS_LARGER_FB")
    check("via verdict", verdict_of("via_quest_size"), "RUNNABLE")
    check("smaller verdict", verdict_of("smaller"), "RUNNABLE")
    check("private layer verdict", verdict_of("private_layer"), "RUNNABLE_WITH_KEYMAP")
    check("keyboard values verdict", verdict_of("keyboard_values"), "RUNNABLE_WITH_KEYMAP")


def test_interrogate_record_shape():
    rec = qs.interrogate(FIXTURES / "via_quest_size")
    check("rec id", rec["quest_id"], "via_quest_size")
    check("rec version", rec["solarus_version"], "1.6")
    check("rec normal", rec["normal_size"], [400, 240])
    check("rec rung", rec["size_classification"], "FITS_VIA_QUEST_SIZE")
    check("rec quest_size_arg", rec["quest_size_arg"], "320x240")
    check("rec stock arg", qs.interrogate(FIXTURES / "stock_320")["quest_size_arg"], None)


def test_severity_beats_lesser_findings():
    # wrong_engine must not be reported as merely needing a keymap or a bigger FB.
    rec = qs.interrogate(FIXTURES / "wrong_engine")
    check("severity wins", rec["verdict"], "WRONG_ENGINE")
    check("findings retained", "WRONG_ENGINE" in rec["findings"], True)
```

Add the four calls inside `main()`:

```python
    test_scan_shaders()
    test_interrogate_verdicts()
    test_interrogate_record_shape()
    test_severity_beats_lesser_findings()
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `AttributeError: module 'quest_survey' has no attribute 'scan_shaders'`

- [ ] **Step 4: Write the minimal implementation**

Append to `scripts/lib/quest_survey.py`:

```python
# Most severe first. A quest that cannot load must never be reported as merely
# needing a keymap.
VERDICT_SEVERITY = (
    "WRONG_ENGINE",
    "NEEDS_SHADERS",
    "NEEDS_LARGER_FB",
    "RUNNABLE_WITH_KEYMAP",
    "RUNNABLE",
)


def scan_shaders(quest_dir):
    """Relative paths of Lua files referencing sol.shader (unavailable in this port)."""
    hits = []
    for path in _lua_files(quest_dir):
        if "sol.shader" in path.read_text(errors="replace"):
            hits.append(str(path.relative_to(quest_dir)))
    return sorted(hits)


def interrogate(quest_dir):
    """Full static compatibility record for one quest directory."""
    quest_dat_path = quest_dir / "data" / "quest.dat"
    sizes = parse_quest_dat(quest_dat_path.read_text(errors="replace"))
    rung = size_classification(sizes)
    scan = scan_input_surface(quest_dir)
    shaders = scan_shaders(quest_dir)

    findings = []
    if not engine_compatible(sizes["solarus_version"]):
        findings.append("WRONG_ENGINE")
    if shaders:
        findings.append("NEEDS_SHADERS")
    if rung == "TOO_LARGE":
        findings.append("NEEDS_LARGER_FB")
    if scan["private_bindings"]:
        findings.append("RUNNABLE_WITH_KEYMAP")
    if not findings:
        findings.append("RUNNABLE")

    verdict = next(v for v in VERDICT_SEVERITY if v in findings)

    return {
        "quest_id": quest_dir.name,
        "solarus_version": sizes["solarus_version"],
        "normal_size": list(sizes["normal_size"]),
        "min_size": list(sizes["min_size"]),
        "max_size": list(sizes["max_size"]),
        "size_classification": rung,
        "quest_size_arg": "%dx%d" % FB_SIZE if rung == "FITS_VIA_QUEST_SIZE" else None,
        "private_bindings": scan["private_bindings"],
        "private_layer": scan["private_layer"],
        "shader_files": shaders,
        "findings": findings,
        "verdict": verdict,
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS`

- [ ] **Step 6: Prove the test can fail**

Temporarily reorder `VERDICT_SEVERITY` to put `"RUNNABLE_WITH_KEYMAP"` first.
Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `FAIL` naming `keyboard values verdict` or `severity wins`.
Revert and confirm `PASS`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/quest_survey.py scripts/tests/test_quest_survey.py scripts/tests/fixtures/
git commit -m "feat(compat): shader detection and per-quest verdict resolution"
```

---

### Task 4: controls.cfg section generation

**Files:**
- Modify: `scripts/lib/quest_survey.py`
- Modify: `scripts/tests/test_quest_survey.py`

**Interfaces:**
- Consumes: `interrogate`, `ACTION_VOCAB` from Tasks 1-3.
- Produces:
  - `generate_mapping(record: dict) -> dict` — `{'rows': dict[str,str], 'dropped': list[str]}` where `rows` maps a pad input to an SDL key name
  - `render_section(quest_id: str, mapping: dict) -> str|None` — the `controls.cfg` text, or `None` when no section is needed
  - constants `PAD_INPUTS`, `CORE_SLOTS`, `DIRECTION_ROWS`, `SPARE_SLOT_ORDER`, `SPARE_ACTION_PRIORITY`

The pad input names and file syntax come from the shipped `games/Solarus/controls.cfg.default`:
inputs are `right left down up a b x y l r select start`, rows read `<input> = key <sdl key name>` or `<input> = none`, and layering is built-in defaults → `[default]` → `[<quest-id>]` with later winning — so **a section states only its differences**.

Slot assignment, per the spec:

| Pad input | Action |
| --- | --- |
| `right`/`left`/`down`/`up` | directions |
| `a` | action |
| `b` | attack |
| `y` | item_1 |
| `x` | item_2 |
| `start` | pause |
| spares, in order `start` (only when no pause is bound), `l`, `r`, `select` | remaining named actions by priority `save > escape > run > map > inventory > monsters > look > commands` |

- [ ] **Step 1: Write the failing test**

Add to `scripts/tests/test_quest_survey.py` before `main()`:

```python
def test_generate_stock_quest_needs_no_section():
    rec = qs.interrogate(FIXTURES / "stock_320")
    mapping = qs.generate_mapping(rec)
    check("stock rows", mapping["rows"], {})
    check("stock dropped", mapping["dropped"], [])
    check("stock section", qs.render_section("stock_320", mapping), None)


def test_generate_private_layer():
    # A private layer rebinds everything, so the section restates the core rows.
    rec = qs.interrogate(FIXTURES / "private_layer")
    mapping = qs.generate_mapping(rec)
    check("pl rows", mapping["rows"], {
        "right": "right", "left": "left", "down": "down", "up": "up",
        "b": "s",        # attack
        "a": "space",    # action
        "y": "a",        # item_1
        "x": "d",        # item_2
        "start": "escape",   # no pause bound -> start is spare, escape has priority
        "l": "tab",          # map
        "r": "w",            # inventory
    })
    check("pl dropped", mapping["dropped"], [])


def test_generate_keyboard_values_oversubscribed():
    # Stock GameCommands still own a/b/x/y/start, so only l, r, select are spare
    # and three of the six private commands cannot be mapped.
    rec = qs.interrogate(FIXTURES / "keyboard_values")
    mapping = qs.generate_mapping(rec)
    check("kv rows", mapping["rows"], {
        "l": "escape",       # save
        "r": "left shift",   # run
        "select": "p",       # map
    })
    check("kv dropped", mapping["dropped"], ["monsters", "look", "commands"])


def test_render_section_reports_dropped():
    rec = qs.interrogate(FIXTURES / "keyboard_values")
    text = qs.render_section("keyboard_values", qs.generate_mapping(rec))
    check("header", text.splitlines()[0], "[keyboard_values]")
    check("mentions dropped", "monsters" in text and "look" in text and "commands" in text, True)
    check("row present", "l      = key escape" in text, True)


def test_no_key_bound_twice():
    for name in ("private_layer", "keyboard_values"):
        rows = qs.generate_mapping(qs.interrogate(FIXTURES / name))["rows"]
        check("%s unique inputs" % name, len(rows), len(set(rows)))
```

Add the calls inside `main()`:

```python
    test_generate_stock_quest_needs_no_section()
    test_generate_private_layer()
    test_generate_keyboard_values_oversubscribed()
    test_render_section_reports_dropped()
    test_no_key_bound_twice()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `AttributeError: module 'quest_survey' has no attribute 'generate_mapping'`

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/quest_survey.py`:

```python
# Pad inputs, in the CONF_STR J1 order used by games/Solarus/controls.cfg.default.
PAD_INPUTS = ("right", "left", "down", "up", "a", "b", "x", "y", "l", "r", "select", "start")

# Stock GameCommands actions and the pad input each owns.
CORE_SLOTS = {"action": "a", "attack": "b", "item_1": "y", "item_2": "x", "pause": "start"}

DIRECTION_ROWS = {"right": "right", "left": "left", "down": "down", "up": "up"}

# Spare inputs, in assignment order. `start` is spare only when the quest binds
# no pause. This order reproduces the hand-authored Patched Tunics section exactly.
SPARE_SLOT_ORDER = ("start", "l", "r", "select")

# Which leftover named actions win a spare input when there are not enough.
SPARE_ACTION_PRIORITY = (
    "save", "escape", "run", "map", "inventory", "monsters", "look", "commands",
)


def generate_mapping(record):
    """Build the pad-input -> SDL-key table for one quest.

    Returns {'rows': {input: key}, 'dropped': [action, ...]}. `rows` states only
    what differs from [default]; `dropped` names actions with no spare input left.
    """
    bindings = record["private_bindings"]
    rows = {}

    if record["private_layer"]:
        # The quest replaced GameCommands outright, so [default]'s rows are all
        # wrong for it -- restate directions and every core action it binds.
        rows.update(DIRECTION_ROWS)
        for action, slot in CORE_SLOTS.items():
            if action in bindings:
                rows[slot] = bindings[action]

    occupied = set(rows)
    if not record["private_layer"]:
        # [default] already owns every core input for a stock-commands quest,
        # including `start` for pause -- so only l, r, select are ever spare.
        occupied |= set(CORE_SLOTS.values()) | set(DIRECTION_ROWS)
    spares = [s for s in SPARE_SLOT_ORDER if s not in occupied]

    leftover = [a for a in SPARE_ACTION_PRIORITY if a in bindings and a not in CORE_SLOTS]

    dropped = []
    for i, action in enumerate(leftover):
        if i < len(spares):
            rows[spares[i]] = bindings[action]
        else:
            dropped.append(action)

    return {"rows": rows, "dropped": dropped}


def render_section(quest_id, mapping):
    """Render a controls.cfg section, or None when the quest needs no section."""
    if not mapping["rows"]:
        return None

    lines = ["[%s]" % quest_id]
    lines.append("; Generated by scripts/quest_interrogate.py from this quest's own")
    lines.append("; action names. Edit freely -- this file is read from the SD card.")
    if mapping["dropped"]:
        lines.append(
            "; Left unmapped for lack of spare pad inputs: %s."
            % ", ".join(mapping["dropped"])
        )
        lines.append("; Reach them by swapping one of the rows below.")
    for inp in PAD_INPUTS:
        if inp in mapping["rows"]:
            lines.append("%-6s = key %s" % (inp, mapping["rows"][inp]))
    return "\n".join(lines) + "\n"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS`

- [ ] **Step 5: Prove the test can fail**

Temporarily change `SPARE_SLOT_ORDER` to `("l", "r", "select", "start")`.
Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `FAIL` on `pl rows` — `escape` moves off `start`.
Revert and confirm `PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/quest_survey.py scripts/tests/test_quest_survey.py
git commit -m "feat(compat): generate per-quest controls.cfg sections"
```

---

### Task 5: Golden test against the shipped controls.cfg

**Files:**
- Modify: `scripts/lib/quest_survey.py`
- Modify: `scripts/tests/test_quest_survey.py`

**Interfaces:**
- Consumes: `generate_mapping`, `render_section` from Task 4.
- Produces: `parse_controls_section(text: str, section: str) -> dict[str,str]` — pad input → key name for one section, `none` rows omitted.

This is the task that decides whether the generator can be trusted. The two hand-authored sections in `games/Solarus/controls.cfg.default` were written from careful source reading and are the closest thing to ground truth available.

**They do not follow one consistent spare-slot rule** — Patched Tunics assigns spares in `start, l, r` order, ROTH used `select, l, r` — so the assertions differ by necessity. That is a property of the hand-authored data, not a weakness of the generator:

- **Patched Tunics:** all rows must match exactly.
- **ROTH SE:** the set of mapped *keys* must match exactly, and the three dropped commands must be reported; which spare input each lands on is not asserted.

Because there is no committed copy of the PT or ROTH quest source, the golden test drives the generator from **hand-written binding dicts transcribed from the 2026-07-25 design doc**, not from a quest scan. It tests the generator, which is the part under our control.

- [ ] **Step 1: Write the failing test**

Add to `scripts/tests/test_quest_survey.py` before `main()`:

```python
CONTROLS_CFG = ROOT / "games" / "Solarus" / "controls.cfg.default"

# Transcribed from docs/superpowers/specs/2026-07-25-per-quest-controller-mapping-design.md.
PT_BINDINGS = {
    "attack": "s", "action": "space", "item_1": "a", "item_2": "d",
    "inventory": "w", "map": "tab", "escape": "escape",
}
ROTH_BINDINGS = {
    "save": "escape", "run": "left shift", "map": "p",
    "monsters": "m", "look": "left control", "commands": "f1",
}


def _record(bindings, private_layer):
    return {"private_bindings": bindings, "private_layer": private_layer}


def test_golden_patched_tunics_exact():
    want = qs.parse_controls_section(CONTROLS_CFG.read_text(), "patched-tunics-b007e656")
    got = qs.generate_mapping(_record(PT_BINDINGS, True))["rows"]
    check("PT golden", got, want)


def test_golden_roth_action_set():
    want = qs.parse_controls_section(CONTROLS_CFG.read_text(), "zelda-roth-se-v1.2.1")
    mapping = qs.generate_mapping(_record(ROTH_BINDINGS, False))
    check("ROTH key set", sorted(mapping["rows"].values()), sorted(want.values()))
    check("ROTH count", len(mapping["rows"]), 3)
    check("ROTH dropped", mapping["dropped"], ["monsters", "look", "commands"])


def test_parse_controls_section_ignores_none_rows():
    parsed = qs.parse_controls_section(CONTROLS_CFG.read_text(), "patched-tunics-b007e656")
    check("select omitted", "select" in parsed, False)
    check("start present", parsed.get("start"), "escape")
```

Add the calls inside `main()`:

```python
    test_golden_patched_tunics_exact()
    test_golden_roth_action_set()
    test_parse_controls_section_ignores_none_rows()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `AttributeError: module 'quest_survey' has no attribute 'parse_controls_section'`

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/lib/quest_survey.py`:

```python
_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
_ROW_RE = re.compile(r"^\s*(\w+)\s*=\s*key\s+([^;]+?)\s*(?:;.*)?$")


def parse_controls_section(text, section):
    """Parse one [section] of a controls.cfg into {pad_input: sdl_key}.

    `= none` rows and comments are omitted, so the result compares directly
    against generate_mapping()['rows'].
    """
    rows = {}
    in_section = False
    for line in text.splitlines():
        m = _SECTION_RE.match(line)
        if m:
            in_section = (m.group(1) == section)
            continue
        if not in_section:
            continue
        m = _ROW_RE.match(line)
        if m and m.group(1) in PAD_INPUTS:
            rows[m.group(1)] = m.group(2)
    return rows
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS`

If `PT golden` fails, the generator does not reproduce the hand-authored section — **do not weaken the test to make it pass.** Fix `SPARE_SLOT_ORDER` / `SPARE_ACTION_PRIORITY` until it matches, or escalate: the exact-match claim is the spec's stated justification for trusting the generator.

- [ ] **Step 5: Prove the test can fail**

Temporarily change `SPARE_ACTION_PRIORITY` to put `"map"` before `"escape"`.
Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `FAIL` on `PT golden` — `start` and `l` swap.
Revert and confirm `PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/quest_survey.py scripts/tests/test_quest_survey.py
git commit -m "test(compat): golden test generator against shipped controls.cfg"
```

---

### Task 6: CLI and CI wiring

**Files:**
- Create: `scripts/quest_interrogate.py`
- Modify: `.github/workflows/patch-series-ci.yml`

**Interfaces:**
- Consumes: `interrogate`, `generate_mapping`, `render_section` from Tasks 1-5.
- Produces: a CLI emitting a JSON array of records to stdout, one per quest directory, each record extended with `controls_section: str|None` and `dropped_actions: list[str]`.

- [ ] **Step 1: Write the failing test**

Add `import json` and `import subprocess` to the imports at the top of
`scripts/tests/test_quest_survey.py`, then add before `main()`:

```python
def test_cli_emits_json():
    out = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "quest_interrogate.py"),
         str(FIXTURES / "stock_320"), str(FIXTURES / "private_layer")],
        capture_output=True, text=True, check=True,
    ).stdout
    recs = json.loads(out)
    check("cli count", len(recs), 2)
    check("cli ids", [r["quest_id"] for r in recs], ["stock_320", "private_layer"])
    check("cli stock section", recs[0]["controls_section"], None)
    check("cli pl section head", recs[1]["controls_section"].splitlines()[0], "[private_layer]")
    check("cli pl dropped", recs[1]["dropped_actions"], [])


def test_cli_rejects_non_quest_dir():
    r = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "quest_interrogate.py"), str(ROOT / "scripts")],
        capture_output=True, text=True,
    )
    check("cli exit", r.returncode, 1)
    check("cli stderr", "quest.dat" in r.stderr, True)
```

Add the calls inside `main()`:

```python
    test_cli_emits_json()
    test_cli_rejects_non_quest_dir()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `FAIL` — `subprocess.CalledProcessError` because `scripts/quest_interrogate.py` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/quest_interrogate.py`:

```python
#!/usr/bin/env python3
"""Report static MiSTer-port compatibility for one or more Solarus quest dirs.

Usage: scripts/quest_interrogate.py <quest-dir> [<quest-dir> ...]

Emits a JSON array of per-quest records on stdout. Exits 1 if any argument is
not a quest directory (no data/quest.dat).
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

import quest_survey as qs


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    dirs = [Path(a) for a in argv[1:]]
    for d in dirs:
        if not (d / "data" / "quest.dat").is_file():
            print("not a quest directory (no data/quest.dat): %s" % d, file=sys.stderr)
            return 1

    records = []
    for d in dirs:
        rec = qs.interrogate(d)
        mapping = qs.generate_mapping(rec)
        rec["controls_section"] = qs.render_section(rec["quest_id"], mapping)
        rec["dropped_actions"] = mapping["dropped"]
        records.append(rec)

    json.dump(records, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS`

- [ ] **Step 5: Wire into CI**

In `.github/workflows/patch-series-ci.yml`, after the existing `test_manifest.sh` step, add:

```yaml
      - name: Quest compatibility interrogator tests
        run: python3 scripts/tests/test_quest_survey.py
```

- [ ] **Step 6: Verify the CI step command works from a clean checkout path**

Run: `cd / && python3 "$OLDPWD/scripts/tests/test_quest_survey.py"; cd -`
Expected: `PASS` — the test resolves paths from `__file__`, not the working directory.

- [ ] **Step 7: Commit**

```bash
git add scripts/quest_interrogate.py scripts/tests/test_quest_survey.py .github/workflows/patch-series-ci.yml
git commit -m "feat(compat): quest_interrogate CLI and CI wiring"
```

---

### Task 7: Corpus manifest and fetch script

**Files:**
- Create: `scripts/quests.tsv`
- Create: `scripts/fetch_corpus.sh`
- Create: `scripts/tests/test_quests_manifest.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `deploy/quests/<quest_id>/` trees for `scripts/quest_interrogate.py` to read.

Manifest columns, tab-separated: `quest_id`, `source_url`, `ref`, `expected_version`, `license`, `redistributable`. Comment lines start with `#`.

**The `ref` column is load-bearing.** `scripts/fetch_quest.sh` already pins MoSDX to `release-1.12.3` precisely because master/dev target Solarus 2.0 and will not load on our 1.6.5 engine. Every entry must pin a ref that targets Solarus 1.6; an unpinned clone silently fetches an incompatible quest.

- [ ] **Step 1: Create the manifest seeded with the three known quests**

Create `scripts/quests.tsv`:
```
# Quest compatibility corpus. Tab-separated. Quest DATA is never committed --
# scripts/fetch_corpus.sh clones each entry at its pinned ref.
#
# ref MUST target Solarus 1.6. Many quests' master/dev branches target Solarus
# 2.x and will not load on our 1.6.5 engine (see scripts/fetch_quest.sh).
#
# quest_id	source_url	ref	expected_version	license	redistributable
mystery_of_solarus_dx	https://gitlab.com/solarus-games/zsdx.git	release-1.12.3	1.6	GPL-3.0	yes
```

Additional entries are added in Task 8 as the corpus is enumerated.

- [ ] **Step 2: Write the failing test**

Create `scripts/tests/test_quests_manifest.sh`:

```bash
#!/bin/bash
# Validate scripts/quests.tsv structurally: 6 columns, no unpinned refs, no
# duplicate ids. Pure text checks -- no network.
set -u
cd "$(dirname "$0")/../.."

MANIFEST=scripts/quests.tsv
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST missing"; exit 1; }

lineno=0
while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac

    n=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
    [ "$n" -eq 6 ] || fail "line $lineno: expected 6 tab-separated columns, got $n"

    ref=$(printf '%s' "$line" | cut -f3)
    case "$ref" in
        master|main|dev|develop|'') fail "line $lineno: ref '$ref' is not pinned" ;;
    esac

    ver=$(printf '%s' "$line" | cut -f4)
    case "$ver" in
        1.6*) ;;
        *) fail "line $lineno: expected_version '$ver' is not 1.6-compatible" ;;
    esac

    id=$(printf '%s' "$line" | cut -f1)
    printf '%s\n' "$id"
done < "$MANIFEST" | sort | uniq -d | while read -r dup; do
    [ -n "$dup" ] && fail "duplicate quest_id: $dup"
done

if [ "$fails" -ne 0 ]; then
    echo "FAIL ($fails)"
    exit 1
fi
echo "PASS"
```

- [ ] **Step 3: Run the test to verify it fails**

First prove it can fail: temporarily append a bad row to `scripts/quests.tsv`:
```
bad_quest	https://example.invalid/x.git	master	2.0	unknown	no
```
Run: `bash scripts/tests/test_quests_manifest.sh`
Expected: `FAIL (2)` — unpinned ref and non-1.6 version.
Remove the bad row.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/tests/test_quests_manifest.sh`
Expected: `PASS`

- [ ] **Step 5: Write the fetch script**

Create `scripts/fetch_corpus.sh`:

```bash
#!/bin/bash
# Clone every quest in scripts/quests.tsv at its pinned ref into deploy/quests/.
# Quest data is never committed; this script re-fetches it.
#
# Usage: scripts/fetch_corpus.sh [quest_id ...]   (default: all)
set -u
cd "$(dirname "$0")/.."

MANIFEST=scripts/quests.tsv
mkdir -p deploy/quests

want="$*"
rc=0

while IFS=$'\t' read -r id url ref version license redistributable; do
    case "$id" in ''|'#'*) continue ;; esac
    if [ -n "$want" ]; then
        case " $want " in *" $id "*) ;; *) continue ;; esac
    fi

    dest="deploy/quests/$id"
    if [ -d "$dest/data" ]; then
        echo "== $id: already present at $dest"
        continue
    fi

    echo "== $id: cloning $url at $ref"
    if git clone --depth 1 --branch "$ref" "$url" "$dest"; then
        echo "   ok -> $dest (expected solarus_version $version, $license)"
    else
        echo "   FAILED to clone $id from $url at $ref" >&2
        rc=1
    fi
done < "$MANIFEST"

exit "$rc"
```

- [ ] **Step 6: Verify the fetch script against the one known-good entry**

Run: `bash scripts/fetch_corpus.sh mystery_of_solarus_dx`
Expected: either `== mystery_of_solarus_dx: already present at deploy/quests/mystery_of_solarus_dx`, or a successful clone.

Then verify the interrogator reads a real quest:
Run: `python3 scripts/quest_interrogate.py deploy/quests/mystery_of_solarus_dx`
Expected: JSON with `"solarus_version": "1.6"`, `"normal_size": [320, 240]`, `"size_classification": "FITS"`, `"verdict": "RUNNABLE"`, `"controls_section": null`.

That last value is the strongest single check in this plan: MoSDX is the one quest known to need no section, and the generator agreeing is independent confirmation that the stock-commands path is right.

- [ ] **Step 7: Commit**

```bash
chmod +x scripts/fetch_corpus.sh
git add scripts/quests.tsv scripts/fetch_corpus.sh scripts/tests/test_quests_manifest.sh
git commit -m "feat(compat): corpus manifest and pinned fetch script"
```

---

### Task 8: Run the survey, publish the matrix, answer the gate

**Files:**
- Modify: `scripts/quests.tsv`
- Create: `docs/quest-compatibility.md`
- Modify: `games/Solarus/controls.cfg.default`
- Modify: `README.md:97-106` (the "Known limitations" section)
- Create: `docs/superpowers/2026-07-27-quest-compat-resolution-gate.md`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: the survey result, and the gate decision that determines whether a banded-framebuffer spec gets written.

This task is where the pass stops being tooling and starts being an answer.

- [ ] **Step 1: Enumerate the corpus and fill the manifest**

Enumerate the freely-redistributable quests on the official Solarus games list (`https://www.solarus-games.org/en/games`). For each, find the newest ref whose `quest.dat` declares `solarus_version = "1.6"` — check tags and release branches, not master, since master commonly targets Solarus 2.x.

Add one row per quest to `scripts/quests.tsv`. Record the license and redistribution status from the quest's own repository, not from assumption.

Run: `bash scripts/tests/test_quests_manifest.sh`
Expected: `PASS`

- [ ] **Step 2: Fetch and survey the corpus**

Run:
```bash
bash scripts/fetch_corpus.sh
python3 scripts/quest_interrogate.py deploy/quests/*/ > /tmp/survey.json
python3 -c "
import json
for r in json.load(open('/tmp/survey.json')):
    print('%-32s %-24s %-20s %s' % (r['quest_id'], r['verdict'], r['size_classification'], r['solarus_version']))
"
```

Record which quests failed to clone at all — an unreachable source is a matrix row too, not a silent omission.

- [ ] **Step 3: Write the matrix**

Create `docs/quest-compatibility.md` with one row per corpus quest: quest id, version, declared normal size, resolution rung, verdict, keymap needed, and **evidence tier**. Every row in this task is tier 1 (static analysis only) — no quest has been run yet. State that plainly at the top; the device harness is a separate plan, and a matrix that implies more evidence than it has is worse than no matrix.

- [ ] **Step 4: Regenerate controls.cfg.default**

Run:
```bash
python3 -c "
import json
for r in json.load(open('/tmp/survey.json')):
    if r['controls_section']:
        print(r['controls_section'])
"
```

Merge the generated sections into `games/Solarus/controls.cfg.default`, keeping the existing header comment and `[default]` section unchanged.

> **ROTH SE's shipped spare-button layout changes.** The hand-authored section put save on `select`, run on `l`, map on `r`; the generator assigns them in `l, r, select` order. Same three commands, different buttons. This is a user-visible change to a working quest — flag it explicitly in the commit message and put it on the operator shortlist for the device plan. Do not silently ship it.

Run: `python3 scripts/tests/test_quest_survey.py`
Expected: `PASS` — the golden test still parses the file after the merge.

- [ ] **Step 5: Answer the resolution gate**

The criterion, pre-registered in the spec before any data existed:

> Open a banded-framebuffer spec **only if ≥2 corpus quests are 1.6-compatible, shader-free, and cannot be satisfied at ≤320×240.**

Count the quests whose record has `verdict != "WRONG_ENGINE"`, empty `shader_files`, and `size_classification == "TOO_LARGE"`.

Create `docs/superpowers/2026-07-27-quest-compat-resolution-gate.md` recording the count, the quests it comprises, and the decision. If the count is below 2, this is a **NO-GO document** — write it as one, in the style of the existing decision docs, so nobody re-chases it.

- [ ] **Step 6: Update the README**

Replace the two "Known limitations" bullets at `README.md:97-106` that currently read *"Quest compatibility is validated primarily against Mystery of Solarus DX; other quests should work but are less tested"* with the measured position: how many corpus quests are 1.6-compatible, how many need a keymap (now generated), and what the resolution limit actually excludes.

If the survey found the corpus is largely Solarus 2.x, **say so plainly** — the spec pre-commits to reporting that rather than burying it. It is the single most consequential thing this pass can discover, and it reframes the port's roadmap.

- [ ] **Step 7: Commit**

```bash
git add scripts/quests.tsv docs/quest-compatibility.md games/Solarus/controls.cfg.default README.md docs/superpowers/2026-07-27-quest-compat-resolution-gate.md
git commit -m "feat(compat): corpus survey, compatibility matrix, and resolution gate answer

Regenerates controls.cfg.default from the survey. NOTE: ROTH SE's spare-button
layout changes (save/run/map move from select,l,r to l,r,select) -- needs an
operator check before release."
```

---

## What this plan does NOT cover

Two subsystems from the spec are deliberately deferred to their own plans, because this plan's output determines their scope:

1. **Device smoke harness** (`scripts/quest_compat.sh`, DDR3 frame grabs, evidence tiers 2 and 3). Scope depends on how many quests survive Task 8's survey — planning a harness for a corpus that turns out to be mostly Solarus 2.x would be planning work the survey moots.
2. **Failure UX** (`mister_msgscreen.h`, `quest.info` sidecar, `solarus_run.sh` pre-flight, the `is_fpga_target` relaxation for sub-320×240 quests, and the runtime quest-size-change handling that relaxation makes reachable). This is the only part that touches the engine, and the sub-320×240 relaxation is only worth building if the survey finds quests that need it.

When writing the failure-UX plan, carry this forward: **`mister_msgscreen.h` must be registered in `scripts/apply_mister_files.sh` and verified with `scripts/docker_run.sh scripts/build_engine.sh`.** Per `CLAUDE.md` this exact omission has shipped twice; neither the native `-fsyntax-only` check nor code review can catch it.
