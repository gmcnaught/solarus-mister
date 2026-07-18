#!/usr/bin/env bash
# Build + run the Stage 1 overlay emit test. Host-only, no engine link, no SDL --
# models Impl::emit_overlay_composite() against the REAL emitter and asserts the
# overlay composite is the last command, full-screen, PALPHA over ARGB4444, and
# absent when the root was not painted or the flag is off.
set -euo pipefail
cd "$(dirname "$0")"
CFLAGS="-O2 -Wall -Wextra"

echo "== overlay emit (last / full-screen / PALPHA, positive + negative) =="
# shellcheck disable=SC2086
cc $CFLAGS -I blitter test_overlay_emit.c blitter/blt_emitter.c blitter/blt_alloc.c \
   -o /tmp/test_overlay_emit
/tmp/test_overlay_emit
