#requires -Version 7.4
# Desktop: internal Desktop launcher module. No per-launch module state.


function Get-CodexCliExecutable {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($configPath in @($Context.DefaultConfigPath, $Context.CustomConfigPath)) {
        if (-not (Test-Path -LiteralPath $configPath)) {
            continue
        }

        $config = Get-Content -LiteralPath $configPath -Raw
        $configuredCliMatch = [regex]::Match(
            $config,
            "(?m)^CODEX_CLI_PATH\s*=\s*['`"]([^'`"]+)['`"]\s*$"
        )
        if ($configuredCliMatch.Success) {
            $candidatePaths.Add($configuredCliMatch.Groups[1].Value)
        }
    }

    foreach ($codexCommand in @(Get-Command codex -All -ErrorAction SilentlyContinue)) {
        $commandSource = [string]$codexCommand.Source
        if ([string]::IsNullOrWhiteSpace($commandSource)) {
            continue
        }

        $candidatePaths.Add($commandSource)
        $commandDirectory = Split-Path -Parent $commandSource
        $npmPackageRoot = Join-Path $commandDirectory 'node_modules\@openai\codex'
        if (Test-Path -LiteralPath $npmPackageRoot -PathType Container) {
            $npmNativeCandidates = Get-ChildItem `
                -LiteralPath $npmPackageRoot `
                -Filter 'codex.exe' `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending
            foreach ($npmNativeCandidate in $npmNativeCandidates) {
                $candidatePaths.Add($npmNativeCandidate.FullName)
            }
        }
    }

    $localCodexBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $localCodexBin) {
        $localNativeCandidates = Get-ChildItem `
            -LiteralPath $localCodexBin `
            -Recurse `
            -Filter 'codex.exe' `
            -File `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5
        foreach ($localNativeCandidate in $localNativeCandidates) {
            $candidatePaths.Add($localNativeCandidate.FullName)
        }
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($candidatePath in $candidatePaths) {
        if (
            [string]::IsNullOrWhiteSpace($candidatePath) -or
            [System.IO.Path]::GetExtension($candidatePath) -ine '.exe' -or
            -not $seenPaths.Add($candidatePath) -or
            -not (Test-Path -LiteralPath $candidatePath -PathType Leaf)
        ) {
            continue
        }

        return (Resolve-Path -LiteralPath $candidatePath).Path
    }

    return $null
}

function Initialize-CodexWindowsSandbox {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    $config = Get-Content -LiteralPath $Context.CustomConfigPath -Raw
    if ($config -match '(?m)^sandbox_mode\s*=\s*["'']danger-full-access["'']\s*$') {
        Write-Host `
            '[ungate] Windows sandbox initialization skipped (sandbox_mode=danger-full-access).' `
            -ForegroundColor DarkGray
        return
    }

    $codexExecutable = Get-CodexCliExecutable -Context $Context
    if (-not $codexExecutable) {
        throw 'Codex CLI is required to prepare the Windows sandbox.'
    }

    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $Context.CustomCodexHome
        & $codexExecutable sandbox cmd.exe /d /c exit 0 *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Codex Windows sandbox preparation failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        if ($null -eq $previousCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        } else {
            $env:CODEX_HOME = $previousCodexHome
        }
    }

    Write-Host '[ungate] Windows sandbox ready.' -ForegroundColor DarkGray
}

function Get-CodexBetaPackageInfo {
    $ErrorActionPreference = 'Stop'
    $package = Get-AppxPackage -Name OpenAI.CodexBeta |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        throw 'Codex Beta package OpenAI.CodexBeta is not installed for the current user.'
    }

    $manifest = Get-AppxPackageManifest -Package $package
    foreach ($application in @($manifest.Package.Applications.Application)) {
        $relativeExecutable = [string]$application.Executable
        if (-not $relativeExecutable) {
            continue
        }
        $normalizedPath = $relativeExecutable.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $executable = Join-Path $package.InstallLocation $normalizedPath
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            $bundledMarketplace = Join-Path `
                $package.InstallLocation `
                'app\resources\plugins\openai-bundled'
            if (-not (Test-Path -LiteralPath $bundledMarketplace -PathType Container)) {
                throw "Codex Beta bundled plugin marketplace was not found at $bundledMarketplace."
            }

            return [pscustomobject]@{
                ExecutablePath = $executable
                InstallLocation = [string]$package.InstallLocation
                Version = [string]$package.Version
                BundledMarketplacePath = $bundledMarketplace
                PackageFamilyName = [string]$package.PackageFamilyName
                ApplicationId = [string]$application.Id
            }
        }
    }

    throw "Codex Beta executable from the AppX manifest was not found under $($package.InstallLocation)."
}

function Get-CodexPerformanceArguments {
    return @(
        '--disable-renderer-backgrounding',
        '--disable-backgrounding-occluded-windows',
        '--disable-background-timer-throttling',
        '--disable-features=CalculateNativeWinOcclusion,IntensiveWakeUpThrottling',
        '--enable-gpu-rasterization',
        '--enable-zero-copy',
        '--js-flags="--max-old-space-size=8192 --initial-old-space-size=1024"'
    )
}

function Optimize-CodexBetaPriority {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [System.Diagnostics.ProcessPriorityClass]$PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
    )
    $ErrorActionPreference = 'SilentlyContinue'

    $processes = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    foreach ($proc in $processes) {
        try {
            $p = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
            if ($p -and -not $p.HasExited -and $p.PriorityClass -ne $PriorityClass) {
                $p.PriorityClass = $PriorityClass
            }
        }
        catch { }
    }
}

function Start-CodexBetaDesktop {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory)][psobject]$PackageInfo,
        [Parameter(Mandatory)][hashtable]$LaunchEnvironment,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )
    $ErrorActionPreference = 'Stop'

    $desktopArguments = Get-CodexPerformanceArguments

    try {
        Start-Process `
            -FilePath ([string]$PackageInfo.ExecutablePath) `
            -ArgumentList $desktopArguments `
            -WorkingDirectory $WorkingDirectory `
            -Environment $LaunchEnvironment `
            -ErrorAction Stop

        Optimize-CodexBetaPriority -ExecutablePath ([string]$PackageInfo.ExecutablePath)
        return
    }
    catch {
        $directLaunchError = $_.Exception.Message
    }

    try {
        Start-CodexBetaPackageDesktop -Context $Context -PackageInfo $PackageInfo -LaunchEnvironment $LaunchEnvironment -WorkingDirectory $WorkingDirectory -DesktopArguments $desktopArguments
    }
    catch {
        throw "Direct Codex Beta launch failed ($directLaunchError). MSIX package launch also failed: $($_.Exception.Message)"
    }
}

