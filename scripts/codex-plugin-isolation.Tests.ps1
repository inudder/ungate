BeforeAll {
    $modulePath = Join-Path $PSScriptRoot 'codex-plugin-isolation.psm1'
    Import-Module $modulePath -Force

function New-TestCodexHomes {
    param([Parameter(Mandatory = $true)][string]$Root)

    $Root = Join-Path $Root ([guid]::NewGuid().ToString('N'))
    $defaultHome = Join-Path $Root 'default'
    $customHome = Join-Path $Root 'custom'
    New-Item -ItemType Directory -Path (Join-Path $defaultHome 'plugins') -Force | Out-Null
    New-Item -ItemType Directory -Path $customHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $defaultHome 'config.toml'), "model = 'default'")
    [System.IO.File]::WriteAllText((Join-Path $customHome 'config.toml'), "model = 'custom'")
    return [pscustomobject]@{
        DefaultHome = $defaultHome
        CustomHome = $customHome
    }
}

function New-TestBetaMarketplace {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$PluginNames = @('browser')
    )

    $marketplace = Join-Path `
        $Root `
        ('beta-marketplace-' + [guid]::NewGuid().ToString('N'))
    $manifestDirectory = Join-Path $marketplace '.agents\plugins'
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $plugins = @($PluginNames | ForEach-Object {
        [ordered]@{
            name = $_
            source = [ordered]@{ source = 'local'; path = "./plugins/$_" }
        }
    })
    [System.IO.File]::WriteAllText(
        (Join-Path $manifestDirectory 'marketplace.json'),
        ([ordered]@{ name = 'openai-bundled'; plugins = $plugins } | ConvertTo-Json -Depth 10)
    )
    $browserScripts = Join-Path $marketplace 'plugins\browser\scripts'
    New-Item -ItemType Directory -Path $browserScripts -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $browserScripts 'browser-client.mjs'),
        'trusted beta browser client'
    )
    return $marketplace
}
}

Describe 'Get-CodexPluginDirectoryState' {
    It 'reports a missing plugin directory' {
        $homes = New-TestCodexHomes -Root $TestDrive

        $state = Get-CodexPluginDirectoryState `
            -DefaultCodexHome $homes.DefaultHome `
            -CustomCodexHome $homes.CustomHome

        $state.Kind | Should -Be 'Missing'
    }

    It 'reports a real isolated directory' {
        $homes = New-TestCodexHomes -Root $TestDrive
        New-Item -ItemType Directory -Path (Join-Path $homes.CustomHome 'plugins') | Out-Null

        $state = Get-CodexPluginDirectoryState `
            -DefaultCodexHome $homes.DefaultHome `
            -CustomCodexHome $homes.CustomHome

        $state.Kind | Should -Be 'Directory'
    }

    It 'accepts only the expected normal-Codex junction' {
        $homes = New-TestCodexHomes -Root $TestDrive
        New-Item `
            -ItemType Junction `
            -Path (Join-Path $homes.CustomHome 'plugins') `
            -Target (Join-Path $homes.DefaultHome 'plugins') | Out-Null

        $state = Get-CodexPluginDirectoryState `
            -DefaultCodexHome $homes.DefaultHome `
            -CustomCodexHome $homes.CustomHome

        $state.Kind | Should -Be 'ExpectedJunction'
    }

    It 'rejects a junction to any other directory' {
        $homes = New-TestCodexHomes -Root $TestDrive
        $foreign = Join-Path $TestDrive 'foreign'
        New-Item -ItemType Directory -Path $foreign | Out-Null
        New-Item `
            -ItemType Junction `
            -Path (Join-Path $homes.CustomHome 'plugins') `
            -Target $foreign | Out-Null

        $state = Get-CodexPluginDirectoryState `
            -DefaultCodexHome $homes.DefaultHome `
            -CustomCodexHome $homes.CustomHome

        $state.Kind | Should -Be 'ForeignLink'
    }
}

