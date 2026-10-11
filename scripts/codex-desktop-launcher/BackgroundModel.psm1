#requires -Version 7.4
# Background model preference; importing this module has no side effects.
# Codex Desktop sends chat titles, ambient suggestions, their safety check and codex-auto-review
# to the hard-coded model ID gpt-5.6-luna. The launcher routes that ID to the model chosen here.
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'LauncherLock.psm1') -DisableNameChecking -ErrorAction Stop

function Read-UngateBackgroundModelSetting {
    param([Parameter(Mandatory)][psobject]$Context)
    # $null means "the model selected for this launch".
    if (-not (Test-Path -LiteralPath $Context.BackgroundModelSettingsPath -PathType Leaf)) { return $null }
    try {
        $settings = Get-Content -LiteralPath $Context.BackgroundModelSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if ($settings.Version -ne 1) { throw 'unsupported version' }
        $slug = $settings.ModelSlug
        if ($null -eq $slug) { return $null }
        if ($slug -isnot [string] -or [string]::IsNullOrWhiteSpace($slug)) { throw 'invalid model slug' }
        return $slug.Trim()
    } catch {
        Write-Warning 'Background model settings could not be read. This launch uses the launch model for background tasks; the file is retained.'
        return $null
    }
}

function Write-UngateBackgroundModelSetting {
    param([Parameter(Mandatory)][psobject]$Context, [AllowNull()][string]$ModelSlug)
    $ErrorActionPreference = 'Stop'
    $value = if ([string]::IsNullOrWhiteSpace($ModelSlug)) { $null } else { $ModelSlug.Trim() }
    $path = [IO.Path]::GetFullPath($Context.BackgroundModelSettingsPath)
    $directory = [IO.Path]::GetDirectoryName($path)
    $lease = Enter-UngateProfileLock -HomePath $directory
    try {
        [void][IO.Directory]::CreateDirectory($directory)
        $transaction = [guid]::NewGuid().ToString('N')
        $temporary = Join-Path $directory ".background-model.$transaction.tmp"
        $backup = Join-Path $directory ".background-model.$transaction.bak"
        $record = [ordered]@{ Version = 1; ModelSlug = $value }
        [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json) + "`r`n", [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Replace($temporary, $path, $backup) }
        else { [IO.File]::Move($temporary, $path) }
    } finally {
        Exit-UngateProfileLock -Lease $lease
    }
}

function Find-UngateDefinitionBySlug {
    param([object[]]$Definitions, [Parameter(Mandatory)][string]$Slug)
    return $Definitions | Where-Object {
        $_.Slug -eq $Slug -or
        ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $Slug) -or
        ($_.PSObject.Properties['Aliases'] -and $_.Aliases -and $Slug -in $_.Aliases)
    } | Select-Object -First 1
}

# Returns a copy of the background model's definition routed through the background shell ID,
# with Source 'launch' or 'custom'. A saved model that no longer exists falls back to the launch model.
function Resolve-UngateBackgroundDefinition {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$LaunchDefinition,
        [object[]]$PickerDefinitions = @(),
        [object[]]$AllDefinitions = @(),
        [AllowNull()][string]$CustomModelSlug
    )
    $ErrorActionPreference = 'Stop'
    $source = 'launch'
    $definition = $LaunchDefinition
    if (-not [string]::IsNullOrWhiteSpace($CustomModelSlug)) {
        $custom = Find-UngateDefinitionBySlug -Definitions $PickerDefinitions -Slug $CustomModelSlug
        if (-not $custom) { $custom = Find-UngateDefinitionBySlug -Definitions $AllDefinitions -Slug $CustomModelSlug }
        if ($custom) {
            $definition = $custom
            $source = 'custom'
        } else {
            Write-Warning "Background model '$CustomModelSlug' is no longer configured. Background tasks use the launch model for this run."
        }
    }

    $properties = [ordered]@{}
    foreach ($property in $definition.PSObject.Properties) { $properties[$property.Name] = $property.Value }
    $properties['ShellSlug'] = $Context.CodexBackgroundShellSlug
    $properties['BackgroundSource'] = $source
    return [pscustomobject]$properties
}

function Invoke-UngateBackgroundModelMenu {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][object[]]$Definitions)
    $ErrorActionPreference = 'Stop'
    while ($true) {
        $current = Read-UngateBackgroundModelSetting -Context $Context
        $currentDefinition = if ($current) { Find-UngateDefinitionBySlug -Definitions $Definitions -Slug $current } else { $null }
        $currentLabel = if (-not $current) { 'модель запуска' } elseif ($currentDefinition) { $currentDefinition.DisplayName } else { "$current (не найдена)" }
        Write-Host ''
        Write-Host '--- Модель для фоновых задач Codex Desktop ---' -ForegroundColor Cyan
        Write-Host 'Desktop отправляет заголовки чатов, фоновые подсказки, их проверку и codex-auto-review'
        Write-Host 'на отдельную модель. По умолчанию это модель, выбранная при запуске.'
        Write-Host "Сейчас: $currentLabel" -ForegroundColor Yellow
        Write-Host '  0) Модель запуска (по умолчанию)'
        for ($index = 0; $index -lt $Definitions.Count; $index++) {
            Write-Host ("  {0}) {1}" -f ($index + 1), $Definitions[$index].DisplayName)
        }
        Write-Host '  B) Назад'
        $choice = Read-Host "Выберите [0-$($Definitions.Count) или B]"
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim() -eq 'b') { return }
        $number = 0
        if (-not [int]::TryParse($choice.Trim(), [ref]$number) -or $number -lt 0 -or $number -gt $Definitions.Count) {
            Write-Host "Неверный выбор. Введите 0-$($Definitions.Count) или B." -ForegroundColor Yellow
            continue
        }
        $slug = if ($number -eq 0) { $null } else { [string]$Definitions[$number - 1].Slug }
        Write-UngateBackgroundModelSetting -Context $Context -ModelSlug $slug
        $label = if ($slug) { $Definitions[$number - 1].DisplayName } else { 'модель запуска' }
        Write-Host "  [x] Фоновые задачи: $label. Применится при следующем запуске." -ForegroundColor Green
        return
    }
}

Export-ModuleMember -Function @(
    'Read-UngateBackgroundModelSetting',
    'Write-UngateBackgroundModelSetting',
    'Resolve-UngateBackgroundDefinition',
    'Invoke-UngateBackgroundModelMenu'
)
