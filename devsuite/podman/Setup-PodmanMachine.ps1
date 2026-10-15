<#
.SYNOPSIS
Creates (or repairs) the Podman machine devsuite runs on: Hyper-V provider,
rootful, source drives shared over 9p, Docker API reachable on a named pipe.

.DESCRIPTION
Run once per developer machine from an ELEVATED PowerShell (Hyper-V needs
admin to create and start VMs). Idempotent: an existing machine is reused and
only the missing bits (rootful, env vars, registries, images) are applied;
pass -Recreate to rebuild it (shares can only be set at init time).

What it does:
  1. checks Windows, admin, Hyper-V and podman >= 5
  2. CONTAINERS_MACHINE_PROVIDER=hyperv (process + user env)
  3. podman machine init --rootful --volume <share>... (default share: the
     drive the solution lives on, mapped exactly like podman.path_map maps it)
  4. podman machine start
  5. Docker API: uses \\.\pipe\docker_engine when Podman serves it, else sets
     DOCKER_HOST=npipe:////./pipe/<machine pipe> for the user
  6. DOCKER_BUILDKIT=0 for the user (Podman has no BuildKit session API)
  7. optional air-gapped extras: -Registry (registries.conf in the VM) and
     -LoadImages (podman load every .tar in a folder)

See docs/podman-hyperv.md.

.EXAMPLE
.\devsuite\podman\Setup-PodmanMachine.ps1
.EXAMPLE
.\devsuite\podman\Setup-PodmanMachine.ps1 -Share C:\src, D:\data -ImagePath \\fs\podman\machine-os.vhdx.zst -LoadImages \\fs\images -Registry registry.corp:5000
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$MachineName = 'podman-machine-default',
    # Host folders shared into the VM. Default: the root of the drive holding the solution.
    [string[]]$Share = @(),
    [int]$Cpus = 4,
    [int]$MemoryMB = 8192,
    [int]$DiskGB = 100,
    # Offline machine OS image (.vhdx / .vhdx.zst) for air-gapped init.
    [string]$ImagePath = '',
    # Internal registry used instead of docker.io (written to registries.conf in the VM).
    [string]$Registry = '',
    [switch]$InsecureRegistry,
    # Folder of image tarballs (podman save / docker save) to preload.
    [string]$LoadImages = '',
    [switch]$Recreate,
    # Do not persist DOCKER_HOST / DOCKER_BUILDKIT / CONTAINERS_MACHINE_PROVIDER for the user.
    [switch]$NoUserEnv
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevSuite.Podman.psm1') -Force

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Invoke-Podman {
    param([string[]]$Arguments, [switch]$AllowFail)
    Write-Verbose ("podman " + ($Arguments -join ' '))
    $r = Invoke-DevSuiteNative podman $Arguments
    if ($r.ExitCode -ne 0 -and -not $AllowFail) {
        throw "podman $($Arguments -join ' ') failed ($($r.ExitCode)):`n$($r.Output)"
    }
    $r
}

function Set-UserEnv([string]$Name, [string]$Value) {
    if ($NoUserEnv) {
        if ($Value) { Set-Item "Env:$Name" $Value } else { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
        Write-Host "    $Name=$Value (this session only, -NoUserEnv)"
    } else {
        Set-DevSuiteUserEnv $Name $Value
        Write-Host "    $Name=$Value (user environment)"
    }
}

# --- 1. prerequisites ---------------------------------------------------------
Write-Step 'Checking prerequisites'
if ($env:OS -ne 'Windows_NT') { throw 'Setup-PodmanMachine.ps1 targets Windows (Hyper-V). On Linux use the native engine.' }
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell (Hyper-V needs admin to create and start the machine).'
}
$hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if (-not $hv -or $hv.State -ne 'Enabled') {
    throw 'Hyper-V is not enabled. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All, then reboot.'
}
$ver = Invoke-Podman @('--version') -AllowFail
if ($ver.ExitCode -ne 0) { throw 'podman not found on PATH. Install Podman for Windows 5.x (podman-<ver>-setup.exe) first.' }
if ($ver.Output -notmatch '(\d+)\.(\d+)\.(\d+)') { throw "Cannot parse podman version: $($ver.Output)" }
if ([int]$Matches[1] -lt 5) { throw "podman $($Matches[0]) is too old; the Hyper-V provider with 9p volumes needs podman 5.x." }
Write-Host "    $($ver.Output)"

