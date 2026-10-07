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
        $validLevels = @('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors')
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
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors')]
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
        Write-Host '  6) Errors    - Errors only: turn aborted, failed tool output, router errors (4xx/5xx)'
        Write-Host '  B) Back to main menu'
        Write-Host ''

        $choice = Read-Host 'Select log level [1-6 or B] (default: keep current)'
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $current
        }

        $chosen = switch ($choice.Trim()) {
            '1' { 'Full' }
            '2' { 'Standard' }
            '3' { 'Compact' }
            '4' { 'Minimal' }
            '5' { 'Off' }
            '6' { 'Errors' }
            default { $null }
        }

        if ($chosen) {
            Write-UngateLogSettings -SettingsPath $SettingsPath -LogLevel $chosen
            Write-Host "  [x] Log level updated to: $chosen" -ForegroundColor Green
            return $chosen
        }

        Write-Host 'Invalid choice. Enter 1-6 or B.' -ForegroundColor Yellow
    }
}

function Test-CodexToolFailure {
    param([AllowNull()][object]$Result, [int]$Depth = 0)
    if ($null -eq $Result -or $Depth -gt 8) { return $false }
    if ($Result -is [array]) {
        foreach ($item in $Result) {
            if (Test-CodexToolFailure -Result $item -Depth ($Depth + 1)) { return $true }
        }
        return $false
    }
    if ($Result -is [string]) {
        $value = $Result.Trim()
        if ($value -match '^Script failed(?:\r?\n|$)|^Script error:') { return $true }
        # A shell result's header is authoritative; its stdout may be source code.
        if ($value -match '^Exit code:\s*(-?\d+)\b') { return [int]$Matches[1] -ne 0 }
        if ($value -match '(?s)^Script completed\r?\nWall time[^\r\n]*\r?\nOutput:\r?\n(.*)$') {
            return Test-CodexToolFailure -Result $Matches[1] -Depth ($Depth + 1)
        }
        if ($value -match '^---RESULT \d+---') {
            foreach ($part in ($value -split '(?m)^---RESULT \d+---\s*$')) {
                if (Test-CodexToolFailure -Result $part -Depth ($Depth + 1)) { return $true }
            }
            return $false
        }
        if ($value -match '^Error executing [\w.]+:') { return $true }
        if ($value.StartsWith('{') -or $value.StartsWith('[')) {
            try {
                $parsed = ConvertFrom-Json -InputObject $value -ErrorAction Stop
                return Test-CodexToolFailure -Result $parsed -Depth ($Depth + 1)
            } catch { }
        }
        return $false
    }
    foreach ($flag in @('is_error', 'isError')) {
        $property = $Result.PSObject.Properties[$flag]
        if ($null -ne $property -and $property.Value -eq $true) { return $true }
    }
    foreach ($field in @('exit_code', 'exitCode')) {
        $property = $Result.PSObject.Properties[$field]
        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -match '^-?\d+$') {
            return [long]$property.Value -ne 0
        }
    }
    $status = $Result.PSObject.Properties['status']
    if ($null -ne $status -and $status.Value -in @('rejected', 'failed', 'error')) { return $true }
    foreach ($field in @('output', 'value', 'result', 'content', 'text')) {
        $property = $Result.PSObject.Properties[$field]
        if ($null -ne $property -and (Test-CodexToolFailure -Result $property.Value -Depth ($Depth + 1))) { return $true }
    }
    return $false
}

function Test-CodexRouterFailure {
    param([Parameter(Mandatory)][string]$Line)
    if ($Line -match '->\s*[45]\d\d\b') { return $true }
    $jsonOffset = $Line.IndexOf(' {')
    if ($jsonOffset -ge 0) {
        try {
            $details = ConvertFrom-Json -InputObject $Line.Substring($jsonOffset + 1) -ErrorAction Stop
            if ($details.status -ge 400 -or $details.error_category) { return $true }
        } catch { }
    }
    if ($Line -match '^\[codex-model-shell-router\] \[mimo-responses-adapter\] ') {
        return $Line -notmatch '\] (converted textual tool call|normalized exec input) '
    }
    return $Line -match '^\[codex-model-shell-router\] (upstream request error:|pipeline error:)'
}

