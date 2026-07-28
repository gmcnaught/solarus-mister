"""Static compatibility analysis for Solarus quests, for the MiSTer port.

Pure functions over a quest directory. No device, no engine, no network, no
third-party imports. Everything decidable by reading quest files lives here so
it can be decided before any scarce device time is spent.
"""

import re

# The port composites into a fixed 320x240 framebuffer (BLT_FB_WIDTH / FB_W / FB_H).
FB_SIZE = (320, 240)

# This port ships Solarus 1.6.5. The engine's own compatibility rule (NOT plain
# equality) is: quest major must match ENGINE_MAJOR_VERSION exactly, and quest
# minor must fall in ENGINE_SUPPORTED_MINOR_RANGE inclusive. The patch digit is
# never consulted. Source of truth: check_version_compatibility() in
# work/solarus/src/core/MainLoop.cpp -- do not let this drift from it.
ENGINE_MAJOR_VERSION = 1
ENGINE_SUPPORTED_MINOR_RANGE = (5, 6)  # (min_minor, max_minor), inclusive


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
    """True if this quest's declared solarus_version loads on our 1.6.5 engine.

    Mirrors check_version_compatibility() in
    work/solarus/src/core/MainLoop.cpp: the patch digit is ignored, the major
    version must match exactly, and the minor version must fall within
    ENGINE_SUPPORTED_MINOR_RANGE (a quest newer than the engine's minor is
    too recent; a 1.x quest older than 1.5 predates the engine's backward-
    compatibility guarantee). A missing or unparsable version -- including a
    literal major version of 0 -- is incompatible, matching the engine's own
    "No Solarus version is specified" hard failure.
    """
    if not version:
        return False
    m = re.match(r"(\d+)\.(\d+)", version)
    if not m:
        return False
    major, minor = int(m.group(1)), int(m.group(2))
    if major == 0:
        return False
    if major != ENGINE_MAJOR_VERSION:
        return False
    lo, hi = ENGINE_SUPPORTED_MINOR_RANGE
    return lo <= minor <= hi


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

# attack = "s",   (anywhere in a file with a key handler -- see below). Flat
# `action = "key"` shape; not anchored to a whole line, since real scripts put
# more than one binding per line or trail a comment. Retained as a second
# recognised form alongside the nested shape below, gated identically (same
# file_has_handler + ACTION_VOCAB + SDL_KEY_NAMES guards), so it cannot
# introduce a new false positive on its own; see
# test_scan_false_positive_words_rejected, test_scan_awkward_formatting,
# test_scan_commented_bindings_not_recorded, test_scan_residual_collision_*
# in scripts/tests/test_quest_survey.py for the behaviour it pins.
_TABLE_BINDING_RE = re.compile(r"(\w+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')")

# attack = { buttons={0}, keys={'s'} },
# action = { buttons={1}, keys={'space', 'return', 'kp return'} },
#
# The nested-table shape real quests actually use (Patched Tunics'
# data/lib/bindings.lua, fetched to
# deploy/quests/patched_tunics/data/lib/bindings.lua -- not in git). Each
# action's own table nests exactly one level deep (a `buttons={...}` list and
# a `keys={...}` list), so _NESTED_TABLE_BINDING_RE tolerates one level of
# brace nesting inside the action's `{...}` body while still stopping at that
# body's own closing brace. _NESTED_KEYS_FIELD_RE then pulls the FIRST key
# out of the matched body's `keys={...}` list -- multiple keys can name the
# same action (e.g. action's keys={'space', 'return', 'kp return'}) and only
# the first is used, matching the hand-authored controls.cfg.default section
# (`a = key space`). An action table with no `keys=` field (e.g. axis_commands'
# numeric-indexed direction tables) simply yields no match from
# _NESTED_KEYS_FIELD_RE and is skipped.
_NESTED_TABLE_BINDING_RE = re.compile(r"(\w+)\s*=\s*\{((?:[^{}]|\{[^{}]*\})*)\}")
_NESTED_KEYS_FIELD_RE = re.compile(r"keys\s*=\s*\{\s*(?:\"([^\"]*)\"|'([^']*)')")

