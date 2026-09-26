#requires -Version 7.4
# ProxyRuntime: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Routing.psm1') -DisableNameChecking -ErrorAction Stop

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'ungate-codex-common.ps1')

function Resolve-CliProxyApiKey {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    if ($env:CLIPROXYAPI_API_KEY) {
        return $env:CLIPROXYAPI_API_KEY
    }

    if (-not (Test-Path -LiteralPath $Context.CliProxyConfigPath)) {
        throw "CLIProxyAPI config not found at $($Context.CliProxyConfigPath)."
    }

    $lines = Get-Content -LiteralPath $Context.CliProxyConfigPath
    $inApiKeys = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*api-keys:\s*$') {
            $inApiKeys = $true
            continue
        }
        if ($inApiKeys) {
            if ($line -match '^\S') {
                break
            }
            if ($line -match '^\s*-\s*(?:"([^"]+)"|''([^'']+)''|(\S+))\s*$') {
                $key = $Matches[1]
                if (-not $key) { $key = $Matches[2] }
                if (-not $key) { $key = $Matches[3] }
                if ($key) {
                    return $key
                }
            }
        }
    }

    throw "Could not find api-keys in $($Context.CliProxyConfigPath). Set CLIPROXYAPI_API_KEY or add api-keys to the config."
}

