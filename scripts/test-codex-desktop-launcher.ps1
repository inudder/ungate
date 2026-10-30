#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot 'codex-desktop-launcher'
$testPaths = @(
    (Join-Path $PSScriptRoot 'start-codex-desktop-ungate.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Launcher.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/RouterCredentials.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/OmniRouteContextLimit.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Management.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Registry.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Argon.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/ToolCompatibility.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Capabilities.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/OutputLimits.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Logging.Tests.ps1'),
    (Join-Path $moduleRoot 'tests/Memories.Tests.ps1'),
    (Join-Path $PSScriptRoot 'ungate-codex-common.Tests.ps1'),
    (Join-Path $PSScriptRoot 'codex-plugin-isolation.Tests.ps1')
)
$sourcePaths = @(
    $PSCommandPath,
    (Join-Path $PSScriptRoot 'start-codex-desktop-ungate.ps1'),
    (Join-Path $PSScriptRoot 'ungate-codex-common.ps1'),
    (Join-Path $PSScriptRoot 'codex-plugin-isolation.psm1')
    ,(Join-Path $PSScriptRoot 'codex-launcher-control-agent.ps1')
    ,(Join-Path $PSScriptRoot 'start-codex-launcher-control.ps1')
) + $testPaths + @(
    Get-ChildItem -LiteralPath $moduleRoot -Recurse -File |
        Where-Object Extension -In @('.ps1', '.psm1') |
        ForEach-Object FullName
)
function Assert-NoAutomaticHomeUse {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$ParsedAst)
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($assignment in $ParsedAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $target = $assignment.Left
        if ($target -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $baseName = ($target.VariablePath.UserPath -split ':')[-1]
        if ($baseName -eq 'home') {
            $failures.Add("$($assignment.Extent.StartLineNumber): assignment to automatic variable home")
        }
    }
    foreach ($command in $ParsedAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $commandName = $command.GetCommandName()
        if ($commandName -notin @('Remove-Item', 'ri', 'rm', 'del', 'rd', 'rmdir')) { continue }
        foreach ($element in $command.CommandElements) {
            if ($element -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $baseName = ($element.VariablePath.UserPath -split ':')[-1]
            if ($baseName -eq 'home') {
                $failures.Add("$($element.Extent.StartLineNumber): Remove-Item uses automatic variable home")
            }
        }
    }
    if ($failures.Count -gt 0) {
        throw "Refusing automatic variable home in ${Path}: $($failures -join '; ')"
    }
}

foreach ($path in ($sourcePaths | Select-Object -Unique)) {
    $tokens = $null
    $parseErrors = $null
    $parsedAst = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell syntax errors in ${path}: $($parseErrors.Message -join '; ')"
    }
    Assert-NoAutomaticHomeUse -Path $path -ParsedAst $parsedAst
}

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$result = Invoke-Pester -Path $testPaths -Output Detailed -PassThru
if ($result.Result -ne 'Passed') { exit 1 }
exit 0
