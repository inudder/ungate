BeforeAll {
    . (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')
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
