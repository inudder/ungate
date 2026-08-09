# Codex Beta Launcher Model Routing

This is the canonical operational map for models exposed by
`start-codex-desktop-ungate.ps1`. It tells an AI agent which local component
and which external directory to inspect first. The launcher source remains the
source of truth for exact runtime values; update this document in the same
change when routes change.

## Local endpoints

| Component | Endpoint | Repository or data location | Responsibility |
| --- | --- | --- | --- |
| Ungate Responses proxy | `http://127.0.0.1:47821` | `J:\Dev\ungate-local\apps\api` | Direct Ungate and MiniMax Responses routes |
| CLIProxyAPI upstream | `http://127.0.0.1:8317` | `J:\Sandbox\CLIProxyAPI` | External CLIProxyAPI server and Grok upstream |
| CLIProxy namespace bridge | `http://127.0.0.1:8318` | `J:\Dev\ungate-local\scripts\cliproxy-namespace-bridge.mjs` | Converts Codex namespace tools to flat CLIProxy function tools and restores responses |
| Codex model-shell router | `http://127.0.0.1:8319` | `J:\Dev\ungate-local\scripts\codex-model-shell-router.mjs` | Selects the route, rewrites model id, and enables only the configured stream adapter |
| OmniRoute | `http://127.0.0.1:20128` | `%APPDATA%\omniroute` | OmniRoute provider/combo routing and call logs |

## Launcher modes

| Mode | Display model | Upstream model | Provider/transport | Tool adapter |
| --- | --- | --- | --- | --- |
| 1 | Claude Fable 5 (Ungate) | `claude-fable-5` | Ungate proxy `47821` | None in model-shell router; compatibility belongs to `apps\api` |
| 2 | MiniMax M3 (Ungate) | Launcher leaves id unset; API normalizes it | Ungate proxy `47821` | MiniMax inline Responses parser in `apps\api`; do not use Mimo adapter |
| 3 | Grok 4.5 (CLIProxyAPI) | `grok-4.5` | Router `8319` -> bridge `8318` -> CLIProxyAPI `8317` | CLIProxy namespace bridge only; no Mimo adapter |
| 4 | Kimi K3 (OmniRoute) | `apikey-fun/kimi-k3` | OmniRoute `20128` | No route-specific stream adapter |
| 5 | Grok 4.5 (apikey.fun) | `apikey-fun/grok-4.5` | OmniRoute `20128` | No route-specific stream adapter |
| 6 | Claude Opus 5 (apikey.fun) | `apikey-fun/claude-opus-5` | OmniRoute `20128` | No route-specific stream adapter |
| 7 | Mimo v2.5 Pro (OmniRoute) | `mimo-v2.5-pro` | OmniRoute `20128` | `mimo-textual-tools` via `scripts\mimo-responses-stream-adapter.mjs` |
| 9 | Provider fallback (opt-in) | `codex-fallback` | OmniRoute `20128` | Fallback policy chooses the configured upstream; verify the generated route before debugging a provider |

Mode 8 only opens the Desktop model picker. Mode 10 adds a model definition;
it does not define a new transport by itself.

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

## Where to look first

### Grok 4.5 (CLIProxyAPI), mode 3

1. `J:\Sandbox\CLIProxyAPI` for upstream configuration, provider auth, model
   availability, and upstream logs.
2. `scripts\cliproxy-namespace-bridge.mjs` for namespace flattening, tool
   choice/history conversion, and response restoration.
3. `scripts\codex-model-shell-router.mjs` for route selection and downstream
   disconnect/pipeline errors.
4. Session transcript and Desktop/router logs only after confirming the
   upstream path.

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

## Relevant tests

- CLIProxy bridge: `pnpm --filter @ungate/scripts run bridge:test`
- Mimo adapter: `pnpm --filter @ungate/scripts run mimo-adapter:test`
- Router: `scripts\codex-model-shell-router.test.mjs`
- MiniMax/API Responses: tests under `apps\api\tests\unit` and the
  Responses orchestration suites.

Do not copy API keys, full tool arguments, patch contents, or provider secrets
into this document or into diagnostic notes.
