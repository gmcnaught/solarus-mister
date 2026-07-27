#!/usr/bin/env python3
"""Emit git pathspecs for a workflow's `on.push.paths` filter.

Used by the release-test provenance gate to ask: "did anything change between
the commit this artifact was built from and the release tag that would have
retriggered this workflow?"  Deriving the globs from the workflow itself keeps
the gate from drifting out of sync with the build triggers.

Translation to git pathspec syntax (git does the matching, so we do not have to
reimplement glob semantics):
    fpga/**            -> fpga/
    !fpga/sim/**       -> :(exclude)fpga/sim/
    scripts/build.sh   -> scripts/build.sh

Stdlib only: PyYAML is not installed on the runner or the dev host.
Any malformed / missing / empty `paths:` block exits non-zero. An empty list
must never be returned silently: it would make every artifact look permanently
up to date and the gate would pass on everything.
"""
import re
import sys


def _indent(s):
    return len(s) - len(s.lstrip(" "))


def parse(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    n = len(lines)

    i = 0
    while i < n and not re.match(r"^on:\s*$", lines[i]):
        i += 1
    if i == n:
        sys.exit(f"{path}: no top-level 'on:' block")

    push = None
    i += 1
    while i < n:
        line = lines[i]
        if line.strip() and _indent(line) == 0:
            break
        if re.match(r"^\s+push:\s*$", line):
            push = i
            break
        i += 1
    if push is None:
        sys.exit(f"{path}: no 'push:' under 'on:'")

    paths = None
    push_ind = _indent(lines[push])
    i = push + 1
    while i < n:
        line = lines[i]
        if line.strip() and _indent(line) <= push_ind:
            break
        if re.match(r"^\s+paths:\s*$", line):
            paths = i
            break
        i += 1
    if paths is None:
        sys.exit(f"{path}: no 'paths:' under 'on.push'")

    out = []
    paths_ind = _indent(lines[paths])
    i = paths + 1
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.strip().startswith("#"):
            i += 1
            continue
        if _indent(line) <= paths_ind:
            break
        m = re.match(r"^\s*-\s*(.+?)\s*$", line)
        if not m:
            sys.exit(f"{path}: unparseable line in 'paths:' list: {line!r}")
        val = re.sub(r"\s+#.*$", "", m.group(1)).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if val:
            out.append(val)
        i += 1

    if not out:
        sys.exit(f"{path}: 'paths:' list is empty")
    return out


def to_pathspec(glob):
    neg = glob.startswith("!")
    if neg:
        glob = glob[1:]
    if glob.endswith("/**"):
        glob = glob[:-3] + "/"
    elif glob.endswith("/*"):
        glob = glob[:-2] + "/"
    return ":(exclude)" + glob if neg else glob


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: wf_pathspec.py <workflow.yml>")
    for glob in parse(sys.argv[1]):
        print(to_pathspec(glob))


if __name__ == "__main__":
    main()