function New-CodexSessionCursor {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File, [switch]$FromEnd)
    $sessionId = if ($File.BaseName.Length -ge 36) { $File.BaseName.Substring($File.BaseName.Length - 36) } else { $File.BaseName }
    return [pscustomobject]@{
        Position = if ($FromEnd) { $File.Length } else { 0L }
        CreationTimeUtc = $File.CreationTimeUtc
        Pending = [byte[]]@()
        SessionId = $sessionId
        Active = $false
    }
}

function Read-CodexSessionAppend {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][psobject]$Cursor)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -lt $Cursor.Position -or $file.CreationTimeUtc -ne $Cursor.CreationTimeUtc) {
        $Cursor.Position = 0L
        $Cursor.Pending = [byte[]]@()
        $Cursor.CreationTimeUtc = $file.CreationTimeUtc
    }
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    $buffer = [System.IO.MemoryStream]::new()
    try {
        $stream.Seek($Cursor.Position, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer.Write($Cursor.Pending, 0, $Cursor.Pending.Length)
        $stream.CopyTo($buffer)
        $Cursor.Position = $stream.Position
        $bytes = $buffer.ToArray()
        $start = 0
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            if ($bytes[$index] -eq 10) {
                [System.Text.Encoding]::UTF8.GetString($bytes, $start, $index - $start).TrimEnd("`r")
                $start = $index + 1
            }
        }
        $Cursor.Pending = [byte[]]@()
        if ($start -lt $bytes.Length) { $Cursor.Pending = [byte[]]$bytes[$start..($bytes.Length - 1)] }
    } finally {
        $buffer.Dispose()
        $stream.Dispose()
    }
}

