#requires -Version 7.4
<#
.SYNOPSIS
    Starts Codex Beta with an isolated Ungate configuration.

.DESCRIPTION
    Creates ~/.codex-ungate/config.toml from the normal Codex config on first
    use, mirrors the normal Codex MCP server configuration, exposes the
    configured Ungate models through the Desktop picker, selects
    ungate-opus-4-8 by default, and launches Codex Beta with a process-local
    CODEX_HOME.

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
$CliProxyUpstreamBaseUrl = 'http://127.0.0.1:8317'
$CliProxyBaseUrl = 'http://127.0.0.1:8318'
$CliProxyProviderName = 'cliproxyapi'
$CliProxyConfigPath = 'J:\Sandbox\CLIProxyAPI\config.yaml'
$CliProxyBridgePath = Join-Path $PSScriptRoot 'cliproxy-namespace-bridge.mjs'
$CliProxyBridgeServiceName = 'cliproxy-namespace-bridge'
$PluginIsolationModulePath = Join-Path $PSScriptRoot 'codex-plugin-isolation.psm1'
$CodexPackageLaunchHelperPath = Join-Path $PSScriptRoot 'start-codex-beta-package-process.ps1'
if (-not (Test-Path -LiteralPath $PluginIsolationModulePath -PathType Leaf)) {
    throw "Codex plugin isolation module not found at $PluginIsolationModulePath."
}
if (-not (Test-Path -LiteralPath $CodexPackageLaunchHelperPath -PathType Leaf)) {
    throw "Codex Beta package launch helper not found at $CodexPackageLaunchHelperPath."
}
Import-Module $PluginIsolationModulePath -Force
$UngateEnvironmentInstruction = @'
Execution environment: Windows 11. The shell is PowerShell 7.

HARD RULE — source edits:
- Call the apply_patch tool for every manual source-file edit or file creation.
  Do not type apply_patch inside Shell.
- Use Shell only for inspection, execution, formatting, and verification.
- Do not edit source through Set-Content, Add-Content, WriteAllText, Python,
  Node.js, or a generated temporary edit script while apply_patch is available.
- Never nest PowerShell here-strings or wrap source containing @' / '@ / @" / "@
  inside another here-string.
- PowerShell is not Bash. Never use <<EOF or python - <<'PY'.
- The js tool is a V8 orchestration isolate, not Node.js. Do not use require,
  fs, path, or filesystem access there.
- After editing a .ps1 file, validate it with Parser.ParseFile.
- After an edit-related ParserError, do not retry with another quoting wrapper;
  switch directly to apply_patch.

Images / vision:
- If the user attaches an image (LocalImage, input_image, data:image/..., or <image ... path=...>),
  it is already in the model context. Answer from that attachment directly.
- NEVER use Read, exec_command, Shell, or any file tool to open/view an attached image path.
  That produces: Cannot read "image.png" (this model does not support image input).
- Only use filesystem tools for non-image files, or when the user asks to inspect binary/metadata
  offline and no vision attachment is present.
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
        Description = 'Grok 4.5 through the local CLIProxyAPI compatibility bridge on port 8318.'
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

