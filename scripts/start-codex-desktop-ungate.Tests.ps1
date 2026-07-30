BeforeAll {
    $script:launcherPath = Join-Path $PSScriptRoot 'start-codex-desktop-ungate.ps1'
    $tokens = $null
    $parseErrors = $null
    $launcherAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:launcherPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | ForEach-Object Message | Out-String)
    }

    $functionNames = @(
        'ConvertTo-UngateModelDefinition',
        'Read-UngateCustomModelDefinitions',
        'Write-UngateCustomModelDefinitions',
        'Get-UngateModelDefinitions',
        'Read-UngateMenuChoice',
        'Read-UngateYesNo',
        'Invoke-AddUngateModelMode',
        'Select-UngateDesktopModel',
        'Get-ProviderDefinitions',
        'Resolve-ModelApiKey',
        'Invoke-OmniRoutePreflight',
        'Get-ProviderTomlBlock',
        'Ensure-ModelProvidersInConfig',
        'Set-TopLevelTomlValue',
        'Set-ModelIdentity',
        'Write-UngateModelCatalog',
        'Remove-TomlTable',
        'Get-TomlTableFamilyContent',
        'Normalize-CodexHomePath',
        'Get-CodexHistoryProfileInfo',
        'Get-CodexCliExecutable',
        'Test-CodexMcpConfiguration',
        'Sync-CodexMcpServers'
    )
    foreach ($functionName in $functionNames) {
        $definition = $launcherAst.FindAll(
            {
                param($ast)
                $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $ast.Name -eq $functionName
            },
            $true
        ) | Select-Object -First 1
        if (-not $definition) {
            throw "Launcher function '$functionName' was not found."
        }
        Set-Item -Path "Function:$functionName" -Value $definition.Body.GetScriptBlock()
    }

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

Describe 'Optional OmniRoute provider fallback' {
    BeforeEach {
        $script:OmniRouteProviderName = 'omniroute'
        $script:RepoRoot = $TestDrive
        $script:previousOmniRouteApiKey = $env:OMNIROUTE_API_KEY
        Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:previousOmniRouteApiKey) {
            Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:OMNIROUTE_API_KEY = $script:previousOmniRouteApiKey
        }
    }

    It 'uses an explicit OmniRoute key before the environment and never falls back to SQLite' {
        $env:OMNIROUTE_API_KEY = 'environment-key'
        $definition = [pscustomobject]@{ ProviderName = 'omniroute'; RequiresUngate = $false }

        Resolve-ModelApiKey -Definition $definition -ApiKey 'argument-key' |
            Should -BeExactly 'argument-key'
        Resolve-ModelApiKey -Definition $definition |
            Should -BeExactly 'environment-key'
    }

    It 'fails clearly when no OmniRoute client key is configured' {
        $definition = [pscustomobject]@{ ProviderName = 'omniroute'; RequiresUngate = $false }

        { Resolve-ModelApiKey -Definition $definition } |
            Should -Throw '*Pass -ApiKey or set OMNIROUTE_API_KEY*'
    }

    It 'does not add OmniRoute to active providers without the switch' {
        $script:UngateModelDefinitions = @(
            [pscustomobject]@{
                ProviderName = 'ungate_proxy'
                ProviderDisplayName = 'Ungate Proxy'
                ProxyBaseUrl = 'http://127.0.0.1:47821'
                EnvKey = 'UNGATE_API_KEY'
            }
        )

        @((Get-ProviderDefinitions).Name) | Should -Be @('ungate_proxy')
    }

    It 'rejects an explicit model together with provider fallback' {
        $customHome = Join-Path $TestDrive 'fallback-conflict-home'
        $powerShellExecutable = (Get-Command pwsh -ErrorAction Stop).Source
        $arguments = @(
            '-NoProfile',
            '-File', $script:launcherPath,
            '-EnableProviderFallback',
            '-Model', 'grok-4.5',
            '-CustomCodexHome', $customHome
        )

        $output = @(& $powerShellExecutable @arguments 2>&1)

        $LASTEXITCODE | Should -Not -Be 0
        $output -join "`n" | Should -Match 'EnableProviderFallback cannot be combined with -Model'
    }
}

