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
| Models | Builtins, identities, custom model registry, context windows | None |
| Toml | Pure TOML text transformations | None |
| Desktop | CLI/AppX discovery, process lifecycle, MSIX fallback, sandbox, workspace roots | None |
| Routing | Providers, shell IDs and route records, provider TOML | Toml |
| Logging | Log preferences, menu, event formatting and live watch | Desktop |
| Picker | Model selection, picker preferences and add-model wizard | Models, Logging, ToolCompatibility |
| ProxyRuntime | Credentials, bridge/router lifecycle, provider preflight | Routing, existing common helpers |
| ToolCompatibility | Diagnostic model selection, credentials and standalone schema runner | Models, ProxyRuntime |
| Catalog | Model catalog generation, catalog/config verification | Models, Routing, Toml, Desktop |
| Profile | Initial config, MCP transaction/rollback, shared skills, AGENTS and auth | Routing, Toml, Desktop |
| Launcher | Selection, transport, profile preparation and launch orchestration | Above modules, existing plugin-isolation module |

Modules use explicit local imports and explicit exports; internal helpers
remain private. Importing a module does not prepare a profile, discover an
installed Desktop, call a provider or launch/stop a process. There is no
mutable per-launch module or global state and no dependency cycle.

`environment-instructions.txt` contains the unchanged instruction text used
to build model identities. The context factory reads it explicitly. Builtin
definitions are newly constructed on each call to `New-UngateModelSet`.

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
2. Resolve registry/picker selection and launch model/provider; print history
   diagnostics; discover the Beta package and close it unless `PrepareOnly`.
3. Resolve provider keys, ensure required bridge/router, then preflight.
   Normal preflight has two attempts; fallback has one. Preflight failure
   remains a warning and does not skip profile preparation.
4. Initialize config, write the model catalog **before** MCP validation,
   synchronize MCP/skills/instructions/auth, prepare isolated plugins, verify
   the config, initialize sandbox and restore workspace roots.
5. `PrepareOnly` returns `0` on success or `2` after a preflight warning.
   Normal execution starts Desktop and optionally watches logs. `NoLogWatch`
   overrides log preferences; otherwise a nonempty explicit level overrides
   persisted preferences. `Off` starts Desktop without watching.

Except for the additive `TestTools` mode, existing public parameters, persisted file formats, model order, shell
mapping and [routing matrix](model-routing.md) are unchanged. Normal Codex
config remains read-only. MCP rollback is preserved. Temporarily changed
environment values are restored on failure, including removing provider
variables that were originally absent (rather than leaving an empty value
on newer .NET versions).

## Safe verification

From the repository root:

```powershell
pnpm --filter @ungate/scripts run launcher:test
```

The runner parses all launcher modules and related PowerShell sources, then
runs Pester **5.8.0** over the original launcher scenarios, module/flow tests,
common helper tests and plugin-isolation tests. It exits nonzero for syntax,
discovery, container or test failures. Pester 5.8.0 must already be installed;
the runner does not install dependencies or change the machine.

Tests import actual modules, pass explicit contexts and use module-scoped
mocks at network/process boundaries. File-writing scenarios use `TestDrive`;
the add-model CLI test runs against a disposable profile. The frozen model
fixture was captured from the pre-refactor definitions; identity SHA256
values verify instruction bytes without repeating the text in each record.
JSON object key order is irrelevant, but model/array order is significant.

Do not use the real launcher `-PrepareOnly` as a read-only check: it writes
the target profile and can restart the model-shell router. Automated
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

Requests run sequentially: control without tools, each tool (preserving its
namespace wrapper), then the complete set. Each request streams Responses,
has a 120-second timeout and 512 output-token budget, disables tool use with
`tool_choice: none`, and is not retried. No returned tool call is executed.
A completed response or explicit output-token-limit terminal event proves
only schema acceptance. SSE errors, missing terminal events, authentication,
rate limits and timeouts remain distinct from explicit schema rejection.
A failed control skips the remaining probes for that model.

JSON reports in `CustomCodexHome/tool-compatibility/reports/` are updated
after each probe; cancellation preserves partial results. Exit codes:
`0` all accepted (or selection cancelled before testing), `1` explicit schema
rejection, `2` technical failure/incomplete test/cancellation. Code 2 wins
when errors are mixed. No tool blocklist is created or modified.

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
