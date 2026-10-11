#requires -Version 7.4
param([string]$BetaHome = (Join-Path $HOME '.codex-ungate'))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher\LauncherLock.psm1') -DisableNameChecking
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$ownerSid = $identity.User.Value
$launcherHome = Normalize-UngateLauncherHome $BetaHome
$pipeName = Get-UngateLauncherPipeName -OwnerSid $ownerSid -BetaHome $launcherHome
$agentPath = Join-Path $PSScriptRoot 'codex-launcher-control-agent.ps1'
$pidFile = Join-Path $launcherHome 'launcher-control\agent.json'

function Read-PipeExact {
    param($Stream, [byte[]]$Buffer)
    $offset = 0
    while ($offset -lt $Buffer.Length) {
        $task = $Stream.ReadAsync($Buffer, $offset, $Buffer.Length - $offset)
        if (-not $task.Wait(5000)) { throw 'Launcher control agent did not respond.' }
        if ($task.Result -le 0) { throw 'Launcher control agent closed the pipe before responding.' }
        $offset += $task.Result
    }
}

function Send-LauncherPing {
    $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $client.Connect(1500)
        $payload = @{ version = 1; requestId = ([guid]::NewGuid().ToString('n')); action = 'agent.ping'; payload = @{} } | ConvertTo-Json -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $client.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
        $client.Write($bytes, 0, $bytes.Length)
        $client.Flush()
        $lengthBytes = New-Object byte[] 4
        Read-PipeExact $client $lengthBytes
        $length = [BitConverter]::ToInt32($lengthBytes, 0)
        if ($length -lt 2 -or $length -gt 1MB) { throw 'Invalid launcher control response.' }
        $body = New-Object byte[] $length
        Read-PipeExact $client $body
        return [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
    } finally {
        $client.Dispose()
    }
}

$running = $false
if (Test-Path -LiteralPath $pidFile) {
    $record = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
    if ($record.pid -and (Get-Process -Id $record.pid -ErrorAction SilentlyContinue)) {
        try { $pong = Send-LauncherPing; $running = [bool]$pong.body.ready } catch { $running = $false }
    }
}
if (-not $running) {
    $process = Start-Process -FilePath (Get-Command pwsh).Source -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-File', $agentPath, '-BetaHome', $launcherHome, '-OwnerSid', $ownerSid)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        try { $pong = Send-LauncherPing; if ($pong.body.ready) { $running = $true; break } } catch { }
    } while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if (-not $running) {
        if ($process.HasExited) {
            Write-Error "Launcher control agent exited during startup (exit code $($process.ExitCode))."
        }
        Write-Error 'Launcher control agent did not become ready.'
        exit 1
    }
    Write-Output ('ready pid=' + $process.Id)
} else {
    Write-Output 'ready reused'
}
exit 0
