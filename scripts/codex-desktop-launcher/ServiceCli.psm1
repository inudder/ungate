#requires -Version 7.4
# ServiceCli: service CLI source and versioning. No per-launch module state.

function Get-CodexFileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path
    )
    $ErrorActionPreference = 'SilentlyContinue'

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    catch {
        return $null
    }
}

function Get-CodexCliVersion {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath
    )
    $ErrorActionPreference = 'SilentlyContinue'

    try {
        $output = & $ExecutablePath --version 2>$null
    }
    catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $versionText = ($output | Out-String).Trim()
    if ($versionText -match 'codex-cli\s+([0-9][^\s]*)') {
        return $Matches[1]
    }
    return $null
}

# The Beta package CLI cannot be executed from WindowsApps (Access denied), so the launcher keeps
# its own verified copy. The copy is refreshed only when the package version or the binary changes.
function Get-CodexBetaServiceCli {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$PackageInfo
    )
    $ErrorActionPreference = 'Stop'

    $installLocation = ''
    if ($PackageInfo.PSObject.Properties['InstallLocation']) {
        $installLocation = [string]$PackageInfo.InstallLocation
    }
    if (-not $installLocation) {
        Write-Host `
            '[ungate] The Beta package install location is unknown; the service CLI copy is skipped.' `
            -ForegroundColor DarkGray
        return $null
    }

    $packageCli = Join-Path $installLocation 'app\resources\codex.exe'
    if (-not (Test-Path -LiteralPath $packageCli -PathType Leaf)) {
        Write-Host "[ungate] Beta package CLI not found at $packageCli." -ForegroundColor Yellow
        return $null
    }

    $packageHash = Get-CodexFileSha256 -Path $packageCli
    if (-not $packageHash) {
        Write-Host "[ungate] Beta package CLI could not be read at $packageCli." -ForegroundColor Yellow
        return $null
    }

    $serviceCliDirectory = Join-Path `
        $Context.CustomCodexHome `
        (".launcher-cli\$([string]$PackageInfo.Version)")
    $serviceCli = Join-Path $serviceCliDirectory 'codex.exe'

    if (Test-Path -LiteralPath $serviceCli -PathType Leaf) {
        $serviceHash = Get-CodexFileSha256 -Path $serviceCli
        if ($serviceHash -and $serviceHash -eq $packageHash) {
            return $serviceCli
        }
    }

    try {
        New-Item -ItemType Directory -Path $serviceCliDirectory -Force | Out-Null
        $stagingCli = Join-Path $serviceCliDirectory 'codex.exe.staging'
        if (Test-Path -LiteralPath $stagingCli) {
            Remove-Item -LiteralPath $stagingCli -Force
        }
        Copy-Item -LiteralPath $packageCli -Destination $stagingCli -Force
        $stagedHash = Get-CodexFileSha256 -Path $stagingCli
        if ($stagedHash -ne $packageHash) {
            Remove-Item -LiteralPath $stagingCli -Force -ErrorAction SilentlyContinue
            Write-Host `
                '[ungate] Service CLI copy did not match the Beta package SHA256.' `
                -ForegroundColor Yellow
            return $null
        }
        Move-Item -LiteralPath $stagingCli -Destination $serviceCli -Force
    }
    catch {
        Write-Host "[ungate] Service CLI copy failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    Write-Host `
        "[ungate] Service CLI prepared from Codex Beta $($PackageInfo.Version)." `
        -ForegroundColor DarkGray
    return $serviceCli
}

Export-ModuleMember -Function @(
    'Get-CodexFileSha256',
    'Get-CodexCliVersion',
    'Get-CodexBetaServiceCli'
)
