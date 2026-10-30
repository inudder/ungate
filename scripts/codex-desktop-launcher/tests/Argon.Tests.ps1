BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'Models', 'Catalog')) {
        Import-Module (Join-Path $moduleRoot "$name.psm1") -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'Per-model auto compaction' {
    It 'keeps Argon at 1M with default compaction unless an explicit threshold is configured' {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive 'argon-home')
        $definition = Get-UngateTemplateModelDefinitions -Context $context |
            Where-Object Slug -EQ 'apikey-fan/gemini-4-argon'
        $definition.ContextWindow | Should -Be 1000000
        $definition.AutoCompactTokenLimit | Should -BeNullOrEmpty
        $template = [pscustomobject]@{
            slug = 'fixture'
            base_instructions = "Original identity`nKeep these instructions."
        }
        $catalog = New-UngateCatalogModelInfo -Definition $definition -CatalogSlug 'fixture' `
            -DefaultCatalog ([pscustomobject]@{ models = @($template) }) -FallbackModelTemplate $template
        $catalog.context_window | Should -Be 1000000
        $catalog.max_context_window | Should -Be 1000000
        $catalog.auto_compact_token_limit | Should -BeNullOrEmpty
        $definition.AutoCompactTokenLimit = 100000
        $configuredCatalog = New-UngateCatalogModelInfo -Definition $definition -CatalogSlug 'fixture' `
            -DefaultCatalog ([pscustomobject]@{ models = @($template) }) -FallbackModelTemplate $template
        $configuredCatalog.context_window | Should -Be 1000000
        $configuredCatalog.auto_compact_token_limit | Should -Be 100000
    }

    It 'preserves the threshold when adding a registry model and leaves other models at defaults' {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive 'registry-home')
        $record = [pscustomobject]@{
            Slug = 'test-gemini'
            DisplayName = 'Test Gemini'
            UpstreamModel = 'gemini-4-argon'
            Transport = 'omniroute'
            DefaultReasoningLevel = 'high'
            SupportsImageInput = $false
            ContextWindow = 1000000
            AutoCompactTokenLimit = 100000
        }
        Add-UngateModelRegistryRecord -Context $context -Record $record | Out-Null
        $definition = Get-UngateModelDefinitions -Context $context | Where-Object Slug -EQ 'test-gemini'
        $definition.AutoCompactTokenLimit | Should -Be 100000
        $stored = Get-Content -LiteralPath $context.ModelRegistryPath -Raw | ConvertFrom-Json -Depth 30
        ($stored.models | Where-Object slug -EQ 'test-gemini').autoCompactTokenLimit | Should -Be 100000
        $other = Get-UngateTemplateModelDefinitions -Context $context | Where-Object Slug -EQ 'miniMax-M3'
        $other.AutoCompactTokenLimit | Should -BeNullOrEmpty
    }

    It 'rejects a compaction threshold outside the model context' {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive 'invalid-home')
        {
            ConvertTo-UngateModelDefinition -Context $context -Priority 0 -Record ([pscustomobject]@{
                Slug = 'bad-threshold'; DisplayName = 'Bad threshold'; UpstreamModel = 'gemini-4-argon'
                Transport = 'omniroute'; DefaultReasoningLevel = 'high'; SupportsImageInput = $false
                ContextWindow = 100000; AutoCompactTokenLimit = 100001
            })
        } | Should -Throw '*autoCompactTokenLimit*'
    }
}
