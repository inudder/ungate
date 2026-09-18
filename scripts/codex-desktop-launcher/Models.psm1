#requires -Version 7.4
# Models: internal Desktop launcher module. No per-launch module state.


function New-UngateModelSet {
    param([Parameter(Mandatory)][psobject]$Context)
    $ErrorActionPreference = 'Stop'

    $BuiltInUngateModelDefinitions = @(
        [pscustomobject][ordered]@{
            Slug = 'ungate-opus-4-8'
            DisplayName = 'Claude Opus 4.8 (Ungate)'
            Description = 'Claude Opus 4.8 through the local Ungate Responses proxy.'
            UpstreamModel = 'claude-opus-4-8'
            TransportDescription = 'the local Ungate Responses proxy'
            DefaultReasoningLevel = 'high'
            Priority = 0
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.ProviderName
            ProviderDisplayName = 'Ungate Proxy'
            ProxyBaseUrl = $Context.ProxyBaseUrl
            EnvKey = 'UNGATE_API_KEY'
            RequiresUngate = $true
        }
        [pscustomobject][ordered]@{
            Slug = 'ungate-fable-5'
            DisplayName = 'Claude Fable 5 (Ungate)'
            Description = 'Claude Fable 5 through the local Ungate Responses proxy.'
            UpstreamModel = 'claude-fable-5'
            TransportDescription = 'the local Ungate Responses proxy'
            DefaultReasoningLevel = 'high'
            Priority = 1
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.ProviderName
            ProviderDisplayName = 'Ungate Proxy'
            ProxyBaseUrl = $Context.ProxyBaseUrl
            EnvKey = 'UNGATE_API_KEY'
            RequiresUngate = $true
        }
        [pscustomobject][ordered]@{
            Slug = 'miniMax-M3'
            DisplayName = 'MiniMax M3 (Ungate)'
            Description = 'MiniMax M3 through the local Ungate Responses proxy with image input support.'
            ContextWindow = 1000000
            MaxContextWindow = 1000000
            # UpstreamModel intentionally left blank: MiniMax provider normalises
            # the model id from Codex's request body itself, so the launcher does
            # not need to know the literal id to put it in the identity string.
            TransportDescription = 'the local Ungate Responses proxy'
            DefaultReasoningLevel = 'xhigh'
            Priority = 2
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.ProviderName
            ProviderDisplayName = 'Ungate Proxy'
            ProxyBaseUrl = $Context.ProxyBaseUrl
            EnvKey = 'UNGATE_API_KEY'
            RequiresUngate = $true
        }
        [pscustomobject][ordered]@{
            # Upstream id accepted by CLIProxyAPI; its dynamic catalog can omit usable models.
            Slug = 'grok-4.6'
            DisplayName = 'Grok 4.6 (CLIProxyAPI)'
            Description = 'Grok 4.6 through the local CLIProxyAPI compatibility bridge on port 8318.'
            ContextWindow = 500000
            MaxContextWindow = 500000
            UpstreamModel = 'grok-4.6'
            TransportDescription = 'the local CLIProxyAPI compatibility bridge'
            DefaultReasoningLevel = 'high'
            Priority = 3
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.CliProxyProviderName
            ProviderDisplayName = 'CLIProxyAPI'
            ProxyBaseUrl = $Context.CliProxyBaseUrl
            EnvKey = 'CLIPROXYAPI_API_KEY'
            RequiresUngate = $false
        }
        [pscustomobject][ordered]@{
            Slug = 'apikey-fun/kimi-k3'
            DisplayName = 'Kimi K3 (OmniRoute)'
            Description = 'Kimi K3 through the local OmniRoute proxy on port 20128.'
            UpstreamModel = 'apikey-fun/kimi-k3'
            TransportDescription = 'the local OmniRoute proxy'
            DefaultReasoningLevel = 'high'
            Priority = 4
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.OmniRouteProviderName
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = $Context.OmniRouteBaseUrl
            EnvKey = 'OMNIROUTE_API_KEY'
            RequiresUngate = $false
        }
        [pscustomobject][ordered]@{
            Slug = 'apikey-fun/grok-4.5'
            DisplayName = 'Grok 4.5 (apikey.fun)'
            Description = 'Grok 4.5 via apikey.fun through the local OmniRoute proxy on port 20128.'
            UpstreamModel = 'apikey-fun/grok-4.5'
            TransportDescription = 'the local OmniRoute proxy'
            DefaultReasoningLevel = 'high'
            Priority = 5
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.OmniRouteProviderName
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = $Context.OmniRouteBaseUrl
            EnvKey = 'OMNIROUTE_API_KEY'
            RequiresUngate = $false
        }
        [pscustomobject][ordered]@{
            Slug = 'apikey-fun/claude-opus-5'
            DisplayName = 'Claude Opus 5 (apikey.fun)'
            Description = 'Claude Opus 5 via apikey.fun through the local OmniRoute proxy on port 20128.'
            UpstreamModel = 'apikey-fun/claude-opus-5'
            TransportDescription = 'the local OmniRoute proxy'
            DefaultReasoningLevel = 'high'
            Priority = 6
            InputModalities = @('text', 'image')
            SupportsImageDetailOriginal = $true
            WebSearchToolType = 'text_and_image'
            ProviderName = $Context.OmniRouteProviderName
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = $Context.OmniRouteBaseUrl
            EnvKey = 'OMNIROUTE_API_KEY'
            RequiresUngate = $false
        }
        [pscustomobject][ordered]@{
            Slug = 'mimo-v2.5-pro'
            DisplayName = 'Mimo v2.5 Pro (OmniRoute)'
            Description = 'Mimo v2.5 Pro through the local OmniRoute proxy on port 20128.'
            UpstreamModel = 'mimo-v2.5-pro'
            TransportDescription = 'the local OmniRoute proxy'
            DefaultReasoningLevel = 'high'
            Priority = 7
            InputModalities = @('text')
            SupportsImageDetailOriginal = $false
            WebSearchToolType = 'text'
            ProviderName = $Context.OmniRouteProviderName
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = $Context.OmniRouteBaseUrl
            EnvKey = 'OMNIROUTE_API_KEY'
            RequiresUngate = $false
            ContextWindow = 1000000
            MaxContextWindow = 1000000
            SupportsReasoningSummaries = $true
            SupportsParallelToolCalls = $false
            ResponsesAdapter = 'mimo-textual-tools'
            TruncationPolicy = @{ mode = 'bytes'; limit = 10000 }
            SupportedReasoningLevels = @(
                @{ effort = 'none'; description = 'Disable Thinking' },
                @{ effort = 'high'; description = 'Enabled Thinking' }
            )
        }
        [pscustomobject][ordered]@{
            Slug = 'deepseek-v4-pro'
            DisplayName = 'DeepSeek V4 Pro (OmniRoute)'
            Description = 'DeepSeek V4 Pro through the local OmniRoute proxy on port 20128.'
            UpstreamModel = 'deepseek/deepseek-v4-pro'
            Aliases = @('deepseek-pro', 'ds/deepseek-v4-pro')
            TransportDescription = 'the local OmniRoute proxy'
            DefaultReasoningLevel = 'high'
            Priority = 8
            InputModalities = @('text')
            SupportsImageDetailOriginal = $false
            WebSearchToolType = 'text'
            ProviderName = $Context.OmniRouteProviderName
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = $Context.OmniRouteBaseUrl
            EnvKey = 'OMNIROUTE_API_KEY'
            RequiresUngate = $false
            ContextWindow = 1000000
            MaxContextWindow = 1000000
            SupportsReasoningSummaries = $true
            SupportsParallelToolCalls = $true
            SupportedReasoningLevels = @(
                @{ effort = 'none'; description = 'Disable Thinking' },
                @{ effort = 'low'; description = 'Low Thinking' },
                @{ effort = 'high'; description = 'High Thinking' },
                @{ effort = 'max'; description = 'Max Thinking' }
            )
        }
        [pscustomobject][ordered]@{
            Slug = 'deepseek-v4-flash'
            DisplayName = 'DeepSeek V4 Flash (OmniRoute)'
            Description = 'DeepSeek V4 Flash through the local OmniRoute proxy on port 20128.'
            UpstreamModel = 'deepseek/deepseek-v4-flash'
            Aliases = @('deepseek-flash', 'deepseek/deepseek-flash', 'ds/deepseek-flash', 'ds/deepseek-v4-flash')
            TransportDescription = 'the local OmniRoute proxy'
            DefaultReasoningLevel = 'high'
            Priority = 9
            InputModalities = @('text')
            SupportsImageDetailOriginal = $false
            WebSearchToolType = 'text'
            ProviderName = $Context.OmniRouteProviderName
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = $Context.OmniRouteBaseUrl
            EnvKey = 'OMNIROUTE_API_KEY'
            RequiresUngate = $false
            ContextWindow = 1000000
            MaxContextWindow = 1000000
            SupportsReasoningSummaries = $true
            SupportsParallelToolCalls = $true
            SupportedReasoningLevels = @(
                @{ effort = 'none'; description = 'Disable Thinking' },
                @{ effort = 'low'; description = 'Low Thinking' },
                @{ effort = 'high'; description = 'High Thinking' },
                @{ effort = 'max'; description = 'Max Thinking' }
            )
        }
    )

    # Populate Identity uniformly through Get-UngateModelIdentity so built-ins and
    # the registry path share the same format. The helper drops the Codex
    # self-identification layer for Anthropic-prefixed models and keeps it for
    # everything else.
    $BuiltInUngateModelDefinitions = @(
        foreach ($def in $BuiltInUngateModelDefinitions) {
            $upstreamModelValue = $null
            if ($def.PSObject.Properties['UpstreamModel'] -and $def.UpstreamModel) {
                $upstreamModelValue = [string]$def.UpstreamModel
            }

            $identity = Get-UngateModelIdentity -Context $Context `
                -DisplayName ([string]$def.DisplayName) `
                -UpstreamModel $upstreamModelValue `
                -ProviderDisplayName ([string]$def.ProviderDisplayName) `
                -TransportDescription ([string]$def.TransportDescription)

            [pscustomobject][ordered]@{
                Slug = $def.Slug
                DisplayName = $def.DisplayName
                Description = $def.Description
                UpstreamModel = $upstreamModelValue
                Aliases = if ($def.PSObject.Properties['Aliases']) { $def.Aliases } else { $null }
                TransportDescription = $def.TransportDescription
                Identity = $identity
                DefaultReasoningLevel = $def.DefaultReasoningLevel
                Priority = $def.Priority
                InputModalities = $def.InputModalities
                SupportsImageDetailOriginal = $def.SupportsImageDetailOriginal
                WebSearchToolType = $def.WebSearchToolType
                ProviderName = $def.ProviderName
                ProviderDisplayName = $def.ProviderDisplayName
                ProxyBaseUrl = $def.ProxyBaseUrl
                EnvKey = $def.EnvKey
                RequiresUngate = $def.RequiresUngate
                ContextWindow = $def.ContextWindow
                MaxContextWindow = $def.MaxContextWindow
                EffectiveContextWindowPercent = $def.EffectiveContextWindowPercent
                SupportsReasoningSummaries = $def.SupportsReasoningSummaries
                SupportsParallelToolCalls = $def.SupportsParallelToolCalls
                ResponsesAdapter = if ($def.PSObject.Properties['ResponsesAdapter']) { [string]$def.ResponsesAdapter } else { $null }
                TruncationPolicy = $def.TruncationPolicy
                SupportedReasoningLevels = $def.SupportedReasoningLevels
            }
        }
    )

    $OmniRouteFallbackModelDefinition = [pscustomobject][ordered]@{
        Slug = $Context.OmniRouteFallbackModel
        DisplayName = 'Codex Provider Fallback (OmniRoute)'
        Description = 'Opt-in provider fallback through OmniRoute: Claude, Grok, MiniMax, then Gemini.'
        Identity = ('You are Codex using the local OmniRoute provider fallback. The active upstream may change between Claude, Grok, MiniMax, and Gemini when a provider is unavailable or its quota is exhausted.' + "`r`n`r`n" + $Context.UngateEnvironmentInstruction)
        DefaultReasoningLevel = 'high'
        Priority = 0
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $Context.OmniRouteProviderName
        ProviderDisplayName = 'OmniRoute'
        ProxyBaseUrl = $Context.OmniRouteBaseUrl
        EnvKey = 'OMNIROUTE_API_KEY'
        RequiresUngate = $false
    }

    return [pscustomobject]@{ BuiltInDefinitions = @($BuiltInUngateModelDefinitions); FallbackDefinition = $OmniRouteFallbackModelDefinition }
}

