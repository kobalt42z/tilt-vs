<#
.SYNOPSIS
devsuite doctor: checks everything `tilt up` needs on a Windows + Podman
(Hyper-V) machine and says how to fix what is missing.

.DESCRIPTION
Checks, in order: tilt, .NET SDK, podman, docker CLI, compose v2 CLI, the
Podman machine (Hyper-V, rootful, running), user environment, the Docker API
pipe, a bind-mount round trip through podman.path_map, the vsdbg drop, and
that every image the stack needs is already present locally (air-gapped).
No admin rights needed. Exit code 0 = no FAIL, 1 = at least one FAIL.

.EXAMPLE
.\devsuite\podman\Test-DevSuite.ps1
.EXAMPLE
.\devsuite\podman\Test-DevSuite.ps1 -ProbeImage alpine:3.20 -Verbose
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$MachineName = 'podman-machine-default',
    # Image used for the bind-mount round trip (needs `cat`). Default: first stack image present locally.
    [string]$ProbeImage = '',
    [switch]$SkipRoundTrip
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevSuite.Podman.psm1') -Force
if (-not $Root) { $Root = Get-DevSuiteRoot }
$settings = Get-DevSuiteSetting $Root
$pathMap = $settings.podman.path_map
$onWindows = $env:OS -eq 'Windows_NT'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Check { param($Status, $Name, $Detail = '', $Fix = '') $results.Add((Write-DevSuiteCheck $Status $Name $Detail $Fix)) }

Write-Host "devsuite doctor  root=$Root" -ForegroundColor Cyan

