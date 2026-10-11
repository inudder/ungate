#requires -Version 7.4
# Cross-process settings lock. Importing this module has no side effects.

# Re-entrant leases live in AppDomain data, not module state: they survive Import-Module -Force,
# so a re-imported module never waits 15 seconds on a lock its own process already holds.
function Get-UngateProfileLockTable {
    $table = [System.AppDomain]::CurrentDomain.GetData('Ungate.ProfileLocks')
    if ($null -eq $table) {
        $table = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        [System.AppDomain]::CurrentDomain.SetData('Ungate.ProfileLocks', $table)
    }
    return ,$table
}

function Normalize-UngateLauncherHome {
    param([Parameter(Mandatory)][string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { throw 'Codex home path cannot be empty.' }
    $normalized = [System.IO.Path]::GetFullPath($PathValue)
    $root = [System.IO.Path]::GetPathRoot($normalized)
    if ($normalized.Length -gt $root.Length) { $normalized = $normalized.TrimEnd('\', '/') }
    return $normalized
}

function Get-UngateLauncherPipeName {
    param([Parameter(Mandatory)][string]$OwnerSid, [Parameter(Mandatory)][string]$BetaHome)
    $material = "$OwnerSid|$(Normalize-UngateLauncherHome $BetaHome)"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    return "ungate-launcher-control-$($hash.Substring(0, 32))"
}

function Get-UngateStableRevision {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Material)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Material)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Enter-UngateProfileLock {
    param([Parameter(Mandatory)][string]$HomePath)
    $normalizedProfile = Normalize-UngateLauncherHome $HomePath
    $key = "$($normalizedProfile.ToLowerInvariant())|$([System.Threading.Thread]::CurrentThread.ManagedThreadId)"
    $locks = Get-UngateProfileLockTable
    if ($locks.ContainsKey($key)) {
        $locks[$key].Depth += 1
        return [pscustomobject]@{ Key = $key; Nested = $true }
    }
    if (-not (Test-Path -LiteralPath $normalizedProfile -PathType Container)) {
        New-Item -ItemType Directory -Path $normalizedProfile -Force | Out-Null
    }
    $lockPath = Join-Path $normalizedProfile 'ungate-launcher-management.lock'
    $stream = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try {
            $stream = [System.IO.FileStream]::new(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
            break
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Launcher settings are locked: $normalizedProfile" }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
    $locks[$key] = @{ Stream = $stream; Depth = 1 }
    return [pscustomobject]@{ Key = $key; Nested = $false }
}

function Exit-UngateProfileLock {
    param($Lease)
    $locks = Get-UngateProfileLockTable
    if (-not $Lease -or -not $locks.ContainsKey([string]$Lease.Key)) { return }
    $state = $locks[[string]$Lease.Key]
    $state.Depth -= 1
    if ($state.Depth -le 0) {
        $state.Stream.Dispose()
        $removed = $null
        [void]$locks.TryRemove([string]$Lease.Key, [ref]$removed)
    }
}

function Invoke-UngateProfileLock {
    param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)][scriptblock]$Action)
    $lease = Enter-UngateProfileLock -HomePath $HomePath
    try { return & $Action } finally { Exit-UngateProfileLock -Lease $lease }
}

Export-ModuleMember -Function @(
    'Normalize-UngateLauncherHome', 'Get-UngateLauncherPipeName', 'Get-UngateStableRevision',
    'Enter-UngateProfileLock', 'Exit-UngateProfileLock', 'Invoke-UngateProfileLock'
)
