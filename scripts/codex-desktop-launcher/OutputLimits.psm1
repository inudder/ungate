#requires -Version 7.4
Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'ProxyRuntime.psm1') -DisableNameChecking -ErrorAction Stop

function Invoke-UngateOutputLimits {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object[]]$Definitions,
        [switch]$Probe, [int]$Budget = 0, [switch]$Full)
    $ErrorActionPreference = 'Stop'
    $records = @($Definitions | ForEach-Object {
        $route = Get-UngateDiagnosticRoute -Context $Context -Definition $_
        $record = @{
            registryId = $route.RegistryId; model = $route.RequestModel; displayName = $_.DisplayName
            transport = $route.Transport; upstreamBaseUrl = $route.UpstreamBaseUrl
            responsesAdapter = $route.ResponsesAdapter; bridgeUpstreamUrl = $route.BridgeUpstreamUrl
            reasoning = $_.DefaultReasoningLevel
            contextWindow = (Get-UngateModelContextWindow -Definition $_).ContextWindow
        }
        if ($_.PSObject.Properties['ParallelToolCallsOverride']) { $record.parallelToolCalls = [bool]$_.ParallelToolCallsOverride }
        try {
            $key = Resolve-ModelApiKey -Context $Context -Definition $_ -ApiKey $Context.Options.ApiKey
            $record.credentialFingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
            if ($Probe) { $record.apiKey = $key }
        } catch {
            if ($Probe) { throw }
            $record.credentialFingerprint = $null
        }
        $record
    })
    $configuration = @{
        models = $records; probe = [bool]$Probe
        budget = if ($Budget) { $Budget } else { $Context.Options.OutputTokenBudget }
        full = [bool]($Full -or $Context.Options.FullOutputTest)
        timeoutMs = $Context.Options.OutputTestTimeoutSeconds * 1000
        reportDirectory = Join-Path $Context.CustomCodexHome 'output-limits/reports'
        evidencePath = Join-Path $Context.CustomCodexHome 'ungate-output-limits.json'
        cliProxyConfigPath = $Context.CliProxyConfigPath
        routerBaseUrl = $Context.CodexModelShellRouterBaseUrl
    }
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $runnerArguments = @('--no-warnings', (Join-Path $Context.ScriptsRoot 'codex-output-limits.mjs'))
    $configuration | ConvertTo-Json -Depth 30 -Compress | & $nodePath $runnerArguments | ForEach-Object { Write-Host $_ }
    return [int]$LASTEXITCODE
}

function Invoke-UngateOutputLimitsMenu {
    param([Parameter(Mandatory)][object]$Context, [Parameter(Mandatory)][object[]]$Definitions)
    $ErrorActionPreference = 'Stop'
    $null = Invoke-UngateOutputLimits -Context $Context -Definitions $Definitions
    Write-Host 'Тест делает платные запросы. Короткий тест проверяет принятие бюджета, не генерацию до предела.' -ForegroundColor Yellow
    for ($index = 0; $index -lt $Definitions.Count; $index++) { Write-Host "  $($index + 1)) $($Definitions[$index].DisplayName)" }
    $choice = Read-Host 'Номер модели для теста; Enter — назад'
    if (-not $choice) { return }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $Definitions.Count) { Write-Warning 'Неверный номер.'; return }
    $value = Read-Host 'Проверяемый бюджет (целое число); Enter — заявленный максимум, если известен'
    $budget = 0
    if ($value -and (-not [int]::TryParse($value, [ref]$budget) -or $budget -lt 1)) { Write-Warning 'Нужен положительный целый бюджет.'; return }
    $mode = Read-Host 'T — короткий тест; FULL — дорогая генерация до заданного предела; Enter — отмена'
    if ($mode -notin @('T', 'FULL')) { return }
    $null = Invoke-UngateOutputLimits -Context $Context -Definitions @($Definitions[$number - 1]) -Probe -Budget $budget -Full:($mode -eq 'FULL')
    $null = Read-Host 'Нажмите Enter для возврата'
}

Export-ModuleMember -Function @('Invoke-UngateOutputLimits', 'Invoke-UngateOutputLimitsMenu')
