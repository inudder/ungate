BeforeAll {
    $script:launcherPath = Join-Path $PSScriptRoot 'start-codex-desktop-ungate.ps1'
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Context.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Models.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Picker.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Routing.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Logging.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Toml.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Profile.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Catalog.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Desktop.psm1') -DisableNameChecking -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Launcher.psm1') -DisableNameChecking -ErrorAction Stop

    function New-McpSyncTestHomes {
        param([Parameter(Mandatory = $true)][string]$Root)

        $testRoot = Join-Path $Root ([guid]::NewGuid().ToString('N'))
        $sourceCodexHome = Join-Path $testRoot 'source'
        $targetCodexHome = Join-Path $testRoot 'target'
        New-Item -ItemType Directory -Path $sourceCodexHome -Force | Out-Null
        New-Item -ItemType Directory -Path $targetCodexHome -Force | Out-Null
        return [pscustomobject]@{
            SourceCodexHome = $sourceCodexHome
            TargetCodexHome = $targetCodexHome
            SourceConfigPath = Join-Path $sourceCodexHome 'config.toml'
            TargetConfigPath = Join-Path $targetCodexHome 'config.toml'
        }
    }

    function Write-Utf8TestFile {
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [Parameter(Mandatory = $true)][string]$Content
        )

        [System.IO.File]::WriteAllText(
            $LiteralPath,
            $Content,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    function New-CustomModelTestRecord {
        param(
            [string]$Slug = 'ungate-opus-5',
            [string]$DisplayName = 'Claude Opus 5 (Ungate)',
            [string]$UpstreamModel = 'claude-opus-5',
            [string]$Transport = 'ungate',
            [string]$ReasoningLevel = 'high',
            [bool]$SupportsImageInput = $true
        )

        return [pscustomobject][ordered]@{
            Slug = $Slug
            DisplayName = $DisplayName
            UpstreamModel = $UpstreamModel
            Transport = $Transport
            DefaultReasoningLevel = $ReasoningLevel
            SupportsImageInput = $SupportsImageInput
        }
    }
}

Describe 'Desktop launcher modules' {
BeforeEach {
    $script:Context = New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive 'isolated-home')
    $script:Selection = [pscustomobject]@{
        Definitions = @()
        EnableProviderFallback = $false
        FallbackDefinition = (New-UngateModelSet -Context $script:Context).FallbackDefinition
        LaunchModel = $null
        LaunchProvider = $null
        SelectedModel = $null
    }
}

Describe 'Optional OmniRoute provider fallback' {
    BeforeEach {
        $script:Context.OmniRouteProviderName = 'omniroute'
        $script:Context.RepoRoot = $TestDrive
        $script:Selection.EnableProviderFallback = $false
        $script:Context.CodexModelShellRouterProviderDefinition = [pscustomobject][ordered]@{
            Name = 'ungate_model_shell_router'
            DisplayName = 'Ungate Codex Model Router'
            ProxyBaseUrl = 'http://127.0.0.1:8319'
            EnvKey = 'UNGATE_API_KEY'
        }
        $script:previousOmniRouteApiKey = $env:OMNIROUTE_API_KEY
        $script:previousOmniRouteCodexApiKey = $env:OMNIROUTE_CODEX_API_KEY
        Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\OMNIROUTE_CODEX_API_KEY -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:previousOmniRouteApiKey) {
            Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:OMNIROUTE_API_KEY = $script:previousOmniRouteApiKey
        }
        if ($null -eq $script:previousOmniRouteCodexApiKey) {
            Remove-Item Env:\OMNIROUTE_CODEX_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:OMNIROUTE_CODEX_API_KEY = $script:previousOmniRouteCodexApiKey
        }
    }

    It 'prefers an explicit key, then the Codex client key, then the legacy environment key' {
        $env:OMNIROUTE_API_KEY = 'master-key'
        $env:OMNIROUTE_CODEX_API_KEY = 'codex-client-key'
        $definition = [pscustomobject]@{ ProviderName = 'omniroute'; RequiresUngate = $false }

        Resolve-ModelApiKey -Context $script:Context -Definition $definition -ApiKey 'argument-key' |
            Should -BeExactly 'argument-key'
        Resolve-ModelApiKey -Context $script:Context -Definition $definition |
            Should -BeExactly 'codex-client-key'

        Remove-Item Env:\OMNIROUTE_CODEX_API_KEY
        Resolve-ModelApiKey -Context $script:Context -Definition $definition |
            Should -BeExactly 'master-key'
    }

    It 'fails clearly when no OmniRoute client key is configured' {
        $definition = [pscustomobject]@{ ProviderName = 'omniroute'; RequiresUngate = $false }

        { Resolve-ModelApiKey -Context $script:Context -Definition $definition } |
            Should -Throw '*set OMNIROUTE_CODEX_API_KEY*OMNIROUTE_API_KEY*'
    }

    It 'does not add OmniRoute to active providers without the switch' {
        $script:Selection.Definitions = @(
            [pscustomobject]@{
                ProviderName = 'ungate_proxy'
                ProviderDisplayName = 'Ungate Proxy'
                ProxyBaseUrl = 'http://127.0.0.1:47821'
                EnvKey = 'UNGATE_API_KEY'
            }
        )

        @((Get-ProviderDefinitions -Selection $script:Selection).Name) | Should -Be @('ungate_proxy')
        @((Get-CodexConfigProviderDefinitions -Context $script:Context -Selection $script:Selection).Name) | Should -Be @('ungate_model_shell_router')
    }

    It 'keeps OmniRoute as the only active provider in fallback mode' {
        $script:Selection.EnableProviderFallback = $true
        $script:Selection.FallbackDefinition = [pscustomobject][ordered]@{
            ProviderName = 'omniroute'
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = 'http://127.0.0.1:20128'
            EnvKey = 'OMNIROUTE_API_KEY'
        }

        @((Get-CodexConfigProviderDefinitions -Context $script:Context -Selection $script:Selection).Name) | Should -Be @('omniroute')
    }

    It 'rejects an explicit model together with provider fallback' {
        $customHome = Join-Path $TestDrive 'fallback-conflict-home'
        $powerShellExecutable = (Get-Command pwsh -ErrorAction Stop).Source
        $arguments = @(
            '-NoProfile',
            '-File', $script:launcherPath,
            '-EnableProviderFallback',
            '-Model', 'grok-4.7',
            '-CustomCodexHome', $customHome
        )

        $output = @(& $powerShellExecutable @arguments 2>&1)

        $LASTEXITCODE | Should -Not -Be 0
        $output -join "`n" | Should -Match 'EnableProviderFallback cannot be combined with -Model'
    }
}

Describe 'Launcher context window labels' {
    It 'uses the Codex default when a model omits ContextWindow' {
        $window = Get-UngateModelContextWindow -Definition ([pscustomobject]@{ Slug = 'ungate-fable-5' })

        $window.ContextWindow | Should -Be 200000
        $window.MaxContextWindow | Should -Be 200000
        $window.EffectiveContextWindowPercent | Should -Be 100
        $window.Label | Should -BeExactly '200k'
    }

    It 'formats official 1M and 500k windows' {
        $minimax = Get-UngateModelContextWindow -Definition ([pscustomobject]@{
            ContextWindow = 1000000
            MaxContextWindow = 1000000
        })
        $grok = Get-UngateModelContextWindow -Definition ([pscustomobject]@{
            ContextWindow = 500000
            MaxContextWindow = 500000
        })

        $minimax.Label | Should -BeExactly '1M'
        $grok.Label | Should -BeExactly '500k'
    }

    It 'shows a squeeze percent when the catalog is not 100%' {
        $window = Get-UngateModelContextWindow -Definition ([pscustomobject]@{
            ContextWindow = 1048576
            MaxContextWindow = 1048576
            EffectiveContextWindowPercent = 95
        })

        $window.Label | Should -BeExactly '1048576 @ 95%'
    }
}

