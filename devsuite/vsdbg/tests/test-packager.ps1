# Offline test for Get-VsDbgOffline.ps1: version table parsing, download path
# (local HTTP listener), FromArchive, markers, manifest, no-op re-run.
# Usage: pwsh devsuite/vsdbg/tests/test-packager.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pkg = Join-Path $PSScriptRoot '..' 'Get-VsDbgOffline.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("vsdbg-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
function Fail([string] $m) { throw "FAIL: $m" }

# fake vsdbg archives served like the CDN: /vsdbg-<dashed version>/vsdbg-<rid>.tar.gz
function New-Archive([string] $ver, [string] $rid, [string] $out) {
    $d = Join-Path $work "src-$rid"
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    New-Item -ItemType Directory -Path $d | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $d 'vsdbg'), "#!/bin/sh`necho `"fake vsdbg $ver $rid`"`n")
    & tar -czf $out -C $d .
    if ($LASTEXITCODE -ne 0) { Fail "tar" }
}
$www = Join-Path $work 'www'
foreach ($v in @('18.7.10521.2', '17.14.10519.1')) {
    $dir = Join-Path $www "vsdbg-$($v.Replace('.', '-'))"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($rid in @('linux-x64', 'linux-musl-x64')) { New-Archive $v $rid (Join-Path $dir "vsdbg-$rid.tar.gz") }
}

$port = Get-Random -Minimum 20000 -Maximum 40000
(Get-Content (Join-Path $PSScriptRoot 'GetVsDbg.fixture.sh') -Raw).Replace('__PORT__', "$port") |
    Set-Content -NoNewline (Join-Path $work 'GetVsDbg.sh')

# minimal static file server on a background runspace
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
$ps = [powershell]::Create().AddScript({
    param($listener, $root)
    while ($listener.IsListening) {
        try { $c = $listener.GetContext() } catch { break }
        $path = Join-Path $root ($c.Request.Url.AbsolutePath.TrimStart('/'))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $c.Response.ContentLength64 = $bytes.Length
            $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else { $c.Response.StatusCode = 404 }
        $c.Response.Close()
    }
}).AddArgument($listener).AddArgument($www)
$null = $ps.BeginInvoke()

try {
    $drop = Join-Path $work 'drop'
    $gs = Join-Path $work 'GetVsDbg.sh'
    & $pkg -ScriptUrl $gs -DropDir $drop -Version vs2022, vs2026 -RuntimeId linux-x64, linux-musl-x64
    foreach ($key in @('vs2022', 'vs2026')) { foreach ($rid in @('linux-x64', 'linux-musl-x64')) {
        $d = Join-Path $drop $key $rid
        if (-not (Test-Path (Join-Path $d 'vsdbg'))) { Fail "$d/vsdbg missing" }
        if ([System.IO.File]::ReadAllText((Join-Path $d 'success_rid.txt')) -ne "$rid`n") { Fail "$d success_rid.txt" }
        if (-not (Test-Path (Join-Path $drop $key "$rid.json"))) { Fail "$key/$rid.json sidecar" }
    } }
    if ((Get-Content (Join-Path $drop 'vs2022' 'linux-x64' 'success_version.txt') -Raw) -ne "17.14.10519.1`n") { Fail 'vs2022 version' }
    if ((Get-Content (Join-Path $drop 'vs2026' 'linux-x64' 'success_version.txt') -Raw) -ne "18.7.10521.2`n") { Fail 'vs2026 -> latest alias' }
    $m = Get-Content (Join-Path $drop 'manifest.json') -Raw | ConvertFrom-Json
    if (@($m.entries).Count -ne 4) { Fail 'manifest entries' }
    if (-not (@($m.entries) | Where-Object { $_.source -eq "http://127.0.0.1:$port/vsdbg-18-7-10521-2/vsdbg-linux-musl-x64.tar.gz" })) { Fail 'manifest source url' }
    if ($env:OS -ne 'Windows_NT') {
        $out = & (Join-Path $drop 'vs2026' 'linux-x64' 'vsdbg')
        if ($out -ne 'fake vsdbg 18.7.10521.2 linux-x64') { Fail "extracted content: $out" }
    }

    $out = & $pkg -ScriptUrl $gs -DropDir $drop -Version vs2022 -RuntimeId linux-x64 6>&1 | Out-String
    if ($out -notmatch 'already present') { Fail "no-op re-run: $out" }

    $local = Join-Path $work 'local.tar.gz'
    New-Archive '17.0.1.1' 'linux-x64' $local
    & $pkg -DropDir $drop -FromArchive $local -Version 17.0.1.1 -Key vs2022 -RuntimeId linux-x64
    if ((Get-Content (Join-Path $drop 'vs2022' 'linux-x64' 'success_version.txt') -Raw) -ne "17.0.1.1`n") { Fail 'archive version marker' }

    $threw = $false
    try { & $pkg -DropDir $drop -ScriptUrl $gs -Version vs1999 -RuntimeId linux-x64 } catch {
        $threw = $true
        if ("$_" -notmatch "does not define version keyword 'vs1999'") { Fail "unknown keyword message: $_" }
    }
    if (-not $threw) { Fail 'unknown keyword accepted' }
    $threw = $false
    try { & $pkg -DropDir $drop -Version 1.2.3 -RuntimeId linux-x86 } catch { $threw = $true }
    if (-not $threw) { Fail 'bad rid accepted' }

    Write-Host 'OK: Get-VsDbgOffline.ps1'
} finally {
    $listener.Stop(); $listener.Close(); $ps.Dispose()
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
