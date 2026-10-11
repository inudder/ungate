#requires -Version 7.4
# Settings management for the Codex Beta dashboard. Importing has no launch side effects.
Import-Module (Join-Path $PSScriptRoot 'Context.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ModelCapabilities.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Picker.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Memories.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'LauncherLock.psm1') -DisableNameChecking -ErrorAction Stop

$script:VersionFields = @('upstreamModel', 'displayName', 'contextWindow')
$script:CapabilityFields = @(Get-UngateCapabilityNames)
$script:LogLevels = @('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors')
$script:ReasoningLevels = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')

function Stop-LauncherRequest {
    param([Parameter(Mandatory)][int]$Status, [Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message, [hashtable]$Extra)
    $payload = [ordered]@{ code = $Code; message = $Message }
    if ($Extra) { foreach ($key in $Extra.Keys) { $payload[$key] = $Extra[$key] } }
    $json = $payload | ConvertTo-Json -Compress -Depth 30
    throw ('LAUNCHER_FAIL|' + $Status + '|' + $Code + '|' + $json)
}

function New-LauncherResult {
    param([int]$Status = 200, $Body)
    return [pscustomobject]@{ status = $Status; body = $Body }
}

function ConvertTo-LauncherDictionary {
    param($Value)
    $result = @{}
    if ($null -eq $Value) { return $result }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { $result[[string]$key] = $Value[$key] }
        return $result
    }
    foreach ($property in @($Value.PSObject.Properties)) { $result[$property.Name] = $property.Value }
    return $result
}

function ConvertTo-RevisionToken {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        $parts = foreach ($key in $keys) { $key + '=' + (ConvertTo-RevisionToken $Value[$key]) }
        return '{' + ($parts -join ';') + '}'
    }
    if (($Value -is [System.Array]) -or (($Value -is [System.Collections.IList]) -and ($Value -isnot [string]))) {
        $parts = foreach ($item in @($Value)) { ConvertTo-RevisionToken $item }
        return '[' + ($parts -join ',') + ']'
    }
    return 's:' + [string]$Value
}

function Get-FileRevision {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (Get-UngateStableRevision 'absent') }
    return (Get-UngateStableRevision ([IO.File]::ReadAllText($Path)))
}

function Read-StrictDocument {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Corrupt = $false; Data = $null; Message = $null }
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop
        if ($null -eq $data.Version -or [int]$data.Version -ne 1) { throw 'Unsupported or missing version.' }
        return [pscustomobject]@{ Present = $true; Corrupt = $false; Data = $data; Message = $null }
    } catch {
        return [pscustomobject]@{ Present = $true; Corrupt = $true; Data = $null; Message = $_.Exception.Message }
    }
}

function Get-LauncherContext {
    param([Parameter(Mandatory)][string]$BetaHome)
    return New-CodexDesktopLaunchContext -CustomCodexHome $BetaHome -LaunchParameters @{}
}

function Get-OverrideMap {
    param($Context)
    $document = Read-StrictDocument -Path $Context.CustomModelOverridesPath
    if ($document.Corrupt) { return @{ Document = $document; Map = $null } }
    if (-not $document.Present) { return @{ Document = $document; Map = [ordered]@{} } }
    if ('Overrides' -notin $document.Data.PSObject.Properties.Name) {
        $document.Corrupt = $true
        $document.Message = 'Model overrides are missing the overrides property.'
        return @{ Document = $document; Map = $null }
    }
    $map = [ordered]@{}
    foreach ($property in @($document.Data.Overrides.PSObject.Properties)) { $map[$property.Name] = $property.Value }
    return @{ Document = $document; Map = $map }
}

function Copy-OverrideMap {
    param($Map)
    $copy = [ordered]@{}
    foreach ($key in @($Map.Keys)) {
        $fields = ConvertTo-LauncherDictionary $Map[$key]
        $record = [ordered]@{}
        foreach ($name in @($fields.Keys)) { $record[$name] = $fields[$name] }
        $copy[$key] = [pscustomobject]$record
    }
    return $copy
}

function Get-DefinitionsWithoutCapabilityOverrides {
    param($Context, $Map, [string]$Slug)
    $modelSet = New-UngateModelSet -Context $Context
    $custom = @(Read-UngateCustomModelDefinitions -Context $Context -RegistryPath $Context.CustomModelDefinitionsPath -BuiltInDefinitions $modelSet.BuiltInDefinitions)
    $definitions = @($modelSet.BuiltInDefinitions) + $custom
    $stripped = Copy-OverrideMap $Map
    if ($stripped.Contains($Slug)) {
        $fields = ConvertTo-LauncherDictionary $stripped[$Slug]
        foreach ($name in $script:CapabilityFields) { [void]$fields.Remove($name) }
        if ($fields.Count -eq 0) { [void]$stripped.Remove($Slug) }
        else {
            $record = [ordered]@{}
            foreach ($name in @($fields.Keys)) { $record[$name] = $fields[$name] }
            $stripped[$Slug] = [pscustomobject]$record
        }
    }
    if ($stripped.Count -eq 0) { return $definitions }
    return @(Apply-UngateModelOverrides -Context $Context -Definitions $definitions -Overrides $stripped)
}

