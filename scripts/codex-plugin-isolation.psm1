Set-StrictMode -Version Latest

$script:IsolationMarkerName = '.ungate-plugin-isolation.json'

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::TrimEndingDirectorySeparator(
        [System.IO.Path]::GetFullPath($Path)
    )
}

function Get-ComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-NormalizedPath -Path $Path
    if ($normalized.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = '\\' + $normalized.Substring(8)
    }
    elseif ($normalized.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(4)
    }

    return [System.IO.Path]::TrimEndingDirectorySeparator($normalized)
}

function Test-EquivalentPath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return (Get-ComparablePath -Path $Left) -ieq (Get-ComparablePath -Path $Right)
}

function Get-ExtendedLengthPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = Get-NormalizedPath -Path $Path
    if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
        return $normalized
    }
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalized
    }
    if ($normalized.StartsWith('\\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\?\UNC\' + $normalized.Substring(2)
    }
    return '\\?\' + $normalized
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = Get-NormalizedPath -Path $Root
    if ($normalizedPath -ieq $normalizedRoot) {
        return $true
    }

    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-CodexPluginDirectoryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome
    )

    $path = Join-Path $CustomCodexHome 'plugins'
    $expectedTarget = Join-Path $DefaultCodexHome 'plugins'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            Kind = 'Missing'
            Path = $path
            Target = $null
        }
    }

    $item = Get-Item -LiteralPath $path -Force
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isReparsePoint) {
        if (-not $item.PSIsContainer) {
            return [pscustomobject]@{
                Kind = 'Invalid'
                Path = $path
                Target = $null
            }
        }

        return [pscustomobject]@{
            Kind = 'Directory'
            Path = $path
            Target = $null
        }
    }

    $target = @($item.Target)[0]
    if (-not $target) {
        return [pscustomobject]@{
            Kind = 'ForeignLink'
            Path = $path
            Target = $null
        }
    }

    $kind = if (
        (Get-NormalizedPath -Path $target) -ieq
        (Get-NormalizedPath -Path $expectedTarget)
    ) {
        'ExpectedJunction'
    }
    else {
        'ForeignLink'
    }

    return [pscustomobject]@{
        Kind = $kind
        Path = $path
        Target = $target
    }
}

function Invoke-CodexPluginJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $CodexExecutable -PathType Leaf)) {
        throw "Codex CLI not found at $CodexExecutable."
    }
    if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
        throw "CODEX_HOME does not exist: $CodexHome"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $CodexExecutable
    $startInfo.WorkingDirectory = $CodexHome
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CODEX_HOME'] = $CodexHome
    $startInfo.ArgumentList.Add('plugin')
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Codex plugin command did not start.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $command = ('plugin ' + ($Arguments -join ' ')).Trim()
        throw "Codex command '$command' failed with exit code $($process.ExitCode): $($stderr.Trim())"
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return $null
    }

    try {
        return $stdout | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Codex plugin command returned invalid JSON: $($stdout.Trim())"
    }
}

function Get-CodexPluginInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    $plugins = Invoke-CodexPluginJson `
        -CodexExecutable $CodexExecutable `
        -CodexHome $CodexHome `
        -Arguments @('list', '--json')
    $marketplaces = Invoke-CodexPluginJson `
        -CodexExecutable $CodexExecutable `
        -CodexHome $CodexHome `
        -Arguments @('marketplace', 'list', '--json')

    return [pscustomobject]@{
        Installed = @($plugins.installed | Where-Object { $_.installed -ne $false })
        Marketplaces = @($marketplaces.marketplaces)
    }
}

function Get-TomlPluginIds {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $matches = [regex]::Matches(
        $content,
        '(?m)^\[plugins\.(?:"([^"]+)"|''([^'']+)'')\]\s*$'
    )
    return @($matches | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    } | Sort-Object -Unique)
}

function Get-TomlMarketplaceNames {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $matches = [regex]::Matches(
        $content,
        '(?m)^\[marketplaces\.(?:"([^"]+)"|''([^'']+)''|([^\]\s]+))\]\s*$'
    )
    return @($matches | ForEach-Object {
        foreach ($groupIndex in 1..3) {
            if ($_.Groups[$groupIndex].Success) {
                $_.Groups[$groupIndex].Value
                break
            }
        }
    } | Sort-Object -Unique)
}

function Update-StaleBundledMarketplaceSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][bool]$BetaIsRunning
    )

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $sectionPattern = '(?ms)^\[marketplaces\.(?:"openai-bundled"|''openai-bundled''|openai-bundled)\][ \t]*\r?\n.*?(?=^\[|\z)'
    $sectionMatch = [regex]::Match($content, $sectionPattern)
    if (-not $sectionMatch.Success) {
        return [pscustomobject]@{
            Changed = $false
            PreviousSource = $null
            CurrentSource = $null
        }
    }

    $sourcePattern = '(?m)^(?<prefix>[ \t]*source[ \t]*=[ \t]*)(?:''(?<literal>[^''\r\n]*)''|"(?<basic>(?:\\.|[^"\\\r\n])*)")(?<suffix>[ \t]*(?:#.*)?\r?$)'
    $sourceMatch = [regex]::Match($sectionMatch.Value, $sourcePattern)
    if (-not $sourceMatch.Success) {
        throw "The openai-bundled marketplace config does not contain a supported source value: $ConfigPath"
    }

    if ($sourceMatch.Groups['literal'].Success) {
        $currentSource = $sourceMatch.Groups['literal'].Value
    }
    else {
        try {
            $currentSource = ('"' + $sourceMatch.Groups['basic'].Value + '"') |
                ConvertFrom-Json
        }
        catch {
            throw "The openai-bundled marketplace source is not a valid TOML string: $ConfigPath"
        }
    }

    if (Test-EquivalentPath -Left $currentSource -Right $ExpectedPath) {
        return [pscustomobject]@{
            Changed = $false
            PreviousSource = $currentSource
            CurrentSource = $currentSource
        }
    }
    if ($BetaIsRunning) {
        throw 'Codex Beta is running and its bundled marketplace path changed. Close Codex Beta and rerun the launcher.'
    }

    $expectedSource = Get-ExtendedLengthPath -Path $ExpectedPath
    $encodedSource = if ($expectedSource.Contains("'")) {
        $expectedSource | ConvertTo-Json -Compress
    }
    else {
        "'$expectedSource'"
    }
    $replacement = $sourceMatch.Groups['prefix'].Value +
        $encodedSource +
        $sourceMatch.Groups['suffix'].Value
    $updatedSection = $sectionMatch.Value.Substring(0, $sourceMatch.Index) +
        $replacement +
        $sectionMatch.Value.Substring($sourceMatch.Index + $sourceMatch.Length)
    $updatedContent = $content.Substring(0, $sectionMatch.Index) +
        $updatedSection +
        $content.Substring($sectionMatch.Index + $sectionMatch.Length)

    $temporaryConfig = "$ConfigPath.bundled-marketplace-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryConfig,
            $updatedContent,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporaryConfig, $ConfigPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryConfig -PathType Leaf) {
            [System.IO.File]::Delete($temporaryConfig)
        }
    }

    return [pscustomobject]@{
        Changed = $true
        PreviousSource = $currentSource
        CurrentSource = $expectedSource
    }
}

function Reset-StagedPluginConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$StagingHome
    )

    $configPath = Join-Path $StagingHome 'config.toml'
    foreach ($pluginId in (Get-TomlPluginIds -ConfigPath $configPath)) {
        $null = Invoke-CodexPluginJson `
            -CodexExecutable $CodexExecutable `
            -CodexHome $StagingHome `
            -Arguments @('remove', $pluginId, '--json')
    }
    foreach ($marketplace in (Get-TomlMarketplaceNames -ConfigPath $configPath)) {
        $null = Invoke-CodexPluginJson `
            -CodexExecutable $CodexExecutable `
            -CodexHome $StagingHome `
            -Arguments @('marketplace', 'remove', $marketplace, '--json')
    }
}

function Get-PluginMarketplaceName {
    param([Parameter(Mandatory = $true)][string]$PluginId)

    $separatorIndex = $PluginId.LastIndexOf('@')
    if ($separatorIndex -le 0 -or $separatorIndex -eq $PluginId.Length - 1) {
        throw "Invalid Codex plugin id '$PluginId'."
    }
    return $PluginId.Substring($separatorIndex + 1)
}

function Get-BundledMarketplacePluginIds {
    param([Parameter(Mandatory = $true)][string]$MarketplacePath)

    $manifestPath = Join-Path $MarketplacePath '.agents\plugins\marketplace.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Bundled plugin marketplace manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
    return @($manifest.plugins | ForEach-Object {
        "$($_.name)@openai-bundled"
    })
}