function Get-UngateModelIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter()][string]$UpstreamModel,
        [Parameter(Mandatory = $true)]
        [string]$ProviderDisplayName,
        [Parameter(Mandatory = $true)]
        [string]$TransportDescription
    )
    $ErrorActionPreference = 'Stop'

    # Anthropic-prefixed models already get the canonical "You are Claude Code,
    # Anthropic's official CLI for Claude." identity from the proxy in
    # apps/api/src/proxy/request-builder.ts (prepareClaudeCodeBody). The Codex
    # self-identification layer ("don't claim to be a GPT model") is pure
    # overhead for them, so we send only the environment instructions.
    $isAnthropicModel = $DisplayName -like 'Claude *' -or $DisplayName -like 'Anthropic *'

    if ($isAnthropicModel) {
        return $Context.UngateEnvironmentInstruction
    }

    $upstreamClause = if ($UpstreamModel) { " (upstream model $UpstreamModel)" } else { '' }

    return (
        "You are Codex, a coding agent powered by $DisplayName$upstreamClause through $TransportDescription. " +
        "When asked which model you are using, identify it as $DisplayName via $ProviderDisplayName and do not claim to be a GPT model." +
        "`r`n`r`n" +
        $Context.UngateEnvironmentInstruction
    )
}

function ConvertTo-UngateModelDefinition {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object]$Record,
        [Parameter(Mandatory = $true)]
        [int]$Priority
    )
    $ErrorActionPreference = 'Stop'

    $requiredProperties = @(
        'Slug',
        'DisplayName',
        'UpstreamModel',
        'Transport',
        'DefaultReasoningLevel',
        'SupportsImageInput'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($propertyName -notin $Record.PSObject.Properties.Name) {
            throw "Custom model record is missing required property '$propertyName'."
        }
    }

    $slug = ([string]$Record.Slug).Trim()
    $displayName = ([string]$Record.DisplayName).Trim()
    $upstreamModel = ([string]$Record.UpstreamModel).Trim()
    $transport = ([string]$Record.Transport).Trim().ToLowerInvariant()
    $reasoningLevel = ([string]$Record.DefaultReasoningLevel).Trim().ToLowerInvariant()

    if (-not $slug) {
        throw 'Custom model ID cannot be empty.'
    }
    if ($slug -match '\s|["'']') {
        throw "Custom model ID '$slug' cannot contain whitespace or quotes."
    }
    if (-not $displayName) {
        throw "Custom model '$slug' must have a display name."
    }
    if (-not $upstreamModel) {
        throw "Custom model '$slug' must have an upstream model ID."
    }
    if ($upstreamModel -match '\s|["'']') {
        throw "Upstream model ID '$upstreamModel' cannot contain whitespace or quotes."
    }
    if ($transport -notin @('ungate', 'cliproxyapi', 'omniroute')) {
        throw "Custom model '$slug' has unsupported transport '$transport'."
    }
    if ($reasoningLevel -notin @('low', 'medium', 'high', 'xhigh')) {
        throw "Custom model '$slug' has unsupported reasoning level '$reasoningLevel'."
    }
    if ($Record.SupportsImageInput -isnot [bool]) {
        throw "Custom model '$slug' property SupportsImageInput must be true or false."
    }

    if ($transport -eq 'ungate') {
        $providerNameForModel = $Context.ProviderName
        $providerDisplayName = 'Ungate Proxy'
        $proxyBaseUrlForModel = $Context.ProxyBaseUrl
        $environmentKey = 'UNGATE_API_KEY'
        $requiresUngate = $true
        $transportDescription = 'the local Ungate Responses proxy'
    }
    elseif ($transport -eq 'cliproxyapi') {
        $providerNameForModel = $Context.CliProxyProviderName
        $providerDisplayName = 'CLIProxyAPI'
        $proxyBaseUrlForModel = $Context.CliProxyBaseUrl
        $environmentKey = 'CLIPROXYAPI_API_KEY'
        $requiresUngate = $false
        $transportDescription = 'the local CLIProxyAPI compatibility bridge'
    }
    else {
        $providerNameForModel = $Context.OmniRouteProviderName
        $providerDisplayName = 'OmniRoute'
        $proxyBaseUrlForModel = $Context.OmniRouteBaseUrl
        $environmentKey = 'OMNIROUTE_API_KEY'
        $requiresUngate = $false
        $transportDescription = 'the local OmniRoute proxy'
    }

    $supportsImageInput = [bool]$Record.SupportsImageInput
    $inputModalities = if ($supportsImageInput) { @('text', 'image') } else { @('text') }
    $webSearchToolType = if ($supportsImageInput) { 'text_and_image' } else { 'text' }
    $description = "$displayName maps to upstream model '$upstreamModel' through $transportDescription."
    $identity = Get-UngateModelIdentity -Context $Context `
        -DisplayName $displayName `
        -UpstreamModel $upstreamModel `
        -ProviderDisplayName $providerDisplayName `
        -TransportDescription $transportDescription

    return [pscustomobject][ordered]@{
        Slug = $slug
        DisplayName = $displayName
        UpstreamModel = $upstreamModel
        Transport = $transport
        Description = $description
        Identity = $identity
        DefaultReasoningLevel = $reasoningLevel
        Priority = $Priority
        InputModalities = $inputModalities
        SupportsImageInput = $supportsImageInput
        SupportsImageDetailOriginal = $supportsImageInput
        WebSearchToolType = $webSearchToolType
        ProviderName = $providerNameForModel
        ProviderDisplayName = $providerDisplayName
        ProxyBaseUrl = $proxyBaseUrlForModel
        EnvKey = $environmentKey
        RequiresUngate = $requiresUngate
    }
}

