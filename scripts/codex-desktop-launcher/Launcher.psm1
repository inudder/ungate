#requires -Version 7.4
# Orchestration owns per-launch state; importing this module does not launch or prepare anything.
Import-Module (Join-Path $PSScriptRoot 'Context.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Picker.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Routing.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Catalog.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Profile.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ToolCompatibility.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-plugin-isolation.psm1') -DisableNameChecking -ErrorAction Stop

function Get-ActiveDesktopModelDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][object[]]$Definitions,
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'
    if ($Selection.EnableProviderFallback) {
        return @($Definitions) + @($Selection.FallbackDefinition)
    }
    # Desktop uses known shell IDs; the router maps them to provider models.
    $pickerDefinitions = @(Get-UngatePickerModelDefinitions `
        -Definitions $Definitions `
        -SettingsPath $Context.PickerModelSelectionPath `
        -Capacity $Context.CodexDesktopPickerCapacity)
    return @(Set-CodexModelShellSlugs -Context $Context -Definitions $pickerDefinitions)
}

function Resolve-CodexDesktopSelection {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$ModelSet
    )
    $ErrorActionPreference = 'Stop'
    $Model = $Context.Options.Model
    $PrepareOnly = $Context.Options.PrepareOnly
    $Selection = [pscustomobject]@{
        Definitions = @()
        FallbackDefinition = $ModelSet.FallbackDefinition
        EnableProviderFallback = [bool]$Context.Options.EnableProviderFallback
        SelectedModel = $null
        LaunchModel = $null
        LaunchProvider = $null
    }
    $AllUngateModelDefinitions = @(
        Get-UngateModelDefinitions -Context $Context `
            -BuiltInDefinitions $ModelSet.BuiltInDefinitions `
            -RegistryPath $Context.CustomModelDefinitionsPath
    )
    if ($Selection.EnableProviderFallback) {
        if ($Context.BoundParameterNames.Contains('Model')) {
            throw '-EnableProviderFallback cannot be combined with -Model.'
        }

        $Model = $Context.OmniRouteFallbackModel
    }
    $Selection.Definitions = @(Get-ActiveDesktopModelDefinitions -Context $Context -Definitions $AllUngateModelDefinitions -Selection $Selection)

    if (-not $Selection.EnableProviderFallback -and -not $PrepareOnly -and -not $Context.BoundParameterNames.Contains('Model')) {
        $Model = Select-UngateDesktopModel -Context $Context `
            -Definitions $AllUngateModelDefinitions `
            -BuiltInDefinitions $ModelSet.BuiltInDefinitions `
            -RegistryPath $Context.CustomModelDefinitionsPath `
            -PickerSettingsPath $Context.PickerModelSelectionPath `
            -PickerCapacity $Context.CodexDesktopPickerCapacity `
            -LogSettingsPath $Context.LogSettingsPath `
            -OverridesPath $Context.CustomModelOverridesPath `
            -IncludeProviderFallback `
            -ProviderFallbackModel $Context.OmniRouteFallbackModel

        if ($Model -eq $Context.OmniRouteFallbackModel) {
            $Selection.EnableProviderFallback = $true
        }
        else {
            $AllUngateModelDefinitions = @(
                Get-UngateModelDefinitions -Context $Context `
                    -BuiltInDefinitions $ModelSet.BuiltInDefinitions `
                    -RegistryPath $Context.CustomModelDefinitionsPath `
                    -OverridesPath $Context.CustomModelOverridesPath
            )
        }
        $Selection.Definitions = @(Get-ActiveDesktopModelDefinitions -Context $Context -Definitions $AllUngateModelDefinitions -Selection $Selection)
    }

    if (-not $Selection.EnableProviderFallback -and [string]::IsNullOrWhiteSpace($Model)) {
        $Model = [string]$Selection.Definitions[0].Slug
    }

    $Selection.SelectedModel = $Selection.Definitions |
        Where-Object {
            $_.Slug -eq $Model -or
            ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $Model) -or
            ($_.PSObject.Properties['Aliases'] -and $_.Aliases -and $Model -in $_.Aliases)
        } |
        Select-Object -First 1
    if (-not $Selection.SelectedModel) {
        $knownModelDefinition = $AllUngateModelDefinitions |
            Where-Object {
                $_.Slug -eq $Model -or
                ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $Model) -or
                ($_.PSObject.Properties['Aliases'] -and $_.Aliases -and $Model -in $_.Aliases)
            } |
            Select-Object -First 1
        if ($knownModelDefinition -and -not $Selection.EnableProviderFallback) {
            throw "Model '$($knownModelDefinition.DisplayName)' is not enabled in the Desktop picker. Run the launcher and choose 'Configure Desktop model picker'."
        }
        $supportedModels = @($Selection.Definitions.Slug) -join ', '
        throw "Unsupported Desktop model '$Model'. Configured models: $supportedModels"
    }
    $Model = [string]$Selection.SelectedModel.Slug
    $Selection.LaunchModel = if ($Selection.EnableProviderFallback) {
        $Model
    } else {
        Get-CodexCatalogModelSlug -Selection $Selection -Definition $Selection.SelectedModel
    }
    $Selection.LaunchProvider = if ($Selection.EnableProviderFallback) {
        [pscustomobject][ordered]@{
            Name = $Selection.SelectedModel.ProviderName
            DisplayName = $Selection.SelectedModel.ProviderDisplayName
            ProxyBaseUrl = $Selection.SelectedModel.ProxyBaseUrl
            EnvKey = $Selection.SelectedModel.EnvKey
        }
    } else {
        $Context.CodexModelShellRouterProviderDefinition
    }
    return $Selection
}

function Initialize-CodexDesktopTransport {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'
    $ApiKey = $Context.Options.ApiKey
    $providerKeys = @{}
    foreach ($provider in (Get-ProviderDefinitions -Selection $Selection)) {
        $sampleDefinition = $Selection.Definitions |
            Where-Object { $_.ProviderName -eq $provider.Name } |
            Select-Object -First 1
        $providerKeys[$provider.Name] = Resolve-ModelApiKey -Context $Context `
            -Definition $sampleDefinition `
            -ApiKey $(if ($Selection.SelectedModel.ProviderName -eq $provider.Name) { $ApiKey } else { $null })
        Write-Host `
            "[ungate] $($provider.DisplayName) API key resolved (len=$($providerKeys[$provider.Name].Length))." `
            -ForegroundColor DarkGray
    }

    if ($providerKeys.ContainsKey($Context.CliProxyProviderName)) {
        Ensure-CliProxyBridge -Context $Context -Key $providerKeys[$Context.CliProxyProviderName]
    }
    if (-not $Selection.EnableProviderFallback) {
        Ensure-CodexModelShellRouter -Context $Context -Selection $Selection `
            -Routes (Get-CodexModelShellRoutes -Selection $Selection) `
            -ProviderKeys $providerKeys
    }

    $selectedKey = $providerKeys[$Selection.SelectedModel.ProviderName]
    $modelToProbe = if ($Selection.SelectedModel.PSObject.Properties['UpstreamModel'] -and $Selection.SelectedModel.UpstreamModel) {
        $Selection.SelectedModel.UpstreamModel
    } else {
        $Selection.SelectedModel.Slug
    }
    $preflightAttempts = if ($Selection.EnableProviderFallback) { 1 } else { 2 }
    $preflightFailure = $null
    for ($attempt = 1; $attempt -le $preflightAttempts; $attempt++) {
        try {
            if ($Selection.EnableProviderFallback -or $Selection.SelectedModel.ProviderName -eq $Context.OmniRouteProviderName) {
                Invoke-DesktopOmniRoutePreflight `
                    -Key $selectedKey `
                    -Model $modelToProbe `
                    -ProxyBaseUrl $Selection.SelectedModel.ProxyBaseUrl
            }
            elseif ($Selection.SelectedModel.RequiresUngate) {
                Invoke-UngatePreflight `
                    -Key $selectedKey `
                    -Model $modelToProbe `
                    -ProxyBaseUrl $Selection.SelectedModel.ProxyBaseUrl
            }
            else {
                # CLIProxyAPI discovery is dynamic, so live Responses inference is authoritative.
                Write-Host "[ungate] Proxy healthy at $($Selection.SelectedModel.ProxyBaseUrl)." -ForegroundColor Green
                Invoke-CliProxyPreflight `
                    -Key $selectedKey `
                    -Model $modelToProbe `
                    -ProxyBaseUrl $Selection.SelectedModel.ProxyBaseUrl
            }

            $preflightFailure = $null
            break
        }
        catch {
            $preflightFailure = $_
            if ($attempt -lt $preflightAttempts) {
                Write-Host `
                    "[ungate] Preflight attempt $attempt of $preflightAttempts failed; retrying." `
                    -ForegroundColor Yellow
                Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkYellow
                Start-Sleep -Seconds 1
            }
        }
    }

    if ($preflightFailure) {
        Write-Host '[ungate] Preflight failed.' -ForegroundColor Red
        Write-Host "        $($preflightFailure.Exception.Message)" -ForegroundColor Yellow
    }
    return [pscustomobject]@{
        ProviderKeys = $providerKeys
        SelectedKey = $selectedKey
        PreflightFailure = $preflightFailure
    }
}

