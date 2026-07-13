#requires -Version 7.4
<#
.SYNOPSIS
    Starts Codex Beta with an isolated Ungate configuration.

.DESCRIPTION
    Creates ~/.codex-ungate/config.toml from the normal Codex config on first
    use, exposes the configured Ungate models through the Desktop picker,
    selects ungate-opus-4-8 by default, and launches Codex Beta with a
    process-local CODEX_HOME.

    The normal ~/.codex/config.toml is never modified. Codex Beta must be
    fully closed before launching this isolated instance.

.PARAMETER ApiKey
    Ungate API key. If omitted, uses UNGATE_API_KEY or ~/.ungate/data.db.

.PARAMETER Model
    Ungate model id selected by default in Desktop. When omitted during a
    normal launch, the script displays a numeric model menu. PrepareOnly uses
    ungate-opus-4-8 by default without prompting.

.PARAMETER CustomCodexHome
    Isolated Codex home (default: ~/.codex-ungate).

.PARAMETER PrepareOnly
    Prepare and validate the custom configuration without launching Desktop.

.PARAMETER SkipWorkspaceRestore
    Skip restoring active-workspace-roots from project-order / saved roots.

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 -PrepareOnly
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Model = 'ungate-opus-4-8',
    [string]$CustomCodexHome = (Join-Path $HOME '.codex-ungate'),
    [switch]$PrepareOnly,
    [switch]$SkipWorkspaceRestore
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$DefaultCodexHome = Join-Path $HOME '.codex'
$DefaultConfigPath = Join-Path $DefaultCodexHome 'config.toml'
$CustomConfigPath = Join-Path $CustomCodexHome 'config.toml'
$DefaultModelCachePath = Join-Path $DefaultCodexHome 'models_cache.json'
$CustomModelCatalogPath = Join-Path $CustomCodexHome 'ungate-models.json'
$CustomGlobalStatePath = Join-Path $CustomCodexHome '.codex-global-state.json'
$ProxyBaseUrl = 'http://127.0.0.1:47821'
$ProviderName = 'ungate_proxy'
$CliProxyBaseUrl = 'http://127.0.0.1:8317'
$CliProxyProviderName = 'cliproxyapi'
$CliProxyConfigPath = 'J:\Sandbox\CLIProxyAPI\config.yaml'
$UngateEnvironmentInstruction = @'
Execution environment: Windows 11 with PowerShell 7.

HARD RULE — PowerShell quoting (follow every time):
1) If a command needs nested quotes, $variables as literals, or multi-line code:
   write a .ps1 file first (single-quoted here-string @' ... '@), then run it.
   Never pass complex PowerShell as one inline shell argument.
2) Never put $Projects, $_, $script:Name, $(), or nested ' / " inside a
   double-quoted PowerShell string meant to stay literal.
3) Prefer single-quoted strings. For multi-line source use @' ... '@.
4) Escape `$ with a backtick only for tiny one-line literals.

WRONG (inline, expands $Projects, breaks on quotes):
  pwsh -Command "Set-Content a.ps1 -Value \"`$Projects = @()\""

RIGHT (script file, no expansion):
  @'
  $Projects = @()
  Write-Host 'dp graphify'
  '@ | Set-Content -Path .\tmp-edit.ps1 -Encoding utf8
  pwsh -File .\tmp-edit.ps1

Source edits:
- Prefer a narrow patch; do not rewrite a whole file with Set-Content for a small change.
- After every edit: git diff. If corrupted, fix the smallest broken section before more edits.
- Verify with Select-String -Path or rg -n. Never pipe Get-Content -Raw into Select-String.

Images / vision:
- If the user attaches an image (LocalImage, input_image, data:image/..., or <image ... path=...>),
  it is already in the model context. Answer from that attachment directly.
- NEVER use Read, exec_command, Shell, or any file tool to open/view an attached image path.
  That produces: Cannot read "image.png" (this model does not support image input).
- Only use filesystem tools for non-image files, or when the user asks to inspect binary/metadata
  offline and no vision attachment is present.

