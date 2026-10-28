#!/usr/bin/env bash
#
# Stage UNIVERSAL (arm64 + x86_64) librist AND its leaf deps into the app's
# 3rdparty/librist/lib, so bundle_libs.sh can copy them explicitly.
#
# librist drags in: libmbedcrypto (mbedtls@3), libcjson, liblz4 — each a leaf
# (only libSystem below). Homebrew ships them per-arch, so we lipo the arm64
# (/opt/homebrew) + x86_64 (/usr/local) slices into one universal dylib each.
#
# Prereqs: all four formulae installed on BOTH arches:
#   /opt/homebrew/bin/brew install librist mbedtls@3 cjson lz4
#   arch -x86_64 /usr/local/bin/brew install librist mbedtls@3 cjson lz4
#
# Usage:  bash stage_librist_universal.sh [DEST_LIB_DIR]
#   DEST_LIB_DIR default: /Users/parbat/Workspace/nxtplayerlight/3rdparty/librist/lib
set -euo pipefail

DEST="${1:-/Users/parbat/Workspace/nxtplayerlight/3rdparty/librist/lib}"
mkdir -p "$DEST"
echo "Staging universal librist + deps into: $DEST"

# formula:glob pairs (glob matches the REAL versioned dylib, e.g. librist.4.dylib)
PAIRS=(
  "librist:librist.*.dylib"
  "mbedtls@3:libmbedcrypto.*.dylib"
  "cjson:libcjson.*.dylib"
  "lz4:liblz4.*.dylib"
)

combine() {  # combine <arm_file> <x64_file> <dest_file>
    local arm="$1" x64="$2" out="$3"
    local ta tx; ta="$(mktemp)"; tx="$(mktemp)"
    lipo "$arm" -thin arm64  -output "$ta" 2>/dev/null || cp "$arm" "$ta"
    lipo "$x64" -thin x86_64 -output "$tx" 2>/dev/null || cp "$x64" "$tx"
    lipo -create "$ta" "$tx" -output "$out"
    rm -f "$ta" "$tx"
}

shopt -s nullglob
for pair in "${PAIRS[@]}"; do
    formula="${pair%%:*}"; glob="${pair#*:}"
    arm_prefix="$(/opt/homebrew/bin/brew --prefix "$formula" 2>/dev/null)"
    x64_prefix="$(arch -x86_64 /usr/local/bin/brew --prefix "$formula" 2>/dev/null)"
    arm_prefix="$(cd "$arm_prefix" && pwd -P)"; x64_prefix="$(cd "$x64_prefix" && pwd -P)"
    echo "--- $formula ---"
    echo "  arm64 : $arm_prefix"
    echo "  x86_64: $x64_prefix"
    # Pass 1: lipo the REAL versioned dylibs into DEST.
    for lib in "$arm_prefix"/lib/$glob; do
        name="$(basename "$lib")"
        [ -L "$lib" ] && continue
        [ -e "$x64_prefix/lib/$name" ] || { echo "  skip (no x86_64 slice): $name"; continue; }
        echo "  lipo -> $name"
        combine "$lib" "$x64_prefix/lib/$name" "$DEST/$name"
    done
    # Pass 2: replicate EVERY symlink Homebrew provides (soname links like
    # libmbedcrypto.16.dylib -> libmbedcrypto.3.6.6.dylib, and the unversioned
    # libmbedcrypto.dylib). These soname names are exactly what librist links
    # against, so they must exist in DEST or bundle_libs.sh can't repoint them.
    for lib in "$arm_prefix"/lib/$glob; do
        name="$(basename "$lib")"
        [ -L "$lib" ] || continue
        tgt="$(readlink "$lib")"          # relative target, e.g. libmbedcrypto.3.6.6.dylib
        ln -sf "$tgt" "$DEST/$name"
        echo "  symlink -> $name -> $tgt"
    done
done

echo "==== verify: every staged dylib must list BOTH arm64 and x86_64 ===="
for f in "$DEST"/*.dylib; do
    [ -L "$f" ] && continue
    printf '%-28s ' "$(basename "$f"):"; lipo -info "$f" | sed 's/.*are: //'
done
echo "==== confirm no deeper non-system deps (should be only /usr/lib + @rpath/self) ===="
for f in "$DEST"/librist.*.dylib "$DEST"/libmbedcrypto.*.dylib "$DEST"/libcjson.*.dylib "$DEST"/liblz4.*.dylib; do
    [ -L "$f" ] && continue
    echo "-- $(basename "$f") --"; otool -L "$f" | tail -n +2 | grep -vE '/usr/lib|/System' || true
done
echo "Done."