function Get-CliProxyBridgeHealth {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    try {
        $health = Invoke-RestMethod `
            -Uri "$($Context.CliProxyBaseUrl)/_bridge/health" `
            -TimeoutSec 2 `
            -ErrorAction Stop
        return $health
    }
    catch {
        return $null
    }
}

function Test-LocalTcpListener {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )
    $ErrorActionPreference = 'Stop'

    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Test-CliProxyBridgeProcessIdentity {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )
    $ErrorActionPreference = 'Stop'

    $commandLine = $null
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $commandLine = $p.CommandLine
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        $process = Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ProcessId = $ProcessId" `
            -ErrorAction SilentlyContinue
        if ($process) {
            $commandLine = $process.CommandLine
        }
    }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    $expectedPath = [System.IO.Path]::GetFullPath($Context.CliProxyBridgePath)
    return $commandLine.IndexOf(
        $expectedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

function Ensure-CliProxyBridge {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Context.CliProxyBridgePath -PathType Leaf)) {
        throw "CLIProxy compatibility bridge not found at $($Context.CliProxyBridgePath)."
    }

    try {
        $null = Invoke-RestMethod `
            -Uri "$($Context.CliProxyUpstreamBaseUrl)/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "CLIProxyAPI upstream at $($Context.CliProxyUpstreamBaseUrl) is not reachable: $($_.Exception.Message)"
    }
    Write-Host "[ungate] CLIProxyAPI upstream healthy at $($Context.CliProxyUpstreamBaseUrl)." -ForegroundColor Green

    $expectedBuildId = (Get-FileHash -LiteralPath $Context.CliProxyBridgePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedUpstream = $Context.CliProxyUpstreamBaseUrl.TrimEnd('/')
    $bridgeListening = Test-LocalTcpListener -Port 8318
    $health = if ($bridgeListening) { Get-CliProxyBridgeHealth -Context $Context } else { $null }
    $bridgeReady = $false

    if ($health) {
        if ($health.status -ne 'ok' -or $health.service -ne $Context.CliProxyBridgeServiceName) {
            throw "Port 8318 is occupied by an unexpected HTTP service. Refusing to stop it."
        }

        $sameBuild = [string]$health.build_id -eq $expectedBuildId
        $sameUpstream = ([string]$health.upstream).TrimEnd('/') -eq $expectedUpstream
        if ($sameBuild -and $sameUpstream) {
            $bridgeReady = $true
            Write-Host "[ungate] Reusing CLIProxy compatibility bridge (PID $($health.pid))." -ForegroundColor DarkGray
        }
        else {
            $bridgeProcessId = [int]$health.pid
            if (-not (Test-CliProxyBridgeProcessIdentity -Context $Context -ProcessId $bridgeProcessId)) {
                throw "Port 8318 reports a stale bridge, but PID $bridgeProcessId does not run $($Context.CliProxyBridgePath). Refusing to stop it."
            }

            Write-Host "[ungate] Restarting stale CLIProxy compatibility bridge (PID $bridgeProcessId)..." -ForegroundColor Yellow
            Stop-Process -Id $bridgeProcessId -Force -ErrorAction Stop
            $stopDeadline = (Get-Date).AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
            } while (
                (Test-LocalTcpListener -Port 8318) -and
                (Get-Date) -lt $stopDeadline
            )
            if (Test-LocalTcpListener -Port 8318) {
                throw 'The stale CLIProxy compatibility bridge did not release port 8318.'
            }
        }
    }
    elseif ($bridgeListening) {
        throw "Port 8318 is occupied, but /_bridge/health did not identify the compatibility bridge. Refusing to stop it."
    }

    if (-not $bridgeReady) {
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
        if (-not $nodeCommand -or -not (Test-Path -LiteralPath $nodeCommand.Source -PathType Leaf)) {
            throw 'node.exe is required to run the CLIProxy compatibility bridge.'
        }

        $logDirectory = Join-Path $Context.CustomCodexHome 'logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $stdoutPath = Join-Path $logDirectory 'cliproxy-namespace-bridge.out.log'
        $stderrPath = Join-Path $logDirectory 'cliproxy-namespace-bridge.err.log'
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

        $bridgeEnvironment = @{
            CLIPROXY_BRIDGE_HOST = '127.0.0.1'
            CLIPROXY_BRIDGE_PORT = '8318'
            CLIPROXY_UPSTREAM = $Context.CliProxyUpstreamBaseUrl
            CLIPROXY_BRIDGE_BUILD_ID = $expectedBuildId
            CLIPROXY_BRIDGE_MAX_BODY_BYTES = '134217728'
            CLIPROXY_BRIDGE_MAX_INPUT_TOKENS = '500000'
        }
        $bridgeProcess = Start-Process `
            -FilePath ([string]$nodeCommand.Source) `
            -ArgumentList @("`"$($Context.CliProxyBridgePath)`"") `
            -WorkingDirectory $Context.RepoRoot `
            -WindowStyle Hidden `
            -Environment $bridgeEnvironment `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru

        $startDeadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 200
            $bridgeProcess.Refresh()
            if ($bridgeProcess.HasExited) {
                $bridgeError = Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue
                throw "CLIProxy compatibility bridge exited with code $($bridgeProcess.ExitCode). $($bridgeError -join ' ')"
            }
            $health = Get-CliProxyBridgeHealth -Context $Context
        } while (-not $health -and (Get-Date) -lt $startDeadline)

        if (
            -not $health -or
            $health.status -ne 'ok' -or
            $health.service -ne $Context.CliProxyBridgeServiceName -or
            [string]$health.build_id -ne $expectedBuildId -or
            ([string]$health.upstream).TrimEnd('/') -ne $expectedUpstream
        ) {
            Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
            throw "CLIProxy compatibility bridge failed its startup health check at $($Context.CliProxyBaseUrl)."
        }
        Write-Host "[ungate] CLIProxy compatibility bridge started at $($Context.CliProxyBaseUrl) (PID $($health.pid))." -ForegroundColor Green
    }

    try {
        $null = Invoke-RestMethod `
            -Uri "$($Context.CliProxyBaseUrl)/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "CLIProxy compatibility bridge could not proxy /v1/models: $($_.Exception.Message)"
    }
    Write-Host '[ungate] CLIProxy compatibility bridge proxy check passed.' -ForegroundColor Green
}