function Read-UngateCustomModelDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions
    )
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        throw "Custom model registry is not a file: $RegistryPath"
    }

    try {
        $registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "Failed to parse custom model registry at $RegistryPath : $($_.Exception.Message)"
    }

    if ('Version' -notin $registry.PSObject.Properties.Name -or [int]$registry.Version -ne 1) {
        throw "Custom model registry at $RegistryPath has an unsupported or missing version."
    }
    if ('Models' -notin $registry.PSObject.Properties.Name) {
        throw "Custom model registry at $RegistryPath is missing the models array."
    }

    $seenSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($definition in $BuiltInDefinitions) {
        if (-not $seenSlugs.Add([string]$definition.Slug)) {
            throw "Built-in model ID '$($definition.Slug)' is duplicated."
        }
    }

    $definitions = [System.Collections.Generic.List[object]]::new()
    $priority = $BuiltInDefinitions.Count
    foreach ($record in @($registry.Models)) {
        $definition = ConvertTo-UngateModelDefinition -Context $Context -Record $record -Priority $priority
        if (-not $seenSlugs.Add($definition.Slug)) {
            throw "Custom model ID '$($definition.Slug)' duplicates an existing model."
        }
        [void]$definitions.Add($definition)
        $priority++
    }

    return @($definitions)
}

