#!/usr/bin/env python3
# Host tests for the quest compatibility interrogator (no device, no network).
# Run: python3 scripts/tests/test_quest_survey.py

import json
import subprocess
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
    # Mirrors check_version_compatibility() in work/solarus/src/core/MainLoop.cpp:
    # major must match exactly; minor must be in [5, 6]; patch is ignored.
    check("1.5 ok", qs.engine_compatible("1.5"), True)  # the bug this pins: was WRONG_ENGINE
    check("1.5.3 ok (patch ignored)", qs.engine_compatible("1.5.3"), True)
    check("1.6 ok", qs.engine_compatible("1.6"), True)
    check("1.6.5 ok", qs.engine_compatible("1.6.5"), True)
    check("1.4 no (older than 1.5)", qs.engine_compatible("1.4"), False)
    check("1.7 no (too recent)", qs.engine_compatible("1.7"), False)
    check("2.0 no (major mismatch)", qs.engine_compatible("2.0"), False)
    check("missing no", qs.engine_compatible(None), False)
    check("junk no", qs.engine_compatible("banana"), False)
    check("0.0 no (zero major)", qs.engine_compatible("0.0"), False)


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


def test_scan_commented_bindings_not_recorded():
    # Every "binding" in this fixture is commented out -- shape 1 and shape 2,
    # a line comment, a `--[[ ]]` block comment, and a long-bracket `--[==[
    # ]==]` block comment. Each would satisfy both the ACTION_VOCAB and
    # SDL_KEY_NAMES checks if the comment text reached the regexes, so this
    # only stays green if comments are stripped before scanning.
    scan = qs.scan_input_surface(FIXTURES / "commented_bindings")
    check("commented has_key_handler", scan["has_key_handler"], True)
    check("commented bindings", scan["private_bindings"], {})
    check("commented unrecognized", scan["unrecognized_keys"], [])


def test_scan_residual_collision_is_recorded_KNOWN_LIMITATION():
    # KNOWN LIMITATION, not a target for the fix: an unrelated table's keys
    # collide with ACTION_VOCAB ("look", "map") and its values happen to be
    # genuine SDL_KEY_NAMES ("up", "m"), not obviously-wrong words. Two
    # independent closed-vocabulary checks cannot tell this apart from a real
    # private binding, so the scanner DOES record it. This test pins that
    # accepted behaviour -- it documents a limitation, it does not assert
    # this is desirable.
    scan = qs.scan_input_surface(FIXTURES / "residual_collision")
    check("residual has_key_handler", scan["has_key_handler"], True)
    check("residual bindings", scan["private_bindings"], {
        "look": "up",
        "map": "m",
    })
    check("residual unrecognized", scan["unrecognized_keys"], [])


def test_scan_shaders():
    check("shader found", qs.scan_shaders(FIXTURES / "shader_user"), ["data/main.lua"])
    check("no shader", qs.scan_shaders(FIXTURES / "stock_320"), [])
    check("commented shader ignored", qs.scan_shaders(FIXTURES / "shader_commented"), [])


def test_interrogate_verdicts():
    def verdict_of(name):
        return qs.interrogate(FIXTURES / name)["verdict"]

    check("stock verdict", verdict_of("stock_320"), "RUNNABLE")
    check("wrong engine verdict", verdict_of("wrong_engine"), "WRONG_ENGINE")
    check("shader verdict", verdict_of("shader_user"), "NEEDS_SHADERS")
    check("commented shader verdict", verdict_of("shader_commented"), "RUNNABLE")
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


def test_interrogate_exposes_key_handler_evidence():
    # interrogate() must carry has_key_handler/unrecognized_keys through from
    # scan_input_surface() -- otherwise a quest with a key handler and zero
    # recognised bindings ("has a private input layer the scanner couldn't
    # parse") is indistinguishable from one that never touches input at all.
    stock = qs.interrogate(FIXTURES / "stock_320")
    check("stock has_key_handler", stock["has_key_handler"], False)
    check("stock unrecognized_keys", stock["unrecognized_keys"], [])

    fp = qs.interrogate(FIXTURES / "false_positive_words")
    check("fp has_key_handler", fp["has_key_handler"], True)
    check("fp unrecognized_keys", fp["unrecognized_keys"], [
        ["action", "idle"],
        ["attack", "hit"],
    ])
    # A key handler with rejected candidates and zero recognised bindings must
    # not be reported as RUNNABLE with no trace of the input surface at all.
    check("fp private_bindings empty", fp["private_bindings"], {})
    check("fp verdict", fp["verdict"], "RUNNABLE")


