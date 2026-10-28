#!/usr/bin/env bash
#
# Fix the '@rpath/libdatachannel.0.dylib' reference that has no matching LC_RPATH.
# Gives libdatachannel an ABSOLUTE install name (like OpenSSL/librist) and repoints
# the already-built FFmpeg libs/binaries at it, then re-signs (ad-hoc) so the
# modified Mach-O files still run on Apple Silicon.
#
# Run from the project root (…/universal_ffmpeg). Safe to run before make_universal.py
# so the merged 'install_universal' inherits the fixed absolute reference.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LDC="$PROJECT_DIR/libdatachannel/lib"
OLD_REF="@rpath/libdatachannel.0.dylib"
NEW_REF="$LDC/libdatachannel.0.dylib"

echo "libdatachannel: $NEW_REF"

# 1) Absolute install name on the dylib itself.
install_name_tool -id "$NEW_REF" "$LDC/libdatachannel.0.dylib"
codesign --force --sign - "$LDC/libdatachannel.0.dylib" 2>/dev/null || true

# 2) Repoint every FFmpeg dylib + executable that references it.
for base in "$PROJECT_DIR/ffmpeg/install_arm64" \
            "$PROJECT_DIR/ffmpeg/install_x86_64" \
            "$PROJECT_DIR/ffmpeg/install_universal"; do
    [ -d "$base" ] || continue
    while IFS= read -r f; do
        if otool -L "$f" 2>/dev/null | grep -q "$OLD_REF"; then
            echo "fix: ${f#$PROJECT_DIR/}"
            install_name_tool -change "$OLD_REF" "$NEW_REF" "$f"
            codesign --force --sign - "$f" 2>/dev/null || true
        fi
    done < <(find "$base/lib" "$base/bin" -type f \( -name '*.dylib' -o -perm -111 \) 2>/dev/null)
done

echo "==== verify (arm64) ===="
otool -L "$PROJECT_DIR/ffmpeg/install_arm64/bin/ffmpeg" 2>/dev/null | grep -i datachannel || echo "(no datachannel ref found in arm64 ffmpeg)"
echo "Done."
