BeforeAll {
    $script:moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'Models', 'Routing', 'ProxyRuntime', 'Desktop', 'Profile', 'Catalog', 'Launcher')) {
        Import-Module (Join-Path $script:moduleRoot "$name.psm1") -DisableNameChecking -ErrorAction Stop
    }

    function New-TestContext {
        param([hashtable]$Options = @{}, [string]$Name = 'beta')
        New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive $Name) -LaunchParameters $Options
    }

    function Get-TestSelection {
        param($Context)
        $modelSet = New-UngateModelSet -Context $Context
        & (Get-Module Launcher) {
            param($Context, $ModelSet)
            Resolve-CodexDesktopSelection -Context $Context -ModelSet $ModelSet
        } $Context $modelSet
    }

    function ConvertTo-ModelSnapshot {
        param($Definition)
        $properties = [ordered]@{}
        foreach ($property in $Definition.PSObject.Properties) {
            if ($property.Name -eq 'Identity') {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$property.Value)
                $properties.IdentitySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            }
            else { $properties[$property.Name] = $property.Value }
        }
        [pscustomobject]$properties
    }

    function ConvertTo-CanonicalObject {
        param([AllowNull()]$Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
            $keys = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
            $result = [ordered]@{}
            foreach ($key in ($keys | Sort-Object)) { $result[$key] = ConvertTo-CanonicalObject $Value.$key }
            return $result
        }
        if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-CanonicalObject $_ }) }
        return $Value
    }
}