Do not end a turn after saying you will repair next: run the repair/verify tool in the same turn unless blocked.
'@
$UngateModelDefinitions = @(
    [pscustomobject][ordered]@{
        Slug = 'ungate-opus-4-8'
        DisplayName = 'Claude Opus 4.8 (Ungate)'
        Description = 'Claude Opus 4.8 through the local Ungate Responses proxy.'
        Identity = ('You are Codex, a coding agent powered by Claude Opus 4.8 through the local Ungate proxy. When asked which model you are using, identify it as Claude Opus 4.8 via Ungate and do not claim to be a GPT model.' + "`r`n`r`n" + $UngateEnvironmentInstruction)
        DefaultReasoningLevel = 'high'
        Priority = 0
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $ProviderName
        ProviderDisplayName = 'Ungate Proxy'
        ProxyBaseUrl = $ProxyBaseUrl
        EnvKey = 'UNGATE_API_KEY'
        RequiresUngate = $true
    }
    [pscustomobject][ordered]@{
        Slug = 'ungate-fable-5'
        DisplayName = 'Claude Fable 5 (Ungate)'
        Description = 'Claude Fable 5 through the local Ungate Responses proxy.'
        Identity = ('You are Codex, a coding agent powered by Claude Fable 5 through the local Ungate proxy. When asked which model you are using, identify it as Claude Fable 5 via Ungate and do not claim to be a GPT model.' + "`r`n`r`n" + $UngateEnvironmentInstruction)
        DefaultReasoningLevel = 'high'
        Priority = 1
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $ProviderName
        ProviderDisplayName = 'Ungate Proxy'
        ProxyBaseUrl = $ProxyBaseUrl
        EnvKey = 'UNGATE_API_KEY'
        RequiresUngate = $true
    }
    [pscustomobject][ordered]@{
        Slug = 'miniMax-M3'
        DisplayName = 'MiniMax M3 (Ungate)'
        Description = 'MiniMax M3 through the local Ungate Responses proxy with image input support.'
        Identity = ('You are Codex, a coding agent powered by MiniMax M3 through the local Ungate proxy. When asked which model you are using, identify it as MiniMax M3 via Ungate and do not claim to be a GPT model.' + "`r`n`r`n" + $UngateEnvironmentInstruction)
        DefaultReasoningLevel = 'xhigh'
        Priority = 2
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $ProviderName
        ProviderDisplayName = 'Ungate Proxy'
        ProxyBaseUrl = $ProxyBaseUrl
        EnvKey = 'UNGATE_API_KEY'
        RequiresUngate = $true
    }
    [pscustomobject][ordered]@{
        # Exact upstream id from CLIProxyAPI /v1/models
        Slug = 'grok-4.5'
        DisplayName = 'Grok 4.5 (CLIProxyAPI)'
        Description = 'Grok 4.5 through local CLIProxyAPI Responses proxy on port 8317.'
        Identity = ('You are Codex, a coding agent powered by Grok 4.5 through the local CLIProxyAPI proxy. When asked which model you are using, identify it as Grok 4.5 via CLIProxyAPI and do not claim to be a GPT model.' + "`r`n`r`n" + $UngateEnvironmentInstruction)
        DefaultReasoningLevel = 'high'
        Priority = 3
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $CliProxyProviderName
        ProviderDisplayName = 'CLIProxyAPI'
        ProxyBaseUrl = $CliProxyBaseUrl
        EnvKey = 'CLIPROXYAPI_API_KEY'
        RequiresUngate = $false
    }
)

. (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')

function Get-ProviderDefinitions {
    $byName = [ordered]@{}
    foreach ($definition in $UngateModelDefinitions) {
        if (-not $byName.Contains($definition.ProviderName)) {
            $byName[$definition.ProviderName] = [pscustomobject][ordered]@{
                Name = $definition.ProviderName
                DisplayName = $definition.ProviderDisplayName
                ProxyBaseUrl = $definition.ProxyBaseUrl
                EnvKey = $definition.EnvKey
            }
        }
    }
    return @($byName.Values)
}

function Resolve-CliProxyApiKey {
    if ($env:CLIPROXYAPI_API_KEY) {
        return $env:CLIPROXYAPI_API_KEY
    }

    if (-not (Test-Path -LiteralPath $CliProxyConfigPath)) {
        throw "CLIProxyAPI config not found at $CliProxyConfigPath."
    }

    $lines = Get-Content -LiteralPath $CliProxyConfigPath
    $inApiKeys = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*api-keys:\s*$') {
            $inApiKeys = $true
            continue
        }
        if ($inApiKeys) {
            if ($line -match '^\S') {
                break
            }
            if ($line -match '^\s*-\s*(?:"([^"]+)"|''([^'']+)''|(\S+))\s*$') {
                $key = $Matches[1]
                if (-not $key) { $key = $Matches[2] }
                if (-not $key) { $key = $Matches[3] }
                if ($key) {
                    return $key
                }
            }
        }
    }

    throw "Could not find api-keys in $CliProxyConfigPath. Set CLIPROXYAPI_API_KEY or add api-keys to the config."
}