function Test-CredentialPresence {
    param($Context, $Definition)
    try {
        $resolved = Resolve-ModelApiKey -Context $Context -Definition $Definition
        $available = -not [string]::IsNullOrWhiteSpace([string]$resolved)
        $source = 'UNGATE_API_KEY'
        if ($Definition.ProviderName -eq $Context.OmniRouteProviderName) {
            if ($env:OMNIROUTE_CODEX_API_KEY) { $source = 'OMNIROUTE_CODEX_API_KEY' } else { $source = 'OMNIROUTE_API_KEY' }
        } elseif ($Definition.ProviderName -eq $Context.CliProxyProviderName) {
            $source = 'CLIProxyAPI'
        }
        return [ordered]@{ available = [bool]$available; source = $source }
    } catch {
        return [ordered]@{ available = $false; source = 'missing' }
    }
}

function Get-UngateLauncherState {
    param([Parameter(Mandatory)][string]$BetaHome)
    $context = Get-LauncherContext -BetaHome $BetaHome
    $overrideInfo = Get-OverrideMap -Context $context
    $modelSet = New-UngateModelSet -Context $context
    $definitions = @()
    $definitionError = $null
    if ($overrideInfo.Document.Corrupt) {
        $definitionError = $overrideInfo.Document.Message
    } else {
        try {
            $definitions = @(Get-UngateModelDefinitions -Context $context -BuiltInDefinitions $modelSet.BuiltInDefinitions -RegistryPath $context.CustomModelDefinitionsPath -OverridesPath $context.CustomModelOverridesPath | Where-Object { $_.Slug -ne 'ungate-memory' })
        } catch {
            $definitionError = $_.Exception.Message
        }
    }
    $pickerDocument = Read-StrictDocument -Path $context.PickerModelSelectionPath
    $pickerSlugs = @()
    $pickerError = $null
    if ($pickerDocument.Corrupt) { $pickerError = $pickerDocument.Message }
    elseif ($pickerDocument.Present) {
        try { $pickerSlugs = @($pickerDocument.Data.ModelSlugs | ForEach-Object { [string]$_ }) }
        catch { $pickerError = $_.Exception.Message }
    } elseif ($definitions.Count -gt 0) {
        $pickerSlugs = @(Get-DefaultUngatePickerModelSlugs -Definitions $definitions -Capacity $context.CodexDesktopPickerCapacity)
    }
    $memoryDocument = Read-StrictDocument -Path $context.MemorySettingsPath
    $memory = $null
    $memoryError = $null
    if ($memoryDocument.Corrupt) { $memoryError = $memoryDocument.Message }
    elseif ($memoryDocument.Present) {
        try { Assert-UngateMemorySettings -Settings $memoryDocument.Data; $memory = $memoryDocument.Data }
        catch { $memoryError = $_.Exception.Message }
    }
    $logLevel = $null
    $logError = $null
    $logPresent = Test-Path -LiteralPath $context.LogSettingsPath -PathType Leaf
    if ($logPresent) {
        try {
            $parsedLog = Get-Content -LiteralPath $context.LogSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
            if ($parsedLog.LogLevel -notin $script:LogLevels) { throw 'Unsupported log level.' }
            $logLevel = [string]$parsedLog.LogLevel
        } catch { $logError = $_.Exception.Message }
    } else { $logLevel = 'Standard' }
    $registryDocument = Read-StrictDocument -Path $context.CustomModelDefinitionsPath
    $credentials = @{}
    foreach ($definition in $definitions) {
        $providerName = [string]$definition.ProviderName
        if (-not $credentials.ContainsKey($providerName)) { $credentials[$providerName] = Test-CredentialPresence -Context $context -Definition $definition }
    }
    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $definitions) {
        $slug = [string]$definition.Slug
        $explicit = @{}
        if ($overrideInfo.Map -and $overrideInfo.Map.Contains($slug)) { $explicit = ConvertTo-LauncherDictionary $overrideInfo.Map[$slug] }
        $route = Get-UngateDiagnosticRoute -Context $context -Definition $definition
        $caps = Get-UngateModelCapabilities -Definition $definition -Context $context
        $baseDefinitions = @(Get-DefinitionsWithoutCapabilityOverrides -Context $context -Map $(if ($overrideInfo.Map) { $overrideInfo.Map } else { [ordered]@{} }) -Slug $slug)
        $base = $baseDefinitions | Where-Object { $_.Slug -eq $slug } | Select-Object -First 1
        $baseCaps = Get-UngateModelCapabilities -Definition $base -Context $context
        $template = Get-UngateCapabilityTemplate -Context $context -Definition $definition
        $templateId = ''
        if ($template -and $template.PSObject.Properties['slug']) { $templateId = [string]$template.slug }
        $capExplicit = [ordered]@{}
        $explicitCapabilities = [ordered]@{}
        foreach ($name in $script:CapabilityFields) {
            if ($explicit.ContainsKey($name)) { $capExplicit[$name] = $explicit[$name]; $explicitCapabilities[$name] = $explicit[$name] }
            else { $capExplicit[$name] = 'missing' }
        }
        $versionExplicit = [ordered]@{}
        foreach ($name in $script:VersionFields) {
            if ($explicit.ContainsKey($name)) { $versionExplicit[$name] = $explicit[$name] } else { $versionExplicit[$name] = 'missing' }
        }
        $prefixExplicit = 'missing'
        if ($explicit.ContainsKey('upstreamModelPrefix')) { $prefixExplicit = [string]$explicit['upstreamModelPrefix'] }
        $window = Get-UngateModelContextWindow -Definition $definition
        $native = [string]$definition.UpstreamModel
        if ($definition.PSObject.Properties['DefaultUpstreamModel'] -and $definition.DefaultUpstreamModel) { $native = [string]$definition.DefaultUpstreamModel }
        $capabilityProvenance = 'definition'
        $explicitCapabilityCount = @($script:CapabilityFields | Where-Object { $explicit.ContainsKey($_) }).Count
        if ($explicitCapabilityCount -gt 0) { $capabilityProvenance = 'override' }
        elseif ($templateId) { $capabilityProvenance = 'catalog-template' }
        $credential = $credentials[[string]$definition.ProviderName]
        [void]$models.Add([ordered]@{
            registryId = $slug
            displayName = [string]$definition.DisplayName
            upstreamModel = [string]$definition.UpstreamModel
            nativeUpstream = $native
            requestModel = [string]$route.RequestModel
            transport = [string]$route.Transport
            providerName = [string]$route.ProviderName
            contextWindow = $window.ContextWindow
            contextLabel = [string]$window.Label
            image = [bool]$caps.supportsImageInput
            original = [bool]$caps.supportsImageDetailOriginal
            reasoningDefault = [string]$caps.defaultReasoningLevel
            reasoningLevels = @($caps.supportedReasoningLevels)
            inPicker = $slug -in @($pickerSlugs)
            endpoint = [string]$route.UpstreamBaseUrl
            adapter = $route.ResponsesAdapter
            bridgeRequired = [bool]$route.BridgeRequired
            credentialAvailable = [bool]$credential.available
            credentialSource = [string]$credential.source
            capabilities = $caps
            explicit = [ordered]@{
                upstreamModel = $(if ($explicit.ContainsKey('upstreamModel')) { $explicit['upstreamModel'] } else { $null })
                displayName = $(if ($explicit.ContainsKey('displayName')) { $explicit['displayName'] } else { $null })
                contextWindow = $(if ($explicit.ContainsKey('contextWindow')) { $explicit['contextWindow'] } else { $null })
                upstreamModelPrefix = $(if ($explicit.ContainsKey('upstreamModelPrefix')) { $explicit['upstreamModelPrefix'] } else { $null })
                capabilities = $explicitCapabilities
            }
            provenance = [ordered]@{
                upstreamModel = $(if ($explicit.ContainsKey('upstreamModel')) { 'override' } else { 'definition' })
                displayName = $(if ($explicit.ContainsKey('displayName')) { 'override' } else { 'definition' })
                contextWindow = $(if ($explicit.ContainsKey('contextWindow')) { 'override' } else { 'definition' })
                upstreamModelPrefix = $(if ($explicit.ContainsKey('upstreamModelPrefix')) { 'override' } else { 'none' })
                capabilities = $capabilityProvenance
            }
            revisions = [ordered]@{
                version = Get-UngateStableRevision (ConvertTo-RevisionToken $versionExplicit)
                capabilities = Get-UngateStableRevision ((ConvertTo-RevisionToken $baseCaps) + '|' + $templateId + '|' + (ConvertTo-RevisionToken $capExplicit))
                prefix = Get-UngateStableRevision $prefixExplicit
            }
        })
    }
    $active = $null
    $operationsRoot = Join-Path $context.CustomCodexHome 'launcher-control\operations'
    if (Test-Path -LiteralPath $operationsRoot -PathType Container) {
        $latest = Get-ChildItem -LiteralPath $operationsRoot -Filter '*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            try { $active = Get-Content -LiteralPath $latest.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30 } catch { $active = $null }
        }
    }
    $memorySaved = $null
    if ($memory) {
        $memorySaved = [ordered]@{ enabled = [bool]$memory.Enabled; provider = [string]$memory.Provider; model = [string]$memory.Model }
    }
    return [ordered]@{
        profileId = 'default'
        betaHome = $context.CustomCodexHome
        definitionError = $definitionError
        picker = [ordered]@{ slugs = @($pickerSlugs); capacity = $context.CodexDesktopPickerCapacity; revision = (Get-FileRevision $context.PickerModelSelectionPath); corrupt = [bool]$pickerError; message = $pickerError; usingDefault = -not $pickerDocument.Present }
        memory = [ordered]@{ saved = $memorySaved; revision = (Get-FileRevision $context.MemorySettingsPath); corrupt = [bool]$memoryError; message = $memoryError; defaults = [ordered]@{ enabled = $false; provider = 'cliproxyapi'; model = 'gemini-3.8-flash-high' } }
        logging = [ordered]@{ level = $logLevel; revision = (Get-FileRevision $context.LogSettingsPath); corrupt = [bool]$logError; message = $logError; usingDefault = -not $logPresent }
        registry = [ordered]@{ revision = (Get-FileRevision $context.CustomModelDefinitionsPath); corrupt = [bool]$registryDocument.Corrupt; message = $registryDocument.Message }
        overrides = [ordered]@{ corrupt = [bool]$overrideInfo.Document.Corrupt; message = $overrideInfo.Document.Message }
        models = @($models)
        launch = [ordered]@{ entryPoint = (Join-Path $context.ScriptsRoot 'start-codex-desktop-ungate.ps1'); agentScript = (Join-Path $context.ScriptsRoot 'start-codex-launcher-control.ps1'); fallbackModel = $context.OmniRouteFallbackModel; logLevels = $script:LogLevels; reasoningLevels = $script:ReasoningLevels }
        activeOperation = $active
    }
}