def test_severity_beats_lesser_findings():
    # wrong_engine must not be reported as merely needing a keymap or a bigger FB.
    rec = qs.interrogate(FIXTURES / "wrong_engine")
    check("severity wins", rec["verdict"], "WRONG_ENGINE")
    check("findings retained", "WRONG_ENGINE" in rec["findings"], True)
    # A quest with multiple findings should report the most severe one.
    rec2 = qs.interrogate(FIXTURES / "shader_and_bindings")
    check("shader beats keymap", rec2["verdict"], "NEEDS_SHADERS")
    check("shader finding present", "NEEDS_SHADERS" in rec2["findings"], True)
    check("keymap finding present", "RUNNABLE_WITH_KEYMAP" in rec2["findings"], True)


def test_generate_mapping_partial_core_binding_is_not_silently_dropped():
    # A quest that privately rebinds SOME but not all four CORE_SLOTS actions
    # fails the private_layer test (so the core-slot pass that would map them
    # never runs), and the leftover/spare pass deliberately excludes
    # CORE_SLOTS actions too (they are not spare-action candidates). Before
    # the fix, both of those actions vanished from `rows` AND `dropped` with
    # no trace at all -- this pins that they must surface in `dropped`.
    record = {
        "private_bindings": {"attack": "s", "action": "space"},
        "private_layer": False,
    }
    mapping = qs.generate_mapping(record)
    check("partial-core rows", mapping["rows"], {})
    check("partial-core dropped", sorted(mapping["dropped"]), ["action", "attack"])


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


def test_mapping_is_internally_consistent():
    for name in ("private_layer", "keyboard_values"):
        rec = qs.interrogate(FIXTURES / name)
        mapping = qs.generate_mapping(rec)
        rows = mapping["rows"]
        dropped = mapping["dropped"]

        # No SDL key name bound to two different inputs
        check("%s: no key bound twice" % name, len(rows.values()), len(set(rows.values())))

        # Every assigned input is a legitimate pad input
        valid_inputs = all(inp in qs.PAD_INPUTS for inp in rows.keys())
        check("%s: all inputs valid" % name, valid_inputs, True)

        # No action both mapped and dropped. Bridge the namespaces through
        # private_bindings: a dropped action's key must never appear in rows.
        # Assumption: each quest binds a distinct key per action (holds for
        # both fixtures and both real quests this generator targets).
        bindings = rec["private_bindings"]
        dropped_keys = {bindings[a] for a in dropped}
        assigned_keys = set(rows.values())
        leaked_keys = dropped_keys & assigned_keys
        check("%s: no action both mapped and dropped" % name, leaked_keys, set())


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


def test_golden_patched_tunics_scan_to_section_end_to_end():
    # Closes the loop the hand-transcribed PT_BINDINGS golden above cannot:
    # this drives the actual scanner (scan_input_surface) over a fixture that
    # is a verbatim copy of Patched Tunics' real data/lib/bindings.lua (the
    # nested `action = { buttons={...}, keys={...} }` shape), then feeds the
    # scanner's own output through generate_mapping/render_section and
    # compares against the shipped [patched-tunics-b007e656] section. The
    # hand-transcribed golden above would stay green even if the scanner
    # itself found nothing (as it did before the nested-table fix) -- this
    # test would not.
    scan = qs.scan_input_surface(FIXTURES / "patched_tunics_real")
    check("PT e2e private_layer", scan["private_layer"], True)
    check("PT e2e unrecognized", scan["unrecognized_keys"], [])
    check("PT e2e bindings", scan["private_bindings"], PT_BINDINGS)

    mapping = qs.generate_mapping(_record(scan["private_bindings"], scan["private_layer"]))
    want = qs.parse_controls_section(CONTROLS_CFG.read_text(), "patched-tunics-b007e656")
    check("PT e2e rows", mapping["rows"], want)
    check("PT e2e dropped", mapping["dropped"], [])


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


def main():
    test_cli_emits_json()
    test_cli_rejects_non_quest_dir()
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
    test_scan_commented_bindings_not_recorded()
    test_scan_residual_collision_is_recorded_KNOWN_LIMITATION()
    test_scan_shaders()
    test_interrogate_verdicts()
    test_interrogate_record_shape()
    test_interrogate_exposes_key_handler_evidence()
    test_severity_beats_lesser_findings()
    test_generate_mapping_partial_core_binding_is_not_silently_dropped()
    test_generate_stock_quest_needs_no_section()
    test_generate_private_layer()
    test_generate_keyboard_values_oversubscribed()
    test_render_section_reports_dropped()
    test_mapping_is_internally_consistent()
    test_golden_patched_tunics_exact()
    test_golden_patched_tunics_scan_to_section_end_to_end()
    test_golden_roth_action_set()
    test_parse_controls_section_ignores_none_rows()
    if FAILURES:
        print("FAIL (%d)" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
