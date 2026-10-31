#requires -Version 7.4
function Get-ShellRouterServiceName { return 'ungate-codex-shell-router' }
function Get-ShellRouterServiceRoot { return 'C:\ProgramData\Ungate\shell-router' }
function Get-ShellRouterPort { return 8319 }

function Assert-ShellRouterConfigProtection {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'Shell router config directory is missing.' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Shell router config directory is a reparse point.' }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw 'Shell router config directory inherits permissions.' }
    $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($ownerSid, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $allowed) { throw "Unexpected access to shell router configuration: $sid." }
    }
    foreach ($sid in $allowed) {
        $present = @($acl.Access | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -gt 0
        if (-not $present) { throw "Required shell router config access is missing for $sid." }
    }
}

function Get-ShellRouterServiceHealth {
    try { return Invoke-RestMethod -Uri 'http://127.0.0.1:8319/_shell-router/health' -TimeoutSec 2 -NoProxy -ErrorAction Stop }
    catch { return $null }
}

function Get-LocalTcpPortListeners {
    param([Parameter(Mandatory)][int]$Port)
    # After Windows boot, a working service listener can have raw CIM State=0,
    # which NetTCPIP exposes as null and excludes from -State Listen queries.
    # Require an unconnected endpoint; identity checks still verify health PID
    # ownership and the protected NSSM/supervisor/router process tree.
    $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
        if ($connection.RemotePort -ne 0 -or $connection.RemoteAddress -notin @('0.0.0.0', '::')) { continue }
        $state = $connection.State
        if ($null -eq $state) {
            $cimProperties = $connection.PSObject.Properties['CimInstanceProperties']
            if ($cimProperties) { $state = $cimProperties.Value['State'].Value }
        }
        if ($null -ne $state -and [string]$state -in @('Listen', '2', '0')) { $connection }
    }
}

function Assert-ShellRouterServiceIdentity {
    param([Parameter(Mandatory)][object]$Health)
    $serviceName = Get-ShellRouterServiceName
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
    if (-not $service -or $service.State -ne 'Running') { throw 'Shell router service is not running.' }
    $expectedNssm = Join-Path (Get-ShellRouterServiceRoot) 'runtime\nssm.exe'
    if ([string]$service.PathName -ine $expectedNssm) { throw 'Shell router NSSM does not use the protected runtime.' }
    $listeners = @(Get-LocalTcpPortListeners -Port (Get-ShellRouterPort) | Where-Object LocalAddress -eq '127.0.0.1')
    if ($listeners.Count -ne 1 -or [int]$listeners[0].OwningProcess -ne [int]$Health.pid -or
        $Health.service -ne 'codex-model-shell-router') { throw 'Port 8319 is not owned by the expected shell router.' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$Health.pid)" -ErrorAction Stop
    $entry = Join-Path (Get-ShellRouterServiceRoot) 'runtime\codex-model-shell-router-service.mjs'
    if (-not $process -or
        $process.ExecutablePath -ine 'C:\Program Files\nodejs\node.exe' -or
        [string]::IsNullOrWhiteSpace($process.CommandLine) -or
        $process.CommandLine.IndexOf($entry, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'The listener is not the expected NSSM service process.'
    }
    $supervisor = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$process.ParentProcessId)" -ErrorAction Stop
    $supervisorEntry = Join-Path (Get-ShellRouterServiceRoot) 'runtime\codex-shell-router-supervisor.mjs'
    if (-not $supervisor -or [int]$supervisor.ParentProcessId -ne [int]$service.ProcessId -or
        $supervisor.ExecutablePath -ine 'C:\Program Files\nodejs\node.exe' -or
        [string]::IsNullOrWhiteSpace($supervisor.CommandLine) -or
        $supervisor.CommandLine.IndexOf($supervisorEntry, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'The listener is not a child of the expected NSSM supervisor.'
    }
}

function Assert-ShellRouterRuntimeVersion {
    param([Parameter(Mandatory)][string]$ScriptsRoot)
    $runtimeDir = Join-Path (Get-ShellRouterServiceRoot) 'runtime'
    $runtimeFiles = @(
        'codex-shell-router-supervisor.mjs', 'codex-model-shell-router-service.mjs', 'codex-model-shell-router.mjs',
        'codex-shell-router-dpapi.ps1', 'codex-agent-messages.mjs', 'codex-tools-schema-cache.mjs',
        'deepseek-responses-adapter.mjs', 'mimo-responses-namespace.mjs', 'mimo-responses-stream-adapter.mjs'
    )
    foreach ($name in $runtimeFiles) {
        $source = Join-Path $ScriptsRoot $name
        $installed = Join-Path $runtimeDir $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $installed -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash) {
            throw "Shell router protected runtime differs from source: $name. Update it after requests finish."
        }
    }
}

function New-ShellRouterEnvelope {
    param(
        [Parameter(Mandatory)][ValidateSet('config','drain','resume')][string]$Action,
        [object[]]$Routes,
        [string]$ToolsCachePath,
        [int]$LeaseMs = 60000
    )
    $revision = [guid]::NewGuid().ToString()
    $envelope = [ordered]@{
        revision = $revision
        action = $Action
        expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(90).ToString('o')
    }
    if ($Action -eq 'config') {
        $envelope.routes = @($Routes)
        $envelope.toolsCachePath = $ToolsCachePath
    } elseif ($Action -eq 'drain') { $envelope.leaseMs = $LeaseMs }
    return $envelope
}

