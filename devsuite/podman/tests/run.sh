#!/usr/bin/env sh
# Evaluates the podman.star fixtures; exits non-zero on any failure.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(tilt alpha tiltfile-result -v -f "$here/Tiltfile" 2>&1 >/dev/null) || { echo "$out"; exit 1; }
echo "$out" | grep "podman fixtures"
