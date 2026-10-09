BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'ModelCapabilities', 'Models', 'Capabilities', 'Picker', 'Routing', 'Catalog', 'Launcher')) {
        Import-Module (Join-Path $moduleRoot "$name.psm1") -DisableNameChecking -ErrorAction Stop
    }
    function New-CapabilityTestContext {
        param([hashtable]$Options = @{}, [string]$Name = '')
        if (-not $Name) { $Name = [guid]::NewGuid().ToString('N') }
        $context = New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive $Name) -LaunchParameters $Options
        $context.DefaultModelCachePath = Join-Path $TestDrive 'missing-cache.json'
        return $context
    }
    function Get-CapabilityTestModel {
        param([object]$Context)
        return (New-UngateModelSet -Context $Context).BuiltInDefinitions | Where-Object Slug -EQ 'mimo-v2.5-pro'
    }
}

Describe 'Capability storage and validation' {
    BeforeEach {
        $context = New-CapabilityTestContext
        $definition = Get-CapabilityTestModel $context
    }
    It 'merges capabilities without discarding version, label or context and applies them after reload' {
        $null = Set-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $definition.Slug -Override @{upstreamModel='mimo-v2.6-pro';displayName='Mimo v2.6 Pro';contextWindow=1000000}
        Set-UngateModelCapabilities -Context $context -Definition $definition -Values @{supportsImageInput=$true;supportsImageDetailOriginal=$false;supportsParallelToolCalls=$true}
        $overrides = Read-UngateModelOverrides $context.CustomModelOverridesPath
        $overrides[$definition.Slug].upstreamModel | Should -Be 'mimo-v2.6-pro'
        $overrides[$definition.Slug].contextWindow | Should -Be 1000000
        $effective = @(Apply-UngateModelOverrides -Context $context -Definitions @($definition) -Overrides $overrides)[0]
        $effective.InputModalities | Should -Be @('text','image')
        $effective.ParallelToolCallsOverride | Should -BeTrue
        $shellDefinitions = @(Set-CodexModelShellSlugs -Context $context -Definitions @($effective))
        $route = @(Get-CodexModelShellRoutes -Selection ([pscustomobject]@{Definitions=$shellDefinitions;MemoryEnabled=$false;EnableProviderFallback=$false}))[0]
        $route.parallelToolCalls | Should -BeTrue
    }
    It 'keeps capability and version reset independent in both directions' {
        $null = Set-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $definition.Slug -Override @{upstreamModel='mimo-v2.6-pro';supportsImageInput=$true;supportsImageDetailOriginal=$false}
        $null = Invoke-UngateModelVersionConfiguration -Context $context -Definitions @($definition) -OverridesPath $context.CustomModelOverridesPath -TargetModelSlug $definition.Slug -NewUpstreamModel reset
        $entry = (Read-UngateModelOverrides $context.CustomModelOverridesPath)[$definition.Slug]
        $entry.supportsImageInput | Should -BeTrue
        $entry.PSObject.Properties.Name | Should -Not -Contain 'upstreamModel'
        $null = Set-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $definition.Slug -Override @{upstreamModel='mimo-v2.6-pro'}
        $null = Remove-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $definition.Slug -Fields @(Get-UngateCapabilityNames)
        $entry = (Read-UngateModelOverrides $context.CustomModelOverridesPath)[$definition.Slug]
        $entry.upstreamModel | Should -Be 'mimo-v2.6-pro'
        $entry.PSObject.Properties.Name | Should -Not -Contain 'supportsImageInput'
    }
    It 'normalizes dependent settings when image, summaries or verbosity are disabled' {
        $enabled = Apply-UngateModelCapabilities -Context $context -Definition $definition -Values @{supportsImageInput=$true;supportsImageDetailOriginal=$true;supportsReasoningSummaries=$true;defaultReasoningSummary='concise';supportVerbosity=$true;defaultVerbosity='high'}
        Set-UngateModelCapabilities -Context $context -Definition $enabled -Values @{supportsImageInput=$false;supportsReasoningSummaries=$false;supportVerbosity=$false}
        $entry = (Read-UngateModelOverrides $context.CustomModelOverridesPath)[$definition.Slug]
        $entry.supportsImageDetailOriginal | Should -BeFalse
        $entry.defaultReasoningSummary | Should -Be 'none'
        $entry.defaultVerbosity | Should -BeNullOrEmpty
    }
    It 'qualifies the transport provider without changing native IDs and follows version edits' {
        $overrides = [ordered]@{ 'mimo-v2.5-pro' = [pscustomobject]@{upstreamModel='mimo-v2.6-pro';upstreamModelPrefix='openai-compatible-chat-test';supportsImageInput=$true} }
        $effective = @(Apply-UngateModelOverrides -Context $context -Definitions @($definition) -Overrides $overrides)[0]
        $effective.UpstreamModel | Should -Be 'mimo-v2.6-pro'
        $shell = @(Set-CodexModelShellSlugs -Context $context -Definitions @($effective))
        $route = @(Get-CodexModelShellRoutes -Selection ([pscustomobject]@{Definitions=$shell;MemoryEnabled=$false;EnableProviderFallback=$false}))[0]
        $route.upstreamModel | Should -Be 'openai-compatible-chat-test/mimo-v2.6-pro'
        (Get-CapabilityRunnerModel -Context $context -Definition $effective).model | Should -Be $route.upstreamModel
        $effective.UpstreamModel = 'mimo-next'
        Get-UngateRequestModel $effective | Should -Be 'openai-compatible-chat-test/mimo-next'
        $effective.UpstreamModel = 'other-provider/mimo-next'
        Get-UngateRequestModel $effective | Should -Be 'other-provider/mimo-next'
        $overrides['mimo-v2.5-pro'].upstreamModelPrefix = 'invalid/provider'
        { Apply-UngateModelOverrides -Context $context -Definitions @($definition) -Overrides $overrides } | Should -Throw '*prefix*'
    }
    It 'rejects invalid <Label> before creating any profile' -ForEach @(
        @{Label='Boolean';Values=@{supportsImageInput='false'}},
        @{Label='unknown field';Values=@{audio=$true}},
        @{Label='original without image';Values=@{supportsImageDetailOriginal=$true}},
        @{Label='empty efforts';Values=@{supportedReasoningLevels=@()}},
        @{Label='duplicate efforts';Values=@{supportedReasoningLevels=@('high','high')}},
        @{Label='unknown effort';Values=@{supportedReasoningLevels=@('persistent')}},
        @{Label='default outside efforts';Values=@{supportedReasoningLevels=@('none')}},
        @{Label='invalid verbosity';Values=@{supportVerbosity=$true;defaultVerbosity='extreme'}}
    ) {
        { Set-UngateModelCapabilities -Context $context -Definition $definition -Values $Values } | Should -Throw
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
    It 'inherits explicit reasoning presets and preserves their model subset' {
        $capabilities = Get-UngateModelCapabilities -Context $context -Definition $definition
        $capabilities.supportedReasoningLevels | Should -Be @('none','high')
        $updated = Apply-UngateModelCapabilities -Context $context -Definition $definition -Values @{supportedReasoningLevels=@('none','low','high');defaultReasoningLevel='low'}
        $updated.SupportedReasoningLevels.effort | Should -Be @('none','low','high')
        $updated.DefaultReasoningLevel | Should -Be 'low'
    }
    It 'retains a manual backup when updating existing overrides' {
        $null = Set-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $definition.Slug -Override @{upstreamModel='mimo-v2.6-pro'}
        $null = Set-UngateModelOverride -OverridesPath $context.CustomModelOverridesPath -Slug $definition.Slug -Override @{supportsImageInput=$true}
        @(Get-ChildItem -LiteralPath $context.CustomCodexHome -Force -Filter '.ungate-model-overrides.*.bak').Count | Should -BeGreaterThan 0
    }
    It 'does not invent levels to accommodate an inconsistent default' {
        $definition.SupportedReasoningLevels = @(@{effort='none'})
        (Get-UngateModelCapabilities -Context $context -Definition $definition).supportedReasoningLevels | Should -Be @('none')
        { Merge-UngateModelCapabilities -Context $context -Definition $definition -Values @{} } | Should -Throw '*default reasoning level*'
    }
    It 'inherits the original shell defaults rather than previous generated overrides' {
        New-Item -ItemType Directory -Path $context.CustomCodexHome | Out-Null
        $context.DefaultModelCachePath = Join-Path $context.CustomCodexHome 'original.json'
        @{models=@(@{slug='gpt-5.4';supported_reasoning_levels=@(@{effort='low'},@{effort='high'});supports_parallel_tool_calls=$true})} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $context.DefaultModelCachePath
        @{models=@(@{slug='gpt-5.4';display_name=$definition.DisplayName;supported_reasoning_levels=@(@{effort='ultra'});supports_parallel_tool_calls=$false})} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $context.CustomModelCatalogPath
        $definition.SupportedReasoningLevels = $null
        $definition.SupportsParallelToolCalls = $null
        $inherited = Get-UngateModelCapabilities -Context $context -Definition $definition
        $inherited.supportedReasoningLevels | Should -Be @('low','high')
        $inherited.supportsParallelToolCalls | Should -BeTrue
    }
    It 'writes current and legacy catalog fields and keeps hidden memory capabilities independent' {
        New-Item -ItemType Directory -Path $context.CustomCodexHome | Out-Null
        $context.DefaultModelCachePath = Join-Path $context.CustomCodexHome 'template.json'
        @{models=@(@{slug='gpt-5.4';base_instructions='You are Codex.';supports_parallel_tool_calls=$false;supported_reasoning_levels=@(@{effort='none'},@{effort='high'})})} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $context.DefaultModelCachePath
        Set-Content -LiteralPath $context.CustomConfigPath -Value 'model = "gpt-5.4"'
        $enabled = Apply-UngateModelCapabilities -Context $context -Definition $definition -Values @{supportsImageInput=$true;supportsImageDetailOriginal=$false;supportsReasoningSummaries=$true;defaultReasoningSummary='concise';supportVerbosity=$true;defaultVerbosity='high';supportsParallelToolCalls=$true}
        $shell = @(Set-CodexModelShellSlugs -Context $context -Definitions @($enabled))[0]
        $memory = ConvertTo-UngateModelDefinition -Context $context -Priority 100 -Record ([pscustomobject]@{Slug='ungate-memory';DisplayName='Memories';UpstreamModel='memory-model';Transport='cliproxyapi';DefaultReasoningLevel='high';SupportsImageInput=$false})
        $selection = [pscustomobject]@{Definitions=@($shell);SelectedModel=$shell;LaunchModel=$shell.ShellSlug;LaunchProvider=$context.CodexModelShellRouterProviderDefinition;EnableProviderFallback=$false;MemoryEnabled=$true;MemoryDefinition=$memory}
        Write-UngateModelCatalog -Context $context -Selection $selection
        $catalog = Get-Content -LiteralPath $context.CustomModelCatalogPath -Raw | ConvertFrom-Json -Depth 100
        $catalog.models[0].supports_reasoning_summary_parameter | Should -BeTrue
        $catalog.models[0].supports_reasoning_summaries | Should -BeTrue
        $catalog.models[0].default_reasoning_summary | Should -Be 'concise'
        $catalog.models[0].default_verbosity | Should -Be 'high'
        $catalog.models[1].input_modalities | Should -Be @('text')
        $catalog.models[1].support_verbosity | Should -BeFalse
        $catalog.models[1].default_reasoning_summary | Should -Be 'none'
        $catalog.models[1].supports_parallel_tool_calls | Should -BeFalse
    }
}

Describe 'Capability command isolation and editor' {
    BeforeEach {
        Mock -ModuleName Launcher Get-CodexBetaPackageInfo { throw 'Must not discover Beta' }
        Mock -ModuleName Launcher Stop-CodexBeta { throw 'Must not stop Beta' }
        Mock -ModuleName Launcher Initialize-CodexDesktopTransport { throw 'Must not restart transport' }
        Mock -ModuleName Launcher Initialize-CodexDesktopProfile { throw 'Must not prepare profile' }
    }
    It 'updates capabilities noninteractively without a running provider' {
        $context = New-CapabilityTestContext @{Model='mimo-v2.5-pro';SetModelCapabilities='{"supportsImageInput":true,"supportsImageDetailOriginal":false}'}
        Invoke-CodexDesktopLauncher -Context $context | Should -Be 0
        Test-Path -LiteralPath $context.CustomConfigPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.CustomCodexHome 'ungate-memory-settings.json') | Should -BeFalse
        (Read-UngateModelOverrides $context.CustomModelOverridesPath)['mimo-v2.5-pro'].supportsImageInput | Should -BeTrue
    }
    It 'rejects conflicting modes without writing' {
        $context = New-CapabilityTestContext @{ConfigureCapabilities=$true;PrepareOnly=$true}
        { Invoke-CodexDesktopLauncher -Context $context } | Should -Throw '*cannot be combined*'
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
    It 'cancels unsaved edits without creating a profile or calling a provider' {
        $context = New-CapabilityTestContext
        $definition = Get-CapabilityTestModel $context
        $answers = [Collections.Generic.Queue[string]]::new()
        @('1','b') | ForEach-Object { $answers.Enqueue($_) }
        Mock -ModuleName Capabilities Read-Host { $answers.Dequeue() }
        Mock -ModuleName Capabilities Invoke-CapabilityRunner { return 0 }
        Mock -ModuleName Capabilities Invoke-UngateCapabilityTest { throw 'Must not probe' }
        Invoke-UngateCapabilitiesMenu -Context $context -Definitions @($definition) -Model $definition.Slug | Should -BeFalse
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
    It 'rejects ambiguous aliases' {
        $defs = @([pscustomobject]@{Slug='one';Aliases=@('alias')},[pscustomobject]@{Slug='two';Aliases=@('alias')})
        { Resolve-CapabilityModel -Definitions $defs -Model alias } | Should -Throw '*ambiguous*'
    }
}
