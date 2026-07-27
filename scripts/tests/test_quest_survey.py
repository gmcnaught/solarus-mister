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
    check("via_and_smaller", qs.size_classification(qs.parse_quest_dat(quest_dat("via_and_smaller"))), "FITS_VIA_QUEST_SIZE")
    check("oversize", qs.size_classification(qs.parse_quest_dat(quest_dat("oversize"))), "TOO_LARGE")


def test_parse_quest_dat_defaults():
    # normal_quest_size defaults to FB_SIZE when absent
    dat_str = """quest{
  solarus_version = "1.6",
  write_dir = "testdefault",
  title = "Test default sizes",
}"""
    d = qs.parse_quest_dat(dat_str)
    check("default normal", d["normal_size"], qs.FB_SIZE)
    check("default min", d["min_size"], qs.FB_SIZE)
    check("default max", d["max_size"], qs.FB_SIZE)


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
    check("pl unrecognized", scan["unrecognized_keys"], [])


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
    check("kv unrecognized", scan["unrecognized_keys"], [])


def test_scan_stock_quest_has_no_bindings():
    scan = qs.scan_input_surface(FIXTURES / "stock_320")
    check("stock bindings", scan["private_bindings"], {})
    check("stock private_layer", scan["private_layer"], False)
    check("stock unrecognized", scan["unrecognized_keys"], [])


def test_scan_false_positive_words_rejected():
    # An on_key_pressed handler alongside an unrelated table using ordinary
    # English words ("attack", "action") that collide with ACTION_VOCAB but
    # whose values ("hit", "idle") are not SDL key names. Neither should be
    # recorded as a real binding, and both should be reported, not dropped.
    scan = qs.scan_input_surface(FIXTURES / "false_positive_words")
    check("fp has_key_handler", scan["has_key_handler"], True)
    check("fp attack not bound", "attack" in scan["private_bindings"], False)
    check("fp action not bound", "action" in scan["private_bindings"], False)
    check("fp bindings", scan["private_bindings"], {})
    check("fp unrecognized", scan["unrecognized_keys"], [
        ["action", "idle"],
        ["attack", "hit"],
    ])


def test_scan_awkward_formatting():
    # Two bindings on one line, a trailing comment, and a punctuation/keypad
    # key name -- all previously silently dropped by the line-anchored regex.
    scan = qs.scan_input_surface(FIXTURES / "awkward_formatting")
    check("awk has_key_handler", scan["has_key_handler"], True)
    check("awk bindings", scan["private_bindings"], {
        "attack": "s",
        "action": "space",
        "item_1": "a",
        "item_2": "kp +",
    })
    check("awk private_layer", scan["private_layer"], True)
    check("awk unrecognized", scan["unrecognized_keys"], [])


def main():
    test_parse_quest_dat()
    test_parse_size()
    test_engine_compatible()
    test_size_classification()
    test_parse_quest_dat_defaults()
    test_scan_private_layer()
    test_scan_keyboard_values()
    test_scan_stock_quest_has_no_bindings()
    test_scan_false_positive_words_rejected()
    test_scan_awkward_formatting()
    if FAILURES:
        print("FAIL (%d)" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