function Resolve-ModelApiKey {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition,
        [string]$ApiKey
    )

    if ($Definition.RequiresUngate) {
        return Resolve-UngateApiKey -ApiKey $ApiKey -RepoRoot $RepoRoot
    }

    if ($ApiKey) {
        return $ApiKey
    }

    return Resolve-CliProxyApiKey
}

function Get-ProviderTomlBlock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Provider
    )

    return @"

[model_providers.$($Provider.Name)]
name = "$($Provider.DisplayName)"
base_url = "$($Provider.ProxyBaseUrl)/v1"
env_key = "$($Provider.EnvKey)"
wire_api = "responses"
"@
}

function Ensure-ModelProvidersInConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $updated = $Content
    foreach ($provider in (Get-ProviderDefinitions)) {
        $updated = Remove-TomlTable -Content $updated -TableName "model_providers.$($provider.Name)"
        $updated = $updated.TrimEnd() + "`r`n" + (Get-ProviderTomlBlock -Provider $provider).TrimStart() + "`r`n"
    }
    return $updated
}

function Select-UngateDesktopModel {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions
    )

    Write-Host ''
    Write-Host 'Select a model for Codex Beta:' -ForegroundColor Cyan
    for ($index = 0; $index -lt $Definitions.Count; $index++) {
        $defaultLabel = if ($index -eq 0) { ' (default)' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f ($index + 1), $Definitions[$index].DisplayName, $defaultLabel)
    }
    Write-Host ''

    while ($true) {
        $choice = Read-Host "Model [1-$($Definitions.Count)] (default: 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $Definitions[0].Slug
        }

        $selectedNumber = 0
        if (
            [int]::TryParse($choice, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $Definitions.Count
        ) {
            return $Definitions[$selectedNumber - 1].Slug
        }

        Write-Host "Enter a number from 1 to $($Definitions.Count)." -ForegroundColor Yellow
    }
}

function Set-TopLevelTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$TomlValue
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split '\r?\n'))
    $firstTableIndex = $lines.Count
    $found = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[') {
            $firstTableIndex = $index
            break
        }
        if ($lines[$index] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$index] = "$Key = $TomlValue"
            $found = $true
            break
        }
    }

    if (-not $found) {
        $lines.Insert($firstTableIndex, "$Key = $TomlValue")
    }

    return $lines -join "`r`n"
}

function Remove-TomlTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $skip = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches[1].Trim()
            if ($currentTable -eq $TableName -or $currentTable.StartsWith("$TableName.")) {
                $skip = $true
                continue
            }
            $skip = $false
        }

        if (-not $skip) {
            $result.Add($line)
        }
    }

    return $result -join "`r`n"
}

