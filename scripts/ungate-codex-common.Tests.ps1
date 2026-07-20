BeforeAll {
    . (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')
}

Describe 'Test-CliProxyResponsesInference' {
    It 'sends a minimal non-streaming inference request and accepts OK' {
        Mock Invoke-WebRequest {
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
            $Body -match '"store":false'
        }
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