Describe 'Module boundaries and stable model contracts' {
    It 'imports in a clean process without launch, network, profile writes or environment changes' {
        $probe = @'
param($ModulePath)
$ErrorActionPreference = 'Stop'
function global:Start-Process { throw 'Unexpected process launch during import' }
function global:Stop-Process { throw 'Unexpected process stop during import' }
function global:Start-Job { throw 'Unexpected job during import' }
function global:Invoke-RestMethod { throw 'Unexpected network during import' }
function global:Invoke-WebRequest { throw 'Unexpected network during import' }
function global:New-Item { throw 'Unexpected filesystem write during import' }
function global:Set-Content { throw 'Unexpected filesystem write during import' }
function global:Remove-Item { throw 'Unexpected deletion during import' }
$before = Get-ChildItem Env: | Sort-Object Name | Select-Object Name,Value | ConvertTo-Json -Compress
Import-Module $ModulePath -DisableNameChecking -ErrorAction Stop
$after = Get-ChildItem Env: | Sort-Object Name | Select-Object Name,Value | ConvertTo-Json -Compress
if ($before -cne $after) { throw 'Import changed environment' }
'@
        $modulePath = (Join-Path $script:moduleRoot 'Launcher.psm1').Replace("'", "''")
        $probe = '& { ' + $probe + "`n} '" + $modulePath + "'"
        $output = & pwsh -NoProfile -NonInteractive -Command $probe 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'parses every module and has no per-launch script/global variables or module-level execution' {
        foreach ($file in Get-ChildItem -LiteralPath $script:moduleRoot -Filter '*.psm1') {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0 -Because $file.Name
            $state = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -match '^(script|global):'
            }, $true))
            $state.Count | Should -Be 0 -Because $file.Name
            foreach ($statement in $ast.EndBlock.Statements) {
                if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
                $statement | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
                $command = $statement.PipelineElements[0]
                if ($command.InvocationOperator -eq 'Dot') {
                    $file.BaseName | Should -Be 'ProxyRuntime'
                }
                else { $command.GetCommandName() | Should -BeIn @('Import-Module', 'Export-ModuleMember') }
            }
        }
    }

    It 'resolves helper paths independently of the current working directory' {
        Push-Location $TestDrive
        try { $context = New-TestContext }
        finally { Pop-Location }
        $context.CliProxyBridgePath | Should -Be (Join-Path (Split-Path -Parent $script:moduleRoot) 'cliproxy-namespace-bridge.mjs')
        $context.CodexPackageLaunchHelperPath | Should -Be (Join-Path (Split-Path -Parent $script:moduleRoot) 'start-codex-beta-package-process.ps1')
        Test-Path -LiteralPath $context.CustomCodexHome | Should -BeFalse
    }

    It 'preserves all builtin model fields and exact identity bytes from the monolith' {
        $models = New-UngateModelSet -Context (New-TestContext)
        $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/models.json') -Raw | ConvertFrom-Json -Depth 30
        $actual = [ordered]@{
            BuiltInDefinitions = @($models.BuiltInDefinitions | ForEach-Object { ConvertTo-ModelSnapshot $_ })
            FallbackDefinition = ConvertTo-ModelSnapshot $models.FallbackDefinition
        }
        (ConvertTo-CanonicalObject $actual | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly (ConvertTo-CanonicalObject $expected | ConvertTo-Json -Depth 30 -Compress)
    }

    It 'keeps route boundaries and shell mappings for Ungate, Grok and Mimo' {
        $context = New-TestContext
        $models = (New-UngateModelSet -Context $context).BuiltInDefinitions
        $definitions = @($models | Where-Object Slug -In @('miniMax-M3', 'grok-4.6', 'mimo-v2.5-pro'))
        $selection = [pscustomobject]@{ Definitions = @(Set-CodexModelShellSlugs -Context $context -Definitions $definitions); EnableProviderFallback = $false }
        $routes = @(Get-CodexModelShellRoutes -Selection $selection)
        @($routes.clientModel) | Should -Be @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
        @($routes.upstreamBaseUrl) | Should -Be @('http://127.0.0.1:47821', 'http://127.0.0.1:8318', 'http://127.0.0.1:20128')
        @($routes.upstreamModel) | Should -Be @('miniMax-M3', 'grok-4.6', 'mimo-v2.5-pro')
        $routes[0].responsesAdapter | Should -BeNullOrEmpty
        $routes[1].responsesAdapter | Should -BeNullOrEmpty
        $routes[2].responsesAdapter | Should -Be 'mimo-textual-tools'
    }

    It 'preserves managed provider TOML and unrelated tables' {
        $context = New-TestContext @{ Model = 'grok-4.6' }
        $selection = Get-TestSelection $context
        $content = "model = 'old'`r`n[other]`r`nkeep = true`r`n[model_providers.omniroute]`r`nname = 'old'`r`n"
        $expected = "model = 'old'`r`n[other]`r`nkeep = true`r`n[model_providers.ungate_model_shell_router]`nname = `"Ungate Codex Model Router`"`nbase_url = `"http://127.0.0.1:8319/v1`"`nenv_key = `"UNGATE_API_KEY`"`nwire_api = `"responses`"`r`n"
        Ensure-ModelProvidersInConfig -Context $context -Selection $selection -Content $content | Should -BeExactly $expected
    }

    It 'distinguishes omitted Model from explicitly passing the default' {
        Mock -ModuleName Launcher Select-UngateDesktopModel { 'grok-4.6' }
        (Get-TestSelection (New-TestContext)).SelectedModel.Slug | Should -Be 'grok-4.6'
        (Get-TestSelection (New-TestContext @{Model='ungate-opus-4-8'})).SelectedModel.Slug | Should -Be 'ungate-opus-4-8'
        Should -Invoke -ModuleName Launcher Select-UngateDesktopModel -Times 1 -Exactly
    }

    It 'rejects unknown and disabled models without preparing a profile' {
        { Get-TestSelection (New-TestContext @{Model='unknown'}) } | Should -Throw '*Unsupported Desktop model*'
        { Get-TestSelection (New-TestContext @{Model='deepseek-v4-pro'}) } | Should -Throw '*not enabled in the Desktop picker*'
        { Get-TestSelection (New-TestContext @{Model='deepseek-flash'}) } | Should -Throw '*not enabled in the Desktop picker*'
    }

    It 'selects fallback from the menu without leaking it into later selections' {
        Mock -ModuleName Launcher Select-UngateDesktopModel { 'codex-fallback' }
        $context = New-TestContext
        $first = Get-TestSelection $context
        $second = Get-TestSelection (New-TestContext @{Model='grok-4.6'})
        $first.EnableProviderFallback | Should -BeTrue
        $first.LaunchModel | Should -Be 'codex-fallback'
        $second.EnableProviderFallback | Should -BeFalse
        $second.LaunchProvider.Name | Should -Be 'ungate_model_shell_router'
        $context.Options.EnableProviderFallback | Should -BeFalse
    }
}

