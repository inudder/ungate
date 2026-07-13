#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

# Disable pnpm 11's auto-install-before-run (verify-deps-before-run)
$env:npm_config_verify_deps_before_run = 'false'
$env:CI = 'true'

$repoDir     = (Resolve-Path "$PSScriptRoot\..\..").Path
$extDir      = Join-Path $repoDir 'apps\extension'
$bundledDir  = Join-Path $extDir 'bundled'
$outDir      = Join-Path $extDir 'out'

# Run all pnpm commands from repo root so workspace detection works
Push-Location $repoDir

Write-Host 'Building shared...' -ForegroundColor Cyan
pnpm --filter @ungate/shared run build
if ($LASTEXITCODE -ne 0) { throw "shared build failed" }

Write-Host 'Building api...' -ForegroundColor Cyan
pnpm --filter @ungate/api run build:bundle
if ($LASTEXITCODE -ne 0) { throw "api build failed" }

Write-Host 'Building web...' -ForegroundColor Cyan
pnpm --filter @ungate/web run build
if ($LASTEXITCODE -ne 0) { throw "web build failed" }

Write-Host 'Building extension...' -ForegroundColor Cyan
Push-Location $extDir
pnpm run build
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "extension build failed" }
Pop-Location

Write-Host 'Copying project files...' -ForegroundColor Cyan
Copy-Item (Join-Path $repoDir 'LICENSE')  (Join-Path $extDir 'LICENSE')  -Force
Copy-Item (Join-Path $repoDir 'README.md') (Join-Path $extDir 'README.md') -Force

Write-Host 'Assembling bundle...' -ForegroundColor Cyan
if (Test-Path $bundledDir) { Remove-Item $bundledDir -Recurse -Force }
if (Test-Path $outDir)     { Remove-Item $outDir     -Recurse -Force }

New-Item -ItemType Directory -Path (Join-Path $bundledDir 'api\bundle')      -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $bundledDir 'api\node_modules') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $bundledDir 'web\dist')         -Force | Out-Null
New-Item -ItemType Directory -Path $outDir                                     -Force | Out-Null

# api: tsup bundle (single file) + drizzle migrations
Copy-Item (Join-Path $repoDir 'apps\api\bundle\*') (Join-Path $bundledDir 'api\bundle\') -Recurse -Force
Copy-Item (Join-Path $repoDir 'apps\api\drizzle')  (Join-Path $bundledDir 'api\')        -Recurse -Force

# wake-ping config (user addition — not in upstream)
Copy-Item (Join-Path $repoDir 'apps\api\wake-ping.json') (Join-Path $bundledDir 'api\wake-ping.json') -Force

# web: static build
Copy-Item (Join-Path $repoDir 'apps\web\dist\*') (Join-Path $bundledDir 'web\dist\') -Recurse -Force

# better-sqlite3 runtime deps (dereference symlinks via -Recurse on Windows)
$bsSource = Join-Path $repoDir 'apps\api\node_modules\better-sqlite3'
if (Test-Path $bsSource) {
    Copy-Item $bsSource (Join-Path $bundledDir 'api\node_modules\better-sqlite3') -Recurse -Force
}

$bindingsSource = Get-ChildItem (Join-Path $repoDir 'node_modules\.pnpm') -Directory -Filter 'bindings@*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bindingsSource) {
    $bindingsPath = Join-Path $bindingsSource.FullName 'node_modules\bindings'
    if (Test-Path $bindingsPath) {
        Copy-Item $bindingsPath (Join-Path $bundledDir 'api\node_modules\bindings') -Recurse -Force
    }
}

$fileUriSource = Get-ChildItem (Join-Path $repoDir 'node_modules\.pnpm') -Directory -Filter 'file-uri-to-path@*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($fileUriSource) {
    $fileUriPath = Join-Path $fileUriSource.FullName 'node_modules\file-uri-to-path'
    if (Test-Path $fileUriPath) {
        Copy-Item $fileUriPath (Join-Path $bundledDir 'api\node_modules\file-uri-to-path') -Recurse -Force
    }
}

# Trim better-sqlite3 build artifacts (dev-machine binary + SQLite C sources)
Write-Host 'Trimming better-sqlite3...' -ForegroundColor Cyan
$bsBuild = Join-Path $bundledDir 'api\node_modules\better-sqlite3\build'
$bsDeps  = Join-Path $bundledDir 'api\node_modules\better-sqlite3\deps'
if (Test-Path $bsBuild) { Remove-Item $bsBuild -Recurse -Force }
if (Test-Path $bsDeps)  { Remove-Item $bsDeps  -Recurse -Force }

Write-Host 'Packaging vsix...' -ForegroundColor Cyan
Push-Location $extDir
pnpm exec vsce package --no-dependencies --out 'out\ungate.vsix'
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "vsce package failed" }
Pop-Location

# Clean up intermediate bundle dir (vsix already contains everything)
Remove-Item $bundledDir -Recurse -Force

$vsixPath = Join-Path $extDir 'out\ungate.vsix'
Write-Host ""
Write-Host "Done. Package ready at: $vsixPath" -ForegroundColor Green

Pop-Location