Describe 'initial plugin isolation migration' {
    BeforeEach {
        $script:homes = New-TestCodexHomes -Root $TestDrive
        $script:marketplace = New-TestBetaMarketplace `
            -Root $TestDrive `
            -PluginNames @('browser', 'computer-use', 'visualize')
        $script:codex = Join-Path $TestDrive 'codex.exe'
        $script:expectedPluginIds = @(
            'browser@openai-bundled',
            'computer-use@openai-bundled',
            'documents@openai-primary-runtime',
            'github@openai-curated',
            'pdf@openai-primary-runtime',
            'presentations@openai-primary-runtime',
            'spreadsheets@openai-primary-runtime',
            'template-creator@openai-primary-runtime',
            'visualize@openai-bundled'
        )
        [System.IO.File]::WriteAllText($script:codex, '')
        [System.IO.File]::WriteAllText(
            (Join-Path $script:homes.CustomHome 'config.toml'),
            "[plugins.`"browser-use@openai-bundled`"]`nenabled = true"
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $script:homes.DefaultHome 'plugins\sentinel.txt'),
            'normal Codex must remain unchanged'
        )
        New-Item `
            -ItemType Junction `
            -Path (Join-Path $script:homes.CustomHome 'plugins') `
            -Target (Join-Path $script:homes.DefaultHome 'plugins') | Out-Null

        Mock Get-CodexPluginInventory -ModuleName codex-plugin-isolation {
            return [pscustomobject]@{
                Installed = @($script:expectedPluginIds | ForEach-Object {
                    [pscustomobject]@{ pluginId = $_; installed = $true }
                })
                Marketplaces = @(
                    [pscustomobject]@{
                        name = 'unused'
                        root = $TestDrive
                    }
                )
            }
        }
        Mock Resolve-MarketplaceSources -ModuleName codex-plugin-isolation {
            return [ordered]@{
                'openai-bundled' = $script:marketplace
                'openai-curated' = $TestDrive
            }
        }
        Mock Install-StagedPlugins -ModuleName codex-plugin-isolation {
            param($StagingHome, $PluginIds)
            $unexpected = @($PluginIds | Where-Object { $_ -notin $script:expectedPluginIds })
            $missing = @($script:expectedPluginIds | Where-Object { $_ -notin $PluginIds })
            if ($unexpected.Count -gt 0 -or $missing.Count -gt 0) {
                throw "Unexpected staged plugin list: $($PluginIds -join ', ')"
            }
            $scripts = Join-Path $StagingHome 'plugins\cache\openai-bundled\browser\test\scripts'
            New-Item -ItemType Directory -Path $scripts -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $scripts 'browser-client.mjs'),
                'trusted beta browser client'
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $StagingHome 'config.toml'),
                "[plugins.`"browser@openai-bundled`"]`nenabled = true"
            )
        }
        Mock Assert-StagedPluginInstallation -ModuleName codex-plugin-isolation {
            return [pscustomobject]@{
                PluginIds = $script:expectedPluginIds
                Browser = [pscustomobject]@{
                    SourceSha256 = 'TEST-BROWSER-HASH'
                }
            }
        }
    }

    It 'moves all installed plugins into a real directory and leaves normal Codex intact' {
        $result = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $result.Action | Should -Be 'Migrated'
        $result.PluginIds.Count | Should -Be 9
        (Get-Item (Join-Path $script:homes.CustomHome 'plugins') -Force).LinkType |
            Should -BeNullOrEmpty
        Test-Path (Join-Path $script:homes.DefaultHome 'plugins\sentinel.txt') |
            Should -BeTrue
        Get-Content (Join-Path $script:homes.DefaultHome 'plugins\sentinel.txt') |
            Should -Be 'normal Codex must remain unchanged'
        Get-Content (Join-Path $script:homes.CustomHome 'config.toml') -Raw |
            Should -Not -Match 'browser-use'
    }

    It 'does not remove the junction when staging fails' {
        Mock Install-StagedPlugins -ModuleName codex-plugin-isolation {
            throw 'simulated staging failure'
        }

        {
            Initialize-CodexBetaPluginIsolation `
                -DefaultCodexHome $script:homes.DefaultHome `
                -CustomCodexHome $script:homes.CustomHome `
                -CodexExecutable $script:codex `
                -BetaBundledMarketplace $script:marketplace `
                -BetaPackageVersion 'test-beta' `
                -BetaIsRunning $false
        } | Should -Throw '*simulated staging failure*'

        $state = Get-CodexPluginDirectoryState `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome
        $state.Kind | Should -Be 'ExpectedJunction'
        Test-Path (Join-Path $script:homes.DefaultHome 'plugins\sentinel.txt') |
            Should -BeTrue
    }

    It 'refuses to migrate while Codex Beta is running' {
        {
            Initialize-CodexBetaPluginIsolation `
                -DefaultCodexHome $script:homes.DefaultHome `
                -CustomCodexHome $script:homes.CustomHome `
                -CodexExecutable $script:codex `
                -BetaBundledMarketplace $script:marketplace `
                -BetaPackageVersion 'test-beta' `
                -BetaIsRunning $true
        } | Should -Throw '*Codex Beta is running*'

        (Get-CodexPluginDirectoryState `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome).Kind |
            Should -Be 'ExpectedJunction'
    }
}

Describe 'curated marketplace staging' {
    It 'copies the curated snapshot and SHA but does not add the reserved marketplace' {
        $homes = New-TestCodexHomes -Root $TestDrive
        $curated = Join-Path $homes.DefaultHome '.tmp\plugins'
        $curatedManifest = Join-Path $curated '.agents\plugins'
        New-Item -ItemType Directory -Path $curatedManifest -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $curatedManifest 'marketplace.json'),
            '{"name":"openai-curated","plugins":[]}'
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $homes.DefaultHome '.tmp\plugins.sha'),
            "0123456789abcdef`n"
        )
        $staging = Join-Path $homes.CustomHome '.plugin-isolation-staging-test'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Copy-Item `
            -LiteralPath (Join-Path $homes.CustomHome 'config.toml') `
            -Destination (Join-Path $staging 'config.toml')

        InModuleScope codex-plugin-isolation -Parameters @{
            DefaultHome = $homes.DefaultHome
            StagingHome = $staging
            Curated = $curated
        } {
            param($DefaultHome, $StagingHome, $Curated)
            $sources = Resolve-MarketplaceSources `
                -PluginIds @('github@openai-curated') `
                -Marketplaces @([pscustomobject]@{
                    name = 'openai-curated'
                    root = $Curated
                }) `
                -DefaultCodexHome $DefaultHome `
                -StagingHome $StagingHome `
                -BetaBundledMarketplace $TestDrive

            Test-Path `
                (Join-Path $StagingHome '.plugin-marketplaces\openai-curated') |
                Should -BeTrue
            Test-Path (Join-Path $StagingHome '.tmp\plugins') | Should -BeTrue
            Get-Content (Join-Path $StagingHome '.tmp\plugins.sha') -Raw |
                Should -Match '^0123456789abcdef'

            Mock Reset-StagedPluginConfiguration {}
            Mock Invoke-CodexPluginJson { return [pscustomobject]@{} }
            Install-StagedPlugins `
                -CodexExecutable (Join-Path $TestDrive 'codex.exe') `
                -StagingHome $StagingHome `
                -PluginIds @('github@openai-curated') `
                -MarketplaceSources $sources

            Should -Invoke Invoke-CodexPluginJson `
                -Times 0 `
                -ParameterFilter { $Arguments[0] -eq 'marketplace' }
            Should -Invoke Invoke-CodexPluginJson `
                -Times 1 `
                -ParameterFilter {
                    $Arguments[0] -eq 'add' -and
                    $Arguments[1] -eq 'github@openai-curated'
                }
        }
    }
}

