#!/usr/bin/env bash
# Runs the Tiltfile.extend / docker / custom fixtures (task D).
#
#   ./run.sh            evaluate every fixture with `tilt alpha tiltfile-result`
#   ./run.sh --ci       also run `tilt ci` on custom-extend-fn and custom-no-extend
#                       (needs a Docker engine; builds tiny alpine images)
#   ./run.sh NAME...    only these fixtures
#
# Each fixture dir has an `expect` file, one check per line:
#   exit N                 tiltfile-result exit code (0 ok, 5 Tiltfile error)
#   contains TEXT          TEXT appears in the Tiltfile log
#   absent TEXT            TEXT does not appear in the Tiltfile log
#   build SVC tilt|compose|none   who builds SVC's image
#   resource NAME          a Tilt resource NAME exists
#   detail SVC KEY JSON    SVC's Tilt image build has KEY == JSON (missing false/null counts as false/null)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
ci=0
names=()
for a in "$@"; do
  case "$a" in
    --ci) ci=1 ;;
    *) names+=("$a") ;;
  esac
done
if [ ${#names[@]} -eq 0 ]; then
  for d in "$here"/*/; do
    [ -f "$d/expect" ] && names+=("$(basename "$d")")
  done
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

for name in "${names[@]}"; do
  dir="$here/$name"
  (cd "$dir" && tilt alpha tiltfile-result -v > "$tmp/$name.json" 2> "$tmp/$name.log")
  code=$?
  if python3 -I - "$dir/expect" "$tmp/$name.json" "$tmp/$name.log" "$code" <<'PY'
import json, sys
expect, result, logf, code = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
log = open(logf, encoding="utf-8").read()
try:
    res = json.load(open(result, encoding="utf-8"))
except Exception:
    res = {"Manifests": []}
manifests = {m["Name"]: m for m in (res.get("Manifests") or [])}
errors = []
def builder(svc):
    m = manifests.get(svc)
    if m is None:
        return None, "missing"
    targets = m.get("ImageTargets") or []
    if not targets:
        return None, "none"
    d = targets[0].get("BuildDetails") or {}
    return d, ("compose" if "Service" in d else "tilt")
for raw in open(expect, encoding="utf-8").read().splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    op, _, arg = line.partition(" ")
    if op == "exit":
        if code != int(arg):
            errors.append("exit code %d, expected %s" % (code, arg))
    elif op == "contains":
        if arg not in log:
            errors.append("log does not contain: %s" % arg)
    elif op == "absent":
        if arg in log:
            errors.append("log contains: %s" % arg)
    elif op == "build":
        svc, want = arg.split()
        _, got = builder(svc)
        if got != want:
            errors.append("build %s: got %s, expected %s" % (svc, got, want))
    elif op == "resource":
        if arg not in manifests:
            errors.append("no resource %s" % arg)
    elif op == "detail":
        svc, key, want = arg.split(" ", 2)
        d, _ = builder(svc)
        want = json.loads(want)
        got = (d or {}).get(key, False if want is False else None)
        if got != want:
            errors.append("detail %s %s: got %r, expected %r" % (svc, key, got, want))
    else:
        errors.append("unknown check: %s" % line)
for e in errors:
    print("    " + e)
sys.exit(1 if errors else 0)
PY
  then
    echo "ok   $name"
  else
    echo "FAIL $name (log below)"
    grep -E '^\[devsuite\]|Error|rror in' "$tmp/$name.log" | sed 's/^/    | /'
    failed=1
  fi
done

if [ $ci -eq 1 ]; then
  for name in custom-extend-fn custom-no-extend; do
    dir="$here/$name"
    echo "...  tilt ci $name"
    # start from no image so the check below proves who built it
    docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^extfix-(web|api):' | xargs -r docker image rm -f > /dev/null 2>&1
    if (cd "$dir" && timeout 600 tilt ci --port 0 > "$tmp/ci-$name.log" 2>&1); then
      echo "ok   tilt ci $name"
    else
      echo "FAIL tilt ci $name"; tail -30 "$tmp/ci-$name.log" | sed 's/^/    | /'; failed=1
    fi
    if [ "$name" = custom-no-extend ]; then
      # compose (not Tilt) built the custom image
      # Tilt tags its builds extfix-web:tilt-<hash>; compose tags extfix-web:latest
      if docker image inspect extfix-web:latest > /dev/null 2>&1 \
         && ! docker image ls --format '{{.Tag}}' extfix-web | grep -q '^tilt-'; then
        echo "ok   compose built extfix-web"
      else
        echo "FAIL compose did not build extfix-web"; grep -i -E 'web' "$tmp/ci-$name.log" | tail -20 | sed 's/^/    | /'; failed=1
      fi
    fi
    (cd "$dir" && tilt down > /dev/null 2>&1)
  done
fi
exit $failed
