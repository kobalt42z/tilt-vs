# Shared helpers for Setup-PodmanMachine.ps1 and Test-DevSuite.ps1.
# Path mapping mirrors devsuite/tilt/podman.star (translate_source / map_path),
# so the doctor and the machine shares agree with what Tilt emits.

Set-StrictMode -Version Latest

$script:DefaultPathMap = [ordered]@{ 'X:\' = '/mnt/x/' }

function Get-DevSuiteRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Merge-DevSuiteHashtable {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Over)
    $out = [ordered]@{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    foreach ($k in $Over.Keys) {
        if ($Over[$k] -is [System.Collections.IDictionary] -and $out[$k] -is [System.Collections.IDictionary]) {
            $out[$k] = Merge-DevSuiteHashtable $out[$k] $Over[$k]
        } else {
            $out[$k] = $Over[$k]
        }
    }
    $out
}

function ConvertTo-DevSuiteHashtable {
    param($Value)
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-DevSuiteHashtable $p.Value }
        return $h
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-DevSuiteHashtable $_ })
    }
    $Value
}

function Get-DevSuiteSetting {
    <# devsuite.json + devsuite.local.json (later wins), podman section with defaults. #>
    param([string]$Root = (Get-DevSuiteRoot))
    $s = [ordered]@{
        compose_files = @('docker-compose.yml')
        compose_cmd   = 'docker compose'
        work_dir      = '.tilt'
        vsdbg         = [ordered]@{}
        podman        = [ordered]@{}
    }
    foreach ($name in 'devsuite.json', 'devsuite.local.json') {
        $f = Join-Path $Root $name
        if (Test-Path $f) {
            $s = Merge-DevSuiteHashtable $s (ConvertTo-DevSuiteHashtable (Get-Content $f -Raw | ConvertFrom-Json))
        }
    }
    $pmap = [ordered]@{}
    foreach ($k in $script:DefaultPathMap.Keys) { $pmap[$k] = $script:DefaultPathMap[$k] }
    if ($s.podman.Contains('path_map')) {
        foreach ($k in $s.podman.path_map.Keys) { $pmap[$k] = $s.podman.path_map[$k] }
    }
    $s.podman.path_map = $pmap
    $s
}

function Test-DevSuiteWindowsPath([string]$Path) {
    ($Path -match '^[A-Za-z]:([\\/]|$)') -or ($Path -match '^(\\\\|//)')
}

function Get-DevSuiteNormalizedPath {
    <# C:/a/./b/../c -> C:\a\c (pure string logic, no filesystem access). #>
    param([string]$Path)
    $unc = $Path -match '^(\\\\|//)'
    $parts = $Path.Replace('/', '\').Split('\')
    if ($unc) { $head = '\\' + (($parts | Select-Object -Skip 2 -First 2) -join '\'); $rest = $parts | Select-Object -Skip 4 }
    else { $head = $parts[0].ToUpperInvariant(); $rest = $parts | Select-Object -Skip 1 }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $rest) {
        if ($p -eq '' -or $p -eq '.') { continue }
        if ($p -eq '..') { if ($out.Count) { $out.RemoveAt($out.Count - 1) }; continue }
        $out.Add($p)
    }
    if ($unc -and -not $out.Count) { return $head }
    $head + '\' + ($out -join '\')
}

function Convert-DevSuitePath {
    <#
    .SYNOPSIS
    Maps an absolute Windows host path to the path the Podman machine sees.
    Returns $null when no path_map entry covers it.
    'X:\' is a wildcard for any drive; an 'x' segment in its value becomes the drive letter.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Collections.IDictionary]$PathMap = $script:DefaultPathMap
    )
    $p = Get-DevSuiteNormalizedPath $Path
    $probe = if ($p.EndsWith('\')) { $p } else { $p + '\' }
    $entries = foreach ($k in $PathMap.Keys) {
        $v = [string]$PathMap[$k]
        if (-not $v) { continue }
        $key = $k.Replace('/', '\')
        if (-not $key.EndsWith('\')) { $key += '\' }
        if (-not $v.EndsWith('/')) { $v += '/' }
        [pscustomobject]@{ Key = $key; Value = $v; Wild = ($key -eq 'X:\'); Len = $key.Length }
    }
    $sorted = @($entries | Where-Object { -not $_.Wild } | Sort-Object Len -Descending) + @($entries | Where-Object Wild)
    foreach ($e in $sorted) {
        if ($e.Wild) {
            if ($probe -notmatch '^[A-Za-z]:\\') { continue }
            $letter = $probe.Substring(0, 1).ToLowerInvariant()
            $value = ($e.Value.Split('/') | ForEach-Object { if ($_ -eq 'x') { $letter } else { $_ } }) -join '/'
            $rest = $probe.Substring(3)
        } elseif ($probe.StartsWith($e.Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = $e.Value
            $rest = $probe.Substring($e.Key.Length)
        } else { continue }
        $out = ($value + $rest.Replace('\', '/')).TrimEnd('/')
        if (-not $out) { return '/' }
        return $out
    }
    $null
}

function Write-DevSuiteCheck {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Name,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    $line = '[{0}] {1,-22} {2}' -f $Status, $Name, $Detail
    Write-Host $line -ForegroundColor $color
    if ($Fix -and $Status -in 'WARN', 'FAIL') { Write-Host ('       fix: ' + $Fix) -ForegroundColor $color }
    [pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail; Fix = $Fix }
}

function Invoke-DevSuiteNative {
    <# Runs a native command; returns @{ ExitCode; Output } and never throws. #>
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode = -1; Output = "$FilePath not found on PATH" }
    }
    $out = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n").Trim() }
}

function Set-DevSuiteUserEnv {
    <# Sets a variable for this process and persists it for the user. #>
    param([string]$Name, [AllowEmptyString()][string]$Value)
    if ($Value) { Set-Item -Path "Env:$Name" -Value $Value } else { Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue }
    if ($env:OS -eq 'Windows_NT') {
        $v = if ($Value) { $Value } else { $null }
        [Environment]::SetEnvironmentVariable($Name, $v, 'User')
    }
}

Export-ModuleMember -Function Get-DevSuiteRoot, Get-DevSuiteSetting, Test-DevSuiteWindowsPath, Get-DevSuiteNormalizedPath,
    Convert-DevSuitePath, Write-DevSuiteCheck, Invoke-DevSuiteNative, Set-DevSuiteUserEnv
