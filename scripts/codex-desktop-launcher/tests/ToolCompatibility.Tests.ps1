BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'Models', 'ToolCompatibility', 'Picker', 'Launcher')) {
        Import-Module (Join-Path $moduleRoot "$name.psm1") -DisableNameChecking -ErrorAction Stop
    }
    function New-ToolTestContext {
        param([hashtable]$Options = @{})
        New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive 'beta') -LaunchParameters $Options
    }
}

Describe 'Standalone tool compatibility orchestration' {
    BeforeEach {
        Mock -ModuleName Launcher Invoke-CodexToolCompatibility { return 0 }
        Mock -ModuleName Launcher Get-CodexBetaPackageInfo { throw 'Must not discover Desktop' }
        Mock -ModuleName Launcher Stop-CodexBeta { throw 'Must not stop Desktop' }
        Mock -ModuleName Launcher Initialize-CodexDesktopTransport { throw 'Must not restart router' }
        Mock -ModuleName Launcher Initialize-CodexDesktopProfile { throw 'Must not write profile' }
    }
    It 'runs standalone for one model and preserves its result' {
        Mock -ModuleName Launcher Invoke-CodexToolCompatibility { return 2 }
        $context = New-ToolTestContext @{ TestTools = $true; Model = 'grok-4.7' }
        Invoke-CodexDesktopLauncher -Context $context | Should -Be 2
        Should -Invoke -ModuleName Launcher Invoke-CodexToolCompatibility -Times 1 -ParameterFilter { $Model -eq 'grok-4.7' -and $Definitions.Count -gt 0 }
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
    It 'does not select the normal default model when Model is omitted' {
        Invoke-CodexDesktopLauncher -Context (New-ToolTestContext @{ TestTools = $true }) | Should -Be 0
        Should -Invoke -ModuleName Launcher Invoke-CodexToolCompatibility -Times 1 -ParameterFilter { [string]::IsNullOrEmpty($Model) }
    }
    It 'rejects conflicting flags before diagnostic work' -ForEach @('AddModel', 'PrepareOnly', 'EnableProviderFallback') {
        $options = @{ TestTools = $true }
        $options[$_] = $true
        { Invoke-CodexDesktopLauncher -Context (New-ToolTestContext $options) } | Should -Throw '*cannot be combined*'
        Should -Invoke -ModuleName Launcher Invoke-CodexToolCompatibility -Times 0
    }
}

Describe 'Tool selection and cache failures' {
    It 'selects several checkbox entries without changing picker settings' {
        Mock -ModuleName ToolCompatibility Test-ToolCompatibilityTerminal { $true }
        Mock -ModuleName ToolCompatibility Clear-Host {}
        $keys = [Collections.Generic.Queue[string]]::new()
        @('Spacebar', 'DownArrow', 'Spacebar', 'Enter') | ForEach-Object { $keys.Enqueue($_) }
        Mock -ModuleName ToolCompatibility Read-ToolCompatibilityKey { $keys.Dequeue() }
        $definitions = @([pscustomobject]@{Slug='one'; DisplayName='One'}, [pscustomobject]@{Slug='two'; DisplayName='Two'})
        $selection = @(& (Get-Module ToolCompatibility) { param($Items) Select-ToolCompatibilityModels -Definitions $Items } $definitions)
        $selection.Slug | Should -Be @('one','two')
    }
    It 'returns success when the user cancels selection' {
        Mock -ModuleName ToolCompatibility Select-ToolCompatibilityModels { @() }
        Mock -ModuleName ToolCompatibility Resolve-ModelApiKey { throw 'Must not resolve keys' }
        $context = New-ToolTestContext
        $definitions = (New-UngateModelSet -Context $context).BuiltInDefinitions
        Invoke-CodexToolCompatibility -Context $context -Definitions $definitions | Should -Be 0
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
    It 'fails missing and corrupt caches before resolving credentials' {
        Mock -ModuleName ToolCompatibility Resolve-ModelApiKey { throw 'Must not resolve keys' }
        $context = New-ToolTestContext
        $definitions = (New-UngateModelSet -Context $context).BuiltInDefinitions
        Invoke-CodexToolCompatibility -Context $context -Definitions $definitions -Model $definitions[0].Slug | Should -Be 2
        $directory = Join-Path $context.CustomCodexHome 'tool-compatibility'
        $null = New-Item -ItemType Directory -Path $directory -Force
        Set-Content -LiteralPath (Join-Path $directory 'tools-schema-cache.json') -Value '{broken'
        Invoke-CodexToolCompatibility -Context $context -Definitions $definitions -Model $definitions[0].Slug | Should -Be 2
        Should -Invoke -ModuleName ToolCompatibility Resolve-ModelApiKey -Times 0
        Test-Path -LiteralPath $context.CustomConfigPath | Should -BeFalse
    }
    It 'rejects unknown explicit models without prompting' {
        Mock -ModuleName ToolCompatibility Select-ToolCompatibilityModels { throw 'Must not prompt' }
        $context = New-ToolTestContext
        Invoke-CodexToolCompatibility -Context $context -Definitions (New-UngateModelSet -Context $context).BuiltInDefinitions -Model 'not-a-model' | Should -Be 2
        Should -Invoke -ModuleName ToolCompatibility Select-ToolCompatibilityModels -Times 0
    }
}

Describe 'TT menu returns to normal selection' {
    It 'runs diagnostics without changing picker configuration' {
        $context = New-ToolTestContext
        $definitions = (New-UngateModelSet -Context $context).BuiltInDefinitions
        $answers = [Collections.Generic.Queue[string]]::new()
        @('TT', '', '1') | ForEach-Object { $answers.Enqueue($_) }
        Mock -ModuleName Picker Read-Host { $answers.Dequeue() }
        Mock -ModuleName Picker Invoke-CodexToolCompatibility { 1 }
        Mock -ModuleName Picker Write-UngatePickerModelSelection { throw 'Must not write picker' }
        $selected = Select-UngateDesktopModel -Context $context -Definitions $definitions -BuiltInDefinitions $definitions -RegistryPath $context.CustomModelDefinitionsPath -PickerSettingsPath $context.PickerModelSelectionPath -PickerCapacity $context.CodexDesktopPickerCapacity
        $selected | Should -Be $definitions[0].Slug
        Should -Invoke -ModuleName Picker Invoke-CodexToolCompatibility -Times 1 -ParameterFilter { $Definitions.Count -gt 0 }
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
}
