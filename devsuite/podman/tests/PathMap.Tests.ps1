# Parity fixtures: Convert-DevSuitePath (PowerShell) must map like podman.star.
# Run: pwsh -NoProfile -File devsuite/podman/tests/PathMap.Tests.ps1   (any OS, pure string logic)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevSuite.Podman.psm1') -Force

$default = [ordered]@{ 'X:\' = '/mnt/x/' }
$explicit = [ordered]@{ 'X:\' = '/mnt/x/'; 'D:\Work\' = '/mnt/work'; '\\srv\share' = '/mnt/share/'; 'C:\src\shop\' = '/src/' }
$cases = @(
    @('C:\src\shop\data', $default, '/mnt/c/src/shop/data'),
    @('c:/Src/Shop/../x/./y', $default, '/mnt/c/Src/x/y'),
    @('D:\work\api', $default, '/mnt/d/work/api'),
    @('E:\', $default, '/mnt/e'),
    @('C:\src\shop\', $default, '/mnt/c/src/shop'),
    @('C:\Users\Dev\My Files', $default, '/mnt/c/Users/Dev/My Files'),
    @('\\srv\share\x', $default, $null),
    @('d:\work\api', $explicit, '/mnt/work/api'),
    @('D:\Work', $explicit, '/mnt/work'),
    @('D:\Workshop\a', $explicit, '/mnt/d/Workshop/a'),
    @('C:\src\shop\api', $explicit, '/src/api'),
    @('C:\other', $explicit, '/mnt/c/other'),
    @('//srv/share/x/y', $explicit, '/mnt/share/x/y'),
    @('F:\a\b', ([ordered]@{ 'F:/a' = '/fa/' }), '/fa/b'),
    @('C:\x', ([ordered]@{ 'X:\' = '' }), $null),
    @('C:\x', ([ordered]@{ 'X:\' = '/host/x/drive' }), '/host/c/drive/x')
)
$failed = 0
foreach ($c in $cases) {
    $got = Convert-DevSuitePath $c[0] $c[1]
    if ($got -ne $c[2]) { $failed++; Write-Host "FAIL $($c[0]): got '$got' want '$($c[2])'" -ForegroundColor Red }
}
if ($failed) { Write-Host "path map parity: $failed of $($cases.Count) failed"; exit 1 }
Write-Host "path map parity: $($cases.Count) passed"
