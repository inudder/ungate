#requires -Version 7.4
<#
.SYNOPSIS
    Starts Codex Beta with an isolated Ungate configuration.

.DESCRIPTION
    Creates ~/.codex-ungate/config.toml from the normal Codex config on first
    use, mirrors the normal Codex MCP server configuration, exposes the
    configured Ungate models through the Desktop picker, selects
    ungate-opus-4-8 by default, and launches Codex Beta with a process-local
    CODEX_HOME. All models selected by this launcher use the same custom
    CODEX_HOME, so their project history is shared. The normal ~/.codex profile
    remains separate.

    The normal ~/.codex/config.toml is never modified. Codex Beta must be
    fully closed before launching this isolated instance.

.PARAMETER ApiKey
    Explicit API key for the selected provider. For OmniRoute, the fallback
    order is OMNIROUTE_CODEX_API_KEY followed by the legacy
    OMNIROUTE_API_KEY. For Ungate, uses UNGATE_API_KEY or ~/.ungate/data.db.

.PARAMETER Model
    Ungate model id selected by default in Desktop. When omitted during a
    normal launch, the script displays a numeric model menu. PrepareOnly uses
    ungate-opus-4-8 by default without prompting.

.PARAMETER CustomCodexHome
    Launcher Codex home and shared history store (default: ~/.codex-ungate).
    Keep this value unchanged when switching models if a common history is
    required. A non-default value is allowed, but creates a separate history.

.PARAMETER PrepareOnly
    Prepare and validate the custom configuration without launching Desktop.

.PARAMETER AddModel
    Start an interactive wizard that adds a model to the user model registry
    inside CustomCodexHome. This mode does not prepare configuration or launch
    Codex Beta.

.PARAMETER TestTools
    Test the cached Codex Beta tool schemas without launching or stopping Desktop.
    With -Model, test one registry model noninteractively; otherwise select models.

.PARAMETER SkipWorkspaceRestore
    Skip restoring active-workspace-roots from project-order / saved roots.

.PARAMETER LogLevel
    Terminal log stream verbosity level: Full, Standard, Compact, Minimal, Off, or Errors (default: Standard).
    Can also be changed interactively in the launcher menu or live during streaming using keys 1-6.

.PARAMETER NoLogWatch
    Launch Codex Beta without streaming live session and router activity in the terminal (equivalent to -LogLevel Off).

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 -PrepareOnly

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 -AddModel

.EXAMPLE
    pwsh J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 -EnableProviderFallback
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Model = 'ungate-opus-4-8',
    [string]$CustomCodexHome = (Join-Path $HOME '.codex-ungate'),
    [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off', 'Errors', '')][string]$LogLevel,
    [switch]$AddModel,
    [switch]$TestTools,
    [switch]$PrepareOnly,
    [switch]$SkipWorkspaceRestore,
    [switch]$EnableProviderFallback,
    [switch]$NoLogWatch
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Context.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'codex-desktop-launcher/Launcher.psm1') -DisableNameChecking -ErrorAction Stop
$context = New-CodexDesktopLaunchContext -CustomCodexHome $CustomCodexHome -LaunchParameters $PSBoundParameters -ScriptsRoot $PSScriptRoot
exit (Invoke-CodexDesktopLauncher -Context $context)