function Write-UngateCustomModelDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [object[]]$Records,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions
    )
    $ErrorActionPreference = 'Stop'

    $normalizedDefinitions = [System.Collections.Generic.List[object]]::new()
    $seenSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($definition in $BuiltInDefinitions) {
        if (-not $seenSlugs.Add([string]$definition.Slug)) {
            throw "Built-in model ID '$($definition.Slug)' is duplicated."
        }
    }

    $priority = $BuiltInDefinitions.Count
    foreach ($record in $Records) {
        $definition = ConvertTo-UngateModelDefinition -Context $Context -Record $record -Priority $priority
        if (-not $seenSlugs.Add($definition.Slug)) {
            throw "Custom model ID '$($definition.Slug)' duplicates an existing model."
        }
        [void]$normalizedDefinitions.Add($definition)
        $priority++
    }

    $persistentRecords = @(
        foreach ($definition in $normalizedDefinitions) {
            [ordered]@{
                slug = $definition.Slug
                displayName = $definition.DisplayName
                upstreamModel = $definition.UpstreamModel
                transport = $definition.Transport
                defaultReasoningLevel = $definition.DefaultReasoningLevel
                supportsImageInput = $definition.SupportsImageInput
            }
        }
    )
    $json = [ordered]@{
        version = 1
        models = $persistentRecords
    } | ConvertTo-Json -Depth 20

    $absoluteRegistryPath = [System.IO.Path]::GetFullPath($RegistryPath)
    if (
        (Test-Path -LiteralPath $absoluteRegistryPath) -and
        -not (Test-Path -LiteralPath $absoluteRegistryPath -PathType Leaf)
    ) {
        throw "Custom model registry target is not a file: $absoluteRegistryPath"
    }

    $registryDirectory = Split-Path -Parent $absoluteRegistryPath
    New-Item -ItemType Directory -Path $registryDirectory -Force | Out-Null
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $registryDirectory ".ungate-model-definitions.$transactionId.tmp"
    $backupPath = Join-Path $registryDirectory ".ungate-model-definitions.$transactionId.bak"
    $writeCompleted = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json + "`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $absoluteRegistryPath -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $absoluteRegistryPath,
                $backupPath,
                $true
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $absoluteRegistryPath)
        }
        $writeCompleted = $true
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if ($writeCompleted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }

    return $absoluteRegistryPath
}