# The package fallback owns its pipe and job; the direct launcher owns fallback selection.
function Start-CodexBetaPackageDesktop {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory)][psobject]$PackageInfo,
        [Parameter(Mandatory)][hashtable]$LaunchEnvironment,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string[]]$DesktopArguments = $null
    )
    $ErrorActionPreference = 'Stop'

    $pipeName = 'ungate-codex-beta-' + [guid]::NewGuid().ToString('N')
    $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
        $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    $job = $null
    try {
        $powerShellPath = (Get-Command pwsh -ErrorAction Stop).Source
        $job = Start-Job -ArgumentList @(
            [string]$PackageInfo.PackageFamilyName,
            [string]$PackageInfo.ApplicationId,
            $powerShellPath,
            $Context.CodexPackageLaunchHelperPath,
            $pipeName,
            [string]$PackageInfo.ExecutablePath,
            $WorkingDirectory,
            $DesktopArguments
        ) -ScriptBlock {
            param(
                $PackageFamilyName,
                $ApplicationId,
                $PowerShellPath,
                $HelperPath,
                $PipeName,
                $ExecutablePath,
                $WorkingDirectory,
                $ExtraArguments
            )

            $argumentsList = [System.Collections.Generic.List[string]]::new()
            $argumentsList.AddRange(@(
                '-NoProfile',
                '-WindowStyle', 'Hidden',
                '-File', "`"$HelperPath`"",
                '-PipeName', "`"$PipeName`"",
                '-ExecutablePath', "`"$ExecutablePath`"",
                '-WorkingDirectory', "`"$WorkingDirectory`""
            ))
            if ($ExtraArguments -and $ExtraArguments.Count -gt 0) {
                $joinedArgs = ($ExtraArguments | ForEach-Object { "`"$_`"" }) -join ','
                $argumentsList.Add("-Arguments @($joinedArgs)")
            }
            $arguments = $argumentsList -join ' '
            Invoke-CommandInDesktopPackage `
                -PackageFamilyName $PackageFamilyName `
                -AppId $ApplicationId `
                -Command $PowerShellPath `
                -Args $arguments `
                -PreventBreakaway `
                -ErrorAction Stop
        }

        $connectTask = $pipe.WaitForConnectionAsync()
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds(20))) {
            throw 'Timed out waiting for the Codex Beta package launch helper.'
        }
        $connectTask.GetAwaiter().GetResult()

        $encoding = [System.Text.UTF8Encoding]::new($false)
        $reader = [System.IO.StreamReader]::new($pipe, $encoding, $false, 1024, $true)
        $writer = [System.IO.StreamWriter]::new($pipe, $encoding, 1024, $true)
        $writer.AutoFlush = $true
        try {
            $writer.WriteLine(($LaunchEnvironment | ConvertTo-Json -Compress))
            $responseTask = $reader.ReadLineAsync()
            if (-not $responseTask.Wait([TimeSpan]::FromSeconds(20))) {
                throw 'Timed out while Codex Beta was starting inside its package.'
            }
            $response = $responseTask.GetAwaiter().GetResult()
        }
        finally {
            $writer.Dispose()
            $reader.Dispose()
        }

        if ($response -notmatch '^OK:(?<processId>\d+)$') {
            throw "The Codex Beta package launch helper failed: $response"
        }
        $completedJob = Wait-Job -Job $job -Timeout 20
        if (-not $completedJob -or $job.State -ne 'Completed') {
            $jobReason = $job.ChildJobs[0].JobStateInfo.Reason
            $reason = if ($jobReason) { $jobReason.Message } else { "job state is $($job.State)" }
            throw "The Codex Beta package command failed: $reason"
        }

        Write-Host `
            "[ungate] Codex Beta started inside its MSIX package (PID $($Matches.processId))." `
            -ForegroundColor DarkGray
    }
    finally {
        $pipe.Dispose()
        if ($job) {
            if ($job.State -in @('Running', 'NotStarted', 'Blocked')) {
                Stop-Job -Job $job
            }
            Remove-Job -Job $job -Force
        }
    }
}

function Get-CodexBetaProcesses {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )
    $ErrorActionPreference = 'Stop'

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -ieq $ExecutablePath
    })
}

function Stop-CodexBeta {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )
    $ErrorActionPreference = 'Stop'

    $runningProcesses = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    if ($runningProcesses.Count -eq 0) {
        return
    }

    $initialCount = $runningProcesses.Count
    Write-Host "[ungate] Closing the running Codex Beta instance ($initialCount process(es))..." -ForegroundColor Yellow

    $closeRequested = $false
    foreach ($runningProcess in $runningProcesses) {
        $process = Get-Process -Id $runningProcess.ProcessId -ErrorAction SilentlyContinue
        if ($process -and $process.MainWindowHandle -ne 0) {
            $closeRequested = $process.CloseMainWindow() -or $closeRequested
        }
    }

    # Electron often keeps helper processes alive after the main window closes.
    $gracefulSeconds = if ($closeRequested) { 12 } else { 2 }
    $gracefulDeadline = (Get-Date).AddSeconds($gracefulSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $runningProcesses = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    } while ($runningProcesses.Count -gt 0 -and (Get-Date) -lt $gracefulDeadline)

    if ($runningProcesses.Count -eq 0) {
        Write-Host '[ungate] Previous Codex Beta instance closed.' -ForegroundColor Green
        return
    }

    # Normal path for Electron multi-process apps: finish residual helpers cleanly.
    Write-Host `
        "[ungate] Finishing residual Codex processes ($($runningProcesses.Count))..." `
        -ForegroundColor DarkGray
    foreach ($processId in @($runningProcesses.ProcessId)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }

    $forcedDeadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 200
        $runningProcesses = @(Get-CodexBetaProcesses -ExecutablePath $ExecutablePath)
    } while ($runningProcesses.Count -gt 0 -and (Get-Date) -lt $forcedDeadline)

    if ($runningProcesses.Count -gt 0) {
        throw "Codex Beta is still running after the automatic close attempt ($($runningProcesses.Count) process(es))."
    }

    Write-Host '[ungate] Previous Codex Beta instance closed.' -ForegroundColor Green
}

function Normalize-WorkspaceRootPath {
    param([AllowNull()][string]$PathValue)
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $normalized = $PathValue.Trim()
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }
    $normalized = $normalized.TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($normalized)
    }
    catch {
        return $normalized
    }
}

function Get-WorkspaceRootList {
    param([AllowNull()]$Value)
    $ErrorActionPreference = 'Stop'

    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        $one = Normalize-WorkspaceRootPath -PathValue $Value
        if ($one) {
            [void]$result.Add($one)
        }
        return @($result)
    }

    foreach ($item in @($Value)) {
        $path = Normalize-WorkspaceRootPath -PathValue ([string]$item)
        if ($path) {
            [void]$result.Add($path)
        }
    }

    return @($result)
}

function Restore-CodexWorkspaceRoots {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    if ($Context.SkipWorkspaceRestore) {
        Write-Host '[ungate] Workspace root restore skipped (-SkipWorkspaceRestore).' -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $Context.CustomGlobalStatePath)) {
        Write-Host "[ungate] No global state yet: $($Context.CustomGlobalStatePath)" -ForegroundColor DarkGray
        return
    }

    $raw = Get-Content -LiteralPath $Context.CustomGlobalStatePath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host '[ungate] Global state is empty; workspace restore skipped.' -ForegroundColor DarkGray
        return
    }

    try {
        $state = $raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Failed to parse Codex global state at $($Context.CustomGlobalStatePath) : $($_.Exception.Message)"
    }

    $orderRoots = @(Get-WorkspaceRootList -Value $state.'project-order')
    $savedRoots = @(Get-WorkspaceRootList -Value $state.'electron-saved-workspace-roots')
    $activeRoots = @(Get-WorkspaceRootList -Value $state.'active-workspace-roots')

    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($path in ($orderRoots + $savedRoots + $activeRoots)) {
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if (Test-Path -LiteralPath $path -PathType Container) {
            [void]$merged.Add($path)
        }
    }

    if ($merged.Count -eq 0) {
        Write-Host '[ungate] Restored 0 workspace roots (project-order/saved are empty or missing on disk).' -ForegroundColor DarkGray
        return
    }

    $backupPath = "$($Context.CustomGlobalStatePath).bak"
    Copy-Item -LiteralPath $Context.CustomGlobalStatePath -Destination $backupPath -Force

    $state | Add-Member -MemberType NoteProperty -Name 'project-order' -Value @($merged) -Force
    $state | Add-Member -MemberType NoteProperty -Name 'electron-saved-workspace-roots' -Value @($merged) -Force
    $state | Add-Member -MemberType NoteProperty -Name 'active-workspace-roots' -Value @($merged) -Force

    $json = $state | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $Context.CustomGlobalStatePath,
        $json + "`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "[ungate] Restored $($merged.Count) workspace roots from project-order ∪ saved roots." -ForegroundColor Green
}

Export-ModuleMember -Function @(
    'Get-CodexCliExecutable',
    'Initialize-CodexWindowsSandbox',
    'Get-CodexBetaPackageInfo',
    'Start-CodexBetaDesktop',
    'Get-CodexBetaProcesses',
    'Stop-CodexBeta',
    'Restore-CodexWorkspaceRoots',
    'Get-CodexPerformanceArguments',
    'Optimize-CodexBetaPriority'
)