function Get-CliProxyBridgeHealth {
    try {
        $health = Invoke-RestMethod `
            -Uri "$CliProxyBaseUrl/_bridge/health" `
            -TimeoutSec 2 `
            -ErrorAction Stop
        return $health
    }
    catch {
        return $null
    }
}

function Test-LocalTcpListener {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Test-CliProxyBridgeProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    $process = Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction SilentlyContinue
    if (-not $process -or [string]::IsNullOrWhiteSpace($process.CommandLine)) {
        return $false
    }

    $expectedPath = [System.IO.Path]::GetFullPath($CliProxyBridgePath)
    return $process.CommandLine.IndexOf(
        $expectedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

function Ensure-CliProxyBridge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $CliProxyBridgePath -PathType Leaf)) {
        throw "CLIProxy compatibility bridge not found at $CliProxyBridgePath."
    }

    try {
        $null = Invoke-RestMethod `
            -Uri "$CliProxyUpstreamBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "CLIProxyAPI upstream at $CliProxyUpstreamBaseUrl is not reachable: $($_.Exception.Message)"
    }
    Write-Host "[ungate] CLIProxyAPI upstream healthy at $CliProxyUpstreamBaseUrl." -ForegroundColor Green

    $expectedBuildId = (Get-FileHash -LiteralPath $CliProxyBridgePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedUpstream = $CliProxyUpstreamBaseUrl.TrimEnd('/')
    $bridgeListening = Test-LocalTcpListener -Port 8318
    $health = if ($bridgeListening) { Get-CliProxyBridgeHealth } else { $null }
    $bridgeReady = $false

    if ($health) {
        if ($health.status -ne 'ok' -or $health.service -ne $CliProxyBridgeServiceName) {
            throw "Port 8318 is occupied by an unexpected HTTP service. Refusing to stop it."
        }

        $sameBuild = [string]$health.build_id -eq $expectedBuildId
        $sameUpstream = ([string]$health.upstream).TrimEnd('/') -eq $expectedUpstream
        if ($sameBuild -and $sameUpstream) {
            $bridgeReady = $true
            Write-Host "[ungate] Reusing CLIProxy compatibility bridge (PID $($health.pid))." -ForegroundColor DarkGray
        }
        else {
            $bridgeProcessId = [int]$health.pid
            if (-not (Test-CliProxyBridgeProcessIdentity -ProcessId $bridgeProcessId)) {
                throw "Port 8318 reports a stale bridge, but PID $bridgeProcessId does not run $CliProxyBridgePath. Refusing to stop it."
            }

            Write-Host "[ungate] Restarting stale CLIProxy compatibility bridge (PID $bridgeProcessId)..." -ForegroundColor Yellow
            Stop-Process -Id $bridgeProcessId -Force -ErrorAction Stop
            $stopDeadline = (Get-Date).AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
            } while (
                (Test-LocalTcpListener -Port 8318) -and
                (Get-Date) -lt $stopDeadline
            )
            if (Test-LocalTcpListener -Port 8318) {
                throw 'The stale CLIProxy compatibility bridge did not release port 8318.'
            }
        }
    }
    elseif ($bridgeListening) {
        throw "Port 8318 is occupied, but /_bridge/health did not identify the compatibility bridge. Refusing to stop it."
    }

    if (-not $bridgeReady) {
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
        if (-not $nodeCommand -or -not (Test-Path -LiteralPath $nodeCommand.Source -PathType Leaf)) {
            throw 'node.exe is required to run the CLIProxy compatibility bridge.'
        }

        $logDirectory = Join-Path $CustomCodexHome 'logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $stdoutPath = Join-Path $logDirectory 'cliproxy-namespace-bridge.out.log'
        $stderrPath = Join-Path $logDirectory 'cliproxy-namespace-bridge.err.log'
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

        $bridgeEnvironment = @{
            CLIPROXY_BRIDGE_HOST = '127.0.0.1'
            CLIPROXY_BRIDGE_PORT = '8318'
            CLIPROXY_UPSTREAM = $CliProxyUpstreamBaseUrl
            CLIPROXY_BRIDGE_BUILD_ID = $expectedBuildId
            CLIPROXY_BRIDGE_MAX_BODY_BYTES = '134217728'
        }
        $bridgeProcess = Start-Process `
            -FilePath ([string]$nodeCommand.Source) `
            -ArgumentList @("`"$CliProxyBridgePath`"") `
            -WorkingDirectory $RepoRoot `
            -WindowStyle Hidden `
            -Environment $bridgeEnvironment `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru

        $startDeadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 200
            $bridgeProcess.Refresh()
            if ($bridgeProcess.HasExited) {
                $bridgeError = Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue
                throw "CLIProxy compatibility bridge exited with code $($bridgeProcess.ExitCode). $($bridgeError -join ' ')"
            }
            $health = Get-CliProxyBridgeHealth
        } while (-not $health -and (Get-Date) -lt $startDeadline)

        if (
            -not $health -or
            $health.status -ne 'ok' -or
            $health.service -ne $CliProxyBridgeServiceName -or
            [string]$health.build_id -ne $expectedBuildId -or
            ([string]$health.upstream).TrimEnd('/') -ne $expectedUpstream
        ) {
            Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
            throw "CLIProxy compatibility bridge failed its startup health check at $CliProxyBaseUrl."
        }
        Write-Host "[ungate] CLIProxy compatibility bridge started at $CliProxyBaseUrl (PID $($health.pid))." -ForegroundColor Green
    }

    try {
        $null = Invoke-RestMethod `
            -Uri "$CliProxyBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "CLIProxy compatibility bridge could not proxy /v1/models: $($_.Exception.Message)"
    }
    Write-Host '[ungate] CLIProxy compatibility bridge proxy check passed.' -ForegroundColor Green
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

function Get-TomlTableFamilyContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $capture = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches[1].Trim()
            $capture = (
                $currentTable -eq $TableName -or
                $currentTable.StartsWith("$TableName.", [System.StringComparison]::Ordinal)
            )
        }

        if ($capture) {
            $result.Add($line)
        }
    }

    return ($result -join "`r`n").Trim()
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

