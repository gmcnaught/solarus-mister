#!/bin/bash
# Copy the whole-file MiSTer additions (new TUs/headers) into the engine tree.
# These are file ADDITIONS, kept verbatim from the original build_engine.sh patch
# phase; upstream-file EDITS live in patches/series/*.patch. The two together
# reproduce the full patched tree. Kept separate so the series stays a clean diff
# against pristine upstream.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:?usage: apply_mister_files.sh <src_dir>}"

# --- renderer / video (blitter + software present-hook + pixel convert) ---
MDST="$SRC/src/graphics/sdlrenderer"
cp patches/mister/native_video_writer.c   "$MDST/"
cp patches/mister/native_video_writer.h   "$MDST/"
cp patches/mister/mister_native_video.cpp "$MDST/"
cp patches/mister/mister_native_video.h   "$MDST/"
cp patches/mister/mister_blitter_renderer.cpp "$MDST/"
cp patches/mister/loadbar.h                 "$MDST/"
cp patches/mister/fps_overlay.h             "$MDST/"
cp patches/mister/mister_blitter_renderer.h   "$MDST/"
cp patches/mister/mister_pixconv.cpp "$MDST/"
cp patches/mister/mister_pixconv.h   "$MDST/"
cp patches/mister/palette_atlas.h    "$MDST/"
cp patches/mister/mister_blitter_renderer.h   "$SRC/include/solarus/graphics/sdlrenderer/"
mkdir -p "$MDST/blitter"
cp patches/mister/blitter/*.h patches/mister/blitter/*.c "$MDST/blitter/"

# --- lua profiling header (used by renderer + lua) ---
cp patches/mister/mister_lua_prof.h "$MDST/"
cp patches/mister/mister_lua_prof.h "$SRC/src/lua/"

# --- audio (DDR audio ring writer) ---
MADST="$SRC/src/audio"
cp patches/mister/native_audio_writer.c   "$MADST/"
cp patches/mister/native_audio_writer.h   "$MADST/"
cp patches/mister/mister_native_audio.cpp "$MADST/"
cp patches/mister/mister_native_audio.h   "$MADST/"

# --- idle-destructible park/skip headers ---
cp patches/mister/mister_idlepark.h "$SRC/src/entities/"
cp patches/mister/mister_idleskip.h "$SRC/src/entities/"

# --- static-entity park header ---
cp patches/mister/mister_staticpark.h "$SRC/src/entities/"
