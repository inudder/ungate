BeforeAll {
    $modulePath = Join-Path $PSScriptRoot 'codex-plugin-isolation.psm1'
    Import-Module $modulePath -Force

    function New-TestPluginState {
        param([string]$PluginId, [bool]$Enabled = $true)
        [pscustomobject]@{ PluginId = $PluginId; Enabled = $Enabled }
    }

    function New-TestCodexHomes {
        param([Parameter(Mandatory = $true)][string]$Root)

        $base = Join-Path $Root ([guid]::NewGuid().ToString('N'))
        $defaultHome = Join-Path $base 'default'
        $customHome = Join-Path $base 'custom'
        New-Item -ItemType Directory -Path (Join-Path $defaultHome 'plugins') -Force | Out-Null
        New-Item -ItemType Directory -Path $customHome -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $defaultHome 'config.toml'), "model = 'default'`n")
        [System.IO.File]::WriteAllText((Join-Path $customHome 'config.toml'), "model = 'custom'`n")
        [pscustomobject]@{ DefaultHome = $defaultHome; CustomHome = $customHome }
    }

    function New-TestBetaMarketplace {
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [string[]]$PluginNames = @('browser', 'chrome', 'computer-use', 'sites', 'visualize')
        )

        $marketplace = Join-Path $Root ('beta-' + [guid]::NewGuid().ToString('N'))
        $manifestDirectory = Join-Path $marketplace '.agents\plugins'
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
        $plugins = @()
        $index = 0
        foreach ($name in $PluginNames) {
            $index++
            $pluginRoot = Join-Path $marketplace (Join-Path 'plugins' $name)
            New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.codex-plugin') -Force | Out-Null
            [System.IO.File]::WriteAllText(
                (Join-Path $pluginRoot '.codex-plugin\plugin.json'),
                (@{ name = $name; version = "1.0.$index" } | ConvertTo-Json)
            )
            if ($name -eq 'browser') {
                New-Item -ItemType Directory -Path (Join-Path $pluginRoot 'scripts') -Force | Out-Null
                [System.IO.File]::WriteAllText(
                    (Join-Path $pluginRoot 'scripts\browser-client.mjs'),
                    'trusted beta browser client'
                )
            }
            $plugins += [ordered]@{
                name = $name
                source = [ordered]@{ source = 'local'; path = "./plugins/$name" }
            }
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $manifestDirectory 'marketplace.json'),
            ([ordered]@{ name = 'openai-bundled'; plugins = $plugins } | ConvertTo-Json -Depth 10)
        )
        return $marketplace
    }

    function New-TestInventory {
        param(
            [Parameter(Mandatory = $true)][object[]]$PluginStates,
            [object[]]$Marketplaces = @()
        )

        [pscustomobject]@{
            Installed = @($PluginStates | ForEach-Object {
                [pscustomobject]@{
                    pluginId = $_.PluginId
                    enabled = $_.Enabled
                    installed = $true
                }
            })
            Marketplaces = $Marketplaces
        }
    }

    function Invoke-InitialMirror {
        [System.IO.File]::WriteAllText((Join-Path $script:homes.DefaultHome 'plugins\sentinel.txt'), 'normal Codex stays untouched')
        New-Item -ItemType Junction -Path (Join-Path $script:homes.CustomHome 'plugins') -Target (Join-Path $script:homes.DefaultHome 'plugins') | Out-Null
        $script:customStates = @($script:defaultStates | Where-Object { $_.PluginId -notmatch '@openai-bundled$' })
        Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false
    }
}

Describe 'Get-CodexPluginDirectoryState' {
    It 'recognizes a real isolated directory and the expected legacy junction' {
        $homes = New-TestCodexHomes -Root $TestDrive
        New-Item -ItemType Directory -Path (Join-Path $homes.CustomHome 'plugins') | Out-Null
        (Get-CodexPluginDirectoryState -DefaultCodexHome $homes.DefaultHome -CustomCodexHome $homes.CustomHome).Kind |
            Should -Be 'Directory'

        Remove-Item -LiteralPath (Join-Path $homes.CustomHome 'plugins') -Force
        New-Item -ItemType Junction -Path (Join-Path $homes.CustomHome 'plugins') -Target (Join-Path $homes.DefaultHome 'plugins') | Out-Null
        (Get-CodexPluginDirectoryState -DefaultCodexHome $homes.DefaultHome -CustomCodexHome $homes.CustomHome).Kind |
            Should -Be 'ExpectedJunction'
    }
}

Describe 'Set-PluginEnabledValue' {
    It 'updates an existing enabled property without colliding with the Enabled parameter' {
        $configPath = Join-Path $TestDrive 'existing-plugin-config.toml'
        [System.IO.File]::WriteAllText(
            $configPath,
            "[plugins.`"github@test-market`"]`nenabled = true`n[shell_environment_policy.set]`nTEST_VALUE = 'preserved'`n"
        )

        InModuleScope codex-plugin-isolation -Parameters @{ ConfigPath = $configPath } {
            param($ConfigPath)
            Set-PluginEnabledValue `
                -ConfigPath $ConfigPath `
                -PluginId 'github@test-market' `
                -Enabled $false
        }

        Get-Content -LiteralPath $configPath -Raw | Should -Match '(?m)^enabled = false$'
        Get-Content -LiteralPath $configPath -Raw |
            Should -Match "(?m)^\[shell_environment_policy\.set\]$\r?\n^TEST_VALUE = 'preserved'$"
    }
}

