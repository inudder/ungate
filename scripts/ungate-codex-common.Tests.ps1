BeforeAll {
    . (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')
}

Describe 'Resolve-UngateApiKey' {
    BeforeEach {
        $script:previousUngateEnvironment = @{}
        foreach ($name in @('UNGATE_API_KEY', 'UNGATE_DB_PATH', 'UNGATE_BS3_PATH')) {
            $script:previousUngateEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
        }
        $script:testUngateDb = Join-Path $TestDrive "$([guid]::NewGuid()).db"
        Mock Join-Path { $script:testUngateDb } -ParameterFilter { $ChildPath -eq '.ungate\data.db' }
    }

    AfterEach {
        foreach ($name in $script:previousUngateEnvironment.Keys) {
            if ($null -eq $script:previousUngateEnvironment[$name]) {
                Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $script:previousUngateEnvironment[$name])
            }
        }
    }

    It 'prefers explicit and environment keys without requiring a database or Node' {
        Mock Get-Command { throw 'Node lookup should not run' }
        $env:UNGATE_API_KEY = 'environment-key'
        Resolve-UngateApiKey -ApiKey 'explicit-key' -RepoRoot $TestDrive | Should -BeExactly 'explicit-key'
        Resolve-UngateApiKey -RepoRoot $TestDrive | Should -BeExactly 'environment-key'
    }

    It 'reads a real database without loading an incompatible native addon' {
        $env:UNGATE_DB_PATH = $script:testUngateDb
        $fixture = @'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.env.UNGATE_DB_PATH);
db.exec('CREATE TABLE app_settings (id INTEGER PRIMARY KEY, api_key TEXT)');
db.prepare('INSERT INTO app_settings VALUES (?, ?)').run(1, 'fixture-key');
db.close();
'@
        $fixture | & node @('--input-type=commonjs', '-')
        $LASTEXITCODE | Should -Be 0
        $addonPath = Join-Path $TestDrive 'apps/api/node_modules/better-sqlite3'
        $null = New-Item -ItemType Directory -Path $addonPath -Force
        Set-Content -LiteralPath (Join-Path $addonPath 'index.js') -Value 'throw new Error("NODE_MODULE_VERSION mismatch");'
        $env:UNGATE_DB_PATH = 'previous-db-path'
        $env:UNGATE_BS3_PATH = 'previous-addon-path'
        $beforeHash = (Get-FileHash -LiteralPath $script:testUngateDb).Hash

        Resolve-UngateApiKey -RepoRoot $TestDrive | Should -BeExactly 'fixture-key'

        (Get-FileHash -LiteralPath $script:testUngateDb).Hash | Should -BeExactly $beforeHash
        $env:UNGATE_DB_PATH | Should -BeExactly 'previous-db-path'
        $env:UNGATE_BS3_PATH | Should -BeExactly 'previous-addon-path'
    }

    It 'reports database errors and restores absent environment variables' {
        Set-Content -LiteralPath $script:testUngateDb -Value 'not a SQLite database'

        { Resolve-UngateApiKey -RepoRoot $TestDrive } | Should -Throw '*Could not read api_key*'

        Test-Path Env:\UNGATE_DB_PATH | Should -BeFalse
        Test-Path Env:\UNGATE_BS3_PATH | Should -BeFalse
    }

    It 'does not create a missing database' {
        { Resolve-UngateApiKey -RepoRoot $TestDrive } | Should -Throw '*Ungate DB not found*'
        Test-Path -LiteralPath $script:testUngateDb | Should -BeFalse
    }
}