# --- tools ----------------------------------------------------------------------
$r = Invoke-DevSuiteNative tilt @('version')
if ($r.ExitCode -eq 0) { Add-Check PASS 'tilt' $r.Output } else { Add-Check FAIL 'tilt' $r.Output 'install tilt.exe (>= 0.35) on PATH or in tools\' }

$r = Invoke-DevSuiteNative dotnet @('--list-sdks')
if ($r.ExitCode -eq 0 -and $r.Output) {
    $sdks = @($r.Output -split "`n" | ForEach-Object { ($_ -split ' ')[0] })
    if ($sdks | Where-Object { $_ -like '10.*' }) { Add-Check PASS 'dotnet SDK' ($sdks -join ', ') }
    else { Add-Check WARN 'dotnet SDK' ($sdks -join ', ') 'install the .NET 10 SDK (ships with VS 2026)' }
} else { Add-Check FAIL 'dotnet SDK' $r.Output 'install the .NET 10 SDK' }

$r = Invoke-DevSuiteNative podman @('--version')
$havePodman = $r.ExitCode -eq 0
if ($havePodman) { Add-Check PASS 'podman' $r.Output } else { Add-Check FAIL 'podman' $r.Output 'install Podman for Windows 5.x' }

$haveDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
if ($haveDocker) { Add-Check PASS 'docker CLI' (Invoke-DevSuiteNative docker @('--version')).Output }
else { Add-Check WARN 'docker CLI' 'not found; Tilt preflight probes the engine with it' 'put a docker.exe client on PATH, or set podman.probe_cmd in devsuite.json' }

$composeCmd = @($settings.compose_cmd -split ' ')
$r = Invoke-DevSuiteNative $composeCmd[0] (@($composeCmd | Select-Object -Skip 1) + @('version', '--short'))
if ($r.ExitCode -eq 0 -and $r.Output -match '^v?2\.|^v?[3-9]\.') { Add-Check PASS 'compose' "$($settings.compose_cmd) $($r.Output)" }
elseif ($r.ExitCode -eq 0) { Add-Check FAIL 'compose' "$($settings.compose_cmd) $($r.Output)" 'Tilt needs compose v2 (docker-compose.exe v2 from Podman Desktop, or the docker compose plugin)' }
else { Add-Check FAIL 'compose' $r.Output "install docker-compose v2 or change compose_cmd in devsuite.json" }

# --- machine --------------------------------------------------------------------------
$machineOk = $false
if ($havePodman -and $onWindows) {
    $r = Invoke-DevSuiteNative podman @('machine', 'inspect', $MachineName)
    if ($r.ExitCode -ne 0) {
        Add-Check FAIL 'podman machine' "$MachineName not found" 'run devsuite\podman\Setup-PodmanMachine.ps1 from an elevated PowerShell'
    } else {
        $m = @($r.Output | ConvertFrom-Json)[0]
        $props = $m.PSObject.Properties.Name
        $state = if ($props -contains 'State') { $m.State } else { '?' }
        $vmType = if ($props -contains 'VMType') { $m.VMType } elseif ($props -contains 'ConfigDir') { "$($m.ConfigDir.Path)" } else { '?' }
        $rootful = ($props -contains 'Rootful') -and $m.Rootful
        if ($state -eq 'running') { Add-Check PASS 'machine state' "$MachineName running"; $machineOk = $true }
        else { Add-Check FAIL 'machine state' "$MachineName is $state" "podman machine start $MachineName (elevated shell for Hyper-V)" }
        if ("$vmType" -match 'hyperv') { Add-Check PASS 'machine provider' 'hyperv' }
        else { Add-Check WARN 'machine provider' "$vmType" 'set CONTAINERS_MACHINE_PROVIDER=hyperv and re-run Setup-PodmanMachine.ps1 -Recreate' }
        if ($rootful) { Add-Check PASS 'machine rootful' 'yes' } else { Add-Check WARN 'machine rootful' 'no' "podman machine stop; podman machine set --rootful $MachineName" }
        if ($props -contains 'Mounts' -and $m.Mounts) {
            Add-Check INFO 'machine shares' ((@($m.Mounts) | ForEach-Object { "$($_.Source) -> $($_.Target)" }) -join '; ')
        }
    }
} elseif (-not $onWindows) {
    Add-Check INFO 'podman machine' 'not Windows: machine checks skipped'
}

# --- environment ----------------------------------------------------------------------
if ($onWindows) {
    if ($env:CONTAINERS_MACHINE_PROVIDER -eq 'hyperv') { Add-Check PASS 'CONTAINERS_MACHINE_PROVIDER' 'hyperv' }
    else { Add-Check WARN 'CONTAINERS_MACHINE_PROVIDER' "'$env:CONTAINERS_MACHINE_PROVIDER'" 'setx CONTAINERS_MACHINE_PROVIDER hyperv (Setup-PodmanMachine.ps1 does)' }
}
if ($env:DOCKER_BUILDKIT -eq '0') { Add-Check PASS 'DOCKER_BUILDKIT' '0' }
else { Add-Check INFO 'DOCKER_BUILDKIT' "'$env:DOCKER_BUILDKIT' (Tilt preflight sets 0 on Podman; set it for the user to cover manual compose runs)" }

# --- Docker API -------------------------------------------------------------------------
$apiOk = $false
if ($onWindows) {
    $endpoint = if ($env:DOCKER_HOST) { $env:DOCKER_HOST } else { 'npipe:////./pipe/docker_engine' }
    if ($endpoint -match '^npipe:////\./pipe/(.+)$') {
        $pipeName = $Matches[1]
        if (Test-Path "\\.\pipe\$pipeName") { Add-Check PASS 'API pipe' "\\.\pipe\$pipeName" }
        else { Add-Check FAIL 'API pipe' "\\.\pipe\$pipeName missing" 'start the machine; if Docker Desktop owns docker_engine, set DOCKER_HOST=npipe:////./pipe/podman-machine-default' }
    } else { Add-Check INFO 'API endpoint' $endpoint }
}
if ($haveDocker) {
    $r = Invoke-DevSuiteNative docker @('version', '--format', '{{json .Server}}')
    $json = ($r.Output -split "`n" | Where-Object { $_.StartsWith('{') } | Select-Object -Last 1)
    if ($r.ExitCode -eq 0 -and $json) {
        $srv = $json | ConvertFrom-Json
        $names = @($srv.Platform.Name) + @($srv.Components | ForEach-Object { $_.Name })
        $isPodman = [bool]($names | Where-Object { $_ -match 'podman' })
        $apiOk = $true
        Add-Check ($(if ($isPodman) { 'PASS' } else { 'WARN' })) 'engine' "$($srv.Version) API $($srv.ApiVersion) ($($names -join ', '))" 'DOCKER_HOST points at a non-Podman engine (Docker Desktop?)'
    } else { Add-Check FAIL 'engine' (($r.Output -split "`n")[-1]) 'podman machine start; then re-run this doctor' }
}

# --- bind mount round trip -------------------------------------------------------------
$images = [System.Collections.Generic.List[string]]::new()
$buildStageImages = [System.Collections.Generic.List[string]]::new()
$composeFiles = @($settings.compose_files | ForEach-Object { Join-Path $Root $_ })
$composeArgs = @($composeCmd | Select-Object -Skip 1) + @($composeFiles | ForEach-Object { '-f'; $_ }) + @('config', '--format', 'json')
$cfg = Invoke-DevSuiteNative $composeCmd[0] $composeArgs
$model = $null
if ($cfg.ExitCode -eq 0) { try { $model = $cfg.Output | ConvertFrom-Json } catch { $model = $null } }
if ($model) {
    foreach ($svc in $model.services.PSObject.Properties) {
        $s = $svc.Value
        $hasBuild = $s.PSObject.Properties.Name -contains 'build'
        if (-not $hasBuild -and $s.PSObject.Properties.Name -contains 'image') { $images.Add($s.image); continue }
        if (-not $hasBuild) { continue }
        $ctxDir = $s.build.context
        $df = if ($s.build.PSObject.Properties.Name -contains 'dockerfile') { $s.build.dockerfile } else { 'Dockerfile' }
        $dfPath = if ([IO.Path]::IsPathRooted($df)) { $df } else { Join-Path $ctxDir $df }
        if (-not (Test-Path $dfPath)) { continue }
        $stages = @{}
        $froms = @()
        foreach ($line in Get-Content $dfPath) {
            if ($line -match '^\s*FROM\s+(--platform=\S+\s+)?(\S+)(\s+AS\s+(\S+))?' ) {
                $img = $Matches[2]; $alias = $Matches[4]
                $froms += [pscustomobject]@{ Image = $img; Alias = $alias }
                if ($alias) { $stages[$alias.ToLowerInvariant()] = $true }
            }
        }
        for ($i = 0; $i -lt $froms.Count; $i++) {
            $img = $froms[$i].Image
            if ($img -eq 'scratch' -or $stages.ContainsKey($img.ToLowerInvariant()) -or $img -match '\$') { continue }
            if ($i -eq $froms.Count - 1) { $images.Add($img) } else { $buildStageImages.Add($img) }
        }
    }
} else {
    Add-Check WARN 'compose model' (($cfg.Output -split "`n")[-1]) 'fix the compose files / compose CLI first; image checks skipped'
}

$cli = if ($haveDocker) { 'docker' } elseif ($havePodman) { 'podman' } else { '' }
function Test-LocalImage([string]$Image) {
    if (-not $cli) { return $false }
    (Invoke-DevSuiteNative $cli @('image', 'inspect', $Image, '--format', '{{.Id}}')).ExitCode -eq 0
}

if (-not $SkipRoundTrip -and $apiOk) {
    if (-not $ProbeImage) { $ProbeImage = [string](@($images) + @($buildStageImages) | Where-Object { Test-LocalImage $_ } | Select-Object -First 1) }
    if (-not $ProbeImage) {
        Add-Check WARN 'bind round trip' 'no local image to probe with' 'pass -ProbeImage <image with cat>, or preload the stack images first'
    } else {
        $dir = Join-Path $Root (Join-Path $settings.work_dir 'doctor')
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $token = [guid]::NewGuid().ToString()
        Set-Content -Path (Join-Path $dir 'roundtrip.txt') -Value $token -NoNewline
        $hostDir = (Resolve-Path $dir).Path
        $vmDir = if ($onWindows) { Convert-DevSuitePath $hostDir $pathMap } else { $hostDir }
        if (-not $vmDir) {
            Add-Check FAIL 'bind round trip' "no podman.path_map entry for $hostDir" 'add one in devsuite.json (and share it with Setup-PodmanMachine.ps1 -Share)'
        } else {
            $r = Invoke-DevSuiteNative docker @('run', '--rm', '-v', "${vmDir}:/probe:ro", '--entrypoint', 'cat', $ProbeImage, '/probe/roundtrip.txt')
            if ($r.ExitCode -eq 0 -and $r.Output.Trim() -eq $token) { Add-Check PASS 'bind round trip' "$hostDir -> $vmDir ($ProbeImage)" }
            else { Add-Check FAIL 'bind round trip' "$vmDir not visible in the container: $(($r.Output -split "`n")[-1])" 'check the machine shares (podman machine inspect) match podman.path_map; Setup-PodmanMachine.ps1 -Recreate' }
            if ($onWindows) {
                # Informational: does this Podman version translate raw Windows paths itself?
                $n = Invoke-DevSuiteNative docker @('run', '--rm', '-v', "${hostDir}:/probe:ro", '--entrypoint', 'cat', $ProbeImage, '/probe/roundtrip.txt')
                $native = if ($n.ExitCode -eq 0 -and $n.Output.Trim() -eq $token) { 'yes' } else { 'no' }
                Add-Check INFO 'native path xlate' "engine accepts raw Windows bind paths: $native (devsuite translates either way)"
            }
        }
        Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    }
}

# --- vsdbg drop --------------------------------------------------------------------------
$drop = if ($settings.vsdbg -is [System.Collections.IDictionary] -and $settings.vsdbg.Contains('drop_dir')) { $settings.vsdbg.drop_dir } else { 'devsuite/vsdbg/drop' }
$dropPath = Join-Path $Root $drop
$manifests = @(if (Test-Path $dropPath) { Get-ChildItem -Path $dropPath -Recurse -Filter manifest.json -ErrorAction SilentlyContinue })
if ($manifests) { Add-Check PASS 'vsdbg drop' "$drop ($($manifests.Count) manifest(s))" }
else { Add-Check WARN 'vsdbg drop' "$drop missing or empty" 'run devsuite\vsdbg\Get-VsDbgOffline.ps1 on a connected machine (or git lfs pull)' }

# --- images present locally (air-gapped) ---------------------------------------------------
if ($cli -and $model) {
    foreach ($img in ($images | Sort-Object -Unique)) {
        if (Test-LocalImage $img) { Add-Check PASS 'image' $img }
        else { Add-Check FAIL 'image' "$img not present locally" "podman load -i <tar> (Setup-PodmanMachine.ps1 -LoadImages) or configure the internal registry" }
    }
    foreach ($img in ($buildStageImages | Sort-Object -Unique)) {
        if (Test-LocalImage $img) { Add-Check PASS 'image (build stage)' $img }
        else { Add-Check WARN 'image (build stage)' "$img not present locally" 'only needed when tilt-skip-build-layer is false; podman load -i <tar>' }
    }
}

# --- summary --------------------------------------------------------------------------------
$fail = @($results | Where-Object Status -eq 'FAIL').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ''
if ($fail) { Write-Host "doctor: $fail FAIL, $warn WARN" -ForegroundColor Red; exit 1 }
Write-Host "doctor: OK ($warn WARN)" -ForegroundColor Green
exit 0
