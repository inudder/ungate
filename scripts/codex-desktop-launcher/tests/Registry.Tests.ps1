BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'Models', 'Picker', 'BackgroundModel')) {
        Import-Module (Join-Path $moduleRoot "$name.psm1") -DisableNameChecking -ErrorAction Stop
    }

    function New-RegistryContext {
        $registryHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $registryHome | Out-Null
        New-CodexDesktopLaunchContext -CustomCodexHome $registryHome
    }

    function Write-RegistryJson {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
        [System.IO.File]::WriteAllText($Path, $Json.Trim() + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }
}

Describe 'Model template contract' {
    It 'loads ten unique template models in file order' {
        $context = New-RegistryContext
        $definitions = @(Get-UngateTemplateModelDefinitions -Context $context)
        $definitions | Should -HaveCount 10
        @($definitions.Slug | Select-Object -Unique) | Should -HaveCount 10
        for ($index = 0; $index -lt $definitions.Count; $index++) {
            $definitions[$index].Priority | Should -Be $index
        }

        $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'models.default.json'
        $template = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        foreach ($model in @($template.models)) {
            $model.transport | Should -BeIn @('ungate', 'cliproxyapi', 'omniroute')
        }
        $mini = @($template.models) | Where-Object slug -eq 'miniMax-M3'
        $null -eq $mini.upstreamModel | Should -BeTrue
    }

    It 'allows a null upstream model only for the ungate transport' {
        $context = New-RegistryContext
        $definition = ConvertTo-UngateModelDefinition -Context $context -Priority 0 -Record ([pscustomobject]@{
            Slug = 'local-ungate'
            DisplayName = 'Local Ungate'
            UpstreamModel = $null
            Transport = 'ungate'
            DefaultReasoningLevel = 'high'
            SupportsImageInput = $false
        })
        $null -eq $definition.UpstreamModel | Should -BeTrue
        $definition.Description | Should -BeExactly 'Local Ungate maps through the local Ungate Responses proxy.'

        foreach ($transport in @('cliproxyapi', 'omniroute')) {
            {
                ConvertTo-UngateModelDefinition -Context $context -Priority 0 -Record ([pscustomobject]@{
                    Slug = 'bad-upstream'
                    DisplayName = 'Bad'
                    UpstreamModel = $null
                    Transport = $transport
                    DefaultReasoningLevel = 'medium'
                    SupportsImageInput = $false
                })
            } | Should -Throw '*must have an upstream model ID*'
        }
    }
}

