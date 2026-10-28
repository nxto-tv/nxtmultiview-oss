#!/usr/bin/env bash
#
# build_librist_universal.sh — [LIBRIST-NOMBED] 2026-10-27
#
# Builds librist 0.2.18 FROM SOURCE, for arm64 AND x86_64, WITHOUT Mbed TLS,
# and stages the universal librist.4.dylib into 3rdparty/librist/lib.
#
# WHY: Mbed TLS (Apache-2.0) is the only library FFmpeg's LICENSE.md calls
# incompatible with the LGPL v2.1. Our FFmpeg is LGPL v2.1-or-later, and only
# librist pulls Mbed TLS in. See attribution/LICENSE_COMPATIBILITY.md sect. 3.
#
# WHAT CHANGES IN librist:
#   * use_mbedtls=false and use_gnutls/use_nettle=false -> librist compiles
#     its own built-in AES / SHA-256 / PBKDF2 (contrib/). RIST encryption with
#     a shared secret (?secret=...&aes-type=128|256) keeps working.
#   * SRP / EAP username+password login is NOT built (Parbat's decision,
#     2026-10-27: the app never sets it).
#   * cJSON and LZ4 stay EXTERNAL (Homebrew, per arch) exactly as before, so
#     3rdparty/librist/lib/libcjson.* and liblz4.* are unchanged.
#
# This REPLACES stage_librist_universal.sh (that script lipo'd Homebrew's
# BOTTLE, which links Mbed TLS; current Homebrew bottles link GnuTLS/nettle/
# gmp instead, and gmp is LGPL v3 — do not go back to the bottle).
#
# Prereqs (one time):
#   /opt/homebrew/bin/brew install meson ninja pkgconf cjson lz4
#   arch -x86_64 /usr/local/bin/brew install cjson lz4
#
# Usage:
#   bash tools/build_librist_universal.sh
# Optional env:
#   LIBRIST_VERSION   default 0.2.18
#   LIBRIST_TARBALL   use this local source tarball instead of downloading
#   EXPECTED_SHA256   fail if the tarball's SHA-256 differs
#   WORK_DIR          default $HOME/Utils/librist_build
#   DEST              default <repo>/3rdparty/librist/lib
#
# Every line this script prints starts with [LIBRIST-BUILD] so the run can be
# pasted back for diagnosis.
set -Eeuo pipefail   # -E: the ERR trap also fires inside functions

