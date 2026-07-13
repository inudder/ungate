# Shared key resolution and token-free preflight for Codex launchers.
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
    if (-not (Test-Path -LiteralPath $betterSqlite3Path)) {
        throw "better-sqlite3 not found at $betterSqlite3Path. Run 'pnpm --filter @ungate/api install' in the repo."
    }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'node not found on PATH.'
    }

    $tmpJs = [System.IO.Path]::GetTempFileName() + '.cjs'
    $stderrFile = [System.IO.Path]::GetTempFileName()
    @"
const Database = require(process.env.UNGATE_BS3_PATH);
const db = new Database(process.env.UNGATE_DB_PATH, { readonly: true });
const row = db.prepare('SELECT api_key FROM app_settings WHERE id = 1').get();
if (row && row.api_key) { process.stdout.write(row.api_key); }
db.close();
"@ | Set-Content -LiteralPath $tmpJs -Encoding utf8

    $previousBs3Path = $env:UNGATE_BS3_PATH
    $previousDbPath = $env:UNGATE_DB_PATH
    $env:UNGATE_BS3_PATH = ($betterSqlite3Path -replace '\\', '/')
    $env:UNGATE_DB_PATH = ($ungateDb -replace '\\', '/')

    try {
        $key = (& node $tmpJs 2>$stderrFile)
        if (-not $key) {
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

    $body = @{
        model = $Model
        input = ''
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri "$ProxyOpenAiBaseUrl/responses" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -ContentType 'application/json' `
            -Body $body `
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
        throw '/v1/responses returned 404. Rebuild the NSSM bundle and restart the ungate-api service.'
    }
    if ($statusCode -eq 400 -and $text -match 'Responses input must not be empty') {
        return
    }

    throw "/v1/responses preflight failed with HTTP ${statusCode}: $text"
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
