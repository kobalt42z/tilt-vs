# Copies a host folder into a named volume through the engine API (docker cp),
# so the container sees it on the engine's own Linux filesystem: exec bits and
# file locks work, unlike a 9p bind mount from a Podman Hyper-V machine.
# `docker cp` from a Windows client marks every file executable, which is what
# vsdbg needs. Used by devsuite/tilt/podman.star (copy mode, docs/podman-hyperv.md section 5).
#
#   seed-volume.ps1 <volume> <host folder> <helper image> [container cli]
#
# The helper image only needs `sh`, `find` and `chmod`; it is never pulled.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Volume,
    [Parameter(Mandatory = $true, Position = 1)][string]$Source,
    [Parameter(Mandatory = $true, Position = 2)][string]$Image,
    [Parameter(Position = 3)][string]$Cli = 'docker'
)
$ErrorActionPreference = 'Stop'

function Invoke-Cli {
    $out = & $Cli @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "seed: '$Cli $($args -join ' ')' failed: $out" }
    $out
}

if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "seed: $Source is not a folder" }
& $Cli volume inspect $Volume *> $null
if ($LASTEXITCODE -ne 0) { Invoke-Cli volume create --label devsuite.seed=true $Volume | Out-Null }
# empty it first so files deleted on the host disappear from the volume too
Invoke-Cli run --rm --pull=never --user 0 --entrypoint sh -v "${Volume}:/dst" $Image -c 'find /dst -mindepth 1 -delete' | Out-Null
$cid = (Invoke-Cli create --pull=never --user 0 --entrypoint sh -v "${Volume}:/dst" $Image | Select-Object -Last 1).ToString().Trim()
try {
    Invoke-Cli cp (Join-Path $Source '.') "${cid}:/dst" | Out-Null
} finally {
    & $Cli rm -f $cid *> $null
}
# readable (and traversable) by any user; keep exec bits already set
Invoke-Cli run --rm --pull=never --user 0 --entrypoint sh -v "${Volume}:/dst" $Image -c 'chmod -R a+rX /dst' | Out-Null
$n = (Get-ChildItem -LiteralPath $Source -Recurse -File -Force | Measure-Object).Count
Write-Output "seed: $Source -> volume $Volume ($n file(s))"
