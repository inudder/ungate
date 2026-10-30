#requires -Version 7.4
# Models: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'ModelCapabilities.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'LauncherLock.psm1') -DisableNameChecking -ErrorAction Stop


function New-UngateModelSet {
    param([Parameter(Mandatory)][psobject]$Context)
    $ErrorActionPreference = 'Stop'

    $templateDefinitions = @(Get-UngateTemplateModelDefinitions -Context $Context)
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

    return [pscustomobject]@{ BuiltInDefinitions = @($templateDefinitions); FallbackDefinition = $OmniRouteFallbackModelDefinition }
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

function Get-UngateRecordProperty {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($property in @($Record.PSObject.Properties)) {
        if ($property.Name -eq $Name) { return $property }
    }
    return $null
}

function Get-UngateTransportProfile {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Transport
    )
    $ErrorActionPreference = 'Stop'
    switch ($Transport) {
        'ungate' {
            return [pscustomobject]@{
                ProviderName = $Context.ProviderName
                ProviderDisplayName = 'Ungate Proxy'
                ProxyBaseUrl = $Context.ProxyBaseUrl
                EnvKey = 'UNGATE_API_KEY'
                RequiresUngate = $true
                TransportDescription = 'the local Ungate Responses proxy'
            }
        }
        'cliproxyapi' {
            return [pscustomobject]@{
                ProviderName = $Context.CliProxyProviderName
                ProviderDisplayName = 'CLIProxyAPI'
                ProxyBaseUrl = $Context.CliProxyBaseUrl
                EnvKey = 'CLIPROXYAPI_API_KEY'
                RequiresUngate = $false
                TransportDescription = 'the local CLIProxyAPI compatibility bridge'
            }
        }
        'omniroute' {
            return [pscustomobject]@{
                ProviderName = $Context.OmniRouteProviderName
                ProviderDisplayName = 'OmniRoute'
                ProxyBaseUrl = $Context.OmniRouteBaseUrl
                EnvKey = 'OMNIROUTE_API_KEY'
                RequiresUngate = $false
                TransportDescription = 'the local OmniRoute proxy'
            }
        }
        default { return $null }
    }
}

function Get-UngateModelTransport {
    param([Parameter(Mandatory)][object]$Definition)
    switch ([string]$Definition.EnvKey) {
        'UNGATE_API_KEY' { return 'ungate' }
        'CLIPROXYAPI_API_KEY' { return 'cliproxyapi' }
        'OMNIROUTE_API_KEY' { return 'omniroute' }
        default { return '' }
    }
}

function Get-UngateModelTemplatePath {
    param([Parameter(Mandatory)][psobject]$Context)
    if ($Context.PSObject.Properties['ModelTemplatePath'] -and $Context.ModelTemplatePath) {
        return [string]$Context.ModelTemplatePath
    }
    return (Join-Path $PSScriptRoot 'models.default.json')
}

function Get-UngateModelRegistryPath {
    param([Parameter(Mandatory)][psobject]$Context)
    if ($Context.PSObject.Properties['ModelRegistryPath'] -and $Context.ModelRegistryPath) {
        return [string]$Context.ModelRegistryPath
    }
    if ($Context.PSObject.Properties['CustomCodexHome'] -and $Context.CustomCodexHome) {
        return (Join-Path ([string]$Context.CustomCodexHome) 'ungate-model-registry.json')
    }
    throw 'Model registry path is not configured.'
}

function Read-UngateJsonDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label was not found: $Path" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is not a file: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
    }
    catch {
        throw "Failed to parse $Label at $Path : $($_.Exception.Message)"
    }
}

function Test-UngateModelToken {
    param([Parameter(Mandatory)][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.IndexOfAny([char[]]@(32, 9, 10, 13, 34, 39)) -ge 0) { return $false }
    return $true
}

function ConvertTo-UngateOptionalWindow {
    param($Record, [string]$Name, [string]$Slug)
    $property = Get-UngateRecordProperty -Record $Record -Name $Name
    if (-not $property -or $null -eq $property.Value) { return $null }
    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value)) { return $null }
    try {
        $number = if ($property.Value -is [string]) {
            ConvertTo-ContextWindowTokens -Value ([string]$property.Value)
        } else {
            [int]$property.Value
        }
    }
    catch { throw "Model '$Slug': $($_.Exception.Message)" }
    if ($number -le 0) { throw "Model '$Slug' has an invalid $Name." }
    return $number
}

function ConvertTo-UngateOptionalBool {
    param($Record, [string]$Name, [string]$Slug)
    $property = Get-UngateRecordProperty -Record $Record -Name $Name
    if (-not $property -or $null -eq $property.Value) { return $null }
    if ($property.Value -isnot [bool]) { throw "Model '$Slug' property $Name must be true or false." }
    return [bool]$property.Value
}

function ConvertTo-UngateAliases {
    param($Record, [string]$Slug)
    $property = Get-UngateRecordProperty -Record $Record -Name 'aliases'
    if (-not $property -or $null -eq $property.Value) { return $null }
    $aliases = [System.Collections.Generic.List[string]]::new()
    foreach ($alias in @($property.Value)) {
        if ($alias -isnot [string] -or -not (Test-UngateModelToken -Value $alias.Trim())) {
            throw "Model '$Slug' has an invalid alias."
        }
        [void]$aliases.Add($alias.Trim())
    }
    if ($aliases.Count -eq 0) { return $null }
    return ,$aliases.ToArray()
}

