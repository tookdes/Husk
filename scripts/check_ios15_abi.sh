#!/bin/bash
# Refuse an IPA that will dyld-abort on iOS 15.4 before main.
# Xcode 26 / iPhoneOS 26 SDK links Swift Foundation protocol descriptors
# (LocalizedErrorMp, ContiguousBytesMp, …) such that dyld reports:
#   Symbol not found: _$s10Foundation14LocalizedErrorMp
#   Expected in: /System/Library/Frameworks/Foundation.framework/Foundation
set -euo pipefail

IPA="${1:?usage: check_ios15_abi.sh <ipa>}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
unzip -q "$IPA" -d "$STAGE"
APP="$STAGE/Payload/Husk.app"
BIN="$APP/Husk"

echo "==> Info.plist SDK / version"
plutil -p "$APP/Info.plist" | grep -E 'MinimumOSVersion|UIDeviceFamily|DTXcode|DTSDKName|CFBundleVersion|CFBundleShortVersionString' || true

SDKNAME="$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$APP/Info.plist")"
MAJOR="$(printf '%s' "$SDKNAME" | sed -n 's/^iphoneos\([0-9][0-9]*\).*/\1/p')"
if [ -z "$MAJOR" ] || [ "$MAJOR" -ge 26 ]; then
    echo "Refusing IPA built with $SDKNAME (need Xcode 16 / iOS <=18 SDK for iOS 15.4 dyld)" >&2
    exit 1
fi
echo "SDK ok: $SDKNAME (major=$MAJOR)"

echo "==> LC_BUILD_VERSION"
otool -l "$BIN" | grep -A5 LC_BUILD_VERSION || true
if [ -f "$APP/Frameworks/libqemu-aarch64-softmmu.dylib" ]; then
    otool -l "$APP/Frameworks/libqemu-aarch64-softmmu.dylib" | grep -A5 LC_BUILD_VERSION || true
fi

echo "==> LocalizedErrorMp two-level namespace"
NM_OUT="$(nm -m "$BIN" 2>/dev/null | grep 'LocalizedErrorMp' || true)"
echo "$NM_OUT"
if echo "$NM_OUT" | grep -q 'from Foundation)'; then
    echo "LocalizedErrorMp is bound to Foundation.framework; iOS 15.4 dyld will abort pre-main" >&2
    exit 1
fi
if echo "$NM_OUT" | grep -q 'LocalizedErrorMp' && ! echo "$NM_OUT" | grep -q 'libswiftFoundation'; then
    echo "LocalizedErrorMp not clearly from libswiftFoundation:" >&2
    echo "$NM_OUT" >&2
    exit 1
fi

echo "==> frameworks absent on iOS 15"
if otool -L "$BIN" | grep -E 'SwiftUICore|SwiftData\.framework|Observation\.framework|Synchronization\.framework'; then
    echo "Binary links a framework absent on iOS 15" >&2
    exit 1
fi

echo "==> must NOT LC_LOAD_DYLIB libqemu at process start (lazy dlopen)"
if otool -L "$BIN" | grep -F 'libqemu-aarch64-softmmu.dylib'; then
    echo "Husk still links libqemu at load time; constructors run pre-UI" >&2
    exit 1
fi
echo "libqemu not in LC_LOAD_DYLIB (good; HuskQemuLazy dlopens later)"

echo "==> must NOT embed banned dynamic-codesigning entitlement"
if codesign -d --entitlements - "$BIN" 2>/dev/null | grep -q 'dynamic-codesigning'; then
    echo "dynamic-codesigning present; iOS 15 A12+ AMFI SIGKILLs at launch" >&2
    exit 1
fi
echo "dynamic-codesigning absent (good)"

echo "==> iOS 15 ABI checks passed"
