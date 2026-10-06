<#
.SYNOPSIS
    Packages vsdbg for air-gapped use. Run once on a CONNECTED machine.

.DESCRIPTION
    Mirrors Microsoft's GetVsDbg.sh (https://aka.ms/getvsdbgsh):
      * version keywords (latest, vs2022, ...) resolve to the version number the
        live GetVsDbg.sh resolves them to (the script is downloaded and parsed);
      * download URL  <base>/vsdbg-<version with . -> ->/vsdbg-<rid>.tar.gz (.zip for win-*);
      * layout        the archive is extracted as-is into the install folder;
      * markers       success_rid.txt / success_version.txt with the same contents,
                      so GetVsDbg.sh (and Visual Studio) treat the folder as installed.

    Output: <DropDir>/<key>/<rid>/        mounted into containers by devsuite/tilt/vsdbg.star
            <DropDir>/<key>/<rid>.json    sidecar: version, rid, sha256, source, date
            <DropDir>/manifest.json       all sidecars, regenerated on every run

    Same behaviour and options as Get-VsDbgOffline.sh. See docs/vsdbg.md.
    Owner: task C (vsdbg offline).

.PARAMETER Version
    Version keywords or numbers (default: vs2022, vs2026). Each one is a drop key.
.PARAMETER RuntimeId
    Runtime IDs (default: linux-x64, linux-musl-x64).
.PARAMETER DropDir
    Drop directory (default: <script dir>/drop).
.PARAMETER Key
    Drop key when -Version is a version number (default: the -Version value).
.PARAMETER FromArchive
    Use an already-downloaded vsdbg-<rid>.tar.gz/.zip (one -Version, one -RuntimeId).