function ConvertTo-UngateReasoningLevels {
    param($Value, [string]$Slug)
    if ($null -eq $Value) { return $null }
    $levels = [System.Collections.Generic.List[object]]::new()
    foreach ($level in @($Value)) {
        if ($null -eq $level) { continue }
        if ($level -is [string]) {
            $effort = $level.Trim().ToLowerInvariant()
            if (-not $effort) { throw "Model '$Slug' has an empty reasoning level." }
            [void]$levels.Add(@{ effort = $effort; description = "Reasoning: $effort" })
        }
        else {
            $effortProperty = Get-UngateRecordProperty -Record $level -Name 'effort'
            $descriptionProperty = Get-UngateRecordProperty -Record $level -Name 'description'
            if (-not $effortProperty -or [string]::IsNullOrWhiteSpace([string]$effortProperty.Value)) {
                throw "Model '$Slug' has a reasoning level without an effort."
            }
            $effort = ([string]$effortProperty.Value).Trim().ToLowerInvariant()
            $description = if ($descriptionProperty -and -not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) {
                [string]$descriptionProperty.Value
            } else {
                "Reasoning: $effort"
            }
            [void]$levels.Add(@{ effort = $effort; description = $description })
        }
    }
    if ($levels.Count -eq 0) { return $null }
    return ,$levels.ToArray()
}

function ConvertTo-UngateTruncationPolicy {
    param($Value, [string]$Slug)
    if ($null -eq $Value) { return $null }
    $modeProperty = Get-UngateRecordProperty -Record $Value -Name 'mode'
    $limitProperty = Get-UngateRecordProperty -Record $Value -Name 'limit'
    if (-not $modeProperty -or -not $limitProperty -or [string]::IsNullOrWhiteSpace([string]$modeProperty.Value)) {
        throw "Model '$Slug' truncationPolicy must include mode and limit."
    }
    return @{ mode = [string]$modeProperty.Value; limit = [int]$limitProperty.Value }
}

function ConvertTo-UngateRegistryDefinition {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][int]$Priority
    )
    $ErrorActionPreference = 'Stop'
    foreach ($propertyName in @('slug', 'displayName', 'upstreamModel', 'transport', 'defaultReasoningLevel', 'supportsImageInput')) {
        if (-not (Get-UngateRecordProperty -Record $Record -Name $propertyName)) {
            throw "Model record is missing required property '$propertyName'."
        }
    }
    $slug = ([string]$Record.slug).Trim()
    $displayName = ([string]$Record.displayName).Trim()
    $transport = ([string]$Record.transport).Trim().ToLowerInvariant()
    $reasoningLevel = ([string]$Record.defaultReasoningLevel).Trim().ToLowerInvariant()
    if (-not $slug) { throw 'Model ID cannot be empty.' }
    if (-not (Test-UngateModelToken -Value $slug)) { throw "Model ID '$slug' cannot contain whitespace or quotes." }
    if (-not $displayName) { throw "Model '$slug' must have a display name." }
    $profile = Get-UngateTransportProfile -Context $Context -Transport $transport
    if (-not $profile) { throw "Model '$slug' has unsupported transport '$transport'." }
    $upstreamProperty = Get-UngateRecordProperty -Record $Record -Name 'upstreamModel'
    $upstreamModel = $null
    if ($null -ne $upstreamProperty.Value) {
        $upstreamModel = ([string]$upstreamProperty.Value).Trim()
        if (-not $upstreamModel) { throw "Model '$slug' must have an upstream model ID." }
        if (-not (Test-UngateModelToken -Value $upstreamModel)) {
            throw "Upstream model ID '$upstreamModel' cannot contain whitespace or quotes."
        }
    }
    elseif ($transport -ne 'ungate') {
        throw "Model '$slug' must have an upstream model ID."
    }
    if ($reasoningLevel -notin @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')) {
        throw "Model '$slug' has unsupported reasoning level '$reasoningLevel'."
    }
    $imageProperty = Get-UngateRecordProperty -Record $Record -Name 'supportsImageInput'
    if ($imageProperty.Value -isnot [bool]) { throw "Model '$slug' property supportsImageInput must be true or false." }
    $supportsImageInput = [bool]$imageProperty.Value
    $detail = ConvertTo-UngateOptionalBool -Record $Record -Name 'supportsImageDetailOriginal' -Slug $slug
    if ($null -eq $detail) { $detail = $supportsImageInput }
    if (-not $supportsImageInput -and $detail) { throw "Model '$slug' original image detail requires image input." }
    $contextWindow = ConvertTo-UngateOptionalWindow -Record $Record -Name 'contextWindow' -Slug $slug
    $maxContextWindow = ConvertTo-UngateOptionalWindow -Record $Record -Name 'maxContextWindow' -Slug $slug
    if ($null -ne $contextWindow -and $null -eq $maxContextWindow) { $maxContextWindow = $contextWindow }
    $autoCompactTokenLimit = ConvertTo-UngateOptionalWindow -Record $Record -Name 'autoCompactTokenLimit' -Slug $slug
    if ($null -ne $autoCompactTokenLimit -and $null -ne $contextWindow -and $autoCompactTokenLimit -gt $contextWindow) {
        throw "Model '$slug' autoCompactTokenLimit cannot exceed contextWindow."
    }
    $effectivePercent = ConvertTo-UngateOptionalWindow -Record $Record -Name 'effectiveContextWindowPercent' -Slug $slug
    $summaries = ConvertTo-UngateOptionalBool -Record $Record -Name 'supportsReasoningSummaries' -Slug $slug
    $parallel = ConvertTo-UngateOptionalBool -Record $Record -Name 'supportsParallelToolCalls' -Slug $slug
    $adapterProperty = Get-UngateRecordProperty -Record $Record -Name 'responsesAdapter'
    $responsesAdapter = $null
    if ($adapterProperty -and -not [string]::IsNullOrWhiteSpace([string]$adapterProperty.Value)) {
        $responsesAdapter = [string]$adapterProperty.Value
    }
    $policyProperty = Get-UngateRecordProperty -Record $Record -Name 'truncationPolicy'
    $truncationPolicy = $null
    if ($policyProperty -and $null -ne $policyProperty.Value) {
        $truncationPolicy = ConvertTo-UngateTruncationPolicy -Value $policyProperty.Value -Slug $slug
    }
    $levelsProperty = Get-UngateRecordProperty -Record $Record -Name 'supportedReasoningLevels'
    $reasoningLevels = $null
    if ($levelsProperty -and $null -ne $levelsProperty.Value) {
        $reasoningLevels = ConvertTo-UngateReasoningLevels -Value $levelsProperty.Value -Slug $slug
    }
    $descriptionProperty = Get-UngateRecordProperty -Record $Record -Name 'description'
    if ($descriptionProperty -and -not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) {
        $description = [string]$descriptionProperty.Value
    }
    elseif ($upstreamModel) {
        $description = "$displayName maps to upstream model '$upstreamModel' through $($profile.TransportDescription)."
    }
    else {
        $description = "$displayName maps through $($profile.TransportDescription)."
    }
    $identity = Get-UngateModelIdentity -Context $Context -DisplayName $displayName -UpstreamModel $upstreamModel -ProviderDisplayName $profile.ProviderDisplayName -TransportDescription $profile.TransportDescription
    $webSearch = if ($supportsImageInput) { 'text_and_image' } else { 'text' }
    $definition = [pscustomobject][ordered]@{
        Slug = $slug
        DisplayName = $displayName
        Description = $description
        UpstreamModel = $upstreamModel
        Aliases = (ConvertTo-UngateAliases -Record $Record -Slug $slug)
        TransportDescription = [string]$profile.TransportDescription
        Identity = $identity
        DefaultReasoningLevel = $reasoningLevel
        Priority = $Priority
        SupportsImageDetailOriginal = [bool]$detail
        WebSearchToolType = $webSearch
        ProviderName = $profile.ProviderName
        ProviderDisplayName = [string]$profile.ProviderDisplayName
        ProxyBaseUrl = $profile.ProxyBaseUrl
        EnvKey = [string]$profile.EnvKey
        RequiresUngate = [bool]$profile.RequiresUngate
        ContextWindow = $contextWindow
        MaxContextWindow = $maxContextWindow
        AutoCompactTokenLimit = $autoCompactTokenLimit
        EffectiveContextWindowPercent = $effectivePercent
        SupportsReasoningSummaries = $summaries
        SupportsParallelToolCalls = $parallel
        ResponsesAdapter = $responsesAdapter
        TruncationPolicy = $truncationPolicy
        SupportedReasoningLevels = $reasoningLevels
    }
    if ($supportsImageInput) {
        Add-Member -InputObject $definition -NotePropertyName InputModalities -NotePropertyValue @('text', 'image')
    }
    else {
        Add-Member -InputObject $definition -NotePropertyName InputModalities -NotePropertyValue @('text')
    }
    $summaryProperty = Get-UngateRecordProperty -Record $Record -Name 'defaultReasoningSummary'
    if ($summaryProperty -and -not [string]::IsNullOrWhiteSpace([string]$summaryProperty.Value)) {
        Add-Member -InputObject $definition -NotePropertyName DefaultReasoningSummary -NotePropertyValue ([string]$summaryProperty.Value)
    }
    $verbositySupport = ConvertTo-UngateOptionalBool -Record $Record -Name 'supportVerbosity' -Slug $slug
    if ($null -ne $verbositySupport) {
        Add-Member -InputObject $definition -NotePropertyName SupportVerbosity -NotePropertyValue ([bool]$verbositySupport)
    }
    $verbosityProperty = Get-UngateRecordProperty -Record $Record -Name 'defaultVerbosity'
    if ($verbosityProperty -and $null -ne $verbosityProperty.Value -and -not [string]::IsNullOrWhiteSpace([string]$verbosityProperty.Value)) {
        Add-Member -InputObject $definition -NotePropertyName DefaultVerbosity -NotePropertyValue ([string]$verbosityProperty.Value)
    }
    return $definition
}

