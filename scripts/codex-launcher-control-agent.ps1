#requires -Version 7.4
param(
    [Parameter(Mandatory = $true)][string]$BetaHome,
    [Parameter(Mandatory = $true)][string]$OwnerSid
)
$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot 'codex-desktop-launcher'
Import-Module (Join-Path $moduleRoot 'LauncherLock.psm1') -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Management.psm1') -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Context.psm1') -DisableNameChecking
Import-Module (Join-Path $moduleRoot 'Memories.psm1') -DisableNameChecking

if (-not ('UngatePipeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UngatePipeNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out int processId);
}
'@
}

$launcherHome = Normalize-UngateLauncherHome $BetaHome
$pipeName = Get-UngateLauncherPipeName -OwnerSid $OwnerSid -BetaHome $launcherHome
$controlRoot = Join-Path $launcherHome 'launcher-control'
New-Item -ItemType Directory -Path $controlRoot -Force | Out-Null
$operationsRoot = Join-Path $controlRoot 'operations'
$reportsRoot = Join-Path $controlRoot 'reports'
New-Item -ItemType Directory -Path $operationsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null
$requestsPath = Join-Path $controlRoot 'requests.json'

function Write-JsonFile {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $json = ($Value | ConvertTo-Json -Depth 40) + "`r`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
}