Describe 'Orchestration without production side effects' {
    BeforeEach {
        $script:events = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Launcher Get-CodexBetaPackageInfo { [pscustomobject]@{ ExecutablePath='test.exe' } }
        Mock -ModuleName Launcher Stop-CodexBeta { $script:events.Add('stop') }
        Mock -ModuleName Launcher Initialize-CodexDesktopTransport {
            param($Context)
            $script:events.Add("transport:$($Context.CustomCodexHome)")
            [pscustomobject]@{ProviderKeys=@{test='test-key'};SelectedKey='test-key';PreflightFailure=$null}
        }
        Mock -ModuleName Launcher Initialize-CodexDesktopProfile { param($Context) $script:events.Add("profile:$($Context.CustomCodexHome)") }
        Mock -ModuleName Launcher Start-CodexDesktopSession { param($Context) $script:events.Add("launch:$($Context.CustomCodexHome)") }
        Mock -ModuleName Launcher Write-Host {}
        Mock -ModuleName Launcher Write-CodexHistoryProfileDiagnostics {}
    }

    It 'prepares without closing or launching Desktop and returns zero' {
        Invoke-CodexDesktopLauncher -Context (New-TestContext @{PrepareOnly=$true}) | Should -Be 0
        Should -Invoke -ModuleName Launcher Stop-CodexBeta -Times 0
        Should -Invoke -ModuleName Launcher Start-CodexDesktopSession -Times 0
        Should -Invoke -ModuleName Launcher Initialize-CodexDesktopProfile -Times 1 -Exactly
    }

    It 'returns two after preparing with a preflight warning' {
        Mock -ModuleName Launcher Initialize-CodexDesktopTransport {
            [pscustomobject]@{ProviderKeys=@{};SelectedKey='test';PreflightFailure='upstream unavailable'}
        }
        Invoke-CodexDesktopLauncher -Context (New-TestContext @{PrepareOnly=$true}) | Should -Be 2
        Should -Invoke -ModuleName Launcher Initialize-CodexDesktopProfile -Times 1 -Exactly
        Should -Invoke -ModuleName Launcher Start-CodexDesktopSession -Times 0
    }

    It 'closes Desktop before transport preparation and launches after profile preparation' {
        $context = New-TestContext @{Model='grok-4.6';NoLogWatch=$true}
        Invoke-CodexDesktopLauncher -Context $context | Should -Be 0
        @($script:events) | Should -Be @('stop', "transport:$($context.CustomCodexHome)", "profile:$($context.CustomCodexHome)", "launch:$($context.CustomCodexHome)")
    }

    It 'keeps profile failure terminating and does not launch' {
        Mock -ModuleName Launcher Initialize-CodexDesktopProfile { throw 'profile rejected' }
        { Invoke-CodexDesktopLauncher -Context (New-TestContext @{Model='grok-4.6'}) } | Should -Throw '*profile rejected*'
        Should -Invoke -ModuleName Launcher Start-CodexDesktopSession -Times 0
    }

    It 'runs two complete preparations with independent contexts in one process' {
        $one = New-TestContext @{PrepareOnly=$true;Model='grok-4.6'} 'one'
        $two = New-TestContext @{PrepareOnly=$true;EnableProviderFallback=$true} 'two'
        Invoke-CodexDesktopLauncher -Context $one | Should -Be 0
        Invoke-CodexDesktopLauncher -Context $two | Should -Be 0
        @($script:events) | Should -Be @("transport:$($one.CustomCodexHome)", "profile:$($one.CustomCodexHome)", "transport:$($two.CustomCodexHome)", "profile:$($two.CustomCodexHome)")
        $one.Options.EnableProviderFallback | Should -BeFalse
        Test-Path -LiteralPath $one.CustomCodexHome | Should -BeFalse
        Test-Path -LiteralPath $two.CustomCodexHome | Should -BeFalse
    }
}

