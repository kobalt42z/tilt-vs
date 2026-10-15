#!/bin/sh
# Offline test for Get-VsDbgOffline.sh: version table parsing, download path
# (local HTTP server), FromArchive, markers, manifest, no-op re-run.
# Usage: sh devsuite/vsdbg/tests/test-packager.sh   (needs python3 for the HTTP server)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
pkg="$here/../Get-VsDbgOffline.sh"
work=$(mktemp -d)
port=$((20000 + $$ % 20000))
cleanup() { [ -n "${srv:-}" ] && kill "$srv" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

# fake vsdbg archives served like the CDN: /vsdbg-<dashed version>/vsdbg-<rid>.tar.gz
mk_archive() { # version rid out
    d="$work/src-$2"; rm -rf "$d"; mkdir -p "$d"
    printf '#!/bin/sh\necho "fake vsdbg %s %s"\n' "$1" "$2" > "$d/vsdbg"; chmod +x "$d/vsdbg"
    echo "$1" > "$d/version.txt"
    tar -czf "$3" -C "$d" .
}
for v in 18.7.10521.2 17.14.10519.1; do
    dv=$(echo $v | tr . -); mkdir -p "$work/www/vsdbg-$dv"
    for rid in linux-x64 linux-musl-x64; do mk_archive $v $rid "$work/www/vsdbg-$dv/vsdbg-$rid.tar.gz"; done
done
sed "s/__PORT__/$port/" "$here/GetVsDbg.fixture.sh" > "$work/GetVsDbg.sh"
(cd "$work/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & srv=$!
i=0; until python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:$port/')" 2>/dev/null; do i=$((i+1)); [ $i -lt 50 ] || fail "http server"; sleep 0.1; done

drop="$work/drop"
sh "$pkg" -S "$work/GetVsDbg.sh" -l "$drop" -v vs2022,vs2026 -r linux-x64,linux-musl-x64 > "$work/out1" 2>&1 || { cat "$work/out1"; fail "download run"; }
cat "$work/out1"
for key in vs2022 vs2026; do for rid in linux-x64 linux-musl-x64; do
    d="$drop/$key/$rid"
    [ -x "$d/vsdbg" ] || fail "$d/vsdbg not executable"
    [ "$(cat "$d/success_rid.txt")" = "$rid" ] || fail "$d success_rid.txt"
    [ -f "$drop/$key/$rid.json" ] || fail "$key/$rid.json sidecar"
done; done
[ "$(cat "$drop/vs2022/linux-x64/success_version.txt")" = "17.14.10519.1" ] || fail "vs2022 version"
[ "$(cat "$drop/vs2026/linux-x64/success_version.txt")" = "18.7.10521.2" ] || fail "vs2026 -> latest alias"
grep -q "127.0.0.1:$port/vsdbg-18-7-10521-2/vsdbg-linux-musl-x64.tar.gz" "$drop/manifest.json" || fail "manifest source url"
"$drop/vs2026/linux-x64/vsdbg" | grep -q "fake vsdbg 18.7.10521.2 linux-x64" || fail "extracted content"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['entries'])==4, d" "$drop/manifest.json" || fail "manifest json"

# second run is a no-op (markers match)
sh "$pkg" -S "$work/GetVsDbg.sh" -l "$drop" -v vs2022 -r linux-x64 > "$work/out2" 2>&1
grep -q "already present" "$work/out2" || { cat "$work/out2"; fail "no-op re-run"; }

# FromArchive with an explicit version number and key
mk_archive 17.0.1.1 linux-x64 "$work/local.tar.gz"
sh "$pkg" -l "$drop" -a "$work/local.tar.gz" -v 17.0.1.1 -k vs2022 -r linux-x64 > "$work/out3" 2>&1 || { cat "$work/out3"; fail "from archive"; }
[ "$(cat "$drop/vs2022/linux-x64/success_version.txt")" = "17.0.1.1" ] || fail "archive version marker"

# bad input fails clearly
if sh "$pkg" -l "$drop" -S "$work/GetVsDbg.sh" -v vs1999 -r linux-x64 > "$work/out4" 2>&1; then fail "unknown keyword accepted"; fi
grep -q "does not define version keyword 'vs1999'" "$work/out4" || { cat "$work/out4"; fail "unknown keyword message"; }
if sh "$pkg" -l "$drop" -v 1.2.3 -r linux-x86 > "$work/out5" 2>&1; then fail "bad rid accepted"; fi

echo "OK: Get-VsDbgOffline.sh"
