#!/bin/sh
# Get-VsDbgOffline.sh: package vsdbg for air-gapped use (run once on a CONNECTED machine).
#
# Mirrors Microsoft's GetVsDbg.sh (https://aka.ms/getvsdbgsh):
#   * version keywords (latest, vs2022, ...) resolve to the version number the
#     live GetVsDbg.sh resolves them to (the script is downloaded and parsed);
#   * download URL  <base>/vsdbg-<version with . -> ->/vsdbg-<rid>.tar.gz (.zip for win-*);
#   * layout        the archive is extracted as-is into the install folder;
#   * markers       success_rid.txt / success_version.txt, same contents, so
#                   GetVsDbg.sh (and VS) treat the folder as already installed.
# Output: <drop>/<key>/<rid>/            (mounted into containers by devsuite/tilt/vsdbg.star)
#         <drop>/<key>/<rid>.json        (sidecar: version, rid, sha256, source, date)
#         <drop>/manifest.json           (all sidecars, regenerated on every run)
#
# Usage:
#   Get-VsDbgOffline.sh [-v key[,key...]] [-r rid[,rid...]] [-l drop_dir] [-f]
#   Get-VsDbgOffline.sh -a vsdbg-linux-x64.tar.gz -r linux-x64 -v <key|version> [-k key]
#
#   -v  version keywords or numbers (default: vs2022,vs2026). Each one is a drop key.
#   -r  runtime IDs (default: linux-x64,linux-musl-x64).
#   -l  drop directory (default: <script dir>/drop).
#   -k  drop key when -v is a version number (default: the -v value).
#   -a  FromArchive: use an already-downloaded vsdbg-<rid>.tar.gz/.zip (one -v, one -r).
#   -S  GetVsDbg.sh URL or local path used for version resolution (default: https://aka.ms/getvsdbgsh).
#   -B  download base URL (default: parsed from GetVsDbg.sh, else Microsoft's CDN). Internal mirrors.
#   -f  re-download even when the markers say the folder is up to date.
#   -h  help.
#
# Owner: task C (vsdbg offline). See docs/vsdbg.md.

set -eu

DEFAULT_SCRIPT_URL="https://aka.ms/getvsdbgsh"
DEFAULT_BASE_URL="https://vsdebugger-cyg0dxb6czfafzaz.b01.azurefd.net"
VALID_RIDS="linux-x64 linux-musl-x64 linux-arm linux-musl-arm linux-arm64 linux-musl-arm64 osx-x64 osx-arm64 win7-x64 win-x64 win-arm64"
# Keys VS uses that GetVsDbg.sh may not know yet: they resolve like "latest" (with a warning).
LATEST_ALIASES="vs2026"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
versions="vs2022,vs2026"
rids="linux-x64,linux-musl-x64"
drop="$SCRIPT_DIR/drop"
key_override=""
archive=""
script_src="$DEFAULT_SCRIPT_URL"
base_url=""
force=0

say()  { echo "[vsdbg-offline] $*"; }
die()  { echo "[vsdbg-offline] ERROR: $*" >&2; exit 1; }
help() { sed -n '2,/^# Owner/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

while getopts "v:r:l:k:a:S:B:fh" opt; do
    case "$opt" in
        v) versions="$OPTARG" ;;
        r) rids="$OPTARG" ;;
        l) drop="$OPTARG" ;;
        k) key_override="$OPTARG" ;;
        a) archive="$OPTARG" ;;
        S) script_src="$OPTARG" ;;
        B) base_url="$OPTARG" ;;
        f) force=1 ;;
        h) help; exit 0 ;;
        *) help >&2; exit 2 ;;
    esac
done

versions=$(echo "$versions" | tr ',' ' ')
rids=$(echo "$rids" | tr ',' ' ')
mkdir -p "$drop"
drop=$(cd "$drop" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

for rid in $rids; do
    case " $VALID_RIDS " in *" $rid "*) ;; *) die "unknown runtime ID '$rid' (valid: $VALID_RIDS)" ;; esac
done

