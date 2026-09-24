# Shared key resolution and preflight helpers for Codex launchers.
function Resolve-UngateApiKey {
    param(
        [string]$ApiKey,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    if ($ApiKey) { return $ApiKey }
    if ($env:UNGATE_API_KEY) { return $env:UNGATE_API_KEY }

    $ungateDb = Join-Path $HOME '.ungate\data.db'
    $betterSqlite3Path = Join-Path $RepoRoot 'apps\api\node_modules\better-sqlite3'

    if (-not (Test-Path -LiteralPath $ungateDb)) {
        throw "Ungate DB not found at $ungateDb. Start the ungate-api service or log in via the Ungate dashboard."
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'node not found on PATH.'
    }

    $tmpJs = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.cjs')
    $stderrFile = [System.IO.Path]::GetTempFileName()
    @"
// Prefer Node's bundled SQLite: native addons may target the previous Node ABI.
let DatabaseSync;
try {
    ({ DatabaseSync } = require('node:sqlite'));
} catch (error) {
    if (error.code !== 'ERR_UNKNOWN_BUILTIN_MODULE') throw error;
}
const db = DatabaseSync
    ? new DatabaseSync(process.env.UNGATE_DB_PATH, { readOnly: true })
    : new (require(process.env.UNGATE_BS3_PATH))(process.env.UNGATE_DB_PATH, { readonly: true });
try {
    const row = db.prepare('SELECT api_key FROM app_settings WHERE id = 1').get();
    if (row && row.api_key) { process.stdout.write(row.api_key); }
} finally {
    db.close();
}
"@ | Set-Content -LiteralPath $tmpJs -Encoding utf8

    $previousBs3Path = $env:UNGATE_BS3_PATH
    $previousDbPath = $env:UNGATE_DB_PATH
    $env:UNGATE_BS3_PATH = ($betterSqlite3Path -replace '\\', '/')
    $env:UNGATE_DB_PATH = ($ungateDb -replace '\\', '/')

    try {
        $key = (& node @($tmpJs) 2>$stderrFile)
        if ($LASTEXITCODE -ne 0 -or -not $key) {
            $nodeError = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
            throw "Could not read api_key from $ungateDb.`nnode stderr: $nodeError"
        }
        return $key
    }
    finally {
        Remove-Item -LiteralPath $tmpJs -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue

        if ($null -eq $previousBs3Path) {
            Remove-Item Env:\UNGATE_BS3_PATH -ErrorAction SilentlyContinue
        } else {
            $env:UNGATE_BS3_PATH = $previousBs3Path
        }

        if ($null -eq $previousDbPath) {
            Remove-Item Env:\UNGATE_DB_PATH -ErrorAction SilentlyContinue
        } else {
            $env:UNGATE_DB_PATH = $previousDbPath
        }
    }
}

function Test-UngateResponsesBridge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyOpenAiBaseUrl
    )

    try {
        $response = Invoke-WebRequest `
            -Method Get `
            -Uri "$ProxyOpenAiBaseUrl/responses/health" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -SkipHttpErrorCheck `
            -ErrorAction Stop
    }
    catch {
        throw "Could not reach /v1/responses: $($_.Exception.Message)"
    }

    $statusCode = [int]$response.StatusCode
    $text = $response.Content

    if ($statusCode -eq 404) {
        throw '/v1/responses/health returned 404. Rebuild the NSSM bundle and restart the ungate-api service.'
    }
    if ($statusCode -in @(401, 403)) {
        $detail = Get-CliProxyHttpErrorDetail -Content $text
        throw "/v1/responses/health authentication failed with HTTP ${statusCode}: $detail"
    }
    if ($statusCode -ne 200) {
        $detail = Get-CliProxyHttpErrorDetail -Content $text
        throw "/v1/responses/health preflight failed with HTTP ${statusCode}: $detail"
    }

    try {
        $payload = $text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "/v1/responses/health returned invalid JSON: $($_.Exception.Message)"
    }

    if ($payload.status -ne 'ok' -or $payload.wire_api -ne 'responses') {
        throw '/v1/responses/health returned an unexpected health response.'
    }
}

function Get-CliProxyHttpErrorDetail {
    param(
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return 'empty response body'
    }

    try {
        $payload = $Content | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        if ($payload.error -is [string] -and -not [string]::IsNullOrWhiteSpace($payload.error)) {
            return [string]$payload.error
        }
        if ($payload.error.message) {
            return [string]$payload.error.message
        }
        if ($payload.message) {
            return [string]$payload.message
        }
    }
    catch {
        # Fall back to the raw response body below.
    }

    $trimmed = $Content.Trim()
    if ($trimmed.Length -gt 500) {
        return $trimmed.Substring(0, 500) + '...'
    }
    return $trimmed
}

function Test-CliProxyResponsesInference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyOpenAiBaseUrl
    )

    $body = [ordered]@{
        model = $Model
        input = 'Reply with exactly OK.'
        max_output_tokens = 16
        stream = $false
        store = $false
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri "$ProxyOpenAiBaseUrl/responses" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec 15 `
            -SkipHttpErrorCheck `
            -ErrorAction Stop
    }
    catch {
        throw "Could not reach CLIProxyAPI /v1/responses: $($_.Exception.Message)"
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        $detail = Get-CliProxyHttpErrorDetail -Content ([string]$response.Content)
        if ($detail -match '(?i)auth_unavailable|no auth available') {
            throw "CLIProxyAPI has no available xAI authorization for model '$Model'. Re-authenticate xAI in CLIProxyAPI and retry. Upstream: $detail"
        }
        throw "CLIProxyAPI /v1/responses inference preflight failed with HTTP ${statusCode}: $detail"
    }

    try {
        $payload = ([string]$response.Content) | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "CLIProxyAPI /v1/responses returned invalid JSON: $($_.Exception.Message)"
    }

    $outputText = @(
        $payload.output |
            Where-Object { $_.type -eq 'message' } |
            ForEach-Object { $_.content } |
            Where-Object { $_.type -eq 'output_text' } |
            ForEach-Object { [string]$_.text }
    ) -join ''
    if ($outputText.Trim().TrimEnd('.') -ne 'OK') {
        throw "CLIProxyAPI /v1/responses returned unexpected preflight output for model '$Model'."
    }

    Test-CliProxyResponsesToolCall `
        -Key $Key `
        -Model $Model `
        -ProxyOpenAiBaseUrl $ProxyOpenAiBaseUrl
}