function ConvertTo-UngateRegistryDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [AllowEmptyCollection()][object[]]$Records
    )
    $ErrorActionPreference = 'Stop'
    $definitions = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $priority = 0
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $definition = ConvertTo-UngateRegistryDefinition -Context $Context -Record $record -Priority $priority
        if ([string]$definition.Slug -eq 'ungate-memory') { throw 'ungate-memory is a service alias, not a launcher model.' }
        if (-not $seen.Add([string]$definition.Slug)) { throw "Model ID '$($definition.Slug)' is duplicated." }
        [void]$definitions.Add($definition)
        $priority++
    }
    return @($definitions.ToArray())
}

function Get-UngateTemplateModelDefinitions {
    param([Parameter(Mandatory)][psobject]$Context)
    $ErrorActionPreference = 'Stop'
    $path = Get-UngateModelTemplatePath -Context $Context
    $document = Read-UngateJsonDocument -Path $path -Label 'Model template'
    $version = Get-UngateRecordProperty -Record $document -Name 'version'
    if (-not $version -or [int]$version.Value -ne 1) { throw "Model template at $path has an unsupported or missing version." }
    $models = Get-UngateRecordProperty -Record $document -Name 'models'
    if (-not $models) { throw "Model template at $path is missing the models array." }
    $records = @()
    if ($null -ne $models.Value) { $records = @($models.Value) }
    return @(ConvertTo-UngateRegistryDefinitions -Context $Context -Records $records)
}
function Get-UngateProfileHomePath {
    param([Parameter(Mandatory)][psobject]$Context)
    if ($Context.PSObject.Properties['CustomCodexHome'] -and $Context.CustomCodexHome) {
        return [string]$Context.CustomCodexHome
    }
    return (Split-Path -Parent (Get-UngateModelRegistryPath -Context $Context))
}

function Get-UngateLegacyDefinitionsPath {
    param([Parameter(Mandatory)][psobject]$Context)
    if ($Context.PSObject.Properties['CustomModelDefinitionsPath'] -and $Context.CustomModelDefinitionsPath) {
        return [string]$Context.CustomModelDefinitionsPath
    }
    return (Join-Path (Get-UngateProfileHomePath -Context $Context) 'ungate-model-definitions.json')
}

function Get-UngateLegacyHiddenPath {
    param([Parameter(Mandatory)][psobject]$Context)
    return (Join-Path (Get-UngateProfileHomePath -Context $Context) 'ungate-hidden-models.json')
}

