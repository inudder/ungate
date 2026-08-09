## Launcher model routing contract

The Desktop launcher is implemented in
`J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1`. The complete
model/provider matrix and external-directory map are maintained in
`J:\Dev\ungate-local\docs\model-routing.md`.

When investigating a model, follow its actual route before changing code:

- Mode 3, Grok 4.5 (CLIProxyAPI): model-shell router `8319` -> local
  namespace bridge `8318` -> CLIProxyAPI upstream `8317`; inspect
  `J:\Sandbox\CLIProxyAPI` first, then
  `scripts\cliproxy-namespace-bridge.mjs` and
  `scripts\codex-model-shell-router.mjs`.
- Mode 7, Mimo v2.5 Pro (OmniRoute): model-shell router `8319` -> OmniRoute
  `20128`; inspect `%APPDATA%\omniroute` call logs, then
  `scripts\mimo-responses-stream-adapter.mjs` and the router.
- Modes 4-6, Kimi K3, Grok 4.5, and Claude Opus 5 (apikey.fun): model-shell
  router `8319` -> OmniRoute `20128`; no CLIProxy bridge and no Mimo adapter.
- Modes 1-2, Claude Fable 5 and MiniMax M3 (Ungate): model-shell router
  `8319` -> Ungate Responses proxy `47821`; inspect `apps\api` and its
  provider-specific Responses handlers. Do not use the CLIProxy bridge or
  Mimo adapter for these routes.

If the launcher, this file, and the detailed matrix disagree, the launcher
route definitions are authoritative. Keep this contract short and update the
detailed matrix whenever a route, port, adapter, or external project changes.

## Codex Beta and Mimo session logs

When diagnosing a Codex Desktop session routed through Mimo, inspect the logs
in this order:

1. Session transcript (model-visible events, tool calls, turn lifecycle):
   `C:\Users\kalvinclein\.codex-ungate\sessions\YYYY\MM\DD\rollout-*.jsonl`
2. Codex Beta desktop/app-server log (renderer and CLI bridge errors):
   `C:\Users\kalvinclein\AppData\Local\Packages\OpenAI.CodexBeta_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\YYYY\MM\DD\codex-desktop-*.log`
3. OmniRoute request/response record (upstream status, timing, token counts,
   finish reason and disconnect errors):
   `C:\Users\kalvinclein\AppData\Roaming\omniroute\call_logs\YYYY-MM-DD\*.json`
4. Local model-shell router lifecycle and request timings:
   `C:\Users\kalvinclein\.codex-ungate\logs\codex-model-shell-router.out.log`

Correlate records by UTC timestamp, then by `turn_id`/`threadId` and the
OmniRoute request timestamp. Useful search terms are
`turn_aborted`, `task_complete`, `OutputTextDelta without active item`,
`turn_completed_with_incomplete_plan`, `mimo-responses-adapter`,
`mimo_tool_call_parse_error`, `request_signal_aborted` and `finish_reason`.

Interpretation rules:

- OmniRoute status `499` with `Client disconnected: request_signal_aborted` and
  zero output tokens means Codex cancelled the request; it is not an upstream
  tool-call parsing failure.
- Status `200` with `finish_reason=stop` means Mimo completed its response. If
  no tool call follows, inspect the session transcript for why the model only
  emitted text or reasoning.
- OmniRoute `504` with `Stream produced no non-ping SSE event within 95000ms`
  (often followed by `[504] Combo ... all targets exhausted`) is the
  OmniRoute-to-Mimo upstream watchdog. A local router heartbeat cannot reset
  that upstream timer; distinguish it from a local `mimo_tool_call_parse_error`.
- Repeated `OutputTextDelta without active item` indicates an invalid Responses
  SSE lifecycle reaching Codex. For Mimo, also check the adapter diagnostic;
  it logs the model, tool name and input byte count, never patch contents or
  API keys.

PowerShell commands for the newest records:

```powershell
$sessionRoot = Join-Path $env:USERPROFILE '.codex-ungate\sessions'
Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter '*.jsonl' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$desktopLogRoot = Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.CodexBeta_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs'
Get-ChildItem -LiteralPath $desktopLogRoot -Recurse -File -Filter '*.log' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
```

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## ungate-api NSSM service

The `ungate-api` NSSM service runs `apps/api/bundle/main.cjs`. A normal API
`build` updates `dist/` only and does not update the running service artifact.

After changing API runtime code or anything bundled into it (including
`apps/api/src/**`, API dependencies/config, or shared packages imported by the
API), the agent must update the local service before finishing:

```powershell
pnpm --filter @ungate/api build
pnpm --filter @ungate/api build:bundle
nssm restart ungate-api
pwsh .\scripts\start-codex-ungate.ps1 -PreflightOnly
```

Run these commands sequentially. Restart the service only when both builds
succeed. Treat a failed restart or preflight as an unresolved task and report
it explicitly.

Do not rebuild or restart `ungate-api` for changes limited to tests,
documentation, graphify output, frontend code, or scripts that are not loaded
by the API process.

## CLIProxy namespace bridge

`scripts/cliproxy-namespace-bridge.mjs` is a local compatibility proxy for
CLIProxyAPI models, currently Grok 4.5. The Desktop launcher starts or reuses
it on port `8318`; it forwards to CLIProxyAPI on port `8317`.

Codex Responses sends MCP tools as `type: "namespace"`, while the CLIProxyAPI
upstream expects ordinary flat function tools. The bridge flattens namespace
tools, tool-call history, and tool choice on the request, then restores the
`namespace` and original tool name in JSON and SSE responses for Codex.

Do not use this bridge for direct Ungate models (`ungate-opus-4-8`,
`ungate-fable-5`, or `miniMax-M3`): they call `ungate-api` on port `47821`.
Their namespace-tool compatibility belongs in the API Responses route, not in
the CLIProxy bridge. After changing the bridge, run:

```powershell
pnpm --filter @ungate/scripts run bridge:test
```