Describe 'Complete preparation on disposable profiles' {
    BeforeEach {
        $script:sourceHome = Join-Path $TestDrive 'normal'
        $null = New-Item -ItemType Directory -Path $script:sourceHome -Force
        [IO.File]::WriteAllText((Join-Path $script:sourceHome 'config.toml'), "sandbox_mode = 'danger-full-access'`n[mcp_servers.fixture]`ncommand = 'fixture-command'`n")
        [IO.File]::WriteAllText((Join-Path $script:sourceHome 'models_cache.json'), '{"models":[{"slug":"gpt-5.4","base_instructions":"Original identity\nKeep body"}]}')
        [IO.File]::WriteAllText((Join-Path $script:sourceHome 'AGENTS.md'), '# Fixture instructions')
        [IO.File]::WriteAllText((Join-Path $script:sourceHome 'auth.json'), '{}')
        Mock -ModuleName Launcher Get-CodexBetaPackageInfo { [pscustomobject]@{ExecutablePath='fixture.exe';BundledMarketplacePath='fixture-plugins';Version='1'} }
        Mock -ModuleName Launcher Get-CodexBetaProcesses { @() }
        Mock -ModuleName Launcher Stop-CodexBeta { throw 'Must not stop Desktop' }
        Mock -ModuleName Launcher Start-CodexBetaDesktop { throw 'Must not launch Desktop' }
        Mock -ModuleName Launcher Resolve-ModelApiKey { 'fixture-key' }
        Mock -ModuleName Launcher Ensure-CliProxyBridge {}
        Mock -ModuleName Launcher Ensure-CodexModelShellRouter {}
        Mock -ModuleName Launcher Invoke-CliProxyPreflight {}
        Mock -ModuleName Launcher Invoke-DesktopOmniRoutePreflight {}
        Mock -ModuleName Launcher Get-CodexCliExecutable { 'fixture.exe' }
        Mock -ModuleName Profile Get-CodexCliExecutable { 'fixture.exe' }
        Mock -ModuleName Profile Test-CodexMcpConfiguration { @('fixture', 'ungate_patch') }
        Mock -ModuleName Catalog Get-CodexCliExecutable { $null }
        Mock -ModuleName Catalog Invoke-RestMethod { @{data=@()} }
        Mock -ModuleName Launcher Initialize-CodexBetaPluginIsolation {
            [pscustomobject]@{Changed=$false;PluginIds=@();BrowserSha256='fixture';UnsupportedBundledPluginIds=@()}
        }
    }

    It 'keeps cross-module authentication copy failures terminating' {
        $context = New-TestContext @{} 'missing-parent/target'
        $context.DefaultCodexHome = $script:sourceHome
        {
            & {
                $ErrorActionPreference = 'Stop'
                Sync-CodexAuthentication -Context $context
            }
        } | Should -Throw
    }

    It 'writes and validates the complete <Mode> profile without live services' -ForEach @(
        @{Mode='router';Options=@{PrepareOnly=$true;Model='grok-4.6'};ExpectedProvider='ungate_model_shell_router';ExpectedCount=7;ExpectedModel='gpt-5.5'},
        @{Mode='fallback';Options=@{PrepareOnly=$true;EnableProviderFallback=$true};ExpectedProvider='omniroute';ExpectedCount=11;ExpectedModel='codex-fallback'}
    ) {
        $context = New-TestContext $Options $Mode
        $context.DefaultCodexHome = $script:sourceHome
        $context.DefaultConfigPath = Join-Path $script:sourceHome 'config.toml'
        $context.DefaultModelCachePath = Join-Path $script:sourceHome 'models_cache.json'
        $originalConfigHash = (Get-FileHash -LiteralPath $context.DefaultConfigPath).Hash
        Invoke-CodexDesktopLauncher -Context $context | Should -Be 0
        $config = Get-Content -LiteralPath $context.CustomConfigPath -Raw
        $config | Should -Match ('(?m)^model = "' + $ExpectedModel + '"')
        $config | Should -Match ('(?m)^model_provider = "' + $ExpectedProvider + '"')
        $config | Should -Match '\[mcp_servers.fixture\]'
        $config | Should -Match '\[mcp_servers.ungate_patch\]'
        $catalog = Get-Content -LiteralPath $context.CustomModelCatalogPath -Raw | ConvertFrom-Json -Depth 100
        $catalog.models.Count | Should -Be $ExpectedCount
        @($catalog.models | Where-Object { -not $_.base_instructions.EndsWith('Keep body') }).Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $context.CustomCodexHome 'AGENTS.md') -Raw | Should -BeExactly '# Fixture instructions'
        Get-Content -LiteralPath (Join-Path $context.CustomCodexHome 'auth.json') -Raw | Should -BeExactly '{}'
        (Get-FileHash -LiteralPath $context.DefaultConfigPath).Hash | Should -Be $originalConfigHash
        Should -Invoke -ModuleName Launcher Stop-CodexBeta -Times 0
        Should -Invoke -ModuleName Launcher Start-CodexBetaDesktop -Times 0
    }
}

