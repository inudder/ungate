#requires -Version 7.4
# Picker: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Memories.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'BackgroundModel.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'LauncherLock.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Capabilities.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ToolCompatibility.psm1') -DisableNameChecking -ErrorAction Stop

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
    $lease = Enter-UngateProfileLock -HomePath (Split-Path -Parent ([System.IO.Path]::GetFullPath($SettingsPath)))
    try {

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
    }

        return $absoluteSettingsPath
    } finally {
        Exit-UngateProfileLock -Lease $lease
    }
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
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    $existingDefinitions = @(Get-UngateModelDefinitions -Context $Context -SkipOverrides)

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
    $supportsOriginal = $false
    if ($supportsImageInput) { $supportsOriginal = Read-UngateYesNo -Prompt 'Supports original image detail?' -Default $false }
    $contextInput = Read-Host 'Context window (e.g. 200k, 500k, 1M) [default: 200k]'

    $newRecord = [pscustomobject][ordered]@{
        Slug = $slug
        DisplayName = $displayName
        UpstreamModel = $upstreamModel
        Transport = $transport
        DefaultReasoningLevel = $reasoningLevel
        SupportsImageInput = $supportsImageInput
        SupportsImageDetailOriginal = $supportsOriginal
    }
    if (-not [string]::IsNullOrWhiteSpace($contextInput)) {
        $newRecord | Add-Member -NotePropertyName ContextWindow -NotePropertyValue $contextInput.Trim()
    }
    $candidate = ConvertTo-UngateModelDefinition -Context $Context `
        -Record $newRecord `
        -Priority $existingDefinitions.Count
    $allSlugs = @($existingDefinitions.Slug)
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
    $imageLabel = @($candidate.InputModalities) -contains 'image'
    Write-Host "  Image input:    $imageLabel"
    Write-Host "  Context window: $((Get-UngateModelContextWindow -Definition $candidate).Label)"
    Write-Host ''

    if (-not (Read-UngateYesNo -Prompt 'Save this model?' -Default $true)) {
        Write-Host '[ungate] Model addition cancelled.' -ForegroundColor Yellow
        return
    }

    $null = Add-UngateModelRegistryRecord -Context $Context -Record $newRecord
    Write-Host "[ungate] Model '$($candidate.Slug)' added to the model registry." -ForegroundColor Green
    Write-Host '[ungate] Run the launcher normally to select the new model.' -ForegroundColor Green
    return $candidate.Slug
}

