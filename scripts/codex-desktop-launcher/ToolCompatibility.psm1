#requires -Version 7.4
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop

function Read-ToolCompatibilityKey {
    $ErrorActionPreference = 'Stop'
    return [Console]::ReadKey($true).Key.ToString()
}

function Test-ToolCompatibilityTerminal {
    return -not [Console]::IsInputRedirected
}

function Select-ToolCompatibilityModels {
    param([Parameter(Mandatory)][object[]]$Definitions)
    $ErrorActionPreference = 'Stop'
    if (-not (Test-ToolCompatibilityTerminal)) {
        throw 'Interactive tool selection requires a terminal. Use -TestTools -Model <id>.'
    }
    if ($Definitions.Count -eq 0) { return @() }
    $selected = [Collections.Generic.HashSet[int]]::new()
    $cursor = 0
    while ($true) {
        Clear-Host
        Write-Host 'Тестирование совместимости инструментов' -ForegroundColor Cyan
        for ($index = 0; $index -lt $Definitions.Count; $index++) {
            $marker = if ($selected.Contains($index)) { 'x' } else { ' ' }
            $pointer = if ($cursor -eq $index) { '>' } else { ' ' }
            Write-Host " $pointer [$marker] $($Definitions[$index].DisplayName)"
        }
        Write-Host '↑/↓: модель; Space: отметить; Enter: проверить; Esc: отмена'
        switch (Read-ToolCompatibilityKey) {
            'UpArrow' { $cursor = ($cursor + $Definitions.Count - 1) % $Definitions.Count }
            'DownArrow' { $cursor = ($cursor + 1) % $Definitions.Count }
            'Spacebar' { if (-not $selected.Remove($cursor)) { $null = $selected.Add($cursor) } }
            'Escape' { return @() }
            'Enter' {
                return @($Definitions | Where-Object { $selected.Contains([array]::IndexOf($Definitions, $_)) })
            }
        }
    }
}

function Invoke-ToolCompatibilityRunner {
    param([Parameter(Mandatory)][string]$NodePath, [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][hashtable]$Configuration)
    $ErrorActionPreference = 'Stop'
    # Pass credentials over stdin, never through arguments or a configuration file.
    $Configuration | ConvertTo-Json -Depth 100 -Compress | & $NodePath @($RunnerPath) | ForEach-Object { Write-Host $_ }
    return [int]$LASTEXITCODE
}

function Invoke-CodexToolCompatibility {
    param([Parameter(Mandatory)][psobject]$Context, [Parameter(Mandatory)][object[]]$Definitions,
        [string]$Model)
    $ErrorActionPreference = 'Stop'
    try {
        if ($Model) {
            $selected = @($Definitions | Where-Object {
                $_.Slug -eq $Model -or ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $Model) -or
                ($_.PSObject.Properties['Aliases'] -and $Model -in $_.Aliases)
            })
            if ($selected.Count -ne 1) { throw "Unknown or ambiguous model '$Model'. Use a model registry id." }
        }
        else {
            $selected = @(Select-ToolCompatibilityModels -Definitions $Definitions)
        }
        if ($selected.Count -eq 0) { return 0 }
        if ($Context.Options.ApiKey -and $selected.Count -gt 1) { throw '-ApiKey requires selecting exactly one model.' }
        $nodePath = (Get-Command node -ErrorAction Stop).Source
        $runnerPath = Join-Path $Context.ScriptsRoot 'codex-tool-compatibility.mjs'
        $cachePath = Join-Path $Context.CustomCodexHome 'tool-compatibility/tools-schema-cache.json'
        $cacheArguments = @($runnerPath, '--validate-cache', $cachePath)
        if ($Context.CustomCodexHome -eq $Context.CanonicalCodexHome -and $env:APPDATA) {
            $cacheArguments += Join-Path $env:APPDATA 'omniroute/call_logs'
        }
        & $nodePath $cacheArguments 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { return 2 }
        $models = @(
            foreach ($definition in $selected) {
                $record = @{
                    model = if ($definition.PSObject.Properties['UpstreamModel'] -and $definition.UpstreamModel) { $definition.UpstreamModel } else { $definition.Slug }
                    displayName = $definition.DisplayName
                    upstreamBaseUrl = $definition.ProxyBaseUrl
                    responsesAdapter = if ($definition.PSObject.Properties['ResponsesAdapter']) { $definition.ResponsesAdapter } else { $null }
                    bridgeUpstreamUrl = if ($definition.ProviderName -eq $Context.CliProxyProviderName) { $Context.CliProxyUpstreamBaseUrl } else { $null }
                }
                try {
                    $record.apiKey = Resolve-ModelApiKey -Context $Context -Definition $definition -ApiKey $Context.Options.ApiKey
                }
                catch { $record.error = 'Could not resolve provider credentials. Check the provider key configuration.' }
                $record
            }
        )
        return Invoke-ToolCompatibilityRunner -NodePath $nodePath -RunnerPath $runnerPath -Configuration @{
            cachePath = $cachePath
            reportDirectory = Join-Path $Context.CustomCodexHome 'tool-compatibility/reports'
            models = $models
        }
    }
    catch {
        Write-Host "[TT] $($_.Exception.Message)" -ForegroundColor Yellow
        return 2
    }
}

Export-ModuleMember -Function @('Invoke-CodexToolCompatibility')
