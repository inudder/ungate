#requires -Version 7.4
# Picker: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop

function Get-DefaultUngatePickerModelSlugs {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )
    $ErrorActionPreference = 'Stop'

    return @(
        $Definitions |
            Select-Object -First $Capacity |
            ForEach-Object { [string]$_.Slug }
    )
}

function Read-UngatePickerModelSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return @(Get-DefaultUngatePickerModelSlugs -Definitions $Definitions -Capacity $Capacity)
    }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Desktop picker settings path is not a file: $SettingsPath"
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "Failed to parse Desktop picker settings at $SettingsPath : $($_.Exception.Message)"
    }

    if ('Version' -notin $settings.PSObject.Properties.Name -or [int]$settings.Version -ne 1) {
        throw "Desktop picker settings at $SettingsPath have an unsupported or missing version."
    }
    if ('ModelSlugs' -notin $settings.PSObject.Properties.Name) {
        throw "Desktop picker settings at $SettingsPath are missing the modelSlugs array."
    }

    $configuredSlugs = @($settings.ModelSlugs)
    if ($configuredSlugs.Count -eq 0) {
        throw 'Desktop picker must contain at least one model.'
    }
    if ($configuredSlugs.Count -gt $Capacity) {
        Write-Host (
            "[ungate] Warning: saved picker selection contains $($configuredSlugs.Count) models; only the first $Capacity valid models will be loaded. Open 'Configure Desktop model picker' to choose the final set."
        ) -ForegroundColor Yellow
    }

    $requestedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($configuredSlug in $configuredSlugs) {
        if ($configuredSlug -isnot [string] -or [string]::IsNullOrWhiteSpace($configuredSlug)) {
            throw 'Desktop picker modelSlugs entries must be non-empty strings.'
        }
        if (-not $requestedSlugs.Add($configuredSlug)) {
            throw "Desktop picker model '$configuredSlug' is duplicated."
        }
    }

    $knownSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($definition in $Definitions) {
        [void]$knownSlugs.Add([string]$definition.Slug)
    }

    $staleSlugs = @($configuredSlugs | Where-Object { -not $knownSlugs.Contains($_) })
    if ($staleSlugs.Count -gt 0) {
        Write-Host (
            "[ungate] Warning: picker models no longer configured and ignored: $($staleSlugs -join ', ')."
        ) -ForegroundColor Yellow
    }

    $resolvedSlugs = @(
        $Definitions |
            Where-Object { $requestedSlugs.Contains([string]$_.Slug) } |
            ForEach-Object { [string]$_.Slug }
    )
    if ($resolvedSlugs.Count -gt $Capacity) {
        $resolvedSlugs = @($resolvedSlugs | Select-Object -First $Capacity)
    }
    if ($resolvedSlugs.Count -gt 0) {
        return $resolvedSlugs
    }

    Write-Host '[ungate] Warning: no saved picker models remain; using the default selection.' -ForegroundColor Yellow
    return @(Get-DefaultUngatePickerModelSlugs -Definitions $Definitions -Capacity $Capacity)
}

function Write-UngatePickerModelSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [string[]]$ModelSlugs,
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )
    $ErrorActionPreference = 'Stop'

    if ($ModelSlugs.Count -eq 0) {
        throw 'Desktop picker must contain at least one model.'
    }
    if ($ModelSlugs.Count -gt $Capacity) {
        throw "Desktop picker can contain at most $Capacity models."
    }

    $requestedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($modelSlug in $ModelSlugs) {
        if ([string]::IsNullOrWhiteSpace($modelSlug)) {
            throw 'Desktop picker model IDs cannot be empty.'
        }
        if (-not $requestedSlugs.Add($modelSlug)) {
            throw "Desktop picker model '$modelSlug' is duplicated."
        }
    }

    $canonicalSlugs = @(
        $Definitions |
            Where-Object { $requestedSlugs.Contains([string]$_.Slug) } |
            ForEach-Object { [string]$_.Slug }
    )
    if ($canonicalSlugs.Count -ne $requestedSlugs.Count) {
        $knownSlugs = @($Definitions | ForEach-Object { [string]$_.Slug })
        $unknownSlugs = @($ModelSlugs | Where-Object { $_ -notin $knownSlugs })
        throw "Desktop picker contains unknown models: $($unknownSlugs -join ', ')."
    }

    $json = [ordered]@{
        version = 1
        modelSlugs = $canonicalSlugs
    } | ConvertTo-Json -Depth 10

    $absoluteSettingsPath = [System.IO.Path]::GetFullPath($SettingsPath)
    if (
        (Test-Path -LiteralPath $absoluteSettingsPath) -and
        -not (Test-Path -LiteralPath $absoluteSettingsPath -PathType Leaf)
    ) {
        throw "Desktop picker settings target is not a file: $absoluteSettingsPath"
    }

    $settingsDirectory = Split-Path -Parent $absoluteSettingsPath
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $settingsDirectory ".ungate-picker-models.$transactionId.tmp"
    $backupPath = Join-Path $settingsDirectory ".ungate-picker-models.$transactionId.bak"
    $writeCompleted = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json + "`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $absoluteSettingsPath -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $absoluteSettingsPath,
                $backupPath,
                $true
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $absoluteSettingsPath)
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

    return $absoluteSettingsPath
}

