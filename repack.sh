#!/bin/sh
# repack.sh - repack ZeroBlock-related ipk packages for another OpenWrt
# architecture (default: aarch64_generic).
#
# Only the "Architecture:" line of the control file is changed. Package payloads
# (data.tar.gz) are kept identical (verified after repack, the script aborts on
# any difference). Packages are fetched ONLY from the feed URL you give it, or
# taken from local .ipk files you pass explicitly.
#
# Requirements: sh, curl, GNU tar, gzip, sed, sha256sum, find, sort, diff
# (Linux or WSL; busybox tar is not enough)
#
# Usage:
#   ./repack.sh                              # zeroblock, luci-app-zeroblock, sing-box-rr from the feed
#   ./repack.sh zeroblock sing-box-rr        # only these packages from the feed
#   ./repack.sh ./openwrt-xray_*.ipk         # a local .ipk (any path ending in .ipk)
#   ./repack.sh zeroblock ./xray.ipk         # mix of both
#
# Environment:
#   FEED      feed directory URL (page with links to .ipk files)
#   SRC_ARCH  architecture the source packages were built for (default aarch64_cortex-a53)
#   ARCH      target architecture (default aarch64_generic)
#   OUT       output directory (default ./out)

set -eu

FEED="${FEED:-https://packages.routerich.ru/24.10/mediatek/filogic/routerich}"
SRC_ARCH="${SRC_ARCH:-aarch64_cortex-a53}"
ARCH="${ARCH:-aarch64_generic}"
OUT="${OUT:-./out}"
DEFAULT_PKGS="zeroblock luci-app-zeroblock sing-box-rr"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

for t in curl tar gzip sed sha256sum find sort diff; do need "$t"; done
tar --version 2>/dev/null | grep -qi "gnu tar" || die "GNU tar is required (busybox tar cannot set --owner/--group)"

if [ "$#" -gt 0 ]; then ARGS="$*"; else ARGS="$DEFAULT_PKGS"; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

echo "Feed : $FEED"
echo "Arch : $SRC_ARCH -> $ARCH"
echo "Out  : $OUT_ABS"

INDEX="$WORK/index.html"
INDEX_LOADED=0

# download with resume: some networks/proxies cut long transfers
fetch() {
    url="$1"; dest="$2"
    len="$(curl -fsSI -m 30 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')"
    [ -n "$len" ] || die "no Content-Length for $url"
    i=0
    while [ "$i" -lt 60 ]; do
        if [ -f "$dest" ] && [ "$(wc -c < "$dest")" = "$len" ]; then return 0; fi
        curl -fsS -m 180 -C - -o "$dest" "$url" 2>/dev/null || true
        i=$((i + 1))
        sleep 1
    done
    if [ -f "$dest" ] && [ "$(wc -c < "$dest")" = "$len" ]; then return 0; fi
    die "download incomplete: $url"
}

# repack_file <src.ipk> <workdir>
repack_file() {
    src="$1"; d="$2"
    mkdir -p "$d/c" "$d/data" "$d/x"
    gzip -t "$src" || die "not a valid gzip/ipk file: $src"

    tar -xzf "$src" -C "$d/x"
    tar -xzf "$d/x/control.tar.gz" -C "$d/c"
    tar -xzf "$d/x/data.tar.gz" -C "$d/data"

    name="$(sed -n 's/^Package: //p' "$d/c/control")"
    ver="$(sed -n 's/^Version: //p' "$d/c/control")"
    parch="$(sed -n 's/^Architecture: //p' "$d/c/control")"
    [ -n "$name" ] && [ -n "$ver" ] && [ -n "$parch" ] || die "cannot read control fields from $src"

    if [ "$parch" = "all" ]; then
        cp "$src" "$OUT_ABS/${name}_${ver}_all.ipk"
        echo "   arch-independent, copied as is -> ${name}_${ver}_all.ipk"
        return 0
    fi

    sed -i "s/^Architecture: .*/Architecture: ${ARCH}/" "$d/c/control"
    grep -q "^Architecture: ${ARCH}\$" "$d/c/control" || die "failed to set architecture for $name"

    # ./* does not include dotfiles; refuse rather than silently drop them
    [ -z "$(find "$d/c" "$d/data" -mindepth 1 -name '.*' 2>/dev/null | head -n 1)" ] \
        || die "$name contains dotfiles; refusing to repack"

    (cd "$d/c" && tar --owner=0 --group=0 -czf "$d/x/control.tar.gz" ./*)
    (cd "$d/data" && tar --owner=0 --group=0 -czf "$d/x/data.tar.gz" ./*)
    printf '2.0\n' > "$d/x/debian-binary"

    outf="$OUT_ABS/${name}_${ver}_${ARCH}.ipk"
    (cd "$d/x" && tar --owner=0 --group=0 -czf "$outf" ./debian-binary ./control.tar.gz ./data.tar.gz)

    # verify: payload identical to the source package
    v="$d/verify"; mkdir -p "$v/orig_ipk" "$v/new_ipk" "$v/orig" "$v/new"
    tar -xzf "$src" -C "$v/orig_ipk"; tar -xzf "$v/orig_ipk/data.tar.gz" -C "$v/orig"
    tar -xzf "$outf" -C "$v/new_ipk"; tar -xzf "$v/new_ipk/data.tar.gz" -C "$v/new"
    diff -r "$v/orig" "$v/new" >/dev/null 2>&1 || die "payload mismatch after repack: $name"
    echo "   OK -> ${name}_${ver}_${ARCH}.ipk (payload identical)"
}

repack_feed_pkg() {
    pkg="$1"
    if [ "$INDEX_LOADED" -eq 0 ]; then
        curl -fsS -m 60 -o "$INDEX" "$FEED/" || die "cannot fetch feed index: $FEED/"
        INDEX_LOADED=1
    fi
    file="$(grep -o 'href="[^"]*\.ipk"' "$INDEX" | sed 's/^href="//; s/"$//' \
        | grep -E "^${pkg}_[0-9][^_]*_(${SRC_ARCH}(-${SRC_ARCH})?|all)\.ipk$" \
        | sort -V | tail -n 1 || true)"
    [ -n "$file" ] || die "package '$pkg' not found in feed for $SRC_ARCH/all (not every package is in every feed; pass a local .ipk instead)"
    echo "== $pkg: $file"
    d="$WORK/$pkg"; mkdir -p "$d"
    fetch "$FEED/$file" "$d/src.ipk"
    repack_file "$d/src.ipk" "$d"
}

n=0
for a in $ARGS; do
    n=$((n + 1))
    case "$a" in
        *.ipk)
            [ -f "$a" ] || die "file not found: $a"
            echo "== local: $a"
            d="$WORK/local$n"; mkdir -p "$d"
            repack_file "$a" "$d"
            ;;
        *)
            repack_feed_pkg "$a"
            ;;
    esac
done

(cd "$OUT_ABS" && sha256sum ./*.ipk | sed 's#\./##' > SHA256SUMS)
echo
echo "Done. Checksums of your local build: $OUT_ABS/SHA256SUMS"
echo "Install on the router, e.g.:  opkg install /tmp/<file>.ipk ..."