function Sync-CodexGlobalInstructions {
    $sourceInstructions = Join-Path $DefaultCodexHome 'AGENTS.md'
    $targetInstructions = Join-Path $CustomCodexHome 'AGENTS.md'

    if (-not (Test-Path -LiteralPath $sourceInstructions -PathType Leaf)) {
        throw "Default Codex global instructions not found at $sourceInstructions."
    }
    if (
        (Test-Path -LiteralPath $targetInstructions) -and
        -not (Test-Path -LiteralPath $targetInstructions -PathType Leaf)
    ) {
        throw "Custom Codex global instructions target is not a file: $targetInstructions"
    }

    New-Item -ItemType Directory -Path $CustomCodexHome -Force | Out-Null
    $sourceHash = (Get-FileHash -LiteralPath $sourceInstructions -Algorithm SHA256).Hash
    $targetHash = if (Test-Path -LiteralPath $targetInstructions -PathType Leaf) {
        (Get-FileHash -LiteralPath $targetInstructions -Algorithm SHA256).Hash
    }
    else {
        $null
    }

    if ($sourceHash -eq $targetHash) {
        Write-Host '[ungate] Global AGENTS.md already synchronized.' -ForegroundColor DarkGray
        return
    }

    Copy-Item `
        -LiteralPath $sourceInstructions `
        -Destination $targetInstructions `
        -Force
    $targetHash = (Get-FileHash -LiteralPath $targetInstructions -Algorithm SHA256).Hash
    if ($targetHash -ne $sourceHash) {
        throw "Failed to verify synchronized global instructions at $targetInstructions."
    }
    Write-Host '[ungate] Global AGENTS.md synchronized from the default Codex home.' -ForegroundColor Green
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

function Test-CodexMcpConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexExecutable,
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHome
        $inventoryOutput = @(& $CodexExecutable mcp list --json 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "Codex rejected the MCP configuration in $CodexHome."
        }

        try {
            $inventory = ($inventoryOutput -join "`n") | ConvertFrom-Json -Depth 100
        }
        catch {
            throw "Codex returned invalid MCP inventory JSON for $CodexHome."
        }

        return @(
            $inventory |
                ForEach-Object { [string]$_.name } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    finally {
        if ($null -eq $previousCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_HOME = $previousCodexHome
        }
    }
}

function Sync-CodexMcpServers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceCodexHome,
        [Parameter(Mandatory = $true)]
        [string]$TargetCodexHome
    )

    $sourceConfigPath = Join-Path $SourceCodexHome 'config.toml'
    $targetConfigPath = Join-Path $TargetCodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)) {
        throw "Default Codex config not found at $sourceConfigPath."
    }
    if (-not (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) {
        throw "Custom Codex config not found at $targetConfigPath."
    }

    $codexExecutable = Get-CodexCliExecutable
    if (-not $codexExecutable) {
        throw 'Codex CLI is required to synchronize MCP servers.'
    }

    # Validate the source before reading or changing the isolated config.
    $null = Test-CodexMcpConfiguration `
        -CodexExecutable $codexExecutable `
        -CodexHome $SourceCodexHome

    $sourceConfig = Get-Content -LiteralPath $sourceConfigPath -Raw
    $targetConfig = Get-Content -LiteralPath $targetConfigPath -Raw
    $sourceMcpContent = Get-TomlTableFamilyContent `
        -Content $sourceConfig `
        -TableName 'mcp_servers'
    $targetMcpContent = Get-TomlTableFamilyContent `
        -Content $targetConfig `
        -TableName 'mcp_servers'

    if ($sourceMcpContent -ceq $targetMcpContent) {
        $null = Test-CodexMcpConfiguration `
            -CodexExecutable $codexExecutable `
            -CodexHome $TargetCodexHome
        Write-Host '[ungate] MCP servers already synchronized.' -ForegroundColor DarkGray
        return
    }

    $targetWithoutMcp = (
        Remove-TomlTable -Content $targetConfig -TableName 'mcp_servers'
    ).TrimEnd()
    $updatedTargetConfig = if ([string]::IsNullOrWhiteSpace($sourceMcpContent)) {
        $targetWithoutMcp + "`r`n"
    }
    else {
        $targetWithoutMcp + "`r`n`r`n" + $sourceMcpContent + "`r`n"
    }

    $targetDirectory = Split-Path -Parent $targetConfigPath
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryConfigPath = Join-Path $targetDirectory ".config.toml.$transactionId.tmp"
    $backupConfigPath = Join-Path $targetDirectory ".config.toml.$transactionId.bak"
    $preserveBackup = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryConfigPath,
            $updatedTargetConfig,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Replace(
            $temporaryConfigPath,
            $targetConfigPath,
            $backupConfigPath
        )

        try {
            $null = Test-CodexMcpConfiguration `
                -CodexExecutable $codexExecutable `
                -CodexHome $TargetCodexHome
            $verifiedConfig = Get-Content -LiteralPath $targetConfigPath -Raw
            $verifiedMcpContent = Get-TomlTableFamilyContent `
                -Content $verifiedConfig `
                -TableName 'mcp_servers'
            if ($verifiedMcpContent -cne $sourceMcpContent) {
                throw 'The synchronized MCP table family does not match the source.'
            }
        }
        catch {
            $validationError = $_.Exception.Message
            try {
                [System.IO.File]::Copy($backupConfigPath, $targetConfigPath, $true)
            }
            catch {
                $preserveBackup = $true
                throw "MCP synchronization failed and automatic recovery failed. Backup retained at $backupConfigPath."
            }
            throw "MCP synchronization failed; the previous Beta config was restored. $validationError"
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryConfigPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryConfigPath -Force
        }
        if (
            -not $preserveBackup -and
            (Test-Path -LiteralPath $backupConfigPath -PathType Leaf)
        ) {
            Remove-Item -LiteralPath $backupConfigPath -Force
        }
    }

    Write-Host '[ungate] MCP servers synchronized from the default Codex home.' -ForegroundColor Green
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

