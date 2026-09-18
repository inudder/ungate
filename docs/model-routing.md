# Codex Beta Launcher Model Routing

This is the canonical operational map for models exposed by
`start-codex-desktop-ungate.ps1`. It tells an AI agent which local component
and which external directory to inspect first. The launcher source remains the
source of truth for exact runtime values; update this document in the same
change when routes change. The entry point delegates to the modules in
`scripts/codex-desktop-launcher/`: `Context.psm1` owns endpoint defaults,
`Models.psm1` owns model definitions, `Routing.psm1` constructs shell routes,
and `ProxyRuntime.psm1` owns transport startup and preflight. See
[Desktop launcher architecture](desktop-launcher.md) for the module map and
the isolated test command. The modular refactor does not change the routing
matrix below.

## Local endpoints

| Component | Endpoint | Repository or data location | Responsibility |
| --- | --- | --- | --- |
| Ungate Responses proxy | `http://127.0.0.1:47821` | `J:\Dev\ungate-local\apps\api` | Direct Ungate and MiniMax Responses routes |
| CLIProxyAPI upstream | `http://127.0.0.1:8317` | `J:\Sandbox\CLIProxyAPI` | External CLIProxyAPI server and Grok upstream |
| CLIProxy namespace bridge | `http://127.0.0.1:8318` | `J:\Dev\ungate-local\scripts\cliproxy-namespace-bridge.mjs` | Converts Codex namespace tools to flat CLIProxy function tools and restores responses |
| Codex model-shell router | `http://127.0.0.1:8319` | `J:\Dev\ungate-local\scripts\codex-model-shell-router.mjs` | Selects the route, rewrites model id, and enables only the configured stream adapter |
| OmniRoute | `http://127.0.0.1:20128` | `%APPDATA%\omniroute` | OmniRoute provider/combo routing and call logs |

## OmniRoute credential separation

Keep the OmniRoute server master key and the Codex client key distinct. The
OmniRoute process treats its `OMNIROUTE_API_KEY` value as an unrestricted
environment/master key before consulting SQLite API-key permissions. Reusing
that value for a restricted `codex-local` database record therefore bypasses
its model allow-list and exposes the full `/v1/models` catalog.

The launcher resolves its OmniRoute client credential in this order:

1. Explicit `-ApiKey` argument.
2. `OMNIROUTE_CODEX_API_KEY` (preferred restricted client key).
3. `OMNIROUTE_API_KEY` (legacy compatibility fallback).

The resolved client credential is still exported to the router and Codex child
process as `OMNIROUTE_API_KEY`, because that is the provider `env_key` contract.
This does not change the already-running OmniRoute server process environment.
Never store either secret in this repository or in diagnostic output.

## Launcher modes

| Mode | Display model | Upstream model | Provider/transport | Tool adapter |
| --- | --- | --- | --- | --- |
| 1 | Claude Fable 5 (Ungate) | `claude-fable-5` | Ungate proxy `47821` | None in model-shell router; compatibility belongs to `apps\api` |
| 2 | MiniMax M3 (Ungate) | Launcher leaves id unset; API normalizes it | Ungate proxy `47821` | MiniMax inline Responses parser in `apps\api`; do not use Mimo adapter; 1M context window (official MiniMax Codex `model_context_window`) |
| 3 | Grok 4.6 (CLIProxyAPI) | `grok-4.6` | Router `8319` -> bridge `8318` -> CLIProxyAPI `8317` | CLIProxy namespace bridge only; no Mimo adapter; 500k context window (conservative until xAI publishes the 4.6 model card) |
| 4 | Kimi K3 (OmniRoute) | `apikey-fun/kimi-k3` | OmniRoute `20128` | No route-specific stream adapter |
| 5 | Grok 4.5 (apikey.fun) | `apikey-fun/grok-4.5` | OmniRoute `20128` | No route-specific stream adapter |
| 6 | Claude Opus 5 (apikey.fun) | `apikey-fun/claude-opus-5` | OmniRoute `20128` | No route-specific stream adapter |
| 7 | Mimo v2.5 Pro (OmniRoute) | `mimo-v2.5-pro` | OmniRoute `20128` | `mimo-textual-tools` via `scripts\mimo-responses-stream-adapter.mjs`; 1M context window (official, unsqueezed) |
| — | DeepSeek V4 Pro (OmniRoute) | `deepseek/deepseek-v4-pro` | OmniRoute `20128` | No route-specific stream adapter; 1M context window (official DeepSeek) |
| — | DeepSeek V4 Flash (OmniRoute) | `deepseek/deepseek-v4-flash` | OmniRoute `20128` | No route-specific stream adapter; 1M context window (official DeepSeek) |
| 9 | Provider fallback (opt-in) | `codex-fallback` | OmniRoute `20128` | Fallback policy chooses the configured upstream; verify the generated route before debugging a provider |

