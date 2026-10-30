#requires -Version 7.4
[CmdletBinding()]
param([string]$CustomCodexHome = (Join-Path $env:USERPROFILE '.codex-ungate'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher\Context.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher\Launcher.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher\ShellRouterService.psm1') -DisableNameChecking -ErrorAction Stop
$context = New-CodexDesktopLaunchContext -CustomCodexHome $CustomCodexHome -LaunchParameters @{ PrepareOnly = $true } -ScriptsRoot $PSScriptRoot
$staged = & (Get-Module Launcher) {
    param($Context)
    $modelSet = New-UngateModelSet -Context $Context
    $selection = Resolve-CodexDesktopSelection -Context $Context -ModelSet $modelSet
    $keysByEnv = @{}
    foreach ($provider in (Get-ProviderDefinitions -Selection $selection)) {
        $definition = @($selection.Definitions) + @(Get-CodexBackgroundDefinition -Selection $selection) |
            Where-Object { $_ -and $_.ProviderName -eq $provider.Name } | Select-Object -First 1
        $keysByEnv[$provider.EnvKey] = Resolve-ModelApiKey -Context $Context -Definition $definition
    }
    $memory = Read-UngateMemorySettings -Context $Context
    if ($memory.Enabled) {
        $validation = Invoke-UngateMemoryValidation -Context $Context -Settings $memory
        if (-not $validation.Valid) { throw 'Memory validation failed; no initial shell router configuration was staged.' }
        $selection.MemoryDefinition = Get-UngateMemoryDefinition -Context $Context -Settings $memory
        $selection.MemoryApiKey = Resolve-ModelApiKey -Context $Context -Definition $selection.MemoryDefinition
        $selection.MemoryEnabled = $true
        $keysByEnv['UNGATE_MEMORY_API_KEY'] = $selection.MemoryApiKey
    }
    $routes = @(ConvertTo-ShellRouterServiceRoutes -Routes (Get-CodexModelShellRoutes -Selection $selection) -KeysByEnv $keysByEnv)
    $envelope = New-ShellRouterEnvelope -Action 'config' -Routes $routes `
        -ToolsCachePath (Join-Path $Context.CustomCodexHome 'tool-compatibility/tools-schema-cache.json')
    Write-ShellRouterEnvelope -Envelope $envelope
} $context
Write-Host "Encrypted initial shell router configuration staged: $staged"