$settings = Get-DevSuiteSetting
$pathMap = $settings.podman.path_map

# --- 2. provider --------------------------------------------------------------
Write-Step 'Selecting the Hyper-V machine provider'
Set-UserEnv 'CONTAINERS_MACHINE_PROVIDER' 'hyperv'

# --- 3. shares ------------------------------------------------------------------
if (-not $Share) { $Share = @([IO.Path]::GetPathRoot((Get-DevSuiteRoot))) }
$volumes = foreach ($s in $Share) {
    $hostPath = (Resolve-Path $s).Path
    $vmPath = Convert-DevSuitePath $hostPath $pathMap
    if (-not $vmPath) { throw "No podman.path_map entry covers $hostPath; add one in devsuite.json so Tilt and the machine agree." }
    $hostArg = $hostPath.TrimEnd('\')
    if ($hostArg -match '^[A-Za-z]:$') { $hostArg += '\' }
    [pscustomobject]@{ Host = $hostArg; Vm = $vmPath; Arg = "${hostArg}:${vmPath}" }
}
Write-Step 'Shares (host -> machine)'
$volumes | ForEach-Object { Write-Host "    $($_.Host) -> $($_.Vm)" }

# --- 4. machine -----------------------------------------------------------------
$list = Invoke-Podman @('machine', 'list', '--format', 'json')
$existing = @($list.Output | ConvertFrom-Json) | Where-Object { $_.Name -eq $MachineName -or $_.Name -eq "$MachineName*" }
if ($existing -and $Recreate) {
    if ($PSCmdlet.ShouldProcess($MachineName, 'remove machine')) {
        Write-Step "Removing $MachineName (-Recreate)"
        Invoke-Podman @('machine', 'stop', $MachineName) -AllowFail | Out-Null
        Invoke-Podman @('machine', 'rm', '--force', $MachineName) | Out-Null
        $existing = $null
    }
}
if (-not $existing) {
    $initArgs = @('machine', 'init', $MachineName, '--rootful', '--cpus', $Cpus, '--memory', $MemoryMB, '--disk-size', $DiskGB)
    foreach ($v in $volumes) { $initArgs += @('--volume', $v.Arg) }
    if ($ImagePath) { $initArgs += @('--image', (Resolve-Path $ImagePath).Path) }
    if ($PSCmdlet.ShouldProcess($MachineName, 'podman ' + ($initArgs -join ' '))) {
        Write-Step "Creating $MachineName"
        Invoke-Podman $initArgs | Out-Null
    }
} else {
    Write-Step "Reusing existing machine $MachineName"
    $inspect = (Invoke-Podman @('machine', 'inspect', $MachineName)).Output | ConvertFrom-Json
    $m = @($inspect)[0]
    $mounts = @()
    if ($m.PSObject.Properties.Name -contains 'Mounts' -and $m.Mounts) { $mounts = @($m.Mounts | ForEach-Object { $_.Target }) }
    foreach ($v in $volumes) {
        if ($mounts -notcontains $v.Vm) {
            Write-Warning "$MachineName has no share for $($v.Host) -> $($v.Vm); shares are fixed at init. Re-run with -Recreate."
        }
    }
    if ($m.PSObject.Properties.Name -contains 'Rootful' -and -not $m.Rootful) {
        if ($PSCmdlet.ShouldProcess($MachineName, 'set --rootful')) {
            Write-Step 'Switching the machine to rootful'
            Invoke-Podman @('machine', 'stop', $MachineName) -AllowFail | Out-Null
            Invoke-Podman @('machine', 'set', '--rootful', $MachineName) | Out-Null
        }
    }
}

# --- 5. start -------------------------------------------------------------------
$state = (Invoke-Podman @('machine', 'inspect', '--format', '{{.State}}', $MachineName) -AllowFail).Output
if ($state -ne 'running') {
    if ($PSCmdlet.ShouldProcess($MachineName, 'start')) {
        Write-Step "Starting $MachineName"
        $start = Invoke-Podman @('machine', 'start', $MachineName)
        $start.Output -split "`n" | Where-Object { $_ -match 'API|pipe|forwarding' } | ForEach-Object { Write-Host "    $_" }
    }
} else {
    Write-Step "$MachineName is already running"
}

# --- 6. Docker API endpoint -------------------------------------------------------
Write-Step 'Docker API endpoint'
$pipe = (Invoke-Podman @('machine', 'inspect', '--format', '{{.ConnectionInfo.PodmanPipe.Path}}', $MachineName) -AllowFail).Output
$dockerEngine = Test-Path '\\.\pipe\docker_engine'
if ($dockerEngine) {
    # docker_engine is served by Podman when Docker Desktop is not installed/running.
    Write-Host '    \\.\pipe\docker_engine is available; DOCKER_HOST not needed'
    if ($env:DOCKER_HOST) { Set-UserEnv 'DOCKER_HOST' '' }
} elseif ($pipe) {
    $name = ($pipe -replace '^\\\\\.\\pipe\\', '' -replace '^npipe:////\./pipe/', '')
    Set-UserEnv 'DOCKER_HOST' "npipe:////./pipe/$name"
} else {
    Write-Warning 'Could not find the machine pipe; set DOCKER_HOST=npipe:////./pipe/podman-machine-default manually.'
}
Set-UserEnv 'DOCKER_BUILDKIT' '0'

# --- 7. air-gapped extras -----------------------------------------------------------
if ($Registry) {
    Write-Step "Configuring $Registry in the machine's registries.conf"
    $insecure = if ($InsecureRegistry) { 'true' } else { 'false' }
    $conf = @"
unqualified-search-registries = ["$Registry"]

[[registry]]
prefix = "docker.io"
location = "$Registry"
insecure = $insecure

[[registry]]
prefix = "mcr.microsoft.com"
location = "$Registry"
insecure = $insecure
"@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($conf))
    if ($PSCmdlet.ShouldProcess($MachineName, 'write /etc/containers/registries.conf.d/50-devsuite.conf')) {
        Invoke-Podman @('machine', 'ssh', $MachineName,
            "echo $b64 | base64 -d | sudo tee /etc/containers/registries.conf.d/50-devsuite.conf >/dev/null") | Out-Null
    }
}
if ($LoadImages) {
    Write-Step "Preloading images from $LoadImages"
    Get-ChildItem -Path $LoadImages -File | Where-Object { $_.Name -match '\.(tar|tar\.gz|tgz)$' } | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, 'podman load')) {
            $r = Invoke-Podman @('load', '-i', $_.FullName)
            Write-Host "    $($_.Name): $(($r.Output -split "`n")[-1])"
        }
    }
}

# --- 8. verify ------------------------------------------------------------------------
Write-Step 'Verifying'
$probe = if (Get-Command docker -ErrorAction SilentlyContinue) { Invoke-DevSuiteNative docker @('version', '--format', '{{.Server.Version}}') }
         else { Invoke-DevSuiteNative podman @('version', '--format', '{{.Server.Version}}') }
if ($probe.ExitCode -ne 0) { throw "Engine not reachable after setup:`n$($probe.Output)" }
Write-Host "    engine answers: $($probe.Output)"
Write-Host ''
Write-Host 'Done. Open a NEW terminal (or restart Visual Studio) so the user environment applies, then run:' -ForegroundColor Green
Write-Host '    .\devsuite\podman\Test-DevSuite.ps1' -ForegroundColor Green
