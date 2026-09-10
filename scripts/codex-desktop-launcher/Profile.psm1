#requires -Version 7.4
# Profile: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Routing.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Toml.psm1') -DisableNameChecking -ErrorAction Stop

function Initialize-UngateCodexConfig {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'

    if (Test-Path -LiteralPath $Context.CustomConfigPath) {
        Write-Host "[ungate] Using existing custom config: $($Context.CustomConfigPath)" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $Context.DefaultConfigPath)) {
        throw "Default Codex config not found at $($Context.DefaultConfigPath)."
    }

    New-Item -ItemType Directory -Path $Context.CustomCodexHome -Force | Out-Null

    $config = Get-Content -LiteralPath $Context.DefaultConfigPath -Raw
    $config = Set-TopLevelTomlValue -Content $config -Key 'model' -TomlValue "`"$($Selection.LaunchModel)`""
    $config = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model_provider' `
        -TomlValue "`"$($Selection.LaunchProvider.Name)`""
    $config = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model_reasoning_effort' `
        -TomlValue "`"$($Selection.SelectedModel.DefaultReasoningLevel)`""
    $config = Ensure-ModelProvidersInConfig -Context $Context -Selection $Selection -Content $config
    [System.IO.File]::WriteAllText(
        $Context.CustomConfigPath,
        $config,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "[ungate] Created custom config: $($Context.CustomConfigPath)" -ForegroundColor Green
}

function Ensure-SharedDirectory {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Name
    )
    $ErrorActionPreference = 'Stop'

    $source = Join-Path $Context.DefaultCodexHome $Name
    $target = Join-Path $Context.CustomCodexHome $Name
    if (-not (Test-Path -LiteralPath $source)) {
        return
    }

    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        $targetPath = @($item.Target)[0]
        if (-not $isReparsePoint -or -not $targetPath) {
            throw "$target already exists and is not a directory junction."
        }

        $resolvedSource = [System.IO.Path]::GetFullPath($source)
        $resolvedTarget = [System.IO.Path]::GetFullPath($targetPath)
        if ($resolvedSource -ne $resolvedTarget) {
            throw "$target points to '$targetPath', expected '$source'."
        }
        return
    }

    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    Write-Host "[ungate] Shared Codex directory: $Name" -ForegroundColor DarkGray
}

function Sync-CodexGlobalInstructions {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    $sourceInstructions = Join-Path $Context.DefaultCodexHome 'AGENTS.md'
    $targetInstructions = Join-Path $Context.CustomCodexHome 'AGENTS.md'

    if (-not (Test-Path -LiteralPath $sourceInstructions -PathType Leaf)) {
        throw "Default Codex global instructions not found at $sourceInstructions."
    }
    if (
        (Test-Path -LiteralPath $targetInstructions) -and
        -not (Test-Path -LiteralPath $targetInstructions -PathType Leaf)
    ) {
        throw "Custom Codex global instructions target is not a file: $targetInstructions"
    }

    New-Item -ItemType Directory -Path $Context.CustomCodexHome -Force | Out-Null
    $sourceHash = (Get-FileHash -LiteralPath $sourceInstructions -Algorithm SHA256).Hash
    $targetHash = if (Test-Path -LiteralPath $targetInstructions -PathType Leaf) {
        (Get-FileHash -LiteralPath $targetInstructions -Algorithm SHA256).Hash
    }
    else {
        $null
    }

    if ($sourceHash -eq $targetHash) {
        Write-Host '[ungate] Global AGENTS.md already synchronized.' -ForegroundColor DarkGray
        return
    }

    Copy-Item `
        -LiteralPath $sourceInstructions `
        -Destination $targetInstructions `
        -Force
    $targetHash = (Get-FileHash -LiteralPath $targetInstructions -Algorithm SHA256).Hash
    if ($targetHash -ne $sourceHash) {
        throw "Failed to verify synchronized global instructions at $targetInstructions."
    }
    Write-Host '[ungate] Global AGENTS.md synchronized from the default Codex home.' -ForegroundColor Green
}

function Sync-CodexAuthentication {
    param(
        [Parameter(Mandatory)][psobject]$Context
    )
    $ErrorActionPreference = 'Stop'

    $sourceAuth = Join-Path $Context.DefaultCodexHome 'auth.json'
    if (Test-Path -LiteralPath $sourceAuth) {
        Copy-Item -LiteralPath $sourceAuth -Destination (Join-Path $Context.CustomCodexHome 'auth.json') -Force
    }
}

function Test-CodexMcpConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexExecutable,
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )
    $ErrorActionPreference = 'Stop'

    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHome
        $inventoryOutput = @(& $CodexExecutable mcp list --json 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "Codex rejected the MCP configuration in $CodexHome."
        }

        try {
            $inventory = ($inventoryOutput -join "`n") | ConvertFrom-Json -Depth 100
        }
        catch {
            throw "Codex returned invalid MCP inventory JSON for $CodexHome."
        }

        return @(
            $inventory |
                ForEach-Object { [string]$_.name } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    finally {
        if ($null -eq $previousCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_HOME = $previousCodexHome
        }
    }
}

