#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot 'codex-desktop-launcher'
$testPaths = @(
    (Join-Path $PSScriptRoot 'start-codex-desktop-ungate.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Launcher.Tests.ps1'),
    (Join-Path $PSScriptRoot 'ungate-codex-common.Tests.ps1'),
    (Join-Path $PSScriptRoot 'codex-plugin-isolation.Tests.ps1')
)
$sourcePaths = @(
    $PSCommandPath,
    (Join-Path $PSScriptRoot 'start-codex-desktop-ungate.ps1'),
    (Join-Path $PSScriptRoot 'ungate-codex-common.ps1'),
    (Join-Path $PSScriptRoot 'codex-plugin-isolation.psm1')
) + $testPaths + @(
    Get-ChildItem -LiteralPath $moduleRoot -Recurse -File |
        Where-Object Extension -In @('.ps1', '.psm1') |
        ForEach-Object FullName
)
foreach ($path in ($sourcePaths | Select-Object -Unique)) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell syntax errors in ${path}: $($parseErrors.Message -join '; ')"
    }
}

Import-Module Pester -RequiredVersion 5.8.0 -ErrorAction Stop
$result = Invoke-Pester -Path $testPaths -Output Detailed -PassThru
if ($result.Result -ne 'Passed') { exit 1 }
exit 0
