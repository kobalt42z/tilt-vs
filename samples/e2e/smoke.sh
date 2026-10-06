#!/bin/sh
# Smoke test for the sample stack. Run by the "e2e-smoke" resource from
# Tiltfile.extend once every service is up; also runnable by hand.
set -eu
ORDERS=${ORDERS_URL:-http://localhost:5080}
CATALOG=${CATALOG_URL:-http://localhost:5081}
WEB=${WEB_URL:-http://localhost:5082}

check() {
  name=$1; url=$2; expect=$3
  i=0
  while :; do
    body=$(curl -fsS --max-time 5 "$url" 2>/dev/null) && case "$body" in *"$expect"*) break ;; esac
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      echo "FAIL $name: $url did not return '$expect' (last body: ${body:-<none>})"
      exit 1
    fi
    sleep 2
  done
  echo "ok   $name: $url"
}

check "catalog health"   "$CATALOG/health"     '"service":"catalog-api"'
check "orders health"    "$ORDERS/health"      '"service":"orders-api"'
check "orders->catalog"  "$ORDERS/orders"      '"name":"Keyboard"'
check "orders->db"       "$ORDERS/db"          '"reachable":true'
check "web (custom)"     "$WEB/"               'web-marker-'
echo "smoke: all checks passed"