# Solarus/SDL keyboard key names, as accepted by
# game:set_value("keyboard_<action>", "<name>") and InputEvent key literals.
# Derived from Solarus's keyboard key name table (src/lowlevel/InputEvent.cpp
# upstream); mechanical families are generated, the rest listed explicitly.
_KEY_LETTERS = frozenset(chr(c) for c in range(ord("a"), ord("z") + 1))
_KEY_DIGITS = frozenset(str(d) for d in range(10))
_KEY_FUNCTION = frozenset("f%d" % n for n in range(1, 13))
_KEY_KEYPAD_DIGITS = frozenset("kp %d" % d for d in range(10))
_KEY_KEYPAD_OTHER = frozenset(
    ["kp +", "kp -", "kp *", "kp /", "kp .", "kp return"]
)
_KEY_ARROWS = frozenset(["up", "down", "left", "right"])
_KEY_WHITESPACE_CONTROL = frozenset(
    ["space", "escape", "tab", "return", "backspace"]
)
_KEY_MODIFIERS = frozenset(
    [
        "left shift", "right shift",
        "left control", "right control",
        "left alt", "right alt",
    ]
)
_KEY_NAVIGATION = frozenset(
    ["insert", "delete", "home", "end", "page up", "page down"]
)
_KEY_MISC = frozenset(["pause"])
_KEY_PUNCTUATION = frozenset(
    [
        "comma", "period", "semicolon", "apostrophe", "slash", "backslash",
        "minus", "equals", "left bracket", "right bracket", "grave",
    ]
)

SDL_KEY_NAMES = frozenset().union(
    _KEY_LETTERS,
    _KEY_DIGITS,
    _KEY_FUNCTION,
    _KEY_KEYPAD_DIGITS,
    _KEY_KEYPAD_OTHER,
    _KEY_ARROWS,
    _KEY_WHITESPACE_CONTROL,
    _KEY_MODIFIERS,
    _KEY_NAVIGATION,
    _KEY_MISC,
    _KEY_PUNCTUATION,
)


def _lua_files(quest_dir):
    # Quest Lua source lives under data/ (data/main.lua, data/maps/*.lua, quest
    # scripts, libraries...). Scoping to data/ instead of the whole quest_dir
    # avoids walking sibling directories (e.g. a VCS checkout's own tooling)
    # that happen to sit next to data/ but are not part of the quest.
    return sorted((quest_dir / "data").rglob("*.lua"))


# Lua block comments: `--[[ ... ]]` and the long-bracket forms `--[==[ ... ]==]`
# (the number of `=` in the opener must match the closer -- the backreference
# enforces that). DOTALL so a block comment can span lines; non-greedy so it
# stops at the FIRST matching closer rather than swallowing everything up to
# the last `]]` in the file.
_BLOCK_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)

# Lua line comments: `--` to end of line. Applied AFTER block comments are
# stripped, so a `--` that was inside a block comment (already removed) can't
# be mistaken for the start of a line comment.
_LINE_COMMENT_RE = re.compile(r"--[^\n]*")


def _strip_lua_comments(text):
    """Remove Lua comments so they can't be scanned as bindings.

    Both regexes below run over raw text with no shape anchoring (see
    _TABLE_BINDING_RE), so a commented-out binding like `-- attack = "s"`
    would otherwise pass both closed-vocabulary checks in scan_input_surface
    and be recorded as if it were live; stripping comments before scanning is
    what prevents that.

    Known, accepted limitation: a `--` inside a Lua string literal (e.g. a
    dialog string containing "--") is also treated as a comment start, which
    truncates the rest of that line. The dangerous direction is a FALSE
    NEGATIVE, not a false positive: truncating a live line can only make a
    real construct disappear from the stripped text, never manufacture one
    that wasn't there. scan_shaders() consumes this same stripped text, so a
    `--` inside a same-line string literal ahead of a genuine `sol.shader`
    reference would silently truncate it away and downgrade a quest that
    actually needs shaders to RUNNABLE. No known quest in this corpus hits
    this; it is recorded here as the failure mode to check first if a
    NEEDS_SHADERS quest is ever suspected of being misreported as RUNNABLE.
    """
    text = _BLOCK_COMMENT_RE.sub("", text)
    text = _LINE_COMMENT_RE.sub("", text)
    return text