Describe 'Transport preparation policies' {
    BeforeEach {
        $script:context = New-TestContext @{Model='grok-4.6'}
        $script:selection = Get-TestSelection $script:context
        Mock -ModuleName Launcher Resolve-ModelApiKey { 'test-key' }
        Mock -ModuleName Launcher Ensure-CliProxyBridge {}
        Mock -ModuleName Launcher Ensure-CodexModelShellRouter {}
        Mock -ModuleName Launcher Invoke-CliProxyPreflight {}
        Mock -ModuleName Launcher Invoke-UngatePreflight {}
        Mock -ModuleName Launcher Invoke-DesktopOmniRoutePreflight {}
        Mock -ModuleName Launcher Start-Sleep {}
        Mock -ModuleName Launcher Write-Host {}
    }

    It 'retries normal preflight once and retains failure as a warning' {
        Mock -ModuleName Launcher Invoke-CliProxyPreflight { throw 'offline' }
        $result = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $script:context $script:selection
        $result.PreflightFailure.Exception.Message | Should -Be 'offline'
        Should -Invoke -ModuleName Launcher Invoke-CliProxyPreflight -Times 2 -Exactly
        Should -Invoke -ModuleName Launcher Ensure-CodexModelShellRouter -Times 1 -Exactly
    }

    It 'does not retry fallback preflight or start the shell router in fallback mode' {
        $context = New-TestContext @{EnableProviderFallback=$true;PrepareOnly=$true}
        $selection = Get-TestSelection $context
        Mock -ModuleName Launcher Invoke-DesktopOmniRoutePreflight { throw 'offline' }
        $result = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $context $selection
        $result.PreflightFailure.Exception.Message | Should -Be 'offline'
        Should -Invoke -ModuleName Launcher Invoke-DesktopOmniRoutePreflight -Times 1 -Exactly
        Should -Invoke -ModuleName Launcher Ensure-CodexModelShellRouter -Times 0
    }

    It 'passes an explicit key only to the selected provider' {
        $script:context.Options.ApiKey = 'explicit-test-key'
        $null = & (Get-Module Launcher) { param($c,$s) Initialize-CodexDesktopTransport -Context $c -Selection $s } $script:context $script:selection
        Should -Invoke -ModuleName Launcher Resolve-ModelApiKey -Times 1 -Exactly -ParameterFilter { $Definition.ProviderName -eq 'cliproxyapi' -and $ApiKey -eq 'explicit-test-key' }
        Should -Invoke -ModuleName Launcher Resolve-ModelApiKey -Times 2 -Exactly -ParameterFilter { $Definition.ProviderName -ne 'cliproxyapi' -and -not $ApiKey }
    }
}

Describe 'Desktop OmniRoute preflight remains distinct' {
    It 'uses a discovered DeepSeek alias and 512 output tokens' -ForEach @('deepseek/deepseek-v4-pro', 'ds/deepseek-v4-pro') {
        $script:alias = $_
        Mock -ModuleName ProxyRuntime Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/api/health/ping') { return @{status='ok'} }
            return @{data=@(@{id=$script:alias})}
        }
        Mock -ModuleName ProxyRuntime Invoke-WebRequest { @{StatusCode=200;Content='{"id":"response-test"}'} }
        Invoke-DesktopOmniRoutePreflight -Key 'test' -Model 'deepseek-v4-pro' -ProxyBaseUrl 'http://test'
        Should -Invoke -ModuleName ProxyRuntime Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $payload = $Body | ConvertFrom-Json
            $payload.model -eq $script:alias -and $payload.max_output_tokens -eq 512
        }
    }
}

Describe 'Runtime process ownership guards' {
    BeforeEach {
        $script:context = New-TestContext
        $script:selection = Get-TestSelection (New-TestContext @{Model='grok-4.6'})
        Mock -ModuleName ProxyRuntime Invoke-RestMethod { @{data=@()} }
        Mock -ModuleName ProxyRuntime Test-LocalTcpListener { $true }
        Mock -ModuleName ProxyRuntime Stop-Process { throw 'Must not stop any process' }
        Mock -ModuleName ProxyRuntime Start-Process { throw 'Must not launch any process' }
    }

    It 'refuses an unrelated HTTP service on the bridge port' {
        Mock -ModuleName ProxyRuntime Get-CliProxyBridgeHealth { @{status='ok';service='foreign';pid=123} }
        { Ensure-CliProxyBridge -Context $script:context -Key 'test' } | Should -Throw '*unexpected HTTP service*'
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 0
    }

    It 'refuses a stale bridge whose reported PID belongs to another command' {
        Mock -ModuleName ProxyRuntime Get-CliProxyBridgeHealth { @{status='ok';service='cliproxy-namespace-bridge';pid=123;build_id='old';upstream='http://old'} }
        Mock -ModuleName ProxyRuntime Test-CliProxyBridgeProcessIdentity { $false }
        { Ensure-CliProxyBridge -Context $script:context -Key 'test' } | Should -Throw '*Refusing to stop it*'
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 0
    }

    It 'refuses an unidentified listener on the router port' {
        Mock -ModuleName ProxyRuntime Get-CodexModelShellRouterHealth { $null }
        { Ensure-CodexModelShellRouter -Context $script:context -Selection $script:selection -Routes @(@{clientModel='test'}) -ProviderKeys @{} } | Should -Throw '*occupied*'
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 0
    }

    It 'refuses a router PID with mismatching process identity' {
        Mock -ModuleName ProxyRuntime Get-CodexModelShellRouterHealth { @{status='ok';service='codex-model-shell-router';pid=123} }
        Mock -ModuleName ProxyRuntime Test-CodexModelShellRouterProcessIdentity { $false }
        { Ensure-CodexModelShellRouter -Context $script:context -Selection $script:selection -Routes @(@{clientModel='test'}) -ProviderKeys @{} } | Should -Throw '*Refusing to stop it*'
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 0
    }
}