function Copy-IsolatedMarketplace {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Plugin marketplace source does not exist: $Source"
    }
    if (-not (Test-PathWithin -Path $Destination -Root $CustomCodexHome)) {
        throw "Refusing to copy a marketplace outside custom CODEX_HOME: $Destination"
    }
    if (Test-Path -LiteralPath $Destination) {
        return $Destination
    }

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Destination.staging-$([guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $Source -Destination $temporary -Recurse
    [System.IO.Directory]::Move($temporary, $Destination)
    return $Destination
}

function Resolve-MarketplaceSources {
    param(
        [Parameter(Mandatory = $true)][string[]]$PluginIds,
        [Parameter(Mandatory = $true)][object[]]$Marketplaces,
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$StagingHome,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace
    )

    $sources = [ordered]@{}
    $marketplaceNames = @($PluginIds | ForEach-Object {
        Get-PluginMarketplaceName -PluginId $_
    } | Sort-Object -Unique)

    foreach ($marketplaceName in $marketplaceNames) {
        if ($marketplaceName -eq 'openai-bundled') {
            $sources[$marketplaceName] = $BetaBundledMarketplace
            continue
        }

        $marketplace = $Marketplaces |
            Where-Object { $_.name -eq $marketplaceName } |
            Select-Object -First 1
        if (-not $marketplace -or -not $marketplace.root) {
            throw "Marketplace '$marketplaceName' is not available in the normal Codex profile."
        }

        $source = [string]$marketplace.root
        if (Test-PathWithin -Path $source -Root $DefaultCodexHome) {
            $destination = Join-Path `
                (Join-Path $StagingHome '.plugin-marketplaces') `
                $marketplaceName
            $source = Copy-IsolatedMarketplace `
                -Source $source `
                -Destination $destination `
                -CustomCodexHome $StagingHome
        }

        if ($marketplaceName -eq 'openai-curated') {
            $sourceSha = Join-Path $DefaultCodexHome '.tmp\plugins.sha'
            if (-not (Test-Path -LiteralPath $sourceSha -PathType Leaf)) {
                throw "The normal Codex curated marketplace SHA is missing: $sourceSha"
            }
            $curatedSha = (Get-Content -LiteralPath $sourceSha -Raw).Trim()
            if ([string]::IsNullOrWhiteSpace($curatedSha)) {
                throw "The normal Codex curated marketplace SHA is empty: $sourceSha"
            }

            $stagedTemporaryRoot = Join-Path $StagingHome '.tmp'
            New-Item -ItemType Directory -Path $stagedTemporaryRoot -Force | Out-Null
            $null = Copy-IsolatedMarketplace `
                -Source $source `
                -Destination (Join-Path $stagedTemporaryRoot 'plugins') `
                -CustomCodexHome $StagingHome
            Copy-Item `
                -LiteralPath $sourceSha `
                -Destination (Join-Path $stagedTemporaryRoot 'plugins.sha')
        }
        $sources[$marketplaceName] = $source
    }

    return $sources
}

function Install-StagedPlugins {
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$StagingHome,
        [Parameter(Mandatory = $true)][string[]]$PluginIds,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$MarketplaceSources
    )

    Reset-StagedPluginConfiguration `
        -CodexExecutable $CodexExecutable `
        -StagingHome $StagingHome

    foreach ($marketplaceName in $MarketplaceSources.Keys) {
        if ($marketplaceName -eq 'openai-curated') {
            continue
        }
        $null = Invoke-CodexPluginJson `
            -CodexExecutable $CodexExecutable `
            -CodexHome $StagingHome `
            -Arguments @(
                'marketplace',
                'add',
                [string]$MarketplaceSources[$marketplaceName],
                '--json'
            )
    }
    foreach ($pluginId in $PluginIds) {
        $null = Invoke-CodexPluginJson `
            -CodexExecutable $CodexExecutable `
            -CodexHome $StagingHome `
            -Arguments @('add', $pluginId, '--json')
    }
}