Describe 'Custom launcher model registry' {
    BeforeEach {
        $script:UngateEnvironmentInstruction = 'Test environment instructions.'
        $script:ProviderName = 'ungate_proxy'
        $script:ProxyBaseUrl = 'http://127.0.0.1:47821'
        $script:CliProxyProviderName = 'cliproxyapi'
        $script:CliProxyBaseUrl = 'http://127.0.0.1:8318'
        $script:builtInDefinitions = @(
            [pscustomobject][ordered]@{
                Slug = 'ungate-opus-4-8'
                DisplayName = 'Claude Opus 4.8 (Ungate)'
                Priority = 0
            }
            [pscustomobject][ordered]@{
                Slug = 'grok-4.5'
                DisplayName = 'Grok 4.5 (CLIProxyAPI)'
                Priority = 1
            }
        )
        $script:registryPath = Join-Path $TestDrive 'ungate-model-definitions.json'
    }

    It 'returns only built-in definitions when the registry does not exist' {
        $definitions = @(
            Get-UngateModelDefinitions `
                -BuiltInDefinitions $script:builtInDefinitions `
                -RegistryPath $script:registryPath
        )

        $definitions | Should -HaveCount 2
        @($definitions.Slug) | Should -Be @('ungate-opus-4-8', 'grok-4.5')
    }

    It 'round-trips a versioned registry without losing persisted fields' {
        $record = New-CustomModelTestRecord

        $savedPath = Write-UngateCustomModelDefinitions `
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
            Read-UngateCustomModelDefinitions `
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
        $null = Write-UngateCustomModelDefinitions `
            -RegistryPath $script:registryPath `
            -Records $records `
            -BuiltInDefinitions $script:builtInDefinitions

        $definitions = @(
            Get-UngateModelDefinitions `
                -BuiltInDefinitions $script:builtInDefinitions `
                -RegistryPath $script:registryPath
        )

        $definitions | Should -HaveCount 4
        @($definitions.Slug) | Should -Be @(
            'ungate-opus-4-8',
            'grok-4.5',
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
            ConvertTo-UngateModelDefinition `
                -Record (New-CustomModelTestRecord -Slug '') `
                -Priority 2
        } | Should -Throw '*cannot be empty*'
        {
            ConvertTo-UngateModelDefinition `
                -Record (New-CustomModelTestRecord -Slug 'bad model') `
                -Priority 2
        } | Should -Throw '*cannot contain whitespace*'
        {
            Write-UngateCustomModelDefinitions `
                -RegistryPath $script:registryPath `
                -Records @(
                    New-CustomModelTestRecord -Slug 'UNGATE-OPUS-4-8'
                ) `
                -BuiltInDefinitions $script:builtInDefinitions
        } | Should -Throw '*duplicates an existing model*'
    }

    It 'rejects unsupported transports and reasoning levels' {
        {
            ConvertTo-UngateModelDefinition `
                -Record (New-CustomModelTestRecord -Transport 'unknown') `
                -Priority 2
        } | Should -Throw '*unsupported transport*'
        {
            ConvertTo-UngateModelDefinition `
                -Record (New-CustomModelTestRecord -ReasoningLevel 'extreme') `
                -Priority 2
        } | Should -Throw '*unsupported reasoning level*'
    }

    It 'preserves the existing registry and leaves no temporary file after validation fails' {
        $null = Write-UngateCustomModelDefinitions `
            -RegistryPath $script:registryPath `
            -Records @((New-CustomModelTestRecord)) `
            -BuiltInDefinitions $script:builtInDefinitions
        $beforeHash = (Get-FileHash -LiteralPath $script:registryPath -Algorithm SHA256).Hash

        {
            Write-UngateCustomModelDefinitions `
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
        $definition = ConvertTo-UngateModelDefinition `
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
        $definition.Identity | Should -Match 'claude-opus-5'
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
        $builtInDefinition = ConvertTo-UngateModelDefinition `
            -Record (
                New-CustomModelTestRecord `
                    -Slug 'ungate-opus-4-8' `
                    -DisplayName 'Claude Opus 4.8 (Ungate)' `
                    -UpstreamModel 'claude-opus-4-8'
            ) `
            -Priority 0
        $customDefinition = ConvertTo-UngateModelDefinition `
            -Record (New-CustomModelTestRecord) `
            -Priority 1
        $script:UngateModelDefinitions = @($builtInDefinition, $customDefinition)
        $script:Model = 'ungate-opus-5'
        $script:selectedModelDefinition = $customDefinition
        $script:DefaultModelCachePath = Join-Path $TestDrive 'models_cache.json'
        $script:CustomModelCatalogPath = Join-Path $TestDrive 'ungate-models.json'
        $script:CustomConfigPath = Join-Path $TestDrive 'config.toml'

        $defaultCatalog = [ordered]@{
            models = @(
                [ordered]@{
                    slug = 'gpt-template'
                    display_name = 'GPT Template'
                    description = 'Template model'
                    base_instructions = 'Template instructions'
                    model_messages = [ordered]@{
                        instructions_template = 'Template instructions'
                    }
                }
            )
        } | ConvertTo-Json -Depth 20
        Write-Utf8TestFile `
            -LiteralPath $script:DefaultModelCachePath `
            -Content $defaultCatalog
        Write-Utf8TestFile `
            -LiteralPath $script:CustomConfigPath `
            -Content 'model = "gpt-template"'

        Write-UngateModelCatalog

        $catalog = Get-Content -LiteralPath $script:CustomModelCatalogPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100
        @($catalog.Models) | Should -HaveCount 2
        $opus5 = $catalog.Models |
            Where-Object { $_.slug -eq 'ungate-opus-5' } |
            Select-Object -First 1
        $opus5.display_name | Should -BeExactly 'Claude Opus 5 (Ungate)'
        $opus5.default_reasoning_level | Should -BeExactly 'high'
        @($opus5.input_modalities) | Should -Be @('text', 'image')
        $opus5.base_instructions | Should -Match 'claude-opus-5'

        $config = Get-Content -LiteralPath $script:CustomConfigPath -Raw
        $config | Should -Match '(?m)^model = "ungate-opus-5"\r?$'
        $config | Should -Match '(?m)^model_provider = "ungate_proxy"\r?$'
        $config | Should -Match '(?m)^model_reasoning_effort = "high"\r?$'
        $config | Should -Match '(?m)^\[model_providers\.ungate_proxy\]\r?$'
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
        $script:selectionInputs.Enqueue('2')
        $script:selectionInputs.Enqueue('2')
        $script:selectionDefinitionsAfterAdd = @(
            $script:selectionDefinitions
            [pscustomobject]@{
                Slug = 'ungate-opus-5'
                DisplayName = 'Claude Opus 5 (Ungate)'
            }
        )
        Mock Read-Host {
            return $script:selectionInputs.Dequeue()
        }
        Mock Invoke-AddUngateModelMode {}
        Mock Get-UngateModelDefinitions {
            return @($script:selectionDefinitionsAfterAdd)
        }

        $selected = Select-UngateDesktopModel `
            -Definitions $script:selectionDefinitions `
            -BuiltInDefinitions $script:builtInDefinitions `
            -RegistryPath $script:registryPath

        $selected | Should -BeExactly 'ungate-opus-5'
        Should -Invoke Invoke-AddUngateModelMode -Times 1 -Exactly
        Should -Invoke Get-UngateModelDefinitions -Times 1 -Exactly
    }

    It 'selects the OmniRoute fallback checkbox with a keyboard shortcut' {
        $script:selectionInputs = [System.Collections.Generic.Queue[string]]::new()
        $script:selectionInputs.Enqueue('f')
        Mock Read-Host {
            return $script:selectionInputs.Dequeue()
        }

        $selected = Select-UngateDesktopModel `
            -Definitions $script:selectionDefinitions `
            -BuiltInDefinitions $script:builtInDefinitions `
            -RegistryPath $script:registryPath `
            -IncludeProviderFallback `
            -ProviderFallbackModel 'codex-fallback'

        $selected | Should -BeExactly 'codex-fallback'
    }
}

