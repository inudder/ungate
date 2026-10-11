BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot 'Management.psm1') -Force

    function Remove-LauncherFixtureDirectory {
        param([Parameter(Mandatory)][string]$FixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $resolved = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
        $userProfile = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('\')
        $leaf = [IO.Path]::GetFileName($resolved)
        $insideTemp = $resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
        $isProfile = $resolved.Equals($userProfile, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $insideTemp -or $isProfile -or -not $leaf.StartsWith('ungate-launcher-')) {
            throw "Refusing to delete '$resolved'."
        }
        if (Test-Path -LiteralPath $resolved) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

Describe 'Codex Beta launcher management' {
    BeforeEach {
        $script:LauncherFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ungate-launcher-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:LauncherFixtureRoot | Out-Null
    }
    AfterEach {
        Remove-LauncherFixtureDirectory -FixtureRoot $script:LauncherFixtureRoot
    }

    It 'preserves the transport prefix when the version changes' {
        $override = @{ version = 1; overrides = @{ 'mimo-v2.5-pro' = @{ upstreamModel = 'mimo-v2.6-pro'; displayName = 'Mimo v2.6 Pro'; contextWindow = 1000000; upstreamModelPrefix = 'openai-compatible-chat-test' } } }
        [IO.File]::WriteAllText((Join-Path $script:LauncherFixtureRoot 'ungate-model-overrides.json'), (($override | ConvertTo-Json -Depth 6) + "`r`n"), [Text.UTF8Encoding]::new($false))
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $model = @($state.body.models) | Where-Object registryId -eq 'mimo-v2.5-pro'
        $model.requestModel | Should -Be 'openai-compatible-chat-test/mimo-v2.6-pro'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.version' -Payload @{
            registryId = 'mimo-v2.5-pro'; expectedRevision = $model.revisions.version; set = @{ displayName = 'Mimo renamed' }; unset = @()
        }
        $saved.status | Should -Be 200
        $again = @($saved.body.models) | Where-Object registryId -eq 'mimo-v2.5-pro'
        $again.requestModel | Should -Be 'openai-compatible-chat-test/mimo-v2.6-pro'
        $again.explicit.upstreamModelPrefix | Should -Be 'openai-compatible-chat-test'
    }

    It 'rejects a stale revision without writing' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $model = @($state.body.models) | Where-Object registryId -eq 'grok-4.7'
        $stale = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.version' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = 'stale'; set = @{ displayName = 'Changed' }; unset = @()
        }
        $stale.status | Should -Be 409
        Test-Path -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-overrides.json') | Should -BeFalse
    }

    It 'stores an explicit false without treating it as missing' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $model = @($state.body.models) | Where-Object registryId -eq 'grok-4.7'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.capabilities' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = $model.revisions.capabilities;
            set = @{ supportsImageInput = $false }; unset = @()
        }
        $saved.status | Should -Be 200
        $again = @($saved.body.models) | Where-Object registryId -eq 'grok-4.7'
        $again.image | Should -BeFalse
        $again.original | Should -BeFalse
        $again.explicit.capabilities.supportsImageInput | Should -BeFalse
        $again.explicit.upstreamModel | Should -BeNullOrEmpty
    }

    It 'rejects a picker selection above capacity' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $ids = @($state.body.models | Select-Object -First 8 | ForEach-Object registryId)
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'picker.set' -Payload @{
            registryIds = $ids; expectedRevision = $state.body.picker.revision
        }
        $saved.status | Should -Be 422
    }

    It 'changes only the transport prefix' {
        $override = @{ version = 1; overrides = @{ 'mimo-v2.5-pro' = @{ upstreamModel = 'mimo-v2.6-pro'; displayName = 'Mimo v2.6 Pro'; contextWindow = 1000000; upstreamModelPrefix = 'openai-compatible-chat-test' } } }
        [IO.File]::WriteAllText((Join-Path $script:LauncherFixtureRoot 'ungate-model-overrides.json'), (($override | ConvertTo-Json -Depth 6) + "`r`n"), [Text.UTF8Encoding]::new($false))
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $model = @($state.body.models) | Where-Object registryId -eq 'mimo-v2.5-pro'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.prefix' -Payload @{
            registryId = 'mimo-v2.5-pro'; expectedRevision = $model.revisions.prefix; set = @{ upstreamModelPrefix = 'openai-compatible-chat' }; unset = @()
        }
        $saved.status | Should -Be 200
        $again = @($saved.body.models) | Where-Object registryId -eq 'mimo-v2.5-pro'
        $again.requestModel | Should -Be 'openai-compatible-chat/mimo-v2.6-pro'
        $again.explicit.displayName | Should -Be 'Mimo v2.6 Pro'
    }

    It 'adds a custom model with original detail off unless requested' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-custom'; displayName = 'Dashboard custom'; upstreamModel = 'dashboard-custom-upstream'
            transport = 'omniroute'; defaultReasoningLevel = 'medium'; supportsImageInput = $false
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 200
        $model = @($saved.body.models) | Where-Object registryId -eq 'dashboard-custom'
        $model.original | Should -BeFalse
        $model.upstreamModel | Should -Be 'dashboard-custom-upstream'
    }

    It 'rejects an unknown catalog transport without calling a provider' {
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'catalog.list' -Payload @{ transport = 'gateway' }
        $saved.status | Should -Be 422
    }
}
