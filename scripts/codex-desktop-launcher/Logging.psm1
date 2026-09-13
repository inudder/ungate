#requires -Version 7.4
# Logging: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1') -DisableNameChecking -ErrorAction Stop

function Read-UngateLogSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )
    $ErrorActionPreference = 'Stop'

    $defaultSettings = [pscustomobject]@{
        LogLevel = 'Standard'
    }

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $defaultSettings
    }

    try {
        $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $defaultSettings
        }
        $parsed = $raw | ConvertFrom-Json
        $validLevels = @('Full', 'Standard', 'Compact', 'Minimal', 'Off')
        $level = if ($parsed.LogLevel -and $validLevels -contains [string]$parsed.LogLevel) {
            [string]$parsed.LogLevel
        } else {
            'Standard'
        }
        return [pscustomobject]@{
            LogLevel = $level
        }
    }
    catch {
        return $defaultSettings
    }
}

function Write-UngateLogSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off')]
        [string]$LogLevel
    )
    $ErrorActionPreference = 'Stop'

    $parent = [System.IO.Path]::GetDirectoryName($SettingsPath)
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    $settings = [pscustomobject]@{
        LogLevel = $LogLevel
    }
    $json = $settings | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($SettingsPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

function Invoke-UngateLoggingMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )
    $ErrorActionPreference = 'Stop'

    $current = (Read-UngateLogSettings -SettingsPath $SettingsPath).LogLevel

    while ($true) {
        Write-Host ''
        Write-Host '--- Live Terminal Log Level ---' -ForegroundColor Cyan
        Write-Host "Current level: $current" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  1) Full      - All events, reasoning, full tool output (no truncation), router logs'
        Write-Host '  2) Standard  - Default: reasoning, tool calls/output (truncated to 800 chars), agent text, router logs'
        Write-Host '  3) Compact   - Hide reasoning [THINK], short tool output (400 chars), agent text, router logs'
        Write-Host '  4) Minimal   - Clean summary: user, single-line tool calls, agent text only (no think, no output, no router)'
        Write-Host '  5) Off       - Disable terminal log stream completely (detach immediately to prompt)'
        Write-Host '  B) Back to main menu'
        Write-Host ''

        $choice = Read-Host 'Select log level [1-5 or B] (default: keep current)'
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $current
        }

        $chosen = switch ($choice.Trim()) {
            '1' { 'Full' }
            '2' { 'Standard' }
            '3' { 'Compact' }
            '4' { 'Minimal' }
            '5' { 'Off' }
            default { $null }
        }

        if ($chosen) {
            Write-UngateLogSettings -SettingsPath $SettingsPath -LogLevel $chosen
            Write-Host "  [x] Log level updated to: $chosen" -ForegroundColor Green
            return $chosen
        }

        Write-Host 'Invalid choice. Enter 1-5 or B.' -ForegroundColor Yellow
    }
}

