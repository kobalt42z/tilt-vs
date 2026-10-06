# devsuite: local `dotnet publish` for one service (run by the <svc>-dotnet Tilt resource).
#
#   publish.ps1 <csproj> <configuration> <staging dir> <publish dir> <artifacts dir> [extra publish args...]
#
# Same behaviour as publish.sh (keep both in step):
# 1. dotnet publish into <staging dir> with intermediates under <artifacts dir>
#    (never the obj/ and bin/ folders Visual Studio uses);
# 2. when it succeeds, mirror <staging dir> into <publish dir> by content, one
#    atomic move per changed file, and delete files that disappeared.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Project,
    [Parameter(Mandatory = $true, Position = 1)][string]$Configuration,
    [Parameter(Mandatory = $true, Position = 2)][string]$Staging,
    [Parameter(Mandatory = $true, Position = 3)][string]$Publish,
    [Parameter(Mandatory = $true, Position = 4)][AllowEmptyString()][string]$Artifacts,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$PublishArgs
)
$ErrorActionPreference = 'Stop'

foreach ($d in @($Staging, $Publish)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Write-Host "[devsuite] dotnet publish $Project -c $Configuration"
$argv = @('publish', $Project, '-c', $Configuration, '-o', $Staging,
    '--no-self-contained', '-p:UseAppHost=false', '-nologo')
# an empty artifacts dir means "do not isolate intermediates" (settings dotnet.isolate_intermediates)
if ($Artifacts) { $argv += @('--artifacts-path', $Artifacts) }
if ($PublishArgs) { $argv += $PublishArgs }
& dotnet @argv
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$src = (Resolve-Path -LiteralPath $Staging).Path.TrimEnd('\', '/')
$dst = (Resolve-Path -LiteralPath $Publish).Path.TrimEnd('\', '/')
$swap = "$src.swap"
$changed = 0
$removed = 0

function Test-SameFile([string]$a, [string]$b) {
    if (-not (Test-Path -LiteralPath $b -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $a).Length -ne (Get-Item -LiteralPath $b).Length) { return $false }
    return (Get-FileHash -LiteralPath $a).Hash -eq (Get-FileHash -LiteralPath $b).Hash
}

Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length).TrimStart('\', '/')
    $target = Join-Path $dst $rel
    if (-not (Test-SameFile $_.FullName $target)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $swap -Force
        Move-Item -LiteralPath $swap -Destination $target -Force
        $changed++
    }
}
Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($dst.Length).TrimStart('\', '/')
    if (-not (Test-Path -LiteralPath (Join-Path $src $rel))) {
        Remove-Item -LiteralPath $_.FullName -Force
        $removed++
    }
}
Write-Host "[devsuite] publish ok: $changed file(s) updated, $removed removed in $dst"
