#requires -Version 7
<#
.SYNOPSIS
    Starts Codex against the local Ungate proxy (port 47821) with ungate-opus-4-8.

.DESCRIPTION
    1. Resolves the Ungate API key in priority: -ApiKey > $env:UNGATE_API_KEY > ~/.ungate/data.db (app_settings.api_key).
    2. Exports $env:UNGATE_API_KEY for this process only.
    3. Pre-flight health check on http://127.0.0.1:47821/health.
    4. Verifies the model id is listed by /v1/models.
    5. Verifies the inbound /v1/responses bridge exists without spending model tokens.
    6. Launches Codex with a process-local model_provider override using wire_api = "responses".

.PARAMETER ApiKey
    Ungate API key (16-hex). If omitted, falls back to $env:UNGATE_API_KEY, then to the Ungate DB.

.PARAMETER Profile
    Ungate model id to use (default: ungate-opus-4-8).

.PARAMETER PreflightOnly
    Run all Ungate checks but do not launch Codex.

.PARAMETER Remaining
    Extra arguments forwarded to codex (e.g. "exec", '"review this change"').

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-ungate.ps1
    # validates Ungate health, API key, model mapping, Responses bridge; then starts Codex
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Profile = 'ungate-opus-4-8',
    [switch]$PreflightOnly,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'

$ProxyBaseUrl = 'http://127.0.0.1:47821'
$ProxyOpenAiBaseUrl = "$ProxyBaseUrl/v1"
$ProviderName = 'ungate_proxy'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')

function Invoke-CodexWithUngate {
    param([string]$Model)

    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) {
        throw "codex not found on PATH."
    }

    $codexArgs = @(
        '--model', $Model,
        '-c', "model_provider=`"$ProviderName`"",
        '-c', "model_providers.$ProviderName.name=`"Ungate Proxy (local 47821)`"",
        '-c', "model_providers.$ProviderName.base_url=`"$ProxyOpenAiBaseUrl`"",
        '-c', "model_providers.$ProviderName.env_key=`"UNGATE_API_KEY`"",
        '-c', "model_providers.$ProviderName.wire_api=`"responses`""
    )

    Write-Host "[ungate] Launching Codex: codex --model $Model (provider=$ProviderName, base_url=$ProxyOpenAiBaseUrl)." -ForegroundColor Green
    & codex @codexArgs @Remaining
    exit $LASTEXITCODE
}

# 1. Resolve + export key (child session only)
$key = Resolve-UngateApiKey -ApiKey $ApiKey -RepoRoot $RepoRoot
$env:UNGATE_API_KEY = $key
Write-Host "[ungate] API key resolved (len=$($key.Length))." -ForegroundColor DarkGray

# 2. Validate the proxy, model mapping, and Responses bridge.
try {
    Invoke-UngatePreflight -Key $key -Model $Profile -ProxyBaseUrl $ProxyBaseUrl
}
catch {
    Write-Host '[ungate] Preflight failed.' -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "        Run: pnpm --filter @ungate/api build:bundle; then restart: nssm restart ungate-api" -ForegroundColor Yellow
    exit 2
}

if ($PreflightOnly) {
    Write-Host "[ungate] Preflight passed. Skipping Codex launch because -PreflightOnly was set." -ForegroundColor Green
    exit 0
}

Invoke-CodexWithUngate -Model $Profile
