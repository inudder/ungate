#requires -Version 7
<#
.SYNOPSIS
    Starts Codex against the local Ungate proxy (port 47821) or OmniRoute proxy (port 20128).

.DESCRIPTION
    1. Resolves the API key for Ungate (or OmniRoute if -UseOmniRoute/-Provider omniroute is specified).
    2. Exports $env:UNGATE_API_KEY or $env:OMNIROUTE_API_KEY for this process only.
    3. Runs pre-flight health check on target proxy.
    4. Verifies the model id is listed by /v1/models.
    5. Verifies the inbound /v1/responses bridge exists.
    6. Launches Codex with process-local model_provider overrides using wire_api = "responses".

.PARAMETER ApiKey
    API key. If omitted for Ungate, falls back to $env:UNGATE_API_KEY, then ~/.ungate/data.db.
    If omitted for OmniRoute, falls back to $env:OMNIROUTE_API_KEY.

.PARAMETER Profile
    Model id or combo to use (default: ungate-opus-4-8).

.PARAMETER Provider
    Proxy provider to use: ungate_proxy (default) or omniroute.

.PARAMETER UseOmniRoute
    Shortcut switch to select OmniRoute proxy (port 20128).

.PARAMETER PreflightOnly
    Run all checks but do not launch Codex.

.PARAMETER Remaining
    Extra arguments forwarded to codex (e.g. "exec", '"review this change"').

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-ungate.ps1
    # validates Ungate health and starts Codex with ungate-opus-4-8

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-ungate.ps1 -UseOmniRoute -Profile kimi-k3
    # validates OmniRoute health and starts Codex with kimi-k3
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Profile = 'ungate-opus-4-8',
    [ValidateSet('ungate_proxy', 'omniroute')]
    [string]$Provider = 'ungate_proxy',
    [switch]$UseOmniRoute,
    [switch]$PreflightOnly,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'

if ($UseOmniRoute) {
    $Provider = 'omniroute'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')

if ($Provider -eq 'omniroute') {
    $ProxyBaseUrl = 'http://127.0.0.1:20128'
    $ProxyOpenAiBaseUrl = "$ProxyBaseUrl/v1"
    $ProviderName = 'omniroute'
    $ProviderDisplayName = 'OmniRoute Proxy (local 20128)'
    $EnvKey = 'OMNIROUTE_API_KEY'
} else {
    $ProxyBaseUrl = 'http://127.0.0.1:47821'
    $ProxyOpenAiBaseUrl = "$ProxyBaseUrl/v1"
    $ProviderName = 'ungate_proxy'
    $ProviderDisplayName = 'Ungate Proxy (local 47821)'
    $EnvKey = 'UNGATE_API_KEY'
}

function Invoke-CodexWithProxy {
    param(
        [string]$Model,
        [string]$ProviderName,
        [string]$ProviderDisplayName,
        [string]$ProxyOpenAiBaseUrl,
        [string]$EnvKey
    )

    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        throw "codex not found on PATH."
    }

    $codexArgs = @(
        '--model', $Model,
        '-c', "model_provider=`"$ProviderName`"",
        '-c', "model_providers.$ProviderName.name=`"$ProviderDisplayName`"",
        '-c', "model_providers.$ProviderName.base_url=`"$ProxyOpenAiBaseUrl`"",
        '-c', "model_providers.$ProviderName.env_key=`"$EnvKey`"",
        '-c', "model_providers.$ProviderName.wire_api=`"responses`""
    )

    Write-Host "[ungate] Launching Codex: codex --model $Model (provider=$ProviderName, base_url=$ProxyOpenAiBaseUrl)." -ForegroundColor Green
    & codex @codexArgs @Remaining
    exit $LASTEXITCODE
}

# 1. Resolve + export key (child session only)
if ($Provider -eq 'omniroute') {
    $key = Resolve-OmniRouteApiKey -ApiKey $ApiKey
    $env:OMNIROUTE_API_KEY = $key
    Write-Host "[ungate] OmniRoute API key resolved (len=$($key.Length))." -ForegroundColor DarkGray
} else {
    $key = Resolve-UngateApiKey -ApiKey $ApiKey -RepoRoot $RepoRoot
    $env:UNGATE_API_KEY = $key
    Write-Host "[ungate] Ungate API key resolved (len=$($key.Length))." -ForegroundColor DarkGray
}

# 2. Validate the proxy, model mapping, and Responses bridge.
$preflightFailed = $false
try {
    if ($Provider -eq 'omniroute') {
        Invoke-OmniRoutePreflight -Key $key -Model $Profile -ProxyBaseUrl $ProxyBaseUrl
    } else {
        Invoke-UngatePreflight -Key $key -Model $Profile -ProxyBaseUrl $ProxyBaseUrl
    }
}
catch {
    $preflightFailed = $true
    Write-Host '[ungate] Preflight failed.' -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Yellow
    if ($Provider -eq 'ungate_proxy') {
        Write-Host "        Run: pnpm --filter @ungate/api build:bundle; then restart: nssm restart ungate-api" -ForegroundColor Yellow
    }
}

if ($PreflightOnly) {
    if ($preflightFailed) {
        exit 2
    }
    Write-Host "[ungate] Preflight passed. Skipping Codex launch because -PreflightOnly was set." -ForegroundColor Green
    exit 0
}

Invoke-CodexWithProxy `
    -Model $Profile `
    -ProviderName $ProviderName `
    -ProviderDisplayName $ProviderDisplayName `
    -ProxyOpenAiBaseUrl $ProxyOpenAiBaseUrl `
    -EnvKey $EnvKey

