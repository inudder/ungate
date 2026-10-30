# Desktop launcher architecture

`scripts/start-codex-desktop-ungate.ps1` remains the public PowerShell 7.4+
entry point. It retains the existing parameters and defaults, creates a
per-invocation context, calls the launcher and translates its result to a
process exit code. Existing shortcuts and command lines do not need changes.

## Module ownership

Implementation lives in `scripts/codex-desktop-launcher/`.

| Module | Responsibility | Module dependencies |
| --- | --- | --- |
| Context | Paths, endpoint defaults, launch options, history diagnostics | None |
| Models | Template and profile registry, identities, context windows | None |
| Toml | Pure TOML text transformations | None |
| Desktop | CLI/AppX discovery, process lifecycle, MSIX fallback, sandbox, workspace roots | None |
| Routing | Providers, shell IDs and route records, provider TOML | Toml |
| Logging | Log preferences, menu, event formatting and live watch | Desktop |
| Picker | Model selection, picker preferences and add-model wizard | Models, Logging, ToolCompatibility |
| ProxyRuntime | Credentials, bridge/router lifecycle, provider preflight | Routing, existing common helpers |
| ShellRouterService | Protected route envelopes, service identity, drain and runtime checks | None |
| ToolCompatibility | Diagnostic model selection, credentials and isolated Codex runtime discovery | Models, ProxyRuntime, Desktop, Catalog |
| Catalog | Model catalog generation, catalog/config verification | Models, Routing, Toml, Desktop |
| Profile | Initial config, MCP transaction and backup, shared skills, AGENTS and auth | Routing, Toml, Desktop |
| Launcher | Selection, transport, profile preparation and launch orchestration | Above modules, existing plugin-isolation module |

Modules use explicit local imports and explicit exports; internal helpers
remain private. Importing a module does not prepare a profile, discover an
installed Desktop, call a provider or launch/stop a process. There is no
mutable per-launch module or global state and no dependency cycle.

`environment-instructions.txt` contains the unchanged instruction text used
to build model identities. The context factory reads it explicitly. Builtin
definitions and the OmniRoute fallback are built on each call to `New-UngateModelSet`.
The profile's active list is `ungate-model-registry.json`, created from
`models.default.json` when the registry is missing.

The `ungate_patch` MCP source editor has its own [patch authoring and
diagnostic contract](patch-mcp.md), including JavaScript numeric coercion
when patch markers are placed outside string literals.

## Internal interfaces

- `New-CodexDesktopLaunchContext -CustomCodexHome ... -LaunchParameters ...
  -ScriptsRoot ...` returns an object with resolved paths, endpoint/provider
  defaults, shell pool, instruction text, `Options` and `BoundParameterNames`.
  The entry point passes its actual `$PSBoundParameters`, preserving the
  difference between an omitted switch/model and an explicitly supplied one.
- `Invoke-CodexDesktopLauncher -Context ...` owns execution. It returns only
  the integer exit code on the success stream; diagnostic text stays on the
  host/warning streams. Failures remain terminating errors.
- Selection is a separate, invocation-local object: `Definitions`,
  `FallbackDefinition`, `EnableProviderFallback`, `SelectedModel`,
  `LaunchModel`, `LaunchProvider`. Functions that need it accept `-Selection`
  explicitly. Menu choices do not mutate the original context options.
- Paths and infrastructure settings are passed as `-Context`; other inputs
  are regular parameters. No function resolves caller variables dynamically.
  Provider keys remain local to transport preparation and are passed only to
  operations that need them; they are not stored in module state or fixtures.

Functions explicitly set their local `ErrorActionPreference` to `Stop` to
retain the original entry point's fail-fast behavior across module session
states. They do not rely on caller preference inheritance. Existing targeted
`SilentlyContinue`/best-effort operations retain their original policy.

`ScriptsRoot` is the original `scripts` directory, not the module directory
or current working directory. Existing router, bridge, package helper and
plugin-isolation paths are resolved from it. The shared
`ungate-codex-common.ps1` is loaded privately by `ProxyRuntime` only.