function Assert-Revision {
    param([string]$Expected, [string]$Actual, $Snapshot)
    if ($Expected -ne $Actual) {
        Stop-LauncherRequest -Status 409 -Code 'stale_revision' -Message 'The settings changed since they were loaded.' -Extra @{ currentRevision = $Actual; snapshot = $Snapshot }
    }
}

function Get-PatchLists {
    param($Payload, [string[]]$Allowed)
    $set = @{}; $unset = @()
    if ($Payload.ContainsKey('set') -and $null -ne $Payload.set) { $set = ConvertTo-LauncherDictionary $Payload.set }
    if ($Payload.ContainsKey('unset') -and $null -ne $Payload.unset) { $unset = @($Payload.unset | ForEach-Object { [string]$_ }) }
    foreach ($name in @($set.Keys)) {
        if ($name -notin $Allowed) { Stop-LauncherRequest -Status 422 -Code 'unknown_field' -Message "Unknown field '$name'." }
    }
    foreach ($name in $unset) {
        if ($name -notin $Allowed) { Stop-LauncherRequest -Status 422 -Code 'unknown_field' -Message "Unknown field '$name'." }
        if ($set.ContainsKey($name)) { Stop-LauncherRequest -Status 422 -Code 'invalid_combination' -Message "Field '$name' cannot be both set and unset." }
    }
    return @{ Set = $set; Unset = $unset }
}

