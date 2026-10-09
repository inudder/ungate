#requires -Version 7.4
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ModelCapabilities.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop

function Resolve-CapabilityModel {
    param([Parameter(Mandatory)][object[]]$Definitions, [Parameter(Mandatory)][string]$Model)
    $modelMatches = @($Definitions | Where-Object {
        $_.Slug -eq $Model -or $_.UpstreamModel -eq $Model -or $Model -in @($_.Aliases)
    })
    if ($modelMatches.Count -ne 1) { throw "Unknown or ambiguous model '$Model'. Use its registry ID." }
    return $modelMatches[0]
}

function Set-UngateModelCapabilities {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Values)
    $patch = ConvertTo-CapabilityDictionary $Values
    if ($patch.ContainsKey('supportsImageInput') -and $patch.supportsImageInput -eq $false -and -not $patch.ContainsKey('supportsImageDetailOriginal')) {
        $patch.supportsImageDetailOriginal = $false
    }
    if ($patch.ContainsKey('supportsReasoningSummaries') -and $patch.supportsReasoningSummaries -eq $false) { $patch.defaultReasoningSummary = 'none' }
    if ($patch.ContainsKey('supportVerbosity') -and $patch.supportVerbosity -eq $false) { $patch.defaultVerbosity = $null }
    $null = Merge-UngateModelCapabilities -Definition $Definition -Context $Context -Values $patch
    if ($patch.Count -gt 0) {
        $null = Set-UngateModelOverride -OverridesPath $Context.CustomModelOverridesPath -Slug $Definition.Slug -Override $patch
    }
}

function Get-CapabilityRunnerModel {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object]$Definition)
    $record = @{
        registryId = $Definition.Slug
        model = Get-UngateRequestModel -Definition $Definition
        displayName = $Definition.DisplayName
        upstreamBaseUrl = $Definition.ProxyBaseUrl
        responsesAdapter = $Definition.ResponsesAdapter
        bridgeUpstreamUrl = if ($Definition.ProviderName -eq $Context.CliProxyProviderName) { $Context.CliProxyUpstreamBaseUrl } else { $null }
        capabilities = Get-UngateModelCapabilities -Definition $Definition -Context $Context
    }
    if ($Definition.PSObject.Properties['ParallelToolCallsOverride']) { $record.parallelToolCalls = [bool]$Definition.ParallelToolCallsOverride }
    return $record
}

function Invoke-CapabilityRunner {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][hashtable]$Configuration, [switch]$StatusOnly)
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $runnerArguments = @((Join-Path $Context.ScriptsRoot 'codex-model-capabilities.mjs'))
    if ($StatusOnly) { $runnerArguments += '--status' }
    $Configuration | ConvertTo-Json -Depth 30 -Compress | & $nodePath $runnerArguments | ForEach-Object { Write-Host $_ }
    return [int]$LASTEXITCODE
}

function Invoke-UngateCapabilityTest {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object]$Definition)
    $record = Get-CapabilityRunnerModel -Context $Context -Definition $Definition
    try { $record.apiKey = Resolve-ModelApiKey -Context $Context -Definition $Definition -ApiKey $Context.Options.ApiKey }
    catch { $record.error = 'Provider credentials are unavailable.' }
    return Invoke-CapabilityRunner -Context $Context -Configuration @{
        model = $record
        reportDirectory = Join-Path $Context.CustomCodexHome 'model-capabilities/reports'
    }
}

