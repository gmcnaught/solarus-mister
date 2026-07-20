#!/bin/bash
# Host unit tests (no device). Run from repo root: bash tests/run_tests.sh
set -e
cd "$(dirname "$0")/.."
CC="${CC:-cc}"
echo "== blt_alloc (issue #14 DDR texture allocator) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_alloc_test.c patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_alloc_test
/tmp/blt_alloc_test

echo "== wire_pal8 (PAL8 v1: format/opcode + pal_id/base wire round-trip) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/wire_pal8_test.c \
    -o /tmp/wire_pal8_test
/tmp/wire_pal8_test

echo "== blt_emitter selftest (PAL8 v1: blt_emit_clut_upload + blt_blit_pal8) =="
$CC -Wall -Wextra -O2 -DBLT_EMITTER_SELFTEST -I patches/mister/blitter \
    patches/mister/blitter/blt_emitter.c patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_emitter_selftest
/tmp/blt_emitter_selftest

echo "== blt_stage (issue #19 SDRAM source staging) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_stage_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_stage_test
/tmp/blt_stage_test

echo "== blt_sdram_vram (issue #33 SDRAM-VRAM allocator + staging) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_sdram_vram_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_sdram_vram_test
/tmp/blt_sdram_vram_test

echo "== blt_sdram_regions (residency: perm vs intermediate split) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_sdram_regions_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_sdram_regions_test
/tmp/blt_sdram_regions_test

echo "== blt_stage_enabled (issue #19 T3: upload->stage sequence + disable) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_stage_enabled_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_stage_enabled_test
/tmp/blt_stage_enabled_test

echo "== blt_bgcache_stage (issue #19: stage bg-cache DDR3->SDRAM on snapshot) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter \
    tests/blt_bgcache_stage_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    -o /tmp/blt_bgcache_stage_test
/tmp/blt_bgcache_stage_test

echo "== sdram_selftest_logic (issue #34 round-trip harness pattern/compare) =="
$CC -Wall -Wextra -O2 -I patches/mister/sdram_selftest \
    tests/sdram_selftest_logic_test.c \
    -o /tmp/sdram_selftest_logic_test
/tmp/sdram_selftest_logic_test

echo "== idleskip (perf: idle-destructible update-skip predicate) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/idleskip_test.c \
    -o /tmp/idleskip_test
/tmp/idleskip_test

echo "== idlepark (perf: idle-destructible re-scan sweep-range) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/idlepark_test.c \
    -o /tmp/idlepark_test
/tmp/idlepark_test

echo "== staticpark (perf: static-entity update-skip predicate) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/staticpark_test.c \
    -o /tmp/staticpark_test
/tmp/staticpark_test

echo "== core_watch (productionization #3: core-change exit watcher) =="
sh tests/core_watch_test.sh

echo "== resolve_quest (productionization #2: OSD quest select) =="
sh tests/resolve_quest_test.sh

echo "== quest_manager (productionization #2: OSD quest lifecycle) =="
sh tests/quest_manager_test.sh

echo "== solarus_daemon (Frontier-independent core-load watcher) =="
sh tests/solarus_daemon_test.sh

echo "== quadtree_fat (perf: fat-AABB hysteresis in Quadtree::move) =="
# Ensure the engine checkout has the fat-AABB edit applied (idempotent no-op if
# already patched, e.g. after build_engine.sh). The test compiles the REAL
# Quadtree template, so the header must carry the change.
python3 scripts/patch_quadtree_fat.py \
    work/solarus/include/solarus/containers/Quadtree.h \
    work/solarus/include/solarus/containers/Quadtree.inl
CXX="${CXX:-g++}"
$CXX -std=c++17 -Wall \
    -I work/solarus/include \
    -I tests/qtree_test_include \
    -I work/solarus/libraries/win32/mingw32/include \
    -I work/SDL2-2.28.5/include \
    tests/quadtree_fat_test.cpp \
    work/solarus/src/core/Rectangle.cpp \
    work/solarus/src/core/Point.cpp \
    work/solarus/src/core/Size.cpp \
    -o /tmp/quadtree_fat_test
/tmp/quadtree_fat_test

echo "== loadbar (issue #72 progress-bar width math) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/loadbar_test.c \
    -o /tmp/loadbar_test
/tmp/loadbar_test

echo "== fps_overlay (OSD FPS overlay clamp + 7-segment digit table) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/fps_overlay_test.c \
    -o /tmp/fps_overlay_test
/tmp/fps_overlay_test

echo "== palette_atlas (paletted composition: host index recovery + CLUT extraction) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/palette_atlas_test.c $(sdl2-config --cflags --libs) \
    -o /tmp/palette_atlas_test
/tmp/palette_atlas_test

echo "== pal_restage (PAL8 v1, Task 2.4: cumulative multi-tileset perm/CLUT staging) =="
$CC -Wall -Wextra -O2 -I patches/mister/blitter -I patches/mister \
    tests/pal_restage_test.c \
    patches/mister/blitter/blt_emitter.c \
    patches/mister/blitter/blt_alloc.c \
    $(sdl2-config --cflags --libs) \
    -o /tmp/pal_restage_test
/tmp/pal_restage_test

echo "All host tests passed."