def scan_input_surface(quest_dir):
    """Report which keys a quest binds outside stock GameCommands defaults.

    Two binding shapes are recognised -- savegame keyboard values, and a
    quest-private binding table, itself matched in two forms (flat
    `action = "key"` and the nested `action = { keys={'key', ...} }` real
    quests use, see _NESTED_TABLE_BINDING_RE) -- and every side of every
    shape is validated against closed vocabularies: the action must be in
    ACTION_VOCAB and the value must be in SDL_KEY_NAMES. A match on an
    ACTION_VOCAB name whose value is NOT a recognised key name is never
    silently dropped -- it is reported in `unrecognized_keys` instead, so a
    rejected candidate is always visible rather than invented or discarded.

    Lua comments are stripped from each file before scanning (see
    _strip_lua_comments), so a commented-out binding is never recorded.

    Known, accepted residual: because both checks are closed-vocabulary
    membership tests rather than proof the table IS an input map, an
    unrelated table entry whose key happens to be an ACTION_VOCAB word AND
    whose value happens to be a genuine SDL_KEY_NAMES entry (e.g. `look =
    "up"` in an unrelated table, in a file with an on_key_pressed handler)
    is indistinguishable from a real binding and WILL be recorded. This is
    inherent to the approach, not a bug -- see
    test_scan_residual_collision_is_recorded_KNOWN_LIMITATION.

    Returns a dict with:
      private_bindings  -- {action: key} for validated bindings
      has_key_handler   -- True if any scanned file installs on_key_pressed
      private_layer     -- True if all four core actions are privately bound
      unrecognized_keys -- sorted list of [action, value] pairs where action
                           was in ACTION_VOCAB but value was not a recognised
                           SDL key name
    """
    bindings = {}
    has_key_handler = False
    unrecognized = set()

    for path in _lua_files(quest_dir):
        text = _strip_lua_comments(path.read_text(errors="replace"))
        file_has_handler = "on_key_pressed" in text
        has_key_handler = has_key_handler or file_has_handler

        # Shape 1: savegame keyboard values (works in any file).
        for action, key in _KEYBOARD_VALUE_RE.findall(text):
            if action in ACTION_VOCAB:
                if key in SDL_KEY_NAMES:
                    bindings.setdefault(action, key)
                else:
                    unrecognized.add((action, key))

        # Shape 2: a private binding table -- only trusted in a file that also
        # installs a key handler, so ordinary data tables cannot be mistaken
        # for an input map. `text` has already had comments stripped (see
        # _strip_lua_comments), and is not anchored to a whole line (real
        # scripts put more than one binding per line, or trail a comment);
        # remaining safety against an unrelated LIVE table comes from
        # validating the value against SDL_KEY_NAMES, not line shape.
        if file_has_handler:
            for m in _TABLE_BINDING_RE.finditer(text):
                action = m.group(1)
                key = m.group(2) if m.group(2) is not None else m.group(3)
                if action in ACTION_VOCAB:
                    if key in SDL_KEY_NAMES:
                        bindings.setdefault(action, key)
                    else:
                        unrecognized.add((action, key))

            # Shape 2b: the nested-table form (`action = { ... keys={...} ...
            # }`) real quests use -- see _NESTED_TABLE_BINDING_RE above. Same
            # file_has_handler gate, same ACTION_VOCAB / SDL_KEY_NAMES
            # validation, so an unrecognised action is ignored and a
            # recognised action with an unrecognised key is reported, not
            # dropped, exactly like every other shape here.
            for m in _NESTED_TABLE_BINDING_RE.finditer(text):
                action = m.group(1)
                if action not in ACTION_VOCAB:
                    continue
                km = _NESTED_KEYS_FIELD_RE.search(m.group(2))
                if not km:
                    continue
                key = km.group(1) if km.group(1) is not None else km.group(2)
                if key in SDL_KEY_NAMES:
                    bindings.setdefault(action, key)
                else:
                    unrecognized.add((action, key))

    private_layer = all(a in bindings for a in _CORE_ACTIONS)
    return {
        "private_bindings": bindings,
        "has_key_handler": has_key_handler,
        "private_layer": private_layer,
        "unrecognized_keys": sorted([list(pair) for pair in unrecognized]),
    }


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
    """Relative paths of Lua files referencing sol.shader (unavailable in this port).

    Lua comments are stripped before scanning, so a commented-out shader reference
    like `-- local shader = sol.shader.create(...)` does not mark the quest as
    requiring shaders. This follows the same principle as scan_input_surface:
    commented-out code is not live code.
    """
    hits = []
    for path in _lua_files(quest_dir):
        text = _strip_lua_comments(path.read_text(errors="replace"))
        if "sol.shader" in text:
            hits.append(str(path.relative_to(quest_dir)))
    return sorted(hits)