The Desktop-specific `Invoke-DesktopOmniRoutePreflight` deliberately differs
from the shared `Invoke-OmniRoutePreflight`: it accepts the discovered
`deepseek/` and `ds/` model aliases and requests 512 output tokens. Its unique
name avoids import-order-dependent overriding. Other launchers keep their
existing common preflight behavior.

## Execution contract

1. Handle standalone `TestTools` before Desktop/profile operations; otherwise validate launcher dependencies and handle standalone `AddModel`.
2. Resolve registry/picker selection and launch model/provider, then print history
   diagnostics. If the selected model uses OmniRoute, compare its catalog context
   window with OmniRoute's enforced limit before stopping Beta, preparing the
   profile, or changing the shared router. A smaller context window or
   `max_input_tokens` limit exits `1` for a normal launch and for `PrepareOnly`.
   An unconfirmed limit is a warning, not a passed check.
3. Discover the Beta package. Before closing a running Beta, drain the service and wait
   up to 30 seconds for active router requests. If they do not finish, or Beta refuses to
   close, warn and defer profile changes and a second launch. With the service installed,
   `PrepareOnly` also defers profile changes while Beta is running. Resolve provider keys, ensure the
   required bridge/router, then preflight. Normal preflight has two attempts; fallback
   has one. Preflight failure remains a warning and does not skip profile preparation.
4. Resolve the service CLI, initialize config, write the model catalog **before** MCP
   validation, synchronize MCP/skills/instructions/auth, prepare isolated plugins,
   verify the config and the catalog load, report sandbox readiness and restore
   workspace roots.
5. `PrepareOnly` returns `0` on success, `1` when the OmniRoute context limit is
   smaller than the launcher window, or `2` after a preflight or preparation warning.
   Normal execution starts Desktop and optionally watches logs. `NoLogWatch`
   overrides log preferences; otherwise a nonempty explicit level overrides
   persisted preferences. `Off` starts Desktop without watching.

### Fatal and soft gates

Only physical blockers stop the launch: a missing Beta package or executable, an
invalid custom config or model catalog, a missing provider key, an unavailable model
or a failed Desktop start. Every other preparation step is a soft gate: its failure is
printed as a warning, listed in the closing summary and the launch continues. A normal
launch returns `0` with warnings; `PrepareOnly` returns `2`. If the router cannot
be prepared, a route that depends on it is not launched. If only memories need the
router in provider fallback mode, disable memories for that launch and retain their
saved preference. An unverified MCP write stops dependent profile preparation and
leaves the effective config and its backup in place for forward repair.

## Model-shell router service

On this machine `ungate-codex-shell-router` is an automatic LocalSystem NSSM
service listening only on `127.0.0.1:8319`. It is independent of the ordinary
Codex profile and `codex.exe`; restarting or updating ordinary Codex does not
require stopping this service. The service uses the installed Node and PowerShell
executables under `C:\Program Files`. Updating Node itself may require stopping the
router after its requests finish because the service has Node processes open.

The service wrapper and router dependencies are copied to
`C:\ProgramData\Ungate\shell-router\runtime`. Only SYSTEM and administrators
have write access there, including to the NSSM executable. The launcher verifies
the SCM wrapper, supervisor and listener process identities, the listener port,
the router build and the hashes of all copied runtime files. It never stops a
foreign listener. If the protected runtime no longer matches this repository,
finish active requests, stop this service, run
`pwsh -NoProfile -File scripts\install-codex-shell-router-runtime.ps1`, and
start it again only after that command succeeds. The installer requires an
elevated administrator and refuses to copy over a running service.

`C:\ProgramData\Ungate\shell-router\config` is restricted to the user, SYSTEM
and administrators. Route sets and keys, including `-ApiKey`, are encrypted with
Windows DPAPI `LocalMachine` before they are written. Any principal with access
to those files on this machine can use machine DPAPI to decrypt them; the ACL is
therefore part of the protection. The service decrypts through a private child
pipe, validates the complete set, keeps encrypted previous versions in `backups`,
and switches snapshots without restarting. Requests already accepted retain
their original snapshot. Rejected envelopes are retained in `rejected`. Missing
or unreadable configuration produces `not_ready` and a diagnostic, without
silently restoring a previous version. For an initial installation,
`scripts\stage-codex-shell-router-config.ps1` stages a short-lived encrypted
envelope; start the service promptly or let the launcher submit a new one.
Backups are for explicit manual recovery after diagnosis, not automatic rollback.

