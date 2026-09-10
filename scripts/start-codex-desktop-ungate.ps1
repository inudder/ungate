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

.PARAMETER SkipWorkspaceRestore
    Skip restoring active-workspace-roots from project-order / saved roots.

.PARAMETER LogLevel
    Terminal log stream verbosity level: Full, Standard, Compact, Minimal, or Off (default: Standard).
    Can also be changed interactively in the launcher menu or live during streaming using keys 1-5.

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
    [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off', '')][string]$LogLevel,
    [switch]$AddModel,
    [switch]$PrepareOnly,
    [switch]$SkipWorkspaceRestore,
    [switch]$EnableProviderFallback,
    [switch]$NoLogWatch
)

$ErrorActionPreference = 'Stop'

function Normalize-CodexHomePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw 'Codex home path cannot be empty.'
    }

    $normalized = [System.IO.Path]::GetFullPath($PathValue)
    $root = [System.IO.Path]::GetPathRoot($normalized)
    if ($normalized.Length -gt $root.Length) {
        $normalized = $normalized.TrimEnd('\', '/')
    }

    return $normalized
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$DefaultCodexHome = Join-Path $HOME '.codex'
$CanonicalCodexHome = Normalize-CodexHomePath -PathValue (Join-Path $HOME '.codex-ungate')
$CustomCodexHome = Normalize-CodexHomePath -PathValue $CustomCodexHome
$DefaultConfigPath = Join-Path $DefaultCodexHome 'config.toml'
$CustomConfigPath = Join-Path $CustomCodexHome 'config.toml'
$DefaultModelCachePath = Join-Path $DefaultCodexHome 'models_cache.json'
$CustomModelCatalogPath = Join-Path $CustomCodexHome 'ungate-models.json'
$CustomModelDefinitionsPath = Join-Path $CustomCodexHome 'ungate-model-definitions.json'
$PickerModelSelectionPath = Join-Path $CustomCodexHome 'ungate-picker-models.json'
$LogSettingsPath = Join-Path $CustomCodexHome 'ungate-log-settings.json'
$CustomGlobalStatePath = Join-Path $CustomCodexHome '.codex-global-state.json'
$ProxyBaseUrl = 'http://127.0.0.1:47821'
$ProviderName = 'ungate_proxy'
$CliProxyUpstreamBaseUrl = 'http://127.0.0.1:8317'
$CliProxyBaseUrl = 'http://127.0.0.1:8318'
$CliProxyProviderName = 'cliproxyapi'
$OmniRouteBaseUrl = 'http://127.0.0.1:20128'
$OmniRouteProviderName = 'omniroute'
$OmniRouteFallbackModel = 'codex-fallback'
$CodexModelShellRouterBaseUrl = 'http://127.0.0.1:8319'
$CodexModelShellRouterProviderName = 'ungate_model_shell_router'
$CodexModelShellRouterPath = Join-Path $PSScriptRoot 'codex-model-shell-router.mjs'
$CodexModelShellRouterServiceName = 'codex-model-shell-router'
$CodexDesktopPickerCapacity = 7
$CodexModelShellPool = @(
    'gpt-5.6-sol',
    'gpt-5.6-terra',
    'gpt-5.6-luna',
    'gpt-5.5',
    'gpt-5.4',
    'gpt-5.4-mini',
    'gpt-5.3-codex'
)
$CodexModelShellRouterProviderDefinition = [pscustomobject][ordered]@{
    Name = $CodexModelShellRouterProviderName
    DisplayName = 'Ungate Codex Model Router'
    ProxyBaseUrl = $CodexModelShellRouterBaseUrl
    EnvKey = 'UNGATE_API_KEY'
}
$CliProxyConfigPath = 'J:\Sandbox\CLIProxyAPI\config.yaml'
$CliProxyBridgePath = Join-Path $PSScriptRoot 'cliproxy-namespace-bridge.mjs'
$CliProxyBridgeServiceName = 'cliproxy-namespace-bridge'
$PluginIsolationModulePath = Join-Path $PSScriptRoot 'codex-plugin-isolation.psm1'
$CodexPackageLaunchHelperPath = Join-Path $PSScriptRoot 'start-codex-beta-package-process.ps1'
if (-not (Test-Path -LiteralPath $PluginIsolationModulePath -PathType Leaf)) {
    throw "Codex plugin isolation module not found at $PluginIsolationModulePath."
}
if (-not (Test-Path -LiteralPath $CodexPackageLaunchHelperPath -PathType Leaf)) {
    throw "Codex Beta package launch helper not found at $CodexPackageLaunchHelperPath."
}
Import-Module $PluginIsolationModulePath -Force
$UngateEnvironmentInstruction = @'
Execution environment: Windows 11. The shell is PowerShell 7.

HARD RULE — source edits:
- For every manual source-file edit or file creation, call
  mcp__ungate_patch__apply_patch from exec with
  { working_directory, patch }. This is the only patch path.
- Build patch as ['*** Begin Patch', ...].join('\n') or a regular
  quoted string. Never use backticks or `${}` — V8 interpolates them
  and throws ReferenceError before the patch runs.
- Always capture the return value and pass it to text(...) or
  notify(...), e.g. text(JSON.stringify(result, null, 2)).
  A bare await yields empty exec output (Wall time 0.0s) even when
  the UI shows Apply patch ok/error. Empty output is not a failed
  tool and does not authorize a different invocation path.
- Never call await tools.apply_patch(`...`) or wrap a patch in a
  JavaScript or PowerShell template literal.
- Do not emulate patch tools via Shell, Python, Node.js, Set-Content,
  or wrappers. If the patch tool is missing, stop and report it.
  An error never authorizes Shell edits.
- Patch text must start with *** Begin Patch, end with *** End Patch,
  use only plain-text Add/Update/Delete/Move headers, and include at
  least one - or + line in every Update File hunk. Do not wrap headers
  in Markdown emphasis.
- hunk_not_found / no_change_hunk / invalid_patch: re-read the live
  file, rebuild the hunk, retry this same MCP tool once. Do not
  switch tools. Do not re-apply a patch that already returned ok: true.
- Copy this exec shape:
  const result = await tools.mcp__ungate_patch__apply_patch({ working_directory: "<absolute cwd>", patch: ["*** Begin Patch", "*** Update File: path", "@@", " context", "-old", "+new", "*** End Patch"].join("\n") });
  text(JSON.stringify(result, null, 2));
- Use Shell only for inspection, execution, formatting, and verification.
- Do not edit source through Set-Content, Add-Content, WriteAllText, Python,
  Node.js, or a generated temporary edit script while apply_patch is available.
- Never nest PowerShell here-strings or wrap source containing @' / '@ / @" / "@
  inside another here-string.
- PowerShell is not Bash. Never use <<EOF or python - <<'PY'.
- Remote SSH scripts via PowerShell: never pass remote Bash scripts with
  variables or command substitutions as double-quoted strings (ssh host "... \$VAR ... $(cmd)").
  In PowerShell \ does not escape $, and $(cmd) runs locally on Windows.
  Always pipe a single-quoted here-string into stdin: @' ... '@ | ssh host 'bash -s'.
- The js tool is a V8 orchestration isolate, not Node.js. Do not use require,
  fs, path, or filesystem access there.
- After editing a .ps1 file, validate it with Parser.ParseFile.
- After an edit-related ParserError, do not retry with another quoting wrapper;
  switch directly to apply_patch.

HARD RULE — long commands:
- Never call await tools.wait(...) inside exec. tools.wait is not a function there;
  it throws TypeError and the turn ends with no final message.
- For pytest, builds, and other commands that may take more than 10 seconds, call
  shell_command with timeout_ms of at least 180000 and start the exec script with
  // @exec: {"yield_time_ms": 180000}.
- If exec already returned "Script running with cell ID ...", call the native wait
  tool named wait with { cell_id, yield_time_ms }. Do not wrap that call in exec.
- After await tools.shell_command(...) or any nested exec tool, pass the result to
  text(...) or notify(...). A bare await returns nothing to the model even when the
  UI shows the command output.

HARD RULE — Plan Mode:
- If collaboration_mode is Plan Mode, do not edit, create, delete, patch, or format
  any source files. Do not call apply_patch, mcp__ungate_patch__apply_patch, or any
  other mutating tool. Read-only inspection is allowed.
- Imperative user language ("перенеси", "сделай", "implement") does not exit Plan Mode.
  Plan the work; do not perform it.
- Finish with a single <proposed_plan> block. No file changes until the user leaves
  Plan Mode or explicitly asks to implement the plan.

Images / vision:
- If the user attaches an image (LocalImage, input_image, data:image/..., or <image ... path=...>),
  it is already in the model context. Answer from that attachment directly.
- NEVER use Read, exec_command, Shell, or any file tool to open/view an attached image path.
  That produces: Cannot read "image.png" (this model does not support image input).
- Only use filesystem tools for non-image files, or when the user asks to inspect binary/metadata
  offline and no vision attachment is present.
'@
function Get-UngateModelIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter()][string]$UpstreamModel,
        [Parameter(Mandatory = $true)]
        [string]$ProviderDisplayName,
        [Parameter(Mandatory = $true)]
        [string]$TransportDescription
    )

    # Anthropic-prefixed models already get the canonical "You are Claude Code,
    # Anthropic's official CLI for Claude." identity from the proxy in
    # apps/api/src/proxy/request-builder.ts (prepareClaudeCodeBody). The Codex
    # self-identification layer ("don't claim to be a GPT model") is pure
    # overhead for them, so we send only the environment instructions.
    $isAnthropicModel = $DisplayName -like 'Claude *' -or $DisplayName -like 'Anthropic *'

    if ($isAnthropicModel) {
        return $UngateEnvironmentInstruction
    }

    $upstreamClause = if ($UpstreamModel) { " (upstream model $UpstreamModel)" } else { '' }

    return (
        "You are Codex, a coding agent powered by $DisplayName$upstreamClause through $TransportDescription. " +
        "When asked which model you are using, identify it as $DisplayName via $ProviderDisplayName and do not claim to be a GPT model." +
        "`r`n`r`n" +
        $UngateEnvironmentInstruction
    )
}

$BuiltInUngateModelDefinitions = @(
    [pscustomobject][ordered]@{
        Slug = 'ungate-opus-4-8'
        DisplayName = 'Claude Opus 4.8 (Ungate)'
        Description = 'Claude Opus 4.8 through the local Ungate Responses proxy.'
        UpstreamModel = 'claude-opus-4-8'
        TransportDescription = 'the local Ungate Responses proxy'
        DefaultReasoningLevel = 'high'
        Priority = 0
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $ProviderName
        ProviderDisplayName = 'Ungate Proxy'
        ProxyBaseUrl = $ProxyBaseUrl
        EnvKey = 'UNGATE_API_KEY'
        RequiresUngate = $true
    }
    [pscustomobject][ordered]@{
        Slug = 'ungate-fable-5'
        DisplayName = 'Claude Fable 5 (Ungate)'
        Description = 'Claude Fable 5 through the local Ungate Responses proxy.'
        UpstreamModel = 'claude-fable-5'
        TransportDescription = 'the local Ungate Responses proxy'
        DefaultReasoningLevel = 'high'
        Priority = 1
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $ProviderName
        ProviderDisplayName = 'Ungate Proxy'
        ProxyBaseUrl = $ProxyBaseUrl
        EnvKey = 'UNGATE_API_KEY'
        RequiresUngate = $true
    }
    [pscustomobject][ordered]@{
        Slug = 'miniMax-M3'
        DisplayName = 'MiniMax M3 (Ungate)'
        Description = 'MiniMax M3 through the local Ungate Responses proxy with image input support.'
        ContextWindow = 1000000
        MaxContextWindow = 1000000
        # UpstreamModel intentionally left blank: MiniMax provider normalises
        # the model id from Codex's request body itself, so the launcher does
        # not need to know the literal id to put it in the identity string.
        TransportDescription = 'the local Ungate Responses proxy'
        DefaultReasoningLevel = 'xhigh'
        Priority = 2
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $ProviderName
        ProviderDisplayName = 'Ungate Proxy'
        ProxyBaseUrl = $ProxyBaseUrl
        EnvKey = 'UNGATE_API_KEY'
        RequiresUngate = $true
    }
    [pscustomobject][ordered]@{
        # Upstream id accepted by CLIProxyAPI; its dynamic catalog can omit usable models.
        Slug = 'grok-4.6'
        DisplayName = 'Grok 4.6 (CLIProxyAPI)'
        Description = 'Grok 4.6 through the local CLIProxyAPI compatibility bridge on port 8318.'
        ContextWindow = 500000
        MaxContextWindow = 500000
        UpstreamModel = 'grok-4.6'
        TransportDescription = 'the local CLIProxyAPI compatibility bridge'
        DefaultReasoningLevel = 'high'
        Priority = 3
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $CliProxyProviderName
        ProviderDisplayName = 'CLIProxyAPI'
        ProxyBaseUrl = $CliProxyBaseUrl
        EnvKey = 'CLIPROXYAPI_API_KEY'
        RequiresUngate = $false
    }
    [pscustomobject][ordered]@{
        Slug = 'apikey-fun/kimi-k3'
        DisplayName = 'Kimi K3 (OmniRoute)'
        Description = 'Kimi K3 through the local OmniRoute proxy on port 20128.'
        UpstreamModel = 'apikey-fun/kimi-k3'
        TransportDescription = 'the local OmniRoute proxy'
        DefaultReasoningLevel = 'high'
        Priority = 4
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $OmniRouteProviderName
        ProviderDisplayName = 'OmniRoute'
        ProxyBaseUrl = $OmniRouteBaseUrl
        EnvKey = 'OMNIROUTE_API_KEY'
        RequiresUngate = $false
    }
    [pscustomobject][ordered]@{
        Slug = 'apikey-fun/grok-4.5'
        DisplayName = 'Grok 4.5 (apikey.fun)'
        Description = 'Grok 4.5 via apikey.fun through the local OmniRoute proxy on port 20128.'
        UpstreamModel = 'apikey-fun/grok-4.5'
        TransportDescription = 'the local OmniRoute proxy'
        DefaultReasoningLevel = 'high'
        Priority = 5
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $OmniRouteProviderName
        ProviderDisplayName = 'OmniRoute'
        ProxyBaseUrl = $OmniRouteBaseUrl
        EnvKey = 'OMNIROUTE_API_KEY'
        RequiresUngate = $false
    }
    [pscustomobject][ordered]@{
        Slug = 'apikey-fun/claude-opus-5'
        DisplayName = 'Claude Opus 5 (apikey.fun)'
        Description = 'Claude Opus 5 via apikey.fun through the local OmniRoute proxy on port 20128.'
        UpstreamModel = 'apikey-fun/claude-opus-5'
        TransportDescription = 'the local OmniRoute proxy'
        DefaultReasoningLevel = 'high'
        Priority = 6
        InputModalities = @('text', 'image')
        SupportsImageDetailOriginal = $true
        WebSearchToolType = 'text_and_image'
        ProviderName = $OmniRouteProviderName
        ProviderDisplayName = 'OmniRoute'
        ProxyBaseUrl = $OmniRouteBaseUrl
        EnvKey = 'OMNIROUTE_API_KEY'
        RequiresUngate = $false
    }
    [pscustomobject][ordered]@{
        Slug = 'mimo-v2.5-pro'
        DisplayName = 'Mimo v2.5 Pro (OmniRoute)'
        Description = 'Mimo v2.5 Pro through the local OmniRoute proxy on port 20128.'
        UpstreamModel = 'mimo-v2.5-pro'
        TransportDescription = 'the local OmniRoute proxy'
        DefaultReasoningLevel = 'high'
        Priority = 7
        InputModalities = @('text')
        SupportsImageDetailOriginal = $false
        WebSearchToolType = 'text'
        ProviderName = $OmniRouteProviderName
        ProviderDisplayName = 'OmniRoute'
        ProxyBaseUrl = $OmniRouteBaseUrl
        EnvKey = 'OMNIROUTE_API_KEY'
        RequiresUngate = $false
        ContextWindow = 1000000
        MaxContextWindow = 1000000
        SupportsReasoningSummaries = $true
        SupportsParallelToolCalls = $false
        ResponsesAdapter = 'mimo-textual-tools'
        TruncationPolicy = @{ mode = 'bytes'; limit = 10000 }
        SupportedReasoningLevels = @(
            @{ effort = 'none'; description = 'Disable Thinking' },
            @{ effort = 'high'; description = 'Enabled Thinking' }
        )
    }
    [pscustomobject][ordered]@{
        Slug = 'deepseek-v4-pro'
        DisplayName = 'DeepSeek V4 Pro (OmniRoute)'
        Description = 'DeepSeek V4 Pro through the local OmniRoute proxy on port 20128.'
        UpstreamModel = 'deepseek/deepseek-v4-pro'
        TransportDescription = 'the local OmniRoute proxy'
        DefaultReasoningLevel = 'high'
        Priority = 8
        InputModalities = @('text')
        SupportsImageDetailOriginal = $false
        WebSearchToolType = 'text'
        ProviderName = $OmniRouteProviderName
        ProviderDisplayName = 'OmniRoute'
        ProxyBaseUrl = $OmniRouteBaseUrl
        EnvKey = 'OMNIROUTE_API_KEY'
        RequiresUngate = $false
        ContextWindow = 1000000
        MaxContextWindow = 1000000
        SupportsReasoningSummaries = $true
        SupportsParallelToolCalls = $true
        SupportedReasoningLevels = @(
            @{ effort = 'none'; description = 'Disable Thinking' },
            @{ effort = 'low'; description = 'Low Thinking' },
            @{ effort = 'high'; description = 'High Thinking' },
            @{ effort = 'max'; description = 'Max Thinking' }
        )
    }
)