def interrogate(quest_dir):
    """Full static compatibility record for one quest directory.

    Returns a dict with:
      quest_id           -- quest_dir's own directory name
      solarus_version    -- declared quest.dat solarus_version, or None
      normal_size/min_size/max_size -- [w, h] lists from quest.dat
      size_classification -- see size_classification()
      quest_size_arg     -- "WxH" to pass -quest-size, or None
      private_bindings   -- {action: key}, from scan_input_surface()
      private_layer      -- True if all four of _CORE_ACTIONS (attack/action/
                             item_1/item_2 -- CORE_SLOTS minus pause) are
                             privately bound, i.e. GameCommands is fully replaced
      has_key_handler    -- True if any scanned Lua file installs on_key_pressed,
                             carried through from scan_input_surface() so a
                             quest that rebinds keys through a form the scanner
                             doesn't recognise is still visible as "has a
                             private input layer", not silently reported as if
                             it used none at all
      unrecognized_keys  -- [[action, value], ...] rejected candidates from
                             scan_input_surface(), carried through for the same
                             reason: a rejected binding must be visible in the
                             product, not just inside the scanning function
      shader_files       -- relative paths referencing sol.shader
      findings           -- list of finding codes that applied
      verdict            -- the single most severe finding, see VERDICT_SEVERITY
    """
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
        "has_key_handler": scan["has_key_handler"],
        "unrecognized_keys": scan["unrecognized_keys"],
        "shader_files": shaders,
        "findings": findings,
        "verdict": verdict,
    }


# Pad inputs, in the CONF_STR J1 order used by games/Solarus/controls.cfg.default.
PAD_INPUTS = ("right", "left", "down", "up", "a", "b", "x", "y", "l", "r", "select", "start")

# Stock GameCommands actions and the pad input each owns.
CORE_SLOTS = {"action": "a", "attack": "b", "item_1": "y", "item_2": "x", "pause": "start"}

DIRECTION_ROWS = {"right": "right", "left": "left", "down": "down", "up": "up"}

# Spare inputs, in assignment order. `start` is spare only when the quest binds
# no pause. This order reproduces the hand-authored Patched Tunics section exactly.
# The two hand-authored sections in games/Solarus/controls.cfg.default follow
# different orders (Patched Tunics: start, l, r; ROTH SE: select, l, r): this
# generator reproduces Patched Tunics's order exactly, and reproduces ROTH SE's
# action set but on different spare buttons. Known and accepted, documented in
# the design spec.
SPARE_SLOT_ORDER = ("start", "l", "r", "select")

# Which leftover named actions win a spare input when there are not enough.
SPARE_ACTION_PRIORITY = (
    "save", "escape", "run", "map", "inventory", "monsters", "look", "commands",
)

# generate_mapping() only ever consults CORE_SLOTS and SPARE_ACTION_PRIORITY;
# today that union is exactly ACTION_VOCAB, so nothing in ACTION_VOCAB is
# invisible to the generator. This assertion pins that invariant: an
# ACTION_VOCAB addition that forgets to also extend SPARE_ACTION_PRIORITY (or
# CORE_SLOTS) would otherwise silently vanish from both `rows` and `dropped`
# with no error anywhere.
assert set(ACTION_VOCAB) == set(CORE_SLOTS) | set(SPARE_ACTION_PRIORITY), (
    "ACTION_VOCAB must equal CORE_SLOTS | SPARE_ACTION_PRIORITY"
)


def generate_mapping(record):
    """Build the pad-input -> SDL-key table for one quest.

    Returns {'rows': {input: key}, 'dropped': [action, ...]}. `rows` states only
    what differs from [default]; `dropped` names actions with no spare input left,
    OR (see below) a CORE_SLOTS action privately bound by a quest that did not
    replace GameCommands outright.
    """
    bindings = record["private_bindings"]
    private_layer = record["private_layer"]
    rows = {}
    dropped = []

    if private_layer:
        # The quest replaced GameCommands outright, so [default]'s rows are all
        # wrong for it -- restate directions and every core action it binds.
        rows.update(DIRECTION_ROWS)
        for action, slot in CORE_SLOTS.items():
            if action in bindings:
                rows[slot] = bindings[action]
    else:
        # [default] still owns every core slot here, so this quest's OWN
        # binding for a CORE_SLOTS action is never wired to any pad input --
        # the private_layer branch above (which would map it) did not run,
        # and the leftover/spare pass below deliberately excludes CORE_SLOTS
        # actions too (they are not spare-action candidates). Left alone,
        # such an action would vanish from both `rows` and `dropped` with no
        # trace, contradicting the hard rule that a rejected/unreachable
        # binding is always reported, never silently discarded. Report it.
        for action in CORE_SLOTS:
            if action in bindings:
                dropped.append(action)

    occupied = set(rows)
    if not private_layer:
        # [default] already owns every core input for a stock-commands quest,
        # including `start` for pause -- so only l, r, select are ever spare.
        occupied |= set(CORE_SLOTS.values()) | set(DIRECTION_ROWS)
    spares = [s for s in SPARE_SLOT_ORDER if s not in occupied]

    leftover = [a for a in SPARE_ACTION_PRIORITY if a in bindings and a not in CORE_SLOTS]

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
