#!/bin/bash
# Download + unpack every Husk dependency into third_party/sources and third_party/build.
set -u
HUSK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$HUSK_ROOT/scripts/sources.sh"
DL="$HUSK_ROOT/third_party/sources"
SRC="$HUSK_ROOT/third_party/build"
mkdir -p "$DL" "$SRC"

fetch() {
    local url="$1" file="$DL/$(basename "$1")" candidate
    if [ -s "$file" ]; then echo "[skip] $(basename "$file")"; return 0; fi
    echo "[get ] $(basename "$file")"

    # ftp.gnu.org is occasionally unreachable from GitHub's macOS runners.
    # GNU's mirror redirector is the preferred CI path; keep the canonical URL
    # as a fallback so a mirror outage does not break the build either.
    local candidates=("$url")
    if [[ "$url" == https://ftp.gnu.org/gnu/* ]]; then
        candidates=("https://ftpmirror.gnu.org/${url#https://ftp.gnu.org/gnu/}" "$url")
    fi

    rm -f "$file.part"
    for candidate in "${candidates[@]}"; do
        echo "      -> $candidate"
        if curl -fL --connect-timeout 15 --max-time 180 \
                --retry 2 --retry-delay 3 --retry-all-errors \
                -o "$file.part" "$candidate"; then
            mv "$file.part" "$file"
            return 0
        fi
        rm -f "$file.part"
    done
    echo "[FAIL] $url"
    return 1
}

unpack() {
    local file="$DL/$(basename "$1")" stamp
    stamp="$SRC/.unpacked-$(basename "$file")"
    [ -f "$stamp" ] && { echo "[skip] unpack $(basename "$file")"; return 0; }
    echo "[tar ] $(basename "$file")"
    tar -xf "$file" -C "$SRC" || return 1
    touch "$stamp"
}

rc=0
for u in "$FFI_SRC" "$ICONV_SRC" "$GETTEXT_SRC" "$GLIB_SRC" "$PIXMAN_SRC" "$SLIRP_SRC" "$QEMU_SRC"; do
    fetch "$u" || rc=1
done
for u in "$FFI_SRC" "$ICONV_SRC" "$GETTEXT_SRC" "$GLIB_SRC" "$PIXMAN_SRC" "$SLIRP_SRC" "$QEMU_SRC"; do
    unpack "$u" || rc=1
done

if [ ! -d "$SRC/libucontext" ]; then
    echo "[git ] libucontext"
    git clone "$LIBUCONTEXT_REPO" "$SRC/libucontext" >/dev/null 2>&1 \
        && git -C "$SRC/libucontext" checkout -q "$LIBUCONTEXT_COMMIT" \
        || { echo "[FAIL] libucontext"; rc=1; }
else
    echo "[skip] libucontext"
fi

echo "--- result rc=$rc ---"
ls -1 "$SRC" | grep -v '^\.' 
exit $rc