function Initialize-UngateCodexConfig {
    if (Test-Path -LiteralPath $CustomConfigPath) {
        Write-Host "[ungate] Using existing custom config: $CustomConfigPath" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $DefaultConfigPath)) {
        throw "Default Codex config not found at $DefaultConfigPath."
    }

    New-Item -ItemType Directory -Path $CustomCodexHome -Force | Out-Null

    $config = Get-Content -LiteralPath $DefaultConfigPath -Raw
    $config = Set-TopLevelTomlValue -Content $config -Key 'model' -TomlValue "`"$Model`""
    $config = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model_provider' `
        -TomlValue "`"$($selectedModelDefinition.ProviderName)`""
    $config = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model_reasoning_effort' `
        -TomlValue "`"$($selectedModelDefinition.DefaultReasoningLevel)`""
    $config = Ensure-ModelProvidersInConfig -Content $config
    [System.IO.File]::WriteAllText(
        $CustomConfigPath,
        $config,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "[ungate] Created custom config: $CustomConfigPath" -ForegroundColor Green
}

function Set-ModelIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instructions,
        [Parameter(Mandatory = $true)]
        [string]$Identity
	)

	$firstLine = [regex]::new('\A[^\r\n]*(?:\r?\n)?')
	$replacement = [System.Text.RegularExpressions.MatchEvaluator]{
		param([System.Text.RegularExpressions.Match]$Match)

		return "$Identity`r`n"
	}

	return $firstLine.Replace($Instructions, $replacement, 1)
}

function Write-UngateModelCatalog {
    if (-not (Test-Path -LiteralPath $DefaultModelCachePath)) {
        throw "Default Codex model cache not found at $DefaultModelCachePath. Launch normal Codex Desktop once, then retry."
    }

    $defaultCatalog = Get-Content -LiteralPath $DefaultModelCachePath -Raw |
        ConvertFrom-Json -Depth 100
    $modelTemplate = $defaultCatalog.models |
        Where-Object { $_.slug -eq 'gpt-5.4' } |
        Select-Object -First 1
    if (-not $modelTemplate) {
        $modelTemplate = $defaultCatalog.models | Select-Object -First 1
    }
    if (-not $modelTemplate) {
        throw "Default Codex model cache at $DefaultModelCachePath contains no models."
    }

    $catalogModels = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $UngateModelDefinitions) {
        $modelInfo = $modelTemplate |
            ConvertTo-Json -Depth 100 |
            ConvertFrom-Json -Depth 100
        $overrides = [ordered]@{
            slug = $definition.Slug
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
            base_instructions = Set-ModelIdentity `
                -Instructions $modelInfo.base_instructions `
                -Identity $definition.Identity
            supports_reasoning_summaries = $false
            default_reasoning_summary = 'none'
            support_verbosity = $false
            default_verbosity = $null
            context_window = 200000
            max_context_window = 200000
            auto_compact_token_limit = $null
            comp_hash = $null
            supports_search_tool = $false
            use_responses_lite = $false
            input_modalities = @($definition.InputModalities)
            supports_image_detail_original = [bool]$definition.SupportsImageDetailOriginal
            web_search_tool_type = [string]$definition.WebSearchToolType
        }
        foreach ($override in $overrides.GetEnumerator()) {
            $modelInfo | Add-Member `
                -MemberType NoteProperty `
                -Name $override.Key `
                -Value $override.Value `
                -Force
        }

        if ($modelInfo.model_messages -and $modelInfo.model_messages.instructions_template) {
            $modelInfo.model_messages.instructions_template = Set-ModelIdentity `
                -Instructions $modelInfo.model_messages.instructions_template `
                -Identity $definition.Identity
        }

        [void]$catalogModels.Add($modelInfo)
    }

    $catalog = [ordered]@{ models = @($catalogModels) }
    $json = $catalog | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $CustomModelCatalogPath,
        $json + "`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    $config = Get-Content -LiteralPath $CustomConfigPath -Raw
    $escapedCatalogPath = $CustomModelCatalogPath.Replace('\', '\\').Replace('"', '\"')
    $catalogPathToml = "`"$escapedCatalogPath`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model' `
        -TomlValue "`"$Model`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_provider' `
        -TomlValue "`"$($selectedModelDefinition.ProviderName)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_reasoning_effort' `
        -TomlValue "`"$($selectedModelDefinition.DefaultReasoningLevel)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_catalog_json' `
        -TomlValue $catalogPathToml
    $updatedConfig = Ensure-ModelProvidersInConfig -Content $updatedConfig
    if ($updatedConfig -ne $config) {
        [System.IO.File]::WriteAllText(
            $CustomConfigPath,
            $updatedConfig,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    Write-Host "[ungate] Model catalog ready: $CustomModelCatalogPath" -ForegroundColor Green
}

function Ensure-SharedDirectory {
    param([Parameter(Mandatory = $true)][string]$Name)

    $source = Join-Path $DefaultCodexHome $Name
    $target = Join-Path $CustomCodexHome $Name
    if (-not (Test-Path -LiteralPath $source)) {
        return
    }

    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        $targetPath = @($item.Target)[0]
        if (-not $isReparsePoint -or -not $targetPath) {
            throw "$target already exists and is not a directory junction."
        }

        $resolvedSource = [System.IO.Path]::GetFullPath($source)
        $resolvedTarget = [System.IO.Path]::GetFullPath($targetPath)
        if ($resolvedSource -ne $resolvedTarget) {
            throw "$target points to '$targetPath', expected '$source'."
        }
        return
    }

    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    Write-Host "[ungate] Shared Codex directory: $Name" -ForegroundColor DarkGray
}

function Sync-CodexAuthentication {
    $sourceAuth = Join-Path $DefaultCodexHome 'auth.json'
    if (Test-Path -LiteralPath $sourceAuth) {
        Copy-Item -LiteralPath $sourceAuth -Destination (Join-Path $CustomCodexHome 'auth.json') -Force
    }
}

function Get-CodexCliExecutable {
    foreach ($configPath in @($DefaultConfigPath, $CustomConfigPath)) {
        if (-not (Test-Path -LiteralPath $configPath)) {
            continue
        }

        $config = Get-Content -LiteralPath $configPath -Raw
        $configuredCliMatch = [regex]::Match(
            $config,
            "(?m)^CODEX_CLI_PATH\s*=\s*['`"]([^'`"]+)['`"]\s*$"
        )
        if ($configuredCliMatch.Success) {
            $configuredCli = $configuredCliMatch.Groups[1].Value
            if (Test-Path -LiteralPath $configuredCli) {
                return $configuredCli
            }
        }
    }

    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($codex -and (Test-Path -LiteralPath $codex.Source)) {
        return $codex.Source
    }

    $localCodexBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $localCodexBin) {
        $codexExecutable = Get-ChildItem -LiteralPath $localCodexBin -Recurse -Filter codex.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($codexExecutable) {
            return $codexExecutable.FullName
        }
    }

    return $null
}

function Assert-UngateCodexConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [hashtable]$ProviderKeys
    )

    $config = Get-Content -LiteralPath $CustomConfigPath -Raw
    $selectedProvider = $selectedModelDefinition.ProviderName
    $selectedBaseUrl = $selectedModelDefinition.ProxyBaseUrl
    $selectedEnvKey = $selectedModelDefinition.EnvKey
    $checks = @(
        "(?m)^model\s*=\s*`"$([regex]::Escape($Model))`"\s*$",
        "(?m)^model_provider\s*=\s*`"$([regex]::Escape($selectedProvider))`"\s*$",
        '(?m)^model_catalog_json\s*=',
        "(?m)^\[model_providers\.$([regex]::Escape($selectedProvider))\]\s*$",
        "(?m)^base_url\s*=\s*`"$([regex]::Escape($selectedBaseUrl))/v1`"\s*$",
        "(?m)^env_key\s*=\s*`"$([regex]::Escape($selectedEnvKey))`"\s*$",
        '(?m)^wire_api\s*=\s*"responses"\s*$'
    )

    foreach ($pattern in $checks) {
        if ($config -notmatch $pattern) {
            throw "Custom Codex config failed validation: $CustomConfigPath"
        }
    }

    foreach ($provider in (Get-ProviderDefinitions)) {
        $providerChecks = @(
            "(?m)^\[model_providers\.$([regex]::Escape($provider.Name))\]\s*$",
            "(?m)^base_url\s*=\s*`"$([regex]::Escape($provider.ProxyBaseUrl))/v1`"\s*$",
            "(?m)^env_key\s*=\s*`"$([regex]::Escape($provider.EnvKey))`"\s*$"
        )
        foreach ($pattern in $providerChecks) {
            if ($config -notmatch $pattern) {
                throw "Provider '$($provider.Name)' missing/invalid in custom config: $CustomConfigPath"
            }
        }
    }

    $catalog = Get-Content -LiteralPath $CustomModelCatalogPath -Raw |
        ConvertFrom-Json -Depth 100
    $catalogModels = @($catalog.models)
    if ($catalogModels.Count -ne $UngateModelDefinitions.Count) {
        throw "Custom model catalog failed validation: $CustomModelCatalogPath"
    }
    foreach ($definition in $UngateModelDefinitions) {
        $catalogModel = $catalogModels |
            Where-Object { $_.slug -eq $definition.Slug } |
            Select-Object -First 1
        $catalogModalities = @($catalogModel.input_modalities | ForEach-Object { [string]$_ })
        $expectedModalities = @($definition.InputModalities | ForEach-Object { [string]$_ })
        $modalitiesMatch = (
            $catalogModalities.Count -eq $expectedModalities.Count -and
            -not (Compare-Object -ReferenceObject $expectedModalities -DifferenceObject $catalogModalities)
        )
        if (
            -not $catalogModel -or
            $catalogModel.display_name -ne $definition.DisplayName -or
            $catalogModel.visibility -ne 'list' -or
            -not ([string]$catalogModel.base_instructions).StartsWith($definition.Identity) -or
            -not $modalitiesMatch -or
            [bool]$catalogModel.supports_image_detail_original -ne [bool]$definition.SupportsImageDetailOriginal -or
            [string]$catalogModel.web_search_tool_type -ne [string]$definition.WebSearchToolType
        ) {
            throw "Custom model '$($definition.Slug)' failed validation: $CustomModelCatalogPath"
        }
    }

    foreach ($provider in (Get-ProviderDefinitions)) {
        $providerKey = $ProviderKeys[$provider.Name]
        if (-not $providerKey) {
            throw "Missing API key for provider '$($provider.Name)'."
        }

        $providerModels = @($UngateModelDefinitions | Where-Object { $_.ProviderName -eq $provider.Name })
        try {
            $availableModels = Invoke-RestMethod `
                -Uri "$($provider.ProxyBaseUrl)/v1/models" `
                -Headers @{ Authorization = "Bearer $providerKey" } `
                -TimeoutSec 5 `
                -ErrorAction Stop
        }
        catch {
            throw "Could not validate models for '$($provider.Name)' through $($provider.ProxyBaseUrl)/v1/models: $($_.Exception.Message)"
        }

        $availableModelIds = @($availableModels.data | ForEach-Object { $_.id })
        $missingModelIds = @($providerModels.Slug | Where-Object { $_ -notin $availableModelIds })
        if ($missingModelIds.Count -gt 0) {
            throw "Catalog models not found in $($provider.Name) /v1/models: $($missingModelIds -join ', ')"
        }
        Write-Host `
            "[ungate] $($provider.DisplayName) models available: $($providerModels.Slug -join ', ')." `
            -ForegroundColor Green
    }

    $codexExecutable = Get-CodexCliExecutable
    if ($codexExecutable) {
        $previousCodexHome = $env:CODEX_HOME
        $previousEnv = @{}
        foreach ($provider in (Get-ProviderDefinitions)) {
            $previousEnv[$provider.EnvKey] = [System.Environment]::GetEnvironmentVariable($provider.EnvKey)
            [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $ProviderKeys[$provider.Name])
        }
        try {
            $env:CODEX_HOME = $CustomCodexHome

            $supportsModelDebug = (& $codexExecutable debug models --help 2>$null) -match 'raw model catalog'
            if ($supportsModelDebug) {
                $rawCatalog = & $codexExecutable debug models 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $resolvedCatalog = ($rawCatalog -join "`n") | ConvertFrom-Json -Depth 100
                    $resolvedModels = @($resolvedCatalog.models)
                    if ($resolvedModels.Count -ne $UngateModelDefinitions.Count) {
                        throw 'Codex loaded an unexpected model catalog.'
                    }
                    foreach ($definition in $UngateModelDefinitions) {
                        $resolvedModel = $resolvedModels |
                            Where-Object { $_.slug -eq $definition.Slug } |
                            Select-Object -First 1
                        if (-not $resolvedModel -or $resolvedModel.display_name -ne $definition.DisplayName) {
                            throw "Codex did not load model '$($definition.Slug)' as expected."
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

            foreach ($provider in (Get-ProviderDefinitions)) {
                $previousValue = $previousEnv[$provider.EnvKey]
                if ($null -eq $previousValue) {
                    [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $null)
                } else {
                    [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $previousValue)
                }
            }
        }
    }
}

function Initialize-CodexWindowsSandbox {
    $config = Get-Content -LiteralPath $CustomConfigPath -Raw
    if ($config -match '(?m)^sandbox_mode\s*=\s*["'']danger-full-access["'']\s*$') {
        Write-Host `
            '[ungate] Windows sandbox initialization skipped (sandbox_mode=danger-full-access).' `
            -ForegroundColor DarkGray
        return
    }

    $codexExecutable = Get-CodexCliExecutable
    if (-not $codexExecutable) {
        throw 'Codex CLI is required to prepare the Windows sandbox.'
    }

    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CustomCodexHome
        & $codexExecutable sandbox cmd.exe /d /c exit 0 *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Codex Windows sandbox preparation failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        if ($null -eq $previousCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        } else {
            $env:CODEX_HOME = $previousCodexHome
        }
    }

    Write-Host '[ungate] Windows sandbox ready.' -ForegroundColor DarkGray
}

function Get-CodexBetaExecutable {
    $package = Get-AppxPackage -Name OpenAI.CodexBeta |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        throw 'Codex Beta package OpenAI.CodexBeta is not installed for the current user.'
    }

    $manifest = Get-AppxPackageManifest -Package $package
    $relativeExecutables = @(
        $manifest.Package.Applications.Application |
            ForEach-Object { [string]$_.Executable } |
            Where-Object { $_ }
    )

    foreach ($relativeExecutable in $relativeExecutables) {
        $normalizedPath = $relativeExecutable.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $executable = Join-Path $package.InstallLocation $normalizedPath
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            return $executable
        }
    }

    throw "Codex Beta executable from the AppX manifest was not found under $($package.InstallLocation)."
}

function Get-CodexBetaProcesses {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -ieq $ExecutablePath
    })
}

