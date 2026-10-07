#requires -Version 7.4
# Memory preferences and validation; importing this module has no side effects.
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Toml.psm1') -DisableNameChecking -ErrorAction Stop

function New-UngateMemorySettings {
    return [pscustomobject]@{ Version = 1; Enabled = $false; Provider = 'cliproxyapi'; Model = 'gemini-3.8-flash-high' }
}

function Assert-UngateMemorySettings {
    param([Parameter(Mandatory)][psobject]$Settings)
    if ($Settings.Version -ne 1 -or $Settings.Enabled -isnot [bool] -or
        $Settings.Provider -isnot [string] -or $Settings.Model -isnot [string] -or
        $Settings.Provider -notin @('cliproxyapi', 'omniroute', 'ungate') -or
        [string]::IsNullOrWhiteSpace($Settings.Model) -or $Settings.Model -match '[\s"''\\\x00-\x1f]') {
        throw 'Invalid memory settings. Select a provider and a non-empty upstream model ID.'
    }
}

function Read-UngateMemorySettings {
    param([Parameter(Mandatory)][psobject]$Context)
    $defaults = New-UngateMemorySettings
    if (-not (Test-Path -LiteralPath $Context.MemorySettingsPath)) { return $defaults }
    try {
        $settings = Get-Content -LiteralPath $Context.MemorySettingsPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        Assert-UngateMemorySettings -Settings $settings
        return $settings
    } catch {
        Write-Warning 'Memory settings could not be read. This launch will use memories Off; the original settings file is retained.'
        return $defaults
    }
}

function Write-UngateMemorySettings {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][psobject]$Settings)
    $ErrorActionPreference = 'Stop'
    Assert-UngateMemorySettings -Settings $Settings
    $path = [IO.Path]::GetFullPath($Context.MemorySettingsPath)
    $directory = [IO.Path]::GetDirectoryName($path)
    [void][IO.Directory]::CreateDirectory($directory)
    $transaction = [guid]::NewGuid().ToString('N')
    $temporary = Join-Path $directory ".memory.$transaction.tmp"
    $backup = Join-Path $directory ".memory.$transaction.bak"
    $record = [ordered]@{ Version = 1; Enabled = $Settings.Enabled; Provider = $Settings.Provider; Model = $Settings.Model }
    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json) + "`r`n", [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Replace($temporary, $path, $backup) }
    else { [IO.File]::Move($temporary, $path) }
}

function Get-UngateMemoryDefinition {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][psobject]$Settings)
    Assert-UngateMemorySettings -Settings $Settings
    $providerName = switch ($Settings.Provider) {
        'cliproxyapi' { $Context.CliProxyProviderName }
        'omniroute' { $Context.OmniRouteProviderName }
        'ungate' { $Context.ProviderName }
    }
    $modelSet = New-UngateModelSet -Context $Context
    $definitions = @(Get-UngateModelDefinitions -Context $Context -BuiltInDefinitions $modelSet.BuiltInDefinitions `
        -RegistryPath $Context.CustomModelDefinitionsPath -OverridesPath $Context.CustomModelOverridesPath)
    $known = $definitions | Where-Object { $_.ProviderName -eq $providerName -and
        ($_.UpstreamModel -eq $Settings.Model -or $_.Slug -eq $Settings.Model) } | Select-Object -First 1
    if ($known) {
        $properties = [ordered]@{}
        foreach ($property in $known.PSObject.Properties) { $properties[$property.Name] = $property.Value }
        $definition = [pscustomobject]$properties
    } else {
        $definition = ConvertTo-UngateModelDefinition -Context $Context -Priority 100 -Record ([pscustomobject]@{
            Slug = 'ungate-memory'; DisplayName = 'Local memory model'; UpstreamModel = $Settings.Model
            Transport = $Settings.Provider; DefaultReasoningLevel = 'high'; SupportsImageInput = $false
        })
    }
    $definition | Add-Member NoteProperty Slug 'ungate-memory' -Force
    $definition | Add-Member NoteProperty ShellSlug 'ungate-memory' -Force
    $definition | Add-Member NoteProperty UpstreamModel $Settings.Model -Force
    return $definition
}

function Invoke-UngateMemoryProbe {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][hashtable]$Configuration)
    $ErrorActionPreference = 'Stop'
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $runnerArguments = @((Join-Path $Context.ScriptsRoot 'codex-memory-preflight.mjs'))
    $lines = @($Configuration | ConvertTo-Json -Depth 20 -Compress | & $nodePath @runnerArguments 2>&1 | ForEach-Object {
        if ([string]$_ -match '^\[memory\]') { Write-Host ([string]$_) -ForegroundColor DarkGray }
        else { [string]$_ }
    })
    $runnerExitCode = $LASTEXITCODE
    $result = ($lines -join "`n") | ConvertFrom-Json -ErrorAction Stop
    if ($runnerExitCode -ne 0) { $result.valid = $false }
    return $result
}