foreach ($operationFile in @(Get-ChildItem -LiteralPath $operationsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $operation = Read-JsonFile $operationFile.FullName
    if ($operation -and $operation.status -in @('queued', 'running')) {
        $operation.status = 'interrupted'
        $operation.finishedAt = [DateTime]::UtcNow.ToString('o')
        $operation.message = 'The control agent stopped before the operation finished.'
        Write-JsonFile -Path $operationFile.FullName -Value $operation
    }
}

$script:Jobs = @{}
$maxBytes = 1MB
# Named pipes do not support ReadTimeout/WriteTimeout, so I/O is bounded with async waits.
$pipeIoTimeoutMs = 10000
$pipeCloseTimeoutMs = 2000

function Get-ProcessSid {
    param([int]$ProcessId)
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId"
    if (-not $process) { return $null }
    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner
    if ($owner.ReturnValue -ne 0) { return $null }
    $account = [System.Security.Principal.NTAccount]::new([string]$owner.Domain, [string]$owner.User)
    return @{ Sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value; Executable = [string]$process.ExecutablePath }
}

function Read-Exact {
    param($Stream, [byte[]]$Buffer)
    $offset = 0
    while ($offset -lt $Buffer.Length) {
        $task = $Stream.ReadAsync($Buffer, $offset, $Buffer.Length - $offset)
        if (-not $task.Wait($pipeIoTimeoutMs)) { throw 'Pipe read timed out.' }
        $read = $task.Result
        if ($read -le 0) { throw 'Pipe closed.' }
        $offset += $read
    }
}

function Read-Frame {
    param($Stream)
    $header = New-Object byte[] 4
    Read-Exact $Stream $header
    $length = [BitConverter]::ToInt32($header, 0)
    if ($length -lt 2 -or $length -gt $maxBytes) { throw 'Invalid frame length.' }
    $body = New-Object byte[] $length
    Read-Exact $Stream $body
    return [Text.Encoding]::UTF8.GetString($body)
}

function Write-Frame {
    param($Stream, [string]$Text)
    $body = [Text.Encoding]::UTF8.GetBytes($Text)
    if ($body.Length -gt $maxBytes) { throw 'Response exceeds 1 MiB.' }
    $frame = [byte[]]::new(4 + $body.Length)
    [BitConverter]::GetBytes([int]$body.Length).CopyTo($frame, 0)
    $body.CopyTo($frame, 4)
    $task = $Stream.WriteAsync($frame, 0, $frame.Length)
    if (-not $task.Wait($pipeIoTimeoutMs)) { throw 'Pipe write timed out.' }
    $Stream.Flush()
}

function Wait-PipeClientClose {
    # Disconnect discards unread data, and PipeStream.Flush does not wait for the reader.
    # Give the client a moment to read the response and close its end first.
    param($Stream)
    try {
        $task = $Stream.ReadAsync([byte[]]::new(1), 0, 1)
        [void]$task.Wait($pipeCloseTimeoutMs)
    } catch { }
}

function New-Operation {
    param([string]$RequestId, [string]$Kind, [string[]]$RegistryIds, [int]$ProbeCount)
    $id = [guid]::NewGuid().ToString('n')
    $operation = [ordered]@{
        id = $id
        requestId = $RequestId
        kind = $Kind
        status = 'running'
        stage = 'starting'
        message = $null
        registryIds = @($RegistryIds)
        startedAt = [DateTime]::UtcNow.ToString('o')
        finishedAt = $null
        deadlineAt = [DateTime]::UtcNow.AddSeconds((120 * [Math]::Max($ProbeCount, 1)) + 30).ToString('o')
        reportId = $null
        exitCode = $null
    }
    Write-JsonFile -Path (Join-Path $operationsRoot ($id + '.json')) -Value $operation
    $requests = @{};
    if (Test-Path -LiteralPath $requestsPath) { $requests = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -AsHashtable }
    if (-not $requests) { $requests = @{} }
    $requests[$RequestId] = $id
    Write-JsonFile -Path $requestsPath -Value $requests
    return $operation
}

function Save-Operation {
    param($Operation)
    Write-JsonFile -Path (Join-Path $operationsRoot ($Operation.id + '.json')) -Value $Operation
}

function Complete-Job {
    param($Job, [string]$Status, [string]$Message, $Report, [int]$ExitCode)
    $operation = Read-JsonFile (Join-Path $operationsRoot ($Job.Id + '.json'))
    if (-not $operation) { return }
    $operation.status = $Status
    $operation.finishedAt = [DateTime]::UtcNow.ToString('o')
    $operation.message = $Message
    $operation.exitCode = $ExitCode
    if ($Report) {
        $safe = Remove-SensitiveValue $Report
        $operation.reportId = $Job.Id
        Write-JsonFile -Path (Join-Path $reportsRoot ($Job.Id + '.json')) -Value $safe
    }
    Save-Operation $operation
    $script:Jobs.Remove($Job.Id)
}

function Update-Jobs {
    foreach ($id in @($script:Jobs.Keys)) {
        $job = $script:Jobs[$id]
        if ($job.Kind -eq 'node') {
            if ($job.Cancel -or ([DateTime]::UtcNow -gt $job.Deadline)) {
                if (-not $job.Process.HasExited) { Stop-Process -Id $job.Process.Id -Force -ErrorAction SilentlyContinue }
                Complete-Job -Job $job -Status $(if ($job.Cancel) { 'cancelled' } else { 'failed' }) -Message $(if ($job.Cancel) { 'Cancelled.' } else { 'Deadline exceeded.' }) -ExitCode 2
                continue
            }
            if ($job.Process.HasExited) {
                $report = $null
                $line = $job.LastLine
                if ($line) {
                    try { $parsed = $line | ConvertFrom-Json -Depth 40; if ($parsed.type -eq 'result') { $report = $parsed.report } } catch { $report = $null }
                }
                $status = if ($job.Process.ExitCode -eq 0) { 'succeeded' } else { 'failed' }
                Complete-Job -Job $job -Status $status -Message $job.Stage -Report $report -ExitCode $job.Process.ExitCode
            }
        } elseif ($job.Handle.IsCompleted) {
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                $report = $null
                $status = 'succeeded'
                $message = 'Saved.'
                if ($result -and $result.ok -eq $false) { $status = 'failed'; $message = [string]$result.message; $report = $result.report }
                Complete-Job -Job $job -Status $status -Message $message -Report $report -ExitCode $(if ($status -eq 'succeeded') { 0 } else { 2 })
            } catch {
                Complete-Job -Job $job -Status 'failed' -Message $_.Exception.Message -ExitCode 2
            } finally { $job.PowerShell.Dispose() }
        }
    }
}