function Stop-CodexBeta {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

    $runningProcesses = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    if ($runningProcesses.Count -eq 0) {
        return
    }

    $initialCount = $runningProcesses.Count
    Write-Host "[ungate] Closing the running Codex Beta instance ($initialCount process(es))..." -ForegroundColor Yellow

    $closeRequested = $false
    foreach ($runningProcess in $runningProcesses) {
        $process = Get-Process -Id $runningProcess.ProcessId -ErrorAction SilentlyContinue
        if ($process -and $process.MainWindowHandle -ne 0) {
            $closeRequested = $process.CloseMainWindow() -or $closeRequested
        }
    }

    # Electron often keeps helper processes alive after the main window closes.
    $gracefulSeconds = if ($closeRequested) { 12 } else { 2 }
    $gracefulDeadline = (Get-Date).AddSeconds($gracefulSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $runningProcesses = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    } while ($runningProcesses.Count -gt 0 -and (Get-Date) -lt $gracefulDeadline)

    if ($runningProcesses.Count -eq 0) {
        Write-Host '[ungate] Previous Codex Beta instance closed.' -ForegroundColor Green
        return
    }

    # Normal path for Electron multi-process apps: finish residual helpers cleanly.
    Write-Host `
        "[ungate] Finishing residual Codex processes ($($runningProcesses.Count))..." `
        -ForegroundColor DarkGray
    foreach ($processId in @($runningProcesses.ProcessId)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }

    $forcedDeadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 200
        $runningProcesses = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    } while ($runningProcesses.Count -gt 0 -and (Get-Date) -lt $forcedDeadline)

    if ($runningProcesses.Count -gt 0) {
        throw "Codex Beta is still running after the automatic close attempt ($($runningProcesses.Count) process(es))."
    }

    Write-Host '[ungate] Previous Codex Beta instance closed.' -ForegroundColor Green
}