function Format-CodexSessionEvent {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line,
        [Parameter(Mandatory = $false)]
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors')]
        [string]$LogLevel = 'Standard',
        [string]$SessionId
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
            if ($LogLevel -in @('Compact', 'Minimal', 'Errors')) {
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
            if ($LogLevel -eq 'Errors') {
                return
            }
            Write-Host "`n=== USER ===" -ForegroundColor Cyan
            Write-Host $p.message.Trim() -ForegroundColor White
            return
        }

        # 3. Tool Call
        if ($objType -eq 'response_item' -and ($pType -eq 'custom_tool_call' -or $pType -eq 'function_call')) {
            if ($LogLevel -eq 'Errors') {
                return
            }

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

            $isToolError = Test-CodexToolFailure -Result $p

            if ($LogLevel -eq 'Errors' -and -not $isToolError) {
                return
            }

            if ($outText) {
                $limit = switch ($LogLevel) {
                    'Full' { 0 }
                    'Compact' { 400 }
                    'Errors' { 1200 }
                    default { 800 }
                }
                $preview = if ($limit -gt 0 -and $outText.Length -gt $limit) {
                    $outText.Substring(0, $limit) + "... [truncated: $($outText.Length) chars total]"
                } else {
                    $outText
                }
                if ($isToolError) {
                    Write-Host "<-- [TOOL ERROR] [session: $SessionId]" -ForegroundColor Red
                    Write-Host $preview -ForegroundColor DarkYellow
                } else {
                    Write-Host "<-- [TOOL OUTPUT] [session: $SessionId]" -ForegroundColor Blue
                    Write-Host $preview -ForegroundColor Gray
                }
            }
            return
        }

        # 5. Agent Message
        if ($pType -eq 'agent_message' -and $p.message) {
            if ($LogLevel -eq 'Errors') {
                return
            }
            Write-Host "`n=== AGENT ===" -ForegroundColor Green
            Write-Host $p.message.Trim() -ForegroundColor White
            return
        }

        # 6. Turn Aborted
        if ($pType -eq 'turn_aborted') {
            Write-Host "`n[TURN ABORTED] [session: $SessionId]" -ForegroundColor Red
            return
        }

        # 7. Explicit Error Events
        if ($pType -match '(?i)error|fail|exception' -or $objType -match '(?i)error|fail' -or $p.error) {
            $errText = if ($p.message) { $p.message } elseif ($p.error) { $p.error } else { $Line }
            Write-Host "`n[ERROR: $pType] [session: $SessionId] $errText" -ForegroundColor Red
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
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors')]
        [string]$LogLevel = 'Standard',
        [string]$LogSettingsPath = (Join-Path $CustomCodexHome 'ungate-log-settings.json'),
        [int]$PollIntervalMs = 250
    )
    $ErrorActionPreference = 'Stop'

    if ($LogLevel -eq 'Off') {
        Write-Host '[ungate] Live terminal logging is Off.' -ForegroundColor DarkGray
        return
    }

    Write-Host "`n[ungate] Streaming live Codex Beta activity in terminal (Level: $LogLevel | Keys: 1-6 switch level, Ctrl+C to detach)..." -ForegroundColor Cyan

    $sessionsRoot = Join-Path $CustomCodexHome 'sessions'
    $routerLogPath = Join-Path $CustomCodexHome 'logs\codex-model-shell-router.out.log'

    $sessionStates = @{}
    $watchStartedUtc = [System.DateTime]::UtcNow
    if (Test-Path -LiteralPath $sessionsRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl')) {
            $sessionStates[$file.FullName] = New-CodexSessionCursor -File $file -FromEnd
        }
    }
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
                    '6' { 'Errors' }
                    default { $null }
                }
                if ($newLevel) {
                    $LogLevel = $newLevel
                    Write-Host "`n[ungate] Switched log level to: $LogLevel (Keys: 1=Full, 2=Std, 3=Compact, 4=Minimal, 5=Off, 6=Errors)" -ForegroundColor Yellow
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
                            if ($LogLevel -eq 'Errors') {
                                if (Test-CodexRouterFailure -Line $rLine) {
                                    Write-Host "[router error] $rLine" -ForegroundColor Red
                                }
                            } else {
                                Write-Host "[router] $rLine" -ForegroundColor DarkCyan
                            }
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
            if ($null -eq $currentSessionPath -or $lastSessionCheck.ElapsedMilliseconds -gt 1500) {
                $lastSessionCheck.Restart()
                if (Test-Path -LiteralPath $sessionsRoot) {
                    $sessionFiles = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
                    $newest = $sessionFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    foreach ($file in $sessionFiles) {
                        if (-not $sessionStates.ContainsKey($file.FullName)) {
                            $sessionStates[$file.FullName] = New-CodexSessionCursor -File $file
                        }
                        if ($file.LastWriteTimeUtc -ge $watchStartedUtc) { $sessionStates[$file.FullName].Active = $true }
                    }

                    if ($newest -and $newest.FullName -ne $currentSessionPath) {
                        $isFirstAttach = ($null -eq $currentSessionPath)
                        $currentSessionPath = $newest.FullName
                        $sessionStates[$currentSessionPath].Active = $true
                        if ($isFirstAttach) { Write-Host "[ungate] Attached to active session: $($newest.Name)" -ForegroundColor DarkGray }
                        else { Write-Host "`n[ungate] Switched to new session: $($newest.Name)" -ForegroundColor Cyan }
                    }
                }
            }

            # 3. Read session lines
            foreach ($sessionPath in @($sessionStates.Keys)) {
                $cursor = $sessionStates[$sessionPath]
                if (-not $cursor.Active -or -not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { continue }
                foreach ($sLine in @(Read-CodexSessionAppend -Path $sessionPath -Cursor $cursor)) {
                    if (-not [string]::IsNullOrWhiteSpace($sLine)) {
                        Format-CodexSessionEvent -Line $sLine -LogLevel $LogLevel -SessionId $cursor.SessionId
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