function Start-NodeJob {
    param($Operation, [string]$Runner, $Configuration)
    $node = (Get-Command node -ErrorAction Stop).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $node
    $start.ArgumentList.Add($Runner)
    $start.ArgumentList.Add('--format')
    $start.ArgumentList.Add('ndjson')
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $process.EnableRaisingEvents = $true
    $job = @{ Id = $Operation.id; Kind = 'node'; Process = $process; Cancel = $false; Deadline = [DateTime]::Parse($Operation.deadlineAt).ToUniversalTime(); Stage = 'starting'; LastLine = $null }
    $script:Jobs[$Operation.id] = $job
    Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -MessageData $job -Action {
        if ($EventArgs.Data) {
            $Event.MessageData.LastLine = $EventArgs.Data
            try {
                $parsed = $EventArgs.Data | ConvertFrom-Json
                if ($parsed.message) { $Event.MessageData.Stage = [string]$parsed.message }
            } catch { }
        }
    } | Out-Null
    [void]$process.Start()
    $process.BeginOutputReadLine()
    $process.StandardInput.Write(($Configuration | ConvertTo-Json -Depth 40 -Compress))
    $process.StandardInput.Close()
}

function Start-MemoryJob {
    param($Operation, [hashtable]$Payload)
    $script = {
        param($ModuleRoot, $LauncherHome, $Payload)
        Import-Module (Join-Path $ModuleRoot 'Management.psm1') -DisableNameChecking
        Import-Module (Join-Path $ModuleRoot 'Context.psm1') -DisableNameChecking
        Import-Module (Join-Path $ModuleRoot 'Memories.psm1') -DisableNameChecking
        $context = New-CodexDesktopLaunchContext -CustomCodexHome $LauncherHome -LaunchParameters @{}
        $settings = [pscustomobject]@{ Version = 1; Enabled = [bool]$Payload.enabled; Provider = [string]$Payload.provider; Model = [string]$Payload.model }
        $validation = Invoke-UngateMemoryValidation -Context $context -Settings $settings -Force
        if (-not $validation.Valid) { return @{ ok = $false; message = 'Memory validation failed.'; report = $validation } }
        $saved = Invoke-UngateLauncherRequest -BetaHome $LauncherHome -Action 'memories.set' -Payload $Payload
        if ($saved.status -ge 400) { return @{ ok = $false; message = [string]$saved.body.message; report = $saved.body } }
        return @{ ok = $true; message = 'Saved.' }
    }
    $powerShell = [powershell]::Create()
    [void]$powerShell.AddScript($script).AddArgument($moduleRoot).AddArgument($launcherHome).AddArgument($Payload)
    $handle = $powerShell.BeginInvoke()
    $script:Jobs[$Operation.id] = @{ Id = $Operation.id; Kind = 'memory'; PowerShell = $powerShell; Handle = $handle; Cancel = $false }
}

$rights = [System.IO.Pipes.PipeAccessRights]'ReadWrite, Synchronize'
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$security = [System.IO.Pipes.PipeSecurity]::new()
$security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new($OwnerSid), $rights, $allow))
$security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'), $rights, $allow))
try {
    $pipe = [System.IO.Pipes.NamedPipeServerStreamAcl]::Create(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous,
        65536,
        65536,
        $security)
} catch {
    Write-Error "Named pipe ACL could not be created. Refusing to start without an ACL: $($_.Exception.Message)"
    exit 1
}
Write-JsonFile -Path (Join-Path $controlRoot 'agent.json') -Value @{ pid = $PID; pipe = $pipeName; ownerSid = $OwnerSid }

