#!/usr/bin/env bash
# ============================================================================
#  prepare_universal_libs.sh
#
#  Builds universal (arm64 + x86_64) versions of SRT and OpenSSL — the two
#  third-party libraries that Homebrew only ships single-arch — and copies
#  FFmpeg from a pre-built universal install.  Produces a 3rdparty/ tree
#  directly under the project so qmake can pick it up without env vars.
#
#  Usage:
#      ./prepare_universal_libs.sh [DEST_DIR]
#
#  DEST_DIR defaults to ./3rdparty (relative to the project root).
#
#  Verifies downloads with SHA256.  Aborts on any error (set -euo pipefail).
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Configuration — versions and expected SHA256 hashes.
# Update these together when you bump versions.
# ----------------------------------------------------------------------------
SRT_VERSION="1.5.4"
SRT_SHA256="d0a8b600fe1b4eaaf6277530e3cfc8f15b8ce4035f16af4a5eb5d4b123640cdd"

OPENSSL_VERSION="3.4.1"
OPENSSL_SHA256="002a2d6b30b58bf4bea46c43bdd96365aaf8daa6c428782aa4feee06da197df3"
# NOTE: Apple may update the SDK; treat hash mismatch as a hard fail and
# update the constant deliberately rather than silently overwriting it.

MAC_DEPLOYMENT_TARGET="13.0"

# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR="${1:-$SCRIPT_DIR/3rdparty}"
NCPU="$(sysctl -n hw.ncpu)"

mkdir -p "$DEST_DIR"

