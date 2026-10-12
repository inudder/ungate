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
        Mock Read-UngateTransportCatalog -ModuleName Management { [ordered]@{ available = $true; models = @('dashboard-custom-upstream'); message = $null } }
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

    It 'rejects a new model the transport catalog does not list, naming similar IDs' {
        Mock Read-UngateTransportCatalog -ModuleName Management { [ordered]@{ available = $true; models = @('grok-4.7', 'grok-4.5'); message = $null } }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'grok-4.7-build-fast'; displayName = 'Grok fast'; upstreamModel = 'grok-4.7-build-fast'
            transport = 'cliproxyapi'; defaultReasoningLevel = 'medium'; supportsImageInput = $false
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 422
        $saved.body.code | Should -Be 'model_not_in_catalog'
        $saved.body.message | Should -Match "cliproxyapi"
        $saved.body.message | Should -Match 'grok-4\.7'
        (Get-Content -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-registry.json') -Raw) | Should -Not -Match 'grok-4.7-build-fast'
    }

    It 'stores the context window given when the model is added' {
        Mock Read-UngateTransportCatalog -ModuleName Management { [ordered]@{ available = $true; models = @('dashboard-custom-upstream'); message = $null } }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-custom'; displayName = 'Dashboard custom'; upstreamModel = 'dashboard-custom-upstream'
            transport = 'cliproxyapi'; defaultReasoningLevel = 'medium'; supportsImageInput = $false; contextWindow = '500k'
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 200
        (@($saved.body.models) | Where-Object registryId -eq 'dashboard-custom').contextWindow | Should -Be 500000
        $registry = Get-Content -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-registry.json') -Raw | ConvertFrom-Json
        (@($registry.models) | Where-Object slug -eq 'dashboard-custom').contextWindow | Should -Be 500000
        Test-Path -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-overrides.json') | Should -BeFalse
    }

    It 'rejects an unparseable context window before reading the catalog' {
        Mock Read-UngateTransportCatalog -ModuleName Management { throw 'catalog must not be read' }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-custom'; displayName = 'Dashboard custom'; upstreamModel = 'dashboard-custom-upstream'
            transport = 'cliproxyapi'; defaultReasoningLevel = 'medium'; supportsImageInput = $false; contextWindow = 'lots'
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 422
        $saved.body.code | Should -Be 'invalid_settings'
        $saved.body.message | Should -Match 'context window'
    }

    It 'accepts an OmniRoute model that preflight resolves through a discovery alias' {
        Mock Read-UngateTransportCatalog -ModuleName Management { [ordered]@{ available = $true; models = @('ds/deepseek-v9'); message = $null } }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'deepseek-v9'; displayName = 'DeepSeek v9'; upstreamModel = 'deepseek-v9'
            transport = 'omniroute'; defaultReasoningLevel = 'medium'; supportsImageInput = $false
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 200
    }

    It 'rejects a new model when the transport catalog cannot be read' {
        Mock Read-UngateTransportCatalog -ModuleName Management { [ordered]@{ available = $false; models = @(); message = 'Provider credentials are unavailable.' } }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-custom'; displayName = 'Dashboard custom'; upstreamModel = 'dashboard-custom-upstream'
            transport = 'omniroute'; defaultReasoningLevel = 'medium'; supportsImageInput = $false
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 422
        $saved.body.code | Should -Be 'catalog_unavailable'
        $saved.body.message | Should -Match 'credentials'
    }

    It 'adds a model without the catalog check when explicitly skipped' {
        Mock Read-UngateTransportCatalog -ModuleName Management { throw 'catalog must not be read' }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-custom'; displayName = 'Dashboard custom'; upstreamModel = 'dashboard-custom-upstream'
            transport = 'omniroute'; defaultReasoningLevel = 'medium'; supportsImageInput = $false; skipCatalogCheck = $true
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 200
        Should -Invoke Read-UngateTransportCatalog -ModuleName Management -Times 0
    }

    It 'deletes a custom model from the registry, its overrides and the picker' {
        Mock Read-UngateTransportCatalog -ModuleName Management { [ordered]@{ available = $true; models = @('dashboard-custom-upstream'); message = $null } }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $null = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-custom'; displayName = 'Dashboard custom'; upstreamModel = 'dashboard-custom-upstream'
            transport = 'omniroute'; defaultReasoningLevel = 'medium'; supportsImageInput = $false
            expectedRevision = $state.body.registry.revision
        }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $custom = @($state.body.models) | Where-Object registryId -eq 'dashboard-custom'
        $custom.inTemplate | Should -BeFalse
        $null = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.version' -Payload @{
            registryId = 'dashboard-custom'; expectedRevision = $custom.revisions.version; set = @{ displayName = 'Renamed' }; unset = @()
        }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $first = @($state.body.models | Select-Object -First 2 | ForEach-Object registryId)
        $null = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'picker.set' -Payload @{
            registryIds = @($first + 'dashboard-custom'); expectedRevision = $state.body.picker.revision
        }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $custom = @($state.body.models) | Where-Object registryId -eq 'dashboard-custom'
        $custom.inPicker | Should -BeTrue

        $removed = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.remove' -Payload @{
            registryId = 'dashboard-custom'; expectedRevision = $custom.revisions.remove
        }
        $removed.status | Should -Be 200
        @($removed.body.models | Where-Object registryId -eq 'dashboard-custom').Count | Should -Be 0
        $removed.body.picker.slugs | Should -Not -Contain 'dashboard-custom'
        @($removed.body.picker.slugs).Count | Should -Be 2
        $removed.body.templates.models.Count | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-registry.json') -Raw) | Should -Not -Match 'dashboard-custom'
        Test-Path -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-overrides.json') | Should -BeFalse
    }

    It 'deletes a template model and copies the template record back' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $grok = @($state.body.models) | Where-Object registryId -eq 'grok-4.7'
        $grok.inTemplate | Should -BeTrue
        $null = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'picker.set' -Payload @{
            registryIds = @('miniMax-M3', 'grok-4.7'); expectedRevision = $state.body.picker.revision
        }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $grok = @($state.body.models) | Where-Object registryId -eq 'grok-4.7'

        $removed = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.remove' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = $grok.revisions.remove
        }
        $removed.status | Should -Be 200
        @($removed.body.models | Where-Object registryId -eq 'grok-4.7').Count | Should -Be 0
        @($removed.body.templates.models | ForEach-Object registryId) | Should -Contain 'grok-4.7'
        @($removed.body.picker.slugs) | Should -Be @('miniMax-M3')
        Test-Path -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-hidden-models.json') | Should -BeFalse

        $copied = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.addTemplate' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = $removed.body.registry.revision
        }
        $copied.status | Should -Be 200
        @($copied.body.models)[-1].registryId | Should -Be 'grok-4.7'
        @($copied.body.picker.slugs) | Should -Not -Contain 'grok-4.7'
        @($copied.body.templates.models | ForEach-Object registryId) | Should -Not -Contain 'grok-4.7'
        Test-Path -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-hidden-models.json') | Should -BeFalse
    }

    It 'refuses to remove a model from a stale view' {
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.remove' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = 'stale'
        }
        $saved.status | Should -Be 409
        $saved.body.code | Should -Be 'stale_revision'
    }

    It 'refuses to copy a removed template model from a stale view' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $before = [string]$state.body.registry.revision
        $grok = @($state.body.models) | Where-Object registryId -eq 'grok-4.7'
        $removed = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.remove' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = $grok.revisions.remove
        }
        $removed.status | Should -Be 200
        $stale = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.addTemplate' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = $before
        }
        $stale.status | Should -Be 409
        $stale.body.code | Should -Be 'stale_revision'
    }

    It 'refuses unknown removal, a taken slug, a slug outside the template, and restore' {
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $unknown = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.remove' -Payload @{
            registryId = 'no-such-model'; expectedRevision = 'x'
        }
        $unknown.status | Should -Be 404
        $unknown.body.code | Should -Be 'unknown_model'
        $taken = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.addTemplate' -Payload @{
            registryId = 'ungate-opus-4-8'; expectedRevision = $state.body.registry.revision
        }
        $taken.status | Should -Be 422
        $taken.body.code | Should -Be 'invalid_settings'
        $outside = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.addTemplate' -Payload @{
            registryId = 'not-in-template'; expectedRevision = $state.body.registry.revision
        }
        $outside.status | Should -Be 404
        $outside.body.code | Should -Be 'unknown_model'
        $restore = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.restore' -Payload @{
            registryId = 'grok-4.7'; expectedRevision = $state.body.registry.revision
        }
        $restore.status | Should -Be 404
        $restore.body.code | Should -Be 'unknown_action'
    }

    It 'stores a null upstream model only for the ungate transport' {
        Mock Read-UngateTransportCatalog -ModuleName Management { throw 'catalog must not be read' }
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-ungate'; displayName = 'Dashboard ungate'; upstreamModel = ''
            transport = 'ungate'; defaultReasoningLevel = 'medium'; supportsImageInput = $false; skipCatalogCheck = $true
            expectedRevision = $state.body.registry.revision
        }
        $saved.status | Should -Be 200
        $model = @($saved.body.models) | Where-Object registryId -eq 'dashboard-ungate'
        $model.registryId | Should -Be 'dashboard-ungate'
        $null -eq $model.upstreamModel | Should -BeTrue
        $model.inTemplate | Should -BeFalse
        $record = @(Get-Content -LiteralPath (Join-Path $script:LauncherFixtureRoot 'ungate-model-registry.json') -Raw | ConvertFrom-Json).models |
            Where-Object slug -eq 'dashboard-ungate'
        $null -eq $record.upstreamModel | Should -BeTrue
        $state = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'state.get'
        $rejected = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'models.add' -Payload @{
            registryId = 'dashboard-omni'; displayName = 'Dashboard omni'; upstreamModel = ''
            transport = 'omniroute'; defaultReasoningLevel = 'medium'; supportsImageInput = $false; skipCatalogCheck = $true
            expectedRevision = $state.body.registry.revision
        }
        $rejected.status | Should -Be 422
        $rejected.body.code | Should -Be 'invalid_settings'
    }

    It 'rejects an unknown catalog transport without calling a provider' {
        $saved = Invoke-UngateLauncherRequest -BetaHome $script:LauncherFixtureRoot -Action 'catalog.list' -Payload @{ transport = 'gateway' }
        $saved.status | Should -Be 422
    }
}