Describe 'Resolve-OmniRouteApiKey' {
    BeforeEach {
        $script:previousOmniRouteApiKey = $env:OMNIROUTE_API_KEY
        $script:previousOmniRouteCodexApiKey = $env:OMNIROUTE_CODEX_API_KEY
        Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\OMNIROUTE_CODEX_API_KEY -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:previousOmniRouteApiKey) {
            Remove-Item Env:\OMNIROUTE_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:OMNIROUTE_API_KEY = $script:previousOmniRouteApiKey
        }
        if ($null -eq $script:previousOmniRouteCodexApiKey) {
            Remove-Item Env:\OMNIROUTE_CODEX_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:OMNIROUTE_CODEX_API_KEY = $script:previousOmniRouteCodexApiKey
        }
    }

    It 'prefers an explicit key, then the Codex client key, then the legacy environment key' {
        $env:OMNIROUTE_API_KEY = 'master-key'
        $env:OMNIROUTE_CODEX_API_KEY = 'codex-client-key'

        Resolve-OmniRouteApiKey -ApiKey 'argument-key' | Should -BeExactly 'argument-key'
        Resolve-OmniRouteApiKey | Should -BeExactly 'codex-client-key'

        Remove-Item Env:\OMNIROUTE_CODEX_API_KEY
        Resolve-OmniRouteApiKey | Should -BeExactly 'master-key'
    }

    It 'fails clearly when no OmniRoute client key is configured' {
        { Resolve-OmniRouteApiKey } |
            Should -Throw '*set OMNIROUTE_CODEX_API_KEY*OMNIROUTE_API_KEY*'
    }
}

Describe 'Test-UngateResponsesBridge' {
    It 'uses the authenticated health endpoint without a request body' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 200
                Content = '{"status":"ok","wire_api":"responses"}'
            }
        }

        {
            Test-UngateResponsesBridge `
                -Key 'test-key' `
                -Model 'ungate-opus-4-8' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:47821/v1'
        } | Should -Not -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and
            $Uri -eq 'http://127.0.0.1:47821/v1/responses/health' -and
            $Headers.Authorization -eq 'Bearer test-key' -and
            $TimeoutSec -eq 5 -and
            $null -eq $Body
        }
    }

    It 'reports an authentication failure' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 403
                Content = '{"error":{"message":"Unauthorized: Invalid API key"}}'
            }
        }

        {
            Test-UngateResponsesBridge `
                -Key 'bad-key' `
                -Model 'ungate-opus-4-8' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:47821/v1'
        } | Should -Throw '*authentication failed with HTTP 403*'
    }

    It 'reports a stale service bundle when the health endpoint is missing' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 404
                Content = '{"error":"Not Found"}'
            }
        }

        {
            Test-UngateResponsesBridge `
                -Key 'test-key' `
                -Model 'ungate-opus-4-8' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:47821/v1'
        } | Should -Throw '*Rebuild the NSSM bundle and restart the ungate-api service*'
    }

    It 'rejects invalid JSON from the health endpoint' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 200
                Content = 'not-json'
            }
        }

        {
            Test-UngateResponsesBridge `
                -Key 'test-key' `
                -Model 'ungate-opus-4-8' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:47821/v1'
        } | Should -Throw '*returned invalid JSON*'
    }

    It 'rejects an unexpected health response contract' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 200
                Content = '{"status":"ok","wire_api":"chat"}'
            }
        }

        {
            Test-UngateResponsesBridge `
                -Key 'test-key' `
                -Model 'ungate-opus-4-8' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:47821/v1'
        } | Should -Throw '*unexpected health response*'
    }
}