verify_sha256() {
    local file="$1" expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: SHA256 mismatch for $file" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

download_and_verify() {
    local url="$1" out="$2" expected_sha="$3"
    if [[ -f "$out" ]]; then
        if shasum -a 256 -c <(echo "$expected_sha  $out") >/dev/null 2>&1; then
            echo "  already downloaded: $out"
            return
        fi
        rm -f "$out"
    fi
    echo "  downloading $url"
    curl -fL "$url" -o "$out"
    verify_sha256 "$out" "$expected_sha"
}

echo "Preparing universal libraries"
echo "  Destination: $DEST_DIR"
echo "  Target SDK:  $MAC_DEPLOYMENT_TARGET"
echo ""

# ============================================================================
# 1. FFMPEG — caller must build/install this universally themselves (it's
#    a large multi-component build; we don't reinvent it here). Expect either:
#       $FFMPEG_PREFIX/{include,lib}, or
#       $HOME/Utils/universal_ffmpeg/ffmpeg/install_universal/{include,lib}
# ============================================================================
echo "Step 1/3: FFmpeg"

FFMPEG_SRC_PREFIX="${FFMPEG_PREFIX:-$HOME/Utils/universal_ffmpeg/ffmpeg/install_universal}"
if [[ -d "$FFMPEG_SRC_PREFIX/include" && -d "$FFMPEG_SRC_PREFIX/lib" ]]; then
    mkdir -p "$DEST_DIR/ffmpeg/include" "$DEST_DIR/ffmpeg/lib"
    cp -R "$FFMPEG_SRC_PREFIX/include/." "$DEST_DIR/ffmpeg/include/"
    cp -R "$FFMPEG_SRC_PREFIX/lib/."     "$DEST_DIR/ffmpeg/lib/"
    echo "  copied FFmpeg from $FFMPEG_SRC_PREFIX"
else
    cat >&2 <<EOF
error: FFmpeg universal install not found.

Expected layout:
  $FFMPEG_SRC_PREFIX/include/
  $FFMPEG_SRC_PREFIX/lib/

Build FFmpeg universally first, or set FFMPEG_PREFIX to point at an existing
universal install.  See APP_STORE_SUBMISSION.md for one approach using
ffmpeg-kit's universal build scripts.
EOF
    exit 1
fi

# ============================================================================
# 2. SRT (libsrt)
# ============================================================================
echo "Step 2/3: SRT $SRT_VERSION"

SRT_TAR="$DEST_DIR/srt-$SRT_VERSION.tar.gz"
download_and_verify \
    "https://github.com/Haivision/srt/archive/v${SRT_VERSION}.tar.gz" \
    "$SRT_TAR" "$SRT_SHA256"

SRT_SRC="$DEST_DIR/srt-${SRT_VERSION}"
if [[ ! -d "$SRT_SRC" ]]; then
    tar -C "$DEST_DIR" -xzf "$SRT_TAR"
fi

build_srt_arch() {
    local arch="$1"
    local build_dir="$SRT_SRC/build_$arch"
    local prefix="$DEST_DIR/srt_$arch"
    rm -rf "$build_dir" "$prefix"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MAC_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DENABLE_STATIC=ON \
        -DENABLE_SHARED=ON
    make -j"$NCPU"
    make install
    popd >/dev/null
}

build_srt_arch arm64
build_srt_arch x86_64

mkdir -p "$DEST_DIR/srt/include" "$DEST_DIR/srt/lib"
cp -R "$DEST_DIR/srt_arm64/include/." "$DEST_DIR/srt/include/"

for lib in "$DEST_DIR"/srt_arm64/lib/*.dylib "$DEST_DIR"/srt_arm64/lib/*.a; do
    [[ -f "$lib" ]] || continue
    base="$(basename "$lib")"
    if [[ -f "$DEST_DIR/srt_x86_64/lib/$base" ]]; then
        lipo -create "$DEST_DIR/srt_arm64/lib/$base" \
                     "$DEST_DIR/srt_x86_64/lib/$base" \
                     -output "$DEST_DIR/srt/lib/$base"
    else
        cp "$lib" "$DEST_DIR/srt/lib/$base"
    fi
done

# ============================================================================
# 3. OpenSSL
# ============================================================================
echo "Step 3/3: OpenSSL $OPENSSL_VERSION"

OPENSSL_TAR="$DEST_DIR/openssl-$OPENSSL_VERSION.tar.gz"
download_and_verify \
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    "$OPENSSL_TAR" "$OPENSSL_SHA256"

OPENSSL_SRC="$DEST_DIR/openssl-${OPENSSL_VERSION}"
if [[ ! -d "$OPENSSL_SRC" ]]; then
    tar -C "$DEST_DIR" -xzf "$OPENSSL_TAR"
fi

build_openssl_arch() {
    local arch="$1" cfg="$2"
    local prefix="$DEST_DIR/openssl_$arch"
    rm -rf "$prefix"
    pushd "$OPENSSL_SRC" >/dev/null
    make distclean 2>/dev/null || true
    ./Configure "$cfg" --prefix="$prefix" -mmacosx-version-min="$MAC_DEPLOYMENT_TARGET"
    make -j"$NCPU"
    make install_sw
    popd >/dev/null
}

build_openssl_arch arm64  darwin64-arm64-cc
build_openssl_arch x86_64 darwin64-x86_64-cc

mkdir -p "$DEST_DIR/openssl/include" "$DEST_DIR/openssl/lib"
cp -R "$DEST_DIR/openssl_arm64/include/." "$DEST_DIR/openssl/include/"

for lib in "$DEST_DIR"/openssl_arm64/lib/*.dylib "$DEST_DIR"/openssl_arm64/lib/*.a; do
    [[ -f "$lib" ]] || continue
    base="$(basename "$lib")"
    if [[ -f "$DEST_DIR/openssl_x86_64/lib/$base" ]]; then
        lipo -create "$DEST_DIR/openssl_arm64/lib/$base" \
                     "$DEST_DIR/openssl_x86_64/lib/$base" \
                     -output "$DEST_DIR/openssl/lib/$base"
    else
        cp "$lib" "$DEST_DIR/openssl/lib/$base"
    fi
done

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "Verification — every dylib should be x86_64 + arm64:"
for lib in "$DEST_DIR"/{ffmpeg,srt,openssl}/lib/*.dylib; do
    [[ -f "$lib" ]] || continue
    info="$(lipo -info "$lib" 2>/dev/null || true)"
    echo "  $(basename "$lib"): ${info#*: }"
done

echo ""
echo "Universal libraries ready in: $DEST_DIR"
echo ""
echo "Next step: build the app with this prefix:"
echo "  export FFMPEG_PREFIX=$DEST_DIR/ffmpeg"
echo "  export SRT_PREFIX=$DEST_DIR/srt"
echo "  export OPENSSL_PREFIX=$DEST_DIR/openssl"
echo "  qmake MSPlayerV2.pro && make -j$NCPU"
