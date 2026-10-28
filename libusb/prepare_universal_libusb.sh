#!/usr/bin/env bash
# ============================================================================
#  prepare_universal_libusb.sh
#
#  Builds a universal (arm64 + x86_64) libusb-1.0 for the DekTec USB input
#  support (dektec_usb: DTU-245 ASI, DTU-351 HD-SDI). Homebrew ships libusb
#  single-arch only, so the same two-builds-plus-lipo method as
#  prepare_universal_libs.sh (SRT / OpenSSL) is used here.
#
#  Kept as a separate script on purpose: prepare_universal_libs.sh rebuilds
#  FFmpeg/SRT/OpenSSL from scratch and takes a long time. Fold this in as
#  "Step 4" once libusb is a permanent dependency of the app.
#
#  Usage:
#      ./prepare_universal_libusb.sh [DEST_DIR]
#
#  DEST_DIR defaults to ./3rdparty (relative to the project root).
#  Output:  DEST_DIR/libusb/{include/libusb-1.0/libusb.h, lib/libusb-1.0.a,
#           lib/libusb-1.0.0.dylib, lib/pkgconfig/libusb-1.0.pc}
#
#  Verifies the download with SHA256.  Aborts on any error (set -euo pipefail).
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Configuration — version and expected SHA256 of the OFFICIAL release tarball
# (the *.tar.bz2 asset, which includes the generated configure script; the
# GitHub-generated .tar.gz snapshot does not).
# SHA256 computed 2026-09-14 from
# https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
# ----------------------------------------------------------------------------
LIBUSB_VERSION="1.0.30"
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"

# Must match MAC_DEPLOYMENT_TARGET in prepare_universal_libs.sh and
# QMAKE_MACOSX_DEPLOYMENT_TARGET in MSPlayerV2.pro.
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

# The raw toolchain clang (xcrun -f clang) does not know the SDK location and
# fails every link with "ld: library 'System' not found". Resolve the SDK once
# and pass it both ways: SDKROOT for the driver, -isysroot on the flag lines.
CLANG="$(xcrun -f clang)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
if [[ -z "$SDKROOT" || ! -d "$SDKROOT" ]]; then
    echo "error: cannot resolve the macOS SDK path (xcrun --sdk macosx --show-sdk-path)" >&2
    echo "       check: xcode-select -p   and   xcodebuild -showsdks" >&2
    exit 1
fi

echo "Preparing universal libusb $LIBUSB_VERSION"
echo "  Destination: $DEST_DIR/libusb"
echo "  Target SDK:  $MAC_DEPLOYMENT_TARGET"
echo "  Toolchain:   $CLANG"
echo "  SDKROOT:     $SDKROOT"
echo ""

# Pre-flight: prove the compiler can produce a linked executable for each
# architecture BEFORE configure runs, so a toolchain problem is reported here
# with the real error, not as "C compiler cannot create executables".
preflight_arch() {
    local arch="$1"
    local tmp
    tmp="$(mktemp -d)"
    printf 'int main(void){return 0;}\n' > "$tmp/t.c"
    if "$CLANG" -arch "$arch" -isysroot "$SDKROOT" \
            -mmacosx-version-min="$MAC_DEPLOYMENT_TARGET" \
            "$tmp/t.c" -o "$tmp/t" 2> "$tmp/err.txt"; then
        echo "  preflight [$arch]: OK  ($(lipo -info "$tmp/t" | sed 's/.*: //'))"
    else
        echo "error: preflight compile+link for $arch failed:" >&2
        cat "$tmp/err.txt" >&2
        rm -rf "$tmp"
        exit 1
    fi
    rm -rf "$tmp"
}
preflight_arch arm64
preflight_arch x86_64
echo ""

# ============================================================================
# 1. Download + verify + extract
# ============================================================================
echo "Step 1/3: download"
LIBUSB_TAR="$DEST_DIR/libusb-$LIBUSB_VERSION.tar.bz2"
download_and_verify \
    "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2" \
    "$LIBUSB_TAR" "$LIBUSB_SHA256"