Describe 'Model registry migration' {
    It 'creates the template registry once and does not rewrite it' {
        $context = New-RegistryContext
        $templateSlugs = @((Get-UngateTemplateModelDefinitions -Context $context).Slug)

        Initialize-UngateModelRegistry -Context $context | Should -BeTrue
        $definitions = @(Get-UngateModelDefinitions -Context $context)
        @($definitions.Slug) | Should -Be $templateSlugs
        $registry = Get-Content -LiteralPath $context.ModelRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $registry.notice | Should -Match 'Created the model registry'

        $written = (Get-Item -LiteralPath $context.ModelRegistryPath).LastWriteTimeUtc
        $hash = (Get-FileHash -LiteralPath $context.ModelRegistryPath -Algorithm SHA256).Hash
        Start-Sleep -Milliseconds 30
        Initialize-UngateModelRegistry -Context $context | Should -BeFalse
        (Get-Item -LiteralPath $context.ModelRegistryPath).LastWriteTimeUtc | Should -Be $written
        (Get-FileHash -LiteralPath $context.ModelRegistryPath -Algorithm SHA256).Hash | Should -BeExactly $hash
    }

    It 'skips hidden legacy slugs and leaves the hidden file unchanged' {
        $context = New-RegistryContext
        $hiddenPath = Join-Path $context.CustomCodexHome 'ungate-hidden-models.json'
        Write-RegistryJson -Path $hiddenPath -Json '{ "version": 1, "modelSlugs": ["grok-4.7"] }'
        $before = (Get-FileHash -LiteralPath $hiddenPath -Algorithm SHA256).Hash

        Initialize-UngateModelRegistry -Context $context | Should -BeTrue
        @((Get-UngateModelRegistryRecords -Context $context).slug) | Should -Not -Contain 'grok-4.7'
        @(Get-UngateModelRegistryRecords -Context $context) | Should -HaveCount 9
        (Get-FileHash -LiteralPath $hiddenPath -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It 'appends a legacy custom model and leaves the legacy file unchanged' {
        $context = New-RegistryContext
        $legacyPath = Join-Path $context.CustomCodexHome 'ungate-model-definitions.json'
        Write-RegistryJson -Path $legacyPath -Json '{ "version": 1, "models": [{ "slug": "custom-legacy", "displayName": "Custom Legacy", "upstreamModel": "custom-legacy-upstream", "transport": "ungate", "defaultReasoningLevel": "high", "supportsImageInput": false }] }'
        $before = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash

        Initialize-UngateModelRegistry -Context $context | Should -BeTrue
        $records = @(Get-UngateModelRegistryRecords -Context $context)
        $records | Should -HaveCount 11
        $records[-1].slug | Should -BeExactly 'custom-legacy'
        $records[-1].upstreamModel | Should -BeExactly 'custom-legacy-upstream'
        (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It 'does not create a registry when the legacy file is corrupt' {
        $context = New-RegistryContext
        $legacyPath = Join-Path $context.CustomCodexHome 'ungate-model-definitions.json'
        Write-RegistryJson -Path $legacyPath -Json '{'
        $before = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash

        { Initialize-UngateModelRegistry -Context $context } | Should -Throw '*Failed to parse*'
        Test-Path -LiteralPath $context.ModelRegistryPath | Should -BeFalse
        (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It 'does not create a registry when a legacy model duplicates a template slug' {
        $context = New-RegistryContext
        $legacyPath = Join-Path $context.CustomCodexHome 'ungate-model-definitions.json'
        Write-RegistryJson -Path $legacyPath -Json '{ "version": 1, "models": [{ "slug": "ungate-opus-4-8", "displayName": "Duplicate", "upstreamModel": "claude-opus-4-8", "transport": "ungate", "defaultReasoningLevel": "high", "supportsImageInput": true }] }'

        { Initialize-UngateModelRegistry -Context $context } | Should -Throw '*duplicated*'
        Test-Path -LiteralPath $context.ModelRegistryPath | Should -BeFalse
        Test-Path -LiteralPath $legacyPath -PathType Leaf | Should -BeTrue
    }
}

Describe 'Model registry removal and template copy' {
    It 'removes a model from the registry, overrides, picker and background setting' {
        $context = New-RegistryContext
        Initialize-UngateModelRegistry -Context $context | Should -BeTrue
        $definitions = @(Get-UngateModelDefinitions -Context $context)
        Write-UngatePickerModelSelection -SettingsPath $context.PickerModelSelectionPath -ModelSlugs @('grok-4.7', 'miniMax-M3') -Definitions $definitions -Capacity 7
        Set-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug 'grok-4.7' -Override @{ displayName = 'Renamed Grok' }
        Write-UngateBackgroundModelSetting -Context $context -ModelSlug 'grok-4.7'

        $removed = Remove-UngateProfileModel -Context $context -Slug 'grok-4.7'
        $removed.Slug | Should -BeExactly 'grok-4.7'
        $removed.Action | Should -BeExactly 'deleted'

        @((Get-UngateModelDefinitions -Context $context).Slug) | Should -Not -Contain 'grok-4.7'
        $picker = Get-Content -LiteralPath $context.PickerModelSelectionPath -Raw -Encoding utf8 | ConvertFrom-Json
        @($picker.modelSlugs) | Should -Be @('miniMax-M3')
        Test-Path -LiteralPath $context.CustomModelOverridesPath | Should -BeFalse
        Read-UngateBackgroundModelSetting -Context $context | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $context.BackgroundModelSettingsPath -Raw -Encoding utf8) | Should -Not -Match 'grok-4.7'

        Initialize-UngateModelRegistry -Context $context | Should -BeFalse
        @((Get-UngateModelRegistryRecords -Context $context).slug) | Should -Not -Contain 'grok-4.7'
    }

    It 'refuses to remove the last model or the memory alias' {
        $context = New-RegistryContext
        $record = [pscustomobject]@{
            slug = 'only-model'
            displayName = 'Only model'
            upstreamModel = 'only-upstream'
            transport = 'ungate'
            defaultReasoningLevel = 'high'
            supportsImageInput = $false
        }
        Write-UngateModelRegistry -Context $context -Records @($record)

        { Remove-UngateRegistryRecord -Context $context -Slug 'only-model' } | Should -Throw '*last model*'
        { Remove-UngateProfileModel -Context $context -Slug 'ungate-memory' } | Should -Throw '*ungate-memory*'
        @(Get-UngateModelRegistryRecords -Context $context) | Should -HaveCount 1
    }

    It 'copies a removed template model and rejects a taken or unknown slug' {
        $context = New-RegistryContext
        Initialize-UngateModelRegistry -Context $context | Should -BeTrue
        Remove-UngateRegistryRecord -Context $context -Slug 'grok-4.7' | Should -BeExactly 'grok-4.7'
        $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'models.default.json'
        $templateModel = @((Get-Content -LiteralPath $templatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20).models) | Where-Object slug -eq 'grok-4.7'

        Copy-UngateTemplateModelToRegistry -Context $context -Slug 'grok-4.7' | Should -BeExactly 'grok-4.7'
        $copied = @(Get-UngateModelRegistryRecords -Context $context)[-1]
        $copied.slug | Should -BeExactly 'grok-4.7'
        $copied.displayName | Should -BeExactly $templateModel.displayName
        $copied.upstreamModel | Should -BeExactly $templateModel.upstreamModel
        { Copy-UngateTemplateModelToRegistry -Context $context -Slug 'grok-4.7' } | Should -Throw '*already exists*'
        { Copy-UngateTemplateModelToRegistry -Context $context -Slug 'not-in-template' } | Should -Throw '*not in the template*'
    }
}

