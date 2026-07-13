#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

# Disable pnpm 11's auto-install-before-run (verify-deps-before-run)
$env:npm_config_verify_deps_before_run = 'false'
$env:CI = 'true'

<#
.SYNOPSIS
  One-click build + install for Ungate Local.

.DESCRIPTION
  1. pnpm install (if node_modules missing)
  2. Build VSIX via scripts/build-package/run.ps1
  3. Uninstall marketplace version (orchidfiles.ungate)
  4. Install local VSIX with --force
  5. Print next steps

.NOTES
  Run from anywhere:  pwsh scripts/build-and-install.ps1
#>

$repoDir   = (Resolve-Path "$PSScriptRoot\..").Path
$extPkg    = Join-Path $repoDir 'apps\extension\package.json'
$vsixPath  = Join-Path $repoDir 'apps\extension\out\ungate.vsix'
$buildScript = Join-Path $repoDir 'scripts\build-package\run.ps1'

Write-Host '=== Ungate Local — Build & Install ===' -ForegroundColor Cyan
Write-Host "Repo: $repoDir"
Write-Host ""

# Step 0: Auto-bump version (1.7.1-local.N → 1.7.1-local.N+1)
Write-Host '[0/5] Bumping version...' -ForegroundColor Yellow
$pkg = Get-Content $extPkg -Raw | ConvertFrom-Json
$currentVersion = $pkg.version
if ($currentVersion -match '^(\d+\.\d+\.\d+)-local\.(\d+)$') {
    $base = $matches[1]
    $n = [int]$matches[2] + 1
    $newVersion = "$base-local.$n"
    $pkg.version = $newVersion
    $pkg | ConvertTo-Json -Depth 10 | Set-Content $extPkg -NoNewline
    Write-Host "  $currentVersion -> $newVersion" -ForegroundColor DarkGray
} else {
    Write-Host "  Version '$currentVersion' doesn't match x.y.z-local.N pattern, skipping bump" -ForegroundColor DarkGray
    $newVersion = $currentVersion
}

# Step 0b: Clean extensions.json — remove stale ungate-local entry to avoid "reinstall" error
$extJsonPath = "$env:USERPROFILE\.cursor\extensions\extensions.json"
if (Test-Path $extJsonPath) {
    try {
        $extJson = Get-Content $extJsonPath -Raw | ConvertFrom-Json
        $filtered = $extJson | Where-Object { $_.identifier.id -ne 'orchidfiles.ungate-local' }
        if ($filtered.Count -lt $extJson.Count) {
            $filtered | ConvertTo-Json -Depth 10 | Set-Content $extJsonPath -NoNewline
            Write-Host "  Cleaned stale ungate-local from extensions.json" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Warning: could not clean extensions.json ($($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

# Step 1: Install deps if needed
$nodeModules = Join-Path $repoDir 'node_modules'
if (-not (Test-Path $nodeModules)) {
    Write-Host '[1/5] Installing dependencies...' -ForegroundColor Yellow
    Push-Location $repoDir
    pnpm install
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'pnpm install failed' }
    Pop-Location
} else {
    Write-Host '[1/5] Dependencies already installed, skipping.' -ForegroundColor DarkGray
}

# Step 2: Build
Write-Host '[2/5] Building extension package...' -ForegroundColor Yellow
& $buildScript
if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)" }
if (-not (Test-Path $vsixPath)) { throw "VSIX not found at $vsixPath" }

# Step 3: Uninstall marketplace version
Write-Host '[3/6] Uninstalling marketplace version (orchidfiles.ungate)...' -ForegroundColor Yellow
$uninstallResult = cursor --uninstall-extension orchidfiles.ungate 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host '  Marketplace version uninstalled.' -ForegroundColor DarkGray
} else {
    Write-Host '  Marketplace version not found or already removed (continuing).' -ForegroundColor DarkGray
}

# Step 4: Close Cursor and free port 47821
Write-Host '[4/6] Closing Cursor and freeing port 47821...' -ForegroundColor Yellow
Write-Host '  Terminating Cursor processes...' -ForegroundColor DarkGray
Get-Process Cursor -ErrorAction SilentlyContinue | Stop-Process -Force

$port = 47821
$connections = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
if ($connections) {
    foreach ($conn in $connections) {
        $pidOwner = $conn.OwningProcess
        if ($pidOwner) {
            Write-Host "  Killing PID $pidOwner holding port $port..." -ForegroundColor DarkGray
            Stop-Process -Id $pidOwner -Force -ErrorAction SilentlyContinue
        }
    }
}

# Step 5: Install local VSIX
Write-Host '[5/6] Installing local extension...' -ForegroundColor Yellow
cursor --install-extension $vsixPath --force
if ($LASTEXITCODE -ne 0) { throw "Installation failed (exit $LASTEXITCODE)" }

# Step 6: Restart Cursor
Write-Host '[6/7] Starting Cursor...' -ForegroundColor Yellow
Start-Process cursor

# Step 7: Restart ungate-api NSSM service (if installed)
$ungateService = Get-Service -Name "ungate-api" -ErrorAction SilentlyContinue
if ($ungateService) {
    Write-Host '[7/7] Restarting ungate-api NSSM service...' -ForegroundColor Yellow
    nssm restart ungate-api
} else {
    Write-Host '[7/7] ungate-api NSSM service not found (skipping restart).' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
Write-Host "Version: $newVersion"
Write-Host "VSIX: $vsixPath"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Open Ungate dashboard — verify Wake Ping card with time inputs'
Write-Host '  2. Check status bar tooltip shows Wake Ping state'
Write-Host ''
Write-Host 'To disable marketplace auto-update globally:' -ForegroundColor DarkGray
Write-Host '  Settings (Ctrl+,) -> search "autoUpdate" -> set "Extensions: Auto Update" to false' -ForegroundColor DarkGray