function Read-UngateModelRegistryDocument {
    param([Parameter(Mandatory)][psobject]$Context)
    $path = Get-UngateModelRegistryPath -Context $Context
    $document = Read-UngateJsonDocument -Path $path -Label 'Model registry'
    $version = Get-UngateRecordProperty -Record $document -Name 'version'
    if (-not $version -or [int]$version.Value -ne 1) { throw "Model registry at $path has an unsupported or missing version." }
    if (-not (Get-UngateRecordProperty -Record $document -Name 'models')) {
        throw "Model registry at $path is missing the models array."
    }
    return $document
}

function Get-UngateModelRegistryNotice {
    param([Parameter(Mandatory)][object]$Document)
    $property = Get-UngateRecordProperty -Record $Document -Name 'notice'
    if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return [string]$property.Value }
    return $null
}

function Get-UngateModelRegistryRecords {
    param([Parameter(Mandatory)][psobject]$Context)
    $document = Read-UngateModelRegistryDocument -Context $Context
    $models = Get-UngateRecordProperty -Record $document -Name 'models'
    if ($null -eq $models.Value) { return @() }
    return @($models.Value)
}

function Write-UngateModelRegistry {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Records,
        [AllowNull()][string]$Notice,
        [switch]$SetNotice
    )
    $ErrorActionPreference = 'Stop'
    [void](ConvertTo-UngateRegistryDefinitions -Context $Context -Records $Records)
    $path = Get-UngateModelRegistryPath -Context $Context
    $absolutePath = [System.IO.Path]::GetFullPath($path)
    $profileHome = Get-UngateProfileHomePath -Context $Context
    $lease = Enter-UngateProfileLock -HomePath $profileHome
    try {
        if ((Test-Path -LiteralPath $absolutePath) -and -not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "Model registry target is not a file: $absolutePath"
        }
        $storedNotice = $null
        if ($SetNotice) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Notice)) { $storedNotice = [string]$Notice }
        }
        elseif (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            $storedNotice = Get-UngateModelRegistryNotice -Document (Read-UngateModelRegistryDocument -Context $Context)
        }
        $document = [ordered]@{ version = 1 }
        if ($storedNotice) { $document.notice = $storedNotice }
        $modelList = [System.Collections.Generic.List[object]]::new()
        foreach ($registryRecord in @($Records)) {
            if ($null -ne $registryRecord) { [void]$modelList.Add($registryRecord) }
        }
        $document.models = $modelList
        $json = $document | ConvertTo-Json -Depth 20
        $directory = Split-Path -Parent $absolutePath
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $transactionId = [guid]::NewGuid().ToString('N')
        $temporaryPath = Join-Path $directory (".ungate-model-registry." + $transactionId + '.tmp')
        $backupPath = Join-Path $directory (".ungate-model-registry." + $transactionId + '.bak')
        $writeCompleted = $false
        try {
            $newline = [string]([char]13) + [string]([char]10)
            [System.IO.File]::WriteAllText($temporaryPath, $json + $newline, [System.Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
                [System.IO.File]::Replace($temporaryPath, $absolutePath, $backupPath, $true)
            }
            else {
                [System.IO.File]::Move($temporaryPath, $absolutePath)
            }
            $writeCompleted = $true
        }
        finally {
            if ($writeCompleted -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
        return $absolutePath
    }
    finally { Exit-UngateProfileLock -Lease $lease }
}

function Initialize-UngateModelRegistry {
    param([Parameter(Mandatory)][psobject]$Context)
    $ErrorActionPreference = 'Stop'
    $path = Get-UngateModelRegistryPath -Context $Context
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $false }
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Model registry target is not a file: $path"
    }
    $lease = Enter-UngateProfileLock -HomePath (Get-UngateProfileHomePath -Context $Context)
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $false }
        $templatePath = Get-UngateModelTemplatePath -Context $Context
        $templateDocument = Read-UngateJsonDocument -Path $templatePath -Label 'Model template'
        $templateVersion = Get-UngateRecordProperty -Record $templateDocument -Name 'version'
        if (-not $templateVersion -or [int]$templateVersion.Value -ne 1) {
            throw "Model template at $templatePath has an unsupported or missing version."
        }
        $templateModels = Get-UngateRecordProperty -Record $templateDocument -Name 'models'
        if (-not $templateModels) { throw "Model template at $templatePath is missing the models array." }
        $templateRecords = @()
        if ($null -ne $templateModels.Value) { $templateRecords = @($templateModels.Value) }
        [void](ConvertTo-UngateRegistryDefinitions -Context $Context -Records $templateRecords)

        $hidden = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $hiddenPath = Get-UngateLegacyHiddenPath -Context $Context
        if (Test-Path -LiteralPath $hiddenPath) {
            foreach ($hiddenSlug in @(Read-UngateHiddenModelSlugs -HiddenModelsPath $hiddenPath)) {
                [void]$hidden.Add([string]$hiddenSlug)
            }
        }

        $customRecords = @()
        $legacyPath = Get-UngateLegacyDefinitionsPath -Context $Context
        if (Test-Path -LiteralPath $legacyPath) {
            $legacy = Read-UngateJsonDocument -Path $legacyPath -Label 'Custom model registry'
            $legacyVersion = Get-UngateRecordProperty -Record $legacy -Name 'version'
            if (-not $legacyVersion -or [int]$legacyVersion.Value -ne 1) {
                throw "Custom model registry at $legacyPath has an unsupported or missing version."
            }
            $legacyModels = Get-UngateRecordProperty -Record $legacy -Name 'models'
            if (-not $legacyModels) { throw "Custom model registry at $legacyPath is missing the models array." }
            if ($null -ne $legacyModels.Value) { $customRecords = @($legacyModels.Value) }
            [void](ConvertTo-UngateRegistryDefinitions -Context $Context -Records $customRecords)
        }

        $selected = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in $templateRecords) {
            $slugProperty = Get-UngateRecordProperty -Record $record -Name 'slug'
            $slug = [string]$slugProperty.Value
            if ($hidden.Contains($slug)) { continue }
            if (-not $seen.Add($slug)) { throw "Model ID '$slug' is duplicated." }
            [void]$selected.Add($record)
        }
        foreach ($record in $customRecords) {
            $slugProperty = Get-UngateRecordProperty -Record $record -Name 'slug'
            $slug = [string]$slugProperty.Value
            if (-not $seen.Add($slug)) { throw "Model ID '$slug' is duplicated." }
            [void]$selected.Add($record)
        }
        $notice = 'Created the model registry and moved ' + $selected.Count + ' models.'
        [void](Write-UngateModelRegistry -Context $Context -Records @($selected.ToArray()) -Notice $notice -SetNotice)
        Write-Host ('[ungate] ' + $notice) -ForegroundColor Green
        return $true
    }
    finally { Exit-UngateProfileLock -Lease $lease }
}