function Get-UngateModelDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions,
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )
    $ErrorActionPreference = 'Stop'

    $customDefinitions = @(
        Read-UngateCustomModelDefinitions -Context $Context `
            -RegistryPath $RegistryPath `
            -BuiltInDefinitions $BuiltInDefinitions
    )
    return @($BuiltInDefinitions) + $customDefinitions
}

function Get-UngateModelContextWindow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition
    )
    $ErrorActionPreference = 'Stop'

    $contextWindow = if (
        $Definition.PSObject.Properties['ContextWindow'] -and
        $null -ne $Definition.ContextWindow
    ) {
        [int]$Definition.ContextWindow
    }
    else {
        200000
    }
    $maxContextWindow = if (
        $Definition.PSObject.Properties['MaxContextWindow'] -and
        $null -ne $Definition.MaxContextWindow
    ) {
        [int]$Definition.MaxContextWindow
    }
    else {
        200000
    }
    $percent = if (
        $Definition.PSObject.Properties['EffectiveContextWindowPercent'] -and
        $null -ne $Definition.EffectiveContextWindowPercent
    ) {
        [int]$Definition.EffectiveContextWindowPercent
    }
    else {
        100
    }

    $compact = if ($contextWindow -ge 1000000 -and ($contextWindow % 1000000) -eq 0) {
        '{0}M' -f [int]($contextWindow / 1000000)
    }
    elseif ($contextWindow -ge 1000 -and ($contextWindow % 1000) -eq 0) {
        '{0}k' -f [int]($contextWindow / 1000)
    }
    else {
        [string]$contextWindow
    }

    $label = if ($percent -ne 100) {
        '{0} @ {1}%' -f $compact, $percent
    }
    else {
        $compact
    }

    return [pscustomobject][ordered]@{
        ContextWindow = $contextWindow
        MaxContextWindow = $maxContextWindow
        EffectiveContextWindowPercent = $percent
        Label = $label
    }
}

Export-ModuleMember -Function @(
    'Get-UngateModelIdentity',
    'ConvertTo-UngateModelDefinition',
    'Read-UngateCustomModelDefinitions',
    'Write-UngateCustomModelDefinitions',
    'Get-UngateModelDefinitions',
    'Get-UngateModelContextWindow',
    'New-UngateModelSet'
)
