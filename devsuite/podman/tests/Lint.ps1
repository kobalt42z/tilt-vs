# Parses every devsuite/podman PowerShell file (syntax errors fail) and runs
# PSScriptAnalyzer when it is installed.
# Run: pwsh -NoProfile -File devsuite/podman/tests/Lint.ps1
$ErrorActionPreference = 'Stop'
$files = Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Recurse -Include *.ps1, *.psm1
$bad = 0
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($e in $errors) { $bad++; Write-Host "$($f.Name):$($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
}
Write-Host "parse: $($files.Count) file(s), $bad error(s)"
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $issues = $files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error, Warning -ExcludeRule PSAvoidUsingWriteHost }
    $issues | Format-Table -AutoSize | Out-String | Write-Host
    if ($issues | Where-Object Severity -eq 'Error') { $bad++ }
} else {
    Write-Host 'PSScriptAnalyzer not installed: skipped (Install-Module PSScriptAnalyzer)'
}
if ($bad) { exit 1 }
