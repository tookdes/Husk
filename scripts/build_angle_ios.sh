#!/bin/bash
# Build ANGLE (EGL + GLES over Metal) for iOS arm64, deployable to iOS 15.
#
# This is the host-side GPU stack Husk needs. virglrenderer turns the guest's
# GL calls into real draw calls, but it needs an EGL/GLES implementation to make
# them against -- and iOS has no EGL at all. ANGLE supplies one on top of Metal.
# UTM does the same thing, which is what makes GPU acceleration inside a QEMU
# guest on iOS a solved problem rather than a hope.
#
# Source: UTM's WebKit fork, at the commit UTM itself pins (patches/sources in
# utmapp/UTM). Not WebKit main.
#
# Why not WebKit main any more: the ios15-trollstore port has to load this
# dylib on iPadOS 15.4.1. WebKit main only builds cleanly at whatever floor
# WebKit itself ships (the previous build pinned IPHONEOS_DEPLOYMENT_TARGET
# to 16.4 because clearing WebKit's availability overlay surfaced
# "MTLPixelFormatBC1_RGBA is only available on iOS 16.4" -- an enum constant,
# folded at compile time, that ANGLE only reaches behind its own runtime
# supportsBCTextureCompression check). UTM's fork is maintained for exactly
# this use (ANGLE under QEMU/virgl on iOS) and UTM builds it with
# IPHONEOS_DEPLOYMENT_TARGET=15.0 and GCC_TREAT_WARNINGS_AS_ERRORS=NO, and
# ships it to iOS 15 devices. The fork also exports the GL entry points by
# their standard names and drops an EGL_BAD_ACCESS check that QEMU trips.
#
# Output: build/ios-arm64/sysroot/lib/libANGLE-shared.dylib (install name
# @rpath/libANGLE-shared.dylib). The fork names its library libGLESv2; Husk's
# epoxy patch and project expect libANGLE-shared, so it is renamed on staging.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GPU="$HUSK_ROOT/third_party/gpu"
WK="$GPU/webkit-utm"
PREFIX="$HUSK_ROOT/build/ios-arm64/sysroot"
LOG="$HUSK_ROOT/build/logs/angle-build.log"
MINOS="${ANGLE_IOS_MIN:-15.0}"
mkdir -p "$GPU" "$(dirname "$LOG")"

WEBKIT_REPO="https://github.com/utmapp/WebKit.git"
WEBKIT_COMMIT="ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10"
STAMP="$PREFIX/lib/.angle-stamp"
WANT_STAMP="$WEBKIT_COMMIT ios$MINOS v2"

if [ -f "$PREFIX/lib/libANGLE-shared.dylib" ] && [ -f "$STAMP" ] \
   && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    echo "==> ANGLE already built ($WANT_STAMP); skipping"
    exit 0
fi
rm -f "$PREFIX/lib/libANGLE-shared.dylib" "$STAMP"

# Fetch exactly the pinned commit, shallow and blob-filtered, and only the
# subtrees the ANGLE Xcode project needs. Configurations and Tools/ccache are
# not optional: the ANGLE xcconfigs include ../../../../Configurations/* and
# ../../../../Tools/ccache/ccache.xcconfig, and the build fails to even start
# without them.
if [ ! -d "$WK/.git" ] || [ "$(git -C "$WK" rev-parse HEAD 2>/dev/null)" != "$WEBKIT_COMMIT" ]; then
    echo "==> fetching utmapp/WebKit@$WEBKIT_COMMIT (ANGLE subtree only)"
    rm -rf "$WK"
    git init -q "$WK"
    ( cd "$WK"
      git remote add origin "$WEBKIT_REPO"
      git config core.sparseCheckout true
      git sparse-checkout init --cone
      git sparse-checkout set Source/ThirdParty/ANGLE Configurations Tools/ccache
      git fetch -q --depth 1 --filter=blob:none origin "$WEBKIT_COMMIT"
      git checkout -q FETCH_HEAD )
fi
[ -f "$WK/Source/ThirdParty/ANGLE/ANGLE.xcodeproj/project.pbxproj" ] \
    || { echo "ANGLE Xcode project missing after checkout" >&2; exit 1; }

cd "$WK/Source/ThirdParty/ANGLE"
# Scheme "ANGLE (dynamic)" = libGLESv2.dylib (+ its ANGLEMetalLib dependency)
# only. The aggregate "ANGLE" scheme also builds the fork's thin libEGL loader,
# which Husk does not use and which the pass-2 alias list cannot link (it has
# none of the EGL_* symbols the aliases point at).
ALIASES="$GPU/angle-aliases.txt"