Mode 8 only opens the Desktop model picker. Mode 10 adds a model definition;
it supports Ungate, CLIProxyAPI, and OmniRoute transports. DeepSeek V4 Pro
and DeepSeek V4 Flash can be selected via the Desktop model picker (Mode 8)
or via `-Model deepseek-v4-pro` / `-Model deepseek-v4-flash` (alias `deepseek-flash`).

## Route boundaries

- The Mimo stream adapter is enabled only for the Mimo `/v1/responses`
  streaming route when the route has `responsesAdapter = mimo-textual-tools`.
- The CLIProxy bridge is for CLIProxyAPI models, currently mode 3 Grok. It
  must not be inserted into direct Ungate or OmniRoute routes.
- MiniMax tool compatibility is an `apps\api` concern and remains separate
  from the Mimo adapter.
- The launcher starts or reuses the model-shell router for every selected
  model, so a successful router health check does not prove that the selected
  upstream or tool protocol is correct.

## Bridges vs adapters

The model-shell router on `8319` is the common front door. What happens after
it is not the same for every model. Do not treat "bridge" and "adapter" as
synonyms when debugging tool calls, empty turns, or yield/`wait` protocol
failures.

### Bridge

A bridge is a **separate HTTP proxy process** with its own port and lifetime.
Codex talks to the bridge; the bridge talks to a different upstream server.

There is currently one bridge: `scripts/cliproxy-namespace-bridge.mjs` on
`8318`. The Desktop launcher starts or reuses it. It forwards to CLIProxyAPI
on `8317` (`J:\Sandbox\CLIProxyAPI`).

Use a bridge when the next hop is another server that does not speak Codex's
tool schema. The bridge owns the full request/response cycle: flatten on the
way in, restore on the way out, plus any hop-specific repairs.

### Adapter

An adapter is a **stream transform inside the router**. It has no extra port
and no separate process. The router still opens the upstream connection; the
adapter rewrites bytes as they pass through.

There is currently one adapter: `scripts/mimo-responses-stream-adapter.mjs`
(with `scripts/mimo-responses-namespace.mjs`) for Mimo when the route sets
`responsesAdapter = mimo-textual-tools`. The router connects to OmniRoute
`20128`; the adapter converts Chat Completions or textual/native tool calls
into Codex Responses SSE.

### Why Grok 4.6 needs a bridge

Grok 4.6 is the only launcher model that terminates on CLIProxyAPI (xAI CLI
chat proxy), not Ungate API and not OmniRoute.

Codex Desktop Responses sends MCP tools as `type: "namespace"` (nested
`mcp__...` tools, plus custom `exec`). CLIProxyAPI expects ordinary flat OpenAI
`function` tools (`mcp__foo__js`). Tool-call history and `tool_choice` use the
same nested-versus-flat split. Without a hop that flattens names on the
request and restores `namespace` plus the original tool name on the response,
Grok cannot see Codex tools correctly, or Codex cannot map calls back.

That mismatch does not belong in `apps/api`: Grok never calls `47821`. It
does not belong in the Mimo adapter: OmniRoute is not on this path. It does
not belong in the router as a CLIProxy schema teacher: the router only selects
a URL and optionally enables a stream adapter.

The same hop also repairs CLIProxy-specific shape drift that Codex still
expects:

- custom `exec` as a function tool on the way upstream, restored on the way back;
- `exec` bodies that wrap `await tools.wait({ cell_id })`, rewritten to native `wait`;
- Chat Completions SSE translated into Responses events;
- unresolved `Script running with cell ID N` yields: if the model returns
  `stop` with no tool call, the bridge synthesizes native `wait` before
  `response.completed`. A reasoning-only stop is not a finished turn.

After changing the bridge, run `pnpm --filter @ungate/scripts run bridge:test`.
The process on `8318` picks up code only after a Desktop launcher restart. Do
not rebuild or restart `ungate-api` for bridge-only changes.

### Where other models keep compatibility

- Modes 1-2, Claude Fable 5 and MiniMax M3: Ungate Responses proxy `47821`.
  Namespace and MiniMax tool compatibility live in `apps/api` Responses
  handlers. Do not insert the CLIProxy bridge or the Mimo adapter.
- Modes 4-6, Kimi K3, Grok 4.5, Claude Opus 5, DeepSeek V4 Pro, and DeepSeek V4 Flash: router `8319`
  to OmniRoute `20128` with neither a bridge nor an adapter.
- Mode 7, Mimo v2.5 Pro: router adapter only. Protocol repair for Mimo belongs
  in `mimo-responses-stream-adapter.mjs` / `mimo-responses-namespace.mjs`, not
  in the Grok bridge.

## Where to look first

