#!/usr/bin/env bash
#
# Make Homebrew's librist UNIVERSAL (arm64 + x86_64), idempotent & re-runnable.
#
# Prereqs: install librist for BOTH arches via Homebrew:
#   arm64 :  /opt/homebrew/bin/brew install librist
#   x86_64:  arch -x86_64 /usr/local/bin/brew install librist
set -euo pipefail

ARM_CELLAR="$(/opt/homebrew/bin/brew --prefix librist 2>/dev/null || echo /opt/homebrew/opt/librist)"
X64_CELLAR="$(arch -x86_64 /usr/local/bin/brew --prefix librist 2>/dev/null || echo /usr/local/opt/librist)"
ARM_PATH="$(cd "$ARM_CELLAR" && pwd -P)"
X64_PATH="$(cd "$X64_CELLAR" && pwd -P)"
UNIVERSAL_PATH="$ARM_PATH"   # ARM path is the destination (matches ssl.sh)

echo "ARM  librist: $ARM_PATH"
echo "x64  librist: $X64_PATH"
[ "$ARM_PATH" = "$X64_PATH" ] && { echo "ERROR: same path for both arches — is x86_64 librist installed?" >&2; exit 1; }

# Combine one lib by extracting pure per-arch slices first (safe even if a copy
# is already fat, so the script can be re-run).
combine() {
    local name="$1"
    local arm_src="$ARM_PATH/lib/$name" x64_src="$X64_PATH/lib/$name"
    [ -e "$arm_src" ] && [ -e "$x64_src" ] || { echo "skip (missing): $name"; return; }
    local ta tx; ta="$(mktemp)"; tx="$(mktemp)"
    lipo "$arm_src" -thin arm64  -output "$ta" 2>/dev/null || cp "$arm_src" "$ta"
    lipo "$x64_src" -thin x86_64 -output "$tx" 2>/dev/null || cp "$x64_src" "$tx"
    echo "lipo -> $name"
    lipo -create "$ta" "$tx" -output "$UNIVERSAL_PATH/lib/$name"
    rm -f "$ta" "$tx"
}

# Real versioned dylib(s) + any static archives. Skip the unversioned symlink.
shopt -s nullglob
for lib in "$ARM_PATH"/lib/librist.*.dylib "$ARM_PATH"/lib/librist*.a; do
    name="$(basename "$lib")"
    [ -L "$lib" ] && continue          # never lipo a symlink
    combine "$name"
done

# Recreate the unversioned dev symlink (librist.dylib -> librist.4.dylib).
cd "$UNIVERSAL_PATH/lib"
real="$(ls librist.*.dylib 2>/dev/null | grep -E 'librist\.[0-9]+\.dylib' | head -n1 || true)"
[ -n "$real" ] && ln -sf "$real" librist.dylib

echo "==== verify (should list arm64 AND x86_64) ===="
for f in "$UNIVERSAL_PATH"/lib/librist.*.dylib; do
    [ -L "$f" ] && continue
    echo "$f:"; lipo -info "$f"
done
echo "Done. pkgconfig: $UNIVERSAL_PATH/lib/pkgconfig/librist.pc"