# Populate Identity uniformly through Get-UngateModelIdentity so built-ins and
# the registry path share the same format. The helper drops the Codex
# self-identification layer for Anthropic-prefixed models and keeps it for
# everything else.
$BuiltInUngateModelDefinitions = @(
    foreach ($def in $BuiltInUngateModelDefinitions) {
        $upstreamModelValue = $null
        if ($def.PSObject.Properties['UpstreamModel'] -and $def.UpstreamModel) {
            $upstreamModelValue = [string]$def.UpstreamModel
        }

        $identity = Get-UngateModelIdentity `
            -DisplayName ([string]$def.DisplayName) `
            -UpstreamModel $upstreamModelValue `
            -ProviderDisplayName ([string]$def.ProviderDisplayName) `
            -TransportDescription ([string]$def.TransportDescription)

        [pscustomobject][ordered]@{
            Slug = $def.Slug
            DisplayName = $def.DisplayName
            Description = $def.Description
            UpstreamModel = $upstreamModelValue
            TransportDescription = $def.TransportDescription
            Identity = $identity
            DefaultReasoningLevel = $def.DefaultReasoningLevel
            Priority = $def.Priority
            InputModalities = $def.InputModalities
            SupportsImageDetailOriginal = $def.SupportsImageDetailOriginal
            WebSearchToolType = $def.WebSearchToolType
            ProviderName = $def.ProviderName
            ProviderDisplayName = $def.ProviderDisplayName
            ProxyBaseUrl = $def.ProxyBaseUrl
            EnvKey = $def.EnvKey
            RequiresUngate = $def.RequiresUngate
            ContextWindow = $def.ContextWindow
            MaxContextWindow = $def.MaxContextWindow
            EffectiveContextWindowPercent = $def.EffectiveContextWindowPercent
            SupportsReasoningSummaries = $def.SupportsReasoningSummaries
            SupportsParallelToolCalls = $def.SupportsParallelToolCalls
            ResponsesAdapter = if ($def.PSObject.Properties['ResponsesAdapter']) { [string]$def.ResponsesAdapter } else { $null }
            TruncationPolicy = $def.TruncationPolicy
            SupportedReasoningLevels = $def.SupportedReasoningLevels
        }
    }
)

$OmniRouteFallbackModelDefinition = [pscustomobject][ordered]@{
    Slug = $OmniRouteFallbackModel
    DisplayName = 'Codex Provider Fallback (OmniRoute)'
    Description = 'Opt-in provider fallback through OmniRoute: Claude, Grok, MiniMax, then Gemini.'
    Identity = ('You are Codex using the local OmniRoute provider fallback. The active upstream may change between Claude, Grok, MiniMax, and Gemini when a provider is unavailable or its quota is exhausted.' + "`r`n`r`n" + $UngateEnvironmentInstruction)
    DefaultReasoningLevel = 'high'
    Priority = 0
    InputModalities = @('text', 'image')
    SupportsImageDetailOriginal = $true
    WebSearchToolType = 'text_and_image'
    ProviderName = $OmniRouteProviderName
    ProviderDisplayName = 'OmniRoute'
    ProxyBaseUrl = $OmniRouteBaseUrl
    EnvKey = 'OMNIROUTE_API_KEY'
    RequiresUngate = $false
}
$UngateModelDefinitions = @($BuiltInUngateModelDefinitions)

. (Join-Path $PSScriptRoot 'ungate-codex-common.ps1')

function ConvertTo-UngateModelDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record,
        [Parameter(Mandatory = $true)]
        [int]$Priority
    )

    $requiredProperties = @(
        'Slug',
        'DisplayName',
        'UpstreamModel',
        'Transport',
        'DefaultReasoningLevel',
        'SupportsImageInput'
    )
    foreach ($propertyName in $requiredProperties) {
        if ($propertyName -notin $Record.PSObject.Properties.Name) {
            throw "Custom model record is missing required property '$propertyName'."
        }
    }

    $slug = ([string]$Record.Slug).Trim()
    $displayName = ([string]$Record.DisplayName).Trim()
    $upstreamModel = ([string]$Record.UpstreamModel).Trim()
    $transport = ([string]$Record.Transport).Trim().ToLowerInvariant()
    $reasoningLevel = ([string]$Record.DefaultReasoningLevel).Trim().ToLowerInvariant()

    if (-not $slug) {
        throw 'Custom model ID cannot be empty.'
    }
    if ($slug -match '\s|["'']') {
        throw "Custom model ID '$slug' cannot contain whitespace or quotes."
    }
    if (-not $displayName) {
        throw "Custom model '$slug' must have a display name."
    }
    if (-not $upstreamModel) {
        throw "Custom model '$slug' must have an upstream model ID."
    }
    if ($upstreamModel -match '\s|["'']') {
        throw "Upstream model ID '$upstreamModel' cannot contain whitespace or quotes."
    }
    if ($transport -notin @('ungate', 'cliproxyapi', 'omniroute')) {
        throw "Custom model '$slug' has unsupported transport '$transport'."
    }
    if ($reasoningLevel -notin @('low', 'medium', 'high', 'xhigh')) {
        throw "Custom model '$slug' has unsupported reasoning level '$reasoningLevel'."
    }
    if ($Record.SupportsImageInput -isnot [bool]) {
        throw "Custom model '$slug' property SupportsImageInput must be true or false."
    }

    if ($transport -eq 'ungate') {
        $providerNameForModel = $ProviderName
        $providerDisplayName = 'Ungate Proxy'
        $proxyBaseUrlForModel = $ProxyBaseUrl
        $environmentKey = 'UNGATE_API_KEY'
        $requiresUngate = $true
        $transportDescription = 'the local Ungate Responses proxy'
    }
    elseif ($transport -eq 'cliproxyapi') {
        $providerNameForModel = $CliProxyProviderName
        $providerDisplayName = 'CLIProxyAPI'
        $proxyBaseUrlForModel = $CliProxyBaseUrl
        $environmentKey = 'CLIPROXYAPI_API_KEY'
        $requiresUngate = $false
        $transportDescription = 'the local CLIProxyAPI compatibility bridge'
    }
    else {
        $providerNameForModel = $OmniRouteProviderName
        $providerDisplayName = 'OmniRoute'
        $proxyBaseUrlForModel = $OmniRouteBaseUrl
        $environmentKey = 'OMNIROUTE_API_KEY'
        $requiresUngate = $false
        $transportDescription = 'the local OmniRoute proxy'
    }

    $supportsImageInput = [bool]$Record.SupportsImageInput
    $inputModalities = if ($supportsImageInput) { @('text', 'image') } else { @('text') }
    $webSearchToolType = if ($supportsImageInput) { 'text_and_image' } else { 'text' }
    $description = "$displayName maps to upstream model '$upstreamModel' through $transportDescription."
    $identity = Get-UngateModelIdentity `
        -DisplayName $displayName `
        -UpstreamModel $upstreamModel `
        -ProviderDisplayName $providerDisplayName `
        -TransportDescription $transportDescription

    return [pscustomobject][ordered]@{
        Slug = $slug
        DisplayName = $displayName
        UpstreamModel = $upstreamModel
        Transport = $transport
        Description = $description
        Identity = $identity
        DefaultReasoningLevel = $reasoningLevel
        Priority = $Priority
        InputModalities = $inputModalities
        SupportsImageInput = $supportsImageInput
        SupportsImageDetailOriginal = $supportsImageInput
        WebSearchToolType = $webSearchToolType
        ProviderName = $providerNameForModel
        ProviderDisplayName = $providerDisplayName
        ProxyBaseUrl = $proxyBaseUrlForModel
        EnvKey = $environmentKey
        RequiresUngate = $requiresUngate
    }
}

function Read-UngateCustomModelDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        throw "Custom model registry is not a file: $RegistryPath"
    }

    try {
        $registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "Failed to parse custom model registry at $RegistryPath : $($_.Exception.Message)"
    }

    if ('Version' -notin $registry.PSObject.Properties.Name -or [int]$registry.Version -ne 1) {
        throw "Custom model registry at $RegistryPath has an unsupported or missing version."
    }
    if ('Models' -notin $registry.PSObject.Properties.Name) {
        throw "Custom model registry at $RegistryPath is missing the models array."
    }

    $seenSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($definition in $BuiltInDefinitions) {
        if (-not $seenSlugs.Add([string]$definition.Slug)) {
            throw "Built-in model ID '$($definition.Slug)' is duplicated."
        }
    }

    $definitions = [System.Collections.Generic.List[object]]::new()
    $priority = $BuiltInDefinitions.Count
    foreach ($record in @($registry.Models)) {
        $definition = ConvertTo-UngateModelDefinition -Record $record -Priority $priority
        if (-not $seenSlugs.Add($definition.Slug)) {
            throw "Custom model ID '$($definition.Slug)' duplicates an existing model."
        }
        [void]$definitions.Add($definition)
        $priority++
    }

    return @($definitions)
}

function Write-UngateCustomModelDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [object[]]$Records,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions
    )

    $normalizedDefinitions = [System.Collections.Generic.List[object]]::new()
    $seenSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($definition in $BuiltInDefinitions) {
        if (-not $seenSlugs.Add([string]$definition.Slug)) {
            throw "Built-in model ID '$($definition.Slug)' is duplicated."
        }
    }

    $priority = $BuiltInDefinitions.Count
    foreach ($record in $Records) {
        $definition = ConvertTo-UngateModelDefinition -Record $record -Priority $priority
        if (-not $seenSlugs.Add($definition.Slug)) {
            throw "Custom model ID '$($definition.Slug)' duplicates an existing model."
        }
        [void]$normalizedDefinitions.Add($definition)
        $priority++
    }

    $persistentRecords = @(
        foreach ($definition in $normalizedDefinitions) {
            [ordered]@{
                slug = $definition.Slug
                displayName = $definition.DisplayName
                upstreamModel = $definition.UpstreamModel
                transport = $definition.Transport
                defaultReasoningLevel = $definition.DefaultReasoningLevel
                supportsImageInput = $definition.SupportsImageInput
            }
        }
    )
    $json = [ordered]@{
        version = 1
        models = $persistentRecords
    } | ConvertTo-Json -Depth 20

    $absoluteRegistryPath = [System.IO.Path]::GetFullPath($RegistryPath)
    if (
        (Test-Path -LiteralPath $absoluteRegistryPath) -and
        -not (Test-Path -LiteralPath $absoluteRegistryPath -PathType Leaf)
    ) {
        throw "Custom model registry target is not a file: $absoluteRegistryPath"
    }

    $registryDirectory = Split-Path -Parent $absoluteRegistryPath
    New-Item -ItemType Directory -Path $registryDirectory -Force | Out-Null
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $registryDirectory ".ungate-model-definitions.$transactionId.tmp"
    $backupPath = Join-Path $registryDirectory ".ungate-model-definitions.$transactionId.bak"
    $writeCompleted = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json + "`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $absoluteRegistryPath -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $absoluteRegistryPath,
                $backupPath,
                $true
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $absoluteRegistryPath)
        }
        $writeCompleted = $true
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if ($writeCompleted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }

    return $absoluteRegistryPath
}

function Get-UngateModelDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions,
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    $customDefinitions = @(
        Read-UngateCustomModelDefinitions `
            -RegistryPath $RegistryPath `
            -BuiltInDefinitions $BuiltInDefinitions
    )
    return @($BuiltInDefinitions) + $customDefinitions
}

function Get-DefaultUngatePickerModelSlugs {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )

    return @(
        $Definitions |
            Select-Object -First $Capacity |
            ForEach-Object { [string]$_.Slug }
    )
}