try {
    while ($true) {
        $pending = $pipe.WaitForConnectionAsync()
        while (-not $pending.Wait(500)) { Update-Jobs }
        try {
            $clientPid = 0
            [void][UngatePipeNative]::GetNamedPipeClientProcessId($pipe.SafePipeHandle.DangerousGetHandle(), [ref]$clientPid)
            $client = Get-ProcessSid -ProcessId $clientPid
            $allowed = $client -and ($client.Sid -eq $OwnerSid -or $client.Sid -eq 'S-1-5-18')
            $requestText = Read-Frame $pipe
            $request = $requestText | ConvertFrom-Json -AsHashtable -Depth 40
            $requestId = [string]$request.requestId
            $body = @{ version = 1; requestId = $requestId; serverPid = $PID }
            if (-not $allowed -or [int]$request.version -ne 1) {
                $body.status = 403
                $body.body = @{ code = 'forbidden'; message = 'Pipe peer is not allowed.' }
            } else {
                $payload = @{}; if ($request.payload) { $payload = ConvertTo-LauncherDictionary $request.payload }
                $action = [string]$request.action
                if ($action -eq 'agent.ping') {
                    $body.status = 200
                    $body.body = @{ ready = $true; pid = $PID }
                } elseif ($payload.ContainsKey('betaHome') -or $payload.ContainsKey('path') -or $payload.ContainsKey('apiKey')) {
                    $body.status = 400
                    $body.body = @{ code = 'malformed_request'; message = 'Arbitrary paths and secrets are not accepted.' }
                } elseif ($action -eq 'operations.get') {
                    $record = Read-JsonFile (Join-Path $operationsRoot ([string]$payload.operationId + '.json'))
                    if (-not $record) { $body.status = 404; $body.body = @{ code = 'unknown_operation'; message = 'Operation not found.' } }
                    else { $body.status = 200; $body.body = Remove-SensitiveValue $record }
                } elseif ($action -eq 'operations.cancel') {
                    $job = $script:Jobs[[string]$payload.operationId]
                    if ($job) { $job.Cancel = $true; if ($job.Process -and -not $job.Process.HasExited) { Stop-Process -Id $job.Process.Id -Force } }
                    $body.status = 202
                    $body.body = @{ operationId = [string]$payload.operationId }
                } elseif ($action -eq 'diagnostics.start' -or ($action -eq 'memories.set' -and $payload.enabled -eq $true)) {
                    $existingId = $null
                    if (Test-Path -LiteralPath $requestsPath) {
                        $known = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -AsHashtable
                        if ($known.ContainsKey($requestId)) { $existingId = [string]$known[$requestId] }
                    }
                    if ($existingId) {
                        $body.status = 202
                        $body.body = @{ operationId = $existingId }
                    } elseif ($script:Jobs.Count -gt 0) {
                        $body.status = 409
                        $body.body = @{ code = 'busy'; message = 'Another launcher operation is running.' }
                    } else {
                        $kind = if ($action -eq 'memories.set') { 'memory' } else { [string]$payload.kind }
                        $ids = @()
                        if ($payload.registryIds) { $ids = @($payload.registryIds) }
                        $operation = New-Operation -RequestId $requestId -Kind $kind -RegistryIds $ids -ProbeCount ([Math]::Max($ids.Count, 1))
                        if ($action -eq 'memories.set') { Start-MemoryJob -Operation $operation -Payload $payload }
                        else {
                            $runnerName = switch ($kind) { 'tools' { 'codex-tool-compatibility.mjs' } 'memory' { 'codex-memory-preflight.mjs' } default { 'codex-model-capabilities.mjs' } }
                            $configuration = New-UngateRunnerConfiguration -BetaHome $launcherHome -Kind $kind -RegistryIds $ids
                            $inputObject = if ($kind -eq 'memory') { $configuration.configuration } elseif ($kind -eq 'tools') { @{ models = $configuration.models; reportDirectory = $configuration.reportDirectory; cachePath = (Join-Path $launcherHome 'tool-compatibility/tools-schema-cache.json') } } else { @{ model = @($configuration.models)[0]; reportDirectory = $configuration.reportDirectory } }
                            Start-NodeJob -Operation $operation -Runner (Join-Path $PSScriptRoot $runnerName) -Configuration $inputObject
                        }
                        $body.status = 202
                        $body.body = @{ operationId = $operation.id }
                    }
                } else {
                    $result = Invoke-UngateLauncherRequest -BetaHome $launcherHome -Action $action -Payload $payload
                    $body.status = $result.status
                    $body.body = $result.body
                }
            }
            Write-Frame $pipe (($body | ConvertTo-Json -Depth 40 -Compress))
        } catch {
            try {
                Write-Frame $pipe (@{ version = 1; status = 422; body = @{ code = 'invalid_settings'; message = $_.Exception.Message } } | ConvertTo-Json -Compress -Depth 10)
            } catch { }
        } finally {
            if ($pipe.IsConnected) {
                Wait-PipeClientClose $pipe
                $pipe.Disconnect()
            }
        }
    }
} finally {
    $pipe.Dispose()
}