function Write-OverrideMap {
    param($Context, $Map)
    $stored = [ordered]@{}
    foreach ($key in @($Map.Keys)) { $stored[$key] = ConvertTo-LauncherDictionary $Map[$key] }
    if ($stored.Count -eq 0) {
        if (Test-Path -LiteralPath $Context.CustomModelOverridesPath -PathType Leaf) { Remove-Item -LiteralPath $Context.CustomModelOverridesPath -Force }
        return
    }
    [void](Write-UngateModelOverrides -OverridesPath $Context.CustomModelOverridesPath -Overrides $stored)
}

function Get-ModelSnapshot {
    param($State, [string]$RegistryId)
    $model = @($State.models) | Where-Object { $_.registryId -eq $RegistryId } | Select-Object -First 1
    if (-not $model) { Stop-LauncherRequest -Status 404 -Code 'unknown_model' -Message "Unknown model '$RegistryId'." }
    return $model
}

function Update-UngateLauncherVersion {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $registryId = [string]$Payload.registryId
    $patch = Get-PatchLists -Payload $Payload -Allowed $script:VersionFields
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $info = Get-OverrideMap -Context $context
        if ($info.Document.Corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $info.Document.Message }
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        $model = Get-ModelSnapshot -State $state -RegistryId $registryId
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$model.revisions.version) -Snapshot $state
        $map = Copy-OverrideMap $info.Map
        $fields = @{}
        if ($map.Contains($registryId)) { $fields = ConvertTo-LauncherDictionary $map[$registryId] }
        foreach ($name in $patch.Unset) { [void]$fields.Remove($name) }
        foreach ($name in @($patch.Set.Keys)) {
            $value = $patch.Set[$name]
            if ($name -eq 'contextWindow') {
                if ($value -is [string]) { $fields[$name] = ConvertTo-ContextWindowTokens -Value $value }
                else {
                    $parsed = 0
                    if (-not [int]::TryParse([string]$value, [ref]$parsed) -or $parsed -le 0) { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'Invalid context window.' }
                    $fields[$name] = $parsed
                }
            } elseif ([string]::IsNullOrWhiteSpace([string]$value)) {
                Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message "Field '$name' cannot be empty."
            } else { $fields[$name] = [string]$value }
        }
        if ($fields.Count -eq 0) { [void]$map.Remove($registryId) } else { $map[$registryId] = [pscustomobject]$fields }
        Write-OverrideMap -Context $context -Map $map
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Update-UngateLauncherCapabilities {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $registryId = [string]$Payload.registryId
    $patch = Get-PatchLists -Payload $Payload -Allowed $script:CapabilityFields
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $info = Get-OverrideMap -Context $context
        if ($info.Document.Corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $info.Document.Message }
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        $model = Get-ModelSnapshot -State $state -RegistryId $registryId
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$model.revisions.capabilities) -Snapshot $state
        $map = Copy-OverrideMap $info.Map
        $fields = @{}
        if ($map.Contains($registryId)) { $fields = ConvertTo-LauncherDictionary $map[$registryId] }
        foreach ($name in $patch.Unset) { [void]$fields.Remove($name) }
        foreach ($name in @($patch.Set.Keys)) { $fields[$name] = $patch.Set[$name] }
        $values = @{}
        foreach ($name in $script:CapabilityFields) { if ($fields.ContainsKey($name)) { $values[$name] = $fields[$name] } }
        if ($values.Contains('supportsImageInput') -and $values.supportsImageInput -eq $false -and -not $values.Contains('supportsImageDetailOriginal')) { $values.supportsImageDetailOriginal = $false; $fields.supportsImageDetailOriginal = $false }
        if ($values.Contains('supportsReasoningSummaries') -and $values.supportsReasoningSummaries -eq $false) { $values.defaultReasoningSummary = 'none'; $fields.defaultReasoningSummary = 'none' }
        if ($values.Contains('supportVerbosity') -and $values.supportVerbosity -eq $false) { $values.defaultVerbosity = $null; $fields.defaultVerbosity = $null }
        $base = @(Get-DefinitionsWithoutCapabilityOverrides -Context $context -Map $info.Map -Slug $registryId) | Where-Object { $_.Slug -eq $registryId } | Select-Object -First 1
        try { [void](Merge-UngateModelCapabilities -Definition $base -Context $context -Values $values) }
        catch { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message $_.Exception.Message }
        if ($fields.Count -eq 0) { [void]$map.Remove($registryId) } else { $map[$registryId] = [pscustomobject]$fields }
        Write-OverrideMap -Context $context -Map $map
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Update-UngateLauncherPrefix {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $registryId = [string]$Payload.registryId
    $patch = Get-PatchLists -Payload $Payload -Allowed @('upstreamModelPrefix')
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $info = Get-OverrideMap -Context $context
        if ($info.Document.Corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $info.Document.Message }
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        $model = Get-ModelSnapshot -State $state -RegistryId $registryId
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$model.revisions.prefix) -Snapshot $state
        $map = Copy-OverrideMap $info.Map
        $fields = @{}
        if ($map.Contains($registryId)) { $fields = ConvertTo-LauncherDictionary $map[$registryId] }
        foreach ($name in $patch.Unset) { [void]$fields.Remove($name) }
        foreach ($name in @($patch.Set.Keys)) {
            $value = [string]$patch.Set[$name]
            if ($value -notmatch '^[A-Za-z0-9._-]+$') {
                Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'Invalid upstream model prefix.'
            }
            $fields[$name] = $value
        }
        if ($fields.Count -eq 0) { [void]$map.Remove($registryId) } else { $map[$registryId] = [pscustomobject]$fields }
        Write-OverrideMap -Context $context -Map $map
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Reset-UngateLauncherModel {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $registryId = [string]$Payload.registryId
    $scope = [string]$Payload.scope
    $fields = switch ($scope) {
        'version' { $script:VersionFields }
        'capabilities' { $script:CapabilityFields }
        'transport-prefix' { @('upstreamModelPrefix') }
        default { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'Unknown reset scope.' }
    }
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $info = Get-OverrideMap -Context $context
        if ($info.Document.Corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $info.Document.Message }
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        $model = Get-ModelSnapshot -State $state -RegistryId $registryId
        $actual = switch ($scope) { 'version' { $model.revisions.version } 'capabilities' { $model.revisions.capabilities } default { $model.revisions.prefix } }
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$actual) -Snapshot $state
        [void](Remove-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $registryId -Fields $fields)
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Add-UngateLauncherModel {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $image = $Payload.supportsImageInput
    $original = $false
    if ($Payload.ContainsKey('supportsImageDetailOriginal')) { $original = [bool]$Payload.supportsImageDetailOriginal }
    if ($image -isnot [bool] -or ($Payload.ContainsKey('supportsImageDetailOriginal') -and $Payload.supportsImageDetailOriginal -isnot [bool])) {
        Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'Image flags must be booleans.'
    }
    $record = [pscustomobject][ordered]@{
        Slug = [string]$Payload.registryId
        DisplayName = [string]$Payload.displayName
        UpstreamModel = [string]$Payload.upstreamModel
        Transport = [string]$Payload.transport
        DefaultReasoningLevel = [string]$Payload.defaultReasoningLevel
        SupportsImageInput = [bool]$image
        supportsImageDetailOriginal = [bool]$original
    }
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $registry = Read-StrictDocument -Path $context.CustomModelDefinitionsPath
        if ($registry.Corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $registry.Message }
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual (Get-FileRevision $context.CustomModelDefinitionsPath) -Snapshot (Get-UngateLauncherState -BetaHome $BetaHome)
        $modelSet = New-UngateModelSet -Context $context
        $existing = @(Read-UngateCustomModelDefinitions -Context $context -RegistryPath $context.CustomModelDefinitionsPath -BuiltInDefinitions $modelSet.BuiltInDefinitions)
        try { [void](ConvertTo-UngateModelDefinition -Context $context -Record $record -Priority ($modelSet.BuiltInDefinitions.Count + $existing.Count)) }
        catch { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message $_.Exception.Message }
        $known = @($modelSet.BuiltInDefinitions.Slug) + @($existing.Slug)
        if ($record.Slug -in $known) { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message "Model ID '$($record.Slug)' already exists." }
        [void](Write-UngateCustomModelDefinitions -Context $context -RegistryPath $context.CustomModelDefinitionsPath -Records (@($existing) + @($record)) -BuiltInDefinitions $modelSet.BuiltInDefinitions)
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Set-UngateLauncherPicker {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $ids = @($Payload.registryIds | ForEach-Object { [string]$_ })
    if ($ids -contains 'ungate-memory') { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'ungate-memory is not a picker model.' }
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $document = Read-StrictDocument -Path $context.PickerModelSelectionPath
        if ($document.Corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $document.Message }
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$state.picker.revision) -Snapshot $state
        $modelSet = New-UngateModelSet -Context $context
        $definitions = @(Get-UngateModelDefinitions -Context $context -BuiltInDefinitions $modelSet.BuiltInDefinitions -RegistryPath $context.CustomModelDefinitionsPath -OverridesPath $context.CustomModelOverridesPath)
        try { [void](Write-UngatePickerModelSelection -SettingsPath $context.PickerModelSelectionPath -ModelSlugs $ids -Definitions $definitions -Capacity $context.CodexDesktopPickerCapacity) }
        catch { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message $_.Exception.Message }
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Set-UngateLauncherLogging {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $level = [string]$Payload.level
    if ($level -notin $script:LogLevels) { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'Unsupported log level.' }
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        if ($state.logging.corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $state.logging.message }
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$state.logging.revision) -Snapshot $state
        Write-UngateLogSettings -SettingsPath $context.LogSettingsPath -LogLevel $level
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function Set-UngateLauncherMemory {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $candidate = [pscustomobject]@{ Version = 1; Enabled = $Payload.enabled; Provider = [string]$Payload.provider; Model = [string]$Payload.model }
    try { Assert-UngateMemorySettings -Settings $candidate } catch { Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message $_.Exception.Message }
    $lease = Enter-UngateProfileLock -HomePath $BetaHome
    try {
        $context = Get-LauncherContext -BetaHome $BetaHome
        $state = Get-UngateLauncherState -BetaHome $BetaHome
        if ($state.memory.corrupt) { Stop-LauncherRequest -Status 422 -Code 'corrupt_settings' -Message $state.memory.message }
        Assert-Revision -Expected ([string]$Payload.expectedRevision) -Actual ([string]$state.memory.revision) -Snapshot $state
        Write-UngateMemorySettings -Context $context -Settings $candidate
        return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome)
    } finally { Exit-UngateProfileLock -Lease $lease }
}