function Test-UngateRegistrySlugTaken {
    param([Parameter(Mandatory)][object[]]$Records, [Parameter(Mandatory)][string]$Slug)
    foreach ($record in @($Records)) {
        $property = Get-UngateRecordProperty -Record $record -Name 'slug'
        if ($property -and ([string]$property.Value).Equals($Slug, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function ConvertTo-UngatePersistentModelRecord {
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][object]$Camel
    )
    $supportsImage = @($Definition.InputModalities) -contains 'image'
    $transportProperty = Get-UngateRecordProperty -Record $Camel -Name 'transport'
    $persistent = [ordered]@{
        slug = [string]$Definition.Slug
        displayName = [string]$Definition.DisplayName
        upstreamModel = $Definition.UpstreamModel
        transport = $(if ($transportProperty) { [string]$transportProperty.Value } else { '' })
        defaultReasoningLevel = [string]$Definition.DefaultReasoningLevel
        supportsImageInput = [bool]$supportsImage
    }
    if ($null -ne $Definition.ContextWindow) { $persistent.contextWindow = [int]$Definition.ContextWindow }
    foreach ($name in @(
        'maxContextWindow', 'effectiveContextWindowPercent', 'autoCompactTokenLimit', 'supportsImageDetailOriginal', 'description',
        'aliases', 'responsesAdapter', 'truncationPolicy', 'supportedReasoningLevels',
        'supportsReasoningSummaries', 'supportsParallelToolCalls', 'defaultReasoningSummary',
        'supportVerbosity', 'defaultVerbosity'
    )) {
        $property = Get-UngateRecordProperty -Record $Camel -Name $name
        if ($property -and $null -ne $property.Value) { $persistent[$name] = $property.Value }
    }
    if ($persistent.Contains('maxContextWindow') -and $null -ne $Definition.MaxContextWindow) {
        $persistent.maxContextWindow = [int]$Definition.MaxContextWindow
    }
    if ($persistent.Contains('effectiveContextWindowPercent') -and $null -ne $Definition.EffectiveContextWindowPercent) {
        $persistent.effectiveContextWindowPercent = [int]$Definition.EffectiveContextWindowPercent
    }
    return [pscustomobject]$persistent
}

function Add-UngateModelRegistryRecord {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][object]$Record
    )
    $ErrorActionPreference = 'Stop'
    [void](Initialize-UngateModelRegistry -Context $Context)
    $normalized = ConvertTo-UngateCamelModelRecord -Record $Record
    $definition = ConvertTo-UngateRegistryDefinition -Context $Context -Record $normalized -Priority 0
    if ([string]$definition.Slug -eq 'ungate-memory') { throw 'ungate-memory is a service alias, not a launcher model.' }
    $existing = @(Get-UngateModelRegistryRecords -Context $Context)
    if (Test-UngateRegistrySlugTaken -Records $existing -Slug ([string]$definition.Slug)) {
        throw "Model ID '$($definition.Slug)' already exists."
    }
    $persistent = ConvertTo-UngatePersistentModelRecord -Definition $definition -Camel $normalized
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $existing) { [void]$records.Add($item) }
    [void]$records.Add($persistent)
    [void](Write-UngateModelRegistry -Context $Context -Records @($records.ToArray()))
    return $definition
}

function Remove-UngateRegistryRecord {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Slug
    )
    $ErrorActionPreference = 'Stop'
    if ($Slug -eq 'ungate-memory') { throw 'ungate-memory is a service alias, not a launcher model.' }
    [void](Initialize-UngateModelRegistry -Context $Context)
    $existing = @(Get-UngateModelRegistryRecords -Context $Context)
    $kept = [System.Collections.Generic.List[object]]::new()
    $found = $false
    foreach ($record in $existing) {
        $property = Get-UngateRecordProperty -Record $record -Name 'slug'
        $recordSlug = if ($property) { [string]$property.Value } else { '' }
        if ($recordSlug.Equals($Slug, [System.StringComparison]::OrdinalIgnoreCase)) {
            $found = $true
            continue
        }
        [void]$kept.Add($record)
    }
    if (-not $found) { throw "Model '$Slug' is not configured." }
    if ($kept.Count -eq 0) { throw 'The last model cannot be removed. Add another model first.' }
    [void](Write-UngateModelRegistry -Context $Context -Records @($kept.ToArray()))
    return $Slug
}

function Copy-UngateTemplateModelToRegistry {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Slug
    )
    $ErrorActionPreference = 'Stop'
    [void](Initialize-UngateModelRegistry -Context $Context)
    $templatePath = Get-UngateModelTemplatePath -Context $Context
    $document = Read-UngateJsonDocument -Path $templatePath -Label 'Model template'
    $models = Get-UngateRecordProperty -Record $document -Name 'models'
    $match = $null
    if ($models -and $null -ne $models.Value) {
        foreach ($record in @($models.Value)) {
            $property = Get-UngateRecordProperty -Record $record -Name 'slug'
            if ($property -and ([string]$property.Value).Equals($Slug, [System.StringComparison]::OrdinalIgnoreCase)) {
                $match = $record
                break
            }
        }
    }
    if (-not $match) { throw "Model '$Slug' is not in the template." }
    [void](ConvertTo-UngateRegistryDefinition -Context $Context -Record $match -Priority 0)
    $existing = @(Get-UngateModelRegistryRecords -Context $Context)
    $matchProperty = Get-UngateRecordProperty -Record $match -Name 'slug'
    $matchSlug = [string]$matchProperty.Value
    if (Test-UngateRegistrySlugTaken -Records $existing -Slug $matchSlug) {
        throw "Model ID '$matchSlug' already exists."
    }
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $existing) { [void]$records.Add($item) }
    [void]$records.Add($match)
    [void](Write-UngateModelRegistry -Context $Context -Records @($records.ToArray()))
    return $matchSlug
}

