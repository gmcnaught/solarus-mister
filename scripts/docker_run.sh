#!/usr/bin/env bash
#
# Shared wrapper around `docker run` for the armhf cross-build image.
#
# Usage (from repo root, or any subdir — cwd's repo root is mounted at /src):
#   scripts/docker_run.sh scripts/build_engine.sh
#   SOLARUS_PATCH_ONLY=1 scripts/docker_run.sh scripts/build_engine.sh   # see FORWARD_ENV
#   scripts/docker_run.sh bash -lc 'arm-linux-gnueabihf-gcc ...'
#
# What it does:
#   * Mounts the repo root at /src and sets -w /src (same as every hand-rolled
#     `docker run --rm -v "$(pwd):/src" -w /src <image> <cmd>` call site).
#   * Makes LINKED GIT WORKTREES work. A linked worktree's .git is a *file*
#     pointing at "gitdir: <main-repo>/.git/worktrees/<name>" (an absolute HOST
#     path). Bind-mounting only the worktree dir leaves that path unresolvable
#     inside the container, so ANY git call (even `git config --global`) dies
#     with "fatal: not a git repository". Fix: also bind-mount the shared
#     git-common-dir at the SAME absolute path, read-only. Plain (non-worktree)
#     checkouts add no extra mount.
#   * Forwards env vars named in $FORWARD_ENV (space-separated) into the
#     container, but ONLY those that are actually set in the calling shell.
#     Callers can still pass their own `-e VAR=val` before the command; those
#     are treated as part of the command line and passed through verbatim.
#
# Env knobs:
#   SOLARUS_DOCKER_IMAGE  override the image (default solarus-armhf-build:bullseye)
#   FORWARD_ENV           extra caller shell vars to forward with -e (see default)
#
set -euo pipefail

IMAGE="${SOLARUS_DOCKER_IMAGE:-solarus-armhf-build:bullseye}"

# The repo root (works from a linked worktree too). Fall back to cwd if git is
# unavailable for some reason.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Build the docker argument list.
DOCKER_ARGS=(run --rm -v "${REPO_ROOT}:/src" -w /src)

# Linked-worktree detection (run on the HOST, outside docker). The shared
# ".git" of a plain checkout is "<repo-root>/.git"; a linked worktree instead
# points at "<main-repo>/.git" which lives OUTSIDE this checkout. If the
# absolute git-common-dir is not "<repo-root>/.git", we are in a linked
# worktree and must expose that shared dir at its host path so the "gitdir:"
# pointer in <repo-root>/.git resolves inside the container.
if COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  # Normalise (strip any trailing slash) for a clean comparison / mount.
  COMMON_DIR="${COMMON_DIR%/}"
  if [ -n "$COMMON_DIR" ] && [ "$COMMON_DIR" != "${REPO_ROOT}/.git" ]; then
    DOCKER_ARGS+=(-v "${COMMON_DIR}:${COMMON_DIR}:ro")
  fi
fi

# Forward selected env vars from the calling shell (only if actually set).
# Callers commonly set these before invoking the wrapper; docker does NOT
# inherit the parent shell's environment, so forward them explicitly.
FORWARD_ENV="${FORWARD_ENV:-SOLARUS_PATCH_ONLY SOLARUS_REF SOLARUS_BUILD_DIR SOLARUS_USE_LUAJIT SOLARUS_GPROF SOLARUS_CULL_MARGIN}"
for _var in $FORWARD_ENV; do
  if [ -n "${!_var+x}" ]; then
    DOCKER_ARGS+=(-e "${_var}=${!_var}")
  fi
done

exec docker "${DOCKER_ARGS[@]}" "$IMAGE" "$@"
