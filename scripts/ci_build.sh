#!/bin/bash
# Husk: build everything from a clean checkout to an unsigned IPA, in order.
#
# Runs on macOS with Xcode. Usage: ./scripts/ci_build.sh [output.ipa]
#
# This ios15-trollstore port MUST be built with Xcode 16.4 (iPhoneOS 18.x SDK),
# not Xcode 26. The iOS 26 SDK produces binaries whose Swift Foundation
# protocol descriptors (LocalizedErrorMp) do not resolve on iOS 15.4.1 and
# dyld-abort before main. The workflow may still xcode-select 26.3; we override.
set -euo pipefail

HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HUSK_ROOT/build/Husk.ipa}"
cd "$HUSK_ROOT"

step() { printf '\n\033[1;34m##### %s\033[0m\n' "$*"; }

step "select Xcode 16.4 for iOS 15 back-deploy"
if [ -d /Applications/Xcode_16.4.app/Contents/Developer ]; then
    sudo xcode-select -s /Applications/Xcode_16.4.app/Contents/Developer
    export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
elif [ -d /Applications/Xcode_16.3.app/Contents/Developer ]; then
    sudo xcode-select -s /Applications/Xcode_16.3.app/Contents/Developer
    export DEVELOPER_DIR=/Applications/Xcode_16.3.app/Contents/Developer
else
    echo "Xcode 16.4/16.3 not installed; refusing to build with $(xcodebuild -version 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
fi
xcodebuild -version
XCVER="$(xcodebuild -version | awk 'NR==1{print $2}')"
case "$XCVER" in
    16.*) ;;
    *)
        echo "Expected Xcode 16.x for iOS 15 dyld compatibility, got $XCVER" >&2
        exit 1
        ;;
esac

step "fetch sources"
./scripts/fetch_sources.sh

# ANGLE first: it needs nothing from the other stages and is by far the
# longest single build, so a failure here surfaces in minutes, not after QEMU.
# iOS 15 floor (UTM's WebKit fork, as UTM ships it); see build_angle_ios.sh.
step "ANGLE (EGL/GLES over Metal, iOS ${SDKMINVER:-15.0} floor)"
SDKMINVER="${SDKMINVER:-15.0}" ANGLE_IOS_MIN="${SDKMINVER:-15.0}" ./scripts/build_angle_ios.sh

step "dependencies: libffi glib pixman libucontext libslirp"
./scripts/build_ios.sh libffi glib pixman libucontext libslirp

# build_gpu_ios.sh asks for cross-ios-darwin.meson, which no script generates.
# build_ios.sh writes cross-darwin.meson, the file it describes (host system
# darwin, subsystem ios), under a different name.
cp build/ios-arm64/cross-darwin.meson build/ios-arm64/cross-ios-darwin.meson

step "libepoxy + virglrenderer"
# build_ios.sh's cross environment, which the GPU script assumes is set.
PKG_CONFIG_LIBDIR="$HUSK_ROOT/build/ios-arm64/sysroot/lib/pkgconfig:$HUSK_ROOT/build/ios-arm64/sysroot/share/pkgconfig" \
    SDKMINVER="${SDKMINVER:-15.0}" ./scripts/build_gpu_ios.sh

step "QEMU"
# The CI cache restores a QEMU tree that integrate_husk.sh already wired up
# in an earlier run, so the first QEMU build below compiles whatever Husk
# sources that tree holds. The GL stub is listed unconditionally in
# ui/meson.build; an old copy of it (from the --disable-opengl days) has no
# CONFIG_OPENGL guard and collides with husk-display-gl.c at link time. Refresh
# it before building; everything else is refreshed by integrate_husk.sh below.
if [ -d third_party/build/qemu-10.0.12-utm/ui ]; then
    cp src/ios-jit/husk-display-gl-stub.c third_party/build/qemu-10.0.12-utm/ui/
fi
./scripts/build_ios.sh qemu

step "integrate Husk sources into QEMU, then rebuild it"
./scripts/integrate_husk.sh
./scripts/build_ios.sh qemurebuild

step "guest kernel + firmware"
./scripts/fetch_phase0_guest.sh

step "on-device pairing (Rust)"
./scripts/build_rppairing_ios.sh

step "app + IPA"
mkdir -p "$(dirname "$OUT")"
./scripts/package_ipa.sh "$OUT"

step "iOS 15 ABI guard"
./scripts/check_ios15_abi.sh "$OUT"

# Also keep a versioned sibling next to OUT so a downloaded artifact that still
# uses the stable Actions path can be copied/renamed locally without guessing.
# (Pushing workflow renames needs the GitHub `workflow` scope.)
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/app/Husk/Info.plist 2>/dev/null || echo 0)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' src/app/Husk/Info.plist 2>/dev/null || echo 0)
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
VERSIONED="$(dirname "$OUT")/Husk-${VER}-${BUILD}-${SHA}.ipa"
if [ "$OUT" != "$VERSIONED" ] && [ -f "$OUT" ]; then
    cp -f "$OUT" "$VERSIONED"
    echo "==> also wrote $VERSIONED"
fi

