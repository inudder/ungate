## Launcher model routing contract

The Desktop launcher is implemented in
`J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1`. The complete
model/provider matrix and external-directory map are maintained in
`J:\Dev\ungate-local\docs\model-routing.md`.

Bridge versus adapter, why Grok 4.6 has a hop, and where each model's tool
compatibility lives: `docs/model-routing.md#bridges-vs-adapters`.

When investigating a model, follow its actual route before changing code:

- Mode 3, Grok 4.6 (CLIProxyAPI): model-shell router `8319` -> local
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

## Codex Beta config sync

Codex Beta uses `C:\Users\kalvinclein\.codex-ungate\config.toml` as
`CODEX_HOME`. That file is independent of the normal Codex profile except for
the launcher sync below.

The first launcher run copies
`C:\Users\kalvinclein\.codex\config.toml` into the Beta home, then
patches Ungate `model` / `model_provider` values. Every later launcher start
replaces the entire `[mcp_servers.*]` table family in the Beta config from
`C:\Users\kalvinclein\.codex\config.toml`. Edit MCP servers,
including Playwright args, in the normal Codex config and relaunch Beta
through the launcher. MCP edits made only in `.codex-ungate` are overwritten.

`AGENTS.md` and `auth.json` are also copied from the normal Codex home on
each launch. Other Beta settings stay independent. A running Codex Beta
process does not pick up MCP changes until it is restarted via the launcher.

## Codex Beta and Mimo session logs


When diagnosing a Codex Desktop session, start with the session transcript.
OmniRoute call logs are an extra hop for Mimo (mode 7) and other OmniRoute
routes (modes 4-6). Do not treat OmniRoute as the primary session log.

Two Codex homes:

- Codex Beta (`CODEX_HOME` `.codex-ungate`): this launcher profile.
- Normal Codex (`.codex`): the non-Beta Desktop profile.

Inspect logs in this order:

1. Session transcript (model-visible events, tool calls, turn lifecycle):
   Beta: `C:\Users\kalvinclein\.codex-ungate\sessions\YYYY\MM\DD\rollout-*.jsonl`
   Normal: `C:\Users\kalvinclein\.codex\sessions\YYYY\MM\DD\rollout-*.jsonl`
   The newest `LastWriteTime` in that home is usually the active chat.
   Match a project by `payload.cwd` in the first `session_meta` / later
   `turn_context` records (for example `J:\\Dev\\gambling-landing-generator`).
2. Codex Beta desktop/app-server log (renderer and CLI bridge errors):
   `C:\Users\kalvinclein\AppData\Local\Packages\OpenAI.CodexBeta_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs\YYYY\MM\DD\codex-desktop-*.log`
3. Local model-shell router lifecycle and request timings:
   `C:\Users\kalvinclein\.codex-ungate\logs\codex-model-shell-router.out.log`
4. Grok 4.6 / CLIProxy bridge (mode 3 only):
   `C:\Users\kalvinclein\.codex-ungate\logs\cliproxy-namespace-bridge.out.log`
5. For Mimo and other OmniRoute routes, also inspect OmniRoute request/response
   records (upstream status, timing, token counts, finish reason, disconnects):
   `C:\Users\kalvinclein\AppData\Roaming\omniroute\call_logs\YYYY-MM-DD\*.json`

Correlate records by UTC timestamp, then by `turn_id`/`threadId` and the
OmniRoute request timestamp when that hop is in the route. Useful search terms are
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

$normalSessionRoot = Join-Path $env:USERPROFILE '.codex\sessions'
Get-ChildItem -LiteralPath $normalSessionRoot -Recurse -File -Filter '*.jsonl' |
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
CLIProxyAPI models, currently Grok 4.6. The Desktop launcher starts or reuses
it on port `8318`; it forwards to CLIProxyAPI on port `8317`.

Why this hop exists, how it differs from the Mimo adapter, and which models
must not use it: `docs/model-routing.md#bridges-vs-adapters`.

Do not use this bridge for direct Ungate models. After changing the bridge,
run:

```powershell
pnpm --filter @ungate/scripts run bridge:test
```

## Code validation and project publication

After writing or modifying code in this project:

1. Run the relevant syntax and behavior checks. For JavaScript or `.mjs` files, use `node --check <path>`; for PowerShell files, parse with `Parser.ParseFile`; then run the focused test suite.
2. Publish the completed project change with the project manager using a concise commit message:

```powershell
pwsh -NoProfile -File "J:\Dev\dev-project-manager\dev-projects.ps1" ungate-local push -m "message"
```

Do not report the code change as complete until validation and `ungate-local push` have been run, unless the command is blocked by an external failure; in that case report the exact failure.

<!-- BEGIN MANAGED GRAPHIFY INSTRUCTIONS -->
## Graphify — обязательный workflow

Проект индексируется Graphify. Граф: `graphify-out/graph.json`.
Расширенная справка (команды, backend, верификация, типовые проблемы):
`docs/graphify.md`. Читай её по мере нужды, не целиком в начале каждой сессии.

Граф — навигация и карта связей. Источник истины — исходники и тесты.
Рёбра `INFERRED` и `AMBIGUOUS` подтверждай по коду.
`EXTRACTED` — сильный сигнал из AST, но не замена чтению кода,
если от вывода зависит правка или runtime-поведение.

НЕ редактируй `graphify-out/` вручную.
НЕ передавай `--backend` при обычной индексации кода.
НЕ запускай облачный backend по своей инициативе.

### Перед анализом кода (до широкого grep и обхода файлов)

1. `test -f graphify-out/graph.json`
   - нет графа → `graphify extract . --code-only`
     (если установлен skill ассистента: `/graphify .`)
2. Обновляй граф заранее только если только что был `git pull` / merge,
   в сессии уже меняли код, или предыдущий query не видит свежие файлы.
   Иначе сразу к шагу 3.
   При сомнении: `graphify check-update .` → при изменениях: `graphify update .`
3. Точечные вопросы — сразу к графу:
   - `graphify query "<вопрос>"`
   - `graphify explain "<Concept>"`
   - `graphify path "<A>" "<B>"`
   MCP, если уже запущен: `query_graph`, `get_node`, `get_neighbors`, `shortest_path`.
   После `update` CLI свежее MCP: сервер не подхватывает новый `graph.json`
   без перезапуска.
   Обзор архитектуры: `graphify-out/GRAPH_REPORT.md`.
   Навигация по подсистемам, если есть: `graphify-out/wiki/index.md`.

Грязные файлы в `graphify-out/` после hook/update ожидаемы —
из-за этого граф не пропускай.

### После создания / изменения / удаления кода

`graphify update .`  (AST-only, без API)

После массового удаления, переименования или если update отказался
записать меньший граф: `graphify update . --force`
Не используй `--force` без такой причины.
<!-- END MANAGED GRAPHIFY INSTRUCTIONS -->