function ConvertTo-UngateCamelModelRecord {
    param([Parameter(Mandatory)][object]$Record)
    if (Get-UngateRecordProperty -Record $Record -Name 'slug') { return $Record }
    $upstreamProperty = Get-UngateRecordProperty -Record $Record -Name 'UpstreamModel'
    $upstreamValue = $null
    if ($upstreamProperty) { $upstreamValue = $upstreamProperty.Value }
    if ($null -ne $upstreamValue -and [string]::IsNullOrWhiteSpace([string]$upstreamValue)) { $upstreamValue = $null }
    elseif ($null -ne $upstreamValue) { $upstreamValue = ([string]$upstreamValue).Trim() }
    $slugProperty = Get-UngateRecordProperty -Record $Record -Name 'Slug'
    $displayProperty = Get-UngateRecordProperty -Record $Record -Name 'DisplayName'
    $transportProperty = Get-UngateRecordProperty -Record $Record -Name 'Transport'
    $reasoningProperty = Get-UngateRecordProperty -Record $Record -Name 'DefaultReasoningLevel'
    $imageProperty = Get-UngateRecordProperty -Record $Record -Name 'SupportsImageInput'
    $camel = [ordered]@{
        slug = $(if ($slugProperty) { ([string]$slugProperty.Value).Trim() } else { '' })
        displayName = $(if ($displayProperty) { ([string]$displayProperty.Value).Trim() } else { '' })
        upstreamModel = $upstreamValue
        transport = $(if ($transportProperty) { ([string]$transportProperty.Value).Trim() } else { '' })
        defaultReasoningLevel = $(if ($reasoningProperty) { ([string]$reasoningProperty.Value).Trim() } else { '' })
        supportsImageInput = $(if ($imageProperty) { $imageProperty.Value } else { $null })
    }
    $optional = @{
        ContextWindow = 'contextWindow'
        MaxContextWindow = 'maxContextWindow'
        AutoCompactTokenLimit = 'autoCompactTokenLimit'
        EffectiveContextWindowPercent = 'effectiveContextWindowPercent'
        SupportsImageDetailOriginal = 'supportsImageDetailOriginal'
        Description = 'description'
        Aliases = 'aliases'
        ResponsesAdapter = 'responsesAdapter'
        TruncationPolicy = 'truncationPolicy'
        SupportedReasoningLevels = 'supportedReasoningLevels'
        SupportsReasoningSummaries = 'supportsReasoningSummaries'
        SupportsParallelToolCalls = 'supportsParallelToolCalls'
        DefaultReasoningSummary = 'defaultReasoningSummary'
        SupportVerbosity = 'supportVerbosity'
        DefaultVerbosity = 'defaultVerbosity'
    }
    foreach ($name in @($optional.Keys)) {
        $property = Get-UngateRecordProperty -Record $Record -Name $name
        if ($property -and $null -ne $property.Value) { $camel[$optional[$name]] = $property.Value }
    }
    if (-not $camel.Contains('supportsImageDetailOriginal')) {
        $detailProperty = Get-UngateRecordProperty -Record $Record -Name 'supportsImageDetailOriginal'
        if ($detailProperty -and $null -ne $detailProperty.Value) { $camel.supportsImageDetailOriginal = $detailProperty.Value }
    }
    return [pscustomobject]$camel
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
    return ConvertTo-UngateRegistryDefinition -Context $Context -Record (ConvertTo-UngateCamelModelRecord -Record $Record) -Priority $Priority
}

function Read-UngateHiddenModelSlugs {
    param([Parameter(Mandatory = $true)][string]$HiddenModelsPath)
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $HiddenModelsPath)) { return @() }
    if (-not (Test-Path -LiteralPath $HiddenModelsPath -PathType Leaf)) {
        throw "Hidden models target is not a file: $HiddenModelsPath"
    }
    try {
        $data = Get-Content -LiteralPath $HiddenModelsPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "Failed to parse hidden models at $HiddenModelsPath : $($_.Exception.Message)"
    }
    if ('Version' -notin $data.PSObject.Properties.Name -or [int]$data.Version -ne 1) {
        throw "Hidden models at $HiddenModelsPath have an unsupported or missing version."
    }
    if ('ModelSlugs' -notin $data.PSObject.Properties.Name) {
        throw "Hidden models at $HiddenModelsPath are missing the modelSlugs array."
    }
    $slugs = [System.Collections.Generic.List[string]]::new()
    foreach ($slug in @($data.ModelSlugs)) {
        if ($slug -isnot [string] -or [string]::IsNullOrWhiteSpace($slug)) {
            throw "Hidden models at $HiddenModelsPath contain an invalid model ID."
        }
        if ($slug -notin $slugs) { [void]$slugs.Add($slug) }
    }
    return @($slugs)
}

function ConvertTo-ContextWindowTokens {
    param([Parameter(Mandatory = $true)][string]$Value)
    $ErrorActionPreference = 'Stop'

    $trimmed = $Value.Trim()
    if ($trimmed -match '^(?<num>\d+(?:\.\d+)?)\s*[mM]$') {
        return [int]([double]$Matches.num * 1000000)
    }
    if ($trimmed -match '^(?<num>\d+(?:\.\d+)?)\s*[kK]$') {
        return [int]([double]$Matches.num * 1000)
    }
    $intVal = 0
    if ([int]::TryParse($trimmed, [ref]$intVal) -and $intVal -gt 0) {
        return $intVal
    }
    throw "Invalid context window '$Value'. Use an integer (e.g. 500000) or compact format (e.g. 500k, 1M)."
}

