# Smoke test for the sample stack (Windows). Same checks as smoke.sh.
$ErrorActionPreference = 'Stop'
$orders  = if ($env:ORDERS_URL)  { $env:ORDERS_URL }  else { 'http://localhost:5080' }
$catalog = if ($env:CATALOG_URL) { $env:CATALOG_URL } else { 'http://localhost:5081' }
$web     = if ($env:WEB_URL)     { $env:WEB_URL }     else { 'http://localhost:5082' }

function Test-Endpoint([string]$Name, [string]$Url, [string]$Expect) {
    $body = ''
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $body = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5).Content
            if ($body -like "*$Expect*") { Write-Host "ok   ${Name}: $Url"; return }
        } catch { $body = $_.Exception.Message }
        Start-Sleep -Seconds 2
    }
    Write-Host "FAIL ${Name}: $Url did not return '$Expect' (last body: $body)"
    exit 1
}

Test-Endpoint 'catalog health'  "$catalog/health" '"service":"catalog-api"'
Test-Endpoint 'orders health'   "$orders/health"  '"service":"orders-api"'
Test-Endpoint 'orders->catalog' "$orders/orders"  '"name":"Keyboard"'
Test-Endpoint 'orders->db'      "$orders/db"      '"reachable":true'
Test-Endpoint 'web (custom)'    "$web/"           'web-marker-'
Write-Host 'smoke: all checks passed'