function Invoke-UngateCapabilitiesMenu {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object[]]$Definitions, [string]$Model)
    if ($Model) { $definition = Resolve-CapabilityModel -Definitions $Definitions -Model $Model }
    else {
        Write-Host 'Возможности моделей — выберите модель:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $Definitions.Count; $index++) { Write-Host "  $($index + 1)) $($Definitions[$index].DisplayName)" }
        $selection = Read-Host 'Номер модели; Enter — назад'
        if (-not $selection) { return $false }
        $number = 0
        if (-not [int]::TryParse($selection, [ref]$number) -or $number -lt 1 -or $number -gt $Definitions.Count) { throw 'Invalid model selection.' }
        $definition = $Definitions[$number - 1]
    }
    $draft = @{}
    $changed = $false
    while ($true) {
        $effective = Merge-UngateModelCapabilities -Definition $definition -Context $Context -Values $draft
        $saved = Read-UngateModelOverrides -OverridesPath $Context.CustomModelOverridesPath
        $overridden = @()
        if ($saved.Contains($definition.Slug)) {
            $entry = ConvertTo-CapabilityDictionary $saved[$definition.Slug]
            $overridden = @(Get-UngateCapabilityNames | Where-Object { $entry.ContainsKey($_) })
        }
        Write-Host "`n$($definition.DisplayName) [$($definition.UpstreamModel)]" -ForegroundColor Cyan
        Write-Host '  Text: всегда включён'
        $overrideLabel = if ($overridden.Count) { $overridden -join ', ' } else { 'нет; наследуются значения модели' }
        Write-Host "  Override: $overrideLabel"
        if ($draft.Count) { Write-Host '  Есть несохранённые изменения.' -ForegroundColor Yellow }
        Write-Host "  1) Image: $($effective.supportsImageInput)"
        Write-Host "  2) Original: $($effective.supportsImageDetailOriginal)"
        Write-Host "  3) Уровни рассуждений: $($effective.supportedReasoningLevels -join ', ')"
        Write-Host "  4) Уровень по умолчанию: $($effective.defaultReasoningLevel)"
        Write-Host "  5) Описания рассуждений: $($effective.defaultReasoningSummary)"
        Write-Host "  6) Параллельные инструменты: $($effective.supportsParallelToolCalls)"
        Write-Host "  7) Verbosity: $($effective.supportVerbosity); $($effective.defaultVerbosity)"
        $null = Invoke-CapabilityRunner -Context $Context -StatusOnly -Configuration @{
            model = (Get-CapabilityRunnerModel -Context $Context -Definition $definition)
            reportDirectory = Join-Path $Context.CustomCodexHome 'model-capabilities/reports'
        }
        $choice = Read-Host '1–7: изменить; S: сохранить; R: сбросить возможности; T: проверить; B/Enter: выйти'
        if (-not $choice -or $choice -match '^(b|back)$') { return $changed }
        try {
            switch ($choice.ToLowerInvariant()) {
                's' {
                    Set-UngateModelCapabilities -Context $Context -Definition $definition -Values $draft
                    $definition = Apply-UngateModelCapabilities -Definition $definition -Context $Context -Values $draft
                    $draft = @{}
                    $changed = $true
                    Write-Host 'Сохранено. Применится при следующем запуске Beta через launcher.' -ForegroundColor Green
                }
                'r' {
                    $null = Remove-UngateModelOverride -OverridesPath $Context.CustomModelOverridesPath -Slug $definition.Slug -Fields @(Get-UngateCapabilityNames)
                    $builtins = (New-UngateModelSet -Context $Context).BuiltInDefinitions
                    $all = @(Get-UngateModelDefinitions -Context $Context -BuiltInDefinitions $builtins -RegistryPath $Context.CustomModelDefinitionsPath)
                    $definition = Resolve-CapabilityModel -Definitions $all -Model $definition.Slug
                    $draft = @{}
                    $changed = $true
                }
                't' {
                    if ($draft.Count -gt 0) { Write-Host 'Сначала сохраните изменения (S). Проверка использует сохранённые настройки.' -ForegroundColor Yellow }
                    else { $null = Invoke-UngateCapabilityTest -Context $Context -Definition $definition }
                }
                default {
                    $patch = ConvertTo-CapabilityDictionary $draft
                    switch ($choice) {
                        '1' { $patch.supportsImageInput = -not $effective.supportsImageInput; if (-not $patch.supportsImageInput) { $patch.supportsImageDetailOriginal = $false } }
                        '2' { if (-not $effective.supportsImageInput) { throw 'Сначала включите Image.' }; $patch.supportsImageDetailOriginal = -not $effective.supportsImageDetailOriginal }
                        '3' { $patch.supportedReasoningLevels = @((Read-Host 'Уровни через запятую: none,minimal,low,medium,high,xhigh,max,ultra') -split '[,\s]+' | Where-Object { $_ }); $patch.defaultReasoningLevel = Read-Host 'Уровень по умолчанию' }
                        '4' { $patch.defaultReasoningLevel = Read-Host 'Уровень по умолчанию из разрешённого списка' }
                        '5' { $patch.defaultReasoningSummary = Read-Host 'none/auto/concise/detailed'; $patch.supportsReasoningSummaries = $patch.defaultReasoningSummary -ne 'none' }
                        '6' { $patch.supportsParallelToolCalls = -not $effective.supportsParallelToolCalls }
                        '7' { $value = Read-Host 'off/low/medium/high'; $patch.supportVerbosity = $value -ne 'off'; $patch.defaultVerbosity = if ($patch.supportVerbosity) { $value } else { $null } }
                        default { throw 'Неизвестная команда.' }
                    }
                    $null = Merge-UngateModelCapabilities -Definition $definition -Context $Context -Values $patch
                    $draft = $patch
                }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

function Invoke-UngateCapabilitiesCommand {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object[]]$Definitions)
    $model = if ($Context.BoundParameterNames.Contains('Model')) { $Context.Options.Model } else { $null }
    if ($Context.Options.TestModelCapabilities -or $Context.BoundParameterNames.Contains('SetModelCapabilities')) {
        if (-not $model) { throw '-Model is required for capability updates and tests.' }
        $definition = Resolve-CapabilityModel -Definitions $Definitions -Model $model
        if ($Context.Options.TestModelCapabilities) { return Invoke-UngateCapabilityTest -Context $Context -Definition $definition }
        if ($Context.Options.SetModelCapabilities -eq 'reset') {
            $null = Remove-UngateModelOverride -OverridesPath $Context.CustomModelOverridesPath -Slug $definition.Slug -Fields @(Get-UngateCapabilityNames)
        } else {
            $values = ConvertFrom-Json -InputObject $Context.Options.SetModelCapabilities -AsHashtable -Depth 20
            if ($values -isnot [Collections.IDictionary]) { throw '-SetModelCapabilities requires a JSON object or reset.' }
            Set-UngateModelCapabilities -Context $Context -Definition $definition -Values $values
        }
        return 0
    }
    $null = Invoke-UngateCapabilitiesMenu -Context $Context -Definitions $Definitions -Model $model
    return 0
}

Export-ModuleMember -Function @('Resolve-CapabilityModel', 'Set-UngateModelCapabilities',
    'Get-CapabilityRunnerModel', 'Invoke-UngateCapabilityTest', 'Invoke-UngateCapabilitiesMenu', 'Invoke-UngateCapabilitiesCommand')