function Invoke-UngateModelVersionConfiguration {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [string]$OverridesPath,
        [string]$TargetModelSlug,
        [string]$NewUpstreamModel
    )
    $ErrorActionPreference = 'Stop'

    if ($TargetModelSlug -and $NewUpstreamModel) {
        $targetDef = $Definitions | Where-Object {
            $_.Slug -eq $TargetModelSlug -or
            ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $TargetModelSlug) -or
            ($_.PSObject.Properties['Aliases'] -and $_.Aliases -and $TargetModelSlug -in $_.Aliases)
        } | Select-Object -First 1

        if (-not $targetDef) {
            throw "Target model '$TargetModelSlug' not found in known models."
        }

        if ($NewUpstreamModel.Trim().Equals('reset', [System.StringComparison]::OrdinalIgnoreCase) -or
            $NewUpstreamModel.Trim().Equals('default', [System.StringComparison]::OrdinalIgnoreCase)) {
            $saved = Remove-UngateModelOverride -OverridesPath $OverridesPath -Slug $targetDef.Slug -Fields @('upstreamModel', 'displayName', 'contextWindow')
            Write-Host "[ungate] Model '$($targetDef.DisplayName)' reset to default upstream: $saved" -ForegroundColor Green
            return $true
        }

        $newUpstream = $NewUpstreamModel.Trim()
        $override = [ordered]@{
            upstreamModel = $newUpstream
        }
        $saved = Set-UngateModelOverride -OverridesPath $OverridesPath -Slug $targetDef.Slug -Override $override
        Write-Host "[ungate] Model '$($targetDef.DisplayName)' upstream set to '$newUpstream': $saved" -ForegroundColor Green
        return $true
    }

    Write-Host ''
    Write-Host 'Change model version / upstream slug:' -ForegroundColor Cyan
    Write-Host 'The upstream model ID is sent directly to the provider (e.g. CLIProxyAPI).' -ForegroundColor DarkGray
    Write-Host ''

    for ($i = 0; $i -lt $Definitions.Count; $i++) {
        $def = $Definitions[$i]
        $upstreamDisplay = if ($def.PSObject.Properties['UpstreamModel'] -and $def.UpstreamModel) {
            $def.UpstreamModel
        } else {
            '(auto)'
        }
        $overrideTag = if ($def.PSObject.Properties['IsOverridden'] -and $def.IsOverridden) {
            " [OVERRIDDEN, default: $($def.DefaultUpstreamModel)]"
        } else {
            ''
        }
        $contextLabel = (Get-UngateModelContextWindow -Definition $def).Label
        Write-Host ("  {0,2}) {1}  [{2}] (upstream: {3}){4}" -f ($i + 1), $def.DisplayName, $contextLabel, $upstreamDisplay, $overrideTag)
    }
    Write-Host '   B) Back to main menu' -ForegroundColor DarkGray
    Write-Host ''

    $choice = Read-Host "Select a model [1-$($Definitions.Count) or B] (default: B)"
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $idx = 0
    if (-not [int]::TryParse($choice.Trim(), [ref]$idx) -or $idx -lt 1 -or $idx -gt $Definitions.Count) {
        Write-Host 'Invalid model selection.' -ForegroundColor Yellow
        return $false
    }

    $selectedDef = $Definitions[$idx - 1]
    $currentUpstream = if ($selectedDef.PSObject.Properties['UpstreamModel'] -and $selectedDef.UpstreamModel) {
        $selectedDef.UpstreamModel
    } else {
        $selectedDef.Slug
    }

    Write-Host ''
    Write-Host "Selected model: $($selectedDef.DisplayName) [$currentUpstream]" -ForegroundColor Cyan
    Write-Host "Provider:       $($selectedDef.ProviderDisplayName) ($($selectedDef.ProxyBaseUrl))" -ForegroundColor DarkGray

    if ($selectedDef.ProviderName -eq $Context.CliProxyProviderName -or $selectedDef.ProviderDisplayName -eq 'CLIProxyAPI') {
        $filter = if ($selectedDef.Slug -match '(?i)grok') { 'grok' } else { '' }
        try {
            $proxyUrl = $selectedDef.ProxyBaseUrl
            $disc = Invoke-RestMethod -Uri "$proxyUrl/v1/models" -TimeoutSec 2 -ErrorAction Stop
            $foundModels = @($disc.data | ForEach-Object { [string]$_.id } | Where-Object { if ($filter) { $_ -like "*$filter*" } else { $true } })
            if ($foundModels.Count -gt 0) {
                Write-Host 'Discovered in CLIProxyAPI (/v1/models):' -ForegroundColor Green
                foreach ($m in $foundModels) {
                    Write-Host "  - $m" -ForegroundColor DarkGreen
                }
            }
        }
        catch {
            try {
                $disc = Invoke-RestMethod -Uri "http://127.0.0.1:8317/v1/models" -TimeoutSec 2 -ErrorAction Stop
                $foundModels = @($disc.data | ForEach-Object { [string]$_.id } | Where-Object { if ($filter) { $_ -like "*$filter*" } else { $true } })
                if ($foundModels.Count -gt 0) {
                    Write-Host 'Discovered in CLIProxyAPI (/v1/models):' -ForegroundColor Green
                    foreach ($m in $foundModels) {
                        Write-Host "  - $m" -ForegroundColor DarkGreen
                    }
                }
            }
            catch {}
        }
    }
    elseif ($selectedDef.ProviderName -eq $Context.OmniRouteProviderName -or $selectedDef.ProviderDisplayName -eq 'OmniRoute') {
        $filter = if ($selectedDef.Slug -match '(?i)mimo') { 'mimo' }
                  elseif ($selectedDef.Slug -match '(?i)deepseek') { 'deepseek' }
                  elseif ($selectedDef.Slug -match '(?i)kimi') { 'kimi' }
                  elseif ($selectedDef.Slug -match '(?i)grok') { 'grok' }
                  elseif ($selectedDef.Slug -match '(?i)opus') { 'opus' }
                  else { '' }
        try {
            $key = $env:OMNIROUTE_CODEX_API_KEY
            if (-not $key) { $key = $env:OMNIROUTE_API_KEY }
            $headers = if ($key) { @{ Authorization = "Bearer $key" } } else { @{} }
            $proxyUrl = $selectedDef.ProxyBaseUrl
            $disc = Invoke-RestMethod -Uri "$proxyUrl/v1/models" -Headers $headers -TimeoutSec 2 -ErrorAction Stop
            $foundModels = @($disc.data | ForEach-Object { [string]$_.id } | Where-Object { if ($filter) { $_ -like "*$filter*" } else { $true } })
            if ($foundModels.Count -gt 0) {
                Write-Host 'Discovered in OmniRoute (/v1/models):' -ForegroundColor Green
                foreach ($m in $foundModels) {
                    Write-Host "  - $m" -ForegroundColor DarkGreen
                }
            }
        }
        catch {}
    }

    Write-Host ''
    $resetHint = if ($selectedDef.PSObject.Properties['IsOverridden'] -and $selectedDef.IsOverridden) {
        " (or type 'reset' to revert to '$($selectedDef.DefaultUpstreamModel)')"
    } else {
        ''
    }
    $newUpstreamInput = Read-Host "New upstream model ID$resetHint [current: $currentUpstream]"

    if ([string]::IsNullOrWhiteSpace($newUpstreamInput)) {
        Write-Host '[ungate] Model version unchanged.' -ForegroundColor Yellow
        return $false
    }

    if ($newUpstreamInput.Trim().Equals('reset', [System.StringComparison]::OrdinalIgnoreCase) -or
        $newUpstreamInput.Trim().Equals('default', [System.StringComparison]::OrdinalIgnoreCase)) {
        $saved = Remove-UngateModelOverride -OverridesPath $OverridesPath -Slug $selectedDef.Slug -Fields @('upstreamModel', 'displayName', 'contextWindow')
        Write-Host "[ungate] Model '$($selectedDef.DisplayName)' reset to default: $saved" -ForegroundColor Green
        return $true
    }

    $newUpstream = $newUpstreamInput.Trim()
    if ($newUpstream -match '\s|[\"'']') {
        throw "Upstream model ID '$newUpstream' cannot contain whitespace or quotes."
    }

    $suggestedName = $selectedDef.DisplayName
    if ($selectedDef.DisplayName -match '(?i)grok\s*[\d.]+') {
        $newVer = if ($newUpstream -match '[\d.]+') { $Matches[0] } else { '' }
        if ($newVer) {
            $suggestedName = $selectedDef.DisplayName -replace '(?i)grok\s*[\d.]+', "Grok $newVer"
        }
    }
    $newDisplayNameInput = Read-Host "Display label [default: $suggestedName]"
    $newDisplayName = if ([string]::IsNullOrWhiteSpace($newDisplayNameInput)) { $suggestedName } else { $newDisplayNameInput.Trim() }

    $currentCtx = (Get-UngateModelContextWindow -Definition $selectedDef).Label
    $newCtxInput = Read-Host "Context window (e.g. 500k, 1M, 200k) [default: $currentCtx]"
    $newContextWindow = $null
    if (-not [string]::IsNullOrWhiteSpace($newCtxInput)) {
        $newContextWindow = ConvertTo-ContextWindowTokens -Value $newCtxInput
    }

    Write-Host ''
    Write-Host 'New model override configuration:' -ForegroundColor Cyan
    Write-Host "  Model target:   $($selectedDef.DisplayName) [$($selectedDef.Slug)]"
    Write-Host "  Upstream ID:    $newUpstream"
    Write-Host "  Display label:  $newDisplayName"
    if ($null -ne $newContextWindow) {
        Write-Host "  Context window: $newCtxInput ($newContextWindow tokens)"
    }
    Write-Host ''

    if (-not (Read-UngateYesNo -Prompt 'Save this override?' -Default $true)) {
        Write-Host '[ungate] Cancelled.' -ForegroundColor Yellow
        return $false
    }

    $overrideRecord = [ordered]@{
        upstreamModel = $newUpstream
        displayName = $newDisplayName
    }
    if ($null -ne $newContextWindow) {
        $overrideRecord['contextWindow'] = $newContextWindow
    }

    $saved = Set-UngateModelOverride -OverridesPath $OverridesPath -Slug $selectedDef.Slug -Override $overrideRecord
    Write-Host "[ungate] Model override saved: $saved" -ForegroundColor Green
    return $true
}