Describe 'Codex launcher history profile' {
    It 'uses one canonical history home for every launcher model' {
        $canonicalHome = Join-Path $TestDrive 'codex-ungate'
        $models = @(
            [pscustomobject]@{ Slug = 'ungate-opus-4-8'; Provider = 'ungate_proxy' }
            [pscustomobject]@{ Slug = 'ungate-fable-5'; Provider = 'ungate_proxy' }
            [pscustomobject]@{ Slug = 'miniMax-M3'; Provider = 'ungate_proxy' }
            [pscustomobject]@{ Slug = 'grok-4.5'; Provider = 'cliproxyapi' }
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
            -ModelSlug 'grok-4.5' `
            -ProviderName 'cliproxyapi'

        $profile.IsCanonical | Should -BeFalse
        $profile.CodexHome | Should -Be ([System.IO.Path]::GetFullPath($separateHome))
    }
}

Describe 'Get-CodexCliExecutable' {
    BeforeEach {
        $script:cliTestRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:cliTestRoot -Force | Out-Null
        $script:DefaultConfigPath = Join-Path $script:cliTestRoot 'default-config.toml'
        $script:CustomConfigPath = Join-Path $script:cliTestRoot 'custom-config.toml'
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
            -LiteralPath $script:DefaultConfigPath `
            -Content "CODEX_CLI_PATH = '$nativeCli'"
        Mock Get-Command { $null }

        Get-CodexCliExecutable | Should -BeExactly (Resolve-Path -LiteralPath $nativeCli).Path
    }

    It 'ignores a stale configured path and resolves the native npm CLI behind a PowerShell wrapper' {
        Write-Utf8TestFile `
            -LiteralPath $script:DefaultConfigPath `
            -Content "CODEX_CLI_PATH = 'C:\missing\codex.exe'"
        $npmRoot = Join-Path $script:cliTestRoot 'npm'
        $wrapperPath = Join-Path $npmRoot 'codex.ps1'
        $nativeCli = Join-Path `
            $npmRoot `
            'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $nativeCli) -Force | Out-Null
        New-Item -ItemType File -Path $wrapperPath -Force | Out-Null
        New-Item -ItemType File -Path $nativeCli -Force | Out-Null
        Mock Get-Command {
            [pscustomobject]@{
                Source = $wrapperPath
                CommandType = 'ExternalScript'
            }
        }

        Get-CodexCliExecutable | Should -BeExactly (Resolve-Path -LiteralPath $nativeCli).Path
    }

    It 'does not return a PowerShell wrapper when no native executable exists' {
        $wrapperPath = Join-Path $script:cliTestRoot 'npm\codex.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperPath) -Force | Out-Null
        New-Item -ItemType File -Path $wrapperPath -Force | Out-Null
        Mock Get-Command {
            [pscustomobject]@{
                Source = $wrapperPath
                CommandType = 'ExternalScript'
            }
        }

        Get-CodexCliExecutable | Should -BeNullOrEmpty
    }
}

Describe 'Sync-CodexMcpServers' {
    BeforeEach {
        Mock Get-CodexCliExecutable { 'C:\test\codex.exe' }
        Mock Test-CodexMcpConfiguration { @('context7', 'node_repl', 'openaiDeveloperDocs', 'playwright') }
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

        Sync-CodexMcpServers `
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

        Sync-CodexMcpServers `
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

        Sync-CodexMcpServers `
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
        Mock Test-CodexMcpConfiguration { throw 'source config rejected' }

        {
            Sync-CodexMcpServers `
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
            Sync-CodexMcpServers `
                -SourceCodexHome $homes.SourceCodexHome `
                -TargetCodexHome $homes.TargetCodexHome
        } | Should -Throw '*Default Codex config not found*'

        (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
        Should -Not -Invoke Test-CodexMcpConfiguration
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
        Mock Test-CodexMcpConfiguration {
            param($CodexExecutable, $CodexHome)
            if ($CodexHome -eq $homes.TargetCodexHome) {
                throw 'target config rejected'
            }
            return @('context7')
        }

        {
            Sync-CodexMcpServers `
                -SourceCodexHome $homes.SourceCodexHome `
                -TargetCodexHome $homes.TargetCodexHome
        } | Should -Throw '*previous Beta config was restored*'

        (Get-FileHash -LiteralPath $homes.TargetConfigPath -Algorithm SHA256).Hash |
            Should -BeExactly $beforeHash
        @(Get-ChildItem -LiteralPath $homes.TargetCodexHome -Filter '.config.toml.*').Count |
            Should -Be 0
    }
}