function Get-UngatePickerModelDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )
    $ErrorActionPreference = 'Stop'

    $selectedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($slug in @(
        Read-UngatePickerModelSelection `
            -SettingsPath $SettingsPath `
            -Definitions $Definitions `
            -Capacity $Capacity
    )) {
        [void]$selectedSlugs.Add($slug)
    }

    return @($Definitions | Where-Object { $selectedSlugs.Contains([string]$_.Slug) })
}

function Read-UngatePickerKey {
    $ErrorActionPreference = 'Stop'
    $keyInfo = [Console]::ReadKey($true)
    switch ($keyInfo.Key) {
        'UpArrow' { return 'up' }
        'DownArrow' { return 'down' }
        'Spacebar' { return 'toggle' }
        'Enter' { return 'save' }
        'Escape' { return 'cancel' }
        default { return 'none' }
    }
}

function Invoke-UngatePickerConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )
    $ErrorActionPreference = 'Stop'

    if ($Definitions.Count -eq 0) {
        throw 'No models are available for the Desktop picker.'
    }

    $selectedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($slug in @(
        Read-UngatePickerModelSelection `
            -SettingsPath $SettingsPath `
            -Definitions $Definitions `
            -Capacity $Capacity
    )) {
        [void]$selectedSlugs.Add($slug)
    }

    $cursorIndex = 0
    $statusMessage = $null
    while ($true) {
        Clear-Host
        Write-Host 'Configure Codex Desktop model picker:' -ForegroundColor Cyan
        Write-Host ''
        for ($index = 0; $index -lt $Definitions.Count; $index++) {
            $cursor = if ($index -eq $cursorIndex) { '>' } else { ' ' }
            $checked = if ($selectedSlugs.Contains([string]$Definitions[$index].Slug)) { 'x' } else { ' ' }
            $line = "  $cursor [$checked] $($Definitions[$index].DisplayName)"
            if ($index -eq $cursorIndex) {
                Write-Host $line -ForegroundColor Cyan
            }
            else {
                Write-Host $line
            }
        }
        Write-Host ''
        Write-Host "Selected: $($selectedSlugs.Count)/$Capacity"
        Write-Host 'Up/Down: move  Space: toggle  Enter: save  Esc: cancel' -ForegroundColor DarkGray
        if ($statusMessage) {
            Write-Host $statusMessage -ForegroundColor Yellow
        }

        $statusMessage = $null
        switch (Read-UngatePickerKey) {
            'up' {
                $cursorIndex = if ($cursorIndex -eq 0) { $Definitions.Count - 1 } else { $cursorIndex - 1 }
            }
            'down' {
                $cursorIndex = if ($cursorIndex -eq $Definitions.Count - 1) { 0 } else { $cursorIndex + 1 }
            }
            'toggle' {
                $slug = [string]$Definitions[$cursorIndex].Slug
                if ($selectedSlugs.Contains($slug)) {
                    [void]$selectedSlugs.Remove($slug)
                }
                elseif ($selectedSlugs.Count -ge $Capacity) {
                    $statusMessage = "Select at most $Capacity models. Disable one before adding another."
                }
                else {
                    [void]$selectedSlugs.Add($slug)
                }
            }
            'save' {
                if ($selectedSlugs.Count -eq 0) {
                    $statusMessage = 'Select at least one model.'
                    continue
                }

                $modelSlugs = @(
                    $Definitions |
                        Where-Object { $selectedSlugs.Contains([string]$_.Slug) } |
                        ForEach-Object { [string]$_.Slug }
                )
                $savedPath = Write-UngatePickerModelSelection `
                    -SettingsPath $SettingsPath `
                    -ModelSlugs $modelSlugs `
                    -Definitions $Definitions `
                    -Capacity $Capacity
                Write-Host "[ungate] Desktop picker selection saved: $savedPath" -ForegroundColor Green
                return $true
            }
            'cancel' {
                Write-Host '[ungate] Desktop picker selection unchanged.' -ForegroundColor Yellow
                return $false
            }
        }
    }
}