function New-UngateRunnerConfiguration {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][string]$Kind, [string[]]$RegistryIds)
    $context = Get-LauncherContext -BetaHome $BetaHome
    $modelSet = New-UngateModelSet -Context $context
    $definitions = @(Get-UngateModelDefinitions -Context $context -BuiltInDefinitions $modelSet.BuiltInDefinitions -RegistryPath $context.CustomModelDefinitionsPath -OverridesPath $context.CustomModelOverridesPath)
    if ($Kind -eq 'memory') {
        $settings = Read-UngateMemorySettings -Context $context
        $definition = Get-UngateMemoryDefinition -Context $context -Settings $settings
        $route = Get-UngateDiagnosticRoute -Context $context -Definition $definition
        $key = Resolve-ModelApiKey -Context $context -Definition $definition
        return @{
            kind = 'memory'
            configuration = @{ model = $route.RequestModel; apiKey = $key; upstreamBaseUrl = $route.UpstreamBaseUrl; responsesAdapter = $route.ResponsesAdapter; bridgeUpstreamUrl = $route.BridgeUpstreamUrl }
            fingerprint = Get-UngateStableRevision ($route.RequestModel + '|' + $settings.Provider + '|' + $settings.Model)
        }
    }
    $selected = foreach ($id in @($RegistryIds)) {
        $definition = $definitions | Where-Object { $_.Slug -eq $id } | Select-Object -First 1
        if (-not $definition) { Stop-LauncherRequest -Status 404 -Code 'unknown_model' -Message "Unknown model '$id'." }
        $route = Get-UngateDiagnosticRoute -Context $context -Definition $definition
        $record = @{
            registryId = $route.RegistryId
            model = $route.RequestModel
            displayName = [string]$definition.DisplayName
            upstreamBaseUrl = $route.UpstreamBaseUrl
            responsesAdapter = $route.ResponsesAdapter
            bridgeUpstreamUrl = $route.BridgeUpstreamUrl
            capabilities = Get-UngateModelCapabilities -Definition $definition -Context $context
        }
        if ($definition.PSObject.Properties['ParallelToolCallsOverride']) { $record.parallelToolCalls = [bool]$definition.ParallelToolCallsOverride }
        try { $record.apiKey = Resolve-ModelApiKey -Context $context -Definition $definition }
        catch { $record.error = 'Provider credentials are unavailable.' }
        $record
    }
    return @{ kind = $Kind; models = @($selected); reportDirectory = $(if ($Kind -eq 'tools') { Join-Path $BetaHome 'tool-compatibility/reports' } else { Join-Path $BetaHome 'model-capabilities/reports' }) }
}

