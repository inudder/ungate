BeforeAll {
    $script:moduleRoot = Split-Path -Parent $PSScriptRoot
    $script:helper = Join-Path (Split-Path -Parent $script:moduleRoot) 'omniroute-context-limit.mjs'
    Import-Module (Join-Path $script:moduleRoot 'OmniRouteContextLimit.psm1') -DisableNameChecking -Force -ErrorAction Stop
    $script:quote = [char]34

    function ConvertTo-FixedJson {
        param($Value)
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
        if ($Value -is [string]) {
            $slash = [string][char]92
            $escaped = ([string]$Value).Replace($slash, $slash + $slash).Replace([string]$script:quote, $slash + [string]$script:quote)
            return $script:quote + $escaped + $script:quote
        }
        if ($Value -is [ValueType]) { return [string]$Value }
        if ($Value -is [System.Collections.IList]) {
            $items = foreach ($item in @($Value)) { ConvertTo-FixedJson $item }
            return '[' + ($items -join ',') + ']'
        }
        $props = foreach ($key in @($Value.Keys)) { $script:quote + $key + $script:quote + ':' + (ConvertTo-FixedJson $Value[$key]) }
        return '{' + ($props -join ',') + '}'
    }

    function Invoke-LimitRequest {
        param($Request)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.json')
        [IO.File]::WriteAllText($path, (ConvertTo-FixedJson $Request), [Text.UTF8Encoding]::new($false))
        $raw = & node $script:helper $path
        $LASTEXITCODE | Should -Be 0
        return (($raw | Out-String).Trim() | ConvertFrom-Json)
    }

    function New-ReadyRequest {
        param([string]$Route, [hashtable]$Fixture = @{}, [hashtable]$ListenerEnv = @{}, [hashtable]$StaticCatalog = @{ mode = 'ready' }, [bool]$Readable = $true)
        [ordered]@{
            route = $Route
            listenerEnvReadable = $Readable
            listenerEnv = $ListenerEnv
            staticCatalog = $StaticCatalog
            fixture = $Fixture
        }
    }

    function New-LimitSelection {
        param([long]$Window = 1000000, [string]$Provider = 'omniroute')
        [pscustomobject]@{
            EnableProviderFallback = $false
            SelectedModel = [pscustomobject]@{
                ProviderName = $Provider
                DisplayName = 'MiMo v2.6 Pro'
                UpstreamModel = 'mimo-v2.6-pro'
                UpstreamModelPrefix = 'openai-compatible-chat-abc'
                ContextWindow = $Window
                MaxContextWindow = $Window
            }
        }
    }
}