function Read-UngatePickerModelSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        return @(Get-DefaultUngatePickerModelSlugs -Definitions $Definitions -Capacity $Capacity)
    }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Desktop picker settings path is not a file: $SettingsPath"
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8 |
            ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "Failed to parse Desktop picker settings at $SettingsPath : $($_.Exception.Message)"
    }

    if ('Version' -notin $settings.PSObject.Properties.Name -or [int]$settings.Version -ne 1) {
        throw "Desktop picker settings at $SettingsPath have an unsupported or missing version."
    }
    if ('ModelSlugs' -notin $settings.PSObject.Properties.Name) {
        throw "Desktop picker settings at $SettingsPath are missing the modelSlugs array."
    }

    $configuredSlugs = @($settings.ModelSlugs)
    if ($configuredSlugs.Count -eq 0) {
        throw 'Desktop picker must contain at least one model.'
    }
    if ($configuredSlugs.Count -gt $Capacity) {
        Write-Host (
            "[ungate] Warning: saved picker selection contains $($configuredSlugs.Count) models; only the first $Capacity valid models will be loaded. Open 'Configure Desktop model picker' to choose the final set."
        ) -ForegroundColor Yellow
    }

    $requestedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($configuredSlug in $configuredSlugs) {
        if ($configuredSlug -isnot [string] -or [string]::IsNullOrWhiteSpace($configuredSlug)) {
            throw 'Desktop picker modelSlugs entries must be non-empty strings.'
        }
        if (-not $requestedSlugs.Add($configuredSlug)) {
            throw "Desktop picker model '$configuredSlug' is duplicated."
        }
    }

    $knownSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($definition in $Definitions) {
        [void]$knownSlugs.Add([string]$definition.Slug)
    }

    $staleSlugs = @($configuredSlugs | Where-Object { -not $knownSlugs.Contains($_) })
    if ($staleSlugs.Count -gt 0) {
        Write-Host (
            "[ungate] Warning: picker models no longer configured and ignored: $($staleSlugs -join ', ')."
        ) -ForegroundColor Yellow
    }

    $resolvedSlugs = @(
        $Definitions |
            Where-Object { $requestedSlugs.Contains([string]$_.Slug) } |
            ForEach-Object { [string]$_.Slug }
    )
    if ($resolvedSlugs.Count -gt $Capacity) {
        $resolvedSlugs = @($resolvedSlugs | Select-Object -First $Capacity)
    }
    if ($resolvedSlugs.Count -gt 0) {
        return $resolvedSlugs
    }

    Write-Host '[ungate] Warning: no saved picker models remain; using the default selection.' -ForegroundColor Yellow
    return @(Get-DefaultUngatePickerModelSlugs -Definitions $Definitions -Capacity $Capacity)
}

function Write-UngatePickerModelSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [string[]]$ModelSlugs,
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )

    if ($ModelSlugs.Count -eq 0) {
        throw 'Desktop picker must contain at least one model.'
    }
    if ($ModelSlugs.Count -gt $Capacity) {
        throw "Desktop picker can contain at most $Capacity models."
    }

    $requestedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($modelSlug in $ModelSlugs) {
        if ([string]::IsNullOrWhiteSpace($modelSlug)) {
            throw 'Desktop picker model IDs cannot be empty.'
        }
        if (-not $requestedSlugs.Add($modelSlug)) {
            throw "Desktop picker model '$modelSlug' is duplicated."
        }
    }

    $canonicalSlugs = @(
        $Definitions |
            Where-Object { $requestedSlugs.Contains([string]$_.Slug) } |
            ForEach-Object { [string]$_.Slug }
    )
    if ($canonicalSlugs.Count -ne $requestedSlugs.Count) {
        $knownSlugs = @($Definitions | ForEach-Object { [string]$_.Slug })
        $unknownSlugs = @($ModelSlugs | Where-Object { $_ -notin $knownSlugs })
        throw "Desktop picker contains unknown models: $($unknownSlugs -join ', ')."
    }

    $json = [ordered]@{
        version = 1
        modelSlugs = $canonicalSlugs
    } | ConvertTo-Json -Depth 10

    $absoluteSettingsPath = [System.IO.Path]::GetFullPath($SettingsPath)
    if (
        (Test-Path -LiteralPath $absoluteSettingsPath) -and
        -not (Test-Path -LiteralPath $absoluteSettingsPath -PathType Leaf)
    ) {
        throw "Desktop picker settings target is not a file: $absoluteSettingsPath"
    }

    $settingsDirectory = Split-Path -Parent $absoluteSettingsPath
    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $transactionId = [guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $settingsDirectory ".ungate-picker-models.$transactionId.tmp"
    $backupPath = Join-Path $settingsDirectory ".ungate-picker-models.$transactionId.bak"
    $writeCompleted = $false

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json + "`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $absoluteSettingsPath -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $absoluteSettingsPath,
                $backupPath,
                $true
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $absoluteSettingsPath)
        }
        $writeCompleted = $true
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if ($writeCompleted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }

    return $absoluteSettingsPath
}

function Get-UngatePickerModelDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )

    $selectedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($slug in @(
        Read-UngatePickerModelSelection `
            -SettingsPath $SettingsPath `
            -Definitions $Definitions `
            -Capacity $Capacity
    )) {
        [void]$selectedSlugs.Add($slug)
    }

    return @($Definitions | Where-Object { $selectedSlugs.Contains([string]$_.Slug) })
}

function Read-UngatePickerKey {
    $keyInfo = [Console]::ReadKey($true)
    switch ($keyInfo.Key) {
        'UpArrow' { return 'up' }
        'DownArrow' { return 'down' }
        'Spacebar' { return 'toggle' }
        'Enter' { return 'save' }
        'Escape' { return 'cancel' }
        default { return 'none' }
    }
}

function Invoke-UngatePickerConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$Capacity
    )

    if ($Definitions.Count -eq 0) {
        throw 'No models are available for the Desktop picker.'
    }

    $selectedSlugs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($slug in @(
        Read-UngatePickerModelSelection `
            -SettingsPath $SettingsPath `
            -Definitions $Definitions `
            -Capacity $Capacity
    )) {
        [void]$selectedSlugs.Add($slug)
    }

    $cursorIndex = 0
    $statusMessage = $null
    while ($true) {
        Clear-Host
        Write-Host 'Configure Codex Desktop model picker:' -ForegroundColor Cyan
        Write-Host ''
        for ($index = 0; $index -lt $Definitions.Count; $index++) {
            $cursor = if ($index -eq $cursorIndex) { '>' } else { ' ' }
            $checked = if ($selectedSlugs.Contains([string]$Definitions[$index].Slug)) { 'x' } else { ' ' }
            $line = "  $cursor [$checked] $($Definitions[$index].DisplayName)"
            if ($index -eq $cursorIndex) {
                Write-Host $line -ForegroundColor Cyan
            }
            else {
                Write-Host $line
            }
        }
        Write-Host ''
        Write-Host "Selected: $($selectedSlugs.Count)/$Capacity"
        Write-Host 'Up/Down: move  Space: toggle  Enter: save  Esc: cancel' -ForegroundColor DarkGray
        if ($statusMessage) {
            Write-Host $statusMessage -ForegroundColor Yellow
        }

        $statusMessage = $null
        switch (Read-UngatePickerKey) {
            'up' {
                $cursorIndex = if ($cursorIndex -eq 0) { $Definitions.Count - 1 } else { $cursorIndex - 1 }
            }
            'down' {
                $cursorIndex = if ($cursorIndex -eq $Definitions.Count - 1) { 0 } else { $cursorIndex + 1 }
            }
            'toggle' {
                $slug = [string]$Definitions[$cursorIndex].Slug
                if ($selectedSlugs.Contains($slug)) {
                    [void]$selectedSlugs.Remove($slug)
                }
                elseif ($selectedSlugs.Count -ge $Capacity) {
                    $statusMessage = "Select at most $Capacity models. Disable one before adding another."
                }
                else {
                    [void]$selectedSlugs.Add($slug)
                }
            }
            'save' {
                if ($selectedSlugs.Count -eq 0) {
                    $statusMessage = 'Select at least one model.'
                    continue
                }

                $modelSlugs = @(
                    $Definitions |
                        Where-Object { $selectedSlugs.Contains([string]$_.Slug) } |
                        ForEach-Object { [string]$_.Slug }
                )
                $savedPath = Write-UngatePickerModelSelection `
                    -SettingsPath $SettingsPath `
                    -ModelSlugs $modelSlugs `
                    -Definitions $Definitions `
                    -Capacity $Capacity
                Write-Host "[ungate] Desktop picker selection saved: $savedPath" -ForegroundColor Green
                return $true
            }
            'cancel' {
                Write-Host '[ungate] Desktop picker selection unchanged.' -ForegroundColor Yellow
                return $false
            }
        }
    }
}

function Read-UngateMenuChoice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string[]]$Values,
        [Parameter(Mandatory = $true)]
        [int]$DefaultIndex
    )

    while ($true) {
        $choice = Read-Host "$Prompt [1-$($Values.Count)] (default: $($DefaultIndex + 1))"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $Values[$DefaultIndex]
        }

        $selectedNumber = 0
        if (
            [int]::TryParse($choice, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $Values.Count
        ) {
            return $Values[$selectedNumber - 1]
        }

        Write-Host "Enter a number from 1 to $($Values.Count)." -ForegroundColor Yellow
    }
}

function Read-UngateYesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [bool]$Default = $true
    )

    $defaultLabel = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $choice = Read-Host "$Prompt [$defaultLabel]"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $Default
        }
        $choice = $choice.Trim().ToLowerInvariant()
        if ($choice -in @('y', 'yes')) {
            return $true
        }
        if ($choice -in @('n', 'no')) {
            return $false
        }
        Write-Host 'Enter y or n.' -ForegroundColor Yellow
    }
}

function Invoke-AddUngateModelMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions
    )

    $existingDefinitions = @(
        Read-UngateCustomModelDefinitions `
            -RegistryPath $RegistryPath `
            -BuiltInDefinitions $BuiltInDefinitions
    )

    Write-Host ''
    Write-Host 'Add a model to the Codex Beta launcher:' -ForegroundColor Cyan
    $slug = Read-Host 'Model ID (example: ungate-opus-5)'
    $displayName = Read-Host 'Label (example: Claude Opus 5 (Ungate))'
    $upstreamModel = Read-Host 'Upstream model ID (example: claude-opus-5)'

    Write-Host ''
    Write-Host 'Transport:'
    Write-Host '  1) Ungate Proxy'
    Write-Host '  2) CLIProxyAPI'
    Write-Host '  3) OmniRoute'
    $transport = Read-UngateMenuChoice `
        -Prompt 'Transport' `
        -Values @('ungate', 'cliproxyapi', 'omniroute') `
        -DefaultIndex 0

    Write-Host ''
    Write-Host 'Default reasoning level:'
    Write-Host '  1) low'
    Write-Host '  2) medium'
    Write-Host '  3) high'
    Write-Host '  4) xhigh'
    $reasoningLevel = Read-UngateMenuChoice `
        -Prompt 'Reasoning level' `
        -Values @('low', 'medium', 'high', 'xhigh') `
        -DefaultIndex 2
    $supportsImageInput = Read-UngateYesNo -Prompt 'Supports image input?' -Default $true

    $newRecord = [pscustomobject][ordered]@{
        Slug = $slug
        DisplayName = $displayName
        UpstreamModel = $upstreamModel
        Transport = $transport
        DefaultReasoningLevel = $reasoningLevel
        SupportsImageInput = $supportsImageInput
    }
    $candidate = ConvertTo-UngateModelDefinition `
        -Record $newRecord `
        -Priority ($BuiltInDefinitions.Count + $existingDefinitions.Count)
    $allSlugs = @($BuiltInDefinitions.Slug) + @($existingDefinitions.Slug)
    if ($candidate.Slug -in $allSlugs) {
        throw "Model ID '$($candidate.Slug)' already exists."
    }

    Write-Host ''
    Write-Host 'New model:' -ForegroundColor Cyan
    Write-Host "  Model ID:       $($candidate.Slug)"
    Write-Host "  Label:          $($candidate.DisplayName)"
    Write-Host "  Upstream Model: $($candidate.UpstreamModel)"
    Write-Host "  Transport:      $($candidate.ProviderDisplayName)"
    Write-Host "  Reasoning:      $($candidate.DefaultReasoningLevel)"
    Write-Host "  Image input:    $($candidate.SupportsImageInput)"
    Write-Host ''

    if (-not (Read-UngateYesNo -Prompt 'Save this model?' -Default $true)) {
        Write-Host '[ungate] Model addition cancelled.' -ForegroundColor Yellow
        return
    }

    $registryRecords = @($existingDefinitions) + @($newRecord)
    $savedPath = Write-UngateCustomModelDefinitions `
        -RegistryPath $RegistryPath `
        -Records $registryRecords `
        -BuiltInDefinitions $BuiltInDefinitions
    Write-Host "[ungate] Model '$($candidate.Slug)' added: $savedPath" -ForegroundColor Green
    Write-Host '[ungate] Run the launcher normally to select the new model.' -ForegroundColor Green
    return $candidate.Slug
}

function Get-ProviderDefinitions {
    $byName = [ordered]@{}
    foreach ($definition in $UngateModelDefinitions) {
        if (-not $byName.Contains($definition.ProviderName)) {
            $byName[$definition.ProviderName] = [pscustomobject][ordered]@{
                Name = $definition.ProviderName
                DisplayName = $definition.ProviderDisplayName
                ProxyBaseUrl = $definition.ProxyBaseUrl
                EnvKey = $definition.EnvKey
            }
        }
    }
    return @($byName.Values)
}

function Set-CodexModelShellSlugs {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions
    )

    if ($CodexModelShellPool.Count -lt $CodexDesktopPickerCapacity) {
        throw "Codex shell pool has $($CodexModelShellPool.Count) slots, but the picker requires $CodexDesktopPickerCapacity."
    }
    if ($Definitions.Count -gt $CodexDesktopPickerCapacity) {
        throw "Codex Beta can expose at most $CodexDesktopPickerCapacity custom provider models in its native picker. Remove a model or increase the picker capacity."
    }

    $withShellSlugs = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Definitions.Count; $index++) {
        $properties = [ordered]@{}
        foreach ($property in $Definitions[$index].PSObject.Properties) {
            $properties[$property.Name] = $property.Value
        }
        $properties['ShellSlug'] = $CodexModelShellPool[$index]
        [void]$withShellSlugs.Add([pscustomobject]$properties)
    }

    return @($withShellSlugs)
}

function Get-CodexCatalogModelSlug {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition
    )

    if ($EnableProviderFallback) {
        return [string]$Definition.Slug
    }

    if (-not $Definition.PSObject.Properties['ShellSlug'] -or [string]::IsNullOrWhiteSpace($Definition.ShellSlug)) {
        throw "Model '$($Definition.Slug)' does not have a Codex shell model ID."
    }

    return [string]$Definition.ShellSlug
}

function Get-CodexConfigProviderDefinitions {
    if ($EnableProviderFallback) {
        return @(
            [pscustomobject][ordered]@{
                Name = $OmniRouteFallbackModelDefinition.ProviderName
                DisplayName = $OmniRouteFallbackModelDefinition.ProviderDisplayName
                ProxyBaseUrl = $OmniRouteFallbackModelDefinition.ProxyBaseUrl
                EnvKey = $OmniRouteFallbackModelDefinition.EnvKey
            }
        )
    }

    return @($CodexModelShellRouterProviderDefinition)
}

function Get-CodexModelShellRoutes {
    $routes = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $UngateModelDefinitions) {
        $shellSlug = Get-CodexCatalogModelSlug -Definition $definition
        $upstreamModelValue = if ($definition.PSObject.Properties['UpstreamModel'] -and $definition.UpstreamModel) {
            [string]$definition.UpstreamModel
        } else {
            [string]$definition.Slug
        }
        [void]$routes.Add([ordered]@{
            clientModel = $shellSlug
            upstreamModel = $upstreamModelValue
            upstreamBaseUrl = [string]$definition.ProxyBaseUrl
            apiKeyEnv = [string]$definition.EnvKey
            responsesAdapter = if ($definition.PSObject.Properties['ResponsesAdapter']) { [string]$definition.ResponsesAdapter } else { $null }
        })
    }

    return @($routes)
}

function Resolve-CliProxyApiKey {
    if ($env:CLIPROXYAPI_API_KEY) {
        return $env:CLIPROXYAPI_API_KEY
    }

    if (-not (Test-Path -LiteralPath $CliProxyConfigPath)) {
        throw "CLIProxyAPI config not found at $CliProxyConfigPath."
    }

    $lines = Get-Content -LiteralPath $CliProxyConfigPath
    $inApiKeys = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*api-keys:\s*$') {
            $inApiKeys = $true
            continue
        }
        if ($inApiKeys) {
            if ($line -match '^\S') {
                break
            }
            if ($line -match '^\s*-\s*(?:"([^"]+)"|''([^'']+)''|(\S+))\s*$') {
                $key = $Matches[1]
                if (-not $key) { $key = $Matches[2] }
                if (-not $key) { $key = $Matches[3] }
                if ($key) {
                    return $key
                }
            }
        }
    }

    throw "Could not find api-keys in $CliProxyConfigPath. Set CLIPROXYAPI_API_KEY or add api-keys to the config."
}

function Get-CliProxyBridgeHealth {
    try {
        $health = Invoke-RestMethod `
            -Uri "$CliProxyBaseUrl/_bridge/health" `
            -TimeoutSec 2 `
            -ErrorAction Stop
        return $health
    }
    catch {
        return $null
    }
}