function Remove-SensitiveValue {
    param($Value)
    $hidden = @('apiKey', 'authorization', 'prompt', 'arguments', 'image', 'imageUrl', 'input', 'tools', 'api_key', 'png')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) { if ([string]$key -notin $hidden) { $copy[[string]$key] = Remove-SensitiveValue $Value[$key] } }
        return $copy
    }
    if (($Value -is [System.Array]) -or (($Value -is [System.Collections.IList]) -and ($Value -isnot [string]))) {
        return @($Value | ForEach-Object { Remove-SensitiveValue $_ })
    }
    if ($Value.PSObject.Properties.Count -gt 0) {
        $copy = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) { if ($property.Name -notin $hidden) { $copy[$property.Name] = Remove-SensitiveValue $property.Value } }
        return $copy
    }
    return [string]$Value
}

function Get-UngateLauncherCatalog {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][hashtable]$Payload)
    $transport = [string]$Payload.transport
    if ($transport -notin @('ungate', 'cliproxyapi', 'omniroute')) {
        Stop-LauncherRequest -Status 422 -Code 'invalid_settings' -Message 'Unknown transport.'
    }
    $context = Get-LauncherContext -BetaHome $BetaHome
    $modelSet = New-UngateModelSet -Context $context
    $definitions = @(Get-UngateModelDefinitions -Context $context -BuiltInDefinitions $modelSet.BuiltInDefinitions -RegistryPath $context.CustomModelDefinitionsPath -OverridesPath $context.CustomModelOverridesPath)
    $sample = $definitions | Where-Object { [string]$_.Transport -eq $transport -and [string]$_.Slug -ne 'ungate-memory' } | Select-Object -First 1
    if (-not $sample) {
        return New-LauncherResult -Body ([ordered]@{ transport = $transport; available = $false; models = @(); message = 'No registry model uses this transport.' })
    }
    $route = Get-UngateDiagnosticRoute -Context $context -Definition $sample
    $baseUrl = [string]$route.UpstreamBaseUrl
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return New-LauncherResult -Body ([ordered]@{ transport = $transport; available = $false; models = @(); message = 'Transport has no catalog endpoint.' })
    }
    try { $key = Resolve-ModelApiKey -Context $context -Definition $sample }
    catch {
        return New-LauncherResult -Body ([ordered]@{ transport = $transport; available = $false; models = @(); message = 'Provider credentials are unavailable.' })
    }
    try {
        $headers = @{ Authorization = 'Bearer ' + $key }
        $catalog = Invoke-RestMethod -Uri ($baseUrl.TrimEnd('/') + '/v1/models') -Headers $headers -NoProxy -TimeoutSec 10
        $ids = @($catalog.data | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        return New-LauncherResult -Body ([ordered]@{ transport = $transport; available = $true; models = @($ids); message = $null })
    } catch {
        return New-LauncherResult -Body ([ordered]@{ transport = $transport; available = $false; models = @(); message = 'Catalog is unavailable. Enter an upstream ID manually.' })
    }
}

