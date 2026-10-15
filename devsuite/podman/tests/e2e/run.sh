#!/usr/bin/env sh
# End-to-end check of podman.star on a Linux Docker engine:
#   - preflight sees a (faked) Podman engine -> DOCKER_BUILDKIT=0
#   - translate=true + path_map ./host -> ./vm rewrites the original compose bind
#   - tilt ci goes green only if the container sees vm/marker
#   - copy=true seeds ./host/tools into a named volume for `copied`
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
cat > devsuite.local.json <<JSON
{"podman": {"probe_cmd": "cat podman-version.json", "translate": true,
            "copy": true, "copy_image": "alpine:3.20",
            "path_map": {"$here/host/": "$here/vm/"}}}
JSON
trap 'tilt down >/dev/null 2>&1 || true; rm -f devsuite.local.json' EXIT
tilt ci --port 0 "$@"
for svc in probe copied; do
docker inspect "$(docker compose -p e2e ps -q $svc 2>/dev/null || true)" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null || true
done
