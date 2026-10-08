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

echo "==> must NOT embed TrollStore-banned entitlements (A12+ iOS 15 silent SIGKILL)"
ENTS="$(codesign -d --entitlements - "$BIN" 2>/dev/null || true)"
for bad in dynamic-codesigning com.apple.private.cs.debugger com.apple.private.skip-library-validation; do
    if echo "$ENTS" | grep -q "$bad"; then
        echo "$bad present; iOS 15 A12+ AMFI SIGKILLs at launch" >&2
        exit 1
    fi
done
echo "banned entitlements absent (good)"

# ---------------------------------------------------------------------------
# Every Mach-O in the bundle, not just the main executable.
#
# 0.9.0 embeds ANGLE again. The previous ANGLE build had minos 16.4, and dyld
# on iOS 15.4.1 refuses to load an image whose LC_BUILD_VERSION minos is newer
# than the OS -- for a dlopen'd library that surfaces as a GL start failure,
# for a linked one as a pre-main abort with no .ips. So every embedded image
# must say <= 15.4, and none may hard-link a framework iOS 15 does not have.
# ---------------------------------------------------------------------------
MAX_MINOS="15.4"
ver_gt() {  # ver_gt A B  -> true if A > B (dotted, numeric)
    awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,x,"."); nb=split(b,y,".");
        for(i=1;i<=3;i++){ xa=(i<=na)?x[i]+0:0; yb=(i<=nb)?y[i]+0:0;
            if(xa>yb){exit 0} if(xa<yb){exit 1} }
        exit 1 }'
}
# (awk never exits early: under pipefail an early exit SIGPIPEs otool and
# set -e would then kill the script on a perfectly good image.)
macho_minos() {
    otool -l "$1" 2>/dev/null | awk '
        /cmd LC_BUILD_VERSION/{bv=1; next}
        /cmd LC_VERSION_MIN_IPHONEOS/{vm=1; next}
        !done && bv && $1=="minos"{print $2; done=1}
        !done && vm && $1=="version"{print $2; done=1}' || true
}
# Frameworks / dylibs introduced after iOS 15 (or never on iOS). Only a hard
# (LC_LOAD_DYLIB) link is fatal; LC_LOAD_WEAK_DYLIB is fine.
NEWER_LIBS='SwiftUICore\.framework|SwiftData\.framework|Observation\.framework|Synchronization\.framework|/Testing\.framework|TipKit\.framework|AppIntents\.framework|Translation\.framework|DeviceDiscoveryExtension|ExtensionFoundation\.framework|ExtensionKit\.framework|BrowserEngineKit|BrowserEngineCore|libswift_RegexParser|libswift_StringProcessing'
# Symbols that only exist on iOS 16+ and must be weak if referenced at all.
NEWER_SYMS='_OBJC_CLASS_\$_(MTLIOCommandQueueDescriptor|MTLIOCompressionContext|MTLMeshRenderPipelineDescriptor|MTLResidencySetDescriptor|MTLLogStateDescriptor|MTLLogicalToPhysicalColorAttachmentMap|MTLFunctionStitchingAttributeAlwaysInline|MTL4[A-Za-z]*)|_MTLIOCreateCompressionContext|_MTLIOCompressionContext'

echo "==> every embedded Mach-O: minos <= $MAX_MINOS, no hard links to post-iOS-15 frameworks"
abi_rc=0
nmacho=0
while IFS= read -r -d '' f; do
    case "$(file -b "$f" 2>/dev/null || true)" in *Mach-O*) ;; *) continue ;; esac
    nmacho=$((nmacho+1))
    rel="${f#$APP/}"
    minos="$(macho_minos "$f")"
    if [ -z "$minos" ]; then
        printf "  ??   %-55s no LC_BUILD_VERSION/LC_VERSION_MIN_IPHONEOS\n" "$rel"
    elif ver_gt "$minos" "$MAX_MINOS"; then
        printf "  FAIL %-55s minos %s > %s\n" "$rel" "$minos" "$MAX_MINOS" >&2
        abi_rc=1
    else
        printf "  ok   %-55s minos %s\n" "$rel" "$minos"
    fi
    hard="$(otool -l "$f" 2>/dev/null | awk '/cmd LC_LOAD_DYLIB$/{l=1;next} /cmd /{l=0} l&&$1=="name"{print $2}' || true)"
    bad="$(printf '%s\n' "$hard" | grep -E "$NEWER_LIBS" || true)"
    if [ -n "$bad" ]; then
        echo "  FAIL $rel hard-links a library absent on iOS 15:" >&2
        printf '         %s\n' $bad >&2
        abi_rc=1
    fi
    strong_new="$(nm -m "$f" 2>/dev/null | grep '(undefined)' | grep -v ' weak ' \
                  | grep -E "$NEWER_SYMS" || true)"
    if [ -n "$strong_new" ]; then
        echo "  FAIL $rel strongly references iOS 16+ symbols:" >&2
        echo "$strong_new" | head -20 | sed 's/^/         /' >&2
        abi_rc=1
    fi
done < <(find "$APP" -type f -print0)
echo "  checked $nmacho Mach-O images"
[ "$abi_rc" -eq 0 ] || { echo "embedded images would not load on iOS 15.4" >&2; exit 1; }

echo "==> GPU path present (0.9.0+)"
ANGLE="$APP/Frameworks/libANGLE-shared.dylib"
QEMU="$APP/Frameworks/libqemu-aarch64-softmmu.dylib"
[ -f "$ANGLE" ] || { echo "libANGLE-shared.dylib not embedded" >&2; exit 1; }
grep -q '@rpath/libANGLE-shared.dylib' <<<"$(otool -D "$ANGLE")" \
    || { echo "ANGLE install name is not @rpath/libANGLE-shared.dylib" >&2; otool -D "$ANGLE" >&2; exit 1; }
ANGLE_SYMS="$(nm -g "$ANGLE" 2>/dev/null || true)"
for sym in _eglGetDisplay _eglInitialize _eglGetProcAddress _eglCreateContext _eglMakeCurrent; do
    grep -q " T $sym\$" <<<"$ANGLE_SYMS" || { echo "ANGLE does not export $sym" >&2; exit 1; }
done
if grep -F 'libANGLE-shared.dylib' <<<"$(otool -L "$BIN")"; then
    echo "Husk links ANGLE at load time; it must only be dlopened by QEMU's epoxy" >&2
    exit 1
fi
LC_ALL=C grep -q '@rpath/libANGLE-shared.dylib' "$QEMU" \
    || { echo "libqemu has no epoxy path to ANGLE: QEMU was built without OpenGL" >&2; exit 1; }
# The epoxy path above is the hard proof of --enable-opengl. virglrenderer's
# own internals (vrend_*) are a softer signal -- a stripped static link may
# keep none of their names -- so its absence only warns.
if LC_ALL=C grep -q 'vrend_' "$QEMU"; then
    echo "virglrenderer present in libqemu"
else
    echo "WARNING: no vrend_* strings in libqemu; was virglrenderer linked?" >&2
fi
echo "ANGLE embedded (lazy), libqemu built with epoxy + virglrenderer"

echo "==> iOS 15 ABI checks passed"
