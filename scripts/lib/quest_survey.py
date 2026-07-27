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