function Invoke-UngateMemoryValidation {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][psobject]$Settings, [switch]$Force)
    $ErrorActionPreference = 'Stop'
    $signature = "$($Settings.Provider)/$($Settings.Model)"
    if (-not $Force -and $Context.MemoryValidationSignature -eq $signature) { return $Context.MemoryValidationResult }
    $Context.MemoryValidationSignature = $null
    $Context.MemoryValidationResult = $null
    try {
        $definition = Get-UngateMemoryDefinition -Context $Context -Settings $Settings
        $key = Resolve-ModelApiKey -Context $Context -Definition $definition
        $configuration = @{
            model = $Settings.Model; apiKey = $key; upstreamBaseUrl = $definition.ProxyBaseUrl
            responsesAdapter = $definition.ResponsesAdapter
            bridgeUpstreamUrl = if ($Settings.Provider -eq 'cliproxyapi') { $Context.CliProxyUpstreamBaseUrl } else { $null }
        }
        Write-Host "[memory] Checking $($Settings.Provider): $($Settings.Model)..." -ForegroundColor Cyan
        $result = Invoke-UngateMemoryProbe -Context $Context -Configuration $configuration
        if ($result.valid -ne $true) {
            $result = [pscustomobject]@{ Valid = $false; Stage = $result.stage; Code = $result.code }
        }
    } catch {
        $result = [pscustomobject]@{ Valid = $false; Stage = 'configuration'; Code = 'credentials_or_configuration_unavailable' }
    }
    if ($result.Valid) {
        $Context.MemoryValidationSignature = $signature
        $Context.MemoryValidationResult = $result
        Write-Host '[memory] Extraction and consolidation compatibility passed.' -ForegroundColor Green
    } else {
        Write-Warning "Memory model validation failed: $($result.Stage) / $($result.Code)."
    }
    return $result
}

function Get-UngateMemoryCatalog {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][psobject]$Settings)
    $ErrorActionPreference = 'Stop'
    $definition = Get-UngateMemoryDefinition -Context $Context -Settings $Settings
    $key = Resolve-ModelApiKey -Context $Context -Definition $definition
    $baseUrl = if ($Settings.Provider -eq 'cliproxyapi') { $Context.CliProxyUpstreamBaseUrl } else { $definition.ProxyBaseUrl }
    $catalog = Invoke-RestMethod -Uri "$baseUrl/v1/models" -Headers @{ Authorization = "Bearer $key" } -NoProxy -TimeoutSec 10
    return @($catalog.data | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
}