The current combined log is
`C:\Users\kalvinclein\.codex-ungate\logs\codex-model-shell-router.log`; the
older `.out.log` and `.err.log` files remain available. The service supervisor
merges its router child's stdout and stderr before passing them to NSSM's stdout
pipe. NSSM online rotation is enabled at 10 MiB and does not delete archives.
Request records contain timestamp, model, request ID, status, duration and an
error category; request bodies and keys are not logged. `response_completed`
is `null` when the router did not observe a Responses stream lifecycle, rather
than an indication that the response was incomplete. Fatal records include an
allowlisted exception type, system error code and runtime source locations;
exception messages and arbitrary stack text are not recorded. The NSSM panel reads
the current combined log as stdout; archived files are on disk.

With NSSM 2.24, setting `AppStdout` and `AppStderr` to the same online-rotated
file can leave the wrapper running without restarting its child. For this
service, `AppStderr` must be unset: the supervisor already merges the streams.
The panel entry and `deploy/nssm/ungate-codex-shell-router.service.json` use
`logs: { stdout: <path>, stderr: "" }` to record the effective configuration.
The panel's JSON import form accepts only a single string path, so this file is
not suitable for that form. The panel's general edit/import and backup-restore
flows can set both paths again; after using those flows, reset `AppStderr` with
the protected `nssm.exe` **before** restarting the service and check the
effective settings. Panel `Start all` has its own
documented behavior for `managedPorts` and may stop a foreign port owner; the
launcher's foreign-listener protection does not change that panel behavior.

For diagnostics, inspect `/_shell-router/health` on port 8319, the combined log,
and the Windows Application event log from provider `nssm`. A service restart
can recover the process and its committed route set, but cannot resume a request
that was interrupted by the crash.

The service CLI is the launcher's own copy of the CLI that ships with the Beta package,
kept in `<beta-home>/.launcher-cli/<package-version>/` and verified by SHA-256 against
the package. The package CLI cannot run from `WindowsApps`, and the shared extracted
binaries change when either package updates, so the copy is what keeps the plugin store
and the model catalog verified against the build that later reads them.

Codex Beta provisions the Windows sandbox itself from its own package, so the launcher
only reports readiness: the sandbox is ready when the command runner of the exact
Beta CLI version exists in `<beta-home>/.sandbox-bin/`. A missing runner is a warning
with the command that prepares it eagerly; it never blocks the launch.

Except for the additive `TestTools` mode, existing public parameters, persisted file formats, model order, shell
mapping and [routing matrix](model-routing.md) are unchanged. Normal Codex
config remains read-only. MCP backups are retained for manual recovery. Temporarily changed
environment values are restored on failure, including removing provider
variables that were originally absent (rather than leaving an empty value
on newer .NET versions).

## Safe verification

Local memories default to Off, including the first copy of the normal profile.
Open **Настройки памяти** with `M` (number 12 with six picker models and
provider fallback), or run `start-codex-desktop-ungate.ps1 -ConfigureMemories`
to manage memory settings without stopping or launching Desktop. Choose On/Off,
change the provider and upstream model, check the current model, or restore
CLIProxyAPI `gemini-3.8-flash-high` as the default model. The same model handles
extraction and consolidation. All three configured providers are supported.

`Memories.psm1` stores versioned preferences in `ungate-memory-settings.json`
under the selected `CustomCodexHome`. It keeps credentials outside that file
and retains a backup on replacement. Missing preferences mean Off/Gemini;
unreadable preferences are preserved and produce a warning with memories Off.
Menu changes take effect on the next launcher start. The launcher applies the
saved choice to `features.memories`, `memories.generate_memories` and
`memories.use_memories`; both model overrides use hidden alias `ungate-memory`.
A toggle changed only in Beta's UI is replaced by the launcher preference on
the next preparation. The normal profile and existing memory files are retained.