Describe 'Transport startup failures' {
    BeforeEach {
        $script:context = New-TestContext
        $script:selection = Get-TestSelection (New-TestContext @{Model='grok-4.6'})
        $script:process = [pscustomobject]@{ Id=987; HasExited=$true; ExitCode=23 }
        $script:process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
        Mock -ModuleName ProxyRuntime Test-LocalTcpListener { $false }
        Mock -ModuleName ProxyRuntime Invoke-RestMethod { @{data=@()} }
        Mock -ModuleName ProxyRuntime Get-CliProxyBridgeHealth { $null }
        Mock -ModuleName ProxyRuntime Get-CodexModelShellRouterHealth { $null }
        Mock -ModuleName ProxyRuntime New-Item {}
        Mock -ModuleName ProxyRuntime Remove-Item {}
        Mock -ModuleName ProxyRuntime Start-Sleep {}
        Mock -ModuleName ProxyRuntime Get-Content { 'fixture startup error' }
        Mock -ModuleName ProxyRuntime Start-Process { $script:process }
        Mock -ModuleName ProxyRuntime Stop-Process {}
    }

    It 'reports a bridge process that exits during startup' {
        { Ensure-CliProxyBridge -Context $script:context -Key 'test' } | Should -Throw '*exited with code 23*'
        Should -Invoke -ModuleName ProxyRuntime Start-Process -Times 1 -Exactly
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 0
    }

    It 'reports a router process that exits during startup' {
        { Ensure-CodexModelShellRouter -Context $script:context -Selection $script:selection -Routes @(@{clientModel='test'}) -ProviderKeys @{ungate_proxy='a';cliproxyapi='b';omniroute='c'} } | Should -Throw '*exited with code 23*'
        Should -Invoke -ModuleName ProxyRuntime Start-Process -Times 1 -Exactly
    }

    It 'stops only its newly launched bridge after a failed readiness check' {
        $script:process.HasExited = $false
        Mock -ModuleName ProxyRuntime Get-CliProxyBridgeHealth { @{status='wrong';service='foreign'} }
        { Ensure-CliProxyBridge -Context $script:context -Key 'test' } | Should -Throw '*failed its startup health check*'
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 987 }
    }

    It 'stops only its newly launched router after a route readiness mismatch' {
        $script:process.HasExited = $false
        Mock -ModuleName ProxyRuntime Get-CodexModelShellRouterHealth { @{status='ok';service='codex-model-shell-router';route_models=@('wrong')} }
        { Ensure-CodexModelShellRouter -Context $script:context -Selection $script:selection -Routes @(@{clientModel='test'}) -ProviderKeys @{ungate_proxy='a';cliproxyapi='b';omniroute='c'} } | Should -Throw '*failed its startup health check*'
        Should -Invoke -ModuleName ProxyRuntime Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 987 }
    }
}