function Get-BrowserClientVerification {
    param(
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace
    )

    $sourceClient = Join-Path `
        $BetaBundledMarketplace `
        'plugins\browser\scripts\browser-client.mjs'
    if (-not (Test-Path -LiteralPath $sourceClient -PathType Leaf)) {
        throw "Browser client missing from Codex Beta bundle: $sourceClient"
    }

    $installedRoot = Join-Path $CodexHome 'plugins\cache\openai-bundled\browser'
    $installedClients = @(
        Get-ChildItem `
            -LiteralPath $installedRoot `
            -Recurse `
            -File `
            -Filter 'browser-client.mjs' `
            -ErrorAction SilentlyContinue
    )
    if ($installedClients.Count -ne 1) {
        return [pscustomobject]@{
            Matches = $false
            SourcePath = $sourceClient
            SourceSha256 = (Get-FileHash $sourceClient -Algorithm SHA256).Hash
            InstalledPath = $null
            InstalledSha256 = $null
        }
    }

    $sourceHash = (Get-FileHash $sourceClient -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash $installedClients[0].FullName -Algorithm SHA256).Hash
    return [pscustomobject]@{
        Matches = $sourceHash -eq $installedHash
        SourcePath = $sourceClient
        SourceSha256 = $sourceHash
        InstalledPath = $installedClients[0].FullName
        InstalledSha256 = $installedHash
    }
}

function Assert-StagedPluginInstallation {
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$StagingHome,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPluginIds,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace
    )

    $inventory = Get-CodexPluginInventory `
        -CodexExecutable $CodexExecutable `
        -CodexHome $StagingHome
    $installedIds = @($inventory.Installed.pluginId | Sort-Object -Unique)
    $missing = @($ExpectedPluginIds | Where-Object { $_ -notin $installedIds })
    if ($missing.Count -gt 0) {
        throw "Staged Codex profile is missing plugins: $($missing -join ', ')"
    }

    $browser = Get-BrowserClientVerification `
        -CodexHome $StagingHome `
        -BetaBundledMarketplace $BetaBundledMarketplace
    if (-not $browser.Matches) {
        throw 'Staged Browser client does not match the current Codex Beta bundle.'
    }

    return [pscustomobject]@{
        PluginIds = $installedIds
        Browser = $browser
    }
}

function Write-IsolationMarker {
    param(
        [Parameter(Mandatory = $true)][string]$PluginsPath,
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$BetaPackageVersion,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace,
        [Parameter(Mandatory = $true)][string[]]$PluginIds,
        [Parameter(Mandatory = $true)][string]$BrowserSha256
    )

    $marker = [ordered]@{
        schema_version = 1
        updated_at_utc = [DateTime]::UtcNow.ToString('o')
        source_codex_home = Get-NormalizedPath -Path $DefaultCodexHome
        beta_package_version = $BetaPackageVersion
        beta_bundled_marketplace = Get-NormalizedPath -Path $BetaBundledMarketplace
        plugin_ids = @($PluginIds | Sort-Object -Unique)
        browser_sha256 = $BrowserSha256
    }
    $markerPath = Join-Path $PluginsPath $script:IsolationMarkerName
    [System.IO.File]::WriteAllText(
        $markerPath,
        ($marker | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Remove-PrivateTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-PathWithin -Path $Path -Root $CustomCodexHome)) {
        throw "Refusing to remove a directory outside custom CODEX_HOME: $Path"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Set-StagedConfig {
    param(
        [Parameter(Mandatory = $true)][string]$StagedConfig,
        [Parameter(Mandatory = $true)][string]$CustomConfig
    )

    $replacementConfig = "$CustomConfig.plugin-isolation-new"
    [System.IO.File]::Copy($StagedConfig, $replacementConfig, $true)
    [System.IO.File]::Move($replacementConfig, $CustomConfig, $true)
}

function Commit-StagedPluginIsolation {
    param(
        [Parameter(Mandatory = $true)][psobject]$DirectoryState,
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome,
        [Parameter(Mandatory = $true)][string]$StagingHome
    )

    $customConfig = Join-Path $CustomCodexHome 'config.toml'
    $stagedConfig = Join-Path $StagingHome 'config.toml'
    $stagedPlugins = Join-Path $StagingHome 'plugins'
    $finalPlugins = Join-Path $CustomCodexHome 'plugins'
    $stagedMarketplaces = Join-Path $StagingHome '.plugin-marketplaces'
    $finalMarketplaces = Join-Path $CustomCodexHome '.plugin-marketplaces'
    $stagedCuratedRepo = Join-Path $StagingHome '.tmp\plugins'
    $stagedCuratedSha = Join-Path $StagingHome '.tmp\plugins.sha'
    $finalTemporaryRoot = Join-Path $CustomCodexHome '.tmp'
    $finalCuratedRepo = Join-Path $finalTemporaryRoot 'plugins'
    $finalCuratedSha = Join-Path $finalTemporaryRoot 'plugins.sha'
    $backupRoot = Join-Path `
        (Join-Path $CustomCodexHome '.plugin-isolation-backups') `
        ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupConfig = Join-Path $backupRoot 'config.toml'
    Copy-Item -LiteralPath $customConfig -Destination $backupConfig

    $linkRemoved = $false
    $pluginsMoved = $false
    $marketplacesMoved = $false
    $curatedRepoMoved = $false
    $curatedShaMoved = $false
    $previousMarketplaces = Join-Path $backupRoot 'previous-marketplaces'
    $previousCuratedRepo = Join-Path $backupRoot 'previous-curated-repo'
    $previousCuratedSha = Join-Path $backupRoot 'previous-curated.sha'
    try {
        if (Test-Path -LiteralPath $finalMarketplaces) {
            [System.IO.Directory]::Move($finalMarketplaces, $previousMarketplaces)
        }
        if (Test-Path -LiteralPath $finalCuratedRepo) {
            [System.IO.Directory]::Move($finalCuratedRepo, $previousCuratedRepo)
        }
        if (Test-Path -LiteralPath $finalCuratedSha -PathType Leaf) {
            [System.IO.File]::Move($finalCuratedSha, $previousCuratedSha)
        }

        if ($DirectoryState.Kind -eq 'ExpectedJunction') {
            $currentState = Get-CodexPluginDirectoryState `
                -DefaultCodexHome $DefaultCodexHome `
                -CustomCodexHome $CustomCodexHome
            if ($currentState.Kind -ne 'ExpectedJunction') {
                throw 'The custom plugins junction changed during migration.'
            }
            [System.IO.Directory]::Delete($finalPlugins, $false)
            $linkRemoved = $true
        }

        [System.IO.Directory]::Move($stagedPlugins, $finalPlugins)
        $pluginsMoved = $true

        if (Test-Path -LiteralPath $stagedMarketplaces -PathType Container) {
            [System.IO.Directory]::Move($stagedMarketplaces, $finalMarketplaces)
            $marketplacesMoved = $true
        }
        if (Test-Path -LiteralPath $stagedCuratedRepo -PathType Container) {
            New-Item -ItemType Directory -Path $finalTemporaryRoot -Force | Out-Null
            [System.IO.Directory]::Move($stagedCuratedRepo, $finalCuratedRepo)
            $curatedRepoMoved = $true
        }
        if (Test-Path -LiteralPath $stagedCuratedSha -PathType Leaf) {
            New-Item -ItemType Directory -Path $finalTemporaryRoot -Force | Out-Null
            [System.IO.File]::Move($stagedCuratedSha, $finalCuratedSha)
            $curatedShaMoved = $true
        }

        Set-StagedConfig `
            -StagedConfig $stagedConfig `
            -CustomConfig $customConfig
    }
    catch {
        [System.IO.File]::Copy($backupConfig, $customConfig, $true)
        if ($pluginsMoved -and (Test-Path -LiteralPath $finalPlugins)) {
            $failedPlugins = Join-Path $backupRoot 'failed-plugins'
            [System.IO.Directory]::Move($finalPlugins, $failedPlugins)
        }
        if ($marketplacesMoved -and (Test-Path -LiteralPath $finalMarketplaces)) {
            [System.IO.Directory]::Move(
                $finalMarketplaces,
                (Join-Path $backupRoot 'failed-marketplaces')
            )
        }
        if ($curatedRepoMoved -and (Test-Path -LiteralPath $finalCuratedRepo)) {
            [System.IO.Directory]::Move(
                $finalCuratedRepo,
                (Join-Path $backupRoot 'failed-curated-repo')
            )
        }
        if ($curatedShaMoved -and (Test-Path -LiteralPath $finalCuratedSha)) {
            [System.IO.File]::Move(
                $finalCuratedSha,
                (Join-Path $backupRoot 'failed-curated.sha')
            )
        }
        if (Test-Path -LiteralPath $previousMarketplaces -PathType Container) {
            [System.IO.Directory]::Move($previousMarketplaces, $finalMarketplaces)
        }
        if (Test-Path -LiteralPath $previousCuratedRepo -PathType Container) {
            New-Item -ItemType Directory -Path $finalTemporaryRoot -Force | Out-Null
            [System.IO.Directory]::Move($previousCuratedRepo, $finalCuratedRepo)
        }
        if (Test-Path -LiteralPath $previousCuratedSha -PathType Leaf) {
            New-Item -ItemType Directory -Path $finalTemporaryRoot -Force | Out-Null
            [System.IO.File]::Move($previousCuratedSha, $finalCuratedSha)
        }
        if ($linkRemoved -and -not (Test-Path -LiteralPath $finalPlugins)) {
            $expectedTarget = Join-Path $DefaultCodexHome 'plugins'
            New-Item -ItemType Junction -Path $finalPlugins -Target $expectedTarget | Out-Null
        }
        throw
    }

    return $backupRoot
}

function Invoke-InitialPluginMigration {
    param(
        [Parameter(Mandatory = $true)][psobject]$DirectoryState,
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome,
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace,
        [Parameter(Mandatory = $true)][string]$BetaPackageVersion
    )

    $defaultInventory = Get-CodexPluginInventory `
        -CodexExecutable $CodexExecutable `
        -CodexHome $DefaultCodexHome
    $pluginIds = @($defaultInventory.Installed.pluginId | Sort-Object -Unique)
    if ('browser@openai-bundled' -notin $pluginIds) {
        $pluginIds += 'browser@openai-bundled'
        $pluginIds = @($pluginIds | Sort-Object -Unique)
    }

    $availableBundled = Get-BundledMarketplacePluginIds `
        -MarketplacePath $BetaBundledMarketplace
    $unavailableBundled = @($pluginIds | Where-Object {
        (Get-PluginMarketplaceName -PluginId $_) -eq 'openai-bundled' -and
        $_ -notin $availableBundled
    })
    if ($unavailableBundled.Count -gt 0) {
        throw "Codex Beta does not provide installed bundled plugins: $($unavailableBundled -join ', ')"
    }

    $stagingHome = Join-Path `
        $CustomCodexHome `
        ('.plugin-isolation-staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingHome | Out-Null
    Copy-Item `
        -LiteralPath (Join-Path $CustomCodexHome 'config.toml') `
        -Destination (Join-Path $stagingHome 'config.toml')

    try {
        $marketplaceSources = Resolve-MarketplaceSources `
            -PluginIds $pluginIds `
            -Marketplaces $defaultInventory.Marketplaces `
            -DefaultCodexHome $DefaultCodexHome `
            -StagingHome $stagingHome `
            -BetaBundledMarketplace $BetaBundledMarketplace
        Install-StagedPlugins `
            -CodexExecutable $CodexExecutable `
            -StagingHome $stagingHome `
            -PluginIds $pluginIds `
            -MarketplaceSources $marketplaceSources
        $verification = Assert-StagedPluginInstallation `
            -CodexExecutable $CodexExecutable `
            -StagingHome $stagingHome `
            -ExpectedPluginIds $pluginIds `
            -BetaBundledMarketplace $BetaBundledMarketplace
        Write-IsolationMarker `
            -PluginsPath (Join-Path $stagingHome 'plugins') `
            -DefaultCodexHome $DefaultCodexHome `
            -BetaPackageVersion $BetaPackageVersion `
            -BetaBundledMarketplace $BetaBundledMarketplace `
            -PluginIds $verification.PluginIds `
            -BrowserSha256 $verification.Browser.SourceSha256
        $backupRoot = Commit-StagedPluginIsolation `
            -DirectoryState $DirectoryState `
            -DefaultCodexHome $DefaultCodexHome `
            -CustomCodexHome $CustomCodexHome `
            -StagingHome $stagingHome

        return [pscustomobject]@{
            Changed = $true
            Action = 'Migrated'
            PluginIds = $verification.PluginIds
            BrowserSha256 = $verification.Browser.SourceSha256
            BackupRoot = $backupRoot
        }
    }
    finally {
        Remove-PrivateTree -Path $stagingHome -CustomCodexHome $CustomCodexHome
    }
}

function Test-BundledMarketplaceSource {
    param(
        [Parameter(Mandatory = $true)][object[]]$Marketplaces,
        [Parameter(Mandatory = $true)][string]$ExpectedPath
    )

    $configured = $Marketplaces |
        Where-Object { $_.name -eq 'openai-bundled' } |
        Select-Object -First 1
    if (-not $configured -or -not $configured.root) {
        return $false
    }
    return Test-EquivalentPath `
        -Left ([string]$configured.root) `
        -Right $ExpectedPath
}

function Invoke-BundledPluginReconciliation {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome,
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace,
        [Parameter(Mandatory = $true)][string]$BetaPackageVersion,
        [Parameter(Mandatory = $true)][psobject]$Inventory
    )

    $availableBundled = Get-BundledMarketplacePluginIds `
        -MarketplacePath $BetaBundledMarketplace
    $bundledIds = @($Inventory.Installed.pluginId | Where-Object {
        (Get-PluginMarketplaceName -PluginId $_) -eq 'openai-bundled'
    } | Sort-Object -Unique)
    if ('browser@openai-bundled' -notin $bundledIds) {
        $bundledIds += 'browser@openai-bundled'
    }
    $bundledIds = @($bundledIds | Sort-Object -Unique)

    $unavailable = @($bundledIds | Where-Object { $_ -notin $availableBundled })
    if ($unavailable.Count -gt 0) {
        throw "The current Codex Beta bundle no longer provides: $($unavailable -join ', ')"
    }

    $backupRoot = Join-Path `
        (Join-Path $CustomCodexHome '.plugin-isolation-backups') `
        ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-reconcile-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $customConfig = Join-Path $CustomCodexHome 'config.toml'
    $backupConfig = Join-Path $backupRoot 'config.toml'
    Copy-Item -LiteralPath $customConfig -Destination $backupConfig

    $bundledCache = Join-Path $CustomCodexHome 'plugins\cache\openai-bundled'
    $backupCache = Join-Path $backupRoot 'openai-bundled-cache'
    if (Test-Path -LiteralPath $bundledCache) {
        Copy-Item -LiteralPath $bundledCache -Destination $backupCache -Recurse
    }

    try {
        foreach ($configuredId in (Get-TomlPluginIds -ConfigPath $customConfig)) {
            if ((Get-PluginMarketplaceName -PluginId $configuredId) -eq 'openai-bundled') {
                $null = Invoke-CodexPluginJson `
                    -CodexExecutable $CodexExecutable `
                    -CodexHome $CustomCodexHome `
                    -Arguments @('remove', $configuredId, '--json')
            }
        }
        if ('openai-bundled' -in (Get-TomlMarketplaceNames -ConfigPath $customConfig)) {
            $null = Invoke-CodexPluginJson `
                -CodexExecutable $CodexExecutable `
                -CodexHome $CustomCodexHome `
                -Arguments @('marketplace', 'remove', 'openai-bundled', '--json')
        }
        $null = Invoke-CodexPluginJson `
            -CodexExecutable $CodexExecutable `
            -CodexHome $CustomCodexHome `
            -Arguments @('marketplace', 'add', $BetaBundledMarketplace, '--json')
        foreach ($pluginId in $bundledIds) {
            $null = Invoke-CodexPluginJson `
                -CodexExecutable $CodexExecutable `
                -CodexHome $CustomCodexHome `
                -Arguments @('add', $pluginId, '--json')
        }

        $updatedInventory = Get-CodexPluginInventory `
            -CodexExecutable $CodexExecutable `
            -CodexHome $CustomCodexHome
        $browser = Get-BrowserClientVerification `
            -CodexHome $CustomCodexHome `
            -BetaBundledMarketplace $BetaBundledMarketplace
        if (-not $browser.Matches) {
            throw 'Reinstalled Browser client does not match the current Codex Beta bundle.'
        }
        Write-IsolationMarker `
            -PluginsPath (Join-Path $CustomCodexHome 'plugins') `
            -DefaultCodexHome $DefaultCodexHome `
            -BetaPackageVersion $BetaPackageVersion `
            -BetaBundledMarketplace $BetaBundledMarketplace `
            -PluginIds @($updatedInventory.Installed.pluginId) `
            -BrowserSha256 $browser.SourceSha256

        return [pscustomobject]@{
            Changed = $true
            Action = 'Reconciled'
            PluginIds = @($updatedInventory.Installed.pluginId | Sort-Object -Unique)
            BrowserSha256 = $browser.SourceSha256
            BackupRoot = $backupRoot
        }
    }
    catch {
        [System.IO.File]::Copy($backupConfig, $customConfig, $true)
        Remove-PrivateTree -Path $bundledCache -CustomCodexHome $CustomCodexHome
        if (Test-Path -LiteralPath $backupCache) {
            Copy-Item -LiteralPath $backupCache -Destination $bundledCache -Recurse
        }
        throw
    }
}

function Initialize-CodexBetaPluginIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DefaultCodexHome,
        [Parameter(Mandatory = $true)][string]$CustomCodexHome,
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string]$BetaBundledMarketplace,
        [Parameter(Mandatory = $true)][string]$BetaPackageVersion,
        [Parameter(Mandatory = $true)][bool]$BetaIsRunning
    )

    if (-not (Test-Path -LiteralPath (Join-Path $CustomCodexHome 'config.toml') -PathType Leaf)) {
        throw "Custom Codex config is missing under $CustomCodexHome."
    }
    if (-not (Test-Path -LiteralPath $BetaBundledMarketplace -PathType Container)) {
        throw "Codex Beta bundled marketplace is missing: $BetaBundledMarketplace"
    }

    $directoryState = Get-CodexPluginDirectoryState `
        -DefaultCodexHome $DefaultCodexHome `
        -CustomCodexHome $CustomCodexHome
    if ($directoryState.Kind -eq 'ForeignLink') {
        throw "Custom plugins path points to an unexpected target '$($directoryState.Target)'."
    }
    if ($directoryState.Kind -eq 'Invalid') {
        throw "Custom plugins path is not a directory: $($directoryState.Path)"
    }

    $sourceRefresh = Update-StaleBundledMarketplaceSource `
        -ConfigPath (Join-Path $CustomCodexHome 'config.toml') `
        -ExpectedPath $BetaBundledMarketplace `
        -BetaIsRunning $BetaIsRunning

    if ($directoryState.Kind -in @('Missing', 'ExpectedJunction')) {
        if ($BetaIsRunning) {
            throw 'Codex Beta is running and plugin isolation is required. Close Codex Beta and rerun the launcher.'
        }
        return Invoke-InitialPluginMigration `
            -DirectoryState $directoryState `
            -DefaultCodexHome $DefaultCodexHome `
            -CustomCodexHome $CustomCodexHome `
            -CodexExecutable $CodexExecutable `
            -BetaBundledMarketplace $BetaBundledMarketplace `
            -BetaPackageVersion $BetaPackageVersion
    }

    $inventory = Get-CodexPluginInventory `
        -CodexExecutable $CodexExecutable `
        -CodexHome $CustomCodexHome
    $browser = Get-BrowserClientVerification `
        -CodexHome $CustomCodexHome `
        -BetaBundledMarketplace $BetaBundledMarketplace
    $marketplaceMatches = Test-BundledMarketplaceSource `
        -Marketplaces $inventory.Marketplaces `
        -ExpectedPath $BetaBundledMarketplace

    if ($sourceRefresh.Changed -or -not $browser.Matches -or -not $marketplaceMatches) {
        if ($BetaIsRunning) {
            throw 'Codex Beta is running and bundled plugins require an update. Close Codex Beta and rerun the launcher.'
        }
        return Invoke-BundledPluginReconciliation `
            -DefaultCodexHome $DefaultCodexHome `
            -CustomCodexHome $CustomCodexHome `
            -CodexExecutable $CodexExecutable `
            -BetaBundledMarketplace $BetaBundledMarketplace `
            -BetaPackageVersion $BetaPackageVersion `
            -Inventory $inventory
    }

    $markerPath = Join-Path (Join-Path $CustomCodexHome 'plugins') $script:IsolationMarkerName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-IsolationMarker `
            -PluginsPath (Join-Path $CustomCodexHome 'plugins') `
            -DefaultCodexHome $DefaultCodexHome `
            -BetaPackageVersion $BetaPackageVersion `
            -BetaBundledMarketplace $BetaBundledMarketplace `
            -PluginIds @($inventory.Installed.pluginId) `
            -BrowserSha256 $browser.SourceSha256
    }

    return [pscustomobject]@{
        Changed = $false
        Action = 'Verified'
        PluginIds = @($inventory.Installed.pluginId | Sort-Object -Unique)
        BrowserSha256 = $browser.SourceSha256
        BackupRoot = $null
    }
}

Export-ModuleMember -Function @(
    'Initialize-CodexBetaPluginIsolation',
    'Get-CodexPluginDirectoryState'
)
