#!/bin/bash
# Shared helpers for the patch-series apply + bootstrap paths.
# shellcheck shell=bash

# Immutable upstream base (issue #98). `--branch v1.6` tracks a MOVING branch tip:
# on 2026-07-11 it advanced ("Fix compilation issues") under an active series, so a
# clone-by-branch silently shifts the golden/base the whole patch series is authored
# against. Pin every Solarus clone to this exact commit so the base cannot drift.
# To intentionally advance the base: rebase patches/series onto the new upstream,
# re-export, confirm test_export_roundtrip passes, then bump this SHA in one place.
SOLARUS_URL="${SOLARUS_URL:-https://gitlab.com/solarus-games/solarus.git}"
SOLARUS_SHA="${SOLARUS_SHA:-3caad8586ea0add5ce07cb512ed63f761fc46fa1}"  # v1.6 (1.6.5) pinned base

# --- Solarus 2.x TEST-OPTION pin (docs/solarus2.md) -------------------------
# The SECOND, opt-in engine line: latest upstream 2.x, built STOCK (no patch
# series — see docs/solarus2.md for why the 1.6 series cannot apply). Pinned the
# same way and for the same reason as SOLARUS_SHA above: `--branch v2.1.0` is a
# lightweight tag today but `master` moves, and a build whose base can shift is
# not a comparable measurement. Bump both vars together to advance the test line.
SOLARUS2_REF="${SOLARUS2_REF:-v2.1.0}"
SOLARUS2_SHA="${SOLARUS2_SHA:-09d45b3c40ab08388eee29e285903e8e3b90a4cc}"  # v2.1.0

# Clone the pinned upstream into $1. Gets the branch tip first (fast, shallow), then
# — if the tip has moved off the pin — fetches the exact pinned commit (GitLab serves
# any commit still reachable from a branch) and checks it out. If the pin is no longer
# reachable (force-push/rebase upstream), fail loudly rather than build on a surprise
# base. Leaves refs/remotes/origin/$ref pointing AT the pin so export/format-patch
# bases stay consistent. $1 = dest dir, $2 = ref (default v1.6), extra args -> clone.
pcs_clone_pinned() {   # $1 = dest, $2 = ref, [$3.. = extra git clone args]
  local dest="$1" ref="${2:-v1.6}"; shift 2 || true
  pcs_clone_pinned_at "$dest" "$ref" "$SOLARUS_SHA" "$@"
}

# Same as pcs_clone_pinned but with an EXPLICIT pin, so a second engine line
# (Solarus 2.x) can be cloned by the same audited logic instead of a hand-rolled
# `git clone --branch`. pcs_clone_pinned delegates here with $SOLARUS_SHA, so the
# 1.6 path's behaviour is unchanged.
pcs_clone_pinned_at() {   # $1 = dest, $2 = ref, $3 = sha, [$4.. = extra git clone args]
  local dest="$1" ref="$2" sha="$3"; shift 3
  git clone "$@" --branch "$ref" "$SOLARUS_URL" "$dest"
  local head; head=$(git -C "$dest" rev-parse HEAD)
  if [ "$head" != "$sha" ]; then
    echo "[pin] $ref tip $head != pinned $sha — fetching the pinned commit"
    if ! git -C "$dest" fetch --depth 1 origin "$sha" 2>/dev/null; then
      echo "FATAL: pinned commit $sha is no longer reachable on upstream $ref (tip=$head)." >&2
      echo "       Upstream history diverged from the pin. Re-base onto the new upstream" >&2
      echo "       and bump the pin in scripts/lib/patch_common.sh." >&2
      return 1
    fi
    git -C "$dest" checkout -q -B "$ref" "$sha"
  fi
  # Anchor the remote-tracking ref to the pin so origin/$ref-based exports are stable.
  git -C "$dest" update-ref "refs/remotes/origin/$ref" "$sha" 2>/dev/null || true
  local got; got=$(git -C "$dest" rev-parse HEAD)
  [ "$got" = "$sha" ] || { echo "FATAL: pin checkout failed ($got != $sha)" >&2; return 1; }
}

pcs_git_identity() {   # $1 = clone dir (absolute)
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "build@solarus-mister.local"
  git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "solarus-mister build"
  git config --global --add safe.directory "$1" 2>/dev/null || true
}

# Reset a persistent clone to the pinned pristine upstream base. `git am` advances
# the local branch, so a second apply must hard-reset back to the pinned commit —
# NOT origin/$ref, which can track a moved branch tip in a pre-existing clone. Also
# re-anchors origin/$ref to the pin so export/format-patch bases stay consistent
# (scripts/export_patches.sh exports against origin/$ref).
pcs_reset_clone() {    # $1 = clone dir, $2 = ref
  pcs_reset_clone_at "$1" "$2" "$SOLARUS_SHA"
}

# Explicit-pin variant, for the same reason as pcs_clone_pinned_at.
pcs_reset_clone_at() { # $1 = clone dir, $2 = ref, $3 = sha
  local sha="$3"
  git -C "$1" am --abort 2>/dev/null || true
  # Ensure the pinned commit is present locally (fetch if the clone predates the pin).
  git -C "$1" cat-file -e "$sha^{commit}" 2>/dev/null || \
    git -C "$1" fetch --depth 1 origin "$sha" 2>/dev/null || true
  git -C "$1" update-ref "refs/remotes/origin/$2" "$sha" 2>/dev/null || true
  git -C "$1" checkout -f -B "$2" "$sha"
  git -C "$1" reset --hard "$sha"
  git -C "$1" clean -fdx -e /build
}
