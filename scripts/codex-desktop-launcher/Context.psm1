#requires -Version 7.4
# Context: internal Desktop launcher module. No per-launch module state.


function Normalize-CodexHomePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw 'Codex home path cannot be empty.'
    }

    $normalized = [System.IO.Path]::GetFullPath($PathValue)
    $root = [System.IO.Path]::GetPathRoot($normalized)
    if ($normalized.Length -gt $root.Length) {
        $normalized = $normalized.TrimEnd('\', '/')
    }

    return $normalized
}

function Get-CodexHistoryProfileInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HomePath,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalHomePath,
        [Parameter(Mandatory = $true)]
        [string]$ModelSlug,
        [Parameter(Mandatory = $true)]
        [string]$ProviderName
    )
    $ErrorActionPreference = 'Stop'

    $normalizedHome = Normalize-CodexHomePath -PathValue $HomePath
    $normalizedCanonicalHome = Normalize-CodexHomePath -PathValue $CanonicalHomePath

    return [pscustomobject][ordered]@{
        ModelSlug = $ModelSlug
        ProviderName = $ProviderName
        CodexHome = $normalizedHome
        SessionsPath = Join-Path $normalizedHome 'sessions'
        StatePath = Join-Path $normalizedHome 'state_5.sqlite'
        IsCanonical = [string]::Equals(
            $normalizedHome,
            $normalizedCanonicalHome,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
}

function Write-CodexHistoryProfileDiagnostics {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [psobject]$Profile
    )
    $ErrorActionPreference = 'Stop'

    Write-Host "[ungate] CODEX_HOME (launcher history): $($Profile.CodexHome)" -ForegroundColor Cyan
    Write-Host "[ungate] Session history directory: $($Profile.SessionsPath)" -ForegroundColor DarkGray
    Write-Host "[ungate] Session state database: $($Profile.StatePath)" -ForegroundColor DarkGray
    Write-Host "[ungate] Normal Codex profile remains separate: $($Context.DefaultCodexHome)" -ForegroundColor DarkGray
    Write-Host "[ungate] Selected model/provider: $($Profile.ModelSlug) / $($Profile.ProviderName)." -ForegroundColor DarkGray

    if (-not $Profile.IsCanonical) {
        Write-Host `
            "[ungate] Warning: -CustomCodexHome is not the shared default '$($Context.CanonicalCodexHome)'. This launch uses a separate history." `
            -ForegroundColor Yellow
    }
}

