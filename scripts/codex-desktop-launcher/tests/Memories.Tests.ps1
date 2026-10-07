BeforeAll {
    $script:moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'Models', 'Routing', 'Memories', 'Launcher', 'Picker', 'Profile', 'Catalog')) {
        Import-Module (Join-Path $script:moduleRoot "$name.psm1") -DisableNameChecking
    }
    function New-MemoryTestContext {
        param([hashtable]$Options = @{Model='grok-4.7'})
        New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -LaunchParameters $Options
    }
    function Get-MemoryTestSelection {
        param($Context)
        & (Get-Module Launcher) { param($c) Resolve-CodexDesktopSelection -Context $c -ModelSet (New-UngateModelSet -Context $c) } $Context
    }
}

Describe 'Memory preferences' {
    It 'defaults to disabled Gemini without writing or requiring credentials' {
        $context = New-MemoryTestContext
        $settings = Read-UngateMemorySettings -Context $context
        $settings.Enabled | Should -BeFalse
        $settings.Model | Should -Be 'gemini-3.8-flash-high'
        $settings.Provider | Should -Be 'cliproxyapi'
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
    It 'persists a chosen model and retains a manual backup on replacement' {
        $context = New-MemoryTestContext
        $settings = New-UngateMemorySettings
        Write-UngateMemorySettings -Context $context -Settings $settings
        $settings.Enabled = $true
        Write-UngateMemorySettings -Context $context -Settings $settings
        (Read-UngateMemorySettings -Context $context).Enabled | Should -BeTrue
        @(Get-ChildItem -LiteralPath $context.CustomCodexHome -Force -Filter '*.bak').Count | Should -Be 1
        Get-Content -LiteralPath $context.MemorySettingsPath -Raw | Should -Not -Match 'apiKey|secret'
    }
    It 'preserves corrupt settings and uses memories Off' {
        $context = New-MemoryTestContext
        [void][IO.Directory]::CreateDirectory($context.CustomCodexHome)
        [IO.File]::WriteAllText($context.MemorySettingsPath, '{invalid')
        Mock Write-Warning {} -ModuleName Memories
        (Read-UngateMemorySettings -Context $context).Enabled | Should -BeFalse
        Get-Content -LiteralPath $context.MemorySettingsPath -Raw | Should -BeExactly '{invalid'
    }
    It 'maps the exact model to each provider and preserves known adapters' -ForEach @(
        @{Provider='cliproxyapi';Model='gemini-3.8-flash-high';Endpoint='http://127.0.0.1:8318';Adapter=$null},
        @{Provider='omniroute';Model='mimo-v2.5-pro';Endpoint='http://127.0.0.1:20128';Adapter='mimo-textual-tools'},
        @{Provider='omniroute';Model='deepseek/deepseek-v4-pro';Endpoint='http://127.0.0.1:20128';Adapter='deepseek-responses'},
        @{Provider='ungate';Model='claude-fable-5';Endpoint='http://127.0.0.1:47821';Adapter=$null}
    ) {
        $context = New-MemoryTestContext
        $settings = New-UngateMemorySettings
        $settings.Provider = $Provider; $settings.Model = $Model
        $definition = Get-UngateMemoryDefinition -Context $context -Settings $settings
        $definition.ProxyBaseUrl | Should -Be $Endpoint
        $definition.UpstreamModel | Should -Be $Model
        $definition.ResponsesAdapter | Should -Be $Adapter
        $definition.ShellSlug | Should -Be 'ungate-memory'
    }
    It 'applies all flags and both model aliases while preserving other settings' {
        $config = "[features]`nmemories = false`njs_repl = true`n[memories]`nextract_model = `"old`" # keep`n"
        $updated = Set-UngateMemoryConfig -Content $config -Enabled $true
        $updated | Should -Match 'memories = true'
        $updated | Should -Match 'generate_memories = true'
        $updated | Should -Match 'use_memories = true'
        $updated | Should -Match 'extract_model = "ungate-memory" # keep'
        $updated | Should -Match 'consolidation_model = "ungate-memory"'
        $updated | Should -Match 'js_repl = true'
    }
}

Describe 'Memory validation cache' {
    BeforeEach {
        $script:context = New-MemoryTestContext
        Mock Resolve-ModelApiKey { 'fixture' } -ModuleName Memories
        Mock Write-Host {} -ModuleName Memories
        Mock Write-Warning {} -ModuleName Memories
    }
    It 'reuses a success within the invocation and repeats it on a new context' {
        Mock Invoke-UngateMemoryProbe { [pscustomobject]@{Valid=$true;Stage='complete'} } -ModuleName Memories
        $settings = New-UngateMemorySettings
        (Invoke-UngateMemoryValidation -Context $script:context -Settings $settings).Valid | Should -BeTrue
        (Invoke-UngateMemoryValidation -Context $script:context -Settings $settings).Valid | Should -BeTrue
        Should -Invoke Invoke-UngateMemoryProbe -ModuleName Memories -Times 1
        $nextContext = New-MemoryTestContext
        (Invoke-UngateMemoryValidation -Context $nextContext -Settings $settings).Valid | Should -BeTrue
        Should -Invoke Invoke-UngateMemoryProbe -ModuleName Memories -Times 2
    }
    It 'invalidates an earlier success when a forced check fails' {
        Mock Invoke-UngateMemoryProbe { [pscustomobject]@{Valid=$true;Stage='complete'} } -ModuleName Memories
        $settings = New-UngateMemorySettings
        $null = Invoke-UngateMemoryValidation -Context $script:context -Settings $settings
        Mock Invoke-UngateMemoryProbe { [pscustomobject]@{Valid=$false;Stage='extraction';Code='http_401'} } -ModuleName Memories
        (Invoke-UngateMemoryValidation -Context $script:context -Settings $settings -Force).Valid | Should -BeFalse
        $script:context.MemoryValidationSignature | Should -BeNullOrEmpty
        (Invoke-UngateMemoryValidation -Context $script:context -Settings $settings).Valid | Should -BeFalse
        Should -Invoke Invoke-UngateMemoryProbe -ModuleName Memories -Times 3
    }
}

Describe 'Memory menu' {
    BeforeEach {
        $script:context = New-MemoryTestContext
        Mock Write-Host {} -ModuleName Memories
        Mock Write-Warning {} -ModuleName Memories
    }
    It 'disables without validation or network access' {
        $settings = New-UngateMemorySettings; $settings.Enabled = $true
        Write-UngateMemorySettings -Context $script:context -Settings $settings
        $script:choices = [Collections.Generic.Queue[string]]::new(); $script:choices.Enqueue('1'); $script:choices.Enqueue('B')
        Mock Read-Host { $script:choices.Dequeue() } -ModuleName Memories
        Mock Invoke-UngateMemoryValidation { throw 'unexpected network' } -ModuleName Memories
        Invoke-UngateMemoryMenu -Context $script:context
        (Read-UngateMemorySettings -Context $script:context).Enabled | Should -BeFalse
        Should -Invoke Invoke-UngateMemoryValidation -ModuleName Memories -Times 0
    }
    It 'does not save enabling after validation failure' {
        $script:choices = [Collections.Generic.Queue[string]]::new(); $script:choices.Enqueue('1'); $script:choices.Enqueue('B')
        Mock Read-Host { $script:choices.Dequeue() } -ModuleName Memories
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$false} } -ModuleName Memories
        Invoke-UngateMemoryMenu -Context $script:context
        Test-Path -LiteralPath $script:context.MemorySettingsPath | Should -BeFalse
    }
    It 'saves an enabled choice after validation and returns to the submenu' {
        $script:choices = [Collections.Generic.Queue[string]]::new(); $script:choices.Enqueue('1'); $script:choices.Enqueue('B')
        Mock Read-Host { $script:choices.Dequeue() } -ModuleName Memories
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$true} } -ModuleName Memories
        Invoke-UngateMemoryMenu -Context $script:context
        (Read-UngateMemorySettings -Context $script:context).Enabled | Should -BeTrue
    }
    It 'opens standalone settings without launching or stopping Codex' {
        $context = New-MemoryTestContext @{ConfigureMemories=$true}
        Mock Invoke-UngateMemoryMenu {} -ModuleName Launcher
        Mock Get-CodexBetaPackageInfo { throw 'unexpected desktop lookup' } -ModuleName Launcher
        Invoke-CodexDesktopLauncher -Context $context | Should -Be 0
        Should -Invoke Invoke-UngateMemoryMenu -ModuleName Launcher -Times 1
    }
    It 'selects a manual upstream model and provider after a successful check' {
        $script:choices = [Collections.Generic.Queue[string]]::new()
        foreach ($choice in @('2','2','fixture-upstream','B')) { $script:choices.Enqueue($choice) }
        Mock Read-Host { $script:choices.Dequeue() } -ModuleName Memories
        Mock Get-UngateMemoryCatalog { @('catalog-model') } -ModuleName Memories
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$true} } -ModuleName Memories
        Invoke-UngateMemoryMenu -Context $script:context
        $settings = Read-UngateMemorySettings -Context $script:context
        $settings.Provider | Should -Be 'omniroute'
        $settings.Model | Should -Be 'fixture-upstream'
        $settings.Enabled | Should -BeFalse
        Should -Invoke Invoke-UngateMemoryValidation -ModuleName Memories -Times 1 -ParameterFilter { $Settings.Model -eq 'fixture-upstream' }
    }
    It 'restores the default model while retaining the enable preference' {
        $settings = New-UngateMemorySettings; $settings.Enabled=$true; $settings.Provider='ungate'; $settings.Model='old-model'
        Write-UngateMemorySettings -Context $script:context -Settings $settings
        $script:choices = [Collections.Generic.Queue[string]]::new()
        foreach ($choice in @('4','B')) { $script:choices.Enqueue($choice) }
        Mock Read-Host { $script:choices.Dequeue() } -ModuleName Memories
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$true} } -ModuleName Memories
        Invoke-UngateMemoryMenu -Context $script:context
        $settings = Read-UngateMemorySettings -Context $script:context
        $settings.Enabled | Should -BeTrue
        $settings.Provider | Should -Be 'cliproxyapi'
        $settings.Model | Should -Be 'gemini-3.8-flash-high'
    }
    It 'supports the main menu shortcut and its numbered item' -ForEach @(@{Choice='M'},@{Choice='13'}) {
        $context = New-MemoryTestContext
        $modelSet = New-UngateModelSet -Context $context
        $script:mainChoices = [Collections.Generic.Queue[string]]::new()
        $script:mainChoices.Enqueue($Choice); $script:mainChoices.Enqueue('1')
        Mock Read-Host { $script:mainChoices.Dequeue() } -ModuleName Picker
        Mock Write-Host {} -ModuleName Picker
        Mock Invoke-UngateMemoryMenu {} -ModuleName Picker
        $selection = Select-UngateDesktopModel -Context $context -Definitions $modelSet.BuiltInDefinitions `
            -BuiltInDefinitions $modelSet.BuiltInDefinitions -RegistryPath $context.CustomModelDefinitionsPath `
            -PickerSettingsPath $context.PickerModelSelectionPath -PickerCapacity 7 -IncludeProviderFallback
        $selection | Should -Be $modelSet.BuiltInDefinitions[0].Slug
        Should -Invoke Invoke-UngateMemoryMenu -ModuleName Picker -Times 1
    }
}