Catalog validation includes the hidden memory entry in both the generated file
and Codex's raw loaded catalog. With six picker models and memories On, both
catalogs must contain eight entries: six listed models, hidden `ungate-memory`
and hidden `gpt-5.6-luna` for Desktop background tasks.

### Desktop background tasks

Codex Desktop hard-codes `gpt-5.6-luna` for chat titles, ambient suggestions,
their safety check and codex-auto-review, whatever model the chat uses. That ID
is therefore not a picker slot: the picker holds six models, and the launcher
adds a hidden catalog entry and router route for `gpt-5.6-luna`. By default it
points at the model selected for the launch. Menu `B` saves another registry
model, including one outside the picker, in `ungate-background-model.json`;
`0` returns to the launch model. A saved model that no longer exists falls back
to the launch model with a warning. Provider fallback mode does not remap it.

Choosing a model or enabling memories requires successful live Responses
validation. The check also runs at each launch with memories On; a successful
unchanged choice is reused within that invocation. Manual Check forces a fresh
probe. Discovery is advisory; inference must pass JSON Schema extraction,
namespace/function and custom tool calls, both tool-result continuations, and
complete Responses SSE. The probe uses synthetic inputs, executes no tool code,
and passes credentials to `codex-memory-preflight.mjs` over stdin. Temporary
router/bridge listeners bind exclusive OS-assigned ports and close in `finally`.
Each request is limited to 120 seconds, with a 10-minute overall bound.
The function probe specifies its exact arguments as JSON, so sentence
punctuation cannot become part of the memory value. Argument validation
still rejects any changed value or extra property.

If memory validation fails, Desktop still launches with generation and use Off
for that run. Saved preferences remain intact for the next attempt. Main-model
preflight behavior is independent. `-PrepareOnly` returns 2 on a memory check
failure. Disabled memories cause no memory validation or memory-only credential
lookup. No provider fallback is substituted for a failed memory model.

Ungate key lookup in `ungate-codex-common.ps1` prefers built-in `node:sqlite`
and opens the database read-only. This avoids native `better-sqlite3` ABI
mismatches after a Node upgrade. Older Node runtimes without `node:sqlite`
retain the `better-sqlite3` fallback; explicit and environment keys still
take precedence.

From the repository root:

```powershell
pnpm --filter @ungate/scripts run launcher:test
```

The runner parses all launcher modules and related PowerShell sources, then
runs Pester **5.0 or newer** over the original launcher scenarios, module/flow tests,
common helper tests and plugin-isolation tests. It exits nonzero for syntax,
discovery, container or test failures. A compatible Pester version must already be installed;
the runner does not install dependencies or change the machine.

Tests import actual modules, pass explicit contexts and use module-scoped
mocks at network/process boundaries. File-writing scenarios use `TestDrive`;
the add-model CLI test runs against a disposable profile. The frozen model
fixture was captured from the pre-refactor definitions; identity SHA256
values verify instruction bytes without repeating the text in each record.
JSON object key order is irrelevant, but model/array order is significant.

Do not use the real launcher `-PrepareOnly` as a read-only check: it writes
the target profile and can update the model-shell router configuration. Automated
refactoring verification must not stop a working Beta instance or query live
providers. No API rebuild or `ungate-api` service restart is needed for
launcher-only changes.

## Tool schema compatibility diagnostics

Choose **TT** in the launcher menu, then mark models with arrows/Space and
press Enter. Esc or an empty selection cancels. All registered models are
available, including models disabled in the Desktop picker; diagnostic
selection does not change picker settings. TT returns to the main menu.

TT explicitly reports whether the snapshot contains custom `exec`, and records
`snapshot.hasCustomExec` in its JSON report. A snapshot with only `apply_patch`
does not establish `exec` support. These remain schema acceptance tests, not
execution or multi-turn reasoning tests.

DeepSeek V4 Pro and Flash use the explicit `deepseek-responses` router adapter
through OmniRoute. It converts custom `exec` to a function and restores JSON/SSE
custom calls, preserving reasoning and parallel call groups. It does not execute
generated code. Restart Beta through the launcher to activate updated router
code; applying the source changes does not close a running Beta session.