.PARAMETER ScriptUrl
    GetVsDbg.sh URL or local path used for version resolution (default: https://aka.ms/getvsdbgsh).
.PARAMETER BaseUrl
    Download base URL (default: parsed from GetVsDbg.sh, else Microsoft's CDN). For internal mirrors.
.PARAMETER Force
    Re-download even when the markers say the folder is up to date.

.EXAMPLE
    ./devsuite/vsdbg/Get-VsDbgOffline.ps1
.EXAMPLE
    ./devsuite/vsdbg/Get-VsDbgOffline.ps1 -FromArchive C:\Downloads\vsdbg-linux-x64.tar.gz -RuntimeId linux-x64 -Version 18.7.10521.2 -Key vs2026
#>
[CmdletBinding()]
param(
    [string[]] $Version = @('vs2022', 'vs2026'),
    [string[]] $RuntimeId = @('linux-x64', 'linux-musl-x64'),
    [string] $DropDir = (Join-Path $PSScriptRoot 'drop'),
    [string] $Key = '',
    [string] $FromArchive = '',
    [string] $ScriptUrl = 'https://aka.ms/getvsdbgsh',
    [string] $BaseUrl = '',
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar

$DefaultBaseUrl = 'https://vsdebugger-cyg0dxb6czfafzaz.b01.azurefd.net'
$ValidRids = @('linux-x64', 'linux-musl-x64', 'linux-arm', 'linux-musl-arm', 'linux-arm64', 'linux-musl-arm64',
               'osx-x64', 'osx-arm64', 'win7-x64', 'win-x64', 'win-arm64')
# Keys VS uses that GetVsDbg.sh may not know yet: they resolve like "latest" (with a warning).
$LatestAliases = @('vs2026')

function Say([string] $msg) { Write-Host "[vsdbg-offline] $msg" }
function Die([string] $msg) { throw "[vsdbg-offline] ERROR: $msg" }
function Test-VersionNumber([string] $v) { return $v -match '^[0-9]+\.[0-9]+(\.[0-9]+){0,2}$' }

# Accept "a,b" as well as @('a','b') (handy from cmd / launchers).
$Version = @($Version | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$RuntimeId = @($RuntimeId | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

foreach ($rid in $RuntimeId) {
    if ($ValidRids -notcontains $rid) { Die "unknown runtime ID '$rid' (valid: $($ValidRids -join ' '))" }
}
if ($FromArchive) {
    if (-not (Test-Path -LiteralPath $FromArchive -PathType Leaf)) { Die "archive not found: $FromArchive" }
    if ($Version.Count -ne 1) { Die '-FromArchive needs exactly one -Version (keyword or version number)' }
    if ($RuntimeId.Count -ne 1) { Die '-FromArchive needs exactly one -RuntimeId' }
    $FromArchive = (Resolve-Path -LiteralPath $FromArchive).Path
}
if ($Key -and $Version.Count -ne 1) { Die '-Key needs exactly one -Version' }

New-Item -ItemType Directory -Force -Path $DropDir | Out-Null
$DropDir = (Resolve-Path -LiteralPath $DropDir).Path
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vsdbg-offline-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

# --- version resolution (same table as GetVsDbg.sh) ---------------------------
$script:ScriptText = $null
function Get-ScriptText([switch] $Quiet) {
    if ($null -ne $script:ScriptText) { return $script:ScriptText }
    try {
        if (Test-Path -LiteralPath $ScriptUrl -PathType Leaf) {
            $script:ScriptText = Get-Content -LiteralPath $ScriptUrl -Raw
        } else {
            Say "reading version table from $ScriptUrl"
            $script:ScriptText = (Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing).Content
            if ($script:ScriptText -is [byte[]]) { $script:ScriptText = [System.Text.Encoding]::UTF8.GetString($script:ScriptText) }
        }
    } catch {
        if ($Quiet) { return $null }
        Die "cannot download $ScriptUrl ($($_.Exception.Message)). Pass -Version <version number> (and -Key <key>), or -ScriptUrl <local copy of GetVsDbg.sh>"
    }
    return $script:ScriptText
}

# The version GetVsDbg.sh assigns for keyword $kw in its case statement
# ("  latest)" followed by "__VsDbgVersion=18.7.10521.2"), or $null.
function Get-ScriptVersion([string] $text, [string] $kw) {
    $found = $false
    foreach ($raw in ($text -split "`r?`n")) {
        $line = $raw.TrimStart()
        if (-not $found -and $line -match '^([A-Za-z0-9_."|-]+)\)') {
            $alts = $Matches[1].Replace('"', '') -split '\|'
            if ($alts | Where-Object { $_ -ieq $kw }) { $found = $true }
        }
        if ($found -and $line -match '=' -and $line -match '([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)') { return $Matches[1] }
        if ($found -and $line -match ';;') { return $null }
    }
    return $null
}

function Resolve-VsDbgVersion([string] $v) {
    if (Test-VersionNumber $v) { return $v }
    $text = Get-ScriptText
    $resolved = Get-ScriptVersion $text $v
    if (-not $resolved -and $LatestAliases -contains $v.ToLowerInvariant()) {
        $resolved = Get-ScriptVersion $text 'latest'
        if ($resolved) { Say "WARN: GetVsDbg.sh has no '$v' keyword, using 'latest' ($resolved) for it" }
    }
    if (-not $resolved) { Die "GetVsDbg.sh does not define version keyword '$v'" }
    return $resolved
}

function Resolve-BaseUrl {
    if ($BaseUrl) { return $BaseUrl.TrimEnd('/') }
    $text = Get-ScriptText -Quiet
    # the host in front of "/vsdbg-<version>/" in the download URL
    if ($text -and $text -match '(https?://[A-Za-z0-9.:-]+)/vsdbg-') { return $Matches[1] }
    return $DefaultBaseUrl
}

# --- one key/rid --------------------------------------------------------------
function Write-Utf8NoBom([string] $path, [string] $content) {
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Install-One([string] $k, [string] $ver, [string] $rid) {
    $dest = Join-Path (Join-Path $DropDir $k) $rid
    $vMarker = Join-Path $dest 'success_version.txt'
    $rMarker = Join-Path $dest 'success_rid.txt'
    if (-not $Force -and -not $FromArchive -and (Test-Path $vMarker) -and (Test-Path $rMarker) -and
        (Get-Content $vMarker -Raw).Trim() -eq $ver -and (Get-Content $rMarker -Raw).Trim() -eq $rid) {
        Say "$k/${rid}: vsdbg $ver already present, skipped (-Force to refresh)"
        return
    }
    $ext = if ($rid -like 'win*') { 'zip' } else { 'tar.gz' }
    if ($FromArchive) {
        $src = "archive:$(Split-Path -Leaf $FromArchive)"; $pkg = $FromArchive
        Say "$k/${rid}: vsdbg $ver from archive $FromArchive"
    } else {
        $src = "$(Resolve-BaseUrl)/vsdbg-$($ver.Replace('.', '-'))/vsdbg-$rid.$ext"
        $pkg = Join-Path $tmp "vsdbg-$rid.$ext"
        Say "$k/${rid}: downloading vsdbg $ver from $src"
        try { Invoke-WebRequest -Uri $src -OutFile $pkg -UseBasicParsing }
        catch { Die "download failed: $src ($($_.Exception.Message))" }
    }
    $sum = (Get-FileHash -Algorithm SHA256 -LiteralPath $pkg).Hash.ToLowerInvariant()

    $stage = Join-Path (Join-Path $DropDir $k) ".$rid.partial"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    if ($pkg -like '*.zip') {
        Expand-Archive -LiteralPath $pkg -DestinationPath $stage
    } else {
        # tar.exe ships with Windows 10 1803+ and every Linux/macOS.
        & tar -xzf $pkg -C $stage
        if ($LASTEXITCODE -ne 0) { Die "tar failed to extract $pkg" }
    }
    # Some archives (or repacks) wrap everything in one folder: flatten it like the official layout.
    if (-not (Test-Path (Join-Path $stage 'vsdbg')) -and -not (Test-Path (Join-Path $stage 'vsdbg.exe'))) {
        $inner = Get-ChildItem -LiteralPath $stage -Recurse -File -Depth 2 |
            Where-Object { $_.Name -in @('vsdbg', 'vsdbg.exe') } | Select-Object -First 1
        if (-not $inner) { Die "$pkg does not contain vsdbg" }
        $wrap = "$stage.wrap"
        Move-Item -LiteralPath $stage -Destination $wrap
        Move-Item -LiteralPath (Join-Path $wrap $inner.Directory.FullName.Substring($stage.Length + 1)) -Destination $stage
        Remove-Item -Recurse -Force $wrap
    }
    if ($env:OS -ne 'Windows_NT') {
        foreach ($exe in @('vsdbg', 'vsdbg-ui')) {
            $p = Join-Path $stage $exe
            if (Test-Path $p) { & chmod +x $p }
        }
    }
    # GetVsDbg.sh writes these last with `echo`: one line, LF, no BOM.
    Write-Utf8NoBom (Join-Path $stage 'success_rid.txt') "$rid`n"
    Write-Utf8NoBom (Join-Path $stage 'success_version.txt') "$ver`n"
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Move-Item -LiteralPath $stage -Destination $dest

    $sidecar = [ordered]@{
        key = $k; rid = $rid; version = $ver; sha256 = $sum; source = $src
        date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    Write-Utf8NoBom (Join-Path (Join-Path $DropDir $k) "$rid.json") (($sidecar | ConvertTo-Json) + "`n")
    Say "$k/${rid}: vsdbg $ver ready in $dest (sha256 $sum)"
}

function Write-Manifest {
    $entries = @(Get-ChildItem -LiteralPath $DropDir -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        }
    })
    $manifest = [ordered]@{ generator = 'devsuite/vsdbg/Get-VsDbgOffline.ps1'; entries = $entries }
    $out = Join-Path $DropDir 'manifest.json'
    Write-Utf8NoBom $out (($manifest | ConvertTo-Json -Depth 5) + "`n")
    Say "manifest: $out"
}

try {
    foreach ($v in $Version) {
        $ver = Resolve-VsDbgVersion $v
        $k = if ($Key) { $Key } else { $v }
        foreach ($rid in $RuntimeId) { Install-One $k $ver $rid }
    }
    Write-Manifest
    if ($env:OS -eq 'Windows_NT') {
        Write-Host ''
        Say 'Windows checkouts: keep the exec bit when committing the drop (core.fileMode is off on Windows):'
        Say '  git add devsuite/vsdbg/drop; git add --chmod=+x ''devsuite/vsdbg/drop/*/vsdbg'''
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
