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

step "dependencies: libffi glib pixman libucontext libslirp"
./scripts/build_ios.sh libffi glib pixman libucontext libslirp

step "QEMU"
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
