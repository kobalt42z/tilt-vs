#!/bin/sh
# devsuite: local `dotnet publish` for one service (run by the <svc>-dotnet Tilt resource).
#
#   publish.sh <csproj> <configuration> <staging dir> <publish dir> <artifacts dir> [extra publish args...]
#
# 1. dotnet publish into <staging dir> (framework-dependent, no apphost), with all
#    intermediate output under <artifacts dir> so it never touches the obj/ and
#    bin/ folders Visual Studio uses.
# 2. Only when publish succeeds: mirror <staging dir> into <publish dir> by content,
#    one atomic rename per changed file, and delete files that disappeared.
#    Tilt live_update syncs <publish dir>, so it only ever sees complete files and
#    only the files that really changed.
# Windows twin: publish.ps1 (keep both in step).
set -euf

if [ $# -lt 5 ]; then
  echo "usage: $0 <csproj> <configuration> <staging> <publish> <artifacts> [args...]" >&2
  exit 2
fi
csproj=$1; configuration=$2; staging=$3; publish=$4; artifacts=$5
shift 5

mkdir -p "$staging" "$publish"
echo "[devsuite] dotnet publish $csproj -c $configuration"
# an empty <artifacts dir> means "do not isolate intermediates" (settings dotnet.isolate_intermediates)
if [ -n "$artifacts" ]; then
  set -- --artifacts-path "$artifacts" "$@"
fi
dotnet publish "$csproj" -c "$configuration" -o "$staging" \
  --no-self-contained -p:UseAppHost=false -nologo "$@"

swap="$staging.swap"
changed=0
removed=0
files=$(cd "$staging" && find . -type f)
old_ifs=$IFS
IFS='
'
for f in $files; do
  f=${f#./}
  if ! cmp -s "$staging/$f" "$publish/$f"; then
    mkdir -p "$(dirname "$publish/$f")"
    cp -p "$staging/$f" "$swap"
    mv -f "$swap" "$publish/$f"
    changed=$((changed + 1))
  fi
done
for f in $(cd "$publish" && find . -type f); do
  f=${f#./}
  if [ ! -e "$staging/$f" ]; then
    rm -f "$publish/$f"
    removed=$((removed + 1))
  fi
done
IFS=$old_ifs
echo "[devsuite] publish ok: $changed file(s) updated, $removed removed in $publish"