function Test-LocalTcpListener {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Test-CliProxyBridgeProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    $process = Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction SilentlyContinue
    if (-not $process -or [string]::IsNullOrWhiteSpace($process.CommandLine)) {
        return $false
    }

    $expectedPath = [System.IO.Path]::GetFullPath($CliProxyBridgePath)
    return $process.CommandLine.IndexOf(
        $expectedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

function Ensure-CliProxyBridge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $CliProxyBridgePath -PathType Leaf)) {
        throw "CLIProxy compatibility bridge not found at $CliProxyBridgePath."
    }

    try {
        $null = Invoke-RestMethod `
            -Uri "$CliProxyUpstreamBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "CLIProxyAPI upstream at $CliProxyUpstreamBaseUrl is not reachable: $($_.Exception.Message)"
    }
    Write-Host "[ungate] CLIProxyAPI upstream healthy at $CliProxyUpstreamBaseUrl." -ForegroundColor Green

    $expectedBuildId = (Get-FileHash -LiteralPath $CliProxyBridgePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedUpstream = $CliProxyUpstreamBaseUrl.TrimEnd('/')
    $bridgeListening = Test-LocalTcpListener -Port 8318
    $health = if ($bridgeListening) { Get-CliProxyBridgeHealth } else { $null }
    $bridgeReady = $false

    if ($health) {
        if ($health.status -ne 'ok' -or $health.service -ne $CliProxyBridgeServiceName) {
            throw "Port 8318 is occupied by an unexpected HTTP service. Refusing to stop it."
        }

        $sameBuild = [string]$health.build_id -eq $expectedBuildId
        $sameUpstream = ([string]$health.upstream).TrimEnd('/') -eq $expectedUpstream
        if ($sameBuild -and $sameUpstream) {
            $bridgeReady = $true
            Write-Host "[ungate] Reusing CLIProxy compatibility bridge (PID $($health.pid))." -ForegroundColor DarkGray
        }
        else {
            $bridgeProcessId = [int]$health.pid
            if (-not (Test-CliProxyBridgeProcessIdentity -ProcessId $bridgeProcessId)) {
                throw "Port 8318 reports a stale bridge, but PID $bridgeProcessId does not run $CliProxyBridgePath. Refusing to stop it."
            }

            Write-Host "[ungate] Restarting stale CLIProxy compatibility bridge (PID $bridgeProcessId)..." -ForegroundColor Yellow
            Stop-Process -Id $bridgeProcessId -Force -ErrorAction Stop
            $stopDeadline = (Get-Date).AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
            } while (
                (Test-LocalTcpListener -Port 8318) -and
                (Get-Date) -lt $stopDeadline
            )
            if (Test-LocalTcpListener -Port 8318) {
                throw 'The stale CLIProxy compatibility bridge did not release port 8318.'
            }
        }
    }
    elseif ($bridgeListening) {
        throw "Port 8318 is occupied, but /_bridge/health did not identify the compatibility bridge. Refusing to stop it."
    }

    if (-not $bridgeReady) {
        $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
        if (-not $nodeCommand -or -not (Test-Path -LiteralPath $nodeCommand.Source -PathType Leaf)) {
            throw 'node.exe is required to run the CLIProxy compatibility bridge.'
        }

        $logDirectory = Join-Path $CustomCodexHome 'logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $stdoutPath = Join-Path $logDirectory 'cliproxy-namespace-bridge.out.log'
        $stderrPath = Join-Path $logDirectory 'cliproxy-namespace-bridge.err.log'
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

        $bridgeEnvironment = @{
            CLIPROXY_BRIDGE_HOST = '127.0.0.1'
            CLIPROXY_BRIDGE_PORT = '8318'
            CLIPROXY_UPSTREAM = $CliProxyUpstreamBaseUrl
            CLIPROXY_BRIDGE_BUILD_ID = $expectedBuildId
            CLIPROXY_BRIDGE_MAX_BODY_BYTES = '134217728'
            CLIPROXY_BRIDGE_MAX_INPUT_TOKENS = '500000'
        }
        $bridgeProcess = Start-Process `
            -FilePath ([string]$nodeCommand.Source) `
            -ArgumentList @("`"$CliProxyBridgePath`"") `
            -WorkingDirectory $RepoRoot `
            -WindowStyle Hidden `
            -Environment $bridgeEnvironment `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru

        $startDeadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 200
            $bridgeProcess.Refresh()
            if ($bridgeProcess.HasExited) {
                $bridgeError = Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue
                throw "CLIProxy compatibility bridge exited with code $($bridgeProcess.ExitCode). $($bridgeError -join ' ')"
            }
            $health = Get-CliProxyBridgeHealth
        } while (-not $health -and (Get-Date) -lt $startDeadline)

        if (
            -not $health -or
            $health.status -ne 'ok' -or
            $health.service -ne $CliProxyBridgeServiceName -or
            [string]$health.build_id -ne $expectedBuildId -or
            ([string]$health.upstream).TrimEnd('/') -ne $expectedUpstream
        ) {
            Stop-Process -Id $bridgeProcess.Id -Force -ErrorAction SilentlyContinue
            throw "CLIProxy compatibility bridge failed its startup health check at $CliProxyBaseUrl."
        }
        Write-Host "[ungate] CLIProxy compatibility bridge started at $CliProxyBaseUrl (PID $($health.pid))." -ForegroundColor Green
    }

    try {
        $null = Invoke-RestMethod `
            -Uri "$CliProxyBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "CLIProxy compatibility bridge could not proxy /v1/models: $($_.Exception.Message)"
    }
    Write-Host '[ungate] CLIProxy compatibility bridge proxy check passed.' -ForegroundColor Green
}