Describe 'Desktop package launch fallback' {
    BeforeEach {
        $script:context = New-TestContext
        $script:package = [pscustomobject]@{ExecutablePath='fixture.exe'}
        Mock -ModuleName Desktop Start-Process {}
        Mock -ModuleName Desktop Start-CodexBetaPackageDesktop {}
    }

    It 'does not enter MSIX fallback after a successful direct launch' {
        Start-CodexBetaDesktop -Context $script:context -PackageInfo $script:package -LaunchEnvironment @{CODEX_HOME='fixture-home'} -WorkingDirectory $TestDrive
        Should -Invoke -ModuleName Desktop Start-CodexBetaPackageDesktop -Times 0
        Should -Invoke -ModuleName Desktop Start-Process -Times 1 -Exactly -ParameterFilter { $Environment.CODEX_HOME -eq 'fixture-home' }
    }

    It 'passes the same environment and package to the MSIX fallback' {
        Mock -ModuleName Desktop Start-Process { throw 'direct launch denied' }
        Start-CodexBetaDesktop -Context $script:context -PackageInfo $script:package -LaunchEnvironment @{CODEX_HOME='fixture-home';OMNIROUTE_API_KEY='fake-key'} -WorkingDirectory $TestDrive
        Should -Invoke -ModuleName Desktop Start-CodexBetaPackageDesktop -Times 1 -Exactly -ParameterFilter { $LaunchEnvironment.CODEX_HOME -eq 'fixture-home' -and $LaunchEnvironment.OMNIROUTE_API_KEY -eq 'fake-key' -and $PackageInfo.ExecutablePath -eq 'fixture.exe' }
    }

    It 'retains both direct and MSIX errors when fallback fails' {
        Mock -ModuleName Desktop Start-Process { throw 'direct launch denied' }
        Mock -ModuleName Desktop Start-CodexBetaPackageDesktop { throw 'package launch denied' }
        { Start-CodexBetaDesktop -Context $script:context -PackageInfo $script:package -LaunchEnvironment @{} -WorkingDirectory $TestDrive } | Should -Throw '*Direct Codex Beta launch failed (direct launch denied). MSIX package launch also failed: package launch denied*'
    }
}

Describe 'Desktop performance configuration' {
    It 'provides anti-throttling flags and V8 heap expansion without experimental zero-copy' {
        $arguments = @(Get-CodexPerformanceArguments)
        $arguments | Should -Contain '--disable-renderer-backgrounding'
        $arguments | Should -Contain '--disable-backgrounding-occluded-windows'
        $arguments | Should -Contain '--disable-background-timer-throttling'
        $arguments | Should -Contain '--disable-features=CalculateNativeWinOcclusion,IntensiveWakeUpThrottling'
        $arguments | Should -Contain '--enable-gpu-rasterization'
        $arguments | Should -Not -Contain '--enable-zero-copy'
        ($arguments -match 'max-old-space-size=8192').Count | Should -BeGreaterThan 0
    }

    It 'passes performance arguments and optimizes priority on direct launch' {
        $context = New-TestContext
        $package = [pscustomobject]@{ExecutablePath='fixture.exe'}
        Mock -ModuleName Desktop Start-Process {}
        Mock -ModuleName Desktop Optimize-CodexBetaPriority {}
        Start-CodexBetaDesktop -Context $context -PackageInfo $package -LaunchEnvironment @{CODEX_HOME='fixture-home'} -WorkingDirectory $TestDrive
        Should -Invoke -ModuleName Desktop Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains '--disable-renderer-backgrounding' -and $ArgumentList -contains '--disable-background-timer-throttling'
        }
        Should -Invoke -ModuleName Desktop Optimize-CodexBetaPriority -Times 1 -Exactly -ParameterFilter {
            $ExecutablePath -eq 'fixture.exe'
        }
    }
}

Describe 'Session logging precedence' {
    BeforeEach {
        Mock -ModuleName Launcher Start-CodexBetaDesktop {}
        Mock -ModuleName Launcher Write-UngateLogSettings {}
        Mock -ModuleName Launcher Read-UngateLogSettings { [pscustomobject]@{LogLevel='Compact'} }
        Mock -ModuleName Launcher Watch-CodexActivity {}
        Mock -ModuleName Launcher Write-Host {}
    }

    It 'honors NoLogWatch before explicit logging and does not rewrite settings' {
        $context = New-TestContext @{Model='grok-4.6';NoLogWatch=$true;LogLevel='Full'}
        $selection = Get-TestSelection $context
        & (Get-Module Launcher) { param($c,$s) Start-CodexDesktopSession -Context $c -Selection $s -codexBeta ([pscustomobject]@{ExecutablePath='test.exe'}) -providerKeys @{} } $context $selection
        Should -Invoke -ModuleName Launcher Watch-CodexActivity -Times 0
        Should -Invoke -ModuleName Launcher Write-UngateLogSettings -Times 0
    }

    It 'uses the explicit log level instead of saved settings' {
        $context = New-TestContext @{Model='grok-4.6';LogLevel='Full'}
        $selection = Get-TestSelection $context
        & (Get-Module Launcher) { param($c,$s) Start-CodexDesktopSession -Context $c -Selection $s -codexBeta ([pscustomobject]@{ExecutablePath='test.exe'}) -providerKeys @{} } $context $selection
        Should -Invoke -ModuleName Launcher Watch-CodexActivity -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Full' }
        Should -Invoke -ModuleName Launcher Read-UngateLogSettings -Times 0
    }

    It 'uses saved settings when explicit LogLevel is empty' {
        $context = New-TestContext @{Model='grok-4.6';LogLevel=''}
        $selection = Get-TestSelection $context
        & (Get-Module Launcher) { param($c,$s) Start-CodexDesktopSession -Context $c -Selection $s -codexBeta ([pscustomobject]@{ExecutablePath='test.exe'}) -providerKeys @{} } $context $selection
        Should -Invoke -ModuleName Launcher Watch-CodexActivity -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Compact' }
    }

    It 'does not watch when logging is Off' {
        $context = New-TestContext @{Model='grok-4.6';LogLevel='Off'}
        $selection = Get-TestSelection $context
        & (Get-Module Launcher) { param($c,$s) Start-CodexDesktopSession -Context $c -Selection $s -codexBeta ([pscustomobject]@{ExecutablePath='test.exe'}) -providerKeys @{} } $context $selection
        Should -Invoke -ModuleName Launcher Watch-CodexActivity -Times 0
    }
}