function Sync-CodexMcpServers {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [string]$SourceCodexHome,
        [Parameter(Mandatory = $true)]
        [string]$TargetCodexHome,
        [string]$BetaOnlyMcpContent = ''
    )
    $ErrorActionPreference = 'Stop'

    $sourceConfigPath = Join-Path $SourceCodexHome 'config.toml'
    $targetConfigPath = Join-Path $TargetCodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)) {
        throw "Default Codex config not found at $sourceConfigPath."
    }
    if (-not (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) {
        throw "Custom Codex config not found at $targetConfigPath."
    }

    $codexExecutable = Get-CodexCliExecutable -Context $Context
    if (-not $codexExecutable) {
        throw 'Codex CLI is required to synchronize MCP servers.'
    }

    # Validate the source before reading or changing the isolated config.
    $null = Test-CodexMcpConfiguration `
        -CodexExecutable $codexExecutable `
        -CodexHome $SourceCodexHome

    $sourceConfig = Get-Content -LiteralPath $sourceConfigPath -Raw
    $targetConfig = Get-Content -LiteralPath $targetConfigPath -Raw
    $sourceMcpContent = Get-TomlTableFamilyContent `
        -Content $sourceConfig `
        -TableName 'mcp_servers'
    if (-not [string]::IsNullOrWhiteSpace($BetaOnlyMcpContent)) {
        # The launcher source file uses LF line endings, while Codex rewrites
        # config files with CRLF on Windows. Normalize the injected block before
        # composing the target so post-write verification compares equivalent
        # text instead of failing on line-ending differences.
        $normalizedBetaOnlyMcpContent = ($BetaOnlyMcpContent -split '\r?\n') -join "`r`n"
        $normalizedBetaOnlyMcpContent = $normalizedBetaOnlyMcpContent.Trim()
        $sourceMcpContent = if ([string]::IsNullOrWhiteSpace($sourceMcpContent)) {
            $normalizedBetaOnlyMcpContent
        }
        else {
            ($sourceMcpContent.TrimEnd() + "`r`n`r`n" + $normalizedBetaOnlyMcpContent).Trim()
        }
    }
    $targetMcpContent = Get-TomlTableFamilyContent `
        -Content $targetConfig `
        -TableName 'mcp_servers'

    if ($sourceMcpContent -ceq $targetMcpContent) {
        $null = Test-CodexMcpConfiguration `
            -CodexExecutable $codexExecutable `
            -CodexHome $TargetCodexHome
        Write-Host '[ungate] MCP servers already synchronized.' -ForegroundColor DarkGray
        return
    }

    $targetWithoutMcp = (
        Remove-TomlTable -Content $targetConfig -TableName 'mcp_servers'
    ).TrimEnd()
    $updatedTargetConfig = if ([string]::IsNullOrWhiteSpace($sourceMcpContent)) {
        $targetWithoutMcp + "`r`n"
    }
    else {
        $targetWithoutMcp + "`r`n`r`n" + $sourceMcpContent + "`r`n"
    }

    $targetDirectory = Split-Path -Parent $targetConfigPath
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryConfigPath = Join-Path $targetDirectory ".config.toml.$transactionId.tmp"
    $backupConfigPath = Join-Path $targetDirectory ".config.toml.$transactionId.bak"
    $preserveBackup = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryConfigPath,
            $updatedTargetConfig,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Replace(
            $temporaryConfigPath,
            $targetConfigPath,
            $backupConfigPath
        )

        try {
            $null = Test-CodexMcpConfiguration `
                -CodexExecutable $codexExecutable `
                -CodexHome $TargetCodexHome
            $verifiedConfig = Get-Content -LiteralPath $targetConfigPath -Raw
            $verifiedMcpContent = Get-TomlTableFamilyContent `
                -Content $verifiedConfig `
                -TableName 'mcp_servers'
            if ($verifiedMcpContent -cne $sourceMcpContent) {
                throw 'The synchronized MCP table family does not match the source.'
            }
        }
        catch {
            $validationError = $_.Exception.Message
            try {
                [System.IO.File]::Copy($backupConfigPath, $targetConfigPath, $true)
            }
            catch {
                $preserveBackup = $true
                throw "MCP synchronization failed and automatic recovery failed. Backup retained at $backupConfigPath."
            }
            throw "MCP synchronization failed; the previous Beta config was restored. $validationError"
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryConfigPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryConfigPath -Force
        }
        if (
            -not $preserveBackup -and
            (Test-Path -LiteralPath $backupConfigPath -PathType Leaf)
        ) {
            Remove-Item -LiteralPath $backupConfigPath -Force
        }
    }

    Write-Host '[ungate] MCP servers synchronized from the default Codex home.' -ForegroundColor Green
}

Export-ModuleMember -Function @(
    'Initialize-UngateCodexConfig',
    'Ensure-SharedDirectory',
    'Sync-CodexGlobalInstructions',
    'Sync-CodexAuthentication',
    'Sync-CodexMcpServers'
)