function Get-CodexModelShellRouterHealth {
    try {
        return Invoke-RestMethod `
            -Uri "$CodexModelShellRouterBaseUrl/_shell-router/health" `
            -TimeoutSec 2 `
            -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-CodexModelShellRouterProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    $process = Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction SilentlyContinue
    if (-not $process -or [string]::IsNullOrWhiteSpace($process.CommandLine)) {
        return $false
    }

    $expectedPath = [System.IO.Path]::GetFullPath($CodexModelShellRouterPath)
    return $process.CommandLine.IndexOf(
        $expectedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

function Ensure-CodexModelShellRouter {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Routes,
        [Parameter(Mandatory = $true)]
        [hashtable]$ProviderKeys
    )

    if (-not (Test-Path -LiteralPath $CodexModelShellRouterPath -PathType Leaf)) {
        throw "Codex model-shell router not found at $CodexModelShellRouterPath."
    }

    $routerPort = ([uri]$CodexModelShellRouterBaseUrl).Port
    $routerListening = Test-LocalTcpListener -Port $routerPort
    $health = if ($routerListening) { Get-CodexModelShellRouterHealth } else { $null }
    if ($health) {
        if ($health.status -ne 'ok' -or $health.service -ne $CodexModelShellRouterServiceName) {
            throw "Port $routerPort is occupied by an unexpected HTTP service. Refusing to stop it."
        }

        $routerProcessId = [int]$health.pid
        if (-not (Test-CodexModelShellRouterProcessIdentity -ProcessId $routerProcessId)) {
            throw "Port $routerPort reports the model-shell router, but PID $routerProcessId does not run $CodexModelShellRouterPath. Refusing to stop it."
        }

        Write-Host "[ungate] Restarting Codex model-shell router (PID $routerProcessId) to refresh model routes." -ForegroundColor DarkGray
        Stop-Process -Id $routerProcessId -Force -ErrorAction Stop
        $stopDeadline = (Get-Date).AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
        } while (
            (Test-LocalTcpListener -Port $routerPort) -and
            (Get-Date) -lt $stopDeadline
        )
        if (Test-LocalTcpListener -Port $routerPort) {
            throw "The Codex model-shell router did not release port $routerPort."
        }
    }
    elseif ($routerListening) {
        throw "Port $routerPort is occupied, but /_shell-router/health did not identify the Codex model-shell router. Refusing to stop it."
    }

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCommand -or -not (Test-Path -LiteralPath $nodeCommand.Source -PathType Leaf)) {
        throw 'node.exe is required to run the Codex model-shell router.'
    }

    $routerEnvironment = @{
        CODEX_SHELL_ROUTER_HOST = '127.0.0.1'
        CODEX_SHELL_ROUTER_PORT = [string]$routerPort
        CODEX_SHELL_ROUTER_BUILD_ID = (Get-FileHash -LiteralPath $CodexModelShellRouterPath -Algorithm SHA256).Hash.ToLowerInvariant()
        CODEX_SHELL_ROUTER_MAX_BODY_BYTES = '134217728'
        CODEX_SHELL_ROUTER_ROUTES_JSON = ([ordered]@{ routes = @($Routes) } | ConvertTo-Json -Depth 20 -Compress)
    }
    foreach ($provider in (Get-ProviderDefinitions)) {
        $providerKey = $ProviderKeys[$provider.Name]
        if ([string]::IsNullOrWhiteSpace($providerKey)) {
            throw "Missing API key for model-shell route provider '$($provider.Name)'."
        }
        $routerEnvironment[$provider.EnvKey] = $providerKey
    }

    $logDirectory = Join-Path $CustomCodexHome 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $stdoutPath = Join-Path $logDirectory 'codex-model-shell-router.out.log'
    $stderrPath = Join-Path $logDirectory 'codex-model-shell-router.err.log'
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $routerProcess = Start-Process `
        -FilePath ([string]$nodeCommand.Source) `
        -ArgumentList @("`"$CodexModelShellRouterPath`"") `
        -WorkingDirectory $RepoRoot `
        -WindowStyle Hidden `
        -Environment $routerEnvironment `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    $startDeadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        $routerProcess.Refresh()
        if ($routerProcess.HasExited) {
            $routerError = Get-Content -LiteralPath $stderrPath -Tail 20 -ErrorAction SilentlyContinue
            throw "Codex model-shell router exited with code $($routerProcess.ExitCode). $($routerError -join ' ')"
        }
        $health = Get-CodexModelShellRouterHealth
    } while (-not $health -and (Get-Date) -lt $startDeadline)

    $expectedShells = @($Routes | ForEach-Object { [string]$_.clientModel })
    $actualShells = @($health.route_models | ForEach-Object { [string]$_ })
    $sameShells = (
        $health -and
        $health.status -eq 'ok' -and
        $health.service -eq $CodexModelShellRouterServiceName -and
        $actualShells.Count -eq $expectedShells.Count -and
        -not (Compare-Object -ReferenceObject $expectedShells -DifferenceObject $actualShells)
    )
    if (-not $sameShells) {
        Stop-Process -Id $routerProcess.Id -Force -ErrorAction SilentlyContinue
        throw "Codex model-shell router failed its startup health check at $CodexModelShellRouterBaseUrl."
    }

    Write-Host "[ungate] Codex model-shell router ready at $CodexModelShellRouterBaseUrl (PID $($health.pid))." -ForegroundColor Green
}

function Resolve-ModelApiKey {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition,
        [string]$ApiKey
    )

    if ($Definition.ProviderName -eq $OmniRouteProviderName) {
        if ($ApiKey) {
            return $ApiKey
        }
        if ($env:OMNIROUTE_CODEX_API_KEY) {
            return $env:OMNIROUTE_CODEX_API_KEY
        }
        if ($env:OMNIROUTE_API_KEY) {
            return $env:OMNIROUTE_API_KEY
        }

        throw 'OmniRoute client key is required. Pass -ApiKey or set OMNIROUTE_CODEX_API_KEY (preferred) or OMNIROUTE_API_KEY (legacy fallback).'
    }

    if ($Definition.RequiresUngate) {
        return Resolve-UngateApiKey -ApiKey $ApiKey -RepoRoot $RepoRoot
    }

    if ($ApiKey) {
        return $ApiKey
    }

    return Resolve-CliProxyApiKey
}

function Invoke-OmniRoutePreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$ProxyBaseUrl
    )

    try {
        $health = Invoke-RestMethod `
            -Uri "$ProxyBaseUrl/api/health/ping" `
            -TimeoutSec 3 `
            -ErrorAction Stop
        if ($health.status -ne 'ok') {
            throw 'health.status != ok'
        }
    }
    catch {
        throw "OmniRoute is not reachable at $ProxyBaseUrl. Start OmniRoute manually, then retry with -EnableProviderFallback."
    }
    Write-Host "[ungate] OmniRoute healthy at $ProxyBaseUrl." -ForegroundColor Green

    try {
        $models = Invoke-RestMethod `
            -Uri "$ProxyBaseUrl/v1/models" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
    }
    catch {
        throw "Could not list OmniRoute /v1/models. Verify OMNIROUTE_CODEX_API_KEY and the codex-local key permissions: $($_.Exception.Message)"
    }

    $ids = @($models.data | ForEach-Object { $_.id })
    $effectiveModel = if ($Model -in $ids) {
        $Model
    } elseif ("deepseek/$Model" -in $ids) {
        "deepseek/$Model"
    } elseif ("ds/$Model" -in $ids) {
        "ds/$Model"
    } else {
        throw "OmniRoute model or combo '$Model' was not found in /v1/models. Configure the model before launching."
    }
    Write-Host "[ungate] OmniRoute model or combo '$Model' available." -ForegroundColor Green

    $body = [ordered]@{
        model = $effectiveModel
        input = 'Reply with exactly OK.'
        max_output_tokens = 512
        stream = $false
        store = $false
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri "$ProxyBaseUrl/v1/responses" `
            -Headers @{ Authorization = "Bearer $Key" } `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec 60 `
            -SkipHttpErrorCheck `
            -ErrorAction Stop
    }
    catch {
        throw "Could not reach OmniRoute /v1/responses: $($_.Exception.Message)"
    }

    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        $detail = Get-CliProxyHttpErrorDetail -Content ([string]$response.Content)
        throw "OmniRoute /v1/responses preflight failed with HTTP ${statusCode}: $detail"
    }

    try {
        $payload = ([string]$response.Content) | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "OmniRoute /v1/responses returned invalid JSON: $($_.Exception.Message)"
    }
    if (-not $payload.id -and -not $payload.output) {
        throw "OmniRoute /v1/responses returned an unexpected response for '$Model'."
    }

    Write-Host "[ungate] Live OmniRoute /v1/responses preflight passed for '$Model'." -ForegroundColor Green
}

function Get-ProviderTomlBlock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Provider
    )

    return @"

[model_providers.$($Provider.Name)]
name = "$($Provider.DisplayName)"
base_url = "$($Provider.ProxyBaseUrl)/v1"
env_key = "$($Provider.EnvKey)"
wire_api = "responses"
"@
}

function Ensure-ModelProvidersInConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $updated = $Content
    $managedProviderNames = @(
        $ProviderName,
        $CliProxyProviderName,
        $OmniRouteProviderName,
        $CodexModelShellRouterProviderName
    )
    foreach ($providerNameToRemove in $managedProviderNames) {
        $updated = Remove-TomlTable -Content $updated -TableName "model_providers.$providerNameToRemove"
    }
    foreach ($provider in (Get-CodexConfigProviderDefinitions)) {
        $updated = Remove-TomlTable -Content $updated -TableName "model_providers.$($provider.Name)"
        $updated = $updated.TrimEnd() + "`r`n" + (Get-ProviderTomlBlock -Provider $provider).TrimStart() + "`r`n"
    }
    return $updated
}

function Get-UngateModelContextWindow {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Definition
    )

    $contextWindow = if (
        $Definition.PSObject.Properties['ContextWindow'] -and
        $null -ne $Definition.ContextWindow
    ) {
        [int]$Definition.ContextWindow
    }
    else {
        200000
    }
    $maxContextWindow = if (
        $Definition.PSObject.Properties['MaxContextWindow'] -and
        $null -ne $Definition.MaxContextWindow
    ) {
        [int]$Definition.MaxContextWindow
    }
    else {
        200000
    }
    $percent = if (
        $Definition.PSObject.Properties['EffectiveContextWindowPercent'] -and
        $null -ne $Definition.EffectiveContextWindowPercent
    ) {
        [int]$Definition.EffectiveContextWindowPercent
    }
    else {
        100
    }

    $compact = if ($contextWindow -ge 1000000 -and ($contextWindow % 1000000) -eq 0) {
        '{0}M' -f [int]($contextWindow / 1000000)
    }
    elseif ($contextWindow -ge 1000 -and ($contextWindow % 1000) -eq 0) {
        '{0}k' -f [int]($contextWindow / 1000)
    }
    else {
        [string]$contextWindow
    }

    $label = if ($percent -ne 100) {
        '{0} @ {1}%' -f $compact, $percent
    }
    else {
        $compact
    }

    return [pscustomobject][ordered]@{
        ContextWindow = $contextWindow
        MaxContextWindow = $maxContextWindow
        EffectiveContextWindowPercent = $percent
        Label = $label
    }
}

function Read-UngateLogSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    $defaultSettings = [pscustomobject]@{
        LogLevel = 'Standard'
    }

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $defaultSettings
    }

    try {
        $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $defaultSettings
        }
        $parsed = $raw | ConvertFrom-Json
        $validLevels = @('Full', 'Standard', 'Compact', 'Minimal', 'Off')
        $level = if ($parsed.LogLevel -and $validLevels -contains [string]$parsed.LogLevel) {
            [string]$parsed.LogLevel
        } else {
            'Standard'
        }
        return [pscustomobject]@{
            LogLevel = $level
        }
    }
    catch {
        return $defaultSettings
    }
}

function Write-UngateLogSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off')]
        [string]$LogLevel
    )

    $parent = [System.IO.Path]::GetDirectoryName($SettingsPath)
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    $settings = [pscustomobject]@{
        LogLevel = $LogLevel
    }
    $json = $settings | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($SettingsPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

function Invoke-UngateLoggingMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    $current = (Read-UngateLogSettings -SettingsPath $SettingsPath).LogLevel

    while ($true) {
        Write-Host ''
        Write-Host '--- Live Terminal Log Level ---' -ForegroundColor Cyan
        Write-Host "Current level: $current" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  1) Full      - All events, reasoning, full tool output (no truncation), router logs'
        Write-Host '  2) Standard  - Default: reasoning, tool calls/output (truncated to 800 chars), agent text, router logs'
        Write-Host '  3) Compact   - Hide reasoning [THINK], short tool output (400 chars), agent text, router logs'
        Write-Host '  4) Minimal   - Clean summary: user, single-line tool calls, agent text only (no think, no output, no router)'
        Write-Host '  5) Off       - Disable terminal log stream completely (detach immediately to prompt)'
        Write-Host '  B) Back to main menu'
        Write-Host ''

        $choice = Read-Host 'Select log level [1-5 or B] (default: keep current)'
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $current
        }

        $chosen = switch ($choice.Trim()) {
            '1' { 'Full' }
            '2' { 'Standard' }
            '3' { 'Compact' }
            '4' { 'Minimal' }
            '5' { 'Off' }
            default { $null }
        }

        if ($chosen) {
            Write-UngateLogSettings -SettingsPath $SettingsPath -LogLevel $chosen
            Write-Host "  [x] Log level updated to: $chosen" -ForegroundColor Green
            return $chosen
        }

        Write-Host 'Invalid choice. Enter 1-5 or B.' -ForegroundColor Yellow
    }
}

function Select-UngateDesktopModel {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Definitions,
        [Parameter(Mandatory = $true)]
        [object[]]$BuiltInDefinitions,
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,
        [Parameter(Mandatory = $true)]
        [string]$PickerSettingsPath,
        [Parameter(Mandatory = $true)]
        [int]$PickerCapacity,
        [string]$LogSettingsPath,
        [switch]$IncludeProviderFallback,
        [string]$ProviderFallbackModel = 'codex-fallback'
    )

    if ([string]::IsNullOrWhiteSpace($LogSettingsPath)) {
        $parentDir = Split-Path $PickerSettingsPath -Parent
        $LogSettingsPath = Join-Path $parentDir 'ungate-log-settings.json'
    }

    while ($true) {
        $pickerDefinitions = @(
            Get-UngatePickerModelDefinitions `
                -Definitions $Definitions `
                -SettingsPath $PickerSettingsPath `
                -Capacity $PickerCapacity
        )
        Write-Host ''
        Write-Host 'Select a mode for Codex Beta:' -ForegroundColor Cyan
        for ($index = 0; $index -lt $pickerDefinitions.Count; $index++) {
            $defaultLabel = if ($index -eq 0) { ' (default)' } else { '' }
            $contextLabel = (Get-UngateModelContextWindow -Definition $pickerDefinitions[$index]).Label
            Write-Host ("  {0}) {1}{2}  [{3}]" -f ($index + 1), $pickerDefinitions[$index].DisplayName, $defaultLabel, $contextLabel)
        }
        $configurePickerIndex = $pickerDefinitions.Count + 1
        Write-Host ("  {0}) Configure Desktop model picker" -f $configurePickerIndex) -ForegroundColor DarkCyan
        $providerFallbackIndex = if ($IncludeProviderFallback) { $configurePickerIndex + 1 } else { $null }
        if ($IncludeProviderFallback) {
            Write-Host (
                "  {0}) [ ] Enable provider fallback (OmniRoute) — Claude → Grok → MiniMax → Gemini" -f
                    $providerFallbackIndex
            ) -ForegroundColor Yellow
        }
        $addModelIndex = $configurePickerIndex + $(if ($IncludeProviderFallback) { 2 } else { 1 })
        Write-Host ("  {0}) Add a new model" -f $addModelIndex) -ForegroundColor DarkCyan

        $currentLogLevel = (Read-UngateLogSettings -SettingsPath $LogSettingsPath).LogLevel
        $loggingMenuIndex = $addModelIndex + 1
        Write-Host ("  {0}) Configure live logging [Current: {1}]" -f $loggingMenuIndex, $currentLogLevel) -ForegroundColor DarkCyan
        Write-Host ''

        $fallbackHint = if ($IncludeProviderFallback) { ' or F' } else { '' }
        $choicePrompt = "Mode [1-$loggingMenuIndex$fallbackHint or L] (default: 1)"
        $choice = Read-Host $choicePrompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $pickerDefinitions[0].Slug
        }

        if ($IncludeProviderFallback -and $choice.Trim().Equals('f', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host '  [x] Provider fallback enabled.' -ForegroundColor Green
            return $ProviderFallbackModel
        }

        if ($choice.Trim().Equals('l', [System.StringComparison]::OrdinalIgnoreCase)) {
            $null = Invoke-UngateLoggingMenu -SettingsPath $LogSettingsPath
            continue
        }

        $selectedNumber = 0
        if (
            [int]::TryParse($choice, [ref]$selectedNumber) -and
            $selectedNumber -ge 1 -and
            $selectedNumber -le $loggingMenuIndex
        ) {
            if ($selectedNumber -le $pickerDefinitions.Count) {
                return $pickerDefinitions[$selectedNumber - 1].Slug
            }

            if ($selectedNumber -eq $configurePickerIndex) {
                $null = Invoke-UngatePickerConfiguration `
                    -Definitions $Definitions `
                    -SettingsPath $PickerSettingsPath `
                    -Capacity $PickerCapacity
                continue
            }

            if ($IncludeProviderFallback -and $selectedNumber -eq $providerFallbackIndex) {
                Write-Host '  [x] Provider fallback enabled.' -ForegroundColor Green
                return $ProviderFallbackModel
            }

            if ($selectedNumber -eq $addModelIndex) {
                $addedModelSlug = Invoke-AddUngateModelMode `
                    -RegistryPath $RegistryPath `
                    -BuiltInDefinitions $BuiltInDefinitions
                if ($addedModelSlug) {
                    $Definitions = @(
                        Get-UngateModelDefinitions `
                            -BuiltInDefinitions $BuiltInDefinitions `
                            -RegistryPath $RegistryPath
                    )
                    $null = Invoke-UngatePickerConfiguration `
                        -Definitions $Definitions `
                        -SettingsPath $PickerSettingsPath `
                        -Capacity $PickerCapacity
                }
                continue
            }

            if ($selectedNumber -eq $loggingMenuIndex) {
                $null = Invoke-UngateLoggingMenu -SettingsPath $LogSettingsPath
                continue
            }
        }

        Write-Host "Enter a number from 1 to $loggingMenuIndex$fallbackHint or L." -ForegroundColor Yellow
    }
}

function Set-TopLevelTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$TomlValue
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split '\r?\n'))
    $firstTableIndex = $lines.Count
    $found = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[') {
            $firstTableIndex = $index
            break
        }
        if ($lines[$index] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$index] = "$Key = $TomlValue"
            $found = $true
            break
        }
    }

    if (-not $found) {
        $lines.Insert($firstTableIndex, "$Key = $TomlValue")
    }

    return $lines -join "`r`n"
}

function Remove-TomlTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $skip = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches[1].Trim()
            if ($currentTable -eq $TableName -or $currentTable.StartsWith("$TableName.")) {
                $skip = $true
                continue
            }
            $skip = $false
        }

        if (-not $skip) {
            $result.Add($line)
        }
    }

    return $result -join "`r`n"
}

function Get-TomlTableFamilyContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $capture = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches[1].Trim()
            $capture = (
                $currentTable -eq $TableName -or
                $currentTable.StartsWith("$TableName.", [System.StringComparison]::Ordinal)
            )
        }

        if ($capture) {
            $result.Add($line)
        }
    }

    return ($result -join "`r`n").Trim()
}

function Get-CodexHistoryProfileInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HomePath,
        [Parameter(Mandatory = $true)]
        [string]$CanonicalHomePath,
        [Parameter(Mandatory = $true)]
        [string]$ModelSlug,
        [Parameter(Mandatory = $true)]
        [string]$ProviderName
    )

    $normalizedHome = Normalize-CodexHomePath -PathValue $HomePath
    $normalizedCanonicalHome = Normalize-CodexHomePath -PathValue $CanonicalHomePath

    return [pscustomobject][ordered]@{
        ModelSlug = $ModelSlug
        ProviderName = $ProviderName
        CodexHome = $normalizedHome
        SessionsPath = Join-Path $normalizedHome 'sessions'
        StatePath = Join-Path $normalizedHome 'state_5.sqlite'
        IsCanonical = [string]::Equals(
            $normalizedHome,
            $normalizedCanonicalHome,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }
}

function Write-CodexHistoryProfileDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Profile
    )

    Write-Host "[ungate] CODEX_HOME (launcher history): $($Profile.CodexHome)" -ForegroundColor Cyan
    Write-Host "[ungate] Session history directory: $($Profile.SessionsPath)" -ForegroundColor DarkGray
    Write-Host "[ungate] Session state database: $($Profile.StatePath)" -ForegroundColor DarkGray
    Write-Host "[ungate] Normal Codex profile remains separate: $DefaultCodexHome" -ForegroundColor DarkGray
    Write-Host "[ungate] Selected model/provider: $($Profile.ModelSlug) / $($Profile.ProviderName)." -ForegroundColor DarkGray

    if (-not $Profile.IsCanonical) {
        Write-Host `
            "[ungate] Warning: -CustomCodexHome is not the shared default '$CanonicalCodexHome'. This launch uses a separate history." `
            -ForegroundColor Yellow
    }
}