Describe 'Custom launcher model registry' {
    BeforeEach {
        $script:Context.UngateEnvironmentInstruction = 'Test environment instructions.'
        $script:Context.ProviderName = 'ungate_proxy'
        $script:Context.ProxyBaseUrl = 'http://127.0.0.1:47821'
        $script:Context.CliProxyProviderName = 'cliproxyapi'
        $script:Context.CliProxyBaseUrl = 'http://127.0.0.1:8318'
        $script:Context.OmniRouteProviderName = 'omniroute'
        $script:Context.OmniRouteBaseUrl = 'http://127.0.0.1:20128'
        $script:Context.CodexModelShellRouterProviderName = 'ungate_model_shell_router'
        $script:Context.CodexModelShellRouterBaseUrl = 'http://127.0.0.1:8319'
        $script:Context.CodexModelShellRouterProviderDefinition = [pscustomobject][ordered]@{
            Name = $script:Context.CodexModelShellRouterProviderName
            DisplayName = 'Ungate Codex Model Router'
            ProxyBaseUrl = $script:Context.CodexModelShellRouterBaseUrl
            EnvKey = 'UNGATE_API_KEY'
        }
        $script:Context.CodexModelShellPool = @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
        $script:Context.CodexDesktopPickerCapacity = 3
        $script:Selection.EnableProviderFallback = $false
        $script:builtInDefinitions = @(
            [pscustomobject][ordered]@{
                Slug = 'ungate-opus-4-8'
                DisplayName = 'Claude Opus 4.8 (Ungate)'
                Priority = 0
            }
            [pscustomobject][ordered]@{
                Slug = 'grok-4.7'
                DisplayName = 'Grok 4.7 (CLIProxyAPI)'
                Priority = 1
            }
        )
        $script:registryPath = Join-Path $TestDrive 'ungate-model-definitions.json'
        $script:pickerSettingsPath = Join-Path $TestDrive 'ungate-picker-models.json'
    }

    It 'returns only built-in definitions when the registry does not exist' {
        $definitions = @(
            Get-UngateModelDefinitions -Context $script:Context `
                -BuiltInDefinitions $script:builtInDefinitions `
                -RegistryPath $script:registryPath
        )

        $definitions | Should -HaveCount 2
        @($definitions.Slug) | Should -Be @('ungate-opus-4-8', 'grok-4.7')
    }

    It 'round-trips a versioned registry without losing persisted fields' {
        $record = New-CustomModelTestRecord

        $savedPath = Write-UngateCustomModelDefinitions -Context $script:Context `
            -RegistryPath $script:registryPath `
            -Records @($record) `
            -BuiltInDefinitions $script:builtInDefinitions
        $savedPath | Should -BeExactly ([System.IO.Path]::GetFullPath($script:registryPath))

        $registry = Get-Content -LiteralPath $script:registryPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20
        $registry.Version | Should -Be 1
        @($registry.Models) | Should -HaveCount 1
        $registry.Models[0].Slug | Should -BeExactly 'ungate-opus-5'
        $registry.Models[0].DisplayName | Should -BeExactly 'Claude Opus 5 (Ungate)'
        $registry.Models[0].UpstreamModel | Should -BeExactly 'claude-opus-5'
        $registry.Models[0].Transport | Should -BeExactly 'ungate'
        $registry.Models[0].DefaultReasoningLevel | Should -BeExactly 'high'
        $registry.Models[0].SupportsImageInput | Should -BeTrue

        $definitions = @(
            Read-UngateCustomModelDefinitions -Context $script:Context `
                -RegistryPath $script:registryPath `
                -BuiltInDefinitions $script:builtInDefinitions
        )
        $definitions | Should -HaveCount 1
        $definitions[0].UpstreamModel | Should -BeExactly 'claude-opus-5'
        $definitions[0].Transport | Should -BeExactly 'ungate'
        $definitions[0].SupportsImageInput | Should -BeTrue
    }

    It 'appends custom definitions after built-ins with sequential priorities' {
        $records = @(
            New-CustomModelTestRecord
            New-CustomModelTestRecord `
                -Slug 'custom-text-model' `
                -DisplayName 'Custom Text Model' `
                -UpstreamModel 'upstream-text-model' `
                -Transport 'cliproxyapi' `
                -ReasoningLevel 'medium' `
                -SupportsImageInput $false
        )
        $null = Write-UngateCustomModelDefinitions -Context $script:Context `
            -RegistryPath $script:registryPath `
            -Records $records `
            -BuiltInDefinitions $script:builtInDefinitions

        $definitions = @(
            Get-UngateModelDefinitions -Context $script:Context `
                -BuiltInDefinitions $script:builtInDefinitions `
                -RegistryPath $script:registryPath
        )

        $definitions | Should -HaveCount 4
        @($definitions.Slug) | Should -Be @(
            'ungate-opus-4-8',
            'grok-4.7',
            'ungate-opus-5',
            'custom-text-model'
        )
        $definitions[2].Priority | Should -Be 2
        $definitions[3].Priority | Should -Be 3
        @($definitions[3].InputModalities) | Should -Be @('text')
        $definitions[3].WebSearchToolType | Should -BeExactly 'text'
    }

    It 'rejects empty, whitespace-containing, and duplicate model IDs' {
        {
            ConvertTo-UngateModelDefinition -Context $script:Context `
                -Record (New-CustomModelTestRecord -Slug '') `
                -Priority 2
        } | Should -Throw '*cannot be empty*'
        {
            ConvertTo-UngateModelDefinition -Context $script:Context `
                -Record (New-CustomModelTestRecord -Slug 'bad model') `
                -Priority 2
        } | Should -Throw '*cannot contain whitespace*'
        {
            Write-UngateCustomModelDefinitions -Context $script:Context `
                -RegistryPath $script:registryPath `
                -Records @(
                    New-CustomModelTestRecord -Slug 'UNGATE-OPUS-4-8'
                ) `
                -BuiltInDefinitions $script:builtInDefinitions
        } | Should -Throw '*duplicates an existing model*'
    }

    It 'rejects unsupported transports and reasoning levels' {
        {
            ConvertTo-UngateModelDefinition -Context $script:Context `
                -Record (New-CustomModelTestRecord -Transport 'unknown') `
                -Priority 2
        } | Should -Throw '*unsupported transport*'
        {
            ConvertTo-UngateModelDefinition -Context $script:Context `
                -Record (New-CustomModelTestRecord -ReasoningLevel 'extreme') `
                -Priority 2
        } | Should -Throw '*unsupported reasoning level*'
    }

    It 'preserves the existing registry and leaves no temporary file after validation fails' {
        $null = Write-UngateCustomModelDefinitions -Context $script:Context `
            -RegistryPath $script:registryPath `
            -Records @((New-CustomModelTestRecord)) `
            -BuiltInDefinitions $script:builtInDefinitions
        $beforeHash = (Get-FileHash -LiteralPath $script:registryPath -Algorithm SHA256).Hash

        {
            Write-UngateCustomModelDefinitions -Context $script:Context `
                -RegistryPath $script:registryPath `
                -Records @(
                    New-CustomModelTestRecord
                    New-CustomModelTestRecord -Slug 'UNGATE-OPUS-5'
                ) `
                -BuiltInDefinitions $script:builtInDefinitions
        } | Should -Throw '*duplicates an existing model*'

        (Get-FileHash -LiteralPath $script:registryPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp' -File) | Should -HaveCount 0
    }

    It 'generates the expected Ungate launcher definition for Claude Opus 5' {
        $definition = ConvertTo-UngateModelDefinition -Context $script:Context `
            -Record (New-CustomModelTestRecord) `
            -Priority 2

        $definition.Slug | Should -BeExactly 'ungate-opus-5'
        $definition.ProviderName | Should -BeExactly 'ungate_proxy'
        $definition.ProxyBaseUrl | Should -BeExactly 'http://127.0.0.1:47821'
        $definition.EnvKey | Should -BeExactly 'UNGATE_API_KEY'
        $definition.RequiresUngate | Should -BeTrue
        @($definition.InputModalities) | Should -Be @('text', 'image')
        $definition.SupportsImageDetailOriginal | Should -BeTrue
        $definition.WebSearchToolType | Should -BeExactly 'text_and_image'
        $definition.Description | Should -Match 'claude-opus-5'
        # Anthropic-prefixed models skip the Codex self-identification layer;
        # Identity is just the shared environment instruction.
        $definition.Identity | Should -Match 'environment instructions'
        $definition.Identity | Should -Not -Match 'GPT model'
    }

    It 'generates the expected OmniRoute launcher definition for a custom model' {
        $definition = ConvertTo-UngateModelDefinition -Context $script:Context `
            -Record (New-CustomModelTestRecord -Slug 'custom-ds' -DisplayName 'Custom DeepSeek (OmniRoute)' -UpstreamModel 'deepseek/deepseek-v4-pro' -Transport 'omniroute' -SupportsImageInput $false) `
            -Priority 3

        $definition.Slug | Should -BeExactly 'custom-ds'
        $definition.ProviderName | Should -BeExactly 'omniroute'
        $definition.ProxyBaseUrl | Should -BeExactly 'http://127.0.0.1:20128'
        $definition.EnvKey | Should -BeExactly 'OMNIROUTE_API_KEY'
        $definition.RequiresUngate | Should -BeFalse
        @($definition.InputModalities) | Should -Be @('text')
        $definition.SupportsImageDetailOriginal | Should -BeFalse
        $definition.WebSearchToolType | Should -BeExactly 'text'
        $definition.Description | Should -Match 'the local OmniRoute proxy'
    }

    It 'runs the AddModel wizard without preparing or launching Codex' {
        $customHome = Join-Path $TestDrive 'wizard-home'
        $powerShellExecutable = (Get-Command pwsh -ErrorAction Stop).Source
        $arguments = @(
            '-NoProfile',
            '-File', $script:launcherPath,
            '-AddModel',
            '-CustomCodexHome', $customHome
        )
        $answers = @(
            'ungate-opus-5',
            'Claude Opus 5 (Ungate)',
            'claude-opus-5',
            '',
            '',
            '',
            ''
        )

        $output = @($answers | & $powerShellExecutable @arguments 2>&1)

        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $registryPath = Join-Path $customHome 'ungate-model-definitions.json'
        Test-Path -LiteralPath $registryPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $customHome 'config.toml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $customHome 'ungate-models.json') | Should -BeFalse
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20
        $registry.Models[0].Slug | Should -BeExactly 'ungate-opus-5'
        $registry.Models[0].UpstreamModel | Should -BeExactly 'claude-opus-5'
    }

    It 'includes the custom model in the generated Codex model catalog' {
        $builtInDefinition = ConvertTo-UngateModelDefinition -Context $script:Context `
            -Record (
                New-CustomModelTestRecord `
                    -Slug 'ungate-opus-4-8' `
                    -DisplayName 'Claude Opus 4.8 (Ungate)' `
                    -UpstreamModel 'claude-opus-4-8'
            ) `
            -Priority 0
        $customDefinition = ConvertTo-UngateModelDefinition -Context $script:Context `
            -Record (New-CustomModelTestRecord) `
            -Priority 1
        $script:Selection.Definitions = @(
            Set-CodexModelShellSlugs -Context $script:Context -Definitions @($builtInDefinition, $customDefinition)
        )
        $script:Model = 'ungate-opus-5'
        $script:Selection.SelectedModel = $script:Selection.Definitions |
            Where-Object { $_.Slug -eq $script:Model } |
            Select-Object -First 1
        $script:Selection.LaunchModel = $script:Selection.SelectedModel.ShellSlug
        $script:Selection.LaunchProvider = $script:Context.CodexModelShellRouterProviderDefinition
        $script:Context.DefaultModelCachePath = Join-Path $TestDrive 'models_cache.json'
        $script:Context.CustomModelCatalogPath = Join-Path $TestDrive 'ungate-models.json'
        $script:Context.CustomConfigPath = Join-Path $TestDrive 'config.toml'

        $defaultCatalog = [ordered]@{
            models = @(
                [ordered]@{
                    slug = 'gpt-template'
                    display_name = 'GPT Template'
                    description = 'Template model'
                    model_messages = [ordered]@{
                        instructions_template = 'Template instructions'
                    }
                }
            )
        } | ConvertTo-Json -Depth 20
        Write-Utf8TestFile `
            -LiteralPath $script:Context.DefaultModelCachePath `
            -Content $defaultCatalog
        Write-Utf8TestFile `
            -LiteralPath $script:Context.CustomConfigPath `
            -Content @'
model = "gpt-template"

[model_providers.omniroute]
name = "OmniRoute"
base_url = "http://127.0.0.1:20128/v1"
env_key = "OMNIROUTE_API_KEY"
'@

        Write-UngateModelCatalog -Context $script:Context -Selection $script:Selection

        $catalog = Get-Content -LiteralPath $script:Context.CustomModelCatalogPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100
        @($catalog.Models) | Should -HaveCount 2
        foreach ($catalogModel in @($catalog.Models)) {
            $parallelToolCallProperty =
                $catalogModel.PSObject.Properties['supports_parallel_tool_calls']
            $parallelToolCallProperty | Should -Not -BeNullOrEmpty
            ($parallelToolCallProperty.Value -is [bool]) | Should -BeTrue
        }
        $opus5 = $catalog.Models |
            Where-Object { $_.slug -eq 'gpt-5.6-terra' } |
            Select-Object -First 1
        $opus5.display_name | Should -BeExactly 'Claude Opus 5 (Ungate)'
        $opus5.default_reasoning_level | Should -BeExactly 'high'
        @($opus5.input_modalities) | Should -Be @('text', 'image')
        $opus5.supports_parallel_tool_calls | Should -BeFalse
        # Current catalog caches use instructions_template, while the installed
        # Codex CLI requires the generated catalog to include both fields.
        $opus5.base_instructions | Should -Match 'environment instructions'
        $opus5.base_instructions | Should -Not -Match 'GPT model'
        $opus5.model_messages.instructions_template | Should -Match 'environment instructions'
        $opus5.model_messages.instructions_template | Should -Not -Match 'GPT model'

        $config = Get-Content -LiteralPath $script:Context.CustomConfigPath -Raw
        $config | Should -Match '(?m)^model = "gpt-5.6-terra"\r?$'
        $config | Should -Match '(?m)^model_provider = "ungate_model_shell_router"\r?$'
        $config | Should -Match '(?m)^model_reasoning_effort = "high"\r?$'
        $config | Should -Match '(?m)^\[model_providers\.ungate_model_shell_router\]\r?$'
        $config | Should -Not -Match '(?m)^\[model_providers\.omniroute\]\r?$'
    }

    It 'allocates stable official shell IDs for provider models' {
        $definitions = @(
            [pscustomobject]@{ Slug = 'ungate-opus-4-8' },
            [pscustomobject]@{ Slug = 'grok-4.7' },
            [pscustomobject]@{ Slug = 'miniMax-M3' }
        )

        $mapped = @(Set-CodexModelShellSlugs -Context $script:Context -Definitions $definitions)

        @($mapped.Slug) | Should -Be @('ungate-opus-4-8', 'grok-4.7', 'miniMax-M3')
        @($mapped.ShellSlug) | Should -Be @('gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna')
    }

    It 'uses official unsqueezed 1M context windows for MiniMax M3, Mimo, and DeepSeek V4 Pro' {
        $definitions = (New-UngateModelSet -Context $script:Context).BuiltInDefinitions
        foreach ($slug in @('miniMax-M3', 'mimo-v2.5-pro', 'deepseek-v4-pro')) {
            $definition = $definitions | Where-Object Slug -EQ $slug
            $definition.ContextWindow | Should -Be 1000000
            $definition.MaxContextWindow | Should -Be 1000000
            $definition.EffectiveContextWindowPercent | Should -BeNullOrEmpty
        }
        @($definitions | Where-Object ContextWindow -EQ 1048576).Count | Should -Be 0
    }

    It 'rejects launch parameters combined with AddModel before writing the registry' {
        $customHome = Join-Path $TestDrive 'conflict-home'
        $powerShellExecutable = (Get-Command pwsh -ErrorAction Stop).Source
        $arguments = @(
            '-NoProfile',
            '-File', $script:launcherPath,
            '-AddModel',
            '-PrepareOnly',
            '-CustomCodexHome', $customHome
        )

        $output = @(& $powerShellExecutable @arguments 2>&1)

        $LASTEXITCODE | Should -Not -Be 0
        $output -join "`n" | Should -Match 'AddModel cannot be combined with: PrepareOnly'
        Test-Path -LiteralPath $customHome | Should -BeFalse
    }

    It 'exposes AddModel as a menu action and returns to the refreshed model list' {
        $script:selectionDefinitions = @(
            [pscustomobject]@{
                Slug = 'ungate-opus-4-8'
                DisplayName = 'Claude Opus 4.8 (Ungate)'
            }
        )
        $script:selectionInputs = [System.Collections.Generic.Queue[string]]::new()
        $script:selectionInputs.Enqueue('3')
        $script:selectionInputs.Enqueue('2')
        $script:selectionDefinitionsAfterAdd = @(
            $script:selectionDefinitions
            [pscustomobject]@{
                Slug = 'ungate-opus-5'
                DisplayName = 'Claude Opus 5 (Ungate)'
            }
        )
        Mock -ModuleName Picker Read-Host {
            return $script:selectionInputs.Dequeue()
        }
        Mock -ModuleName Picker Invoke-AddUngateModelMode { return 'ungate-opus-5' }
        Mock -ModuleName Picker Invoke-UngatePickerConfiguration {}
        Mock -ModuleName Picker Get-UngateModelDefinitions {
            return @($script:selectionDefinitionsAfterAdd)
        }

        $selected = Select-UngateDesktopModel -Context $script:Context `
            -Definitions $script:selectionDefinitions `
            -BuiltInDefinitions $script:builtInDefinitions `
            -RegistryPath $script:registryPath `
            -PickerSettingsPath $script:pickerSettingsPath `
            -PickerCapacity $script:Context.CodexDesktopPickerCapacity

        $selected | Should -BeExactly 'ungate-opus-5'
        Should -ModuleName Picker -Invoke Invoke-AddUngateModelMode -Times 1 -Exactly
        Should -ModuleName Picker -Invoke Invoke-UngatePickerConfiguration -Times 1 -Exactly
        Should -ModuleName Picker -Invoke Get-UngateModelDefinitions -Times 1 -Exactly
    }

    It 'selects the OmniRoute fallback checkbox with a keyboard shortcut' {
        $script:selectionInputs = [System.Collections.Generic.Queue[string]]::new()
        $script:selectionInputs.Enqueue('f')
        Mock -ModuleName Picker Read-Host {
            return $script:selectionInputs.Dequeue()
        }

        $selected = Select-UngateDesktopModel -Context $script:Context `
            -Definitions $script:selectionDefinitions `
            -BuiltInDefinitions $script:builtInDefinitions `
            -RegistryPath $script:registryPath `
            -PickerSettingsPath $script:pickerSettingsPath `
            -PickerCapacity $script:Context.CodexDesktopPickerCapacity `
            -IncludeProviderFallback `
            -ProviderFallbackModel 'codex-fallback'

        $selected | Should -BeExactly 'codex-fallback'
    }

    It 'opens live logging menu with L shortcut and then selects model' {
        $script:selectionInputs = [System.Collections.Generic.Queue[string]]::new()
        $script:selectionInputs.Enqueue('L')
        $script:selectionInputs.Enqueue('1')
        Mock -ModuleName Picker Read-Host {
            return $script:selectionInputs.Dequeue()
        }
        Mock -ModuleName Picker Invoke-UngateLoggingMenu { return 'Compact' }

        $selected = Select-UngateDesktopModel -Context $script:Context `
            -Definitions $script:selectionDefinitions `
            -BuiltInDefinitions $script:builtInDefinitions `
            -RegistryPath $script:registryPath `
            -PickerSettingsPath $script:pickerSettingsPath `
            -PickerCapacity $script:Context.CodexDesktopPickerCapacity

        $selected | Should -BeExactly 'ungate-opus-4-8'
        Should -ModuleName Picker -Invoke Invoke-UngateLoggingMenu -Times 1 -Exactly
    }

    It 'prints each picker model with its catalog context window' {
        $script:hostLines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Picker Write-Host {
            param($Object)
            $script:hostLines.Add([string]$Object)
        }
        Mock -ModuleName Picker Read-Host { return '1' }
        Mock -ModuleName Picker Invoke-AddUngateModelMode {}
        Mock -ModuleName Picker Invoke-UngatePickerConfiguration {}

        $definitions = @(
            [pscustomobject]@{
                Slug = 'miniMax-M3'
                DisplayName = 'MiniMax M3 (Ungate)'
                ContextWindow = 1000000
                MaxContextWindow = 1000000
            }
            [pscustomobject]@{
                Slug = 'grok-4.7'
                DisplayName = 'Grok 4.7 (CLIProxyAPI)'
                ContextWindow = 500000
                MaxContextWindow = 500000
            }
            [pscustomobject]@{
                Slug = 'ungate-fable-5'
                DisplayName = 'Claude Fable 5 (Ungate)'
            }
        )

        $selected = Select-UngateDesktopModel -Context $script:Context `
            -Definitions $definitions `
            -BuiltInDefinitions $script:builtInDefinitions `
            -RegistryPath $script:registryPath `
            -PickerSettingsPath $script:pickerSettingsPath `
            -PickerCapacity $script:Context.CodexDesktopPickerCapacity

        $selected | Should -BeExactly 'miniMax-M3'
        $menu = $script:hostLines -join "`n"
        $menu | Should -Match 'MiniMax M3 \(Ungate\) \(default\)  \[1M\]'
        $menu | Should -Match 'Grok 4.7 \(CLIProxyAPI\)  \[500k\]'
        $menu | Should -Match 'Claude Fable 5 \(Ungate\)  \[200k\]'
    }
}

Describe 'Launcher model version overrides' {
    BeforeEach {
        $script:overridesPath = Join-Path $TestDrive 'ungate-model-overrides.json'
        $script:testDefs = @(
            [pscustomobject][ordered]@{
                Slug = 'grok-4.7'
                DisplayName = 'Grok 4.7 (CLIProxyAPI)'
                Description = 'Grok 4.7 through CLIProxyAPI.'
                UpstreamModel = 'grok-4.7'
                Aliases = @('grok-4', 'grok')
                TransportDescription = 'the local CLIProxyAPI bridge'
                ProviderDisplayName = 'CLIProxyAPI'
                ContextWindow = 500000
                MaxContextWindow = 500000
                Priority = 2
            }
            [pscustomobject][ordered]@{
                Slug = 'ungate-opus-4-8'
                DisplayName = 'Claude Opus 4.8 (Ungate)'
                Description = 'Claude Opus 4.8 via Ungate.'
                UpstreamModel = 'claude-opus-4-8'
                Aliases = @('opus')
                TransportDescription = 'the Ungate Responses proxy'
                ProviderDisplayName = 'Ungate Proxy'
                ContextWindow = 200000
                MaxContextWindow = 200000
                Priority = 1
            }
        )
    }

    It 'parses human-friendly context window token formats' {
        ConvertTo-ContextWindowTokens -Value '500k' | Should -Be 500000
        ConvertTo-ContextWindowTokens -Value '500K' | Should -Be 500000
        ConvertTo-ContextWindowTokens -Value '1M' | Should -Be 1000000
        ConvertTo-ContextWindowTokens -Value '1m' | Should -Be 1000000
        ConvertTo-ContextWindowTokens -Value '200000' | Should -Be 200000
        ConvertTo-ContextWindowTokens -Value ' 128k ' | Should -Be 128000
        { ConvertTo-ContextWindowTokens -Value 'invalid' } | Should -Throw '*Invalid context window*'
        { ConvertTo-ContextWindowTokens -Value '-100' } | Should -Throw '*Invalid context window*'
    }

    It 'returns an empty hashtable when overrides file does not exist' {
        $overrides = Read-UngateModelOverrides -OverridesPath (Join-Path $TestDrive 'nonexistent.json')
        $overrides.Count | Should -Be 0
    }

    It 'sets, persists, and reads back a model override' {
        $overrideData = [ordered]@{
            upstreamModel = 'grok-4.8'
            displayName = 'Grok 4.8 (CLIProxyAPI)'
            contextWindow = 1000000
        }
        $saved = Set-UngateModelOverride -OverridesPath $script:overridesPath -Slug 'grok-4.7' -Override $overrideData
        Test-Path -LiteralPath $script:overridesPath | Should -BeTrue

        $read = Read-UngateModelOverrides -OverridesPath $script:overridesPath
        $read.Contains('grok-4.7') | Should -BeTrue
        $read['grok-4.7'].upstreamModel | Should -Be 'grok-4.8'
        $read['grok-4.7'].displayName | Should -Be 'Grok 4.8 (CLIProxyAPI)'
        $read['grok-4.7'].contextWindow | Should -Be 1000000
    }

    It 'applies overrides to definitions updating upstream model, label, and context window' {
        $overrideData = [ordered]@{
            upstreamModel = 'grok-4.8'
            displayName = 'Grok 4.8 (CLIProxyAPI)'
            contextWindow = 1000000
        }
        $saved = Set-UngateModelOverride -OverridesPath $script:overridesPath -Slug 'grok-4.7' -Override $overrideData
        $overrides = Read-UngateModelOverrides -OverridesPath $script:overridesPath

        $applied = @(Apply-UngateModelOverrides -Context $script:Context -Definitions $script:testDefs -Overrides $overrides)
        $grok = $applied | Where-Object { $_.Slug -eq 'grok-4.7' }
        $grok.UpstreamModel | Should -Be 'grok-4.8'
        $grok.DisplayName | Should -Be 'Grok 4.8 (CLIProxyAPI)'
        $grok.ContextWindow | Should -Be 1000000
        $grok.MaxContextWindow | Should -Be 1000000
        $grok.IsOverridden | Should -BeTrue
        $grok.DefaultUpstreamModel | Should -Be 'grok-4.7'
        $grok.Aliases -contains 'grok-4.8' | Should -BeTrue

        $window = Get-UngateModelContextWindow -Definition $grok
        $window.Label | Should -Be '1M'
    }

    It 'removes an override and deletes the file when no overrides remain' {
        $overrideData = [ordered]@{ upstreamModel = 'grok-4.8' }
        $null = Set-UngateModelOverride -OverridesPath $script:overridesPath -Slug 'grok-4.7' -Override $overrideData
        Test-Path -LiteralPath $script:overridesPath | Should -BeTrue

        $null = Remove-UngateModelOverride -OverridesPath $script:overridesPath -Slug 'grok-4.7'
        Test-Path -LiteralPath $script:overridesPath | Should -BeFalse

        $read = Read-UngateModelOverrides -OverridesPath $script:overridesPath
        $read.Count | Should -Be 0
    }

    It 'configures model version non-interactively and allows resetting' {
        $mockDefs = @(
            [pscustomobject][ordered]@{
                Slug = 'grok-4.7'
                DisplayName = 'Grok 4.7 (CLIProxyAPI)'
                UpstreamModel = 'grok-4.7'
                DefaultUpstreamModel = 'grok-4.7'
            }
        )
        $res = Invoke-UngateModelVersionConfiguration `
            -Context $script:Context `
            -Definitions $mockDefs `
            -OverridesPath $script:overridesPath `
            -TargetModelSlug 'grok-4.7' `
            -NewUpstreamModel 'grok-4.8'
        $res | Should -BeTrue

        $overrides = Read-UngateModelOverrides -OverridesPath $script:overridesPath
        $overrides['grok-4.7'].upstreamModel | Should -Be 'grok-4.8'

        # Reset via non-interactive call
        $resReset = Invoke-UngateModelVersionConfiguration `
            -Context $script:Context `
            -Definitions $mockDefs `
            -OverridesPath $script:overridesPath `
            -TargetModelSlug 'grok-4.7' `
            -NewUpstreamModel 'reset'
        $resReset | Should -BeTrue

        $overridesAfter = Read-UngateModelOverrides -OverridesPath $script:overridesPath
        $overridesAfter.Count | Should -Be 0
    }
}

Describe 'Desktop picker model selection' {
    BeforeEach {
        $script:pickerDefinitions = @(
            1..8 | ForEach-Object {
                [pscustomobject]@{
                    Slug = "model-$_"
                    DisplayName = "Model $_"
                }
            }
        )
        $script:pickerSettingsPath = Join-Path $TestDrive 'ungate-picker-models.json'
        $script:pickerCapacity = 7
        Remove-Item -LiteralPath $script:pickerSettingsPath -Force -ErrorAction SilentlyContinue
    }

    It 'defaults to seven models and round-trips a custom selection in source order' {
        $defaultSelection = @(
            Read-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        )

        $defaultSelection | Should -HaveCount 7
        $defaultSelection | Should -Be @('model-1', 'model-2', 'model-3', 'model-4', 'model-5', 'model-6', 'model-7')

        $null = Write-UngatePickerModelSelection `
            -SettingsPath $script:pickerSettingsPath `
            -ModelSlugs @('model-8', 'model-2', 'model-1') `
            -Definitions $script:pickerDefinitions `
            -Capacity $script:pickerCapacity

        $savedSelection = @(
            Read-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        )
        $savedSelection | Should -Be @('model-1', 'model-2', 'model-8')
    }

    It 'rejects an empty, oversized, duplicated, or unknown selection' {
        {
            Write-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -ModelSlugs ([string[]]@()) `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        } | Should -Throw '*at least one model*'

        {
            Write-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -ModelSlugs (1..8 | ForEach-Object { "model-$_" }) `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        } | Should -Throw '*at most 7 models*'

        {
            Write-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -ModelSlugs @('model-1', 'MODEL-1') `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        } | Should -Throw '*duplicated*'

        {
            Write-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -ModelSlugs @('model-missing') `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        } | Should -Throw '*unknown models*'
    }

    It 'ignores stale saved models and falls back when none remain' {
        Write-Utf8TestFile `
            -LiteralPath $script:pickerSettingsPath `
            -Content '{"version":1,"modelSlugs":["model-missing"]}'

        $selection = @(
            Read-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        )

        $selection | Should -HaveCount 7
        $selection[0] | Should -BeExactly 'model-1'
        $selection[6] | Should -BeExactly 'model-7'
    }

    It 'truncates a legacy oversized selection to the picker capacity' {
        Write-Utf8TestFile `
            -LiteralPath $script:pickerSettingsPath `
            -Content '{"version":1,"modelSlugs":["model-1","model-2","model-3","model-4","model-5","model-6","model-7","model-8"]}'

        $selection = @(
            Read-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        )

        $selection | Should -HaveCount 7
        $selection | Should -Be @('model-1', 'model-2', 'model-3', 'model-4', 'model-5', 'model-6', 'model-7')
    }

    It 'filters the active definitions to the persisted picker selection' {
        $null = Write-UngatePickerModelSelection `
            -SettingsPath $script:pickerSettingsPath `
            -ModelSlugs @('model-8', 'model-2') `
            -Definitions $script:pickerDefinitions `
            -Capacity $script:pickerCapacity

        $activeDefinitions = @(
            Get-UngatePickerModelDefinitions `
                -Definitions $script:pickerDefinitions `
                -SettingsPath $script:pickerSettingsPath `
                -Capacity $script:pickerCapacity
        )

        @($activeDefinitions.Slug) | Should -Be @('model-2', 'model-8')
    }

    It 'does not write picker settings when the interactive screen is cancelled' {
        $null = Write-UngatePickerModelSelection `
            -SettingsPath $script:pickerSettingsPath `
            -ModelSlugs @('model-1', 'model-2') `
            -Definitions $script:pickerDefinitions `
            -Capacity $script:pickerCapacity
        $beforeHash = (Get-FileHash -LiteralPath $script:pickerSettingsPath -Algorithm SHA256).Hash

        Mock -ModuleName Picker Read-UngatePickerKey { return 'cancel' }
        Mock -ModuleName Picker Clear-Host {}

        $result = Invoke-UngatePickerConfiguration `
            -Definitions $script:pickerDefinitions `
            -SettingsPath $script:pickerSettingsPath `
            -Capacity $script:pickerCapacity

        $result | Should -BeFalse
        (Get-FileHash -LiteralPath $script:pickerSettingsPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
    }

    It 'toggles picker models with keyboard input and saves in source order' {
        $script:pickerKeyInputs = [System.Collections.Generic.Queue[string]]::new()
        foreach ($key in @('down', 'toggle', 'down', 'toggle', 'save')) {
            $script:pickerKeyInputs.Enqueue($key)
        }
        Mock -ModuleName Picker Read-UngatePickerKey {
            return $script:pickerKeyInputs.Dequeue()
        }
        Mock -ModuleName Picker Clear-Host {}

        $result = Invoke-UngatePickerConfiguration `
            -Definitions $script:pickerDefinitions `
            -SettingsPath $script:pickerSettingsPath `
            -Capacity $script:pickerCapacity

        $result | Should -BeTrue
        $selection = @(
            Read-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        )
        $selection | Should -Be @('model-1', 'model-4', 'model-5', 'model-6', 'model-7')
    }

    It 'prevents selecting an eighth model until a selected model is disabled' {
        $script:pickerKeyInputs = [System.Collections.Generic.Queue[string]]::new()
        foreach ($key in @('up', 'toggle', 'down', 'toggle', 'up', 'toggle', 'save')) {
            $script:pickerKeyInputs.Enqueue($key)
        }
        Mock -ModuleName Picker Read-UngatePickerKey {
            return $script:pickerKeyInputs.Dequeue()
        }
        Mock -ModuleName Picker Clear-Host {}

        $result = Invoke-UngatePickerConfiguration `
            -Definitions $script:pickerDefinitions `
            -SettingsPath $script:pickerSettingsPath `
            -Capacity $script:pickerCapacity

        $result | Should -BeTrue
        $selection = @(
            Read-UngatePickerModelSelection `
                -SettingsPath $script:pickerSettingsPath `
                -Definitions $script:pickerDefinitions `
                -Capacity $script:pickerCapacity
        )
        $selection | Should -Be @('model-2', 'model-3', 'model-4', 'model-5', 'model-6', 'model-7', 'model-8')
    }
}

Describe 'Codex launcher history profile' {
    It 'uses one canonical history home for every launcher model' {
        $canonicalHome = Join-Path $TestDrive 'codex-ungate'
        $models = @(
            [pscustomobject]@{ Slug = 'ungate-opus-4-8'; Provider = 'ungate_proxy' }
            [pscustomobject]@{ Slug = 'ungate-fable-5'; Provider = 'ungate_proxy' }
            [pscustomobject]@{ Slug = 'miniMax-M3'; Provider = 'ungate_proxy' }
            [pscustomobject]@{ Slug = 'grok-4.7'; Provider = 'cliproxyapi' }
        )

        $profiles = @(
            foreach ($model in $models) {
                Get-CodexHistoryProfileInfo `
                    -HomePath $canonicalHome `
                    -CanonicalHomePath $canonicalHome `
                    -ModelSlug $model.Slug `
                    -ProviderName $model.Provider
            }
        )

        @($profiles | Select-Object -ExpandProperty CodexHome -Unique) | Should -HaveCount 1
        @($profiles | Select-Object -ExpandProperty SessionsPath -Unique) | Should -HaveCount 1
        @($profiles | Select-Object -ExpandProperty StatePath -Unique) | Should -HaveCount 1
        @($profiles | Where-Object { -not $_.IsCanonical }) | Should -HaveCount 0
        $profiles | ForEach-Object { $_.StatePath | Should -Be (Join-Path $canonicalHome 'state_5.sqlite') }
    }

    It 'marks a non-default custom home as a separate history profile' {
        $canonicalHome = Join-Path $TestDrive 'codex-ungate'
        $separateHome = Join-Path $TestDrive 'codex-ungate-grok'

        $profile = Get-CodexHistoryProfileInfo `
            -HomePath $separateHome `
            -CanonicalHomePath $canonicalHome `
            -ModelSlug 'grok-4.7' `
            -ProviderName 'cliproxyapi'

        $profile.IsCanonical | Should -BeFalse
        $profile.CodexHome | Should -Be ([System.IO.Path]::GetFullPath($separateHome))
    }
}

Describe 'Get-CodexCliExecutable' {
    BeforeEach {
        $script:cliTestRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:cliTestRoot -Force | Out-Null
        $script:Context.DefaultConfigPath = Join-Path $script:cliTestRoot 'default-config.toml'
        $script:Context.CustomConfigPath = Join-Path $script:cliTestRoot 'custom-config.toml'
        $script:previousLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $script:cliTestRoot 'local-app-data'
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
    }

    AfterEach {
        if ($null -eq $script:previousLocalAppData) {
            Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
        }
        else {
            $env:LOCALAPPDATA = $script:previousLocalAppData
        }
    }

    It 'uses an existing configured native executable' {
        $nativeCli = Join-Path $script:cliTestRoot 'configured\codex.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $nativeCli) -Force | Out-Null
        New-Item -ItemType File -Path $nativeCli -Force | Out-Null
        Write-Utf8TestFile `
            -LiteralPath $script:Context.DefaultConfigPath `
            -Content "CODEX_CLI_PATH = '$nativeCli'"
        Mock -ModuleName Desktop Get-Command { $null }

        Get-CodexCliExecutable -Context $script:Context | Should -BeExactly (Resolve-Path -LiteralPath $nativeCli).Path
    }

    It 'ignores a stale configured path and resolves the native npm CLI behind a PowerShell wrapper' {
        Write-Utf8TestFile `
            -LiteralPath $script:Context.DefaultConfigPath `
            -Content "CODEX_CLI_PATH = 'C:\missing\codex.exe'"
        $npmRoot = Join-Path $script:cliTestRoot 'npm'
        $wrapperPath = Join-Path $npmRoot 'codex.ps1'
        $nativeCli = Join-Path `
            $npmRoot `
            'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $nativeCli) -Force | Out-Null
        New-Item -ItemType File -Path $wrapperPath -Force | Out-Null
        New-Item -ItemType File -Path $nativeCli -Force | Out-Null
        Mock -ModuleName Desktop Get-Command {
            [pscustomobject]@{
                Source = $wrapperPath
                CommandType = 'ExternalScript'
            }
        }

        Get-CodexCliExecutable -Context $script:Context | Should -BeExactly (Resolve-Path -LiteralPath $nativeCli).Path
    }

    It 'does not return a PowerShell wrapper when no native executable exists' {
        $wrapperPath = Join-Path $script:cliTestRoot 'npm\codex.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperPath) -Force | Out-Null
        New-Item -ItemType File -Path $wrapperPath -Force | Out-Null
        Mock -ModuleName Desktop Get-Command {
            [pscustomobject]@{
                Source = $wrapperPath
                CommandType = 'ExternalScript'
            }
        }

        Get-CodexCliExecutable -Context $script:Context | Should -BeNullOrEmpty
    }
}

Describe 'Launcher profile preparation order and logging' {
    BeforeEach {
        $script:profileEvents = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Launcher Initialize-UngateCodexConfig { $script:profileEvents.Add('config') }
        Mock -ModuleName Launcher Write-UngateModelCatalog { $script:profileEvents.Add('catalog') }
        Mock -ModuleName Launcher Sync-CodexMcpServers { $script:profileEvents.Add('mcp') }
        Mock -ModuleName Launcher Ensure-SharedDirectory {}
        Mock -ModuleName Launcher Sync-CodexGlobalInstructions {}
        Mock -ModuleName Launcher Sync-CodexAuthentication {}
        Mock -ModuleName Launcher Get-CodexCliExecutable { 'C:\test\codex.exe' }
        Mock -ModuleName Launcher Get-CodexBetaProcesses { @() }
        Mock -ModuleName Launcher Initialize-CodexBetaPluginIsolation {
            [pscustomobject]@{ Changed = $true; SyncReasons = @('package changed'); Action = 'Synced'; PluginIds = @('browser'); BrowserSha256 = 'test-hash'; UnsupportedBundledPluginIds = @() }
        }
        Mock -ModuleName Launcher Assert-UngateCodexConfig { $script:profileEvents.Add('validate') }
        Mock -ModuleName Launcher Initialize-CodexWindowsSandbox {}
        Mock -ModuleName Launcher Restore-CodexWorkspaceRoots {}
        Mock -ModuleName Launcher Write-Host { param($Object) $script:profileEvents.Add([string]$Object) }
    }

    It 'writes the model catalog before validating the isolated MCP configuration' {
        & (Get-Module Launcher) {
            param($context, $selection)
            Initialize-CodexDesktopProfile -Context $context -Selection $selection -codexBeta ([pscustomobject]@{ExecutablePath='test.exe';BundledMarketplacePath='test';Version='1'}) -providerKeys @{} -selectedKey 'test'
        } $script:Context $script:Selection
        $script:profileEvents.IndexOf('catalog') | Should -BeLessThan $script:profileEvents.IndexOf('mcp')
        $script:profileEvents.IndexOf('mcp') | Should -BeLessThan $script:profileEvents.IndexOf('validate')
    }

    It 'prints sync reasons before the isolation result' {
        & (Get-Module Launcher) {
            param($context, $selection)
            Initialize-CodexDesktopProfile -Context $context -Selection $selection -codexBeta ([pscustomobject]@{ExecutablePath='test.exe';BundledMarketplacePath='test';Version='1'}) -providerKeys @{} -selectedKey 'test'
        } $script:Context $script:Selection
        $reason = @($script:profileEvents | Where-Object { $_ -like '*will sync because:*' })
        $result = @($script:profileEvents | Where-Object { $_ -like '*plugins synced and isolated*' })
        $reason.Count | Should -Be 1
        $result.Count | Should -Be 1
        $script:profileEvents.IndexOf($reason[0]) | Should -BeLessThan $script:profileEvents.IndexOf($result[0])
    }
}

Describe 'Sync-CodexMcpServers' {
    BeforeEach {
        Mock -ModuleName Profile Get-CodexCliExecutable { 'C:\test\codex.exe' }
        Mock -ModuleName Profile Test-CodexMcpConfiguration { @('context7', 'node_repl', 'openaiDeveloperDocs', 'playwright') }
    }

    It 'mirrors nested MCP tables and preserves isolated settings' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        $sourceConfig = @'
model = "gpt-5.4"

[mcp_servers.playwright]
command = "npx"
args = ["playwright"]

[mcp_servers.context7]
type = "http"
url = "https://mcp.context7.com/mcp"

[mcp_servers.context7.http_headers]
CONTEXT7_API_KEY = "fake-test-key"

[mcp_servers.openaiDeveloperDocs]
url = "https://developers.openai.com/mcp"

[mcp_servers.node_repl]
command = "node"

[mcp_servers.node_repl.env]
CODEX_HOME = "source-home"

[plugins."github@openai-curated"]
enabled = true
'@
        $targetConfig = @'
model = "grok-4.5"
model_provider = "cliproxyapi"

[model_providers.cliproxyapi]
base_url = "http://127.0.0.1:8318/v1"

[mcp_servers.staleBetaServer]
command = "stale"

[plugins."visualize@openai-bundled"]
enabled = true
'@
        Write-Utf8TestFile -LiteralPath $homes.SourceConfigPath -Content $sourceConfig
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content $targetConfig

        Sync-CodexMcpServers -Context $script:Context `
            -SourceCodexHome $homes.SourceCodexHome `
            -TargetCodexHome $homes.TargetCodexHome

        $actual = Get-Content -LiteralPath $homes.TargetConfigPath -Raw
        $actual | Should -Match '(?m)^model = "grok-4\.5"\r?$'
        $actual | Should -Match '(?m)^model_provider = "cliproxyapi"\r?$'
        $actual | Should -Match '(?m)^\[model_providers\.cliproxyapi\]\r?$'
        $actual | Should -Match '(?m)^\[plugins\."visualize@openai-bundled"\]\r?$'
        $actual | Should -Match '(?m)^\[mcp_servers\.context7\.http_headers\]\r?$'
        $actual | Should -Match '(?m)^CONTEXT7_API_KEY = "fake-test-key"\r?$'
        $actual | Should -Match '(?m)^\[mcp_servers\.node_repl\.env\]\r?$'
        $actual | Should -Match '(?m)^\[mcp_servers\.openaiDeveloperDocs\]\r?$'
        $actual | Should -Not -Match '(?m)^\[mcp_servers\.staleBetaServer\]\r?$'
    }

    It 'does not rewrite a config whose MCP table family already matches' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        $config = @'
model = "grok-4.5"

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
'@
        Write-Utf8TestFile -LiteralPath $homes.SourceConfigPath -Content $config
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content $config
        $beforeHash = (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash
        $beforeWriteTime = (Get-Item -LiteralPath $homes.TargetConfigPath).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50

        Sync-CodexMcpServers -Context $script:Context `
            -SourceCodexHome $homes.SourceCodexHome `
            -TargetCodexHome $homes.TargetCodexHome

        (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
        (Get-Item -LiteralPath $homes.TargetConfigPath).LastWriteTimeUtc |
            Should -BeExactly $beforeWriteTime
    }

    It 'treats a source without MCP tables as an authoritative empty set' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        Write-Utf8TestFile -LiteralPath $homes.SourceConfigPath -Content 'model = "gpt-5.4"'
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content @'
model = "grok-4.5"

[mcp_servers.betaOnly]
command = "beta-only"

[plugins."github@openai-curated"]
enabled = true
'@

        Sync-CodexMcpServers -Context $script:Context `
            -SourceCodexHome $homes.SourceCodexHome `
            -TargetCodexHome $homes.TargetCodexHome

        $actual = Get-Content -LiteralPath $homes.TargetConfigPath -Raw
        $actual | Should -Not -Match '(?m)^\[mcp_servers\.'
        $actual | Should -Match '(?m)^\[plugins\."github@openai-curated"\]\r?$'
    }

    It 'does not modify Beta config when source validation fails' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        Write-Utf8TestFile -LiteralPath $homes.SourceConfigPath -Content 'invalid source'
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content 'model = "grok-4.5"'
        $beforeHash = (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash
        Mock -ModuleName Profile Test-CodexMcpConfiguration { throw 'source config rejected' }

        {
            Sync-CodexMcpServers -Context $script:Context `
                -SourceCodexHome $homes.SourceCodexHome `
                -TargetCodexHome $homes.TargetCodexHome
        } | Should -Throw '*source config rejected*'

        (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
    }

    It 'does not modify Beta config when the source config is missing' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content 'model = "grok-4.5"'
        $beforeHash = (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash

        {
            Sync-CodexMcpServers -Context $script:Context `
                -SourceCodexHome $homes.SourceCodexHome `
                -TargetCodexHome $homes.TargetCodexHome
        } | Should -Throw '*Default Codex config not found*'

        (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
        Should -ModuleName Profile -Not -Invoke Test-CodexMcpConfiguration
    }

    It 'restores the previous Beta config when post-write validation fails' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        Write-Utf8TestFile -LiteralPath $homes.SourceConfigPath -Content @'
model = "gpt-5.4"

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
'@
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content @'
model = "grok-4.5"

[mcp_servers.playwright]
command = "npx"
'@
        $beforeHash = (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash
        Mock -ModuleName Profile Test-CodexMcpConfiguration {
            param($CodexExecutable, $CodexHome)
            if ($CodexHome -eq $homes.TargetCodexHome) {
                throw 'target config rejected'
            }
            return @('context7')
        }

        {
            Sync-CodexMcpServers -Context $script:Context `
                -SourceCodexHome $homes.SourceCodexHome `
                -TargetCodexHome $homes.TargetCodexHome
        } | Should -Throw '*previous Beta config was restored*'

        (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
        @(Get-ChildItem -LiteralPath $homes.TargetCodexHome -Filter '.config.toml.*').Count |
            Should -Be 0
    }

    It 'normalizes Beta-only MCP content before Codex rewrites line endings' {
        $homes = New-McpSyncTestHomes -Root $TestDrive
        Write-Utf8TestFile -LiteralPath $homes.SourceConfigPath -Content @'
model = "gpt-5.4"

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
'@
        Write-Utf8TestFile -LiteralPath $homes.TargetConfigPath -Content 'model = "grok-4.5"'
        $betaOnlyMcpContent = "[mcp_servers.ungate_patch]`ncommand = 'node'`nargs = ['patch.mjs']"

        Mock -ModuleName Profile Test-CodexMcpConfiguration {
            param($CodexExecutable, $CodexHome)
            if ($CodexHome -eq $homes.TargetCodexHome) {
                $path = Join-Path $CodexHome 'config.toml'
                $raw = Get-Content -LiteralPath $path -Raw
                $rewritten = ($raw -split '\r?\n') -join "`r`n"
                [System.IO.File]::WriteAllText(
                    $path,
                    $rewritten,
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
            return @('context7', 'ungate_patch')
        }

        Sync-CodexMcpServers -Context $script:Context `
            -SourceCodexHome $homes.SourceCodexHome `
            -TargetCodexHome $homes.TargetCodexHome `
            -BetaOnlyMcpContent $betaOnlyMcpContent

        $actual = Get-Content -LiteralPath $homes.TargetConfigPath -Raw
        $actual | Should -Match '(?m)^\[mcp_servers\.context7\]\r?$'
        $actual | Should -Match '(?m)^\[mcp_servers\.ungate_patch\]\r?$'
    }
}

Describe 'Ungate environment source-edit instructions' {
    It 'tells Grok 4.7 to use MCP apply_patch and never wrap patches in exec template literals' {
        $script:Context.UngateEnvironmentInstruction | Should -Not -BeNullOrEmpty

        $identity = Get-UngateModelIdentity -Context $script:Context `
            -DisplayName 'Grok 4.7 (CLIProxyAPI)' `
            -UpstreamModel 'grok-4.7' `
            -ProviderDisplayName 'CLIProxyAPI' `
            -TransportDescription 'the local CLIProxyAPI compatibility bridge'

        $identity | Should -Match 'mcp__ungate_patch__apply_patch'
        $identity | Should -Match 'tools\.apply_patch\(`'
        $identity | Should -Match 'ReferenceError'
        $identity | Should -Match '\$\{\}'
        $identity | Should -Match 'tools\.wait'
        $identity | Should -Match 'yield_time_ms'
        $identity | Should -Match 'text\(\.\.\.\)'
        $identity | Should -Match 'bare await returns nothing'
        $identity | Should -Match 'proposed_plan'
        $identity | Should -Match 'HARD RULE — Plan Mode'
        $identity | Should -Match 'text\(JSON\.stringify'
        $identity | Should -Match "join\('\\n'\)"
        $identity | Should -Match 'hunk_not_found'
        $identity | Should -Match 'Wall time 0\.0'
        $identity | Should -Match 'ok: true'
        $identity | Should -Match 'only patch path'
        $identity | Should -Match 'Remote SSH scripts via PowerShell'
        $identity | Should -Match "@' \.\.\. '@ \| ssh host 'bash -s'"
        $identity | Should -Match 'Quoting CLI arguments in PowerShell'
        $identity | Should -Match "rg -n 'id=""domain-list""'"
    }
}

Describe 'Ungate live log settings' {
    It 'returns Standard by default when settings file is missing or empty' {
        $tempSettings = Join-Path ([System.IO.Path]::GetTempPath()) ("ungate-test-log-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            (Read-UngateLogSettings -SettingsPath $tempSettings).LogLevel | Should -BeExactly 'Standard'
            Set-Content -LiteralPath $tempSettings -Value ''
            (Read-UngateLogSettings -SettingsPath $tempSettings).LogLevel | Should -BeExactly 'Standard'
        }
        finally {
            Remove-Item -LiteralPath $tempSettings -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes valid JSON and reads it back for all supported log levels' {
        $tempSettings = Join-Path ([System.IO.Path]::GetTempPath()) ("ungate-test-log-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            foreach ($level in @('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors')) {
                Write-UngateLogSettings -SettingsPath $tempSettings -LogLevel $level
                (Read-UngateLogSettings -SettingsPath $tempSettings).LogLevel | Should -BeExactly $level
            }
        }
        finally {
            Remove-Item -LiteralPath $tempSettings -Force -ErrorAction SilentlyContinue
        }
    }

    It 'normalizes unknown level string to Standard' {
        $tempSettings = Join-Path ([System.IO.Path]::GetTempPath()) ("ungate-test-log-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            Set-Content -LiteralPath $tempSettings -Value '{"LogLevel":"UnknownLevel"}'
            (Read-UngateLogSettings -SettingsPath $tempSettings).LogLevel | Should -BeExactly 'Standard'
        }
        finally {
            Remove-Item -LiteralPath $tempSettings -Force -ErrorAction SilentlyContinue
        }
    }

    It 'allows user to interactively select a log level in Invoke-UngateLoggingMenu' {
        $tempSettings = Join-Path ([System.IO.Path]::GetTempPath()) ("ungate-test-log-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            Mock -ModuleName Logging Read-Host { return '6' }
            $chosen = Invoke-UngateLoggingMenu -SettingsPath $tempSettings
            $chosen | Should -BeExactly 'Errors'
            (Read-UngateLogSettings -SettingsPath $tempSettings).LogLevel | Should -BeExactly 'Errors'
        }
        finally {
            Remove-Item -LiteralPath $tempSettings -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Format-CodexSessionEvent' {
    It 'does not throw on empty or malformed input' {
        { Format-CodexSessionEvent -Line '' } | Should -Not -Throw
        { Format-CodexSessionEvent -Line 'not-json' } | Should -Not -Throw
        { Format-CodexSessionEvent -Line '{"type":"unknown"}' } | Should -Not -Throw
    }

    It 'formats agent_reasoning events without error' {
        $json = '{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Thinking about something"}}'
        { Format-CodexSessionEvent -Line $json } | Should -Not -Throw
    }

    It 'formats custom_tool_call and output events without error' {
        $callJson = '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"tools.shell_command()"}}'
        $outJson = '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"text":"output text"}]}}'
        { Format-CodexSessionEvent -Line $callJson } | Should -Not -Throw
        { Format-CodexSessionEvent -Line $outJson } | Should -Not -Throw
    }

    It 'formats user and agent messages without error' {
        $userJson = '{"type":"event_msg","payload":{"type":"user_message","message":"Hello agent"}}'
        $agentJson = '{"type":"event_msg","payload":{"type":"agent_message","message":"Hello user"}}'
        { Format-CodexSessionEvent -Line $userJson } | Should -Not -Throw
        { Format-CodexSessionEvent -Line $agentJson } | Should -Not -Throw
    }

    It 'suppresses all output when LogLevel is Off' {
        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Logging Write-Host { param($Object) $printed.Add([string]$Object) }
        $json = '{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Thinking"}}'
        Format-CodexSessionEvent -Line $json -LogLevel 'Off'
        $printed.Count | Should -Be 0
    }

    It 'suppresses reasoning in Compact, Minimal, and Errors modes' {
        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Logging Write-Host { param($Object) $printed.Add([string]$Object) }
        $thinkJson = '{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Thinking deeply"}}'
        Format-CodexSessionEvent -Line $thinkJson -LogLevel 'Compact'
        Format-CodexSessionEvent -Line $thinkJson -LogLevel 'Minimal'
        Format-CodexSessionEvent -Line $thinkJson -LogLevel 'Errors'
        $printed.Count | Should -Be 0

        Format-CodexSessionEvent -Line $thinkJson -LogLevel 'Standard'
        ($printed -join ' ') | Should -Match 'Thinking deeply'
    }

    It 'suppresses normal messages and shows only failures when LogLevel is Errors' {
        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Logging Write-Host { param($Object) $printed.Add([string]$Object) }

        $userJson = '{"type":"event_msg","payload":{"type":"user_message","message":"Hello"}}'
        $agentJson = '{"type":"event_msg","payload":{"type":"agent_message","message":"Hi there"}}'
        $callJson = '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"{\"command\":\"dir\"}"}}'
        $normalOutJson = '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"text":"File1.txt"}]}}'
        $abortJson = '{"type":"event_msg","payload":{"type":"turn_aborted"}}'
        $errorOutJson = '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"text":"Error: file not found"}]}}'

        Format-CodexSessionEvent -Line $userJson -LogLevel 'Errors'
        Format-CodexSessionEvent -Line $agentJson -LogLevel 'Errors'
        Format-CodexSessionEvent -Line $callJson -LogLevel 'Errors'
        Format-CodexSessionEvent -Line $normalOutJson -LogLevel 'Errors'
        $printed.Count | Should -Be 0

        Format-CodexSessionEvent -Line $abortJson -LogLevel 'Errors'
        Format-CodexSessionEvent -Line $errorOutJson -LogLevel 'Errors'

        $all = $printed -join "`n"
        $all | Should -Match '\[TURN ABORTED\]'
        $all | Should -Match '<-- \[TOOL ERROR\]'
        $all | Should -Match 'Error: file not found'
    }

    It 'suppresses tool output in Minimal mode and formats single line tool call' {
        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Logging Write-Host { param($Object) $printed.Add([string]$Object) }
        $callJson = '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"{\"command\":\"git status\"}"}}'
        $outJson = '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"text":"On branch main"}]}}'

        Format-CodexSessionEvent -Line $callJson -LogLevel 'Minimal'
        Format-CodexSessionEvent -Line $outJson -LogLevel 'Minimal'

        $all = $printed -join "`n"
        $all | Should -Match '--> \[TOOL: exec\] git status'
        $all | Should -Not -Match 'On branch main'
    }

    It 'truncates tool output appropriately for Compact vs Full' {
        $printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Logging Write-Host { param($Object) $printed.Add([string]$Object) }
        $longOutput = 'x' * 1000
        $outJson = '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"text":"' + $longOutput + '"}]}}'

        Format-CodexSessionEvent -Line $outJson -LogLevel 'Compact'
        ($printed -join "`n") | Should -Match '\[truncated: 1000 chars total\]'

        $printed.Clear()
        Format-CodexSessionEvent -Line $outJson -LogLevel 'Full'
        ($printed -join "`n") | Should -Not -Match '\[truncated'
        ($printed -join "`n") | Should -Match ('x' * 1000)
    }
}
}