function Format-CodexSessionEvent {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line,
        [Parameter(Mandatory = $false)]
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off')]
        [string]$LogLevel = 'Standard'
    )
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Line) -or $LogLevel -eq 'Off') {
        return
    }

    try {
        $json = $Line | ConvertFrom-Json -ErrorAction Stop
        $p = $json.payload
        if (-not $p) { return }

        $objType = [string]$json.type
        $pType = [string]$p.type

        # 1. Agent Reasoning [THINK]
        if ($pType -eq 'agent_reasoning' -and $p.text) {
            if ($LogLevel -in @('Compact', 'Minimal')) {
                return
            }
            $text = $p.text.Trim()
            if ($text) {
                Write-Host "`n[THINK] " -ForegroundColor Magenta -NoNewline
                Write-Host $text -ForegroundColor DarkGray
            }
            return
        }

        # 2. User Message
        if ($pType -eq 'user_message' -and $p.message) {
            Write-Host "`n=== USER ===" -ForegroundColor Cyan
            Write-Host $p.message.Trim() -ForegroundColor White
            return
        }

        # 3. Tool Call
        if ($objType -eq 'response_item' -and ($pType -eq 'custom_tool_call' -or $pType -eq 'function_call')) {
            $toolName = if ($p.name) { $p.name } else { $p.call.name }
            $toolInput = if ($p.input) { $p.input } else { $p.arguments }

            if ($LogLevel -eq 'Minimal') {
                $summary = ''
                if ($toolInput) {
                    try {
                        $parsedInput = $toolInput | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsedInput.command) { $summary = " $($parsedInput.command)" }
                        elseif ($parsedInput.path) { $summary = " $($parsedInput.path)" }
                        elseif ($parsedInput.file_path) { $summary = " $($parsedInput.file_path)" }
                        elseif ($parsedInput.pattern) { $summary = " $($parsedInput.pattern)" }
                    } catch { }
                    if (-not $summary) {
                        $firstLine = ($toolInput.Trim() -split "`r?`n")[0]
                        if ($firstLine.Length -gt 70) { $firstLine = $firstLine.Substring(0, 70) + '...' }
                        $summary = " $firstLine"
                    }
                }
                Write-Host "--> [TOOL: $toolName]$summary" -ForegroundColor Yellow
                return
            }

            Write-Host "`n--> [TOOL CALL: $toolName]" -ForegroundColor Yellow
            if ($toolInput) {
                Write-Host $toolInput.Trim() -ForegroundColor DarkYellow
            }
            return
        }

        # 4. Tool Output
        if ($objType -eq 'response_item' -and ($pType -eq 'custom_tool_call_output' -or $pType -eq 'function_call_output')) {
            if ($LogLevel -eq 'Minimal') {
                return
            }

            $outLines = @()
            if ($p.output) {
                if ($p.output -is [array]) {
                    $outLines = $p.output | ForEach-Object { if ($_.text) { $_.text } else { [string]$_.content } }
                } else {
                    $outLines = @([string]$p.output)
                }
            }
            $outText = ($outLines -join "`n").Trim()
            if ($outText) {
                $limit = switch ($LogLevel) {
                    'Full' { 0 }
                    'Compact' { 400 }
                    default { 800 }
                }
                $preview = if ($limit -gt 0 -and $outText.Length -gt $limit) {
                    $outText.Substring(0, $limit) + "... [truncated: $($outText.Length) chars total]"
                } else {
                    $outText
                }
                Write-Host '<-- [TOOL OUTPUT]' -ForegroundColor Blue
                Write-Host $preview -ForegroundColor Gray
            }
            return
        }

        # 5. Agent Message
        if ($pType -eq 'agent_message' -and $p.message) {
            Write-Host "`n=== AGENT ===" -ForegroundColor Green
            Write-Host $p.message.Trim() -ForegroundColor White
            return
        }

        # 6. Turn Aborted
        if ($pType -eq 'turn_aborted') {
            Write-Host "`n[TURN ABORTED]" -ForegroundColor Red
            return
        }
    }
    catch {
        # Malformed or non-JSON line ignored
    }
}