function Test-CliProxyResponsesToolCall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyOpenAiBaseUrl
    )

    $tool = [ordered]@{
        type = 'namespace'
        name = 'cliproxy_preflight'
        tools = @(
            [ordered]@{
                type = 'function'
                name = 'bridge_preflight'
                description = 'Bridge compatibility probe.'
                parameters = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{}
                    additionalProperties = $false
                }
            }
        )
    }
    $body = [ordered]@{
        model = $Model
        input = 'Call the selected bridge preflight function exactly once.'
        tools = @($tool)
        tool_choice = [ordered]@{
            type = 'function'
            namespace = 'cliproxy_preflight'
            name = 'bridge_preflight'
        }
        parallel_tool_calls = $false
        max_output_tokens = 32
        stream = $false
        store = $false
    } | ConvertTo-Json -Depth 20 -Compress

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri "$ProxyOpenAiBaseUrl/responses" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec 15 `
            -SkipHttpErrorCheck `
            -ErrorAction Stop
    }
    catch {
        throw "Could not reach CLIProxyAPI tool-call preflight: $($_.Exception.Message)"
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "CLIProxyAPI tool-call preflight failed with HTTP ${statusCode}."
    }

    try {
        $payload = ([string]$response.Content) | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw 'CLIProxyAPI tool-call preflight returned invalid JSON.'
    }

    $functionCalls = @(
        $payload.output | Where-Object {
            $_.type -eq 'function_call' -and
            $_.name -eq 'bridge_preflight' -and
            $_.namespace -eq 'cliproxy_preflight'
        }
    )
    if ($functionCalls.Count -ne 1) {
        throw "CLIProxyAPI tool-call preflight returned an unexpected function-call output for model '$Model'."
    }

    try {
        $arguments = ([string]$functionCalls[0].arguments) | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        if ($null -eq $arguments -or $arguments -is [string] -or $arguments -is [array]) {
            throw 'arguments are not an object'
        }
    }
    catch {
        throw "CLIProxyAPI tool-call preflight returned invalid function-call arguments for model '$Model'."
    }
}