function Initialize-CodexDesktopProfile {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection,
        [Parameter(Mandatory)][psobject]$codexBeta,
        [Parameter(Mandatory)][hashtable]$providerKeys,
        [Parameter(Mandatory)][string]$selectedKey
    )
    $ErrorActionPreference = 'Stop'
    Initialize-UngateCodexConfig -Context $Context -Selection $Selection
    Write-UngateModelCatalog -Context $Context -Selection $Selection
    $betaOnlyMcpContent = @'
[mcp_servers.ungate_patch]
command = 'C:\Program Files\nodejs\node.exe'
args = ['J:\Dev\ungate-local\scripts\ungate-patch-mcp.mjs', "--allow-root", "*"]
'@

    Sync-CodexMcpServers -Context $Context `
        -SourceCodexHome $Context.DefaultCodexHome `
        -TargetCodexHome $Context.CustomCodexHome `
        -BetaOnlyMcpContent $betaOnlyMcpContent
    Ensure-SharedDirectory -Context $Context -Name 'skills'
    Sync-CodexGlobalInstructions -Context $Context
    Sync-CodexAuthentication -Context $Context
    $codexExecutable = Get-CodexCliExecutable -Context $Context
    if (-not $codexExecutable) {
        throw 'Codex CLI is required to prepare the isolated Codex Beta plugin store.'
    }
    $betaIsRunning = @(Get-CodexBetaProcesses -ExecutablePath $codexBeta.ExecutablePath).Count -gt 0
    $pluginIsolation = Initialize-CodexBetaPluginIsolation `
        -DefaultCodexHome $Context.DefaultCodexHome `
        -CustomCodexHome $Context.CustomCodexHome `
        -CodexExecutable $codexExecutable `
        -BetaBundledMarketplace $codexBeta.BundledMarketplacePath `
        -BetaPackageVersion $codexBeta.Version `
        -BetaIsRunning $betaIsRunning
    if ($pluginIsolation.Changed) {
        $syncReasons = @($pluginIsolation.SyncReasons)
        if ($syncReasons.Count -gt 0) {
            Write-Host `
                "[ungate] Plugin isolation will sync because: $($syncReasons -join '; ')." `
                -ForegroundColor Yellow
        }
        Write-Host `
            "[ungate] Codex Beta plugins $($pluginIsolation.Action.ToLowerInvariant()) and isolated ($($pluginIsolation.PluginIds.Count) installed)." `
            -ForegroundColor Green
    }
    else {
        Write-Host `
            "[ungate] Isolated Codex Beta plugins verified ($($pluginIsolation.PluginIds.Count) installed)." `
            -ForegroundColor DarkGray
    }
    Write-Host "[ungate] Browser plugin SHA256: $($pluginIsolation.BrowserSha256)" -ForegroundColor DarkGray
    $unsupportedBundledPluginIds = @($pluginIsolation.UnsupportedBundledPluginIds)
    if ($unsupportedBundledPluginIds.Count -gt 0) {
        Write-Warning (
            '[ungate] Codex Beta does not provide bundled plugins from the normal profile: ' +
            ($unsupportedBundledPluginIds -join ', ')
        )
    }
    Assert-UngateCodexConfig -Context $Context -Selection $Selection -Key $selectedKey -ProviderKeys $providerKeys
    Initialize-CodexWindowsSandbox -Context $Context
    Write-Host "[ungate] Custom CODEX_HOME ready: $($Context.CustomCodexHome)" -ForegroundColor Green
    Restore-CodexWorkspaceRoots -Context $Context
}

function Start-CodexDesktopSession {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection,
        [Parameter(Mandatory)][psobject]$codexBeta,
        [Parameter(Mandatory)][hashtable]$providerKeys
    )
    $ErrorActionPreference = 'Stop'
    $launchTransport = if ($Selection.EnableProviderFallback) {
        $Selection.SelectedModel.ProviderName
    } else {
        'the local Codex model-shell router'
    }
    Write-Host "[ungate] Launching Codex Beta with $($Selection.SelectedModel.DisplayName) via $launchTransport." -ForegroundColor Green
    $launchEnv = @{
        CODEX_HOME = $Context.CustomCodexHome
    }
    foreach ($provider in (Get-ProviderDefinitions -Selection $Selection)) {
        $launchEnv[$provider.EnvKey] = $providerKeys[$provider.Name]
    }
    Start-CodexBetaDesktop -Context $Context `
        -PackageInfo $codexBeta `
        -LaunchEnvironment $launchEnv `
        -WorkingDirectory $Context.RepoRoot

    if (-not $Context.Options.NoLogWatch) {
        $activeLogLevel = if ($Context.BoundParameterNames.Contains('LogLevel') -and -not [string]::IsNullOrWhiteSpace($Context.Options.LogLevel)) {
            Write-UngateLogSettings -SettingsPath $Context.LogSettingsPath -LogLevel $Context.Options.LogLevel
            $Context.Options.LogLevel
        } else {
            (Read-UngateLogSettings -SettingsPath $Context.LogSettingsPath).LogLevel
        }

        if ($activeLogLevel -ne 'Off') {
            Watch-CodexActivity `
                -CustomCodexHome $Context.CustomCodexHome `
                -DesktopExecutablePath ([string]$codexBeta.ExecutablePath) `
                -LogLevel $activeLogLevel `
                -LogSettingsPath $Context.LogSettingsPath
        } else {
            Write-Host '[ungate] Live terminal logging is Off.' -ForegroundColor DarkGray
        }
    }
}

