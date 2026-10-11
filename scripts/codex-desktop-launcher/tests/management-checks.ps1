$ErrorActionPreference = 'Stop'
Import-Module 'J:\Dev\ungate-local\scripts\codex-desktop-launcher\Management.psm1' -Force
function New-ProfileHome { Join-Path ([IO.Path]::GetTempPath()) ('ungate-launcher-' + [guid]::NewGuid().ToString('N')) }
$profileHome = New-ProfileHome
New-Item -ItemType Directory -Path $profileHome | Out-Null
try {
    $override = @{ version = 1; overrides = @{ 'mimo-v2.5-pro' = @{ upstreamModel = 'mimo-v2.6-pro'; displayName = 'Mimo v2.6 Pro'; contextWindow = 1000000; upstreamModelPrefix = 'openai-compatible-chat-test' } } }
    [IO.File]::WriteAllText((Join-Path $profileHome 'ungate-model-overrides.json'), (($override | ConvertTo-Json -Depth 6) + "`r`n"), [Text.UTF8Encoding]::new($false))
    $state = Invoke-UngateLauncherRequest -BetaHome $profileHome -Action 'state.get'
    if ($state.status -ne 200) { throw $state.body.message }
    $model = @($state.body.models) | Where-Object registryId -eq 'mimo-v2.5-pro'
    if ($model.requestModel -ne 'openai-compatible-chat-test/mimo-v2.6-pro') { throw "request model $($model.requestModel)" }
    $saved = Invoke-UngateLauncherRequest -BetaHome $profileHome -Action 'models.version' -Payload @{ registryId = 'mimo-v2.5-pro'; expectedRevision = $model.revisions.version; set = @{ displayName = 'Mimo renamed' }; unset = @() }
    if ($saved.status -ne 200) { throw "version save $($saved.body | ConvertTo-Json -Compress -Depth 5)" }
    $again = @($saved.body.models) | Where-Object registryId -eq 'mimo-v2.5-pro'
    if ($again.requestModel -ne 'openai-compatible-chat-test/mimo-v2.6-pro') { throw 'prefix lost' }
    if ($again.explicit.upstreamModelPrefix -ne 'openai-compatible-chat-test') { throw 'prefix field lost' }
    $stale = Invoke-UngateLauncherRequest -BetaHome $profileHome -Action 'models.version' -Payload @{ registryId = 'grok-4.7'; expectedRevision = 'stale'; set = @{ displayName = 'Changed' }; unset = @() }
    if ($stale.status -ne 409) { throw "expected 409 got $($stale.status)" }
    $caps = Invoke-UngateLauncherRequest -BetaHome $profileHome -Action 'models.capabilities' -Payload @{ registryId = 'grok-4.7'; expectedRevision = (@($saved.body.models) | Where-Object registryId -eq 'grok-4.7').revisions.capabilities; set = @{ supportsImageInput = $false }; unset = @() }
    if ($caps.status -ne 200) { throw "caps $($caps.body | ConvertTo-Json -Compress -Depth 6)" }
    $grok = @($caps.body.models) | Where-Object registryId -eq 'grok-4.7'
    if ($grok.image -or $grok.original) { throw 'image reset failed' }
    if ($grok.explicit.capabilities.supportsImageInput -ne $false) { throw 'false was not stored' }
    $ids = @($caps.body.models | Select-Object -First 8 | ForEach-Object registryId)
    $picker = Invoke-UngateLauncherRequest -BetaHome $profileHome -Action 'picker.set' -Payload @{ registryIds = $ids; expectedRevision = $caps.body.picker.revision }
    if ($picker.status -ne 422) { throw "expected picker 422 got $($picker.status) $($picker.body.message)" }
    'management-checks-ok'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $resolved = [IO.Path]::GetFullPath($profileHome).TrimEnd('\')
    $userProfile = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('\')
    $leaf = [IO.Path]::GetFileName($resolved)
    $insideTemp = $resolved.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    $isProfile = $resolved.Equals($userProfile, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $insideTemp -or $isProfile -or -not $leaf.StartsWith('ungate-launcher-')) {
        throw "Refusing to delete '$resolved'."
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