function Watch-CodexActivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CustomCodexHome,
        [Parameter(Mandatory = $true)]
        [string]$DesktopExecutablePath,
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off')]
        [string]$LogLevel = 'Standard',
        [string]$LogSettingsPath = (Join-Path $CustomCodexHome 'ungate-log-settings.json'),
        [int]$PollIntervalMs = 250
    )
    $ErrorActionPreference = 'Stop'

    if ($LogLevel -eq 'Off') {
        Write-Host '[ungate] Live terminal logging is Off.' -ForegroundColor DarkGray
        return
    }

    Write-Host "`n[ungate] Streaming live Codex Beta activity in terminal (Level: $LogLevel | Keys: 1-5 switch level, Ctrl+C to detach)..." -ForegroundColor Cyan

    $sessionsRoot = Join-Path $CustomCodexHome 'sessions'
    $routerLogPath = Join-Path $CustomCodexHome 'logs\codex-model-shell-router.out.log'

    $sessionFs = $null
    $sessionSr = $null
    $currentSessionPath = $null

    $routerFs = $null
    $routerSr = $null

    try {
        if (Test-Path -LiteralPath $routerLogPath -PathType Leaf) {
            try {
                $routerFs = [System.IO.FileStream]::new(
                    $routerLogPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite
                )
                $routerFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                $routerSr = [System.IO.StreamReader]::new($routerFs, [System.Text.Encoding]::UTF8)
            }
            catch { }
        }

        $startupGraceDeadline = [System.DateTime]::UtcNow.AddSeconds(15)
        $lastHealthCheck = [System.Diagnostics.Stopwatch]::StartNew()
        $lastSessionCheck = [System.Diagnostics.Stopwatch]::StartNew()

        while ($true) {
            # 0. Live keyboard shortcuts to change log level
            if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                $newLevel = switch ($keyInfo.KeyChar) {
                    '1' { 'Full' }
                    '2' { 'Standard' }
                    '3' { 'Compact' }
                    '4' { 'Minimal' }
                    '5' { 'Off' }
                    default { $null }
                }
                if ($newLevel) {
                    $LogLevel = $newLevel
                    Write-Host "`n[ungate] Switched log level to: $LogLevel (Keys: 1=Full, 2=Std, 3=Compact, 4=Minimal, 5=Off)" -ForegroundColor Yellow
                    try {
                        Write-UngateLogSettings -SettingsPath $LogSettingsPath -LogLevel $LogLevel
                    } catch { }
                    if ($LogLevel -eq 'Off') {
                        Write-Host '[ungate] Logging turned off. Detaching...' -ForegroundColor DarkGray
                        break
                    }
                }
            }

            # 1. Read router lines (skipped in Minimal mode)
            if ($LogLevel -ne 'Minimal') {
                if ($routerSr) {
                    while (-not $routerSr.EndOfStream) {
                        $rLine = $routerSr.ReadLine()
                        if (-not [string]::IsNullOrWhiteSpace($rLine)) {
                            Write-Host "[router] $rLine" -ForegroundColor DarkCyan
                        }
                    }
                }
                elseif (Test-Path -LiteralPath $routerLogPath -PathType Leaf) {
                    try {
                        $routerFs = [System.IO.FileStream]::new(
                            $routerLogPath,
                            [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::Read,
                            [System.IO.FileShare]::ReadWrite
                        )
                        $routerFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                        $routerSr = [System.IO.StreamReader]::new($routerFs, [System.Text.Encoding]::UTF8)
                    }
                    catch { }
                }
            }

            # 2. Check for active session or switch to newer
            if ($null -eq $sessionSr -or $lastSessionCheck.ElapsedMilliseconds -gt 1500) {
                $lastSessionCheck.Restart()
                if (Test-Path -LiteralPath $sessionsRoot) {
                    $newest = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1

                    if ($newest -and $newest.FullName -ne $currentSessionPath) {
                        if ($sessionSr) {
                            $sessionSr.Dispose()
                            $sessionFs.Dispose()
                            $sessionSr = $null
                            $sessionFs = $null
                        }

                        $isFirstAttach = ($null -eq $currentSessionPath)
                        $currentSessionPath = $newest.FullName
                        try {
                            $sessionFs = [System.IO.FileStream]::new(
                                $currentSessionPath,
                                [System.IO.FileMode]::Open,
                                [System.IO.FileAccess]::Read,
                                [System.IO.FileShare]::ReadWrite
                            )
                            if ($isFirstAttach) {
                                $sessionFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                                Write-Host "[ungate] Attached to active session: $($newest.Name)" -ForegroundColor DarkGray
                            }
                            else {
                                Write-Host "`n[ungate] Switched to new session: $($newest.Name)" -ForegroundColor Cyan
                            }
                            $sessionSr = [System.IO.StreamReader]::new($sessionFs, [System.Text.Encoding]::UTF8)
                        }
                        catch { }
                    }
                }
            }

            # 3. Read session lines
            if ($sessionSr) {
                while (-not $sessionSr.EndOfStream) {
                    $sLine = $sessionSr.ReadLine()
                    if (-not [string]::IsNullOrWhiteSpace($sLine)) {
                        Format-CodexSessionEvent -Line $sLine -LogLevel $LogLevel
                    }
                }
            }

            # 4. Periodically verify Codex Beta process is still alive and maintain AboveNormal priority
            if ($lastHealthCheck.ElapsedMilliseconds -gt 3000) {
                $lastHealthCheck.Restart()
                Optimize-CodexBetaPriority -ExecutablePath $DesktopExecutablePath
                if ([System.DateTime]::UtcNow -gt $startupGraceDeadline) {
                    $running = @(Get-CodexBetaProcesses -ExecutablePath $DesktopExecutablePath).Count -gt 0
                    if (-not $running) {
                        Write-Host "`n[ungate] Codex Beta process exited. Log streaming finished." -ForegroundColor Yellow
                        break
                    }
                }
            }

            Start-Sleep -Milliseconds $PollIntervalMs
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`n[ungate] Log stream detached." -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "[ungate] Log stream stopped: $_"
    }
    finally {
        if ($sessionSr) { $sessionSr.Dispose() }
        if ($sessionFs) { $sessionFs.Dispose() }
        if ($routerSr) { $routerSr.Dispose() }
        if ($routerFs) { $routerFs.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'Watch-CodexActivity',
    'Read-UngateLogSettings',
    'Write-UngateLogSettings',
    'Invoke-UngateLoggingMenu',
    'Format-CodexSessionEvent'
)
