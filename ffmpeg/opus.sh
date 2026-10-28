#!/usr/bin/env bash
#
# Make Homebrew's opus UNIVERSAL (arm64 + x86_64), idempotent & re-runnable.
# Same pattern as rist.sh.
#
# Prereqs: install opus for BOTH arches via Homebrew:
#   arm64 :  /opt/homebrew/bin/brew install opus
#   x86_64:  arch -x86_64 /usr/local/bin/brew install opus
set -euo pipefail

ARM_CELLAR="$(/opt/homebrew/bin/brew --prefix opus 2>/dev/null || echo /opt/homebrew/opt/opus)"
X64_CELLAR="$(arch -x86_64 /usr/local/bin/brew --prefix opus 2>/dev/null || echo /usr/local/opt/opus)"
ARM_PATH="$(cd "$ARM_CELLAR" && pwd -P)"
X64_PATH="$(cd "$X64_CELLAR" && pwd -P)"
UNIVERSAL_PATH="$ARM_PATH"   # ARM path is the destination (matches rist.sh/ssl.sh)

echo "ARM  opus: $ARM_PATH"
echo "x64  opus: $X64_PATH"
[ "$ARM_PATH" = "$X64_PATH" ] && { echo "ERROR: same path for both arches — is x86_64 opus installed?" >&2; exit 1; }

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
for lib in "$ARM_PATH"/lib/libopus.*.dylib "$ARM_PATH"/lib/libopus*.a; do
    name="$(basename "$lib")"
    [ -L "$lib" ] && continue          # never lipo a symlink
    combine "$name"
done

# Recreate the unversioned dev symlink (libopus.dylib -> libopus.0.dylib).
cd "$UNIVERSAL_PATH/lib"
real="$(ls libopus.*.dylib 2>/dev/null | grep -E 'libopus\.[0-9]+\.dylib' | head -n1 || true)"
[ -n "$real" ] && ln -sf "$real" libopus.dylib

echo "==== verify (should list arm64 AND x86_64) ===="
for f in "$UNIVERSAL_PATH"/lib/libopus.*.dylib "$UNIVERSAL_PATH"/lib/libopus*.a; do
    [ -L "$f" ] && continue
    echo "$f:"; lipo -info "$f"
done
echo "Done. pkgconfig: $UNIVERSAL_PATH/lib/pkgconfig/opus.pc"