function Read-UngateMenuChoice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string[]]$Values,
        [Parameter(Mandatory = $true)]
        [int]$DefaultIndex
    )
    $ErrorActionPreference = 'Stop'

    while ($true) {
        $choice = Read-Host "$Prompt [1-$($Values.Count)] (default: $($DefaultIndex + 1))"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $Values[$DefaultIndex]
        }

        $selectedNumber = 0
        if (
            [int]::TryParse($choice, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $Values.Count
        ) {
            return $Values[$selectedNumber - 1]
        }

        Write-Host "Enter a number from 1 to $($Values.Count)." -ForegroundColor Yellow
    }
}

function Read-UngateYesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [bool]$Default = $true
    )
    $ErrorActionPreference = 'Stop'

    $defaultLabel = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $choice = Read-Host "$Prompt [$defaultLabel]"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $Default
        }
        $choice = $choice.Trim().ToLowerInvariant()
        if ($choice -in @('y', 'yes')) {
            return $true
        }
        if ($choice -in @('n', 'no')) {
            return $false
        }
        Write-Host 'Enter y or n.' -ForegroundColor Yellow
    }
}

function Invoke-AddUngateModelMode {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions
    )
    $ErrorActionPreference = 'Stop'

    $existingDefinitions = @(
        Read-UngateCustomModelDefinitions -Context $Context `
            -RegistryPath $RegistryPath `
            -BuiltInDefinitions $BuiltInDefinitions
    )

    Write-Host ''
    Write-Host 'Add a model to the Codex Beta launcher:' -ForegroundColor Cyan
    $slug = Read-Host 'Model ID (example: ungate-opus-5)'
    $displayName = Read-Host 'Label (example: Claude Opus 5 (Ungate))'
    $upstreamModel = Read-Host 'Upstream model ID (example: claude-opus-5)'

    Write-Host ''
    Write-Host 'Transport:'
    Write-Host '  1) Ungate Proxy'
    Write-Host '  2) CLIProxyAPI'
    Write-Host '  3) OmniRoute'
    $transport = Read-UngateMenuChoice `
        -Prompt 'Transport' `
        -Values @('ungate', 'cliproxyapi', 'omniroute') `
        -DefaultIndex 0

    Write-Host ''
    Write-Host 'Default reasoning level:'
    Write-Host '  1) low'
    Write-Host '  2) medium'
    Write-Host '  3) high'
    Write-Host '  4) xhigh'
    $reasoningLevel = Read-UngateMenuChoice `
        -Prompt 'Reasoning level' `
        -Values @('low', 'medium', 'high', 'xhigh') `
        -DefaultIndex 2
    $supportsImageInput = Read-UngateYesNo -Prompt 'Supports image input?' -Default $true

    $newRecord = [pscustomobject][ordered]@{
        Slug = $slug
        DisplayName = $displayName
        UpstreamModel = $upstreamModel
        Transport = $transport
        DefaultReasoningLevel = $reasoningLevel
        SupportsImageInput = $supportsImageInput
    }
    $candidate = ConvertTo-UngateModelDefinition -Context $Context `
        -Record $newRecord `
        -Priority ($BuiltInDefinitions.Count + $existingDefinitions.Count)
    $allSlugs = @($BuiltInDefinitions.Slug) + @($existingDefinitions.Slug)
    if ($candidate.Slug -in $allSlugs) {
        throw "Model ID '$($candidate.Slug)' already exists."
    }

    Write-Host ''
    Write-Host 'New model:' -ForegroundColor Cyan
    Write-Host "  Model ID:       $($candidate.Slug)"
    Write-Host "  Label:          $($candidate.DisplayName)"
    Write-Host "  Upstream Model: $($candidate.UpstreamModel)"
    Write-Host "  Transport:      $($candidate.ProviderDisplayName)"
    Write-Host "  Reasoning:      $($candidate.DefaultReasoningLevel)"
    Write-Host "  Image input:    $($candidate.SupportsImageInput)"
    Write-Host ''

    if (-not (Read-UngateYesNo -Prompt 'Save this model?' -Default $true)) {
        Write-Host '[ungate] Model addition cancelled.' -ForegroundColor Yellow
        return
    }

    $registryRecords = @($existingDefinitions) + @($newRecord)
    $savedPath = Write-UngateCustomModelDefinitions -Context $Context `
        -RegistryPath $RegistryPath `
        -Records $registryRecords `
        -BuiltInDefinitions $BuiltInDefinitions
    Write-Host "[ungate] Model '$($candidate.Slug)' added: $savedPath" -ForegroundColor Green
    Write-Host '[ungate] Run the launcher normally to select the new model.' -ForegroundColor Green
    return $candidate.Slug
}

function Select-UngateDesktopModel {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions,
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [string]$PickerSettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$PickerCapacity,
        [string]$LogSettingsPath,
        [switch]$IncludeProviderFallback,
        [string]$ProviderFallbackModel = 'codex-fallback'
    )
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($LogSettingsPath)) {
        $parentDir = Split-Path $PickerSettingsPath -Parent
        $LogSettingsPath = Join-Path $parentDir 'ungate-log-settings.json'
    }

    while ($true) {
        $pickerDefinitions = @(
            Get-UngatePickerModelDefinitions `
                -Definitions $Definitions `
                -SettingsPath $PickerSettingsPath `
                -Capacity $PickerCapacity
        )
        Write-Host ''
        Write-Host 'Select a mode for Codex Beta:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $pickerDefinitions.Count; $index++) {
            $defaultLabel = if ($index -eq 0) { ' (default)' } else { '' }
            $contextLabel = (Get-UngateModelContextWindow -Definition $pickerDefinitions[$index]).Label
            Write-Host ("  {0}) {1}{2}  [{3}]" -f ($index + 1), $pickerDefinitions[$index].DisplayName, $defaultLabel, $contextLabel)
        }
        $configurePickerIndex = $pickerDefinitions.Count + 1
        Write-Host ("  {0}) Configure Desktop model picker" -f $configurePickerIndex) -ForegroundColor DarkCyan
        $providerFallbackIndex = if ($IncludeProviderFallback) { $configurePickerIndex + 1 } else { $null }
        if ($IncludeProviderFallback) {
            Write-Host (
                "  {0}) [ ] Enable provider fallback (OmniRoute) — Claude → Grok → MiniMax → Gemini" -f
                    $providerFallbackIndex
            ) -ForegroundColor Yellow
        }
        $addModelIndex = $configurePickerIndex + $(if ($IncludeProviderFallback) { 2 } else { 1 })
        Write-Host ("  {0}) Add a new model" -f $addModelIndex) -ForegroundColor DarkCyan

        $currentLogLevel = (Read-UngateLogSettings -SettingsPath $LogSettingsPath).LogLevel
        $loggingMenuIndex = $addModelIndex + 1
        Write-Host ("  {0}) Configure live logging [Current: {1}]" -f $loggingMenuIndex, $currentLogLevel) -ForegroundColor DarkCyan
        Write-Host ''

        $fallbackHint = if ($IncludeProviderFallback) { ' or F' } else { '' }
        $choicePrompt = "Mode [1-$loggingMenuIndex$fallbackHint or L] (default: 1)"
        $choice = Read-Host $choicePrompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $pickerDefinitions[0].Slug
        }

        if ($IncludeProviderFallback -and $choice.Trim().Equals('f', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host '  [x] Provider fallback enabled.' -ForegroundColor Green
            return $ProviderFallbackModel
        }

        if ($choice.Trim().Equals('l', [System.StringComparison]::OrdinalIgnoreCase)) {
            $null = Invoke-UngateLoggingMenu -SettingsPath $LogSettingsPath
            continue
        }

        $selectedNumber = 0
        if (
            [int]::TryParse($choice, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $loggingMenuIndex
        ) {
            if ($selectedNumber -le $pickerDefinitions.Count) {
                return $pickerDefinitions[$selectedNumber - 1].Slug
            }

            if ($selectedNumber -eq $configurePickerIndex) {
                $null = Invoke-UngatePickerConfiguration `
                    -Definitions $Definitions `
                    -SettingsPath $PickerSettingsPath `
                    -Capacity $PickerCapacity
                continue
            }

            if ($IncludeProviderFallback -and $selectedNumber -eq $providerFallbackIndex) {
                Write-Host '  [x] Provider fallback enabled.' -ForegroundColor Green
                return $ProviderFallbackModel
            }

            if ($selectedNumber -eq $addModelIndex) {
                $addedModelSlug = Invoke-AddUngateModelMode -Context $Context `
                    -RegistryPath $RegistryPath `
                    -BuiltInDefinitions $BuiltInDefinitions
                if ($addedModelSlug) {
                    $Definitions = @(
                        Get-UngateModelDefinitions -Context $Context `
                            -BuiltInDefinitions $BuiltInDefinitions `
                            -RegistryPath $RegistryPath
                    )
                    $null = Invoke-UngatePickerConfiguration `
                        -Definitions $Definitions `
                        -SettingsPath $PickerSettingsPath `
                        -Capacity $PickerCapacity
                }
                continue
            }

            if ($selectedNumber -eq $loggingMenuIndex) {
                $null = Invoke-UngateLoggingMenu -SettingsPath $LogSettingsPath
                continue
            }
        }

        Write-Host "Enter a number from 1 to $loggingMenuIndex$fallbackHint or L." -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function @(
    'Invoke-AddUngateModelMode',
    'Read-UngatePickerModelSelection',
    'Write-UngatePickerModelSelection',
    'Get-UngatePickerModelDefinitions',
    'Invoke-UngatePickerConfiguration',
    'Select-UngateDesktopModel'
)
