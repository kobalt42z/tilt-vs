#!/usr/bin/env sh
# Copies a host folder into a named volume through the engine API (docker cp),
# so the container sees it on the engine's own Linux filesystem: exec bits and
# file locks work, unlike a 9p bind mount from a Podman Hyper-V machine.
# Used by devsuite/tilt/podman.star (copy mode, docs/podman-hyperv.md section 5).
#
#   seed-volume.sh <volume> <host folder> <helper image> [container cli]
#
# The helper image only needs `sh`, `find` and `chmod`; it is never pulled.
set -eu
vol=$1
src=$2
img=$3
cli=${4:-docker}

[ -d "$src" ] || { echo "seed: $src is not a folder" >&2; exit 1; }
$cli volume inspect "$vol" >/dev/null 2>&1 || $cli volume create --label devsuite.seed=true "$vol" >/dev/null
# empty it first so files deleted on the host disappear from the volume too
$cli run --rm --pull=never --user 0 --entrypoint sh -v "$vol:/dst" "$img" -c 'find /dst -mindepth 1 -delete'
cid=$($cli create --pull=never --user 0 --entrypoint sh -v "$vol:/dst" "$img")
trap '$cli rm -f "$cid" >/dev/null 2>&1 || true' EXIT
$cli cp "$src/." "$cid:/dst"
# readable (and traversable) by any user; keep exec bits already set
$cli run --rm --pull=never --user 0 --entrypoint sh -v "$vol:/dst" "$img" -c 'chmod -R a+rX /dst'
echo "seed: $src -> volume $vol ($(find "$src" -type f | wc -l | tr -d ' ') file(s))"