function ConvertTo-ShellRouterServiceRoutes {
    param([Parameter(Mandatory)][object[]]$Routes, [Parameter(Mandatory)][hashtable]$KeysByEnv)
    return @($Routes | ForEach-Object {
        $key = $KeysByEnv[[string]$_.apiKeyEnv]
        if ([string]::IsNullOrWhiteSpace($key)) { throw 'A shell router route has no resolved credential.' }
        $route = [ordered]@{
            clientModel = [string]$_.clientModel
            upstreamModel = [string]$_.upstreamModel
            upstreamBaseUrl = [string]$_.upstreamBaseUrl
            apiKey = $key
            responsesAdapter = $_.responsesAdapter
        }
        if (($_ -is [System.Collections.IDictionary] -and $_.Contains('parallelToolCalls')) -or
            ($_ -isnot [System.Collections.IDictionary] -and $_.PSObject.Properties['parallelToolCalls'])) {
            $route.parallelToolCalls = [bool]$_.parallelToolCalls
        }
        $route
    })
}

function Write-ShellRouterEnvelope {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Envelope)
    $configDir = Join-Path (Get-ShellRouterServiceRoot) 'config'
    Assert-ShellRouterConfigProtection -Path $configDir
    $json = ConvertTo-Json -InputObject $Envelope -Depth 30 -Compress
    $plaintext = [Text.Encoding]::UTF8.GetBytes($json)
    try {
        $ciphertext = [Security.Cryptography.ProtectedData]::Protect(
            $plaintext, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine
        )
    } finally { [Array]::Clear($plaintext, 0, $plaintext.Length) }
    $revision = [string]$Envelope.revision
    $tempFile = Join-Path $configDir "pending-$revision.tmp"
    $targetFile = Join-Path $configDir "pending-$revision.bin"
    $stream = [IO.File]::Open($tempFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($ciphertext, 0, $ciphertext.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    [IO.File]::Move($tempFile, $targetFile)
    return $revision
}

function Invoke-ShellRouterEnvelope {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Envelope, [int]$TimeoutSeconds = 25)
    $mutex = [Threading.Mutex]::new($false, 'Global\UngateCodexShellRouterConfiguration')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(15)) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out waiting for the shell router configuration lock.' }
        $health = Get-ShellRouterServiceHealth
        if (-not $health) { throw 'Shell router service health is unavailable.' }
        Assert-ShellRouterServiceIdentity -Health $health
        $Envelope.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds - 2)).ToString('o')
        $revision = Write-ShellRouterEnvelope -Envelope $Envelope
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 250
            $health = Get-ShellRouterServiceHealth
            if ($health) {
                Assert-ShellRouterServiceIdentity -Health $health
                if ($health.error_revision -eq $revision) { throw "Shell router rejected the configuration: $($health.config_error)." }
                $actualRevision = if ($Envelope.action -eq 'config') { $health.config_revision } else { $health.command_revision }
                if ($actualRevision -eq $revision) { return $health }
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Shell router did not acknowledge the configuration before the deadline.'
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Start-ShellRouterServiceIfNeeded {
    $serviceName = Get-ShellRouterServiceName
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) { return $false }
    if ($service.Status -ne 'Running') {
        if (@(Get-LocalTcpPortListeners -Port (Get-ShellRouterPort)).Count -gt 0) {
            throw 'Port 8319 is occupied; refusing to start the shell router service.'
        }
        Start-Service -Name $serviceName -ErrorAction Stop
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $health = Get-ShellRouterServiceHealth
        if ($health) { Assert-ShellRouterServiceIdentity -Health $health; return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Shell router service did not become reachable.'
}

function Enter-ShellRouterDrain {
    param([int]$TimeoutSeconds = 30)
    $service = Get-Service -Name (Get-ShellRouterServiceName) -ErrorAction SilentlyContinue
    if (-not $service) {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $connections = @(Get-NetTCPConnection -LocalPort (Get-ShellRouterPort) -State Established -ErrorAction SilentlyContinue)
            if ($connections.Count -eq 0) { return 'legacy-idle' }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $deadline)
        return $null
    }
    if (-not (Start-ShellRouterServiceIfNeeded)) { return $null }
    $null = Invoke-ShellRouterEnvelope -Envelope (New-ShellRouterEnvelope -Action 'drain' -LeaseMs 120000)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $health = Get-ShellRouterServiceHealth
        if (-not $health) { throw 'Shell router health was lost while waiting for requests.' }
        Assert-ShellRouterServiceIdentity -Health $health
        if (-not $health.draining) { throw 'Shell router drain ended before requests finished.' }
        if ([int]$health.active_requests -eq 0) { return 'service-drained' }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $null = Invoke-ShellRouterEnvelope -Envelope (New-ShellRouterEnvelope -Action 'resume')
    return $null
}

function Exit-ShellRouterDrain {
    param([string]$DrainState)
    if ($DrainState -eq 'service-drained') {
        $null = Invoke-ShellRouterEnvelope -Envelope (New-ShellRouterEnvelope -Action 'resume')
    }
}

Export-ModuleMember -Function @('Get-ShellRouterServiceRoot','Assert-ShellRouterConfigProtection',
    'Get-LocalTcpPortListeners','Get-ShellRouterServiceHealth','Assert-ShellRouterServiceIdentity','Assert-ShellRouterRuntimeVersion','New-ShellRouterEnvelope',
    'ConvertTo-ShellRouterServiceRoutes','Write-ShellRouterEnvelope','Invoke-ShellRouterEnvelope',
    'Start-ShellRouterServiceIfNeeded','Enter-ShellRouterDrain','Exit-ShellRouterDrain')