function Invoke-CliProxyPreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBaseUrl
    )

    $catalogWarning = $null
    try {
        $models = Invoke-RestMethod `
            -Uri "$ProxyBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
        $ids = @($models.data | ForEach-Object { [string]$_.id })
        if ($Model -notin $ids) {
            $catalogWarning = "Model '$Model' is not advertised by $ProxyBaseUrl/v1/models. Available: $($ids -join ', ')"
        }
    }
    catch {
        $catalogWarning = "Could not validate model '$Model' through $ProxyBaseUrl/v1/models: $($_.Exception.Message)"
    }

    if ($catalogWarning) {
        Write-Host "[ungate] Warning: $catalogWarning" -ForegroundColor Yellow
        Write-Host '[ungate] Continuing with authoritative live /v1/responses preflight.' -ForegroundColor DarkGray
    }
    else {
        Write-Host "[ungate] Model '$Model' available." -ForegroundColor Green
    }

    Test-CliProxyResponsesInference `
        -Key $Key `
        -Model $Model `
        -ProxyOpenAiBaseUrl "$ProxyBaseUrl/v1"
    Write-Host `
        "[ungate] Live /v1/responses inference preflight passed for '$Model'." `
        -ForegroundColor Green
}

function Invoke-UngatePreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBaseUrl
    )

    try {
        $health = Invoke-RestMethod -Uri "$ProxyBaseUrl/health" -TimeoutSec 3 -ErrorAction Stop
        if ($health.status -ne 'ok') {
            throw 'health.status != ok'
        }
    }
    catch {
        throw "Proxy at $ProxyBaseUrl is not reachable. Start it with 'nssm start ungate-api'."
    }
    Write-Host "[ungate] Proxy healthy at $ProxyBaseUrl." -ForegroundColor Green

    try {
        $models = Invoke-RestMethod `
            -Uri "$ProxyBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "Could not list /v1/models: $($_.Exception.Message)"
    }

    $ids = @($models.data | ForEach-Object { $_.id })
    if ($Model -notin $ids) {
        throw "Model '$Model' not found in /v1/models. Available: $($ids -join ', ')"
    }
    Write-Host "[ungate] Model '$Model' available." -ForegroundColor Green

    Test-UngateResponsesBridge `
        -Key $Key `
        -Model $Model `
        -ProxyOpenAiBaseUrl "$ProxyBaseUrl/v1"
    Write-Host '[ungate] /v1/responses bridge available.' -ForegroundColor Green
}

function Resolve-OmniRouteApiKey {
    param(
        [string]$ApiKey
    )

    if ($ApiKey) { return $ApiKey }
    if ($env:OMNIROUTE_CODEX_API_KEY) { return $env:OMNIROUTE_CODEX_API_KEY }
    if ($env:OMNIROUTE_API_KEY) { return $env:OMNIROUTE_API_KEY }

    throw 'OmniRoute client key is required. Pass -ApiKey or set OMNIROUTE_CODEX_API_KEY (preferred) or OMNIROUTE_API_KEY (legacy fallback).'
}

function Invoke-OmniRoutePreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBaseUrl
    )

    try {
        $health = Invoke-RestMethod `
            -Uri "$ProxyBaseUrl/api/health/ping" `
            -TimeoutSec 3 `
            -ErrorAction Stop
        if ($health.status -ne 'ok') {
            throw 'health.status != ok'
        }
    }
    catch {
        throw "OmniRoute is not reachable at $ProxyBaseUrl. Start OmniRoute manually."
    }
    Write-Host "[ungate] OmniRoute healthy at $ProxyBaseUrl." -ForegroundColor Green

    try {
        $models = Invoke-RestMethod `
            -Uri "$ProxyBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "Could not list OmniRoute /v1/models. Verify OMNIROUTE_API_KEY and key permissions: $($_.Exception.Message)"
    }

    $ids = @($models.data | ForEach-Object { $_.id })
    if ($Model -notin $ids) {
        throw "OmniRoute model/combo '$Model' was not found in /v1/models. Available: $($ids -join ', ')"
    }
    Write-Host "[ungate] OmniRoute model/combo '$Model' available." -ForegroundColor Green

    $body = [ordered]@{
        model = $Model
        input = 'Reply with exactly OK.'
        max_output_tokens = 16
        stream = $false
        store = $false
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri "$ProxyBaseUrl/v1/responses" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec 60 `
            -SkipHttpErrorCheck `
            -ErrorAction Stop
    }
    catch {
        throw "Could not reach OmniRoute /v1/responses: $($_.Exception.Message)"
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        $detail = Get-CliProxyHttpErrorDetail -Content ([string]$response.Content)
        throw "OmniRoute /v1/responses preflight failed with HTTP ${statusCode}: $detail"
    }

    try {
        $payload = ([string]$response.Content) | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "OmniRoute /v1/responses returned invalid JSON: $($_.Exception.Message)"
    }
    if (-not $payload.id -and -not $payload.output) {
        throw "OmniRoute /v1/responses returned an unexpected response for model/combo '$Model'."
    }

    Write-Host "[ungate] Live OmniRoute /v1/responses preflight passed for '$Model'." -ForegroundColor Green
}
