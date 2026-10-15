#!/usr/bin/env bash
# Runs every compose/labels fixture with `tilt alpha tiltfile-result`.
#
#   devsuite/tilt/tests/compose/run.sh [case ...]
#
# A case is a directory with a Tiltfile and an `expect` file. Each expect line:
#   exit <code>        tiltfile-result exit code (0 ok, 5 Tiltfile error)
#   log <text>         text must appear in the Tiltfile log
#   nolog <text>       text must not appear in the Tiltfile log
#   model <jq expr>    must be true on the model printed by harness.star
#   result <jq expr>   must be true on the tiltfile-result JSON (manifests)
# An optional `env` file holds KEY=VALUE lines exported for that case only.
# Requires: tilt, jq, docker compose (only the `config` subcommand, no daemon).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
  for d in */; do [ -f "$d/expect" ] && cases+=("${d%/}"); done
fi
pass=0; failed=()
for c in "${cases[@]}"; do
  out="$(mktemp -d)"
  (
    cd "$c"
    unset COMPOSE_PROFILES COMPOSE_PROJECT_NAME
    if [ -f env ]; then set -a; . ./env; set +a; fi
    tilt alpha tiltfile-result -v > "$out/result.json" 2> "$out/log.txt"
    echo $? > "$out/exit"
  )
  grep -o 'DEVSUITE_MODEL .*' "$out/log.txt" | head -1 | sed 's/^DEVSUITE_MODEL //' > "$out/model.json"
  ok=1; why=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    kind="${line%% *}"; arg="${line#* }"
    case "$kind" in
      exit)   [ "$(cat "$out/exit")" = "$arg" ] || { ok=0; why+=("exit $(cat "$out/exit") != $arg"); } ;;
      log)    grep -qF -- "$arg" "$out/log.txt" || { ok=0; why+=("missing log: $arg"); } ;;
      nolog)  grep -qF -- "$arg" "$out/log.txt" && { ok=0; why+=("unexpected log: $arg"); } ;;
      model)  [ "$(jq -r "$arg" "$out/model.json" 2>&1)" = "true" ] || { ok=0; why+=("model false: $arg"); } ;;
      result) [ "$(jq -r "$arg" "$out/result.json" 2>&1)" = "true" ] || { ok=0; why+=("result false: $arg"); } ;;
      *) ok=0; why+=("bad expect line: $line") ;;
    esac
  done < "$c/expect"
  if [ $ok = 1 ]; then
    echo "PASS $c"; pass=$((pass+1)); rm -rf "$out"
  else
    echo "FAIL $c"; for w in "${why[@]}"; do echo "     $w"; done
    echo "     log: $out/log.txt"; failed+=("$c")
  fi
done
echo "$pass passed, ${#failed[@]} failed"
[ ${#failed[@]} -eq 0 ]
