BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Logging.psm1') -Force
}

Describe 'Structured tool diagnostics' {
    InModuleScope Logging {
        It 'does not count words in successful source output as failures' {
            Test-CodexToolFailure ([pscustomobject]@{ exit_code = 0; output = 'throw new Error("exception fatal error")' }) | Should -BeFalse
            Test-CodexToolFailure "Exit code: 0`nOutput:`nError executing tool: example source" | Should -BeFalse
            Test-CodexToolFailure 'error exception fatal traceback command not found' | Should -BeFalse
            Test-CodexToolFailure ([pscustomobject]@{ exit_code = '0'; output = 'error' }) | Should -BeFalse
        }
        It 'detects real nested failures and service envelopes' {
            Test-CodexToolFailure 'Script failed' | Should -BeTrue
            Test-CodexToolFailure "Script completed`nWall time: 0.5 seconds`nOutput:`n{`"result`":{`"isError`":true}}" | Should -BeTrue
            Test-CodexToolFailure ([pscustomobject]@{ content = @([pscustomobject]@{ text = '{"result":{"exit_code":2}}' }) }) | Should -BeTrue
            Test-CodexToolFailure "---RESULT 0---`nExit code: 0`nerror`n---RESULT 1---`nExit code: 1`nfailed" | Should -BeTrue
        }
        It 'does not classify a successful router diagnostic by its error_category field name' {
            Test-CodexRouterFailure '[codex-model-shell-router] POST /v1/responses -> 200 (5ms) {"status":200,"error_category":null}' | Should -BeFalse
            Test-CodexRouterFailure '[codex-model-shell-router] POST /v1/responses -> 503 (5ms) {"status":503,"error_category":"chat_admission_busy"}' | Should -BeTrue
            Test-CodexRouterFailure '[codex-model-shell-router] POST /v1/responses -> 200 (5ms) {"status":200,"error_category":"upstream_protocol_error"}' | Should -BeTrue
            Test-CodexRouterFailure '[codex-model-shell-router] [mimo-responses-adapter] normalized exec input model=mimo tool=exec input_bytes=4' | Should -BeFalse
        }
    }
    It 'labels only failed results and includes the session identifier' {
        Mock Write-Host {} -ModuleName Logging
        $line = @{ type = 'response_item'; payload = @{ type = 'function_call_output'; output = 'error exception' } } | ConvertTo-Json -Depth 5 -Compress
        Format-CodexSessionEvent -Line $line -LogLevel Errors -SessionId 'chat-a'
        Should -Invoke Write-Host -ModuleName Logging -Times 0
        $line = @{ type = 'response_item'; payload = @{ type = 'function_call_output'; output = 'Script failed' } } | ConvertTo-Json -Depth 5 -Compress
        Format-CodexSessionEvent -Line $line -LogLevel Errors -SessionId 'chat-a'
        Should -Invoke Write-Host -ModuleName Logging -ParameterFilter { $Object -like '*TOOL ERROR*chat-a*' } -Times 1
    }
}

Describe 'Independent session append cursors' {
    InModuleScope Logging {
        It 'reads each of four sessions once across repeated switches' {
            $files = 1..4 | ForEach-Object {
                $path = Join-Path $TestDrive "session-$_.jsonl"
                [IO.File]::WriteAllText($path, "old`n")
                Get-Item -LiteralPath $path
            }
            $cursors = @{}
            foreach ($file in $files) { $cursors[$file.FullName] = New-CodexSessionCursor $file -FromEnd }
            foreach ($round in 1..3) {
                foreach ($file in $files) {
                    [IO.File]::AppendAllText($file.FullName, "new-$round`n")
                    @(Read-CodexSessionAppend $file.FullName $cursors[$file.FullName]) | Should -Be @("new-$round")
                }
                foreach ($file in $files) { @(Read-CodexSessionAppend $file.FullName $cursors[$file.FullName]).Count | Should -Be 0 }
            }
        }
        It 'keeps a partial UTF-8 line until newline and recovers after truncation' {
            $path = Join-Path $TestDrive 'partial.jsonl'
            [IO.File]::WriteAllBytes($path, [byte[]]@())
            $cursor = New-CodexSessionCursor (Get-Item -LiteralPath $path)
            $bytes = [Text.Encoding]::UTF8.GetBytes("привет`n")
            [IO.File]::WriteAllBytes($path, $bytes[0..2])
            @(Read-CodexSessionAppend $path $cursor).Count | Should -Be 0
            $stream = [IO.File]::OpenWrite($path)
            try { $stream.Seek(0, 'End') | Out-Null; $stream.Write($bytes, 3, $bytes.Length - 3) } finally { $stream.Dispose() }
            @(Read-CodexSessionAppend $path $cursor) | Should -Be @('привет')
            @(Read-CodexSessionAppend $path $cursor).Count | Should -Be 0
            [IO.File]::WriteAllText($path, "x`n")
            @(Read-CodexSessionAppend $path $cursor) | Should -Be @('x')
        }
    }
}