Describe 'migration commit rollback' {
    It 'recreates the original junction when config replacement fails' {
        $homes = New-TestCodexHomes -Root $TestDrive
        [System.IO.File]::WriteAllText(
            (Join-Path $homes.DefaultHome 'plugins\sentinel.txt'),
            'still present'
        )
        New-Item `
            -ItemType Junction `
            -Path (Join-Path $homes.CustomHome 'plugins') `
            -Target (Join-Path $homes.DefaultHome 'plugins') | Out-Null
        $staging = Join-Path $homes.CustomHome '.plugin-isolation-staging-test'
        New-Item -ItemType Directory -Path (Join-Path $staging 'plugins') -Force | Out-Null
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $staging '.plugin-marketplaces\openai-curated') `
            -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $staging '.tmp\plugins') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $staging '.tmp\plugins.sha'), 'new-sha')
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $homes.CustomHome '.plugin-marketplaces\legacy') `
            -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $homes.CustomHome '.plugin-marketplaces\legacy\sentinel.txt'),
            'legacy-marketplace'
        )
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $homes.CustomHome '.tmp\plugins') `
            -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $homes.CustomHome '.tmp\plugins\sentinel.txt'),
            'old-curated'
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $homes.CustomHome '.tmp\plugins.sha'),
            'old-sha'
        )
        [System.IO.File]::WriteAllText((Join-Path $staging 'config.toml'), "model = 'staged'")

        InModuleScope codex-plugin-isolation -Parameters @{
            DefaultHome = $homes.DefaultHome
            CustomHome = $homes.CustomHome
            StagingHome = $staging
        } {
            param($DefaultHome, $CustomHome, $StagingHome)
            Mock Set-StagedConfig { throw 'simulated commit failure' }
            $state = Get-CodexPluginDirectoryState `
                -DefaultCodexHome $DefaultHome `
                -CustomCodexHome $CustomHome

            {
                Commit-StagedPluginIsolation `
                    -DirectoryState $state `
                    -DefaultCodexHome $DefaultHome `
                    -CustomCodexHome $CustomHome `
                    -StagingHome $StagingHome
            } | Should -Throw '*simulated commit failure*'

            (Get-CodexPluginDirectoryState `
                -DefaultCodexHome $DefaultHome `
                -CustomCodexHome $CustomHome).Kind | Should -Be 'ExpectedJunction'
        }

        Test-Path (Join-Path $homes.DefaultHome 'plugins\sentinel.txt') | Should -BeTrue
        Get-Content (Join-Path $homes.CustomHome 'config.toml') | Should -Be "model = 'custom'"
        Get-Content `
            (Join-Path $homes.CustomHome '.plugin-marketplaces\legacy\sentinel.txt') |
            Should -Be 'legacy-marketplace'
        Get-Content (Join-Path $homes.CustomHome '.tmp\plugins\sentinel.txt') |
            Should -Be 'old-curated'
        Get-Content (Join-Path $homes.CustomHome '.tmp\plugins.sha') |
            Should -Be 'old-sha'
    }
}

Describe 'existing isolated plugin directory' {
    BeforeEach {
        $script:homes = New-TestCodexHomes -Root $TestDrive
        $script:marketplace = New-TestBetaMarketplace -Root $TestDrive
        $script:codex = Join-Path $TestDrive 'codex.exe'
        [System.IO.File]::WriteAllText($script:codex, '')
        $installedScripts = Join-Path `
            $script:homes.CustomHome `
            'plugins\cache\openai-bundled\browser\test\scripts'
        New-Item -ItemType Directory -Path $installedScripts -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $installedScripts 'browser-client.mjs'),
            'trusted beta browser client'
        )
        Mock Get-CodexPluginInventory -ModuleName codex-plugin-isolation {
            return [pscustomobject]@{
                Installed = @(
                    [pscustomobject]@{
                        pluginId = 'browser@openai-bundled'
                        installed = $true
                    }
                )
                Marketplaces = @(
                    [pscustomobject]@{
                        name = 'openai-bundled'
                        root = $script:marketplace
                    }
                )
            }
        }
        Mock Invoke-BundledPluginReconciliation -ModuleName codex-plugin-isolation {
            return [pscustomobject]@{
                Changed = $true
                Action = 'Reconciled'
                PluginIds = @('browser@openai-bundled')
                BrowserSha256 = 'UPDATED'
                BackupRoot = $null
            }
        }
    }

    It 'is idempotent when Browser and marketplace already match Beta' {
        $first = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false
        $second = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $first.Changed | Should -BeFalse
        $second.Changed | Should -BeFalse
        Test-Path `
            (Join-Path $script:homes.CustomHome 'plugins\.ungate-plugin-isolation.json') |
            Should -BeTrue
    }

    It 'reconciles only the custom profile when the Browser hash changes' {
        [System.IO.File]::WriteAllText(
            (Get-ChildItem `
                (Join-Path $script:homes.CustomHome 'plugins') `
                -Recurse `
                -Filter 'browser-client.mjs').FullName,
            'stale browser client'
        )

        $result = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $result.Action | Should -Be 'Reconciled'
        Test-Path (Join-Path $script:homes.DefaultHome 'plugins') | Should -BeTrue
    }

    It 'refreshes a stale bundled marketplace before reading plugin inventory' {
        $staleMarketplace = Join-Path $TestDrive 'removed-beta-marketplace'
        [System.IO.File]::WriteAllText(
            (Join-Path $script:homes.CustomHome 'config.toml'),
            @"
model = 'custom'

[marketplaces.openai-bundled]
last_updated = "2026-07-16T14:22:56Z"
source_type = "local"
source = '\\?\$staleMarketplace'
"@
        )
        Mock Get-CodexPluginInventory -ModuleName codex-plugin-isolation {
            param($CodexHome)
            $config = Get-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Raw
            if ($config -notmatch [regex]::Escape($script:marketplace)) {
                throw 'plugin inventory was read before the stale marketplace was refreshed'
            }
            return [pscustomobject]@{
                Installed = @(
                    [pscustomobject]@{
                        pluginId = 'browser@openai-bundled'
                        installed = $true
                    }
                )
                Marketplaces = @(
                    [pscustomobject]@{
                        name = 'openai-bundled'
                        root = $script:marketplace
                    }
                )
            }
        }

        $result = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $result.Action | Should -Be 'Reconciled'
        $config = Get-Content -LiteralPath (Join-Path $script:homes.CustomHome 'config.toml') -Raw
        $config | Should -Match ([regex]::Escape($script:marketplace))
        $config | Should -Not -Match ([regex]::Escape($staleMarketplace))
        Should -Invoke Invoke-BundledPluginReconciliation `
            -ModuleName codex-plugin-isolation `
            -Times 1 `
            -Exactly
    }

    It 'does not rewrite a stale marketplace while Codex Beta is running' {
        $staleMarketplace = Join-Path $TestDrive 'removed-beta-marketplace'
        $configPath = Join-Path $script:homes.CustomHome 'config.toml'
        $originalConfig = @"
model = 'custom'

[marketplaces.openai-bundled]
source_type = "local"
source = '\\?\$staleMarketplace'
"@
        [System.IO.File]::WriteAllText($configPath, $originalConfig)

        {
            Initialize-CodexBetaPluginIsolation `
                -DefaultCodexHome $script:homes.DefaultHome `
                -CustomCodexHome $script:homes.CustomHome `
                -CodexExecutable $script:codex `
                -BetaBundledMarketplace $script:marketplace `
                -BetaPackageVersion 'test-beta' `
                -BetaIsRunning $true
        } | Should -Throw '*bundled marketplace path changed*'

        Get-Content -LiteralPath $configPath -Raw | Should -BeExactly $originalConfig
        Should -Invoke Get-CodexPluginInventory `
            -ModuleName codex-plugin-isolation `
            -Times 0 `
            -Exactly
    }
}

Describe 'normal Codex inventory access' {
    It 'uses only read-only plugin commands for the normal profile' {
        $homes = New-TestCodexHomes -Root $TestDrive
        $codex = Join-Path $TestDrive 'codex.exe'
        [System.IO.File]::WriteAllText($codex, '')

        InModuleScope codex-plugin-isolation -Parameters @{
            DefaultHome = $homes.DefaultHome
            CodexPath = $codex
        } {
            param($DefaultHome, $CodexPath)
            Mock Invoke-CodexPluginJson {
                param($Arguments)
                if ($Arguments[0] -in @('add', 'remove')) {
                    throw "Mutating command used for normal CODEX_HOME: $($Arguments -join ' ')"
                }
                if ($Arguments[0] -eq 'list') {
                    return [pscustomobject]@{ installed = @() }
                }
                return [pscustomobject]@{ marketplaces = @() }
            }

            $null = Get-CodexPluginInventory `
                -CodexExecutable $CodexPath `
                -CodexHome $DefaultHome
        }
    }
}
