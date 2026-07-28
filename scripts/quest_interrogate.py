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
