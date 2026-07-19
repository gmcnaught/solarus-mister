#!/usr/bin/env bash
# Stage 2: OP_SPRITELIST reference-model equivalence.
# A sprite list must paint the SAME framebuffer as the equivalent N OP_BLITs.
set -euo pipefail
cd "$(dirname "$0")"
# Note: the brief's original build line also linked blitter/blt_emitter.c, but
# this test only exercises the reference model (blitter_ref.h/.c + blt_wire.h)
# -- it calls no blt_emitter.h function. Linking blt_emitter.c pulls in
# undefined blt_alloc_*/blt_free references (it needs blt_alloc.c too, which
# the brief's line omitted) for no benefit here, so it's dropped.
cc -std=c99 -Wall -Wextra -Werror -I blitter \
   blitter/blitter_ref.c \
   test_spritelist.c -o /tmp/test_spritelist
/tmp/test_spritelist