`deepseek-responses-live-check.mjs` is an opt-in, finite live cycle check (never
part of the offline test suite). It reads `{models, reportPath}` from stdin;
each model uses route fields `upstreamModel`, `upstreamBaseUrl`, `apiKey`,
`responsesAdapter`. Resolve keys with the existing launcher helpers and do not
put them in command-line arguments or files. It uses a temporary router on an
OS-assigned port, verifies its health/PID, submits synthetic results without
executing generated code, and saves only outcomes/timings. Thinking mode uses
`tool_choice: auto`: DeepSeek rejects forced/required tool choices in this mode.
Run `pnpm --filter @ungate/scripts run deepseek-adapter:test` for offline coverage.

Live verification on 2026-09-18 passed for both Pro and Flash through OmniRoute:
one restored custom `exec` call and continuation, plus four parallel function
calls and continuation with preserved real reasoning. The latter includes an
explicit synthetic commentary fixture when the model omits commentary, matching
the failing session's item order. Outcomes and structural metadata (no prompts,
reasoning text or credentials) are in [the live report](deepseek-live-check-2026-09-18.json).

The initial live check inspected only terminal `response.output`. It missed a
Flash stream where commentary appeared in SSE but was absent from the terminal
array, shifting the exec index and causing duplicate execution. The adapter now
matches calls by stable identity, and live checks validate unique call IDs in
`response.output_item.done` and replay those streamed items as Codex does.
The regression results are in [the SSE live report](deepseek-sse-live-check-2026-09-18.json).
Already duplicated histories are not rewritten: after updating the launcher,
start a new task if an older task contains duplicate calls/results.

```powershell
pwsh -NoProfile -File J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 -TestTools
pwsh -NoProfile -File J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 -TestTools -Model grok-4.7
```

`-TestTools -Model <registry-id-or-alias>` is noninteractive. Unknown or
ambiguous model names fail rather than opening a picker. `TestTools` cannot
be combined with `AddModel`, `PrepareOnly`, or `EnableProviderFallback`.
An explicit `ApiKey` is allowed only for a single selected model.

On normal launcher startup, the router receives
`CODEX_SHELL_ROUTER_TOOLS_CACHE_PATH`, pointing to
`CustomCodexHome/tool-compatibility/tools-schema-cache.json`. It atomically
saves the latest nonempty tools array before namespace/adapter conversion.
The snapshot contains version, capture time, upstream source model, SHA256
and tool definitions only; no messages, request headers or credentials.
Cache failures do not fail model requests. Diagnostic routers do not capture
their own single-tool probes or overwrite this cache.

After installing this feature, relaunch Beta through the launcher and send
one message to populate the cache. A restart alone does not populate it.
For the default Beta home, TT can recover a missing/corrupt cache from the
latest qualifying original Codex Responses request in local OmniRoute logs
(up to seven date directories and 200 newest files per day). It requires
Codex tools and intact namespace schemas, skips translated/single-tool requests,
and copies only schemas and provenance, never messages or keys. The terminal
and report identify this historical source; a later live request replaces it.
Custom homes do not import another profile's logs. When neither source is
available, TT prints the first-message instruction and exits 2.
A run freezes one snapshot for all models and shows
its source/time/hash: it covers tools advertised by that specific request,
not every tool that could later be loaded dynamically.

The finite Node runner uses the existing router and, for CLIProxy, bridge
implementations on exclusively bound OS-assigned localhost ports. It checks
health and owning PID, resolves the same providers/keys, and closes its
servers in finally. It never prepares profiles, launches/stops Beta, or
restarts the working router. Provider services must already be available.
Keys travel from PowerShell over stdin, not command-line arguments or files.

TT and `-TestTools` run schema probes and real execution in one action. The
current snapshot has ten tools (including six `collaboration.*` tools), twelve
schema probes and six functional scenarios. Counts follow the frozen snapshot.
Each tool has a Russian purpose and separate schema, call, execution and
continuation results. Schema probes remain sequential: control without tools,
each tool preserving its namespace, then the full set. Each has a 120-second
timeout and 512 output-token budget with `tool_choice: none`. These probes alone
prove only schema acceptance. Authentication, network errors, unsupported
diagnostic parameters and timeouts do not count as schema rejection. A failed
control skips the remaining probes. An individually rejected schema blocks its
dependent scenarios; rejection of the complete set still permits isolated groups.

