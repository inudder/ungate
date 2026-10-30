BeforeAll {
    $script:moduleRoot = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('Context', 'Routing', 'Launcher')) {
        Import-Module (Join-Path $script:moduleRoot "$name.psm1") -DisableNameChecking -ErrorAction Stop
    }

    $script:providers = @{
        omniroute = [pscustomobject]@{
            DisplayName = 'Test OmniRoute'
            ProviderName = 'omniroute'
            ProviderDisplayName = 'OmniRoute'
            ProxyBaseUrl = 'http://127.0.0.1:20128'
            EnvKey = 'OMNIROUTE_API_KEY'
        }
        cliproxyapi = [pscustomobject]@{
            DisplayName = 'Test CLIProxyAPI'
            ProviderName = 'cliproxyapi'
            ProviderDisplayName = 'CLIProxyAPI'
            ProxyBaseUrl = 'http://127.0.0.1:8318'
            EnvKey = 'CLIPROXYAPI_API_KEY'
        }
        ungate_proxy = [pscustomobject]@{
            DisplayName = 'Test Ungate'
            ProviderName = 'ungate_proxy'
            ProviderDisplayName = 'Ungate'
            ProxyBaseUrl = 'http://127.0.0.1:47821'
            EnvKey = 'UNGATE_API_KEY'
        }
    }
}

Describe 'Desktop config credentials match the launched process environment' {
    BeforeEach {
        $script:launchEnvironment = $null
        Mock -ModuleName Launcher Write-Host {}
        Mock -ModuleName Launcher Start-CodexBetaDesktop {
            param($LaunchEnvironment)
            $script:launchEnvironment = $LaunchEnvironment
        }
    }

    It 'supplies the configured credential for <Name>' -ForEach @(
        @{ Name = 'OmniRoute only'; Providers = @('omniroute'); Selected = 'omniroute'; Client = 'omniroute'; Fallback = $false },
        @{ Name = 'CLIProxyAPI only'; Providers = @('cliproxyapi'); Selected = 'cliproxyapi'; Client = 'cliproxyapi'; Fallback = $false },
        @{ Name = 'OmniRoute and CLIProxyAPI without Ungate'; Providers = @('omniroute', 'cliproxyapi'); Selected = 'omniroute'; Client = 'omniroute'; Fallback = $false },
        @{ Name = 'an existing Ungate credential with OmniRoute selected'; Providers = @('ungate_proxy', 'omniroute'); Selected = 'omniroute'; Client = 'ungate_proxy'; Fallback = $false },
        @{ Name = 'Ungate only'; Providers = @('ungate_proxy'); Selected = 'ungate_proxy'; Client = 'ungate_proxy'; Fallback = $false },
        @{ Name = 'direct OmniRoute fallback'; Providers = @('omniroute'); Selected = 'omniroute'; Client = 'omniroute'; Fallback = $true }
    ) {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome (Join-Path $TestDrive 'beta') -LaunchParameters @{ NoLogWatch = $true }
        $definition = $script:providers[$Selected]
        $selection = [pscustomobject]@{
            Definitions = @($Providers | ForEach-Object { $script:providers[$_] })
            SelectedModel = $definition
            EnableProviderFallback = $Fallback
            FallbackDefinition = $script:providers.omniroute
            MemoryEnabled = $false
            BackgroundDefinition = $null
            LaunchProvider = if ($Fallback) {
                [pscustomobject]@{
                    Name = $definition.ProviderName
                    DisplayName = $definition.ProviderDisplayName
                    ProxyBaseUrl = $definition.ProxyBaseUrl
                    EnvKey = $definition.EnvKey
                }
            } else {
                $context.CodexModelShellRouterProviderDefinition
            }
        }
        $providerKeys = @{}
        foreach ($providerName in $Providers) { $providerKeys[$providerName] = "fixture-$providerName-key" }
        $config = Ensure-ModelProvidersInConfig -Context $context -Selection $selection -Content 'model = "fixture"'
        $configEnvKey = [regex]::Match($config, '(?m)^env_key\s*=\s*"([^"]+)"\s*$').Groups[1].Value
        $configEnvKey | Should -Not -BeNullOrEmpty

        & (Get-Module Launcher) {
            param($Context, $Selection, $ProviderKeys)
            Start-CodexDesktopSession -Context $Context -Selection $Selection `
                -codexBeta ([pscustomobject]@{ ExecutablePath = 'fixture.exe' }) -providerKeys $ProviderKeys
        } $context $selection $providerKeys

        $script:launchEnvironment.ContainsKey($configEnvKey) | Should -BeTrue -Because "Codex otherwise fails with Missing environment variable: $configEnvKey"
        $script:launchEnvironment[$configEnvKey] | Should -BeExactly $providerKeys[$Client]
        $script:launchEnvironment.CODEX_HOME | Should -BeExactly $context.CustomCodexHome
        foreach ($providerName in $Providers) {
            $script:launchEnvironment[$script:providers[$providerName].EnvKey] | Should -BeExactly $providerKeys[$providerName]
        }
        if ($Fallback) { $script:launchEnvironment.ContainsKey('UNGATE_API_KEY') | Should -BeFalse }
    }
}
