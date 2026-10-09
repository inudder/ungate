#requires -Version 7.4
# Pure capability normalization plus read-only catalog defaults; no launch state.

function Get-UngateCapabilityNames {
    return @('supportsImageInput', 'supportsImageDetailOriginal', 'supportedReasoningLevels',
        'defaultReasoningLevel', 'supportsReasoningSummaries', 'defaultReasoningSummary',
        'supportsParallelToolCalls', 'supportVerbosity', 'defaultVerbosity')
}

function ConvertTo-CapabilityDictionary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object]$Value)
    $result = @{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $result[[string]$key] = $Value[$key] }
    } else {
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    return $result
}

function Get-UngateCapabilityTemplate {
    param([object]$Context, [Parameter(Mandatory)][object]$Definition)
    if (-not $Context) { return $null }
    $shellSlug = if ($Definition.PSObject.Properties['ShellSlug']) { $Definition.ShellSlug } else { $null }
    if (-not $shellSlug -and $Context.CustomModelCatalogPath -and (Test-Path -LiteralPath $Context.CustomModelCatalogPath -PathType Leaf)) {
        $current = Get-Content -LiteralPath $Context.CustomModelCatalogPath -Raw | ConvertFrom-Json -Depth 100
        $shellSlug = ($current.models | Where-Object display_name -EQ $Definition.DisplayName | Select-Object -First 1).slug
    }
    foreach ($path in @($Context.DefaultModelCachePath, $Context.CustomModelCatalogPath)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $catalog = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
        $match = $catalog.models | Where-Object slug -EQ $shellSlug | Select-Object -First 1
        if ($match) { return $match }
        $match = $catalog.models | Where-Object slug -EQ 'gpt-5.4' | Select-Object -First 1
        if ($match) { return $match }
        return $catalog.models | Select-Object -First 1
    }
    return $null
}

function Get-UngateModelCapabilities {
    param([Parameter(Mandatory)][object]$Definition, [object]$Context, [object]$Template)
    if (-not $Template) { $Template = Get-UngateCapabilityTemplate -Context $Context -Definition $Definition }
    $properties = ConvertTo-CapabilityDictionary $Definition
    $levels = @($properties.SupportedReasoningLevels | Where-Object { $null -ne $_ } | ForEach-Object {
        if ($_ -is [string]) { $_ } else { [string]$_.effort }
    })
    if ($levels.Count -eq 0 -and $Template) { $levels = @($Template.supported_reasoning_levels | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.effort }) }
    if ($levels.Count -eq 0) { $levels = @('low', 'medium', 'high', 'xhigh') }
    $defaultLevel = [string]$properties.DefaultReasoningLevel
    if (-not $defaultLevel) { $defaultLevel = 'high' }
    $parallel = $false
    if ($null -ne $properties.SupportsParallelToolCalls) { $parallel = [bool]$properties.SupportsParallelToolCalls }
    elseif ($Template) { $parallel = [bool]$Template.supports_parallel_tool_calls }
    $verbosity = [bool]$properties.SupportVerbosity
    $summary = 'none'
    if ($properties.DefaultReasoningSummary) { $summary = [string]$properties.DefaultReasoningSummary }
    $defaultVerbosity = $null
    if ($verbosity) {
        $defaultVerbosity = if ($properties.DefaultVerbosity) { [string]$properties.DefaultVerbosity } else { 'medium' }
    }
    return @{
        supportsImageInput = 'image' -in @($properties.InputModalities)
        supportsImageDetailOriginal = [bool]$properties.SupportsImageDetailOriginal
        supportedReasoningLevels = @($levels)
        defaultReasoningLevel = $defaultLevel
        supportsReasoningSummaries = [bool]$properties.SupportsReasoningSummaries
        defaultReasoningSummary = $summary
        supportsParallelToolCalls = $parallel
        supportVerbosity = $verbosity
        defaultVerbosity = $defaultVerbosity
    }
}