`codex-tool-test-runtime.mjs` starts a real stdio Codex app-server in a temporary
profile and workspace with Code Mode and collaboration v2. The executable is
resolved from Beta's `CODEX_CLI_PATH` first, then the existing launcher resolver;
its path and version are recorded. The selected catalogue model and route also
apply to its one allowed child agent. Global profiles and the running Desktop
are unchanged. The diagnostic gateway filters groups without rewriting schemas
and checks each emitted input contract against the saved snapshot before
forwarding. A missing tool or changed contract means execution is **not tested**.

`codex-tool-test-scenarios.mjs` checks terminal/file read-write-readback through
exec, yielding exec/wait cell IDs, a real Plan-mode question with automatic
answer, all six collaboration tools with one child, live web search with a
cited result, and a combined sequential/parallel task. Random fixture values
must be obtained from actual results and used in continuation; runner checks
file postconditions independently. An executor error or ignored result fails
the corresponding stage. New tools without scenarios and arbitrary MCP tools
never receive an automatic execution pass. The question window's appearance
is outside this test. Synthetic executors exist only in offline tests.

Version 2 JSON reports in `CustomCodexHome/tool-compatibility/reports/` preserve
legacy schema `checks` and add `toolResults` with per-tool stages, dependencies, scenario results,
skip reasons and runtime evidence. Reports are saved before and after each
stage; cancellation preserves partial results. Failed runtime artifacts remain
in the reported temporary directory. Models run sequentially with a 180-second
scenario deadline and 20-minute model deadline. Cancellation interrupts turns,
closes owned listeners and allows ten seconds for app-server shutdown before
terminating its owned process tree. The control agent uses the same runner,
NDJSON progress and final `type: result`, with a deadline based on model count.

Exit codes: `0` all required schemas and execution/continuation checks confirmed
(or selection cancelled before testing); `1` explicit schema or functional
failure; `2` incomplete coverage, runtime mismatch, infrastructure error,
timeout or cancellation. Code 2 wins when errors are mixed. No tool blocklist
is created or modified.

Run `pnpm --filter @ungate/scripts run tool-compatibility:test` for isolated
Node tests; `launcher:test` also includes the TT PowerShell scenarios.

## Model version and upstream slug overrides

The launcher allows changing a model's upstream version/slug, display label, and
context window dynamically without editing the codebase.

### Interactive configuration
- Choose **Change model version (upstream slug)** in the main menu or press **V**.
- Select the target model.
- For CLIProxyAPI models, the launcher queries `/v1/models` on the active bridge/upstream
  and displays all discovered model IDs.
- Set the new upstream model ID (e.g. `grok-4.8`), optional display label, and optional context
  window (e.g. `500k`, `1M`, `200k`).
- To revert back to built-in defaults, enter `reset` or `default`.

### Non-interactive CLI
```powershell
# Open version configuration wizard directly
pwsh .\scripts\start-codex-desktop-ungate.ps1 -ConfigureModel

# Directly set upstream slug for a specific model
pwsh .\scripts\start-codex-desktop-ungate.ps1 -Model grok-4.7 -SetUpstreamModel grok-4.8

# Reset back to built-in default
pwsh .\scripts\start-codex-desktop-ungate.ps1 -Model grok-4.7 -SetUpstreamModel reset
```

Overrides are persisted across launcher sessions in `$CustomCodexHome/ungate-model-overrides.json`.
When all overrides are removed, the file is automatically cleaned up.

An optional `upstreamModelPrefix` transport override selects a specific gateway
provider without changing the native `upstreamModel` displayed by V. Routes and
diagnostics prepend `<prefix>/` only to unqualified native IDs; subsequent
version edits keep the prefix and use the new native ID. It is independent of
capabilities and survives both capability and version resets. Use this only
when the actual gateway route requires disambiguation; it grants no capability.

## Model capabilities (C)

Choose **C / Возможности моделей** or the appended numeric entry. Existing menu
numbers and shortcuts stay unchanged. All registered models can be edited,
including those currently absent from the Desktop picker. The editor displays
effective values and explicit overrides. S saves, R resets only capabilities,
T tests saved settings, and B or an empty input leaves without saving the draft.
The next normal launcher start rebuilds the catalog; restart Beta to apply it.