function Initialize-UngateCodexConfig {
    if (Test-Path -LiteralPath $CustomConfigPath) {
        Write-Host "[ungate] Using existing custom config: $CustomConfigPath" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $DefaultConfigPath)) {
        throw "Default Codex config not found at $DefaultConfigPath."
    }

    New-Item -ItemType Directory -Path $CustomCodexHome -Force | Out-Null

    $config = Get-Content -LiteralPath $DefaultConfigPath -Raw
    $config = Set-TopLevelTomlValue -Content $config -Key 'model' -TomlValue "`"$CodexLaunchModel`""
    $config = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model_provider' `
        -TomlValue "`"$($CodexLaunchProvider.Name)`""
    $config = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model_reasoning_effort' `
        -TomlValue "`"$($selectedModelDefinition.DefaultReasoningLevel)`""
    $config = Ensure-ModelProvidersInConfig -Content $config
    [System.IO.File]::WriteAllText(
        $CustomConfigPath,
        $config,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "[ungate] Created custom config: $CustomConfigPath" -ForegroundColor Green
}

function Set-ModelIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instructions,
        [Parameter(Mandatory = $true)]
        [string]$Identity
	)

	$firstLine = [regex]::new('\A[^\r\n]*(?:\r?\n)?')
	$replacement = [System.Text.RegularExpressions.MatchEvaluator]{
		param([System.Text.RegularExpressions.Match]$Match)

		return "$Identity`r`n"
	}

	return $firstLine.Replace($Instructions, $replacement, 1)
}

function Write-UngateModelCatalog {
    $catalogTemplatePath = if (Test-Path -LiteralPath $DefaultModelCachePath -PathType Leaf) {
        $DefaultModelCachePath
    } elseif (Test-Path -LiteralPath $CustomModelCatalogPath -PathType Leaf) {
        # Cockpit-managed normal profiles do not always retain a default
        # models_cache.json. A prior launcher catalog has the same schema and
        # is safe as the template for replacing its managed entries.
        $CustomModelCatalogPath
    } else {
        throw "No Codex model catalog template was found at $DefaultModelCachePath or $CustomModelCatalogPath. Launch normal Codex Desktop once, then retry."
    }

    $defaultCatalog = Get-Content -LiteralPath $catalogTemplatePath -Raw |
        ConvertFrom-Json -Depth 100
    $fallbackModelTemplate = $defaultCatalog.models |
        Where-Object { $_.slug -eq 'gpt-5.4' } |
        Select-Object -First 1
    if (-not $fallbackModelTemplate) {
        $fallbackModelTemplate = $defaultCatalog.models | Select-Object -First 1
    }
    if (-not $fallbackModelTemplate) {
        throw "Codex model catalog template at $catalogTemplatePath contains no models."
    }

    $catalogModels = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $UngateModelDefinitions) {
        $catalogSlug = Get-CodexCatalogModelSlug -Definition $definition
        $modelTemplate = $defaultCatalog.models |
            Where-Object { $_.slug -eq $catalogSlug } |
            Select-Object -First 1
        if (-not $modelTemplate) {
            $modelTemplate = $fallbackModelTemplate
        }
        $modelInfo = $modelTemplate |
            ConvertTo-Json -Depth 100 |
            ConvertFrom-Json -Depth 100
        $supportsParallelToolCalls = if ($null -ne $definition.SupportsParallelToolCalls) {
            [bool]$definition.SupportsParallelToolCalls
        }
        elseif ($modelInfo.PSObject.Properties['supports_parallel_tool_calls']) {
            [bool]$modelInfo.supports_parallel_tool_calls
        }
        else {
            # The Codex model-catalog schema requires this field even when the
            # models cache used as a template omits it. Prefer a conservative
            # serial-tool fallback for custom providers.
            $false
        }
        $contextWindow = Get-UngateModelContextWindow -Definition $definition
        $overrides = [ordered]@{
            slug = $catalogSlug
            display_name = $definition.DisplayName
            description = $definition.Description
            default_reasoning_level = $definition.DefaultReasoningLevel
            visibility = 'list'
            supported_in_api = $true
            priority = $definition.Priority
            additional_speed_tiers = @()
            service_tiers = @()
            default_service_tier = $null
            availability_nux = $null
            upgrade = $null
            supports_reasoning_summaries = if ($null -ne $definition.SupportsReasoningSummaries) { [bool]$definition.SupportsReasoningSummaries } else { $false }
            default_reasoning_summary = 'none'
            support_verbosity = $false
            default_verbosity = $null
            context_window = $contextWindow.ContextWindow
            max_context_window = $contextWindow.MaxContextWindow
            effective_context_window_percent = $contextWindow.EffectiveContextWindowPercent
            auto_compact_token_limit = $null
            comp_hash = $null
            supports_search_tool = $false
            use_responses_lite = $false
            input_modalities = @($definition.InputModalities)
            supports_parallel_tool_calls = $supportsParallelToolCalls
            supports_image_detail_original = [bool]$definition.SupportsImageDetailOriginal
            web_search_tool_type = [string]$definition.WebSearchToolType
        }

        $baseInstructions = if (
            $modelInfo.PSObject.Properties['base_instructions'] -and
            -not [string]::IsNullOrWhiteSpace([string]$modelInfo.base_instructions)
        ) {
            [string]$modelInfo.base_instructions
        }
        else {
            $null
        }
        $instructionsTemplate = if (
            $modelInfo.model_messages -and
            -not [string]::IsNullOrWhiteSpace([string]$modelInfo.model_messages.instructions_template)
        ) {
            [string]$modelInfo.model_messages.instructions_template
        }
        else {
            $null
        }
        if (-not $baseInstructions -and -not $instructionsTemplate) {
            throw "Codex model catalog template for '$catalogSlug' has no usable instruction template."
        }

        # Newer catalog caches put instructions in model_messages, while the
        # currently installed Codex CLI still requires base_instructions. Keep
        # both fields aligned, deriving the legacy field from the template.
        $baseInstructionSource = if ($baseInstructions) {
            $baseInstructions
        }
        else {
            $instructionsTemplate
        }
        $overrides.base_instructions = Set-ModelIdentity `
            -Instructions $baseInstructionSource `
            -Identity $definition.Identity

        if ($null -ne $definition.TruncationPolicy) {
            $overrides.truncation_policy = $definition.TruncationPolicy
        }
        if ($null -ne $definition.SupportedReasoningLevels) {
            $overrides.supported_reasoning_levels = $definition.SupportedReasoningLevels
        }
        foreach ($override in $overrides.GetEnumerator()) {
            $modelInfo | Add-Member `
                -MemberType NoteProperty `
                -Name $override.Key `
                -Value $override.Value `
                -Force
        }

        if ($instructionsTemplate) {
            $modelInfo.model_messages.instructions_template = Set-ModelIdentity `
                -Instructions $instructionsTemplate `
                -Identity $definition.Identity
        }

        [void]$catalogModels.Add($modelInfo)
    }

    $catalog = [ordered]@{ models = @($catalogModels) }
    $json = $catalog | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $CustomModelCatalogPath,
        $json + "`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    $config = Get-Content -LiteralPath $CustomConfigPath -Raw
    $escapedCatalogPath = $CustomModelCatalogPath.Replace('\', '\\').Replace('"', '\"')
    $catalogPathToml = "`"$escapedCatalogPath`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $config `
        -Key 'model' `
        -TomlValue "`"$CodexLaunchModel`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_provider' `
        -TomlValue "`"$($CodexLaunchProvider.Name)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_reasoning_effort' `
        -TomlValue "`"$($selectedModelDefinition.DefaultReasoningLevel)`""
    $updatedConfig = Set-TopLevelTomlValue `
        -Content $updatedConfig `
        -Key 'model_catalog_json' `
        -TomlValue $catalogPathToml
    $updatedConfig = Ensure-ModelProvidersInConfig -Content $updatedConfig
    if ($updatedConfig -ne $config) {
        [System.IO.File]::WriteAllText(
            $CustomConfigPath,
            $updatedConfig,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    Write-Host "[ungate] Model catalog ready: $CustomModelCatalogPath" -ForegroundColor Green
}

function Ensure-SharedDirectory {
    param([Parameter(Mandatory = $true)][string]$Name)

    $source = Join-Path $DefaultCodexHome $Name
    $target = Join-Path $CustomCodexHome $Name
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
    $sourceInstructions = Join-Path $DefaultCodexHome 'AGENTS.md'
    $targetInstructions = Join-Path $CustomCodexHome 'AGENTS.md'

    if (-not (Test-Path -LiteralPath $sourceInstructions -PathType Leaf)) {
        throw "Default Codex global instructions not found at $sourceInstructions."
    }
    if (
        (Test-Path -LiteralPath $targetInstructions) -and
        -not (Test-Path -LiteralPath $targetInstructions -PathType Leaf)
    ) {
        throw "Custom Codex global instructions target is not a file: $targetInstructions"
    }

    New-Item -ItemType Directory -Path $CustomCodexHome -Force | Out-Null
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
    $sourceAuth = Join-Path $DefaultCodexHome 'auth.json'
    if (Test-Path -LiteralPath $sourceAuth) {
        Copy-Item -LiteralPath $sourceAuth -Destination (Join-Path $CustomCodexHome 'auth.json') -Force
    }
}

function Get-CodexCliExecutable {
    $candidatePaths = [System.Collections.Generic.List[string]]::new()

    foreach ($configPath in @($DefaultConfigPath, $CustomConfigPath)) {
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

function Test-CodexMcpConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexExecutable,
        [Parameter(Mandatory = $true)]
        [string]$CodexHome
    )

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
        [Parameter(Mandatory = $true)]
        [string]$SourceCodexHome,
        [Parameter(Mandatory = $true)]
        [string]$TargetCodexHome,
        [string]$BetaOnlyMcpContent = ''
    )

    $sourceConfigPath = Join-Path $SourceCodexHome 'config.toml'
    $targetConfigPath = Join-Path $TargetCodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)) {
        throw "Default Codex config not found at $sourceConfigPath."
    }
    if (-not (Test-Path -LiteralPath $targetConfigPath -PathType Leaf)) {
        throw "Custom Codex config not found at $targetConfigPath."
    }

    $codexExecutable = Get-CodexCliExecutable
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

function Assert-UngateCodexConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [hashtable]$ProviderKeys
    )

    $config = Get-Content -LiteralPath $CustomConfigPath -Raw
    $selectedProvider = $CodexLaunchProvider.Name
    $selectedBaseUrl = $CodexLaunchProvider.ProxyBaseUrl
    $selectedEnvKey = $CodexLaunchProvider.EnvKey
    $checks = @(
        "(?m)^model\s*=\s*`"$([regex]::Escape($CodexLaunchModel))`"\s*$",
        "(?m)^model_provider\s*=\s*`"$([regex]::Escape($selectedProvider))`"\s*$",
        '(?m)^model_catalog_json\s*=',
        "(?m)^\[model_providers\.$([regex]::Escape($selectedProvider))\]\s*$",
        "(?m)^base_url\s*=\s*`"$([regex]::Escape($selectedBaseUrl))/v1`"\s*$",
        "(?m)^env_key\s*=\s*`"$([regex]::Escape($selectedEnvKey))`"\s*$",
        '(?m)^wire_api\s*=\s*"responses"\s*$'
    )

    foreach ($pattern in $checks) {
        if ($config -notmatch $pattern) {
            throw "Custom Codex config failed validation: $CustomConfigPath"
        }
    }

    foreach ($provider in (Get-CodexConfigProviderDefinitions)) {
        $providerChecks = @(
            "(?m)^\[model_providers\.$([regex]::Escape($provider.Name))\]\s*$",
            "(?m)^base_url\s*=\s*`"$([regex]::Escape($provider.ProxyBaseUrl))/v1`"\s*$",
            "(?m)^env_key\s*=\s*`"$([regex]::Escape($provider.EnvKey))`"\s*$"
        )
        foreach ($pattern in $providerChecks) {
            if ($config -notmatch $pattern) {
                throw "Provider '$($provider.Name)' missing/invalid in custom config: $CustomConfigPath"
            }
        }
    }

    $catalog = Get-Content -LiteralPath $CustomModelCatalogPath -Raw |
        ConvertFrom-Json -Depth 100
    $catalogModels = @($catalog.models)
    if ($catalogModels.Count -ne $UngateModelDefinitions.Count) {
        throw "Custom model catalog failed validation: $CustomModelCatalogPath"
    }
    foreach ($definition in $UngateModelDefinitions) {
        $catalogSlug = Get-CodexCatalogModelSlug -Definition $definition
        $catalogModel = $catalogModels |
            Where-Object { $_.slug -eq $catalogSlug } |
            Select-Object -First 1
        $catalogModalities = @($catalogModel.input_modalities | ForEach-Object { [string]$_ })
        $expectedModalities = @($definition.InputModalities | ForEach-Object { [string]$_ })
        $modalitiesMatch = (
            $catalogModalities.Count -eq $expectedModalities.Count -and
            -not (Compare-Object -ReferenceObject $expectedModalities -DifferenceObject $catalogModalities)
        )
        $catalogInstructions = if (
            $catalogModel.model_messages -and
            -not [string]::IsNullOrWhiteSpace([string]$catalogModel.model_messages.instructions_template)
        ) {
            [string]$catalogModel.model_messages.instructions_template
        }
        else {
            [string]$catalogModel.base_instructions
        }
        $catalogBaseInstructions = [string]$catalogModel.base_instructions
        $parallelToolCallProperty = if ($catalogModel) {
            $catalogModel.PSObject.Properties['supports_parallel_tool_calls']
        }
        else {
            $null
        }
        $parallelToolCallsValid = (
            $null -ne $parallelToolCallProperty -and
            $parallelToolCallProperty.Value -is [bool] -and
            (
                $null -eq $definition.SupportsParallelToolCalls -or
                [bool]$parallelToolCallProperty.Value -eq [bool]$definition.SupportsParallelToolCalls
            )
        )
        if (
            -not $catalogModel -or
            $catalogModel.display_name -ne $definition.DisplayName -or
            $catalogModel.visibility -ne 'list' -or
            -not $catalogInstructions.StartsWith($definition.Identity) -or
            -not $catalogBaseInstructions.StartsWith($definition.Identity) -or
            -not $modalitiesMatch -or
            -not $parallelToolCallsValid -or
            [bool]$catalogModel.supports_image_detail_original -ne [bool]$definition.SupportsImageDetailOriginal -or
            [string]$catalogModel.web_search_tool_type -ne [string]$definition.WebSearchToolType
        ) {
            throw "Custom model '$($definition.DisplayName)' failed validation: $CustomModelCatalogPath"
        }
    }

    foreach ($provider in (Get-ProviderDefinitions)) {
        $providerKey = $ProviderKeys[$provider.Name]
        if (-not $providerKey) {
            throw "Missing API key for provider '$($provider.Name)'."
        }

        $providerModels = @($UngateModelDefinitions | Where-Object { $_.ProviderName -eq $provider.Name })
        try {
            $availableModels = Invoke-RestMethod `
                -Uri "$($provider.ProxyBaseUrl)/v1/models" `
                -Headers @{ Authorization = "Bearer $providerKey" } `
                -TimeoutSec 5 `
                -ErrorAction Stop
            $availableModelIds = @($availableModels.data | ForEach-Object { $_.id })
            $missingModelIds = @($providerModels.Slug | Where-Object {
                $slug = $_
                -not ($availableModelIds | Where-Object { $_ -eq $slug -or $_ -like "*/$slug" -or $slug -like "*/$_" })
            })
            if ($missingModelIds.Count -gt 0) {
                Write-Host `
                    "[ungate] Warning: catalog models not found in $($provider.Name) /v1/models: $($missingModelIds -join ', ')" `
                    -ForegroundColor Yellow
            }
            else {
                Write-Host `
                    "[ungate] $($provider.DisplayName) models available: $($providerModels.Slug -join ', ')." `
                    -ForegroundColor Green
            }
        }
        catch {
            Write-Host `
                "[ungate] Warning: could not validate models for '$($provider.Name)' through $($provider.ProxyBaseUrl)/v1/models: $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    }

    $codexExecutable = Get-CodexCliExecutable
    if ($codexExecutable) {
        $previousCodexHome = $env:CODEX_HOME
        $previousEnv = @{}
        foreach ($provider in (Get-ProviderDefinitions)) {
            $previousEnv[$provider.EnvKey] = [System.Environment]::GetEnvironmentVariable($provider.EnvKey)
            [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $ProviderKeys[$provider.Name])
        }
        try {
            $env:CODEX_HOME = $CustomCodexHome

            $supportsModelDebug = (& $codexExecutable debug models --help 2>$null) -match 'raw model catalog'
            if ($supportsModelDebug) {
                $rawCatalog = & $codexExecutable debug models 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $resolvedCatalog = ($rawCatalog -join "`n") | ConvertFrom-Json -Depth 100
                    $resolvedModels = @($resolvedCatalog.models)
                    if ($resolvedModels.Count -ne $UngateModelDefinitions.Count) {
                        throw 'Codex loaded an unexpected model catalog.'
                    }
                    foreach ($definition in $UngateModelDefinitions) {
                        $catalogSlug = Get-CodexCatalogModelSlug -Definition $definition
                        $resolvedModel = $resolvedModels |
                            Where-Object { $_.slug -eq $catalogSlug } |
                            Select-Object -First 1
                        if (-not $resolvedModel -or $resolvedModel.display_name -ne $definition.DisplayName) {
                            throw "Codex did not load model '$($definition.DisplayName)' as expected."
                        }
                    }
                }
            } else {
                & $codexExecutable features list *> $null
            }

            if ($LASTEXITCODE -ne 0) {
                throw "Codex rejected the custom config with exit code $LASTEXITCODE."
            }
        }
        finally {
            if ($null -eq $previousCodexHome) {
                Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
            } else {
                $env:CODEX_HOME = $previousCodexHome
            }

            foreach ($provider in (Get-ProviderDefinitions)) {
                $previousValue = $previousEnv[$provider.EnvKey]
                if ($null -eq $previousValue) {
                    [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $null)
                } else {
                    [System.Environment]::SetEnvironmentVariable($provider.EnvKey, $previousValue)
                }
            }
        }
    }
}

