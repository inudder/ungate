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
        'Remove-TomlTable',
        'Get-TomlTableFamilyContent',
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