function Get-UngateLauncherReport {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][string]$ReportId)
    if ($ReportId -notmatch '^[A-Za-z0-9._-]{1,160}$') { Stop-LauncherRequest -Status 404 -Code 'unknown_report' -Message 'Report not found.' }
    $context = Get-LauncherContext -BetaHome $BetaHome
    foreach ($relative in @('launcher-control\reports', 'model-capabilities\reports', 'tool-compatibility\reports')) {
        $path = Join-Path (Join-Path $context.CustomCodexHome $relative) ($ReportId + '.json')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $data = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
            return New-LauncherResult -Body (Remove-SensitiveValue $data)
        }
    }
    Stop-LauncherRequest -Status 404 -Code 'unknown_report' -Message 'Report not found.'
}

function Invoke-UngateLauncherRequest {
    param([Parameter(Mandatory)][string]$BetaHome, [Parameter(Mandatory)][string]$Action, [hashtable]$Payload = @{})
    try {
        switch ($Action) {
            'state.get' { return New-LauncherResult -Body (Get-UngateLauncherState -BetaHome $BetaHome) }
            'models.version' { return Update-UngateLauncherVersion -BetaHome $BetaHome -Payload $Payload }
            'models.capabilities' { return Update-UngateLauncherCapabilities -BetaHome $BetaHome -Payload $Payload }
            'models.reset' { return Reset-UngateLauncherModel -BetaHome $BetaHome -Payload $Payload }
            'models.add' { return Add-UngateLauncherModel -BetaHome $BetaHome -Payload $Payload }
            'picker.set' { return Set-UngateLauncherPicker -BetaHome $BetaHome -Payload $Payload }
            'logging.set' { return Set-UngateLauncherLogging -BetaHome $BetaHome -Payload $Payload }
            'memories.set' { return Set-UngateLauncherMemory -BetaHome $BetaHome -Payload $Payload }
            'models.prefix' { return Update-UngateLauncherPrefix -BetaHome $BetaHome -Payload $Payload }
            'catalog.list' { return Get-UngateLauncherCatalog -BetaHome $BetaHome -Payload $Payload }
            'reports.get' { return Get-UngateLauncherReport -BetaHome $BetaHome -ReportId ([string]$Payload.reportId) }
            default { Stop-LauncherRequest -Status 404 -Code 'unknown_action' -Message 'Unknown action.' }
        }
    } catch {
        $text = $_.Exception.Message
        if ($text -match '^LAUNCHER_FAIL\|(\d+)\|([a-z0-9_]+)\|(.*)$') {
            return New-LauncherResult -Status ([int]$Matches[1]) -Body ($Matches[3] | ConvertFrom-Json -Depth 30)
        }
        return New-LauncherResult -Status 422 -Body ([ordered]@{ code = 'invalid_settings'; message = $text })
    }
}

Export-ModuleMember -Function @(
    'Get-UngateLauncherState', 'Invoke-UngateLauncherRequest', 'New-UngateRunnerConfiguration',
    'Remove-SensitiveValue', 'Get-UngateLauncherReport', 'Set-UngateLauncherMemory', 'ConvertTo-LauncherDictionary'
)