function Initialize-CodexWindowsSandbox {
    $config = Get-Content -LiteralPath $CustomConfigPath -Raw
    if ($config -match '(?m)^sandbox_mode\s*=\s*["'']danger-full-access["'']\s*$') {
        Write-Host `
            '[ungate] Windows sandbox initialization skipped (sandbox_mode=danger-full-access).' `
            -ForegroundColor DarkGray
        return
    }

    $codexExecutable = Get-CodexCliExecutable
    if (-not $codexExecutable) {
        throw 'Codex CLI is required to prepare the Windows sandbox.'
    }

    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CustomCodexHome
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

function Start-CodexBetaDesktop {
    param(
        [Parameter(Mandatory)][psobject]$PackageInfo,
        [Parameter(Mandatory)][hashtable]$LaunchEnvironment,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    try {
        Start-Process `
            -FilePath ([string]$PackageInfo.ExecutablePath) `
            -WorkingDirectory $WorkingDirectory `
            -Environment $LaunchEnvironment `
            -ErrorAction Stop
        return
    }
    catch {
        $directLaunchError = $_.Exception.Message
    }

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
            $CodexPackageLaunchHelperPath,
            $pipeName,
            [string]$PackageInfo.ExecutablePath,
            $WorkingDirectory
        ) -ScriptBlock {
            param(
                $PackageFamilyName,
                $ApplicationId,
                $PowerShellPath,
                $HelperPath,
                $PipeName,
                $ExecutablePath,
                $WorkingDirectory
            )

            $arguments = @(
                '-NoProfile',
                '-WindowStyle', 'Hidden',
                '-File', "`"$HelperPath`"",
                '-PipeName', "`"$PipeName`"",
                '-ExecutablePath', "`"$ExecutablePath`"",
                '-WorkingDirectory', "`"$WorkingDirectory`""
            ) -join ' '
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
    catch {
        throw "Direct Codex Beta launch failed ($directLaunchError). MSIX package launch also failed: $($_.Exception.Message)"
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

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -ieq $ExecutablePath
    })
}

function Stop-CodexBeta {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath
    )

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

function Format-CodexSessionEvent {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line,
        [Parameter(Mandatory = $false)]
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off')]
        [string]$LogLevel = 'Standard'
    )

    if ([string]::IsNullOrWhiteSpace($Line) -or $LogLevel -eq 'Off') {
        return
    }

    try {
        $json = $Line | ConvertFrom-Json -ErrorAction Stop
        $p = $json.payload
        if (-not $p) { return }

        $objType = [string]$json.type
        $pType = [string]$p.type

        # 1. Agent Reasoning [THINK]
        if ($pType -eq 'agent_reasoning' -and $p.text) {
            if ($LogLevel -in @('Compact', 'Minimal')) {
                return
            }
            $text = $p.text.Trim()
            if ($text) {
                Write-Host "`n[THINK] " -ForegroundColor Magenta -NoNewline
                Write-Host $text -ForegroundColor DarkGray
            }
            return
        }

        # 2. User Message
        if ($pType -eq 'user_message' -and $p.message) {
            Write-Host "`n=== USER ===" -ForegroundColor Cyan
            Write-Host $p.message.Trim() -ForegroundColor White
            return
        }

        # 3. Tool Call
        if ($objType -eq 'response_item' -and ($pType -eq 'custom_tool_call' -or $pType -eq 'function_call')) {
            $toolName = if ($p.name) { $p.name } else { $p.call.name }
            $toolInput = if ($p.input) { $p.input } else { $p.arguments }

            if ($LogLevel -eq 'Minimal') {
                $summary = ''
                if ($toolInput) {
                    try {
                        $parsedInput = $toolInput | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsedInput.command) { $summary = " $($parsedInput.command)" }
                        elseif ($parsedInput.path) { $summary = " $($parsedInput.path)" }
                        elseif ($parsedInput.file_path) { $summary = " $($parsedInput.file_path)" }
                        elseif ($parsedInput.pattern) { $summary = " $($parsedInput.pattern)" }
                    } catch { }
                    if (-not $summary) {
                        $firstLine = ($toolInput.Trim() -split "`r?`n")[0]
                        if ($firstLine.Length -gt 70) { $firstLine = $firstLine.Substring(0, 70) + '...' }
                        $summary = " $firstLine"
                    }
                }
                Write-Host "--> [TOOL: $toolName]$summary" -ForegroundColor Yellow
                return
            }

            Write-Host "`n--> [TOOL CALL: $toolName]" -ForegroundColor Yellow
            if ($toolInput) {
                Write-Host $toolInput.Trim() -ForegroundColor DarkYellow
            }
            return
        }

        # 4. Tool Output
        if ($objType -eq 'response_item' -and ($pType -eq 'custom_tool_call_output' -or $pType -eq 'function_call_output')) {
            if ($LogLevel -eq 'Minimal') {
                return
            }

            $outLines = @()
            if ($p.output) {
                if ($p.output -is [array]) {
                    $outLines = $p.output | ForEach-Object { if ($_.text) { $_.text } else { [string]$_.content } }
                } else {
                    $outLines = @([string]$p.output)
                }
            }
            $outText = ($outLines -join "`n").Trim()
            if ($outText) {
                $limit = switch ($LogLevel) {
                    'Full' { 0 }
                    'Compact' { 400 }
                    default { 800 }
                }
                $preview = if ($limit -gt 0 -and $outText.Length -gt $limit) {
                    $outText.Substring(0, $limit) + "... [truncated: $($outText.Length) chars total]"
                } else {
                    $outText
                }
                Write-Host '<-- [TOOL OUTPUT]' -ForegroundColor Blue
                Write-Host $preview -ForegroundColor Gray
            }
            return
        }

        # 5. Agent Message
        if ($pType -eq 'agent_message' -and $p.message) {
            Write-Host "`n=== AGENT ===" -ForegroundColor Green
            Write-Host $p.message.Trim() -ForegroundColor White
            return
        }

        # 6. Turn Aborted
        if ($pType -eq 'turn_aborted') {
            Write-Host "`n[TURN ABORTED]" -ForegroundColor Red
            return
        }
    }
    catch {
        # Malformed or non-JSON line ignored
    }
}

function Watch-CodexActivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CustomCodexHome,
        [Parameter(Mandatory = $true)]
        [string]$DesktopExecutablePath,
        [ValidateSet('Full', 'Standard', 'Compact', 'Minimal', 'Off')]
        [string]$LogLevel = 'Standard',
        [string]$LogSettingsPath = (Join-Path $CustomCodexHome 'ungate-log-settings.json'),
        [int]$PollIntervalMs = 250
    )

    if ($LogLevel -eq 'Off') {
        Write-Host '[ungate] Live terminal logging is Off.' -ForegroundColor DarkGray
        return
    }

    Write-Host "`n[ungate] Streaming live Codex Beta activity in terminal (Level: $LogLevel | Keys: 1-5 switch level, Ctrl+C to detach)..." -ForegroundColor Cyan

    $sessionsRoot = Join-Path $CustomCodexHome 'sessions'
    $routerLogPath = Join-Path $CustomCodexHome 'logs\codex-model-shell-router.out.log'

    $sessionFs = $null
    $sessionSr = $null
    $currentSessionPath = $null

    $routerFs = $null
    $routerSr = $null

    try {
        if (Test-Path -LiteralPath $routerLogPath -PathType Leaf) {
            try {
                $routerFs = [System.IO.FileStream]::new(
                    $routerLogPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite
                )
                $routerFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                $routerSr = [System.IO.StreamReader]::new($routerFs, [System.Text.Encoding]::UTF8)
            }
            catch { }
        }

        $startupGraceDeadline = [System.DateTime]::UtcNow.AddSeconds(15)
        $lastHealthCheck = [System.Diagnostics.Stopwatch]::StartNew()
        $lastSessionCheck = [System.Diagnostics.Stopwatch]::StartNew()

        while ($true) {
            # 0. Live keyboard shortcuts to change log level
            if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                $newLevel = switch ($keyInfo.KeyChar) {
                    '1' { 'Full' }
                    '2' { 'Standard' }
                    '3' { 'Compact' }
                    '4' { 'Minimal' }
                    '5' { 'Off' }
                    default { $null }
                }
                if ($newLevel) {
                    $LogLevel = $newLevel
                    Write-Host "`n[ungate] Switched log level to: $LogLevel (Keys: 1=Full, 2=Std, 3=Compact, 4=Minimal, 5=Off)" -ForegroundColor Yellow
                    try {
                        Write-UngateLogSettings -SettingsPath $LogSettingsPath -LogLevel $LogLevel
                    } catch { }
                    if ($LogLevel -eq 'Off') {
                        Write-Host '[ungate] Logging turned off. Detaching...' -ForegroundColor DarkGray
                        break
                    }
                }
            }

            # 1. Read router lines (skipped in Minimal mode)
            if ($LogLevel -ne 'Minimal') {
                if ($routerSr) {
                    while (-not $routerSr.EndOfStream) {
                        $rLine = $routerSr.ReadLine()
                        if (-not [string]::IsNullOrWhiteSpace($rLine)) {
                            Write-Host "[router] $rLine" -ForegroundColor DarkCyan
                        }
                    }
                }
                elseif (Test-Path -LiteralPath $routerLogPath -PathType Leaf) {
                    try {
                        $routerFs = [System.IO.FileStream]::new(
                            $routerLogPath,
                            [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::Read,
                            [System.IO.FileShare]::ReadWrite
                        )
                        $routerFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                        $routerSr = [System.IO.StreamReader]::new($routerFs, [System.Text.Encoding]::UTF8)
                    }
                    catch { }
                }
            }

            # 2. Check for active session or switch to newer
            if ($null -eq $sessionSr -or $lastSessionCheck.ElapsedMilliseconds -gt 1500) {
                $lastSessionCheck.Restart()
                if (Test-Path -LiteralPath $sessionsRoot) {
                    $newest = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1

                    if ($newest -and $newest.FullName -ne $currentSessionPath) {
                        if ($sessionSr) {
                            $sessionSr.Dispose()
                            $sessionFs.Dispose()
                            $sessionSr = $null
                            $sessionFs = $null
                        }

                        $isFirstAttach = ($null -eq $currentSessionPath)
                        $currentSessionPath = $newest.FullName
                        try {
                            $sessionFs = [System.IO.FileStream]::new(
                                $currentSessionPath,
                                [System.IO.FileMode]::Open,
                                [System.IO.FileAccess]::Read,
                                [System.IO.FileShare]::ReadWrite
                            )
                            if ($isFirstAttach) {
                                $sessionFs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                                Write-Host "[ungate] Attached to active session: $($newest.Name)" -ForegroundColor DarkGray
                            }
                            else {
                                Write-Host "`n[ungate] Switched to new session: $($newest.Name)" -ForegroundColor Cyan
                            }
                            $sessionSr = [System.IO.StreamReader]::new($sessionFs, [System.Text.Encoding]::UTF8)
                        }
                        catch { }
                    }
                }
            }

            # 3. Read session lines
            if ($sessionSr) {
                while (-not $sessionSr.EndOfStream) {
                    $sLine = $sessionSr.ReadLine()
                    if (-not [string]::IsNullOrWhiteSpace($sLine)) {
                        Format-CodexSessionEvent -Line $sLine -LogLevel $LogLevel
                    }
                }
            }

            # 4. Periodically verify Codex Beta process is still alive after grace period
            if ($lastHealthCheck.ElapsedMilliseconds -gt 3000) {
                $lastHealthCheck.Restart()
                if ([System.DateTime]::UtcNow -gt $startupGraceDeadline) {
                    $running = @(Get-CodexBetaProcesses -ExecutablePath $DesktopExecutablePath).Count -gt 0
                    if (-not $running) {
                        Write-Host "`n[ungate] Codex Beta process exited. Log streaming finished." -ForegroundColor Yellow
                        break
                    }
                }
            }

            Start-Sleep -Milliseconds $PollIntervalMs
        }
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        Write-Host "`n[ungate] Log stream detached." -ForegroundColor DarkGray
    }
    catch {
        Write-Warning "[ungate] Log stream stopped: $_"
    }
    finally {
        if ($sessionSr) { $sessionSr.Dispose() }
        if ($sessionFs) { $sessionFs.Dispose() }
        if ($routerSr) { $routerSr.Dispose() }
        if ($routerFs) { $routerFs.Dispose() }
    }
}