Describe 'Test-CliProxyResponsesInference' {
    It 'sends a minimal non-streaming inference request and accepts OK' {
        Mock Invoke-WebRequest {
            if ($Body -match 'cliproxy_preflight') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '{"status":"completed","output":[{"type":"function_call","name":"bridge_preflight","namespace":"cliproxy_preflight","arguments":"{}"}]}'
                }
            }

            [pscustomobject]@{
                StatusCode = 200
                Content = '{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}'
            }
        }

        {
            Test-CliProxyResponsesInference `
                -Key 'test-key' `
                -Model 'grok-4.5' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:8318/v1'
        } | Should -Not -Throw

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and
            $Uri -eq 'http://127.0.0.1:8318/v1/responses' -and
            $TimeoutSec -eq 15 -and
            $Body -match '"model":"grok-4.5"' -and
            $Body -match '"max_output_tokens":16' -and
            $Body -match '"stream":false' -and
            $Body -match '"store":false' -and
            $Body -notmatch 'cliproxy_preflight'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and
            $Uri -eq 'http://127.0.0.1:8318/v1/responses' -and
            $Body -match 'cliproxy_preflight' -and
            $Body -match 'bridge_preflight' -and
            $Body -match '"tool_choice"'
        }
    }

    It 'rejects an invalid tool-call preflight response' {
        Mock Invoke-WebRequest {
            if ($Body -match 'cliproxy_preflight') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '{"status":"completed","output":[{"type":"function_call","name":"bridge_preflight","namespace":"cliproxy_preflight","arguments":"{\"incomplete\":"}]}'
                }
            }

            [pscustomobject]@{
                StatusCode = 200
                Content = '{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}'
            }
        }

        {
            Test-CliProxyResponsesInference `
                -Key 'test-key' `
                -Model 'grok-4.5' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:8318/v1'
        } | Should -Throw '*invalid function-call arguments*'
    }

    It 'explains when xAI authorization is unavailable' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 503
                Content = '{"error":{"message":"auth_unavailable: no auth available (providers=xai, model=grok-4.5)"}}'
            }
        }

        {
            Test-CliProxyResponsesInference `
                -Key 'test-key' `
                -Model 'grok-4.5' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:8318/v1'
        } | Should -Throw "*no available xAI authorization for model 'grok-4.5'*"
    }

    It 'rejects a successful response without the expected output' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 200
                Content = '{"status":"completed","output":[]}'
            }
        }

        {
            Test-CliProxyResponsesInference `
                -Key 'test-key' `
                -Model 'grok-4.5' `
                -ProxyOpenAiBaseUrl 'http://127.0.0.1:8318/v1'
        } | Should -Throw '*unexpected preflight output*'
    }
}

Describe 'Invoke-CliProxyPreflight' {
    BeforeEach {
        Mock Test-CliProxyResponsesInference
        Mock Write-Host
    }

    It 'uses live inference when the dynamic catalog omits the requested model' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                data = @([pscustomobject]@{ id = 'grok-4.5' })
            }
        }

        {
            Invoke-CliProxyPreflight `
                -Key 'test-key' `
                -Model 'grok-4.7' `
                -ProxyBaseUrl 'http://127.0.0.1:8318'
        } | Should -Not -Throw

        Should -Invoke Test-CliProxyResponsesInference -Times 1 -Exactly -ParameterFilter {
            $Key -eq 'test-key' -and
            $Model -eq 'grok-4.7' -and
            $ProxyOpenAiBaseUrl -eq 'http://127.0.0.1:8318/v1'
        }
        Should -Invoke Write-Host -ParameterFilter {
            $Object -like "*not advertised*" -and $ForegroundColor -eq 'Yellow'
        }
    }

    It 'uses live inference when catalog discovery is temporarily unavailable' {
        Mock Invoke-RestMethod { throw 'catalog offline' }

        {
            Invoke-CliProxyPreflight `
                -Key 'test-key' `
                -Model 'grok-4.7' `
                -ProxyBaseUrl 'http://127.0.0.1:8318'
        } | Should -Not -Throw

        Should -Invoke Test-CliProxyResponsesInference -Times 1 -Exactly
        Should -Invoke Write-Host -ParameterFilter {
            $Object -like "*Could not validate model 'grok-4.7'*" -and
            $ForegroundColor -eq 'Yellow'
        }
    }

    It 'reports a catalog match before running live inference' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                data = @([pscustomobject]@{ id = 'grok-4.7' })
            }
        }

        Invoke-CliProxyPreflight `
            -Key 'test-key' `
            -Model 'grok-4.7' `
            -ProxyBaseUrl 'http://127.0.0.1:8318'

        Should -Invoke Test-CliProxyResponsesInference -Times 1 -Exactly
        Should -Invoke Write-Host -ParameterFilter {
            $Object -eq "[ungate] Model 'grok-4.7' available." -and
            $ForegroundColor -eq 'Green'
        }
    }
}