LIBUSB_SRC="$DEST_DIR/libusb-${LIBUSB_VERSION}"
if [[ ! -d "$LIBUSB_SRC" ]]; then
    tar -C "$DEST_DIR" -xjf "$LIBUSB_TAR"
fi

# ============================================================================
# 2. Build once per architecture (out-of-tree autotools build)
# ============================================================================
echo "Step 2/3: build arm64 and x86_64"

build_libusb_arch() {
    local arch="$1" host="$2"
    local build_dir="$LIBUSB_SRC/build_$arch"
    local prefix="$DEST_DIR/libusb_$arch"
    rm -rf "$build_dir" "$prefix"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null
    echo "  [$arch] configure --host=$host --prefix=$prefix"
    "$LIBUSB_SRC/configure" \
        --host="$host" \
        --prefix="$prefix" \
        --disable-dependency-tracking \
        --disable-examples-build \
        --disable-tests-build \
        CC="$CLANG" \
        CFLAGS="-arch $arch -isysroot $SDKROOT -mmacosx-version-min=$MAC_DEPLOYMENT_TARGET -O2" \
        LDFLAGS="-arch $arch -isysroot $SDKROOT -mmacosx-version-min=$MAC_DEPLOYMENT_TARGET"
    make -j"$NCPU"
    make install
    popd >/dev/null
    echo "  [$arch] built: $(lipo -info "$prefix/lib/libusb-1.0.0.dylib")"
}

build_libusb_arch arm64  aarch64-apple-darwin
build_libusb_arch x86_64 x86_64-apple-darwin

# ============================================================================
# 3. Merge with lipo
# ============================================================================
echo "Step 3/3: lipo"
rm -rf "$DEST_DIR/libusb"
mkdir -p "$DEST_DIR/libusb/include" "$DEST_DIR/libusb/lib/pkgconfig"
cp -R "$DEST_DIR/libusb_arm64/include/." "$DEST_DIR/libusb/include/"

for lib in "$DEST_DIR"/libusb_arm64/lib/*.dylib "$DEST_DIR"/libusb_arm64/lib/*.a; do
    [[ -f "$lib" ]] || continue
    base="$(basename "$lib")"
    if [[ -f "$DEST_DIR/libusb_x86_64/lib/$base" ]]; then
        lipo -create "$DEST_DIR/libusb_arm64/lib/$base" \
                     "$DEST_DIR/libusb_x86_64/lib/$base" \
                     -output "$DEST_DIR/libusb/lib/$base"
    else
        cp "$lib" "$DEST_DIR/libusb/lib/$base"
    fi
done

# pkg-config file pointing at the merged tree (the per-arch .pc points at
# libusb_arm64). Lets `PKG_CONFIG_PATH=.../libusb/lib/pkgconfig` work too.
sed "s#^prefix=.*#prefix=$DEST_DIR/libusb#" \
    "$DEST_DIR/libusb_arm64/lib/pkgconfig/libusb-1.0.pc" \
    > "$DEST_DIR/libusb/lib/pkgconfig/libusb-1.0.pc"

# ============================================================================
# Verification — every library must be x86_64 + arm64
# ============================================================================
echo ""
echo "Verification — every library should be x86_64 + arm64:"
fail=0
for lib in "$DEST_DIR"/libusb/lib/*.dylib "$DEST_DIR"/libusb/lib/*.a; do
    [[ -f "$lib" ]] || continue
    info="$(lipo -info "$lib" 2>/dev/null || true)"
    echo "  $(basename "$lib"): ${info#*: }"
    case "$info" in
        *x86_64*arm64*|*arm64*x86_64*) ;;
        *) fail=1 ;;
    esac
done
if [[ $fail -ne 0 ]]; then
    echo "error: at least one library is not universal" >&2
    exit 1
fi

echo ""
echo "Universal libusb ready in: $DEST_DIR/libusb"
echo ""
echo "Next steps:"
echo "  dektec_usb tools (static libusb, both CPU types):"
echo "    cd /path/to/dektec_usb && make clean && make LIBUSB_PREFIX=$DEST_DIR/libusb ARCHS=\"arm64 x86_64\""
echo "  NXT Multiview: add LIBUSB_PREFIX=$DEST_DIR/libusb to MSPlayerV2.pro (later step)"