function Invoke-UngateMemoryMenu {
    param([Parameter(Mandatory)][psobject]$Context)
    $ErrorActionPreference = 'Stop'
    $settings = Read-UngateMemorySettings -Context $Context
    while ($true) {
        Write-Host ''
        Write-Host '--- Настройки памяти Codex Beta ---' -ForegroundColor Cyan
        $state = if ($settings.Enabled) { 'Включена' } else { 'Выключена' }
        Write-Host "Память: $state; модель: $($settings.Provider) / $($settings.Model)"
        Write-Host 'Одна модель используется для извлечения и консолидации. Изменения применятся при следующем запуске Codex через launcher.'
        Write-Host '  1) Включить / выключить память'
        Write-Host '  2) Выбрать провайдера и модель'
        Write-Host '  3) Проверить текущую модель'
        Write-Host '  4) Вернуть модель по умолчанию (Gemini 3.8 Flash High / CLIProxyAPI)'
        Write-Host '  B) Назад'
        $choice = Read-Host 'Выберите [1-4 или B]'
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim() -eq 'b') { return }
        if ($choice.Trim() -eq '3') {
            $null = Invoke-UngateMemoryValidation -Context $Context -Settings $settings -Force
            continue
        }
        $candidate = [pscustomobject]@{ Version = 1; Enabled = $settings.Enabled; Provider = $settings.Provider; Model = $settings.Model }
        switch ($choice.Trim()) {
            '1' { $candidate.Enabled = -not $candidate.Enabled }
            '2' {
                Write-Host 'Провайдер: 1) CLIProxyAPI  2) OmniRoute  3) Ungate  B) Отмена'
                $providerChoice = Read-Host 'Провайдер'
                $provider = switch ($providerChoice.Trim()) { '1' { 'cliproxyapi' } '2' { 'omniroute' } '3' { 'ungate' } }
                if (-not $provider) { continue }
                $candidate.Provider = $provider
                $modelSet = New-UngateModelSet -Context $Context
                $definitions = @(Get-UngateModelDefinitions -Context $Context -BuiltInDefinitions $modelSet.BuiltInDefinitions `
                    -RegistryPath $Context.CustomModelDefinitionsPath -OverridesPath $Context.CustomModelOverridesPath)
                $providerName = (Get-UngateMemoryDefinition -Context $Context -Settings $candidate).ProviderName
                $models = @($definitions | Where-Object { $_.ProviderName -eq $providerName } | ForEach-Object {
                    if ($_.UpstreamModel) { [string]$_.UpstreamModel } else { [string]$_.Slug }
                })
                try { $models += @(Get-UngateMemoryCatalog -Context $Context -Settings $candidate) }
                catch { Write-Warning 'Catalog unavailable. You can enter an upstream model ID manually.' }
                $models = @($models | Sort-Object -Unique)
                for ($index = 0; $index -lt $models.Count; $index++) { Write-Host "  $($index + 1)) $($models[$index])" }
                $modelChoice = Read-Host 'Номер или точный upstream ID модели (Enter — отмена)'
                if ([string]::IsNullOrWhiteSpace($modelChoice)) { continue }
                $number = 0
                if ([int]::TryParse($modelChoice, [ref]$number) -and $number -ge 1 -and $number -le $models.Count) {
                    $candidate.Model = $models[$number - 1]
                } else { $candidate.Model = $modelChoice.Trim() }
            }
            '4' {
                $defaults = New-UngateMemorySettings
                $candidate.Provider = $defaults.Provider
                $candidate.Model = $defaults.Model
            }
            default { continue }
        }
        $onlyDisabling = $choice.Trim() -eq '1' -and -not $candidate.Enabled
        if (-not $onlyDisabling -and -not (Invoke-UngateMemoryValidation -Context $Context -Settings $candidate).Valid) { continue }
        Write-UngateMemorySettings -Context $Context -Settings $candidate
        $settings = $candidate
        Write-Host '[memory] Settings saved.' -ForegroundColor Green
    }
}

function Set-UngateMemoryConfig {
    param([Parameter(Mandatory)][string]$Content, [bool]$Enabled = $false)
    $value = if ($Enabled) { 'true' } else { 'false' }
    $Content = Set-TomlTableValue -Content $Content -TableName 'features' -Key 'memories' -TomlValue $value
    foreach ($key in @('generate_memories', 'use_memories')) {
        $Content = Set-TomlTableValue -Content $Content -TableName 'memories' -Key $key -TomlValue $value
    }
    foreach ($key in @('extract_model', 'consolidation_model')) {
        $Content = Set-TomlTableValue -Content $Content -TableName 'memories' -Key $key -TomlValue '"ungate-memory"'
    }
    return $Content
}

Export-ModuleMember -Function @('New-UngateMemorySettings', 'Read-UngateMemorySettings', 'Write-UngateMemorySettings',
    'Get-UngateMemoryDefinition', 'Invoke-UngateMemoryValidation', 'Invoke-UngateMemoryMenu', 'Set-UngateMemoryConfig')
