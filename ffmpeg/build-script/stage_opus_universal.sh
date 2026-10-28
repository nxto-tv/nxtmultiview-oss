#!/usr/bin/env bash
#
# Stage UNIVERSAL (arm64 + x86_64) libopus into the app's 3rdparty/opus/lib,
# so bundle_libs.sh can copy it explicitly (same pattern as
# stage_librist_universal.sh).
#
# libopus is a LEAF library (only libSystem below), so unlike librist there
# are no extra deps to stage.
#
# Why explicit staging: FFmpeg's dylibs reference
# /opt/homebrew/opt/opus/lib/libopus.0.dylib. bundle_libs.sh's absorb pass
# would copy that automatically, but if `brew upgrade opus` ever replaces the
# fat dylib with an arm64-only one, the absorbed copy silently loses the
# x86_64 slice and the Intel side of a shipped app crashes. A staged,
# verified-universal copy in 3rdparty/ removes that risk.
#
# Prereqs: opus installed on BOTH arches:
#   /opt/homebrew/bin/brew install opus
#   arch -x86_64 /usr/local/bin/brew install opus
#
# Usage:  bash stage_opus_universal.sh [DEST_LIB_DIR]
#   DEST_LIB_DIR default: /Users/parbat/Workspace/nxtplayerlight/3rdparty/opus/lib
set -euo pipefail

DEST="${1:-/Users/parbat/Workspace/nxtplayerlight/3rdparty/opus/lib}"
mkdir -p "$DEST"
echo "Staging universal libopus into: $DEST"

arm_prefix="$(/opt/homebrew/bin/brew --prefix opus 2>/dev/null)"
x64_prefix="$(arch -x86_64 /usr/local/bin/brew --prefix opus 2>/dev/null)"
arm_prefix="$(cd "$arm_prefix" && pwd -P)"; x64_prefix="$(cd "$x64_prefix" && pwd -P)"
echo "  arm64 : $arm_prefix"
echo "  x86_64: $x64_prefix"

combine() {  # combine <arm_file> <x64_file> <dest_file>
    local arm="$1" x64="$2" out="$3"
    local ta tx; ta="$(mktemp)"; tx="$(mktemp)"
    lipo "$arm" -thin arm64  -output "$ta" 2>/dev/null || cp "$arm" "$ta"
    lipo "$x64" -thin x86_64 -output "$tx" 2>/dev/null || cp "$x64" "$tx"
    lipo -create "$ta" "$tx" -output "$out"
    rm -f "$ta" "$tx"
}

shopt -s nullglob
# Pass 1: lipo the REAL versioned dylib(s) into DEST.
for lib in "$arm_prefix"/lib/libopus.*.dylib; do
    name="$(basename "$lib")"
    [ -L "$lib" ] && continue
    [ -e "$x64_prefix/lib/$name" ] || { echo "  skip (no x86_64 slice): $name"; continue; }
    echo "  lipo -> $name"
    combine "$lib" "$x64_prefix/lib/$name" "$DEST/$name"
done
# Pass 2: replicate the symlinks (libopus.dylib -> libopus.0.dylib).
for lib in "$arm_prefix"/lib/libopus*.dylib; do
    name="$(basename "$lib")"
    [ -L "$lib" ] || continue
    tgt="$(readlink "$lib")"
    ln -sf "$tgt" "$DEST/$name"
    echo "  symlink -> $name -> $tgt"
done

echo "==== verify: every staged dylib must list BOTH arm64 and x86_64 ===="
for f in "$DEST"/*.dylib; do
    [ -L "$f" ] && continue
    printf '%-24s ' "$(basename "$f"):"; lipo -info "$f" | sed 's/.*are: //'
done
echo "==== confirm no deeper non-system deps (should be only /usr/lib + @rpath/self) ===="
for f in "$DEST"/libopus.*.dylib; do
    [ -L "$f" ] && continue
    echo "-- $(basename "$f") --"; otool -L "$f" | tail -n +2 | grep -vE '/usr/lib|/System' || true
done
echo "Done."