function Get-CodexBetaPackageInfo {
    $package = Get-AppxPackage -Name OpenAI.CodexBeta |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        throw 'Codex Beta package OpenAI.CodexBeta is not installed for the current user.'
    }

    $manifest = Get-AppxPackageManifest -Package $package
    foreach ($application in @($manifest.Package.Applications.Application)) {
        $relativeExecutable = [string]$application.Executable
        if (-not $relativeExecutable) {
            continue
        }
        $normalizedPath = $relativeExecutable.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $executable = Join-Path $package.InstallLocation $normalizedPath
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            $bundledMarketplace = Join-Path `
                $package.InstallLocation `
                'app\resources\plugins\openai-bundled'
            if (-not (Test-Path -LiteralPath $bundledMarketplace -PathType Container)) {
                throw "Codex Beta bundled plugin marketplace was not found at $bundledMarketplace."
            }

            return [pscustomobject]@{
                ExecutablePath = $executable
                InstallLocation = [string]$package.InstallLocation
                Version = [string]$package.Version
                BundledMarketplacePath = $bundledMarketplace
                PackageFamilyName = [string]$package.PackageFamilyName
                ApplicationId = [string]$application.Id
            }
        }
    }

    throw "Codex Beta executable from the AppX manifest was not found under $($package.InstallLocation)."
}

