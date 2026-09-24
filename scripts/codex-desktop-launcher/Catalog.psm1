#requires -Version 7.4
# Catalog: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Routing.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Toml.psm1') -DisableNameChecking -ErrorAction Stop

function Set-ModelIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instructions,
        [Parameter(Mandatory = $true)]
        [string]$Identity
	)
    $ErrorActionPreference = 'Stop'

	$firstLine = [regex]::new('\A[^\r\n]*(?:\r?\n)?')
	$replacement = [System.Text.RegularExpressions.MatchEvaluator]{
		param([System.Text.RegularExpressions.Match]$Match)

		return "$Identity`r`n"
	}

	return $firstLine.Replace($Instructions, $replacement, 1)
}

function Write-UngateModelCatalog {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'

    $catalogTemplatePath = if (Test-Path -LiteralPath $Context.DefaultModelCachePath -PathType Leaf) {
        $Context.DefaultModelCachePath
    } elseif (Test-Path -LiteralPath $Context.CustomModelCatalogPath -PathType Leaf) {
        # Cockpit-managed normal profiles do not always retain a default
        # models_cache.json. A prior launcher catalog has the same schema and
        # is safe as the template for replacing its managed entries.
        $Context.CustomModelCatalogPath
    } else {
        throw "No Codex model catalog template was found at $($Context.DefaultModelCachePath) or $($Context.CustomModelCatalogPath). Launch normal Codex Desktop once, then retry."
    }

    $defaultCatalog = Get-Content -LiteralPath $catalogTemplatePath -Raw |
        ConvertFrom-Json -Depth 100
    $fallbackModelTemplate = $defaultCatalog.models |
        Where-Object { $_.slug -eq 'gpt-5.4' } |
        Select-Object -First 1
    if (-not $fallbackModelTemplate) {
        $fallbackModelTemplate = $defaultCatalog.models | Select-Object -First 1
    }
    if (-not $fallbackModelTemplate) {
        throw "Codex model catalog template at $catalogTemplatePath contains no models."
    }

    $catalogModels = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $Selection.Definitions) {
        $catalogSlug = Get-CodexCatalogModelSlug -Selection $Selection -Definition $definition
        $modelTemplate = $defaultCatalog.models |
            Where-Object { $_.slug -eq $catalogSlug } |
            Select-Object -First 1
        if (-not $modelTemplate) {
            $modelTemplate = $fallbackModelTemplate
        }
        $modelInfo = $modelTemplate |
            ConvertTo-Json -Depth 100 |
            ConvertFrom-Json -Depth 100
        $supportsParallelToolCalls = if ($null -ne $definition.SupportsParallelToolCalls) {
            [bool]$definition.SupportsParallelToolCalls
        }
        elseif ($modelInfo.PSObject.Properties['supports_parallel_tool_calls']) {
            [bool]$modelInfo.supports_parallel_tool_calls
        }
        else {
            # The Codex model-catalog schema requires this field even when the
            # models cache used as a template omits it. Prefer a conservative
            # serial-tool fallback for custom providers.
            $false
        }
        $contextWindow = Get-UngateModelContextWindow -Definition $definition
        $overrides = [ordered]@{
            slug = $catalogSlug
            display_name = $definition.DisplayName
            description = $definition.Description
            default_reasoning_level = $definition.DefaultReasoningLevel
            visibility = 'list'
            supported_in_api = $true
            priority = $definition.Priority
            additional_speed_tiers = @()
            service_tiers = @()
            default_service_tier = $null
            availability_nux = $null
            upgrade = $null
            supports_reasoning_summaries = if ($null -ne $definition.SupportsReasoningSummaries) { [bool]$definition.SupportsReasoningSummaries } else { $false }
            default_reasoning_summary = 'none'
            support_verbosity = $false
            default_verbosity = $null
            context_window = $contextWindow.ContextWindow
            max_context_window = $contextWindow.MaxContextWindow
            effective_context_window_percent = $contextWindow.EffectiveContextWindowPercent
            auto_compact_token_limit = $null
            comp_hash = $null
            supports_search_tool = $false
            use_responses_lite = $false
            input_modalities = @($definition.InputModalities)
            supports_parallel_tool_calls = $supportsParallelToolCalls
            supports_image_detail_original = [bool]$definition.SupportsImageDetailOriginal
            web_search_tool_type = [string]$definition.WebSearchToolType
        }

        $baseInstructions = if (
            $modelInfo.PSObject.Properties['base_instructions'] -and
            -not [string]::IsNullOrWhiteSpace([string]$modelInfo.base_instructions)
        ) {
            [string]$modelInfo.base_instructions
        }
        else {
            $null
        }
        $instructionsTemplate = if (
            $modelInfo.model_messages -and
            -not [string]::IsNullOrWhiteSpace([string]$modelInfo.model_messages.instructions_template)
        ) {
            [string]$modelInfo.model_messages.instructions_template
        }
        else {
            $null
        }
        if (-not $baseInstructions -and -not $instructionsTemplate) {
            throw "Codex model catalog template for '$catalogSlug' has no usable instruction template."
        }

        # Newer catalog caches put instructions in model_messages, while the
        # currently installed Codex CLI still requires base_instructions. Keep
        # both fields aligned, deriving the legacy field from the template.
        $baseInstructionSource = if ($baseInstructions) {
            $baseInstructions
        }
        else {
            $instructionsTemplate
        }
        $overrides.base_instructions = Set-ModelIdentity `
            -Instructions $baseInstructionSource `
            -Identity $definition.Identity

        if ($null -ne $definition.TruncationPolicy) {
            $overrides.truncation_policy = $definition.TruncationPolicy
        }
        if ($null -ne $definition.SupportedReasoningLevels) {
            $overrides.supported_reasoning_levels = $definition.SupportedReasoningLevels
        }
        foreach ($override in $overrides.GetEnumerator()) {
            $modelInfo | Add-Member `
                -MemberType NoteProperty `
                -Name $override.Key `
                -Value $override.Value `
                -Force
        }

        if ($instructionsTemplate) {
            $modelInfo.model_messages.instructions_template = Set-ModelIdentity `
                -Instructions $instructionsTemplate `
                -Identity $definition.Identity
        }

        [void]$catalogModels.Add($modelInfo)
    }

    $catalog = [ordered]@{ models = @($catalogModels) }
    $json = $catalog | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $Context.CustomModelCatalogPath,
        $json + "`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    $config = Get-Content -LiteralPath $Context.CustomConfigPath -Raw
    $escapedCatalogPath = $Context.CustomModelCatalogPath.Replace('\', '\\').Replace('"', '\"')
    $catalogPathToml = "`"$escapedCatalogPath`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model' `
        -TomlValue "`"$($Selection.LaunchModel)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_provider' `
        -TomlValue "`"$($Selection.LaunchProvider.Name)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_reasoning_effort' `
        -TomlValue "`"$($Selection.SelectedModel.DefaultReasoningLevel)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_catalog_json' `
        -TomlValue $catalogPathToml
    $updatedConfig = Ensure-ModelProvidersInConfig -Context $Context -Selection $Selection -Content $updatedConfig
    if ($updatedConfig -ne $config) {
        [System.IO.File]::WriteAllText(
            $Context.CustomConfigPath,
            $updatedConfig,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    Write-Host "[ungate] Model catalog ready: $($Context.CustomModelCatalogPath)" -ForegroundColor Green
}

function Assert-UngateCodexConfig {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection,

        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [hashtable]$ProviderKeys
    )
    $ErrorActionPreference = 'Stop'

    $config = Get-Content -LiteralPath $Context.CustomConfigPath -Raw
    $selectedProvider = $Selection.LaunchProvider.Name
    $selectedBaseUrl = $Selection.LaunchProvider.ProxyBaseUrl
    $selectedEnvKey = $Selection.LaunchProvider.EnvKey
    $checks = @(
        "(?m)^model\s*=\s*`"$([regex]::Escape($Selection.LaunchModel))`"\s*$",
        "(?m)^model_provider\s*=\s*`"$([regex]::Escape($selectedProvider))`"\s*$",
        '(?m)^model_catalog_json\s*=',
        "(?m)^\[model_providers\.$([regex]::Escape($selectedProvider))\]\s*$",
        "(?m)^base_url\s*=\s*`"$([regex]::Escape($selectedBaseUrl))/v1`"\s*$",
        "(?m)^env_key\s*=\s*`"$([regex]::Escape($selectedEnvKey))`"\s*$",
        '(?m)^wire_api\s*=\s*"responses"\s*$'
    )

    foreach ($pattern in $checks) {
        if ($config -notmatch $pattern) {
            throw "Custom Codex config failed validation: $($Context.CustomConfigPath)"
        }
    }

    foreach ($provider in (Get-CodexConfigProviderDefinitions -Context $Context -Selection $Selection)) {
        $providerChecks = @(
            "(?m)^\[model_providers\.$([regex]::Escape($provider.Name))\]\s*$",
            "(?m)^base_url\s*=\s*`"$([regex]::Escape($provider.ProxyBaseUrl))/v1`"\s*$",
            "(?m)^env_key\s*=\s*`"$([regex]::Escape($provider.EnvKey))`"\s*$"
        )
        foreach ($pattern in $providerChecks) {
            if ($config -notmatch $pattern) {
                throw "Provider '$($provider.Name)' missing/invalid in custom config: $($Context.CustomConfigPath)"
            }
        }
    }

    $catalog = Get-Content -LiteralPath $Context.CustomModelCatalogPath -Raw |
        ConvertFrom-Json -Depth 100
    $catalogModels = @($catalog.models)
    if ($catalogModels.Count -ne $Selection.Definitions.Count) {
        throw "Custom model catalog failed validation: $($Context.CustomModelCatalogPath)"
    }
    foreach ($definition in $Selection.Definitions) {
        $catalogSlug = Get-CodexCatalogModelSlug -Selection $Selection -Definition $definition
        $catalogModel = $catalogModels |
            Where-Object { $_.slug -eq $catalogSlug } |
            Select-Object -First 1
        $catalogModalities = @($catalogModel.input_modalities | ForEach-Object { [string]$_ })
        $expectedModalities = @($definition.InputModalities | ForEach-Object { [string]$_ })
        $modalitiesMatch = (
            $catalogModalities.Count -eq $expectedModalities.Count -and
            -not (Compare-Object -ReferenceObject $expectedModalities -DifferenceObject $catalogModalities)
        )
        $catalogInstructions = if (
            $catalogModel.model_messages -and
            -not [string]::IsNullOrWhiteSpace([string]$catalogModel.model_messages.instructions_template)
        ) {
            [string]$catalogModel.model_messages.instructions_template
        }
        else {
            [string]$catalogModel.base_instructions
        }
        $catalogBaseInstructions = [string]$catalogModel.base_instructions
        $parallelToolCallProperty = if ($catalogModel) {
            $catalogModel.PSObject.Properties['supports_parallel_tool_calls']
        }
        else {
            $null
        }
        $parallelToolCallsValid = (
            $null -ne $parallelToolCallProperty -and
            $parallelToolCallProperty.Value -is [bool] -and
            (
                $null -eq $definition.SupportsParallelToolCalls -or
                [bool]$parallelToolCallProperty.Value -eq [bool]$definition.SupportsParallelToolCalls
            )
        )
        if (
            -not $catalogModel -or
            $catalogModel.display_name -ne $definition.DisplayName -or
            $catalogModel.visibility -ne 'list' -or
            -not $catalogInstructions.StartsWith($definition.Identity) -or
            -not $catalogBaseInstructions.StartsWith($definition.Identity) -or
            -not $modalitiesMatch -or
            -not $parallelToolCallsValid -or
            [bool]$catalogModel.supports_image_detail_original -ne [bool]$definition.SupportsImageDetailOriginal -or
            [string]$catalogModel.web_search_tool_type -ne [string]$definition.WebSearchToolType
        ) {
            throw "Custom model '$($definition.DisplayName)' failed validation: $($Context.CustomModelCatalogPath)"
        }
    }

    foreach ($provider in (Get-ProviderDefinitions -Selection $Selection)) {
        $providerKey = $ProviderKeys[$provider.Name]
        if (-not $providerKey) {
            throw "Missing API key for provider '$($provider.Name)'."
        }

        $providerModels = @($Selection.Definitions | Where-Object { $_.ProviderName -eq $provider.Name })
        try {
            $availableModels = Invoke-RestMethod `
                -Uri "$($provider.ProxyBaseUrl)/v1/models" `
                -Headers @{ Authorization = "Bearer $providerKey" } `
                -TimeoutSec 5 `
                -ErrorAction Stop
            $availableModelIds = @($availableModels.data | ForEach-Object { $_.id })
            $effectiveModels = @($providerModels | ForEach-Object {
                if ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel) {
                    $_.UpstreamModel
                } else {
                    $_.Slug
                }
            })
            $missingModelIds = @($effectiveModels | Where-Object {
                $m = $_
                -not ($availableModelIds | Where-Object { $_ -eq $m -or $_ -like "*/$m" -or $m -like "*/$_" })
            })
            if ($missingModelIds.Count -gt 0) {
                Write-Host `
                    "[ungate] Warning: catalog models not found in $($provider.Name) /v1/models: $($missingModelIds -join ', ')" `
                    -ForegroundColor Yellow
            }
            else {
                Write-Host `
                    "[ungate] $($provider.DisplayName) models available: $($effectiveModels -join ', ')." `
                    -ForegroundColor Green
            }
        }
        catch {
            Write-Host `
                "[ungate] Warning: could not validate models for '$($provider.Name)' through $($provider.ProxyBaseUrl)/v1/models: $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    }

    $codexExecutable = Get-CodexCliExecutable -Context $Context
    if ($codexExecutable) {
        $previousCodexHome = $env:CODEX_HOME
        $previousEnv = @{}
        foreach ($provider in (Get-ProviderDefinitions -Selection $Selection)) {
            $previousEnv[$provider.EnvKey] = [System.Environment]::GetEnvironmentVariable($provider.EnvKey)
            [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $ProviderKeys[$provider.Name])
        }
        try {
            $env:CODEX_HOME = $Context.CustomCodexHome

            $supportsModelDebug = (& $codexExecutable debug models --help 2>$null) -match 'raw model catalog'
            if ($supportsModelDebug) {
                $rawCatalog = & $codexExecutable debug models 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $resolvedCatalog = ($rawCatalog -join "`n") | ConvertFrom-Json -Depth 100
                    $resolvedModels = @($resolvedCatalog.models)
                    if ($resolvedModels.Count -ne $Selection.Definitions.Count) {
                        throw 'Codex loaded an unexpected model catalog.'
                    }
                    foreach ($definition in $Selection.Definitions) {
                        $catalogSlug = Get-CodexCatalogModelSlug -Selection $Selection -Definition $definition
                        $resolvedModel = $resolvedModels |
                            Where-Object { $_.slug -eq $catalogSlug } |
                            Select-Object -First 1
                        if (-not $resolvedModel -or $resolvedModel.display_name -ne $definition.DisplayName) {
                            throw "Codex did not load model '$($definition.DisplayName)' as expected."
                        }
                    }
                }
            } else {
                & $codexExecutable features list *> $null
            }

            if ($LASTEXITCODE -ne 0) {
                throw "Codex rejected the custom config with exit code $LASTEXITCODE."
            }
        }
        finally {
            if ($null -eq $previousCodexHome) {
                Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
            } else {
                $env:CODEX_HOME = $previousCodexHome
            }

            foreach ($provider in (Get-ProviderDefinitions -Selection $Selection)) {
                $previousValue = $previousEnv[$provider.EnvKey]
                if ($null -eq $previousValue) {
                    Remove-Item -LiteralPath "Env:$($provider.EnvKey)" -ErrorAction SilentlyContinue
                } else {
                    [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $previousValue)
                }
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Write-UngateModelCatalog',
    'Assert-UngateCodexConfig'
)
