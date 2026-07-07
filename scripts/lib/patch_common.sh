#!/bin/bash
# Shared helpers for the patch-series apply + bootstrap paths.
# shellcheck shell=bash

pcs_git_identity() {   # $1 = clone dir (absolute)
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "build@solarus-mister.local"
  git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "solarus-mister build"
  git config --global --add safe.directory "$1" 2>/dev/null || true
}

# Reset a persistent clone to the pristine pinned upstream tip. `git am` advances
# the local branch, so a second apply must hard-reset the local branch back to the
# stable remote-tracking ref (origin/$ref), not merely `reset --hard` (which would
# reset to the already-advanced local tip). See scripts/export_patches.sh, which
# exports against the same origin/$ref base.
pcs_reset_clone() {    # $1 = clone dir, $2 = ref
  git -C "$1" am --abort 2>/dev/null || true
  git -C "$1" checkout -f -B "$2" "origin/$2"
  git -C "$1" reset --hard "origin/$2"
  git -C "$1" clean -fdx -e /build
}