angle_build () {
    # The alias flag has to reach xcodebuild as ONE argument (see git history
    # of this file); build it in an array and expand that array quoted.
    # $(inherited) is for xcodebuild to expand, not the shell.
    local ldflags=()
    if [ -n "${1:-}" ]; then
        ldflags=("OTHER_LDFLAGS=\$(inherited) -Wl,-alias_list,$1")
    fi

    env -i PATH="$PATH" HOME="$HOME" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} \
      xcodebuild archive \
        -archivePath "ANGLE" -scheme "ANGLE (dynamic)" \
        -sdk iphoneos -arch arm64 -configuration Release \
        WEBCORE_LIBRARY_DIR="/usr/local/lib" NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        GCC_TREAT_WARNINGS_AS_ERRORS=NO \
        WK_AVAILABILITY_OVERLAY_FLAGS="" WK_AVAILABILITY_OVERLAY_SWIFT_FLAGS="" \
        IPHONEOS_DEPLOYMENT_TARGET="$MINOS" \
        ${ldflags[@]+"${ldflags[@]}"} \
        > "$LOG" 2>&1 \
      || { echo "ANGLE build failed; last errors:" >&2
           grep -a "error:\|^ld: \|BUILD FAILED\|ARCHIVE FAILED" "$LOG" | head -30 >&2
           echo "----- tail of $LOG -----" >&2; tail -n 60 "$LOG" >&2
           exit 1; }
}

find_dylib () {
    local d
    for d in "ANGLE.xcarchive/Products/usr/local/lib/libGLESv2.dylib" \
             "ANGLE.xcarchive/Products/usr/local/lib/libANGLE-shared.dylib"; do
        [ -f "$d" ] && { echo "$d"; return 0; }
    done
    echo "no ANGLE dylib in the archive; it contains:" >&2
    find ANGLE.xcarchive/Products -maxdepth 5 >&2 || true
    return 1
}

echo "==> building ANGLE ($WEBKIT_COMMIT) for iOS $MINOS arm64, pass 1 (log: $LOG)"
rm -rf ANGLE.xcarchive
angle_build ""
DYLIB="$(find_dylib)"

# ANGLE's libGLESv2 exports EGL as EGL_ChooseConfig etc. (libEGL normally
# forwards eglChooseConfig to it). Add the standard names as link-time aliases
# so epoxy/virgl/QEMU can bind them directly. GL names are already exported
# under their standard names by UTM's fork; Husk's epoxy patch also falls back
# from glFoo to GL_Foo for older builds.
echo "==> generating EGL symbol aliases"
nm -g "$DYLIB" | awk '$2=="T"{print $3}' | grep -E '^_EGL_' \
  | awk '{o=$1; a=$1; sub(/^_EGL_/,"_egl",a); print o, a}' > "$ALIASES" || true
# Don't alias names the dylib already exports.
if [ -s "$ALIASES" ]; then
    nm -g "$DYLIB" | awk '$2=="T"{print $3}' | grep -E '^_egl' | sort -u > "$GPU/angle-existing-egl.txt" || true
    # (FILENAME, not NR==FNR: the existing-names file is usually empty, and
    # with an empty first file NR==FNR holds for every alias line too.)
    awk -v have_file="$GPU/angle-existing-egl.txt" \
        'FILENAME==have_file{have[$1]=1; next} !($2 in have)' \
        "$GPU/angle-existing-egl.txt" "$ALIASES" > "$ALIASES.tmp"
    mv "$ALIASES.tmp" "$ALIASES"
fi
echo "    $(wc -l < "$ALIASES" | tr -d ' ') aliases"

if [ -s "$ALIASES" ]; then
    echo "==> pass 2, relinking with standard EGL names"
    rm -rf ANGLE.xcarchive
    angle_build "$ALIASES"
    DYLIB="$(find_dylib)"
fi

install -d "$PREFIX/lib" "$PREFIX/include"
cp "$DYLIB" "$PREFIX/lib/libANGLE-shared.dylib"
rsync -a "include/" "$PREFIX/include/"

# Ours is embedded in the app, so the install name has to say so or dyld will
# not find it at runtime.
install_name_tool -id "@rpath/libANGLE-shared.dylib" "$PREFIX/lib/libANGLE-shared.dylib"

OUT="$PREFIX/lib/libANGLE-shared.dylib"
echo "==> staged $(ls -lh "$OUT" | awk '{print $5}') to $PREFIX/lib"
otool -D "$OUT" | tail -1
echo "==> LC_BUILD_VERSION:"
otool -l "$OUT" | grep -A4 LC_BUILD_VERSION | sed 's/^/    /'
echo "==> linked libraries:"
otool -L "$OUT" | sed 's/^/    /'
echo "==> standard EGL entry points exported: $(nm -g "$OUT" | grep -c ' T _egl' || true)"
echo "==> standard GL  entry points exported: $(nm -g "$OUT" | grep -c ' T _gl[A-Z]' || true)"
echo "==> EGL_-prefixed entry points:          $(nm -g "$OUT" | grep -c ' T _EGL_' || true)"
OUT_SYMS="$(nm -g "$OUT")"
for s in _eglGetDisplay _eglInitialize _eglGetProcAddress _eglCreateContext _eglMakeCurrent; do
    grep -q " T $s\$" <<<"$OUT_SYMS" || { echo "ANGLE is missing $s" >&2; exit 1; }
done

MIN_SEEN="$(otool -l "$OUT" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="minos"&&!d{print $2; d=1}')"
if [ "$MIN_SEEN" != "$MINOS" ]; then
    echo "ANGLE minos is '$MIN_SEEN', expected $MINOS" >&2
    exit 1
fi
echo "$WANT_STAMP" > "$STAMP"