# shellcheck disable=SC2086 # word splitting is the point: count the list items
if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "archive not found: $archive"
    set -- $versions; [ $# -eq 1 ] || die "-a needs exactly one -v (keyword or version number)"
    set -- $rids;     [ $# -eq 1 ] || die "-a needs exactly one -r runtime ID"
fi
# shellcheck disable=SC2086
if [ -n "$key_override" ]; then
    set -- $versions; [ $# -eq 1 ] || die "-k needs exactly one -v"
fi

# --- tools ------------------------------------------------------------------
fetch() { # url out
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "curl or wget is required to download"
    fi
}
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
is_version() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+){0,2}$'; }

# --- version resolution (same table as GetVsDbg.sh) ---------------------------
script_file=""
try_load_script() {
    [ -n "$script_file" ] && return 0
    if [ -f "$script_src" ]; then
        cp "$script_src" "$tmp/GetVsDbg.sh"
    else
        say "reading version table from $script_src"
        fetch "$script_src" "$tmp/GetVsDbg.sh" || return 1
    fi
    script_file="$tmp/GetVsDbg.sh"
}
load_script() {
    try_load_script || die "cannot download $script_src. Pass -v <version number> (and -k <key>), or -S <local copy of GetVsDbg.sh>"
}
# Prints the version GetVsDbg.sh assigns for keyword $1 in its case statement
# ("  latest)" followed by "__VsDbgVersion=18.7.10521.2"), or nothing.
script_version() {
    awk -v key="$1" '
        BEGIN { key = tolower(key) }
        {
            line = $0; sub(/^[ \t]+/, "", line)
            if (!found && line ~ /^[A-Za-z0-9_."|-]+\)/) {
                head = line; sub(/\).*$/, "", head); gsub(/"/, "", head)
                m = split(head, alts, "|")
                for (i = 1; i <= m; i++) if (tolower(alts[i]) == key) found = 1
            }
            if (found && line ~ /=/ && match(line, /[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)) { print substr(line, RSTART, RLENGTH); exit }
            if (found && line ~ /;;/) exit
        }' "$script_file"
}
resolve_version() { # keyword-or-number -> version number (call load_script first for keywords)
    if is_version "$1"; then echo "$1"; return 0; fi
    v=$(script_version "$1")
    if [ -z "$v" ]; then
        case " $LATEST_ALIASES " in
            *" $1 "*)
                v=$(script_version latest)
                [ -n "$v" ] && say "WARN: GetVsDbg.sh has no '$1' keyword, using 'latest' ($v) for it" >&2 ;;
        esac
    fi
    [ -n "$v" ] || die "GetVsDbg.sh does not define version keyword '$1'"
    echo "$v"
}
resolve_base_url() {
    [ -n "$base_url" ] && return 0
    base_url="$DEFAULT_BASE_URL"
    if try_load_script 2>/dev/null; then
        # the host in front of "/vsdbg-<version>/" in the download URL
        u=$(grep -Eo 'https?://[A-Za-z0-9.:-]+/vsdbg-' "$script_file" | head -n1 || true)
        [ -n "$u" ] && base_url="${u%/vsdbg-}"
    fi
}

# --- one key/rid --------------------------------------------------------------
write_sidecar() { # key rid version sha source
    cat > "$drop/$1/$2.json" <<EOF
{
  "key": "$1",
  "rid": "$2",
  "version": "$3",
  "sha256": "$4",
  "source": "$5",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

install_one() { # key version rid
    key="$1"; version="$2"; rid="$3"
    dest="$drop/$key/$rid"
    if [ "$force" -eq 0 ] && [ -z "$archive" ] && [ -f "$dest/success_version.txt" ] && [ -f "$dest/success_rid.txt" ] \
        && [ "$(cat "$dest/success_version.txt")" = "$version" ] && [ "$(cat "$dest/success_rid.txt")" = "$rid" ]; then
        say "$key/$rid: vsdbg $version already present, skipped (-f to refresh)"
        return 0
    fi
    case "$rid" in win*) ext=zip ;; *) ext=tar.gz ;; esac
    if [ -n "$archive" ]; then
        src="archive:$(basename "$archive")"
        pkg="$archive"
        say "$key/$rid: vsdbg $version from archive $archive"
    else
        resolve_base_url
        src="$base_url/vsdbg-$(echo "$version" | tr '.' '-')/vsdbg-$rid.$ext"
        pkg="$tmp/vsdbg-$rid.$ext"
        say "$key/$rid: downloading vsdbg $version from $src"
        fetch "$src" "$pkg" || die "download failed: $src"
    fi
    sum=$(sha256 "$pkg")
    stage="$drop/$key/.$rid.partial"
    rm -rf "$stage"; mkdir -p "$stage"
    case "$pkg" in
        *.zip) command -v unzip >/dev/null 2>&1 || die "unzip is required for $pkg"; unzip -q "$pkg" -d "$stage" ;;
        *)     tar -xzf "$pkg" -C "$stage" ;;
    esac
    # Some archives (or repacks) wrap everything in one folder: flatten it like the official layout.
    if [ ! -f "$stage/vsdbg" ] && [ ! -f "$stage/vsdbg.exe" ]; then
        inner=$(find "$stage" -mindepth 2 -maxdepth 3 \( -name vsdbg -o -name vsdbg.exe \) -type f | head -n1)
        [ -n "$inner" ] || die "$pkg does not contain vsdbg"
        idir=$(dirname "$inner")
        mv "$stage" "$stage.wrap" && mv "$stage.wrap/${idir#"$stage"/}" "$stage" && rm -rf "$stage.wrap"
    fi
    [ -f "$stage/vsdbg" ] && chmod +x "$stage/vsdbg"
    [ -f "$stage/vsdbg-ui" ] && chmod +x "$stage/vsdbg-ui"
    # GetVsDbg.sh writes these last; same contents (one line, trailing newline).
    echo "$rid" > "$stage/success_rid.txt"
    echo "$version" > "$stage/success_version.txt"
    rm -rf "$dest"; mv "$stage" "$dest"
    write_sidecar "$key" "$rid" "$version" "$sum" "$src"
    say "$key/$rid: vsdbg $version ready in $dest (sha256 $sum)"
}

write_manifest() {
    out="$drop/manifest.json"
    {
        echo "{"
        echo "  \"generator\": \"devsuite/vsdbg/Get-VsDbgOffline.sh\","
        echo "  \"entries\": ["
        first=1
        for f in "$drop"/*/*.json; do
            [ -f "$f" ] || continue
            [ $first -eq 1 ] || echo "    ,"
            first=0
            sed 's/^/    /' "$f"
        done
        echo "  ]"
        echo "}"
    } > "$out.tmp" && mv "$out.tmp" "$out"
    say "manifest: $out"
}

for v in $versions; do
    is_version "$v" || load_script
    version=$(resolve_version "$v")
    key="${key_override:-$v}"
    for rid in $rids; do
        install_one "$key" "$version" "$rid"
    done
done
write_manifest