Describe 'Environment restoration on failure' {
    It 'restores CODEX_HOME and provider keys after config validation throws' {
        Import-Module (Join-Path $script:moduleRoot 'Catalog.psm1') -DisableNameChecking
        $context = New-TestContext @{Model='grok-4.6'}
        $selection = Get-TestSelection $context
        $context.DefaultModelCachePath = Join-Path $TestDrive 'model-template.json'
        $context.CustomModelCatalogPath = Join-Path $TestDrive 'model-catalog.json'
        $context.CustomConfigPath = Join-Path $TestDrive 'config.toml'
        [IO.File]::WriteAllText($context.DefaultModelCachePath, '{"models":[{"slug":"gpt-5.4","base_instructions":"Original identity\nKeep body"}]}')
        [IO.File]::WriteAllText($context.CustomConfigPath, 'model = "old"')
        Write-UngateModelCatalog -Context $context -Selection $selection
        $script:failingCli = Join-Path $PSScriptRoot 'fixtures/failing-cli.ps1'
        Mock -ModuleName Catalog Get-CodexCliExecutable { $script:failingCli }
        Mock -ModuleName Catalog Invoke-RestMethod { @{data=@()} }
        Mock -ModuleName Catalog Write-Host {}
        $previous = @{}
        foreach ($name in @('CODEX_HOME','UNGATE_API_KEY','CLIPROXYAPI_API_KEY','OMNIROUTE_API_KEY')) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $env:CODEX_HOME = 'original-home'
            $env:UNGATE_API_KEY = 'original-ungate'
            $env:CLIPROXYAPI_API_KEY = 'original-cliproxy'
            Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
            { Assert-UngateCodexConfig -Context $context -Selection $selection -Key 'test' -ProviderKeys @{ungate_proxy='a';cliproxyapi='b';omniroute='c'} } | Should -Throw '*fixture CLI rejected config*'
            $env:CODEX_HOME | Should -Be 'original-home'
            $env:UNGATE_API_KEY | Should -Be 'original-ungate'
            $env:CLIPROXYAPI_API_KEY | Should -Be 'original-cliproxy'
            Test-Path Env:\OMNIROUTE_API_KEY | Should -BeFalse
        }
        finally {
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }

    It 'restores CODEX_HOME when MCP CLI execution fails' {
        $previous = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = 'previous-test-home'
            {
                & (Get-Module Profile) {
                    Test-CodexMcpConfiguration -CodexExecutable 'missing-test-command.exe' -CodexHome 'new-test-home'
                }
            } | Should -Throw '*missing-test-command.exe*'
            $env:CODEX_HOME | Should -Be 'previous-test-home'
        }
        finally {
            if ($null -eq $previous) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
            else { $env:CODEX_HOME = $previous }
        }
    }

    It 'restores an absent CODEX_HOME after sandbox CLI failure' {
        $previous = $env:CODEX_HOME
        $context = New-TestContext
        Mock -ModuleName Desktop Get-Content { 'sandbox_mode = "workspace-write"' }
        Mock -ModuleName Desktop Get-CodexCliExecutable { 'missing-test-command.exe' }
        try {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
            { Initialize-CodexWindowsSandbox -Context $context } | Should -Throw
            Test-Path Env:\CODEX_HOME | Should -BeFalse
        }
        finally {
            if ($null -eq $previous) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
            else { $env:CODEX_HOME = $previous }
        }
    }
}
