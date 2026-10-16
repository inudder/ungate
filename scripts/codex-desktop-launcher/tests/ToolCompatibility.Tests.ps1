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
        $selected = Select-UngateDesktopModel -Context $context -Definitions $definitions -PickerSettingsPath $context.PickerModelSelectionPath -PickerCapacity $context.CodexDesktopPickerCapacity
        $selected | Should -Be $definitions[0].Slug
        Should -Invoke -ModuleName Picker Invoke-CodexToolCompatibility -Times 1 -ParameterFilter { $Definitions.Count -gt 0 }
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }
}

Describe 'Isolated tool runtime discovery' {
    BeforeEach {
        $context = New-ToolTestContext
        $null = New-Item -ItemType Directory -Path $context.CustomCodexHome -Force
        $script:toolRuntimeFixture = Join-Path $TestDrive 'beta-cli.exe'
        Set-Content -LiteralPath $script:toolRuntimeFixture -Value 'fixture executable'
        @{ models = @(@{ slug = 'selected-shell'; display_name = 'Selected model' }) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $context.CustomModelCatalogPath
        $definition = [pscustomobject]@{ DisplayName = 'Selected model'; Slug = 'selected-upstream' }
        Mock -ModuleName ToolCompatibility New-UngateCatalogModelInfo {
            @{ slug = $CatalogSlug; display_name = $Definition.DisplayName }
        }
    }
    It 'prefers the selected Beta CLI over the normal resolver' {
        Set-Content -LiteralPath $context.CustomConfigPath -Value ('CODEX_CLI_PATH = ''' + $script:toolRuntimeFixture + '''')
        Mock -ModuleName ToolCompatibility Get-CodexCliExecutable { throw 'Must prefer Beta' }
        $runtime = Get-CodexToolTestRuntime -Context $context -Definition $definition
        $runtime.executable | Should -Be $script:toolRuntimeFixture
        $runtime.modelInfo.slug | Should -Be 'selected-shell'
        $runtime.modelInfo.display_name | Should -Be 'Selected model'
        Should -Invoke -ModuleName ToolCompatibility Get-CodexCliExecutable -Times 0
    }
    It 'falls back to the existing resolver when the Beta path is stale' {
        Set-Content -LiteralPath $context.CustomConfigPath -Value 'CODEX_CLI_PATH = ''missing-cli.exe'''
        Mock -ModuleName ToolCompatibility Get-CodexCliExecutable { $script:toolRuntimeFixture }
        $runtime = Get-CodexToolTestRuntime -Context $context -Definition $definition
        $runtime.executable | Should -Be $script:toolRuntimeFixture
        Should -Invoke -ModuleName ToolCompatibility Get-CodexCliExecutable -Times 1
    }
}

Describe 'Tool control operation deadlines and cancellation' {
    BeforeAll {
        function Complete-Job { param($Job, $Status, $Message, $Report, $ExitCode) }
        $controlFile = Join-Path (Split-Path -Parent $moduleRoot) 'codex-launcher-control-agent.ps1'
        $controlAst = [System.Management.Automation.Language.Parser]::ParseFile($controlFile, [ref]$null, [ref]$null)
        foreach ($functionName in @('Write-JsonFile','Read-JsonFile','New-Operation','Save-Operation','Update-Jobs')) {
            $definitionAst = $controlAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            Set-Item -Path "Function:script:$functionName" -Value $definitionAst.Body.GetScriptBlock()
        }
    }
    BeforeEach {
        $operationsRoot = Join-Path $TestDrive 'operations'
        $requestsPath = Join-Path $TestDrive 'requests.json'
        $script:Jobs = @{}
        Mock Complete-Job {}
    }
    It 'allows twenty minutes per model plus shutdown grace' {
        $operation = New-Operation -RequestId 'deadline-fixture' -Kind tools -RegistryIds @('one','two') -ProbeCount 2
        $seconds = ([DateTime]::Parse($operation.deadlineAt) - [DateTime]::Parse($operation.startedAt)).TotalSeconds
        $seconds | Should -BeGreaterOrEqual 2430
        $seconds | Should -BeLessThan 2431
    }
    It 'requests graceful cancellation before killing an owned process' {
        $cancelPath = Join-Path $TestDrive 'operation.cancel'
        $fakeProcess = [pscustomobject]@{ HasExited = $false; Killed = $false }
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($EntireTree) $this.Killed = $true }
        $job = @{ Id = 'cancel-fixture'; Kind = 'node'; Process = $fakeProcess; Cancel = $true; CancelPath = $cancelPath; CancelRequestedAt = $null; Deadline = [DateTime]::UtcNow.AddMinutes(1) }
        $script:Jobs[$job.Id] = $job
        Update-Jobs
        Test-Path -LiteralPath $cancelPath | Should -BeTrue
        $fakeProcess.Killed | Should -BeFalse
        $job.CancelRequestedAt | Should -Not -BeNullOrEmpty
    }
    It 'keeps the partial report when the ten-second shutdown grace expires' {
        $partialPath = Join-Path $TestDrive 'partial.json'
        Set-Content -LiteralPath $partialPath -Value '{"version":2,"models":[{"checks":[{"status":"accepted"}]}]}'
        $fakeProcess = [pscustomobject]@{ HasExited = $false; Killed = $false }
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($EntireTree) $this.Killed = $EntireTree }
        $job = @{ Id = 'forced-fixture'; Kind = 'node'; Process = $fakeProcess; Cancel = $true; CancelPath = (Join-Path $TestDrive 'forced.cancel'); CancelRequestedAt = [DateTime]::UtcNow.AddSeconds(-11); PartialReportPath = $partialPath; Deadline = [DateTime]::UtcNow.AddMinutes(1) }
        $script:Jobs[$job.Id] = $job
        Update-Jobs
        $fakeProcess.Killed | Should -BeTrue
        Should -Invoke Complete-Job -Times 1 -ParameterFilter { $Status -eq 'cancelled' -and $ExitCode -eq 2 -and $Report.version -eq 2 -and $Report.models[0].checks[0].status -eq 'accepted' }
        Test-Path -LiteralPath $partialPath | Should -BeTrue
    }
}