function Read-UngateModelOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverridesPath
    )
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $OverridesPath)) {
        return [ordered]@{}
    }
    if (-not (Test-Path -LiteralPath $OverridesPath -PathType Leaf)) {
        throw "Model overrides target is not a file: $OverridesPath"
    }

    try {
        $data = Get-Content -LiteralPath $OverridesPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "Failed to parse model overrides at $OverridesPath : $($_.Exception.Message)"
    }

    if ('Version' -notin $data.PSObject.Properties.Name -or [int]$data.Version -ne 1) {
        throw "Model overrides at $OverridesPath have an unsupported or missing version."
    }
    if ('Overrides' -notin $data.PSObject.Properties.Name) {
        throw "Model overrides at $OverridesPath are missing the overrides property."
    }

    $overrides = [ordered]@{}
    foreach ($prop in $data.Overrides.PSObject.Properties) {
        $overrides[$prop.Name] = $prop.Value
    }
    return $overrides
}

function Write-UngateModelOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverridesPath,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Overrides
    )
    $ErrorActionPreference = 'Stop'

    $json = [ordered]@{
        version = 1
        overrides = $Overrides
    } | ConvertTo-Json -Depth 20

    $absolutePath = [System.IO.Path]::GetFullPath($OverridesPath)
    if ((Test-Path -LiteralPath $absolutePath) -and -not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        throw "Model overrides target is not a file: $absolutePath"
    }

    $directory = Split-Path -Parent $absolutePath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ".ungate-model-overrides.$transactionId.tmp"
    $backupPath = Join-Path $directory ".ungate-model-overrides.$transactionId.bak"
    $writeCompleted = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json + "`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $absolutePath,
                $backupPath,
                $true
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $absolutePath)
        }
        $writeCompleted = $true
    }
    finally {
        if ($writeCompleted -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        # Retain the backup as a manual recovery path; never restore automatically.
    }

    return $absolutePath
}

function Set-UngateModelOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverridesPath,
        [Parameter(Mandatory = $true)]
        [string]$Slug,
        [Parameter(Mandatory = $true)]
        [hashtable]$Override
    )
    $ErrorActionPreference = 'Stop'
    $lease = Enter-UngateProfileLock -HomePath (Split-Path -Parent ([System.IO.Path]::GetFullPath($OverridesPath)))
    try {

    $current = Read-UngateModelOverrides -OverridesPath $OverridesPath
    $updated = [ordered]@{}
    foreach ($key in $current.Keys) {
        $updated[$key] = $current[$key]
    }
    $merged = @{}
    if ($current.Contains($Slug)) { $merged = ConvertTo-CapabilityDictionary $current[$Slug] }
    foreach ($name in $Override.Keys) { $merged[$name] = $Override[$name] }
    $updated[$Slug] = $merged
        return Write-UngateModelOverrides -OverridesPath $OverridesPath -Overrides $updated
    } finally {
        Exit-UngateProfileLock -Lease $lease
    }
}

function Remove-UngateModelOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverridesPath,
        [Parameter(Mandatory = $true)]
        [string]$Slug,
        [string[]]$Fields
    )
    $ErrorActionPreference = 'Stop'
    $lease = Enter-UngateProfileLock -HomePath (Split-Path -Parent ([System.IO.Path]::GetFullPath($OverridesPath)))
    try {

    $current = Read-UngateModelOverrides -OverridesPath $OverridesPath
    $updated = [ordered]@{}
    foreach ($key in $current.Keys) {
        if ($key -eq $Slug -and $Fields) {
            $remaining = ConvertTo-CapabilityDictionary $current[$key]
            foreach ($field in $Fields) { $remaining.Remove($field) }
            if ($remaining.Count -gt 0) { $updated[$key] = $remaining }
        } elseif ($key -ne $Slug) {
            $updated[$key] = $current[$key]
        }
    }
    if ($updated.Count -eq 0) {
        if (Test-Path -LiteralPath $OverridesPath -PathType Leaf) {
            Remove-Item -LiteralPath $OverridesPath -Force
        }
        return $OverridesPath
    }
        return Write-UngateModelOverrides -OverridesPath $OverridesPath -Overrides $updated
    } finally {
        Exit-UngateProfileLock -Lease $lease
    }
}

