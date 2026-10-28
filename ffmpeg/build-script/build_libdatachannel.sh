#!/usr/bin/env bash
#
# Build a UNIVERSAL (arm64 + x86_64) libdatachannel for the WHIP/WHEP FFmpeg build.
#
# Prerequisites (macOS):
#   - Xcode command line tools (clang, clang++)
#   - cmake, git, pkg-config      (brew install cmake pkg-config)
#   - A UNIVERSAL OpenSSL already prepared by ssl.sh (openssl@3 3.4.1 lipo'd).
#
# Output: a universal shared libdatachannel installed at $LDC_PREFIX, sitting
# alongside the ffmpeg/ source dir inside this project.
set -euo pipefail

# ---- paths (dedicated dir under this project, alongside ffmpeg/) ----
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../universal_ffmpeg
LDC_SRC="$PROJECT_DIR/libdatachannel-src"
LDC_PREFIX="$PROJECT_DIR/libdatachannel"                          # install prefix

# Minimum macOS the built dylib must run on. MUST be <= the app's target
# (NXTMultiview = 13.0). Without this, CMake targets the BUILD Mac's OS
# (e.g. macOS 26), and libdatachannel's C++ code links libc++ symbols that
# don't exist on older systems -> "Symbol not found ... exception_ptr" crash
# at launch on the deployment machine. Override via env if your app changes.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# Universal OpenSSL prepared by ssl_universal.sh — auto-detect the prefix
# (no hardcoded version, so it survives Homebrew upgrades).
OPENSSL_ROOT="${OPENSSL_ROOT:-$(/opt/homebrew/bin/brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)}"
OPENSSL_ROOT="$(cd "$OPENSSL_ROOT" && pwd -P)"

echo "PROJECT_DIR = $PROJECT_DIR"
echo "LDC_PREFIX  = $LDC_PREFIX"
echo "OPENSSL_ROOT= $OPENSSL_ROOT"

# ---- 1. get source (recursive: pulls libjuice / usrsctp / libsrtp / plog) ----
if [ ! -d "$LDC_SRC" ]; then
  git clone --recursive https://github.com/paullouisageneau/libdatachannel.git "$LDC_SRC"
else
  echo "Reusing existing $LDC_SRC (run 'git -C $LDC_SRC submodule update --init --recursive' if needed)"
fi

# ---- 2. configure universal build ----
# CMAKE_OSX_ARCHITECTURES builds BOTH slices in one pass (no lipo needed).
# USE_GNUTLS=0 -> use OpenSSL (matches your universal OpenSSL from ssl.sh).
# USE_NICE=0   -> use bundled libjuice for ICE (no libnice dependency).
rm -rf "$LDC_SRC/build"
echo "DEPLOYMENT  = macOS $DEPLOYMENT_TARGET (must be <= the app's target)"
cmake -B "$LDC_SRC/build" -S "$LDC_SRC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DUSE_GNUTLS=0 \
  -DUSE_NICE=0 \
  -DCMAKE_INSTALL_PREFIX="$LDC_PREFIX" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT"

# ---- 3. build + install ----
cmake --build "$LDC_SRC/build" -j"$(sysctl -n hw.ncpu)"
cmake --install "$LDC_SRC/build"

# ---- 3b. give the dylib an ABSOLUTE install name (CMake defaults to @rpath,
#          which FFmpeg links without an LC_RPATH -> dyld can't find it).
#          Absolute matches how OpenSSL/librist are referenced. ----
if [ -f "$LDC_PREFIX/lib/libdatachannel.0.dylib" ]; then
    install_name_tool -id "$LDC_PREFIX/lib/libdatachannel.0.dylib" \
                          "$LDC_PREFIX/lib/libdatachannel.0.dylib"
    codesign --force --sign - "$LDC_PREFIX/lib/libdatachannel.0.dylib" 2>/dev/null || true
fi

# ---- 4. verify it is truly universal ----
echo "==== lipo -info (must list BOTH arm64 and x86_64) ===="
lipo -info "$LDC_PREFIX/lib/libdatachannel.dylib" || true
echo "==== header present? ===="
ls -l "$LDC_PREFIX/include/rtc/rtc.h"
echo "Done. Point FFmpeg configure at: -I$LDC_PREFIX/include -L$LDC_PREFIX/lib"