function Normalize-WorkspaceRootPath {
    param([AllowNull()][string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $normalized = $PathValue.Trim()
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }
    $normalized = $normalized.TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($normalized)
    }
    catch {
        return $normalized
    }
}

function Get-WorkspaceRootList {
    param([AllowNull()]$Value)

    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        $one = Normalize-WorkspaceRootPath -PathValue $Value
        if ($one) {
            [void]$result.Add($one)
        }
        return @($result)
    }

    foreach ($item in @($Value)) {
        $path = Normalize-WorkspaceRootPath -PathValue ([string]$item)
        if ($path) {
            [void]$result.Add($path)
        }
    }

    return @($result)
}

function Restore-CodexWorkspaceRoots {
    if ($SkipWorkspaceRestore) {
        Write-Host '[ungate] Workspace root restore skipped (-SkipWorkspaceRestore).' -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $CustomGlobalStatePath)) {
        Write-Host "[ungate] No global state yet: $CustomGlobalStatePath" -ForegroundColor DarkGray
        return
    }

    $raw = Get-Content -LiteralPath $CustomGlobalStatePath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host '[ungate] Global state is empty; workspace restore skipped.' -ForegroundColor DarkGray
        return
    }

    try {
        $state = $raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Failed to parse Codex global state at $CustomGlobalStatePath : $($_.Exception.Message)"
    }

    $orderRoots = @(Get-WorkspaceRootList -Value $state.'project-order')
    $savedRoots = @(Get-WorkspaceRootList -Value $state.'electron-saved-workspace-roots')
    $activeRoots = @(Get-WorkspaceRootList -Value $state.'active-workspace-roots')

    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($path in ($orderRoots + $savedRoots + $activeRoots)) {
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if (Test-Path -LiteralPath $path -PathType Container) {
            [void]$merged.Add($path)
        }
    }

    if ($merged.Count -eq 0) {
        Write-Host '[ungate] Restored 0 workspace roots (project-order/saved are empty or missing on disk).' -ForegroundColor DarkGray
        return
    }

    $backupPath = "$CustomGlobalStatePath.bak"
    Copy-Item -LiteralPath $CustomGlobalStatePath -Destination $backupPath -Force

    $state | Add-Member -MemberType NoteProperty -Name 'project-order' -Value @($merged) -Force
    $state | Add-Member -MemberType NoteProperty -Name 'electron-saved-workspace-roots' -Value @($merged) -Force
    $state | Add-Member -MemberType NoteProperty -Name 'active-workspace-roots' -Value @($merged) -Force

    $json = $state | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $CustomGlobalStatePath,
        $json + "`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "[ungate] Restored $($merged.Count) workspace roots from project-order ∪ saved roots." -ForegroundColor Green
}