# Removes any model from the registry, its overrides, the Desktop picker and the background setting.
function Remove-UngateProfileModel {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory = $true)][string]$Slug
    )
    $ErrorActionPreference = 'Stop'

    $lease = Enter-UngateProfileLock -HomePath $Context.CustomCodexHome
    try {
        if ($Slug -eq 'ungate-memory') { throw 'ungate-memory is a service alias, not a launcher model.' }
        $current = @(Get-UngateModelDefinitions -Context $Context -SkipOverrides)
        $target = $current | Where-Object { [string]$_.Slug -eq $Slug } | Select-Object -First 1
        if (-not $target) { throw "Model '$Slug' is not configured." }
        $removedSlug = [string]$target.Slug

        [void](Remove-UngateRegistryRecord -Context $Context -Slug $removedSlug)
        if (Test-Path -LiteralPath $Context.CustomModelOverridesPath -PathType Leaf) {
            [void](Remove-UngateModelOverride -OverridesPath $Context.CustomModelOverridesPath -Slug $removedSlug)
        }

        if (Test-Path -LiteralPath $Context.PickerModelSelectionPath -PathType Leaf) {
            $picker = $null
            try { $picker = Get-Content -LiteralPath $Context.PickerModelSelectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
            catch { $picker = $null }
            # A corrupt picker file is left for its own error; only a readable selection is rewritten.
            if ($picker -and 'ModelSlugs' -in $picker.PSObject.Properties.Name -and @($picker.ModelSlugs) -contains $removedSlug) {
                $selected = @($picker.ModelSlugs)
                $after = @(Get-UngateModelDefinitions -Context $Context -OverridesPath $Context.CustomModelOverridesPath)
                $kept = @($after | Where-Object { [string]$_.Slug -in $selected } | ForEach-Object { [string]$_.Slug } |
                    Select-Object -First $Context.CodexDesktopPickerCapacity)
                if ($kept.Count -eq 0) {
                    Remove-Item -LiteralPath $Context.PickerModelSelectionPath -Force
                }
                else {
                    [void](Write-UngatePickerModelSelection -SettingsPath $Context.PickerModelSelectionPath -ModelSlugs $kept -Definitions $after -Capacity $Context.CodexDesktopPickerCapacity)
                }
            }
        }

        $background = Read-UngateBackgroundModelSetting -Context $Context
        if ($background -and $background -eq $removedSlug) {
            Write-UngateBackgroundModelSetting -Context $Context -ModelSlug $null
        }

        return [pscustomobject]@{
            Slug = $removedSlug
            DisplayName = [string]$target.DisplayName
            Action = 'deleted'
        }
    } finally {
        Exit-UngateProfileLock -Lease $lease
    }
}

