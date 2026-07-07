#!/bin/bash
# Shared helpers for the patch-series apply + bootstrap paths.
# shellcheck shell=bash

pcs_git_identity() {   # $1 = clone dir (absolute)
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "build@solarus-mister.local"
  git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "solarus-mister build"
  git config --global --add safe.directory "$1" 2>/dev/null || true
}

# Reset a persistent clone to the pristine pinned upstream tip.
pcs_reset_clone() {    # $1 = clone dir, $2 = ref
  git -C "$1" am --abort 2>/dev/null || true
  git -C "$1" checkout -f "$2"
  git -C "$1" clean -fdx -e /build
  git -C "$1" reset --hard
}