if (-not $PrepareOnly -and -not $PSBoundParameters.ContainsKey('Model')) {
    $Model = Select-UngateDesktopModel -Definitions $UngateModelDefinitions
}

$selectedModelDefinition = $UngateModelDefinitions |
    Where-Object { $_.Slug -eq $Model } |
    Select-Object -First 1
if (-not $selectedModelDefinition) {
    $supportedModels = @($UngateModelDefinitions.Slug) -join ', '
    throw "Unsupported Desktop model '$Model'. Configured models: $supportedModels"
}
Write-Host `
    "[ungate] Selected model: $($selectedModelDefinition.DisplayName) [$Model]." `
    -ForegroundColor Cyan

$desktopExecutable = $null
if (-not $PrepareOnly) {
    $desktopExecutable = Get-CodexBetaExecutable
    Stop-CodexBeta -ExecutablePath $desktopExecutable
}

$providerKeys = @{}
foreach ($provider in (Get-ProviderDefinitions)) {
    $sampleDefinition = $UngateModelDefinitions |
        Where-Object { $_.ProviderName -eq $provider.Name } |
        Select-Object -First 1
    $providerKeys[$provider.Name] = Resolve-ModelApiKey `
        -Definition $sampleDefinition `
        -ApiKey $(if ($selectedModelDefinition.ProviderName -eq $provider.Name) { $ApiKey } else { $null })
    Write-Host `
        "[ungate] $($provider.DisplayName) API key resolved (len=$($providerKeys[$provider.Name].Length))." `
        -ForegroundColor DarkGray
}

