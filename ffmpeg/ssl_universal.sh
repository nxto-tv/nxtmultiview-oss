#!/usr/bin/env bash
#
# Make Homebrew's openssl@3 UNIVERSAL (arm64 + x86_64) WITHOUT hardcoding a version.
# Drop-in replacement for ssl.sh (which pinned OPENSSL_VER and broke on upgrade).
#
# Prereqs: openssl@3 installed for BOTH arches:
#   arm64 :  /opt/homebrew/bin/brew install openssl@3
#   x86_64:  arch -x86_64 /usr/local/bin/brew install openssl@3
set -euo pipefail

# Auto-detect per-arch prefixes (resolve the opt/ symlink to the real Cellar dir).
ARM_PREFIX="$(/opt/homebrew/bin/brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
X64_PREFIX="$(arch -x86_64 /usr/local/bin/brew --prefix openssl@3 2>/dev/null || echo /usr/local/opt/openssl@3)"
ARM_PATH="$(cd "$ARM_PREFIX" && pwd -P)"
X64_PATH="$(cd "$X64_PREFIX" && pwd -P)"
UNIVERSAL_PATH="$ARM_PATH"   # use ARM path as destination (matches original ssl.sh)

echo "ARM  openssl@3: $ARM_PATH"
echo "x64  openssl@3: $X64_PATH"

if [ "$ARM_PATH" = "$X64_PATH" ]; then
    echo "ERROR: both prefixes resolved to the same path — is the x86_64 Homebrew/openssl installed?" >&2
    exit 1
fi

# Combine one lib by extracting pure per-arch slices first, so the script is
# idempotent (safe to re-run even after a copy is already fat).
combine() {
    local name="$1"
    local arm_src="$ARM_PATH/lib/$name" x64_src="$X64_PATH/lib/$name"
    [ -e "$arm_src" ] && [ -e "$x64_src" ] || { echo "skip (missing x86_64 slice): $name"; return; }
    local ta tx; ta="$(mktemp)"; tx="$(mktemp)"
    lipo "$arm_src" -thin arm64  -output "$ta" 2>/dev/null || cp "$arm_src" "$ta"
    lipo "$x64_src" -thin x86_64 -output "$tx" 2>/dev/null || cp "$x64_src" "$tx"
    echo "lipo -> $name"
    lipo -create "$ta" "$tx" -output "$UNIVERSAL_PATH/lib/$name"
    rm -f "$ta" "$tx"
}

# lipo every libssl/libcrypto (.a and versioned .dylib) present in BOTH arches.
shopt -s nullglob
for lib in "$ARM_PATH"/lib/libssl*.a "$ARM_PATH"/lib/libcrypto*.a \
           "$ARM_PATH"/lib/libssl*.dylib "$ARM_PATH"/lib/libcrypto*.dylib; do
    name="$(basename "$lib")"
    [ -L "$lib" ] && continue   # skip unversioned symlinks; recreated below
    combine "$name"
done

# Recreate the unversioned symlinks (soname major stays 3 across 3.x).
cd "$UNIVERSAL_PATH/lib"
[ -e libssl.3.dylib ]    && ln -sf libssl.3.dylib    libssl.dylib
[ -e libcrypto.3.dylib ] && ln -sf libcrypto.3.dylib libcrypto.dylib

echo "==== verify (should list arm64 AND x86_64) ===="
for f in "$UNIVERSAL_PATH"/lib/libssl.3.dylib "$UNIVERSAL_PATH"/lib/libcrypto.3.dylib; do
    [ -e "$f" ] && { echo "$f:"; lipo -info "$f"; }
done
echo "Universal OpenSSL ready at: $UNIVERSAL_PATH"
echo "OPENSSL_ROOT for build_libdatachannel.sh: $UNIVERSAL_PATH"