log()  { printf '[LIBRIST-BUILD] %s\n' "$*"; }
die()  { printf '[LIBRIST-BUILD] ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2154  # rc is set inside the trap string
trap 'rc=$?; printf "[LIBRIST-BUILD] FAILED (exit %s) near line %s - see the lines above\n" "$rc" "$LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VER="${LIBRIST_VERSION:-0.2.18}"
WORK_DIR="${WORK_DIR:-$HOME/Utils/librist_build}"
DEST="${DEST:-$REPO_DIR/3rdparty/librist/lib}"
URL="https://code.videolan.org/rist/librist/-/archive/v${VER}/librist-v${VER}.tar.gz"
MIN_MACOS="13.0"     # = LSMinimumSystemVersion / QMAKE_MACOSX_DEPLOYMENT_TARGET
STAMP="$(date +%Y%m%d-%H%M%S)"

log "librist version : $VER"
log "work dir        : $WORK_DIR"
log "stage into      : $DEST"
log "min macOS       : $MIN_MACOS"

# ---------------------------------------------------------------------------
# 0. Tools
# ---------------------------------------------------------------------------
for t in meson ninja pkg-config lipo otool nm install_name_tool shasum; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' not found (brew install meson ninja pkgconf)"
done
log "meson $(meson --version), ninja $(ninja --version)"
[[ -x /opt/homebrew/bin/brew ]]  || die "arm64 Homebrew not found at /opt/homebrew"
[[ -x /usr/local/bin/brew ]]     || die "x86_64 Homebrew not found at /usr/local (needed for x86_64 cjson/lz4)"

# ---------------------------------------------------------------------------
# 1. Source
# ---------------------------------------------------------------------------
mkdir -p "$WORK_DIR"
TARBALL="${LIBRIST_TARBALL:-$WORK_DIR/librist-v${VER}.tar.gz}"
if [[ ! -f "$TARBALL" ]]; then
    log "downloading $URL"
    curl -fL --retry 3 -o "$TARBALL.part" "$URL"
    mv "$TARBALL.part" "$TARBALL"
fi
SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
log "tarball sha256  : $SHA  ($TARBALL)"
# 0.2.18: the tarball downloaded and built on 2026-10-27 (first run).
if [[ -z "${EXPECTED_SHA256:-}" && "$VER" == "0.2.18" ]]; then
    EXPECTED_SHA256="9a2d16dcdb9fb067b7ba4259a3976ff6f8df9a62dbec7f32f19a0b60ec0c114a"
fi
if [[ -n "${EXPECTED_SHA256:-}" && "$SHA" != "$EXPECTED_SHA256" ]]; then
    die "SHA-256 mismatch: expected $EXPECTED_SHA256"
fi

SRC="$WORK_DIR/src-$VER"
rm -rf "$SRC"; mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
[[ -f "$SRC/meson.build" && -f "$SRC/meson_options.txt" ]] || die "no meson.build / meson_options.txt in the tarball"
PROJ_VER="$(awk -F"'" '/^project\(/{f=1} f&&/version/{print $2; exit}' "$SRC/meson.build" || true)"
log "meson.build project version line: ${PROJ_VER:-<not parsed>}"

# ---------------------------------------------------------------------------
# 1b. Source fix for a build WITHOUT SRP (found 2026-10-27 on the Mac).
#     librist 0.2.18 src/rist-common.c:2733 calls eap_is_authenticated()
#     outside "#if HAVE_SRP_SUPPORT", so a no-Mbed-TLS build fails:
#       error: call to undeclared function 'eap_is_authenticated'
#     The fix guards that one check. Without SRP, peer->eap_ctx is only ever
#     set in proto/eap.c, which is not compiled, so eap_ctx is always NULL and
#     the original line already returned false: the run-time result is the same.
# ---------------------------------------------------------------------------
NOSRP_PATCH="$WORK_DIR/librist-${VER}-nosrp.patch"
cat > "$NOSRP_PATCH" <<'PATCH_EOF'
--- src/rist-common.c
+++ src/rist-common.c
@@ -2730,8 +2730,14 @@
 	    new_peer->receiver_mode || new_peer->receiver_name[0] == '\0')
 		return false;
 
+#if HAVE_SRP_SUPPORT
 	if (!new_peer->eap_ctx || !eap_is_authenticated(new_peer->eap_ctx))
 		return false;
+#else
+	/* [LIBRIST-NOMBED] built without SRP: eap_ctx is never created, so the
+	 * SRP-only re-association can never apply (same result as eap_ctx == NULL). */
+	return false;
+#endif
 
 	uint64_t ka = new_peer->rtcp_keepalive_interval
 	              ? new_peer->rtcp_keepalive_interval
PATCH_EOF
n_unguarded="$(grep -c 'if (!new_peer->eap_ctx || !eap_is_authenticated(new_peer->eap_ctx))' "$SRC/src/rist-common.c" || true)"
if [[ "$n_unguarded" -eq 0 ]]; then
    log "no-SRP source fix: not needed (the call is not in this version)"
elif (cd "$SRC" && patch -p0 -N -t --dry-run < "$NOSRP_PATCH" >/dev/null 2>&1); then
    (cd "$SRC" && patch -p0 -N -t < "$NOSRP_PATCH") | sed 's/^/[LIBRIST-BUILD]   /'
    log "no-SRP source fix: APPLIED to src/rist-common.c ($NOSRP_PATCH)"
elif (cd "$SRC" && patch -p0 -R -t --dry-run < "$NOSRP_PATCH" >/dev/null 2>&1); then
    log "no-SRP source fix: already applied"
else
    die "no-SRP source fix does not apply to this librist version - stop, do not guess"
fi

# ---------------------------------------------------------------------------
# 2. Crypto options — set only the options this version really has.
# ---------------------------------------------------------------------------
OPTS_FILE="$SRC/meson_options.txt"
has_opt() { [[ "$(grep -cE "option\(['\"]$1['\"]" "$OPTS_FILE" || true)" -gt 0 ]]; }

log "crypto/dependency options found in meson_options.txt:"
grep -nE "option\(['\"](use_mbedtls|builtin_mbedtls|use_gnutls|use_nettle|builtin_cjson|fallback_builtin|built_tools|test)['\"]" "$OPTS_FILE" \
    | sed 's/^/[LIBRIST-BUILD]   /' || true

has_opt use_mbedtls || die "this librist has no 'use_mbedtls' option - stop, do not guess"
MESON_OPTS=( -Duse_mbedtls=false )
has_opt builtin_mbedtls && MESON_OPTS+=( -Dbuiltin_mbedtls=false )
has_opt use_gnutls      && MESON_OPTS+=( -Duse_gnutls=false )
has_opt use_nettle      && MESON_OPTS+=( -Duse_nettle=false )
has_opt builtin_cjson   && MESON_OPTS+=( -Dbuiltin_cjson=false )     # keep cJSON external, as before
has_opt fallback_builtin && MESON_OPTS+=( -Dfallback_builtin=false ) # fail if cjson/lz4 are missing, never embed silently
has_opt built_tools     && MESON_OPTS+=( -Dbuilt_tools=false )
has_opt test            && MESON_OPTS+=( -Dtest=false )
log "meson options: ${MESON_OPTS[*]}"

# ---------------------------------------------------------------------------
# 3. Build one slice
# ---------------------------------------------------------------------------
build_arch() {   # build_arch <arm64|x86_64> <cpu_family> <brew prefix>
    local arch="$1" family="$2" brewp="$3"
    local cross="$WORK_DIR/cross-$arch.ini" bdir="$WORK_DIR/build-$arch" pfx="$WORK_DIR/install-$arch"
    rm -rf "$bdir" "$pfx"
    cat > "$cross" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-mmacosx-version-min=$MIN_MACOS']
c_link_args = ['-mmacosx-version-min=$MIN_MACOS']

[properties]
pkg_config_libdir = ['$brewp/lib/pkgconfig']
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
EOF
    log "--- $arch: pkg-config view (PKG_CONFIG_LIBDIR=$brewp/lib/pkgconfig) ---"
    for m in libcjson liblz4; do
        if PKG_CONFIG_LIBDIR="$brewp/lib/pkgconfig" pkg-config --exists "$m"; then
            log "  $m $(PKG_CONFIG_LIBDIR="$brewp/lib/pkgconfig" pkg-config --modversion "$m") -> $(PKG_CONFIG_LIBDIR="$brewp/lib/pkgconfig" pkg-config --variable=libdir "$m")"
        else
            log "  $m NOT FOUND for $arch (install it with that arch's brew)"
        fi
    done
    log "--- $arch: meson setup ---"
    meson setup "$bdir" "$SRC" --cross-file "$cross" --prefix "$pfx" \
        --buildtype=release --default-library=shared "${MESON_OPTS[@]}" \
        2>&1 | sed "s/^/[LIBRIST-BUILD]   [$arch] /"
    log "--- $arch: effective crypto options ---"
    meson configure "$bdir" 2>/dev/null | grep -E 'use_mbedtls|builtin_mbedtls|use_gnutls|use_nettle|builtin_cjson|fallback_builtin' \
        | sed "s/^/[LIBRIST-BUILD]   [$arch] /" || true
    log "--- $arch: compile + install ---"
    ninja -C "$bdir" install 2>&1 | tail -n 20 | sed "s/^/[LIBRIST-BUILD]   [$arch] /"
}

build_arch arm64  aarch64 /opt/homebrew
build_arch x86_64 x86_64  /usr/local

# ---------------------------------------------------------------------------
# 4. Find the real dylib (librist.N.dylib) of each slice and check it
# ---------------------------------------------------------------------------
real_dylib() {   # newest real (non-symlink) librist.<N>.dylib under a prefix
    local f
    for f in "$1"/lib/librist.*.dylib; do [[ -L "$f" ]] || { echo "$f"; return; }; done
}
ARM="$(real_dylib "$WORK_DIR/install-arm64")"
X64="$(real_dylib "$WORK_DIR/install-x86_64")"
[[ -n "$ARM" && -n "$X64" ]] || die "built librist dylib not found under install-arm64 / install-x86_64"
NAME="$(basename "$ARM")"
[[ "$NAME" == "$(basename "$X64")" ]] || die "slice names differ: $NAME vs $(basename "$X64")"
log "built: $NAME"
[[ "$NAME" == "librist.4.dylib" ]] || die "expected librist.4.dylib (what libavformat links), got $NAME - stop"

fail=0
for f in "$ARM" "$X64"; do
    deps="$(otool -L "$f" | tail -n +2)"
    log "otool -L $(basename "$(dirname "$(dirname "$f")")"):"
    printf '%s\n' "$deps" | sed 's/^/[LIBRIST-BUILD]   /'
    for bad in mbed gnutls nettle hogweed gmp; do
        if [[ "$(printf '%s\n' "$deps" | grep -ci "$bad" || true)" -gt 0 ]]; then
            log "  FAIL: links '$bad'"; fail=1
        fi
    done
    syms="$(nm -gU "$f" 2>/dev/null || true)"
    n_mbed="$(printf '%s\n' "$syms" | grep -ci 'mbedtls' || true)"
    n_srp="$(printf '%s\n' "$syms" | grep -ciE 'srp|eap' || true)"
    log "  exported symbols: mbedtls=$n_mbed (must be 0), srp/eap=$n_srp (info only)"
    [[ "$n_mbed" -eq 0 ]] || fail=1
done
[[ "$fail" -eq 0 ]] || die "a slice still links a TLS/crypto library - see the lines above"

# ---------------------------------------------------------------------------
# 5. Every librist symbol libavformat needs must exist in the new build
# ---------------------------------------------------------------------------
AVF="$(ls "$REPO_DIR"/3rdparty/ffmpeg/lib/libavformat.*.*.*.dylib 2>/dev/null | head -n1 || true)"
if [[ -n "$AVF" ]]; then
    for pair in "arm64:$ARM" "x86_64:$X64"; do
        a="${pair%%:*}"; f="${pair#*:}"
        need="$(nm -arch "$a" -u "$AVF" 2>/dev/null | grep -E '^_rist_' | sort -u || true)"
        have="$(nm -gU "$f" 2>/dev/null | awk '{print $3}' | sort -u)"
        miss="$(comm -23 <(printf '%s\n' "$need") <(printf '%s\n' "$have") | grep -v '^$' || true)"
        log "libavformat ($a) needs $(printf '%s\n' "$need" | grep -c . || true) rist symbols; missing: ${miss:-none}"
        [[ -z "$miss" ]] || die "libavformat ($a) needs symbols the new librist does not export"
    done
else
    log "WARNING: 3rdparty/ffmpeg/lib/libavformat.*.dylib not found - symbol check skipped"
fi

# ---------------------------------------------------------------------------
# 6. Public headers: compare with the old Homebrew headers (ABI hint only)
# ---------------------------------------------------------------------------
OLD_INC="$(/opt/homebrew/bin/brew --prefix librist 2>/dev/null || true)/include/librist"
if [[ -d "$OLD_INC" ]]; then
    if diff -rq "$OLD_INC" "$WORK_DIR/install-arm64/include/librist" >/dev/null 2>&1; then
        log "public headers identical to Homebrew's ($OLD_INC)"
    else
        log "NOTE: public headers differ from Homebrew's ($OLD_INC) - Homebrew may hold another version:"
        diff -rq "$OLD_INC" "$WORK_DIR/install-arm64/include/librist" 2>&1 | sed 's/^/[LIBRIST-BUILD]   /' || true
    fi
fi

# ---------------------------------------------------------------------------
# 7. lipo + stage. Old files are MOVED to a backup folder, never deleted.
# ---------------------------------------------------------------------------
UNI="$WORK_DIR/$NAME"
lipo -create "$ARM" "$X64" -output "$UNI"
install_name_tool -id "@rpath/$NAME" "$UNI"
log "universal: $(lipo -info "$UNI" | sed 's/.*are: //')"

mkdir -p "$DEST"
BAK="$WORK_DIR/staged-backup-$STAMP"   # outside the repo
mkdir -p "$BAK"
shopt -s nullglob
moved=0
for f in "$DEST"/librist*.dylib "$DEST"/libmbedcrypto*.dylib "$DEST"/libmbedtls*.dylib "$DEST"/libmbedx509*.dylib; do
    mv "$f" "$BAK/"; moved=$((moved + 1))
done
log "moved $moved old librist/Mbed TLS file(s) to $BAK"
cp "$UNI" "$DEST/$NAME"
ln -sf "$NAME" "$DEST/librist.dylib"
log "staged: $DEST/$NAME (+ librist.dylib -> $NAME)"
log "now in $DEST:"
ls -l "$DEST" | sed 's/^/[LIBRIST-BUILD]   /'

final_deps="$(otool -L "$DEST/$NAME")"
if [[ "$(printf '%s\n' "$final_deps" | grep -ci mbed || true)" -gt 0 ]]; then
    die "staged librist still links Mbed TLS"
fi
log "RESULT: OK - librist $VER staged without Mbed TLS (sha256 of source $SHA)"
log "NEXT: Xcode > Product > Clean Build Folder, then build, then run:"
log "  otool -L Release/NXTMultiview.app/Contents/Frameworks/librist.4.dylib | grep -i mbed   (must print nothing)"