$selectedKey = $providerKeys[$selectedModelDefinition.ProviderName]
try {
    if ($selectedModelDefinition.RequiresUngate) {
        Invoke-UngatePreflight `
            -Key $selectedKey `
            -Model $Model `
            -ProxyBaseUrl $selectedModelDefinition.ProxyBaseUrl
    }
    else {
        # CLIProxyAPI has no /health and may hang on empty Responses input.
        # Validate model listing only; full /v1/responses is exercised at runtime.
        $models = Invoke-RestMethod `
            -Uri "$($selectedModelDefinition.ProxyBaseUrl)/v1/models" `
            -Headers @{ Authorization = "Bearer $selectedKey" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
        $ids = @($models.data | ForEach-Object { $_.id })
        if ($Model -notin $ids) {
            throw "Model '$Model' not found in $($selectedModelDefinition.ProxyBaseUrl)/v1/models. Available: $($ids -join ', ')"
        }
        Write-Host "[ungate] Proxy healthy at $($selectedModelDefinition.ProxyBaseUrl)." -ForegroundColor Green
        Write-Host "[ungate] Model '$Model' available." -ForegroundColor Green
        Write-Host '[ungate] /v1/responses bridge skipped for non-Ungate provider.' -ForegroundColor DarkGray
    }
}
catch {
    Write-Host '[ungate] Preflight failed.' -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

Initialize-UngateCodexConfig
Write-UngateModelCatalog
Ensure-SharedDirectory -Name 'skills'
Ensure-SharedDirectory -Name 'plugins'
Sync-CodexAuthentication
Assert-UngateCodexConfig -Key $selectedKey -ProviderKeys $providerKeys
Initialize-CodexWindowsSandbox
Write-Host "[ungate] Custom CODEX_HOME ready: $CustomCodexHome" -ForegroundColor Green
Restore-CodexWorkspaceRoots

if ($PrepareOnly) {
    Write-Host '[ungate] Preparation passed. Desktop launch skipped.' -ForegroundColor Green
    exit 0
}

Write-Host "[ungate] Launching Codex Beta with model '$Model' via $($selectedModelDefinition.ProviderName)." -ForegroundColor Green
$launchEnv = @{
    CODEX_HOME = $CustomCodexHome
}
foreach ($provider in (Get-ProviderDefinitions)) {
    $launchEnv[$provider.EnvKey] = $providerKeys[$provider.Name]
}
Start-Process `
    -FilePath ([string]$desktopExecutable) `
    -WorkingDirectory $RepoRoot `
    -Environment $launchEnv