function Apply-UngateModelOverrides {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory = $true)][object[]]$Definitions,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Overrides
    )
    $ErrorActionPreference = 'Stop'

    if (-not $Overrides -or $Overrides.Count -eq 0) {
        return @($Definitions)
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($def in $Definitions) {
        $matchKey = $null
        if ($Overrides.Contains($def.Slug)) {
            $matchKey = $def.Slug
        }
        elseif ($def.PSObject.Properties['UpstreamModel'] -and $def.UpstreamModel -and $Overrides.Contains([string]$def.UpstreamModel)) {
            $matchKey = [string]$def.UpstreamModel
        }

        if (-not $matchKey) {
            [void]$result.Add($def)
            continue
        }

        $ov = $Overrides[$matchKey]
        $newUpstreamModel = if ($ov.PSObject.Properties['upstreamModel'] -and $ov.upstreamModel) {
            [string]$ov.upstreamModel
        } else {
            $def.UpstreamModel
        }

        $newDisplayName = if ($ov.PSObject.Properties['displayName'] -and $ov.displayName) {
            [string]$ov.displayName
        } else {
            if ($def.DisplayName -match '(?i)grok\s*[\d.]+') {
                $ver = if ($newUpstreamModel -match '[\d.]+') { $Matches[0] } else { '' }
                if ($ver) {
                    $def.DisplayName -replace '(?i)grok\s*[\d.]+', "Grok $ver"
                } else {
                    $def.DisplayName
                }
            } else {
                $def.DisplayName
            }
        }

        $newContextWindow = if ($ov.PSObject.Properties['contextWindow'] -and $ov.contextWindow) {
            [int]$ov.contextWindow
        } elseif ($def.PSObject.Properties['ContextWindow'] -and $null -ne $def.ContextWindow) {
            [int]$def.ContextWindow
        } else {
            $null
        }

        $newAliases = [System.Collections.Generic.List[string]]::new()
        if ($def.PSObject.Properties['Aliases'] -and $def.Aliases) {
            foreach ($a in $def.Aliases) { [void]$newAliases.Add([string]$a) }
        }
        if ($newUpstreamModel -and $newUpstreamModel -notin $newAliases -and $newUpstreamModel -ne $def.Slug) {
            [void]$newAliases.Add($newUpstreamModel)
        }

        $identity = Get-UngateModelIdentity -Context $Context `
            -DisplayName $newDisplayName `
            -UpstreamModel $newUpstreamModel `
            -ProviderDisplayName $def.ProviderDisplayName `
            -TransportDescription $def.TransportDescription

        $props = [ordered]@{}
        foreach ($p in $def.PSObject.Properties) {
            $props[$p.Name] = $p.Value
        }
        $props['DisplayName'] = $newDisplayName
        $props['UpstreamModel'] = $newUpstreamModel
        if ($ov.PSObject.Properties['upstreamModelPrefix']) {
            $prefix = $ov.upstreamModelPrefix
            if ($prefix -isnot [string] -or $prefix -notmatch '^[A-Za-z0-9._-]+$') {
                throw "Invalid upstream model provider prefix for '$($def.Slug)'."
            }
            $props['UpstreamModelPrefix'] = $prefix
        }
        if ($def.Description -and $newDisplayName -ne $def.DisplayName) {
            $props['Description'] = $def.Description -replace [regex]::Escape($def.DisplayName), $newDisplayName
        }
        $props['Identity'] = $identity
        $props['Aliases'] = if ($newAliases.Count -gt 0) { @($newAliases) } else { $null }
        $props['IsOverridden'] = $true
        $props['DefaultUpstreamModel'] = $def.UpstreamModel
        if ($null -ne $newContextWindow) {
            $props['ContextWindow'] = $newContextWindow
            $props['MaxContextWindow'] = $newContextWindow
        }
        $capabilities = @{}
        $overrideProperties = ConvertTo-CapabilityDictionary $ov
        foreach ($name in @(Get-UngateCapabilityNames)) {
            if ($overrideProperties.ContainsKey($name)) { $capabilities[$name] = $overrideProperties[$name] }
        }
        [void]$result.Add((Apply-UngateModelCapabilities -Definition ([pscustomobject]$props) -Context $Context -Values $capabilities))
    }

    return @($result)
}

function Get-UngateModelDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter()][string]$OverridesPath,
        [switch]$SkipOverrides
    )
    $ErrorActionPreference = 'Stop'

    [void](Get-UngateTemplateModelDefinitions -Context $Context)
    [void](Initialize-UngateModelRegistry -Context $Context)
    $records = @(Get-UngateModelRegistryRecords -Context $Context)
    $all = @(ConvertTo-UngateRegistryDefinitions -Context $Context -Records $records)
    if ($SkipOverrides) { return $all }
    if (-not $OverridesPath -and $Context.PSObject.Properties['CustomModelOverridesPath']) {
        $OverridesPath = $Context.CustomModelOverridesPath
    }
    if ($OverridesPath) {
        $overrides = Read-UngateModelOverrides -OverridesPath $OverridesPath
        if ($overrides -and $overrides.Count -gt 0) {
            $all = @(Apply-UngateModelOverrides -Context $Context -Definitions $all -Overrides $overrides)
        }
    }
    return $all
}

function Get-UngateRequestModel {
    param([Parameter(Mandatory)][object]$Definition)
    $model = if ($Definition.PSObject.Properties['UpstreamModel'] -and $Definition.UpstreamModel) {
        [string]$Definition.UpstreamModel
    } else { [string]$Definition.Slug }
    if ($Definition.PSObject.Properties['UpstreamModelPrefix'] -and $Definition.UpstreamModelPrefix -and $model -notmatch '/') {
        return "$($Definition.UpstreamModelPrefix)/$model"
    }
    return $model
}

function Get-UngateDiagnosticRoute {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][object]$Definition)
    $provider = if ($Definition.PSObject.Properties['ProviderName']) { [string]$Definition.ProviderName } else { '' }
    $transport = Get-UngateModelTransport -Definition $Definition
    if (-not $transport) {
        if ($Definition.PSObject.Properties['Transport'] -and $Definition.Transport) { $transport = [string]$Definition.Transport }
        else { $transport = $provider }
    }
    $cliproxy = $transport -eq 'cliproxyapi'
    return [pscustomobject][ordered]@{
        RegistryId = [string]$Definition.Slug
        RequestModel = Get-UngateRequestModel -Definition $Definition
        Transport = $transport
        ProviderName = $provider
        UpstreamBaseUrl = if ($Definition.PSObject.Properties['ProxyBaseUrl']) { [string]$Definition.ProxyBaseUrl } else { '' }
        ResponsesAdapter = if ($Definition.PSObject.Properties['ResponsesAdapter'] -and $Definition.ResponsesAdapter) { [string]$Definition.ResponsesAdapter } else { $null }
        BridgeUpstreamUrl = if ($cliproxy) { [string]$Context.CliProxyUpstreamBaseUrl } else { $null }
        BridgeRequired = [bool]$cliproxy
    }
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
    'Get-UngateModelDefinitions',
    'Get-UngateRequestModel',
    'Get-UngateDiagnosticRoute',
    'Get-UngateModelContextWindow',
    'New-UngateModelSet',
    'ConvertTo-ContextWindowTokens',
    'Read-UngateModelOverrides',
    'Write-UngateModelOverrides',
    'Set-UngateModelOverride',
    'Remove-UngateModelOverride',
    'Apply-UngateModelOverrides'
    'Get-UngateTemplateModelDefinitions',
    'Get-UngateModelTransport',
    'Get-UngateTransportProfile',
    'Write-UngateModelRegistry',
    'Initialize-UngateModelRegistry',
    'Get-UngateModelRegistryRecords',
    'Get-UngateModelRegistryNotice',
    'Add-UngateModelRegistryRecord',
    'Copy-UngateTemplateModelToRegistry',
    'Remove-UngateRegistryRecord'
)