function Merge-UngateModelCapabilities {
    param([Parameter(Mandatory)][object]$Definition, [object]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Values)
    $effective = Get-UngateModelCapabilities -Definition $Definition -Context $Context
    $names = @(Get-UngateCapabilityNames)
    $booleans = @('supportsImageInput', 'supportsImageDetailOriginal', 'supportsReasoningSummaries',
        'supportsParallelToolCalls', 'supportVerbosity')
    foreach ($key in $Values.Keys) {
        if ($key -notin $names) { throw "Unknown model capability '$key'." }
        if ($key -in $booleans -and $Values[$key] -isnot [bool]) { throw "Capability '$key' must be a Boolean." }
        $effective[$key] = $Values[$key]
    }
    if ($Values.Contains('supportsImageInput') -and -not $Values.supportsImageInput -and -not $Values.Contains('supportsImageDetailOriginal')) {
        $effective.supportsImageDetailOriginal = $false
    }
    if (-not $effective.supportsImageInput -and $effective.supportsImageDetailOriginal) { throw 'original image detail requires image input.' }
    if ($Values.Contains('supportsReasoningSummaries') -and -not $Values.supportsReasoningSummaries) { $effective.defaultReasoningSummary = 'none' }
    if ($Values.Contains('supportVerbosity') -and -not $Values.supportVerbosity) { $effective.defaultVerbosity = $null }
    $allowedLevels = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
    if ($Values.Contains('supportedReasoningLevels')) {
        if ($Values.supportedReasoningLevels -isnot [array] -or $Values.supportedReasoningLevels.Count -eq 0) {
            throw 'supportedReasoningLevels must be a nonempty array of strings.'
        }
        foreach ($level in $Values.supportedReasoningLevels) {
            if ($level -isnot [string] -or $level -notin $allowedLevels) { throw "Unsupported reasoning level '$level'." }
        }
        if (@($Values.supportedReasoningLevels | Select-Object -Unique).Count -ne $Values.supportedReasoningLevels.Count) {
            throw 'supportedReasoningLevels cannot contain duplicates.'
        }
    }
    if ($effective.defaultReasoningLevel -notin $allowedLevels -or $effective.defaultReasoningLevel -notin $effective.supportedReasoningLevels) {
        throw 'The default reasoning level must be included in supportedReasoningLevels.'
    }
    if ($effective.defaultReasoningSummary -notin @('none', 'auto', 'concise', 'detailed')) { throw 'Invalid defaultReasoningSummary.' }
    if (-not $effective.supportsReasoningSummaries -and $effective.defaultReasoningSummary -ne 'none') { throw 'Reasoning summaries are disabled.' }
    if ($effective.supportVerbosity -and $effective.defaultVerbosity -notin @('low', 'medium', 'high')) { throw 'Invalid defaultVerbosity.' }
    if (-not $effective.supportVerbosity -and $null -ne $effective.defaultVerbosity) { throw 'Verbosity is disabled.' }
    return $effective
}

function Apply-UngateModelCapabilities {
    param([Parameter(Mandatory)][object]$Definition, [object]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Values)
    if ($Values.Count -eq 0) { return $Definition }
    $effective = Merge-UngateModelCapabilities -Definition $Definition -Context $Context -Values $Values
    $properties = [ordered]@{}
    foreach ($property in $Definition.PSObject.Properties) { $properties[$property.Name] = $property.Value }
    $properties['InputModalities'] = if ($effective.supportsImageInput) { @('text', 'image') } else { @('text') }
    $properties['SupportsImageInput'] = $effective.supportsImageInput
    $properties['SupportsImageDetailOriginal'] = $effective.supportsImageDetailOriginal
    $properties['WebSearchToolType'] = if ($effective.supportsImageInput) { 'text_and_image' } else { 'text' }
    foreach ($key in @('defaultReasoningLevel', 'supportsReasoningSummaries', 'defaultReasoningSummary', 'supportsParallelToolCalls', 'supportVerbosity', 'defaultVerbosity')) {
        if ($Values.Contains($key)) { $properties[$key] = $effective[$key] }
    }
    if ($Values.Contains('supportsReasoningSummaries')) { $properties['DefaultReasoningSummary'] = $effective.defaultReasoningSummary }
    if ($Values.Contains('supportVerbosity')) { $properties['DefaultVerbosity'] = $effective.defaultVerbosity }
    if ($Values.Contains('supportedReasoningLevels')) {
        $properties['SupportedReasoningLevels'] = @($effective.supportedReasoningLevels | ForEach-Object { @{ effort = $_; description = "Reasoning: $_" } })
    }
    if ($Values.Contains('supportsParallelToolCalls')) { $properties['ParallelToolCallsOverride'] = $effective.supportsParallelToolCalls }
    return [pscustomobject]$properties
}

Export-ModuleMember -Function @('Get-UngateCapabilityNames', 'ConvertTo-CapabilityDictionary',
    'Get-UngateModelCapabilities', 'Merge-UngateModelCapabilities', 'Apply-UngateModelCapabilities')
