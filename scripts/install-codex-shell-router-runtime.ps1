#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$NssmPath = (Join-Path $env:USERPROFILE 'scoop\apps\nssm\current\nssm.exe')
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'An elevated administrator session is required to install the protected runtime.'
}
$service = Get-Service -Name 'ungate-codex-shell-router' -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') { throw 'Stop the shell router service after requests finish before updating its runtime.' }
$serviceRoot = 'C:\ProgramData\Ungate\shell-router'
$runtimeDir = Join-Path $serviceRoot 'runtime'
$configDir = Join-Path $serviceRoot 'config'

function Set-ProtectedDirectory {
    param([string]$Path, [bool]$OwnerWrite)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Protected directory is not a real directory: $Path"
        }
    } else { $null = New-Item -ItemType Directory -Path $Path -Force }
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow))
    }
    $userRights = if ($OwnerWrite) { [Security.AccessControl.FileSystemRights]::FullControl } else { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User, $userRights, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Set-ProtectedRuntimeFile {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected runtime file is not a regular file: $Path"
    }
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}

Set-ProtectedDirectory -Path $serviceRoot -OwnerWrite $false
Set-ProtectedDirectory -Path $runtimeDir -OwnerWrite $false
Set-ProtectedDirectory -Path $configDir -OwnerWrite $true
foreach ($name in @('backups', 'rejected', 'processed')) {
    $directory = Join-Path $configDir $name
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $null = New-Item -ItemType Directory -Path $directory }
}
$runtimeFiles = @(
    'codex-shell-router-supervisor.mjs', 'codex-model-shell-router-service.mjs', 'codex-model-shell-router.mjs', 'codex-shell-router-dpapi.ps1',
    'codex-agent-messages.mjs', 'codex-tools-schema-cache.mjs', 'deepseek-responses-adapter.mjs',
    'mimo-responses-namespace.mjs', 'mimo-responses-stream-adapter.mjs'
)
foreach ($name in $runtimeFiles) {
    $source = Join-Path $PSScriptRoot $name
    $destination = Join-Path $runtimeDir $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing runtime dependency: $name" }
    if (Test-Path -LiteralPath $destination) { Set-ProtectedRuntimeFile -Path $destination }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Set-ProtectedRuntimeFile -Path $destination
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) {
        throw "Runtime copy did not match source: $name"
    }
}
if (-not (Test-Path -LiteralPath $NssmPath -PathType Leaf)) { throw 'The installed NSSM executable is missing.' }
$nssmDestination = Join-Path $runtimeDir 'nssm.exe'
if (Test-Path -LiteralPath $nssmDestination) { Set-ProtectedRuntimeFile -Path $nssmDestination }
Copy-Item -LiteralPath $NssmPath -Destination $nssmDestination -Force
Set-ProtectedRuntimeFile -Path $nssmDestination
if ((Get-FileHash -LiteralPath $NssmPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $nssmDestination -Algorithm SHA256).Hash) {
    throw 'The protected NSSM copy did not match the installed executable.'
}
foreach ($executable in @('C:\Program Files\nodejs\node.exe', 'C:\Program Files\PowerShell\7\pwsh.exe')) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Required runtime executable is missing: $executable" }
}
Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher\ShellRouterService.psm1') -DisableNameChecking -ErrorAction Stop
Assert-ShellRouterConfigProtection -Path $configDir
Write-Host "Protected shell router runtime prepared at $runtimeDir."