Describe 'isolated Codex Beta plugin mirror' {
    BeforeEach {
        $script:homes = New-TestCodexHomes -Root $TestDrive
        $script:marketplace = New-TestBetaMarketplace -Root $TestDrive
        $script:codex = Join-Path $TestDrive 'codex.exe'
        [System.IO.File]::WriteAllText($script:codex, '')
        [System.IO.File]::WriteAllText(
            (Join-Path $script:homes.CustomHome 'auth.json'),
            '{"auth_mode":"test"}'
        )
        $script:externalMarketplace = Join-Path $TestDrive 'external-marketplace'
        New-Item -ItemType Directory -Path $script:externalMarketplace -Force | Out-Null
        $script:marketplaces = @([pscustomobject]@{ name = 'test-market'; root = $script:externalMarketplace })
        $script:defaultStates = @(
            (New-TestPluginState 'browser@openai-bundled'),
            (New-TestPluginState 'chrome@openai-bundled'),
            (New-TestPluginState 'codex-app-tools@openai-bundled'),
            (New-TestPluginState 'computer-use@openai-bundled'),
            (New-TestPluginState 'github@test-market'),
            (New-TestPluginState 'sites@openai-bundled'),
            (New-TestPluginState 'visualize@openai-bundled' $false)
        )
        $script:customStates = @()

        Mock Get-CodexPluginInventory -ModuleName codex-plugin-isolation {
            param($CodexHome)
            if ($CodexHome -eq $script:homes.DefaultHome) {
                return New-TestInventory -PluginStates $script:defaultStates -Marketplaces $script:marketplaces
            }
            if ($CodexHome -eq $script:homes.CustomHome) {
                return New-TestInventory -PluginStates $script:customStates -Marketplaces $script:marketplaces
            }
            return New-TestInventory -PluginStates @($script:defaultStates | Where-Object { $_.PluginId -notmatch '@openai-bundled$' }) -Marketplaces $script:marketplaces
        }
        Mock Invoke-CodexPluginJson -ModuleName codex-plugin-isolation {
            return [pscustomobject]@{}
        }
    }

    It 'migrates bundled plugins without any CLI operation for openai-bundled' {
        $result = Invoke-InitialMirror

        $result.Action | Should -Be 'Migrated'
        $result.UnsupportedBundledPluginIds | Should -Be @('codex-app-tools@openai-bundled')
        $result.PluginIds | Should -Not -Contain 'codex-app-tools@openai-bundled'
        $cacheRoot = Join-Path $script:homes.CustomHome 'plugins\cache\openai-bundled'
        @(Get-ChildItem -LiteralPath $cacheRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -Be @('browser', 'chrome', 'computer-use', 'sites', 'visualize')
        (Get-Content -LiteralPath (Join-Path $script:homes.CustomHome 'config.toml') -Raw) |
            Should -Match '\[plugins\."visualize@openai-bundled"\]\s+enabled = false'
        (Get-Content -LiteralPath (Join-Path $script:homes.DefaultHome 'plugins\sentinel.txt')) |
            Should -Be 'normal Codex stays untouched'
        Should -Invoke Invoke-CodexPluginJson -ModuleName codex-plugin-isolation -Times 0 -ParameterFilter {
            ($Arguments -join ' ') -match 'openai-bundled'
        }
    }

    It 'synchronizes once when an external ID changes, including its enabled state' {
        $null = Invoke-InitialMirror
        $script:defaultStates = @(
            (New-TestPluginState 'browser@openai-bundled'),
            (New-TestPluginState 'chrome@openai-bundled'),
            (New-TestPluginState 'computer-use@openai-bundled'),
            (New-TestPluginState 'github@test-market' $false),
            (New-TestPluginState 'new-plugin@test-market'),
            (New-TestPluginState 'sites@openai-bundled'),
            (New-TestPluginState 'visualize@openai-bundled' $false)
        )
        Mock Install-StagedExternalPlugins -ModuleName codex-plugin-isolation {
            param($StagingHome)
            if (-not (Test-Path -LiteralPath (Join-Path $StagingHome 'auth.json') -PathType Leaf)) {
                throw 'staging auth.json was not copied'
            }
        }

        $result = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $result.Changed | Should -BeTrue
        $result.Action | Should -Be 'Synchronized'
        Should -Invoke Install-StagedExternalPlugins -ModuleName codex-plugin-isolation -Times 1 -Exactly
    }

    It 'is idempotent and ignores an external cache version change when IDs and enabled states match' {
        $null = Invoke-InitialMirror
        $externalCache = Join-Path $script:homes.CustomHome 'plugins\cache\test-market\github\old-version'
        New-Item -ItemType Directory -Path $externalCache -Force | Out-Null
        Mock Install-StagedExternalPlugins -ModuleName codex-plugin-isolation { throw 'unexpected external synchronization' }

        $result = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $result.Changed | Should -BeFalse
        $result.Action | Should -Be 'Verified'
    }

    It 'updates only the direct Beta cache when the Browser client is stale' {
        $null = Invoke-InitialMirror
        $browserClient = Get-ChildItem -LiteralPath (Join-Path $script:homes.CustomHome 'plugins\cache\openai-bundled\browser') -Recurse -Filter 'browser-client.mjs' | Select-Object -First 1
        [System.IO.File]::WriteAllText($browserClient.FullName, 'stale browser client')
        Mock Invoke-CodexPluginJson -ModuleName codex-plugin-isolation { throw 'the bundle-only repair must not call the CLI' }

        $result = Initialize-CodexBetaPluginIsolation `
            -DefaultCodexHome $script:homes.DefaultHome `
            -CustomCodexHome $script:homes.CustomHome `
            -CodexExecutable $script:codex `
            -BetaBundledMarketplace $script:marketplace `
            -BetaPackageVersion 'test-beta' `
            -BetaIsRunning $false

        $result.Changed | Should -BeTrue
        (Get-Content -LiteralPath $browserClient.FullName) | Should -Be 'trusted beta browser client'
    }

    It 'does not modify a profile that needs synchronization while Beta is running' {
        $null = Invoke-InitialMirror
        $configPath = Join-Path $script:homes.CustomHome 'config.toml'
        $before = Get-Content -LiteralPath $configPath -Raw
        $script:defaultStates += New-TestPluginState 'changed@test-market'

        {
            Initialize-CodexBetaPluginIsolation `
                -DefaultCodexHome $script:homes.DefaultHome `
                -CustomCodexHome $script:homes.CustomHome `
                -CodexExecutable $script:codex `
                -BetaBundledMarketplace $script:marketplace `
                -BetaPackageVersion 'test-beta' `
                -BetaIsRunning $true
        } | Should -Throw '*Codex Beta is running*'
        (Get-Content -LiteralPath $configPath -Raw) | Should -BeExactly $before
    }

    It 'rolls back the isolated profile when direct bundled staging fails' {
        $null = Invoke-InitialMirror
        $configPath = Join-Path $script:homes.CustomHome 'config.toml'
        $browserClient = Get-ChildItem -LiteralPath (Join-Path $script:homes.CustomHome 'plugins\cache\openai-bundled\browser') -Recurse -Filter 'browser-client.mjs' | Select-Object -First 1
        [System.IO.File]::WriteAllText($browserClient.FullName, 'stale browser client')
        $beforeConfig = Get-Content -LiteralPath $configPath -Raw
        $beforeBrowser = Get-Content -LiteralPath $browserClient.FullName -Raw
        Mock Copy-BundledPluginCacheToStaging -ModuleName codex-plugin-isolation { throw 'simulated staging failure' }

        {
            Initialize-CodexBetaPluginIsolation `
                -DefaultCodexHome $script:homes.DefaultHome `
                -CustomCodexHome $script:homes.CustomHome `
                -CodexExecutable $script:codex `
                -BetaBundledMarketplace $script:marketplace `
                -BetaPackageVersion 'test-beta' `
                -BetaIsRunning $false
        } | Should -Throw '*simulated staging failure*'
        (Get-Content -LiteralPath $configPath -Raw) | Should -BeExactly $beforeConfig
        (Get-Content -LiteralPath $browserClient.FullName -Raw) | Should -BeExactly $beforeBrowser
    }

    It 'restores config and cache when commit replacement fails' {
        $null = Invoke-InitialMirror
        $configPath = Join-Path $script:homes.CustomHome 'config.toml'
        $browserClient = Get-ChildItem -LiteralPath (Join-Path $script:homes.CustomHome 'plugins\cache\openai-bundled\browser') -Recurse -Filter 'browser-client.mjs' | Select-Object -First 1
        [System.IO.File]::WriteAllText($browserClient.FullName, 'stale browser client')
        $beforeConfig = Get-Content -LiteralPath $configPath -Raw
        $beforeBrowser = Get-Content -LiteralPath $browserClient.FullName -Raw
        Mock Set-StagedConfig -ModuleName codex-plugin-isolation { throw 'simulated commit failure' }

        {
            Initialize-CodexBetaPluginIsolation `
                -DefaultCodexHome $script:homes.DefaultHome `
                -CustomCodexHome $script:homes.CustomHome `
                -CodexExecutable $script:codex `
                -BetaBundledMarketplace $script:marketplace `
                -BetaPackageVersion 'test-beta' `
                -BetaIsRunning $false
        } | Should -Throw '*simulated commit failure*'
        (Get-Content -LiteralPath $configPath -Raw) | Should -BeExactly $beforeConfig
        (Get-Content -LiteralPath $browserClient.FullName -Raw) | Should -BeExactly $beforeBrowser
    }
}
