#!/usr/bin/env bash
# ============================================================================
#  vpx.sh — build a UNIVERSAL STATIC libvpx (arm64 + x86_64) for the
#  universal FFmpeg build in this directory.
#
#  Output prefix:  <this dir>/libvpx/
#      include/vpx/*.h
#      lib/libvpx.a            <- fat archive (arm64 + x86_64)
#      lib/pkgconfig/vpx.pc    <- prefix rewritten to the universal prefix
#
#  FFmpeg finds libvpx through pkg-config ("vpx >= 1.4.0"), the same way it
#  already finds librist and opus. Because libvpx is STATIC here, its code is
#  linked INTO libavcodec.dylib: no new dylib to stage, bundle, or sign.
#
#  libvpx is BSD-3-Clause, so --enable-libvpx does NOT need --enable-gpl.
#
#  Prereq:  nasm (the x86_64 pass needs an assembler)
#      /opt/homebrew/bin/brew install nasm
#
#  Usage:  bash vpx.sh
#  Re-runnable: each run rebuilds both arches from a clean build dir.
# ============================================================================
set -euo pipefail

VPX_VERSION="1.17.0"
VPX_SHA256="1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"

# Must match the app's deployment target (prepare_universal_libs.sh: 13.0).
MACOSX_MIN="13.0"

# 0 = 8-bit only (fastest 8-bit encode; correct for WebRTC/WHIP and normal
#     streaming). 1 = also support VP9 10/12-bit, at a small 8-bit speed cost.
VP9_HIGHBITDEPTH=0

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_TGZ="$ROOT/libvpx-$VPX_VERSION.tar.gz"
SRC_DIR="$ROOT/libvpx-$VPX_VERSION"
PREFIX="$ROOT/libvpx"

echo "==== libvpx universal static build ===="
echo "  version:        $VPX_VERSION"
echo "  output prefix:  $PREFIX"
echo "  macOS min:      $MACOSX_MIN"
echo "  highbitdepth:   $VP9_HIGHBITDEPTH"

# --- prerequisite: assembler for the x86_64 pass ---------------------------
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    echo "ERROR: neither nasm nor yasm found. Run: /opt/homebrew/bin/brew install nasm" >&2
    exit 1
fi
echo "  assembler:      $(command -v nasm || command -v yasm)"

# --- libvpx 1.17.0 knows darwin20..darwin25. Clamp this Mac into that range.
DARWIN_MAJ="$(uname -r | cut -d. -f1)"
ORIG_DARWIN="$DARWIN_MAJ"
[ "$DARWIN_MAJ" -lt 20 ] && DARWIN_MAJ=20
[ "$DARWIN_MAJ" -gt 25 ] && DARWIN_MAJ=25
echo "  darwin target:  darwin$DARWIN_MAJ (host darwin$ORIG_DARWIN)"

# --- download + verify -----------------------------------------------------
if [ ! -f "$SRC_TGZ" ]; then
    echo "-> downloading libvpx $VPX_VERSION"
    curl -fL "https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX_VERSION.tar.gz" -o "$SRC_TGZ"
fi
echo "-> verifying SHA256"
echo "$VPX_SHA256  $SRC_TGZ" | shasum -a 256 -c -

# --- extract ---------------------------------------------------------------
if [ ! -d "$SRC_DIR" ]; then
    echo "-> extracting"
    tar -C "$ROOT" -xzf "$SRC_TGZ"
fi
[ -f "$SRC_DIR/configure" ] || { echo "ERROR: $SRC_DIR/configure not found" >&2; exit 1; }

# --- build one arch --------------------------------------------------------
build_arch() {
    local arch="$1"
    local prefix="$ROOT/libvpx_$arch"
    local bdir="$SRC_DIR/build_$arch"
    local hbd_flag="--disable-vp9-highbitdepth"
    [ "$VP9_HIGHBITDEPTH" = "1" ] && hbd_flag="--enable-vp9-highbitdepth"

    echo "---------- libvpx $arch ----------"
    rm -rf "$bdir" "$prefix"
    mkdir -p "$bdir"
    (
        cd "$bdir"
        ../configure \
            --target="${arch}-darwin${DARWIN_MAJ}-gcc" \
            --prefix="$prefix" \
            --disable-shared --enable-static --enable-pic \
            --enable-vp8 --enable-vp8-encoder --enable-vp8-decoder \
            --enable-vp9 --enable-vp9-encoder --enable-vp9-decoder \
            "$hbd_flag" \
            --enable-runtime-cpu-detect \
            --disable-examples --disable-tools --disable-docs --disable-unit-tests \
            --extra-cflags="-mmacosx-version-min=$MACOSX_MIN"
        make -j"$(sysctl -n hw.ncpu)"
        make install
    )
    echo "-> built: $prefix/lib/libvpx.a"
    lipo -info "$prefix/lib/libvpx.a"
}

build_arch arm64
build_arch x86_64

# --- merge into the universal prefix ---------------------------------------
echo "---------- lipo -> universal ----------"
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"

lipo -create "$ROOT/libvpx_arm64/lib/libvpx.a" \
             "$ROOT/libvpx_x86_64/lib/libvpx.a" \
             -output "$PREFIX/lib/libvpx.a"

cp -R "$ROOT/libvpx_arm64/include/." "$PREFIX/include/"

# Rewrite the pkg-config prefix so FFmpeg's configure points at the fat copy.
sed -e "s|^prefix=.*|prefix=$PREFIX|" \
    "$ROOT/libvpx_arm64/lib/pkgconfig/vpx.pc" > "$PREFIX/lib/pkgconfig/vpx.pc"

# --- verify ----------------------------------------------------------------
echo "==== verify (all four checks must pass) ===="
echo "1) fat archive — must list arm64 AND x86_64:"
lipo -info "$PREFIX/lib/libvpx.a"

echo "2) headers:"
ls "$PREFIX/include/vpx/vp8cx.h" "$PREFIX/include/vpx/vpx_encoder.h"

echo "3) pkg-config resolves from the universal prefix:"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --modversion vpx
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --cflags --libs vpx

echo "4) both encoder symbols present in both slices:"
for a in arm64 x86_64; do
    printf '   %-7s ' "$a:"
    nm -arch "$a" "$PREFIX/lib/libvpx.a" 2>/dev/null \
        | grep -c -E '_vpx_codec_vp8_cx|_vpx_codec_vp9_cx' \
        | xargs -I{} echo "{} vp8_cx/vp9_cx symbol lines"
done

echo "Done. Universal static libvpx: $PREFIX"