```powershell
pwsh .\scripts\start-codex-desktop-ungate.ps1 -ConfigureCapabilities
pwsh .\scripts\start-codex-desktop-ungate.ps1 -ConfigureCapabilities -Model mimo-v2.6-pro
pwsh .\scripts\start-codex-desktop-ungate.ps1 -Model mimo-v2.6-pro -SetModelCapabilities '{"supportsImageInput":true,"supportsImageDetailOriginal":false}'
pwsh .\scripts\start-codex-desktop-ungate.ps1 -Model mimo-v2.6-pro -TestModelCapabilities
pwsh .\scripts\start-codex-desktop-ungate.ps1 -Model mimo-v2.6-pro -SetModelCapabilities reset
```

The version-1 overrides file accepts these optional fields:

| Field | Value |
| --- | --- |
| `supportsImageInput`, `supportsImageDetailOriginal` | Boolean; original requires image |
| `supportedReasoningLevels` | Nonempty unique string array: none, minimal, low, medium, high, xhigh, max, ultra |
| `defaultReasoningLevel` | A member of the effective reasoning-level array |
| `supportsReasoningSummaries` | Boolean |
| `defaultReasoningSummary` | none, auto, concise, detailed |
| `supportsParallelToolCalls` | Boolean |
| `supportVerbosity` | Boolean |
| `defaultVerbosity` | low, medium, high; null when disabled |

Omitted fields inherit model defaults. Updates merge into the existing record;
changing upstream does not discard capabilities. Version reset removes only
upstream/name/context fields. Capability reset preserves those fields. Old
custom registry entries remain supported; newly added models ask about original
detail separately, defaulting it to off. Text is always available. Audio/video,
native PDF, image generation and provider-native search are outside this editor.

Catalog generation emits both `supports_reasoning_summary_parameter` and the
legacy summaries field. Explicit parallel overrides also travel in router
routes as optional Boolean `parallelToolCalls` and override the Responses
request parameter; absent overrides retain previous behavior. Hidden memories
take capabilities from their own definition rather than the first picker model.

Tests use the same router and route-specific adapters, with an isolated bridge
only for CLIProxy models, on exclusively bound OS-assigned ports. Readiness
verifies HTTP status, service identity and serving PID. Credentials travel over
stdin. No running provider, router or Beta process is restarted by C or tests.
Each streamed probe has a 120-second timeout and 512 output-token budget, with
no retries. The control request must complete; a failed control skips the rest.
Image checks compare the answer with four randomly chosen PNG color bands.
Original is checked separately when enabled. Reasoning/verbosity checks report
parameter acceptance, not proof of behavioral effect. Parallel is verified only
when both inert function calls occur in one response; no function is executed.

Reports under `$CustomCodexHome/model-capabilities/reports/` preserve partial
results and distinguish verified, parameter_accepted, unsupported, wrong_answer,
inconclusive, timeout, provider_error, invalid_response and cancelled. The editor
marks a report stale when its upstream/route/adapter/capability fingerprint no
longer matches. Keys, request contents and PNG payloads are not saved. Exit
codes: 0 checks accepted/verified; 1 explicit unsupported or wrong image answer;
2 technical failure, cancellation or an inconclusive observation. A failed
diagnostic never changes settings or triggers rollback.

Override backups are retained for manual recovery. Plugin-isolation failures
also retain the effective state, staging and backups, with `failure.json` in
the backup directory after a commit failure. They do not restore automatically;
inspect the recorded paths and perform a verified forward repair. Restore from
backups only on explicit user instruction.

## Dashboard settings

The Ungate dashboard tab Codex Beta edits launcher settings through the user-session
control agent `scripts/start-codex-launcher-control.ps1`. The dashboard service does
not read the Beta profile or start Codex. Saving writes the existing JSON files and
does not restart Beta; apply changes by running `scripts/start-codex-desktop-ungate.ps1`
after active requests finish. Diagnostics use the same qualified request model as a
normal launch, including an upstream prefix, and never return API keys to the browser.