function Start-CodexBetaDesktop {
    param(
        [Parameter(Mandatory)][psobject]$PackageInfo,
        [Parameter(Mandatory)][hashtable]$LaunchEnvironment,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    try {
        Start-Process `
            -FilePath ([string]$PackageInfo.ExecutablePath) `
            -WorkingDirectory $WorkingDirectory `
            -Environment $LaunchEnvironment `
            -ErrorAction Stop
        return
    }
    catch {
        $directLaunchError = $_.Exception.Message
    }

    $pipeName = 'ungate-codex-beta-' + [guid]::NewGuid().ToString('N')
    $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    $job = $null
    try {
        $powerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
        $job = Start-Job -ArgumentList @(
            [string]$PackageInfo.PackageFamilyName,
            [string]$PackageInfo.ApplicationId,
            $powerShellPath,
            $CodexPackageLaunchHelperPath,
            $pipeName,
            [string]$PackageInfo.ExecutablePath,
            $WorkingDirectory
        ) -ScriptBlock {
            param(
                $PackageFamilyName,
                $ApplicationId,
                $PowerShellPath,
                $HelperPath,
                $PipeName,
                $ExecutablePath,
                $WorkingDirectory
            )

            $arguments = @(
                '-NoProfile',
                '-WindowStyle', 'Hidden',
                '-File', "`"$HelperPath`"",
                '-PipeName', "`"$PipeName`"",
                '-ExecutablePath', "`"$ExecutablePath`"",
                '-WorkingDirectory', "`"$WorkingDirectory`""
            ) -join ' '
            Invoke-CommandInDesktopPackage `
                -PackageFamilyName $PackageFamilyName `
                -AppId $ApplicationId `
                -Command $PowerShellPath `
                -Args $arguments `
                -PreventBreakaway `
                -ErrorAction Stop
        }

        $connectTask = $pipe.WaitForConnectionAsync()
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds(20))) {
            throw 'Timed out waiting for the Codex Beta package launch helper.'
        }
        $connectTask.GetAwaiter().GetResult()

        $encoding = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($pipe, $encoding, $false, 1024, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, $encoding, 1024, $true)
        $writer.AutoFlush = $true
        try {
            $writer.WriteLine(($LaunchEnvironment | ConvertTo-Json -Compress))
            $responseTask = $reader.ReadLineAsync()
            if (-not $responseTask.Wait([TimeSpan]::FromSeconds(20))) {
                throw 'Timed out while Codex Beta was starting inside its package.'
            }
            $response = $responseTask.GetAwaiter().GetResult()
        }
        finally {
            $writer.Dispose()
            $reader.Dispose()
        }

        if ($response -notmatch '^OK:(?<processId>\d+)$') {
            throw "The Codex Beta package launch helper failed: $response"
        }
        $completedJob = Wait-Job -Job $job -Timeout 20
        if (-not $completedJob -or $job.State -ne 'Completed') {
            $jobReason = $job.ChildJobs[0].JobStateInfo.Reason
            $reason = if ($jobReason) { $jobReason.Message } else { "job state is $($job.State)" }
            throw "The Codex Beta package command failed: $reason"
        }

        Write-Host `
            "[ungate] Codex Beta started inside its MSIX package (PID $($Matches.processId))." `
            -ForegroundColor DarkGray
    }
    catch {
        throw "Direct Codex Beta launch failed ($directLaunchError). MSIX package launch also failed: $($_.Exception.Message)"
    }
    finally {
        $pipe.Dispose()
        if ($job) {
            if ($job.State -in @('Running', 'NotStarted', 'Blocked')) {
                Stop-Job -Job $job
            }
            Remove-Job -Job $job -Force
        }
    }
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

$codexBeta = Get-CodexBetaPackageInfo
$desktopExecutable = $codexBeta.ExecutablePath
if (-not $PrepareOnly) {
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

Ensure-CliProxyBridge -Key $providerKeys[$CliProxyProviderName]

$selectedKey = $providerKeys[$selectedModelDefinition.ProviderName]
try {
    if ($selectedModelDefinition.RequiresUngate) {
        Invoke-UngatePreflight `
            -Key $selectedKey `
            -Model $Model `
            -ProxyBaseUrl $selectedModelDefinition.ProxyBaseUrl
    }
    else {
        # CLIProxyAPI has no /health, so validate both discovery and a minimal live inference.
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
        Test-CliProxyResponsesInference `
            -Key $selectedKey `
            -Model $Model `
            -ProxyOpenAiBaseUrl "$($selectedModelDefinition.ProxyBaseUrl)/v1"
        Write-Host `
            "[ungate] Live /v1/responses inference preflight passed for '$Model'." `
            -ForegroundColor Green
    }
}
catch {
    Write-Host '[ungate] Preflight failed.' -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Yellow
    exit 2
}

Initialize-UngateCodexConfig
Sync-CodexMcpServers `
    -SourceCodexHome $DefaultCodexHome `
    -TargetCodexHome $CustomCodexHome
Write-UngateModelCatalog
Ensure-SharedDirectory -Name 'skills'
Sync-CodexGlobalInstructions
Sync-CodexAuthentication
$codexExecutable = Get-CodexCliExecutable
if (-not $codexExecutable) {
    throw 'Codex CLI is required to prepare the isolated Codex Beta plugin store.'
}
$betaIsRunning = @(Get-CodexBetaProcesses -ExecutablePath $desktopExecutable).Count -gt 0
$pluginIsolation = Initialize-CodexBetaPluginIsolation `
    -DefaultCodexHome $DefaultCodexHome `
    -CustomCodexHome $CustomCodexHome `
    -CodexExecutable $codexExecutable `
    -BetaBundledMarketplace $codexBeta.BundledMarketplacePath `
    -BetaPackageVersion $codexBeta.Version `
    -BetaIsRunning $betaIsRunning
if ($pluginIsolation.Changed) {
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
Start-CodexBetaDesktop `
    -PackageInfo $codexBeta `
    -LaunchEnvironment $launchEnv `
    -WorkingDirectory $RepoRoot