Describe 'OmniRoute context limit resolver' {
    It 'blocks a 1M launcher window against the 128k fallback' {
        $report = Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro')
        $report.status | Should -Be 'confirmed'
        $report.targets[0].context.limit | Should -Be 128000
        $report.targets[0].context.source | Should -Be 'fallback'
    }

    It 'accepts an equal or larger manual window' {
        foreach ($limit in 1000000, 2000000) {
            $fixture = @{ contextOverrides = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; realContext = $limit; source = 'manual' }) }
            $report = Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' $fixture)
            $report.targets[0].context.limit | Should -Be $limit
            $report.targets[0].context.source | Should -Be 'manual'
        }
    }

    It 'lets a manual override beat a smaller catalog value' {
        $fixture = @{
            contextOverrides = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; realContext = 1000000; source = 'manual' })
            capabilities = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; limitContext = 128000 })
        }
        $static = @{ mode = 'ready'; specContextWindow = @{ 'mimo-v2.6-pro' = 128000 } }
        $report = Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' $fixture @{} $static)
        $report.targets[0].context.limit | Should -Be 1000000
        $report.targets[0].context.source | Should -Be 'manual'
    }

    It 'lets the provider environment override beat a larger manual value' {
        $fixture = @{ contextOverrides = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; realContext = 1000000; source = 'manual' }) }
        $env = @{ CONTEXT_LENGTH_OPENAI_COMPATIBLE_CHAT_ABC = '128000' }
        $report = Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' $fixture $env)
        $report.targets[0].context.limit | Should -Be 128000
        $report.targets[0].context.source | Should -Be 'environment'
    }

    It 'does not mix same-named models from different providers' {
        $fixture = @{ contextOverrides = @(
            @{ provider = 'alpha'; modelId = 'shared-model'; realContext = 1000000; source = 'manual' },
            @{ provider = 'beta'; modelId = 'shared-model'; realContext = 128000; source = 'manual' }
        ) }
        $alpha = Invoke-LimitRequest (New-ReadyRequest 'alpha/shared-model' $fixture)
        $beta = Invoke-LimitRequest (New-ReadyRequest 'beta/shared-model' $fixture)
        $alpha.targets[0].context.limit | Should -Be 1000000
        $beta.targets[0].context.limit | Should -Be 128000
    }

    It 'resolves a qualified route that discovery does not advertise' {
        $route = 'openai-compatible-chat-a4d5b027-617b-4d6b-a100-a99e059637e8/mimo-v2.6-pro'
        $fixture = @{ contextOverrides = @(@{ provider = 'openai-compatible-chat-a4d5b027-617b-4d6b-a100-a99e059637e8'; modelId = 'mimo-v2.6-pro'; realContext = 1000000; source = 'manual' }) }
        $report = Invoke-LimitRequest (New-ReadyRequest $route $fixture)
        $report.targets[0].route | Should -Be $route
        $report.targets[0].context.limit | Should -Be 1000000
    }

    It 'does not invent a limit for an invalid value, missing static data, or unreadable environment' {
        $invalidFixture = @{ contextOverrides = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; realContext = 0; source = 'manual' }) }
        (Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' $invalidFixture)).status | Should -Be 'unconfirmed'
        (Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' @{} @{} @{ mode = 'unavailable' })).status | Should -Be 'unconfirmed'
        (Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' @{} @{} @{ mode = 'ready' } $false)).status | Should -Be 'unconfirmed'
    }

    It 'ignores max output and reports a smaller max input cap separately' {
        $fixture = @{
            contextOverrides = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; realContext = 1000000; source = 'manual' })
            inputOverrides = @(@{ provider = 'openai-compatible-chat-abc'; modelId = 'mimo-v2.6-pro'; value = 200000; maxOutput = 8192 })
        }
        $report = Invoke-LimitRequest (New-ReadyRequest 'openai-compatible-chat-abc/mimo-v2.6-pro' $fixture)
        $report.targets[0].context.limit | Should -Be 1000000
        $report.targets[0].maxInput.limit | Should -Be 200000
        $report.targets[0].maxInput.source | Should -Be 'max_input_tokens'
    }

    It 'checks every combo member instead of copying one window' {
        $fixture = @{
            combos = @(@{
                name = 'codex-fallback'
                models = @(
                    @{ kind = 'model'; model = 'wide/model'; provider = 'wide' },
                    @{ kind = 'model'; model = 'narrow/model'; provider = 'narrow' },
                    @{ kind = 'combo-ref'; comboName = 'child' }
                )
            }, @{
                name = 'child'
                models = @(@{ kind = 'model'; model = 'child/model'; provider = 'child' })
            })
            contextOverrides = @(
                @{ provider = 'wide'; modelId = 'model'; realContext = 2000000; source = 'manual' },
                @{ provider = 'narrow'; modelId = 'model'; realContext = 128000; source = 'manual' },
                @{ provider = 'child'; modelId = 'model'; realContext = 1000000; source = 'manual' }
            )
        }
        $report = Invoke-LimitRequest (New-ReadyRequest 'codex-fallback' $fixture)
        $report.status | Should -Be 'confirmed'
        $report.combo | Should -BeTrue
        @($report.targets.context.limit) | Should -Be @(2000000, 128000, 1000000)
        $report.PSObject.Properties.Name | Should -Not -Contain 'context'
    }

    It 'leaves an incomplete combo unconfirmed' {
        $fixture = @{
            combos = @(@{
                name = 'codex-fallback'
                models = @(
                    @{ kind = 'model'; model = 'wide/model' },
                    @{ kind = 'provider-wildcard'; providerId = 'auto'; modelPattern = '*' }
                )
            })
            contextOverrides = @(@{ provider = 'wide'; modelId = 'model'; realContext = 2000000; source = 'manual' })
        }
        (Invoke-LimitRequest (New-ReadyRequest 'codex-fallback' $fixture)).status | Should -Be 'unconfirmed'
    }

    It 'sees a limit changed between reads and ignores max output rows' {
        $database = Join-Path $TestDrive 'limits.sqlite'
        $creator = Join-Path $PSScriptRoot 'fixtures/context-limit-db.mjs'
        & node $creator $database 128000
        $LASTEXITCODE | Should -Be 0
        $request = [ordered]@{
            route = 'openai-compatible-chat-abc/mimo-v2.6-pro'
            dbPath = $database
            listenerEnvReadable = $true
            listenerEnv = @{}
            staticCatalog = @{ mode = 'ready' }
        }
        (Invoke-LimitRequest $request).targets[0].context.limit | Should -Be 128000
        & node $creator $database 1000000
        $again = Invoke-LimitRequest $request
        $again.targets[0].context.limit | Should -Be 1000000
        $again.targets[0].context.source | Should -Be 'manual'
        $again.targets[0].maxInput | Should -BeNullOrEmpty
    }
}