function Get-CodexModelShellRouterHealth {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    try {
        return Invoke-RestMethod `
            -Uri "$($Context.CodexModelShellRouterBaseUrl)/_shell-router/health" `
            -TimeoutSec 2 `
            -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-CodexModelShellRouterProcessIdentity {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )
    $ErrorActionPreference = 'Stop'

    $commandLine = $null
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $commandLine = $p.CommandLine
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        $process = Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ProcessId = $ProcessId" `
            -ErrorAction SilentlyContinue
        if ($process) {
            $commandLine = $process.CommandLine
        }
    }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        return $false
    }

    $expectedPath = [System.IO.Path]::GetFullPath($Context.CodexModelShellRouterPath)
    return $commandLine.IndexOf(
        $expectedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

function Ensure-CodexModelShellRouter {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection,

        [Parameter(Mandatory = $true)]
        [object[]]$Routes,
        [Parameter(Mandatory = $true)]
        [hashtable]$ProviderKeys
    )
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Context.CodexModelShellRouterPath -PathType Leaf)) {
        throw "Codex model-shell router not found at $($Context.CodexModelShellRouterPath)."
    }

    $routerPort = ([uri]$Context.CodexModelShellRouterBaseUrl).Port
    $routerListening = Test-LocalTcpListener -Port $routerPort
    $health = if ($routerListening) { Get-CodexModelShellRouterHealth -Context $Context } else { $null }
    if ($health) {
        if ($health.status -ne 'ok' -or $health.service -ne $Context.CodexModelShellRouterServiceName) {
            throw "Port $routerPort is occupied by an unexpected HTTP service. Refusing to stop it."
        }

        $routerProcessId = [int]$health.pid
        if (-not (Test-CodexModelShellRouterProcessIdentity -Context $Context -ProcessId $routerProcessId)) {
            throw "Port $routerPort reports the model-shell router, but PID $routerProcessId does not run $($Context.CodexModelShellRouterPath). Refusing to stop it."
        }

        Write-Host "[ungate] Restarting Codex model-shell router (PID $routerProcessId) to refresh model routes." -ForegroundColor DarkGray
        Stop-Process -Id $routerProcessId -Force -ErrorAction Stop
        $stopDeadline = (Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
        } while (
            (Test-LocalTcpListener -Port $routerPort) -and
            (Get-Date) -lt $stopDeadline
        )
        if (Test-LocalTcpListener -Port $routerPort) {
            throw "The Codex model-shell router did not release port $routerPort."
        }
    }
    elseif ($routerListening) {
        throw "Port $routerPort is occupied, but /_shell-router/health did not identify the Codex model-shell router. Refusing to stop it."
    }

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCommand -or -not (Test-Path -LiteralPath $nodeCommand.Source -PathType Leaf)) {
        throw 'node.exe is required to run the Codex model-shell router.'
    }

    $routerEnvironment = @{
        CODEX_SHELL_ROUTER_HOST = '127.0.0.1'
        CODEX_SHELL_ROUTER_TOOLS_CACHE_PATH = Join-Path $Context.CustomCodexHome 'tool-compatibility/tools-schema-cache.json'
        CODEX_SHELL_ROUTER_PORT = [string]$routerPort
        CODEX_SHELL_ROUTER_BUILD_ID = (Get-FileHash -LiteralPath $Context.CodexModelShellRouterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        CODEX_SHELL_ROUTER_MAX_BODY_BYTES = '134217728'
        CODEX_SHELL_ROUTER_ROUTES_JSON = ([ordered]@{ routes = @($Routes) } | ConvertTo-Json -Depth 20 -Compress)
    }
    foreach ($provider in (Get-ProviderDefinitions -Selection $Selection)) {
        $providerKey = $ProviderKeys[$provider.Name]
        if ([string]::IsNullOrWhiteSpace($providerKey)) {
            throw "Missing API key for model-shell route provider '$($provider.Name)'."
        }
        $routerEnvironment[$provider.EnvKey] = $providerKey
    }

    $logDirectory = Join-Path $Context.CustomCodexHome 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $stdoutPath = Join-Path $logDirectory 'codex-model-shell-router.out.log'
    $stderrPath = Join-Path $logDirectory 'codex-model-shell-router.err.log'
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $routerProcess = Start-Process `
        -FilePath ([string]$nodeCommand.Source) `
        -ArgumentList @("`"$($Context.CodexModelShellRouterPath)`"") `
        -WorkingDirectory $Context.RepoRoot `
        -WindowStyle Hidden `
        -Environment $routerEnvironment `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    $startDeadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        $routerProcess.Refresh()
        if ($routerProcess.HasExited) {
            $routerError = Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue
            throw "Codex model-shell router exited with code $($routerProcess.ExitCode). $($routerError -join ' ')"
        }
        $health = Get-CodexModelShellRouterHealth -Context $Context
    } while (-not $health -and (Get-Date) -lt $startDeadline)

    $expectedShells = @($Routes | ForEach-Object { [string]$_.clientModel })
    $actualShells = @($health.route_models | ForEach-Object { [string]$_ })
    $sameShells = (
        $health -and
        $health.status -eq 'ok' -and
        $health.service -eq $Context.CodexModelShellRouterServiceName -and
        $actualShells.Count -eq $expectedShells.Count -and
        -not (Compare-Object -ReferenceObject $expectedShells -DifferenceObject $actualShells)
    )
    if (-not $sameShells) {
        Stop-Process -Id $routerProcess.Id -Force -ErrorAction SilentlyContinue
        throw "Codex model-shell router failed its startup health check at $($Context.CodexModelShellRouterBaseUrl)."
    }

    Write-Host "[ungate] Codex model-shell router ready at $($Context.CodexModelShellRouterBaseUrl) (PID $($health.pid))." -ForegroundColor Green
}

function Resolve-ModelApiKey {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object]$Definition,
        [string]$ApiKey
    )
    $ErrorActionPreference = 'Stop'

    if ($Definition.ProviderName -eq $Context.OmniRouteProviderName) {
        if ($ApiKey) {
            return $ApiKey
        }
        if ($env:OMNIROUTE_CODEX_API_KEY) {
            return $env:OMNIROUTE_CODEX_API_KEY
        }
        if ($env:OMNIROUTE_API_KEY) {
            return $env:OMNIROUTE_API_KEY
        }

        throw 'OmniRoute client key is required. Pass -ApiKey or set OMNIROUTE_CODEX_API_KEY (preferred) or OMNIROUTE_API_KEY (legacy fallback).'
    }

    if ($Definition.RequiresUngate) {
        return Resolve-UngateApiKey -ApiKey $ApiKey -RepoRoot $Context.RepoRoot
    }

    if ($ApiKey) {
        return $ApiKey
    }

    return Resolve-CliProxyApiKey -Context $Context
}

function Invoke-DesktopOmniRoutePreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBaseUrl
    )
    $ErrorActionPreference = 'Stop'

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
        throw "OmniRoute is not reachable at $ProxyBaseUrl. Start OmniRoute manually, then retry with -EnableProviderFallback."
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
        throw "Could not list OmniRoute /v1/models. Verify OMNIROUTE_CODEX_API_KEY and the codex-local key permissions: $($_.Exception.Message)"
    }

    $ids = @($models.data | ForEach-Object { $_.id })
    $effectiveModel = if ($Model -in $ids) {
        $Model
    } elseif ("mimo/$Model" -in $ids) {
        # Discovery advertises the native Xiaomi route, while the unprefixed
        # name uses the working Codex-compatible provider route.
        $Model
    } elseif ("deepseek/$Model" -in $ids) {
        "deepseek/$Model"
    } elseif ("ds/$Model" -in $ids) {
        "ds/$Model"
    } else {
        throw "OmniRoute model or combo '$Model' was not found in /v1/models. Configure the model before launching."
    }
    Write-Host "[ungate] OmniRoute model or combo '$Model' available." -ForegroundColor Green

    $body = [ordered]@{
        model = $effectiveModel
        input = 'Reply with exactly OK.'
        max_output_tokens = 512
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
        throw "OmniRoute /v1/responses returned an unexpected response for '$Model'."
    }

    Write-Host "[ungate] Live OmniRoute /v1/responses preflight passed for '$Model'." -ForegroundColor Green
}

Export-ModuleMember -Function @(
    'Ensure-CliProxyBridge',
    'Ensure-CodexModelShellRouter',
    'Resolve-ModelApiKey',
    'Invoke-DesktopOmniRoutePreflight',
    'Invoke-UngatePreflight',
    'Invoke-CliProxyPreflight'
)