function Invoke-CodexDesktopLauncher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Context)

    $ErrorActionPreference = 'Stop'
    if ($Context.Options.TestTools) {
        $conflicts = @('AddModel', 'PrepareOnly', 'EnableProviderFallback') | Where-Object { $Context.BoundParameterNames.Contains($_) }
        if ($conflicts.Count -gt 0) { throw "-TestTools cannot be combined with: $($conflicts -join ', ')." }
        $toolModelSet = New-UngateModelSet -Context $Context
        $toolDefinitions = @(Get-UngateModelDefinitions -Context $Context -BuiltInDefinitions $toolModelSet.BuiltInDefinitions -RegistryPath $Context.CustomModelDefinitionsPath)
        $toolModel = if ($Context.BoundParameterNames.Contains('Model')) { $Context.Options.Model } else { $null }
        return Invoke-CodexToolCompatibility -Context $Context -Definitions $toolDefinitions -Model $toolModel
    }
    foreach ($dependency in @($Context.PluginIsolationModulePath, $Context.CodexPackageLaunchHelperPath)) {
        if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
            throw "Codex launcher dependency not found at $dependency."
        }
    }
    $modelSet = New-UngateModelSet -Context $Context
    if ($Context.Options.AddModel) {
        $conflictingParameters = @(
            'ApiKey', 'Model', 'PrepareOnly', 'SkipWorkspaceRestore', 'EnableProviderFallback'
        ) | Where-Object { $Context.BoundParameterNames.Contains($_) }
        if ($conflictingParameters.Count -gt 0) {
            throw "-AddModel cannot be combined with: $($conflictingParameters -join ', ')."
        }
        $null = Invoke-AddUngateModelMode -Context $Context -RegistryPath $Context.CustomModelDefinitionsPath -BuiltInDefinitions $modelSet.BuiltInDefinitions
        return 0
    }

    if ($Context.Options.ConfigureModel -or $Context.BoundParameterNames.Contains('SetUpstreamModel')) {
        $conflictingParameters = @(
            'ApiKey', 'PrepareOnly', 'SkipWorkspaceRestore', 'EnableProviderFallback', 'AddModel', 'TestTools'
        ) | Where-Object { $Context.BoundParameterNames.Contains($_) }
        if ($conflictingParameters.Count -gt 0) {
            throw "-ConfigureModel/-SetUpstreamModel cannot be combined with: $($conflictingParameters -join ', ')."
        }
        $defs = @(Get-UngateModelDefinitions -Context $Context -BuiltInDefinitions $modelSet.BuiltInDefinitions -RegistryPath $Context.CustomModelDefinitionsPath -OverridesPath $Context.CustomModelOverridesPath)
        $targetSlug = if ($Context.BoundParameterNames.Contains('Model')) { $Context.Options.Model } else { $null }
        $newUpstream = if ($Context.BoundParameterNames.Contains('SetUpstreamModel')) { $Context.Options.SetUpstreamModel } else { $null }
        $null = Invoke-UngateModelVersionConfiguration `
            -Context $Context `
            -Definitions $defs `
            -OverridesPath $Context.CustomModelOverridesPath `
            -TargetModelSlug $targetSlug `
            -NewUpstreamModel $newUpstream
        return 0
    }

    $selection = Resolve-CodexDesktopSelection -Context $Context -ModelSet $modelSet
    $selectedModelId = if ($selection.SelectedModel.PSObject.Properties['UpstreamModel'] -and $selection.SelectedModel.UpstreamModel) {
        $selection.SelectedModel.UpstreamModel
    } else {
        $selection.SelectedModel.Slug
    }
    Write-Host "[ungate] Selected model: $($selection.SelectedModel.DisplayName) [$selectedModelId]." -ForegroundColor Cyan
    $historyProfile = Get-CodexHistoryProfileInfo -HomePath $Context.CustomCodexHome -CanonicalHomePath $Context.CanonicalCodexHome -ModelSlug $selectedModelId -ProviderName $selection.SelectedModel.ProviderName
    Write-CodexHistoryProfileDiagnostics -Context $Context -Profile $historyProfile

    $codexBeta = Get-CodexBetaPackageInfo
    if (-not $Context.Options.PrepareOnly) {
        Stop-CodexBeta -ExecutablePath $codexBeta.ExecutablePath
    }
    $transport = Initialize-CodexDesktopTransport -Context $Context -Selection $selection
    Initialize-CodexDesktopProfile -Context $Context -Selection $selection -codexBeta $codexBeta -providerKeys $transport.ProviderKeys -selectedKey $transport.SelectedKey
    if ($Context.Options.PrepareOnly) {
        if ($transport.PreflightFailure) {
            Write-Host '[ungate] Preparation finished with preflight warning. Desktop launch skipped.' -ForegroundColor Yellow
            return 2
        }
        Write-Host '[ungate] Preparation passed. Desktop launch skipped.' -ForegroundColor Green
        return 0
    }
    Start-CodexDesktopSession -Context $Context -Selection $selection -codexBeta $codexBeta -providerKeys $transport.ProviderKeys
    return 0
}

Export-ModuleMember -Function @('Invoke-CodexDesktopLauncher')
