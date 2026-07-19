#!/usr/bin/env bash
# Stage 2: OP_SPRITELIST reference-model equivalence.
# A sprite list must paint the SAME framebuffer as the equivalent N OP_BLITs.
#
# [Task 3] Now ALSO exercises blt_sprite_list_init/blt_sprite_list (the host
# emitter), so blt_emitter.c is linked in -- which in turn needs blt_alloc.c
# for its free-list heap allocator (blt_emitter_init calls blt_alloc_init).
set -euo pipefail
cd "$(dirname "$0")"
cc -std=c99 -Wall -Wextra -Werror -I blitter \
   blitter/blitter_ref.c \
   blitter/blt_emitter.c \
   blitter/blt_alloc.c \
   test_spritelist.c -o /tmp/test_spritelist
/tmp/test_spritelist