Describe 'Desktop context gate' {
    BeforeEach {
        Mock Read-OmniRouteListenerEnvironment { @{ DATA_DIR = 'fixture' } } -ModuleName OmniRouteContextLimit
        Mock Write-Host {} -ModuleName OmniRouteContextLimit
        Mock Write-Warning {} -ModuleName OmniRouteContextLimit
    }

    It 'skips models that do not use OmniRoute' {
        Mock Get-OmniRouteContextLimitReport { throw 'must not resolve' } -ModuleName OmniRouteContextLimit
        $result = Assert-OmniRouteDesktopContextLimit -Context ([pscustomobject]@{ OmniRouteProviderName = 'omniroute' }) -Selection (New-LimitSelection -Provider 'cliproxyapi')
        $result.Status | Should -Be 'skipped'
    }

    It 'blocks 1M against 128k and passes equal or larger limits' {
        $context = [pscustomobject]@{ OmniRouteProviderName = 'omniroute' }
        Mock Get-OmniRouteContextLimitReport {
            [pscustomobject]@{
                status = 'confirmed'
                combo = $false
                targets = @([pscustomobject]@{
                    route = 'openai-compatible-chat-abc/mimo-v2.6-pro'
                    context = [pscustomobject]@{ limit = 128000; source = 'fallback' }
                    maxInput = $null
                })
            }
        } -ModuleName OmniRouteContextLimit
        $blocked = Assert-OmniRouteDesktopContextLimit -Context $context -Selection (New-LimitSelection)
        $blocked.Status | Should -Be 'blocked'
        Should -Invoke Write-Host -ModuleName OmniRouteContextLimit -ParameterFilter { $Object -match 'Запуск отменён: MiMo v2.6 Pro' -and $Object -match '1 000 000' -and $Object -match '128 000' -and $Object -match 'fallback' }

        Mock Get-OmniRouteContextLimitReport {
            [pscustomobject]@{ status = 'confirmed'; combo = $false; targets = @([pscustomobject]@{ route = 'openai-compatible-chat-abc/mimo-v2.6-pro'; context = [pscustomobject]@{ limit = 1000000; source = 'manual' }; maxInput = $null }) }
        } -ModuleName OmniRouteContextLimit
        (Assert-OmniRouteDesktopContextLimit -Context $context -Selection (New-LimitSelection)).Status | Should -Be 'ok'
        Mock Get-OmniRouteContextLimitReport {
            [pscustomobject]@{ status = 'confirmed'; combo = $false; targets = @([pscustomobject]@{ route = 'openai-compatible-chat-abc/mimo-v2.6-pro'; context = [pscustomobject]@{ limit = 2000000; source = 'manual' }; maxInput = $null }) }
        } -ModuleName OmniRouteContextLimit
        (Assert-OmniRouteDesktopContextLimit -Context $context -Selection (New-LimitSelection)).Status | Should -Be 'ok'
    }

    It 'blocks a smaller max input cap without calling it the context window' {
        Mock Get-OmniRouteContextLimitReport {
            [pscustomobject]@{
                status = 'confirmed'
                combo = $false
                targets = @([pscustomobject]@{
                    route = 'openai-compatible-chat-abc/mimo-v2.6-pro'
                    context = [pscustomobject]@{ limit = 1000000; source = 'manual' }
                    maxInput = [pscustomobject]@{ limit = 200000; source = 'max_input_tokens' }
                })
            }
        } -ModuleName OmniRouteContextLimit
        $result = Assert-OmniRouteDesktopContextLimit -Context ([pscustomobject]@{ OmniRouteProviderName = 'omniroute' }) -Selection (New-LimitSelection)
        $result.Status | Should -Be 'blocked'
        Should -Invoke Write-Host -ModuleName OmniRouteContextLimit -ParameterFilter { $Object -match 'max_input_tokens: 200 000' -and $Object -notmatch 'OmniRoute: 200 000' }
    }

    It 'warns without a successful check when the limit is unconfirmed' {
        Mock Get-OmniRouteContextLimitReport { [pscustomobject]@{ status = 'unconfirmed' } } -ModuleName OmniRouteContextLimit
        $result = Assert-OmniRouteDesktopContextLimit -Context ([pscustomobject]@{ OmniRouteProviderName = 'omniroute' }) -Selection (New-LimitSelection)
        $result.Status | Should -Be 'unconfirmed'
        Should -Invoke Write-Warning -ModuleName OmniRouteContextLimit -ParameterFilter { $Message -eq 'лимит контекста не подтверждён' }
        Should -Invoke Write-Host -ModuleName OmniRouteContextLimit -Times 0
    }

    It 'does not block when OmniRoute context checks are disabled' {
        Mock Get-OmniRouteContextLimitReport { [pscustomobject]@{ status = 'checks-disabled' } } -ModuleName OmniRouteContextLimit
        $result = Assert-OmniRouteDesktopContextLimit -Context ([pscustomobject]@{ OmniRouteProviderName = 'omniroute' }) -Selection (New-LimitSelection)
        $result.Status | Should -Be 'checks-disabled'
    }
}