Describe 'Memory transport preparation' {
    BeforeEach {
        $script:context = New-MemoryTestContext
        $settings = New-UngateMemorySettings; $settings.Enabled = $true
        Write-UngateMemorySettings -Context $script:context -Settings $settings
        Mock Resolve-ModelApiKey { 'fixture' } -ModuleName Launcher
        Mock Ensure-CliProxyBridge {} -ModuleName Launcher
        Mock Ensure-CodexModelShellRouter {} -ModuleName Launcher
        Mock Invoke-CliProxyPreflight {} -ModuleName Launcher
        Mock Invoke-DesktopOmniRoutePreflight {} -ModuleName Launcher
        Mock Write-Host {} -ModuleName Launcher
        Mock Write-Warning {} -ModuleName Launcher
    }
    It 'does not validate disabled memories' {
        $settings = New-UngateMemorySettings
        Write-UngateMemorySettings -Context $script:context -Settings $settings
        Mock Invoke-UngateMemoryValidation { throw 'unexpected memory validation' } -ModuleName Launcher
        $selection = Get-MemoryTestSelection $script:context
        $null = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $script:context $selection
        Should -Invoke Invoke-UngateMemoryValidation -ModuleName Launcher -Times 0
        $selection.MemoryEnabled | Should -BeFalse
    }
    It 'temporarily disables failed memories without changing saved preferences' {
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$false;Stage='extraction';Code='http_401'} } -ModuleName Launcher
        $selection = Get-MemoryTestSelection $script:context
        $result = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $script:context $selection
        $selection.MemoryEnabled | Should -BeFalse
        $result.MemoryFailure | Should -Match 'http_401'
        (Read-UngateMemorySettings -Context $script:context).Enabled | Should -BeTrue
    }
    It 'adds a separate route without occupying picker slots' {
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$true} } -ModuleName Launcher
        $selection = Get-MemoryTestSelection $script:context
        $count = $selection.Definitions.Count
        $null = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $script:context $selection
        $selection.Definitions.Count | Should -Be $count
        $routes = @(Get-CodexModelShellRoutes -Selection $selection)
        $routes.Count | Should -Be ($count + 1)
        $memoryRoute = $routes | Where-Object clientModel -EQ 'ungate-memory'
        $memoryRoute.upstreamModel | Should -Be 'gemini-3.8-flash-high'
        $memoryRoute.upstreamBaseUrl | Should -Be 'http://127.0.0.1:8318'
        $memoryRoute.apiKeyEnv | Should -Be 'UNGATE_MEMORY_API_KEY'
    }
    It 'keeps fallback combo routing while sending memories through the router' {
        $context = New-MemoryTestContext @{EnableProviderFallback=$true;PrepareOnly=$true}
        $settings = New-UngateMemorySettings; $settings.Enabled = $true
        Write-UngateMemorySettings -Context $context -Settings $settings
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$true} } -ModuleName Launcher
        $selection = Get-MemoryTestSelection $context
        $null = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $context $selection
        $selection.EnableProviderFallback | Should -BeTrue
        $selection.LaunchProvider.Name | Should -Be $context.CodexModelShellRouterProviderName
        (Get-CodexConfigProviderDefinitions -Context $context -Selection $selection).Name | Should -Be $context.CodexModelShellRouterProviderName
        $fallback = Get-CodexModelShellRoutes -Selection $selection | Where-Object clientModel -EQ 'codex-fallback'
        $fallback.upstreamBaseUrl | Should -Be $context.OmniRouteBaseUrl
        Should -Invoke Ensure-CodexModelShellRouter -ModuleName Launcher -Times 1
    }
    It 'uses independently resolved memory credentials despite an explicit main key' {
        $script:context.Options.ApiKey = 'main-credential'
        Mock Resolve-ModelApiKey { if ($ApiKey) { $ApiKey } else { 'memory-or-default-credential' } } -ModuleName Launcher
        Mock Invoke-UngateMemoryValidation { [pscustomobject]@{Valid=$true} } -ModuleName Launcher
        $selection = Get-MemoryTestSelection $script:context
        $result = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $script:context $selection
        $selection.MemoryApiKey | Should -Be 'memory-or-default-credential'
        $result.SelectedKey | Should -Be 'main-credential'
    }
}
