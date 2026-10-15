#!/usr/bin/env sh
# End-to-end check of podman.star on a Linux Docker engine:
#   - preflight sees a (faked) Podman engine -> DOCKER_BUILDKIT=0
#   - translate=true + path_map ./host -> ./vm rewrites the original compose bind
#   - tilt ci goes green only if the container sees vm/marker
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
cat > devsuite.local.json <<JSON
{"podman": {"probe_cmd": "cat podman-version.json", "translate": true,
            "path_map": {"$here/host/": "$here/vm/"}}}
JSON
trap 'tilt down >/dev/null 2>&1 || true; rm -f devsuite.local.json' EXIT
tilt ci --port 0 "$@"
docker inspect "$(docker compose -p e2e ps -q probe 2>/dev/null || true)" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null || true