Describe 'Listener environment' {
    It 'reads only context-limit keys from the current process' {
        $previous = $env:CONTEXT_LENGTH_UNGATE_TEST
        try {
            $env:CONTEXT_LENGTH_UNGATE_TEST = '12345'
            $env:OMNIROUTE_SECRET_MUST_NOT_LEAK = 'secret-value'
            $read = $null
            foreach ($attempt in 1..3) {
                $read = Read-OmniRouteProcessEnvironment -ProcessId $PID
                if ($read -and $read['CONTEXT_LENGTH_UNGATE_TEST'] -eq '12345') { break }
                Start-Sleep -Milliseconds 50
            }
            $read['CONTEXT_LENGTH_UNGATE_TEST'] | Should -Be '12345'
            ($read.Keys -join ',') | Should -Not -Match 'SECRET'
            ($read.Values -join ',') | Should -Not -Match 'secret-value'
        } finally {
            if ($null -eq $previous) { Remove-Item Env:CONTEXT_LENGTH_UNGATE_TEST -ErrorAction SilentlyContinue }
            else { $env:CONTEXT_LENGTH_UNGATE_TEST = $previous }
            Remove-Item Env:OMNIROUTE_SECRET_MUST_NOT_LEAK -ErrorAction SilentlyContinue
        }
    }
}