function Normalize-WorkspaceRootPath {
    param([AllowNull()][string]$PathValue)

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
    if ($SkipWorkspaceRestore) {
        Write-Host '[ungate] Workspace root restore skipped (-SkipWorkspaceRestore).' -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $CustomGlobalStatePath)) {
        Write-Host "[ungate] No global state yet: $CustomGlobalStatePath" -ForegroundColor DarkGray
        return
    }

    $raw = Get-Content -LiteralPath $CustomGlobalStatePath -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host '[ungate] Global state is empty; workspace restore skipped.' -ForegroundColor DarkGray
        return
    }

    try {
        $state = $raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Failed to parse Codex global state at $CustomGlobalStatePath : $($_.Exception.Message)"
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

    $backupPath = "$CustomGlobalStatePath.bak"
    Copy-Item -LiteralPath $CustomGlobalStatePath -Destination $backupPath -Force

    $state | Add-Member -MemberType NoteProperty -Name 'project-order' -Value @($merged) -Force
    $state | Add-Member -MemberType NoteProperty -Name 'electron-saved-workspace-roots' -Value @($merged) -Force
    $state | Add-Member -MemberType NoteProperty -Name 'active-workspace-roots' -Value @($merged) -Force

    $json = $state | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $CustomGlobalStatePath,
        $json + "`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "[ungate] Restored $($merged.Count) workspace roots from project-order ∪ saved roots." -ForegroundColor Green
}

if ($AddModel) {
    $conflictingParameters = @(
        'ApiKey',
        'Model',
        'PrepareOnly',
        'SkipWorkspaceRestore',
        'EnableProviderFallback'
    ) | Where-Object { $PSBoundParameters.ContainsKey($_) }
    if ($conflictingParameters.Count -gt 0) {
        throw "-AddModel cannot be combined with: $($conflictingParameters -join ', ')."
    }

    $null = Invoke-AddUngateModelMode `
        -RegistryPath $CustomModelDefinitionsPath `
        -BuiltInDefinitions $BuiltInUngateModelDefinitions
    exit 0
}

$AllUngateModelDefinitions = @(
    Get-UngateModelDefinitions `
        -BuiltInDefinitions $BuiltInUngateModelDefinitions `
        -RegistryPath $CustomModelDefinitionsPath
)
$UngateModelDefinitions = @($AllUngateModelDefinitions)

if ($EnableProviderFallback) {
    if ($PSBoundParameters.ContainsKey('Model')) {
        throw '-EnableProviderFallback cannot be combined with -Model.'
    }

    $Model = $OmniRouteFallbackModel
    $UngateModelDefinitions = @($AllUngateModelDefinitions) + @($OmniRouteFallbackModelDefinition)
}
else {
    # Codex Beta only renders custom catalog labels for its own known model
    # IDs. The local shell router reverses these official IDs to the real
    # provider model before the request reaches Ungate or CLIProxyAPI.
    $UngateModelDefinitions = @(
        Get-UngatePickerModelDefinitions `
            -Definitions $AllUngateModelDefinitions `
            -SettingsPath $PickerModelSelectionPath `
            -Capacity $CodexDesktopPickerCapacity
    )
    $UngateModelDefinitions = @(
        Set-CodexModelShellSlugs -Definitions $UngateModelDefinitions
    )
}

if (-not $EnableProviderFallback -and -not $PrepareOnly -and -not $PSBoundParameters.ContainsKey('Model')) {
    $Model = Select-UngateDesktopModel `
        -Definitions $AllUngateModelDefinitions `
        -BuiltInDefinitions $BuiltInUngateModelDefinitions `
        -RegistryPath $CustomModelDefinitionsPath `
        -PickerSettingsPath $PickerModelSelectionPath `
        -PickerCapacity $CodexDesktopPickerCapacity `
        -LogSettingsPath $LogSettingsPath `
        -IncludeProviderFallback `
        -ProviderFallbackModel $OmniRouteFallbackModel

    if ($Model -eq $OmniRouteFallbackModel) {
        $EnableProviderFallback = $true
        $UngateModelDefinitions = @($AllUngateModelDefinitions) + @($OmniRouteFallbackModelDefinition)
    }
    else {
        $AllUngateModelDefinitions = @(
            Get-UngateModelDefinitions `
                -BuiltInDefinitions $BuiltInUngateModelDefinitions `
                -RegistryPath $CustomModelDefinitionsPath
        )
        $UngateModelDefinitions = @(
            Get-UngatePickerModelDefinitions `
                -Definitions $AllUngateModelDefinitions `
                -SettingsPath $PickerModelSelectionPath `
                -Capacity $CodexDesktopPickerCapacity
        )
        $UngateModelDefinitions = @(
            Set-CodexModelShellSlugs -Definitions $UngateModelDefinitions
        )
    }
}

if (-not $EnableProviderFallback -and [string]::IsNullOrWhiteSpace($Model)) {
    $Model = [string]$UngateModelDefinitions[0].Slug
}

$selectedModelDefinition = $UngateModelDefinitions |
    Where-Object { $_.Slug -eq $Model -or ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $Model) } |
    Select-Object -First 1
if (-not $selectedModelDefinition) {
    $knownModelDefinition = $AllUngateModelDefinitions |
        Where-Object { $_.Slug -eq $Model -or ($_.PSObject.Properties['UpstreamModel'] -and $_.UpstreamModel -eq $Model) } |
        Select-Object -First 1
    if ($knownModelDefinition -and -not $EnableProviderFallback) {
        throw "Model '$($knownModelDefinition.DisplayName)' is not enabled in the Desktop picker. Run the launcher and choose 'Configure Desktop model picker'."
    }
    $supportedModels = @($UngateModelDefinitions.Slug) -join ', '
    throw "Unsupported Desktop model '$Model'. Configured models: $supportedModels"
}
$Model = [string]$selectedModelDefinition.Slug
$CodexLaunchModel = if ($EnableProviderFallback) {
    $Model
} else {
    Get-CodexCatalogModelSlug -Definition $selectedModelDefinition
}
$CodexLaunchProvider = if ($EnableProviderFallback) {
    [pscustomobject][ordered]@{
        Name = $selectedModelDefinition.ProviderName
        DisplayName = $selectedModelDefinition.ProviderDisplayName
        ProxyBaseUrl = $selectedModelDefinition.ProxyBaseUrl
        EnvKey = $selectedModelDefinition.EnvKey
    }
} else {
    $CodexModelShellRouterProviderDefinition
}
Write-Host `
    "[ungate] Selected model: $($selectedModelDefinition.DisplayName) [$Model]." `
    -ForegroundColor Cyan
$historyProfile = Get-CodexHistoryProfileInfo `
    -HomePath $CustomCodexHome `
    -CanonicalHomePath $CanonicalCodexHome `
    -ModelSlug $Model `
    -ProviderName $selectedModelDefinition.ProviderName
Write-CodexHistoryProfileDiagnostics -Profile $historyProfile

$codexBeta = Get-CodexBetaPackageInfo
$desktopExecutable = $codexBeta.ExecutablePath
if (-not $PrepareOnly) {
    Stop-CodexBeta -ExecutablePath $desktopExecutable
}

$providerKeys = @{}
foreach ($provider in (Get-ProviderDefinitions)) {
    $sampleDefinition = $UngateModelDefinitions |
        Where-Object { $_.ProviderName -eq $provider.Name } |
        Select-Object -First 1
    $providerKeys[$provider.Name] = Resolve-ModelApiKey `
        -Definition $sampleDefinition `
        -ApiKey $(if ($selectedModelDefinition.ProviderName -eq $provider.Name) { $ApiKey } else { $null })
    Write-Host `
        "[ungate] $($provider.DisplayName) API key resolved (len=$($providerKeys[$provider.Name].Length))." `
        -ForegroundColor DarkGray
}

if ($providerKeys.ContainsKey($CliProxyProviderName)) {
    Ensure-CliProxyBridge -Key $providerKeys[$CliProxyProviderName]
}
if (-not $EnableProviderFallback) {
    Ensure-CodexModelShellRouter `
        -Routes (Get-CodexModelShellRoutes) `
        -ProviderKeys $providerKeys
}

$selectedKey = $providerKeys[$selectedModelDefinition.ProviderName]
$preflightAttempts = if ($EnableProviderFallback) { 1 } else { 2 }
$preflightFailure = $null
for ($attempt = 1; $attempt -le $preflightAttempts; $attempt++) {
    try {
        if ($EnableProviderFallback -or $selectedModelDefinition.ProviderName -eq $OmniRouteProviderName) {
            Invoke-OmniRoutePreflight `
                -Key $selectedKey `
                -Model $Model `
                -ProxyBaseUrl $selectedModelDefinition.ProxyBaseUrl
        }
        elseif ($selectedModelDefinition.RequiresUngate) {
            Invoke-UngatePreflight `
                -Key $selectedKey `
                -Model $Model `
                -ProxyBaseUrl $selectedModelDefinition.ProxyBaseUrl
        }
        else {
            # CLIProxyAPI discovery is dynamic, so live Responses inference is authoritative.
            Write-Host "[ungate] Proxy healthy at $($selectedModelDefinition.ProxyBaseUrl)." -ForegroundColor Green
            Invoke-CliProxyPreflight `
                -Key $selectedKey `
                -Model $Model `
                -ProxyBaseUrl $selectedModelDefinition.ProxyBaseUrl
        }

        $preflightFailure = $null
        break
    }
    catch {
        $preflightFailure = $_
        if ($attempt -lt $preflightAttempts) {
            Write-Host `
                "[ungate] Preflight attempt $attempt of $preflightAttempts failed; retrying." `
                -ForegroundColor Yellow
            Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkYellow
            Start-Sleep -Seconds 1
        }
    }
}

if ($preflightFailure) {
    Write-Host '[ungate] Preflight failed.' -ForegroundColor Red
    Write-Host "        $($preflightFailure.Exception.Message)" -ForegroundColor Yellow
}

Initialize-UngateCodexConfig
Write-UngateModelCatalog
$betaOnlyMcpContent = @'
[mcp_servers.ungate_patch]
command = 'C:\Program Files\nodejs\node.exe'
args = ['J:\Dev\ungate-local\scripts\ungate-patch-mcp.mjs', "--allow-root", "*"]
'@

Sync-CodexMcpServers `
    -SourceCodexHome $DefaultCodexHome `
    -TargetCodexHome $CustomCodexHome `
    -BetaOnlyMcpContent $betaOnlyMcpContent
Ensure-SharedDirectory -Name 'skills'
Sync-CodexGlobalInstructions
Sync-CodexAuthentication
$codexExecutable = Get-CodexCliExecutable
if (-not $codexExecutable) {
    throw 'Codex CLI is required to prepare the isolated Codex Beta plugin store.'
}
$betaIsRunning = @(Get-CodexBetaProcesses -ExecutablePath $desktopExecutable).Count -gt 0
$pluginIsolation = Initialize-CodexBetaPluginIsolation `
    -DefaultCodexHome $DefaultCodexHome `
    -CustomCodexHome $CustomCodexHome `
    -CodexExecutable $codexExecutable `
    -BetaBundledMarketplace $codexBeta.BundledMarketplacePath `
    -BetaPackageVersion $codexBeta.Version `
    -BetaIsRunning $betaIsRunning
if ($pluginIsolation.Changed) {
    $syncReasons = @($pluginIsolation.SyncReasons)
    if ($syncReasons.Count -gt 0) {
        Write-Host `
            "[ungate] Plugin isolation will sync because: $($syncReasons -join '; ')." `
            -ForegroundColor Yellow
    }
    Write-Host `
        "[ungate] Codex Beta plugins $($pluginIsolation.Action.ToLowerInvariant()) and isolated ($($pluginIsolation.PluginIds.Count) installed)." `
        -ForegroundColor Green
}
else {
    Write-Host `
        "[ungate] Isolated Codex Beta plugins verified ($($pluginIsolation.PluginIds.Count) installed)." `
        -ForegroundColor DarkGray
}
Write-Host "[ungate] Browser plugin SHA256: $($pluginIsolation.BrowserSha256)" -ForegroundColor DarkGray
$unsupportedBundledPluginIds = @($pluginIsolation.UnsupportedBundledPluginIds)
if ($unsupportedBundledPluginIds.Count -gt 0) {
    Write-Warning (
        '[ungate] Codex Beta does not provide bundled plugins from the normal profile: ' +
        ($unsupportedBundledPluginIds -join ', ')
    )
}
Assert-UngateCodexConfig -Key $selectedKey -ProviderKeys $providerKeys
Initialize-CodexWindowsSandbox
Write-Host "[ungate] Custom CODEX_HOME ready: $CustomCodexHome" -ForegroundColor Green
Restore-CodexWorkspaceRoots

if ($PrepareOnly) {
    if ($preflightFailure) {
        Write-Host '[ungate] Preparation finished with preflight warning. Desktop launch skipped.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host '[ungate] Preparation passed. Desktop launch skipped.' -ForegroundColor Green
    exit 0
}

$launchTransport = if ($EnableProviderFallback) {
    $selectedModelDefinition.ProviderName
} else {
    'the local Codex model-shell router'
}
Write-Host "[ungate] Launching Codex Beta with $($selectedModelDefinition.DisplayName) via $launchTransport." -ForegroundColor Green
$launchEnv = @{
    CODEX_HOME = $CustomCodexHome
}
foreach ($provider in (Get-ProviderDefinitions)) {
    $launchEnv[$provider.EnvKey] = $providerKeys[$provider.Name]
}
Start-CodexBetaDesktop `
    -PackageInfo $codexBeta `
    -LaunchEnvironment $launchEnv `
    -WorkingDirectory $RepoRoot

if (-not $NoLogWatch) {
    $activeLogLevel = if ($PSBoundParameters.ContainsKey('LogLevel') -and -not [string]::IsNullOrWhiteSpace($LogLevel)) {
        Write-UngateLogSettings -SettingsPath $LogSettingsPath -LogLevel $LogLevel
        $LogLevel
    } else {
        (Read-UngateLogSettings -SettingsPath $LogSettingsPath).LogLevel
    }

    if ($activeLogLevel -ne 'Off') {
        Watch-CodexActivity `
            -CustomCodexHome $CustomCodexHome `
            -DesktopExecutablePath ([string]$desktopExecutable) `
            -LogLevel $activeLogLevel `
            -LogSettingsPath $LogSettingsPath
    } else {
        Write-Host '[ungate] Live terminal logging is Off.' -ForegroundColor DarkGray
    }
}