function New-CodexDesktopLaunchContext {
    [CmdletBinding()]
    param(
        [string]$CustomCodexHome = (Join-Path $HOME '.codex-ungate'),
        [System.Collections.IDictionary]$LaunchParameters = @{},
        [string]$ScriptsRoot = (Split-Path -Parent $PSScriptRoot)
    )
    $ErrorActionPreference = 'Stop'

    $options = [ordered]@{
        ApiKey = $null
        Model = 'ungate-opus-4-8'
        LogLevel = ''
        AddModel = $false
        PrepareOnly = $false
        SkipWorkspaceRestore = $false
        EnableProviderFallback = $false
        NoLogWatch = $false
    }
    foreach ($name in @($options.Keys)) {
        if ($name -in $LaunchParameters.Keys) { $options[$name] = $LaunchParameters[$name] }
    }
    $RepoRoot = (Resolve-Path (Join-Path $ScriptsRoot '..')).Path
    $DefaultCodexHome = Join-Path $HOME '.codex'
    $CanonicalCodexHome = Normalize-CodexHomePath -PathValue (Join-Path $HOME '.codex-ungate')
    $CustomCodexHome = Normalize-CodexHomePath -PathValue $CustomCodexHome
    $DefaultConfigPath = Join-Path $DefaultCodexHome 'config.toml'
    $CustomConfigPath = Join-Path $CustomCodexHome 'config.toml'
    $DefaultModelCachePath = Join-Path $DefaultCodexHome 'models_cache.json'
    $CustomModelCatalogPath = Join-Path $CustomCodexHome 'ungate-models.json'
    $CustomModelDefinitionsPath = Join-Path $CustomCodexHome 'ungate-model-definitions.json'
    $PickerModelSelectionPath = Join-Path $CustomCodexHome 'ungate-picker-models.json'
    $LogSettingsPath = Join-Path $CustomCodexHome 'ungate-log-settings.json'
    $CustomGlobalStatePath = Join-Path $CustomCodexHome '.codex-global-state.json'
    $ProxyBaseUrl = 'http://127.0.0.1:47821'
    $ProviderName = 'ungate_proxy'
    $CliProxyUpstreamBaseUrl = 'http://127.0.0.1:8317'
    $CliProxyBaseUrl = 'http://127.0.0.1:8318'
    $CliProxyProviderName = 'cliproxyapi'
    $OmniRouteBaseUrl = 'http://127.0.0.1:20128'
    $OmniRouteProviderName = 'omniroute'
    $OmniRouteFallbackModel = 'codex-fallback'
    $CodexModelShellRouterBaseUrl = 'http://127.0.0.1:8319'
    $CodexModelShellRouterProviderName = 'ungate_model_shell_router'
    $CodexModelShellRouterPath = Join-Path $ScriptsRoot 'codex-model-shell-router.mjs'
    $CodexModelShellRouterServiceName = 'codex-model-shell-router'
    $CodexDesktopPickerCapacity = 7
    $CodexModelShellPool = @(
        'gpt-5.6-sol',
        'gpt-5.6-terra',
        'gpt-5.6-luna',
        'gpt-5.5',
        'gpt-5.4',
        'gpt-5.4-mini',
        'gpt-5.3-codex'
    )
    $CodexModelShellRouterProviderDefinition = [pscustomobject][ordered]@{
        Name = $CodexModelShellRouterProviderName
        DisplayName = 'Ungate Codex Model Router'
        ProxyBaseUrl = $CodexModelShellRouterBaseUrl
        EnvKey = 'UNGATE_API_KEY'
    }
    $CliProxyConfigPath = 'J:\Sandbox\CLIProxyAPI\config.yaml'
    $CliProxyBridgePath = Join-Path $ScriptsRoot 'cliproxy-namespace-bridge.mjs'
    $CliProxyBridgeServiceName = 'cliproxy-namespace-bridge'
    $PluginIsolationModulePath = Join-Path $ScriptsRoot 'codex-plugin-isolation.psm1'
    $CodexPackageLaunchHelperPath = Join-Path $ScriptsRoot 'start-codex-beta-package-process.ps1'

    $UngateEnvironmentInstruction = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'environment-instructions.txt')).TrimEnd([char[]]"`r`n")
    $SkipWorkspaceRestore = [bool]$options.SkipWorkspaceRestore
    return [pscustomobject][ordered]@{
        ScriptsRoot = $ScriptsRoot
        Options = [pscustomobject]$options
        BoundParameterNames = @($LaunchParameters.Keys)
        RepoRoot = $RepoRoot
        DefaultCodexHome = $DefaultCodexHome
        CanonicalCodexHome = $CanonicalCodexHome
        DefaultConfigPath = $DefaultConfigPath
        CustomConfigPath = $CustomConfigPath
        DefaultModelCachePath = $DefaultModelCachePath
        CustomModelCatalogPath = $CustomModelCatalogPath
        CustomModelDefinitionsPath = $CustomModelDefinitionsPath
        PickerModelSelectionPath = $PickerModelSelectionPath
        LogSettingsPath = $LogSettingsPath
        CustomGlobalStatePath = $CustomGlobalStatePath
        ProxyBaseUrl = $ProxyBaseUrl
        ProviderName = $ProviderName
        CliProxyUpstreamBaseUrl = $CliProxyUpstreamBaseUrl
        CliProxyBaseUrl = $CliProxyBaseUrl
        CliProxyProviderName = $CliProxyProviderName
        OmniRouteBaseUrl = $OmniRouteBaseUrl
        OmniRouteProviderName = $OmniRouteProviderName
        OmniRouteFallbackModel = $OmniRouteFallbackModel
        CodexModelShellRouterBaseUrl = $CodexModelShellRouterBaseUrl
        CodexModelShellRouterProviderName = $CodexModelShellRouterProviderName
        CodexModelShellRouterPath = $CodexModelShellRouterPath
        CodexModelShellRouterServiceName = $CodexModelShellRouterServiceName
        CodexDesktopPickerCapacity = $CodexDesktopPickerCapacity
        CodexModelShellPool = $CodexModelShellPool
        CodexModelShellRouterProviderDefinition = $CodexModelShellRouterProviderDefinition
        CliProxyConfigPath = $CliProxyConfigPath
        CliProxyBridgePath = $CliProxyBridgePath
        CliProxyBridgeServiceName = $CliProxyBridgeServiceName
        PluginIsolationModulePath = $PluginIsolationModulePath
        CodexPackageLaunchHelperPath = $CodexPackageLaunchHelperPath
        CustomCodexHome = $CustomCodexHome
        UngateEnvironmentInstruction = $UngateEnvironmentInstruction
        SkipWorkspaceRestore = $SkipWorkspaceRestore
    }
}

Export-ModuleMember -Function @(
    'Get-CodexHistoryProfileInfo',
    'Write-CodexHistoryProfileDiagnostics',
    'New-CodexDesktopLaunchContext'
)