function Invoke-UngateModelRemovalMenu {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    while ($true) {
        $definitions = @(Get-UngateModelDefinitions -Context $Context)
        $templateDefinitions = @(Get-UngateTemplateModelDefinitions -Context $Context)
        $templateSlugs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($templateDefinition in $templateDefinitions) { [void]$templateSlugs.Add([string]$templateDefinition.Slug) }
        $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($definition in $definitions) { [void]$present.Add([string]$definition.Slug) }
        $available = @($templateDefinitions | Where-Object { -not $present.Contains([string]$_.Slug) })

        Write-Host ''
        Write-Host 'Удаление моделей из launcher:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $definitions.Count; $index++) {
            $kind = if ($templateSlugs.Contains([string]$definitions[$index].Slug)) { 'из шаблона' } else { 'своя' }
            Write-Host ("  {0,2}) {1}  [{2}]" -f ($index + 1), $definitions[$index].DisplayName, $kind)
        }
        if ($available.Count -gt 0) {
            Write-Host 'Добавить из шаблонов:' -ForegroundColor DarkGray
            for ($index = 0; $index -lt $available.Count; $index++) {
                Write-Host ("  {0,2}) {1}" -f ($definitions.Count + $index + 1), $available[$index].DisplayName)
            }
        }
        Write-Host '   B) Назад' -ForegroundColor DarkGray
        $total = $definitions.Count + $available.Count
        if ($total -eq 0) {
            $null = Read-Host 'Нажмите Enter для возврата'
            return $false
        }
        $choice = Read-Host "Номер [1-$total или B] (по умолчанию: B)"
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        $number = 0
        if (-not [int]::TryParse($choice.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $total) {
            Write-Host "Введите число от 1 до $total или B." -ForegroundColor Yellow
            continue
        }

        try {
            if ($number -le $definitions.Count) {
                $target = $definitions[$number - 1]
                $prompt = if ($templateSlugs.Contains([string]$target.Slug)) {
                    "Удалить '$($target.DisplayName)'? Модель можно вернуть из шаблонов. Вернётся запись шаблона, не текущие правки."
                } else {
                    "Удалить '$($target.DisplayName)'? Свою модель после удаления придётся ввести заново."
                }
                if (-not (Read-UngateYesNo -Prompt $prompt -Default $false)) {
                    Write-Host '[ungate] Без изменений.' -ForegroundColor Yellow
                    continue
                }
                $result = Remove-UngateProfileModel -Context $Context -Slug ([string]$target.Slug)
                Write-Host "[ungate] Модель '$($result.DisplayName)' удалена из реестра и убрана из picker." -ForegroundColor Green
            }
            else {
                $entry = $available[$number - $definitions.Count - 1]
                $restoredSlug = Copy-UngateTemplateModelToRegistry -Context $Context -Slug ([string]$entry.Slug)
                Write-Host "[ungate] Модель '$($entry.DisplayName)' ($restoredSlug) возвращена из шаблона. Включите её в picker вручную." -ForegroundColor Green
            }
            return $true
        }
        catch {
            Write-Host "[ungate] $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Select-UngateDesktopModel {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [string]$PickerSettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$PickerCapacity,
        [string]$LogSettingsPath,
        [string]$OverridesPath,
        [switch]$IncludeProviderFallback,
        [string]$ProviderFallbackModel = 'codex-fallback'
    )
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($LogSettingsPath)) {
        $parentDir = Split-Path $PickerSettingsPath -Parent
        $LogSettingsPath = Join-Path $parentDir 'ungate-log-settings.json'
    }

    if ([string]::IsNullOrWhiteSpace($OverridesPath) -and $Context.PSObject.Properties['CustomModelOverridesPath']) {
        $OverridesPath = $Context.CustomModelOverridesPath
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

        $changeVersionIndex = $addModelIndex + 1
        Write-Host ("  {0}) Change model version (upstream slug)" -f $changeVersionIndex) -ForegroundColor DarkCyan

        $currentLogLevel = (Read-UngateLogSettings -SettingsPath $LogSettingsPath).LogLevel
        $loggingMenuIndex = $changeVersionIndex + 1
        Write-Host ("  {0}) Configure live logging [Current: {1}]" -f $loggingMenuIndex, $currentLogLevel) -ForegroundColor DarkCyan
        $memoryMenuIndex = $loggingMenuIndex + 1
        $memorySettings = Read-UngateMemorySettings -Context $Context
        $memoryState = if ($memorySettings.Enabled) { 'On' } else { 'Off' }
        Write-Host ("  {0}) Настройки памяти [Current: {1}; {2} / {3}]" -f $memoryMenuIndex, $memoryState, $memorySettings.Provider, $memorySettings.Model) -ForegroundColor DarkCyan
        Write-Host '  [TT] Тестирование совместимости инструментов (чекбоксы)' -ForegroundColor Yellow
        $capabilitiesMenuIndex = $memoryMenuIndex + 1
        Write-Host ("  {0}) Возможности моделей [C]" -f $capabilitiesMenuIndex) -ForegroundColor DarkCyan
        $backgroundSlug = Read-UngateBackgroundModelSetting -Context $Context
        $backgroundLabel = if (-not $backgroundSlug) {
            'модель запуска'
        } else {
            $backgroundModel = $Definitions | Where-Object { $_.Slug -eq $backgroundSlug } | Select-Object -First 1
            if ($backgroundModel) { $backgroundModel.DisplayName } else { "$backgroundSlug (не найдена)" }
        }
        Write-Host "  [B] Фоновые задачи Desktop (заголовки, подсказки, auto-review) [Current: $backgroundLabel]" -ForegroundColor DarkCyan
        Write-Host '  [R] Удалить модель из launcher и picker' -ForegroundColor DarkCyan
        Write-Host ''

        $fallbackHint = if ($IncludeProviderFallback) { ' or F' } else { '' }
        $choicePrompt = "Mode [1-$capabilitiesMenuIndex$fallbackHint or V or L or M or TT or C or B or R] (default: 1)"
        $choice = Read-Host $choicePrompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $pickerDefinitions[0].Slug
        }

        if ($choice.Trim() -match '^(tt|tools|compat|testtools)$') {
            $null = Invoke-CodexToolCompatibility -Context $Context -Definitions $Definitions
            $null = Read-Host 'Нажмите Enter для возврата в меню'
            continue
        }
        if ($choice.Trim() -match '^(c|capabilities)$' -or $choice.Trim() -eq [string]$capabilitiesMenuIndex) {
            $changed = Invoke-UngateCapabilitiesMenu -Context $Context -Definitions $Definitions
            if ($changed) {
                $Definitions = @(Get-UngateModelDefinitions -Context $Context -OverridesPath $OverridesPath)
            }
            continue
        }

        if ($choice.Trim() -match '^(v|ver|version)$') {
            $changed = Invoke-UngateModelVersionConfiguration `
                -Context $Context `
                -Definitions $Definitions `
                -OverridesPath $OverridesPath
            if ($changed) {
                $Definitions = @(
                    Get-UngateModelDefinitions -Context $Context -OverridesPath $OverridesPath
                )
            }
            continue
        }

        if ($IncludeProviderFallback -and $choice.Trim().Equals('f', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host '  [x] Provider fallback enabled.' -ForegroundColor Green
            return $ProviderFallbackModel
        }

        if ($choice.Trim().Equals('l', [System.StringComparison]::OrdinalIgnoreCase)) {
            $null = Invoke-UngateLoggingMenu -SettingsPath $LogSettingsPath
            continue
        }

        if ($choice.Trim().Equals('m', [System.StringComparison]::OrdinalIgnoreCase)) {
            Invoke-UngateMemoryMenu -Context $Context
            continue
        }

        if ($choice.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            Invoke-UngateBackgroundModelMenu -Context $Context -Definitions $Definitions
            continue
        }

        if ($choice.Trim().Equals('r', [System.StringComparison]::OrdinalIgnoreCase)) {
            if (Invoke-UngateModelRemovalMenu -Context $Context) {
                $Definitions = @(
                    Get-UngateModelDefinitions -Context $Context -OverridesPath $OverridesPath
                )
            }
            continue
        }

        $selectedNumber = 0
        if (
            [int]::TryParse($choice, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $memoryMenuIndex
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
                $addedModelSlug = Invoke-AddUngateModelMode -Context $Context
                if ($addedModelSlug) {
                    $Definitions = @(
                        Get-UngateModelDefinitions -Context $Context -OverridesPath $OverridesPath
                    )
                    $null = Invoke-UngatePickerConfiguration `
                        -Definitions $Definitions `
                        -SettingsPath $PickerSettingsPath `
                        -Capacity $PickerCapacity
                }
                continue
            }

            if ($selectedNumber -eq $changeVersionIndex) {
                $changed = Invoke-UngateModelVersionConfiguration `
                    -Context $Context `
                    -Definitions $Definitions `
                    -OverridesPath $OverridesPath
                if ($changed) {
                    $Definitions = @(
                        Get-UngateModelDefinitions -Context $Context -OverridesPath $OverridesPath
                    )
                }
                continue
            }

            if ($selectedNumber -eq $loggingMenuIndex) {
                $null = Invoke-UngateLoggingMenu -SettingsPath $LogSettingsPath
                continue
            }
            if ($selectedNumber -eq $memoryMenuIndex) {
                Invoke-UngateMemoryMenu -Context $Context
                continue
            }
        }

        Write-Host "Enter a number from 1 to $capabilitiesMenuIndex$fallbackHint or V or L or M or TT or C or B or R." -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function @(
    'Get-DefaultUngatePickerModelSlugs',
    'Invoke-AddUngateModelMode',
    'Invoke-UngateModelVersionConfiguration',
    'Read-UngatePickerModelSelection',
    'Write-UngatePickerModelSelection',
    'Get-UngatePickerModelDefinitions',
    'Invoke-UngatePickerConfiguration',
    'Remove-UngateProfileModel',
    'Invoke-UngateModelRemovalMenu',
    'Select-UngateDesktopModel'
)