### Grok 4.6 (CLIProxyAPI), mode 3

1. `J:\Sandbox\CLIProxyAPI` for upstream configuration, provider auth, model
   availability, and upstream logs.
2. `scripts\cliproxy-namespace-bridge.mjs` for namespace flattening, tool
   choice/history conversion, and response restoration.
   If the latest tool output is an unresolved `Script running with cell ID`
   yield and the model returns no tool call, the bridge synthesizes a native
   `wait` before `response.completed`.
3. `scripts\codex-model-shell-router.mjs` for route selection and downstream
   disconnect/pipeline errors.
4. Session transcript and Desktop/router logs only after confirming the
   upstream path.

CLIProxyAPI builds `/v1/models` from credentials that are currently eligible,
so a temporarily expired, disabled, or quota-limited xAI credential can remove
`grok-4.6` from discovery. The launcher treats discovery as advisory and uses
the authenticated text and tool-call `/v1/responses` probes as the authoritative
preflight. An `auth_unavailable` response still fails preflight and requires xAI
reauthentication in CLIProxyAPI.

### Mimo v2.5 Pro, mode 7

1. `%APPDATA%\omniroute\call_logs\YYYY-MM-DD\*.json` for status, finish
   reason, watchdog timeouts, and client disconnects.
2. `scripts\mimo-responses-stream-adapter.mjs` for Chat Completions or
   textual/native tool-call conversion into Responses SSE events.
3. `scripts\mimo-responses-namespace.mjs` for namespace flattening and
   restoration.
4. `scripts\codex-model-shell-router.mjs` for adapter activation and stream
   lifecycle.

### Direct Ungate or MiniMax, modes 1-2

1. `apps\api\src\routes\responses.ts` and the provider handler selected by
   `apps\api\src\orchestration\openai\model-routing.ts`.
2. MiniMax inline tool-call and Responses synthesizer tests.
3. `ungate-api` service logs and the `47821` health/preflight result.

## Adding an OmniRoute model checklist

When exposing a new provider model from OmniRoute through the Desktop launcher:

1. **OmniRoute client key allow-list (`api_keys.allowed_models`)**:
   - The launcher uses the restricted `codex-local` key (resolved via `OMNIROUTE_CODEX_API_KEY`).
   - Add the model's IDs (both prefixed and bare forms, e.g. `"deepseek/deepseek-v4-flash"`, `"deepseek-v4-flash"`, `"deepseek-flash"`) to the `allowed_models` JSON array of the `codex-local` record in `%APPDATA%\omniroute\storage.sqlite`.
2. **OmniRoute active live catalog gating (`key_value` table)**:
   - OmniRoute validates incoming model IDs against the connection's active synced catalog (`getActiveSyncedCatalog`).
   - Ensure the connection entry in `key_value` (`<providerId>:<connectionId>`) lists the expected model ID (e.g. `[{"id":"deepseek-flash",...},{"id":"deepseek-v4-flash",...}]`), otherwise requests fail with HTTP 400: `Model '<id>' is not available in the active live catalog for provider '<provider>'`.
3. **Launcher model definitions & aliases (`scripts/codex-desktop-launcher/Models.psm1`)**:
   - Add built-in definition in `New-UngateModelSet` with `Slug`, `DisplayName`, `UpstreamModel`, `Aliases`, `ContextWindow`, and `SupportedReasoningLevels`.
   - `Aliases` enable friendly command-line resolution (e.g. `-Model deepseek-flash` mapping to `deepseek-v4-flash`).
4. **Desktop picker configuration (`%USERPROFILE%\.codex-ungate\ungate-picker-models.json`)**:
   - The native desktop picker supports at most 7 models (`$CodexDesktopPickerCapacity = 7`).
   - Add the slug to `modelSlugs` if it should appear directly in the interactive menu without manual reconfiguration.
5. **Test fixture snapshot synchronization (`tests/fixtures/models.json`)**:
   - `scripts/codex-desktop-launcher/tests/fixtures/models.json` holds the snapshot for `Launcher.Tests.ps1`, including `IdentitySha256` hashes computed against `environment-instructions.txt`.
   - After adding built-ins or changing instructions, regenerate this snapshot and update the fallback model count assertion.

## Relevant tests

- Launcher suite: `pwsh scripts/test-codex-desktop-launcher.ps1`
- CLIProxy bridge: `pnpm --filter @ungate/scripts run bridge:test`
- Mimo adapter: `pnpm --filter @ungate/scripts run mimo-adapter:test`
- Router: `scripts\codex-model-shell-router.test.mjs`
- MiniMax/API Responses: tests under `apps\api\tests\unit` and the
  Responses orchestration suites.

Do not copy API keys, full tool arguments, patch contents, or provider secrets
into this document or into diagnostic notes.
