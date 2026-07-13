# Ungate (Local) AI Context

Ungate — это Cursor-расширение, которое позволяет использовать подписки Claude, ChatGPT и MiniMax в Cursor вместо оплаты API-токенов. Расширение запускает локальный HTTP-прокси (Fastify), который транслирует OpenAI-формат запросов в формат провайдера, и публикует его через публичный туннель, чтобы бэкенд Cursor мог достучаться до прокси. Этот репозиторий — **локальный форк** `orchidfiles/ungate` v1.7.1 с тремя существенными пользовательскими модификациями: Wake Ping (поддержание квоты Claude), хардкод туннеля на кастомный FRP-домен, и запуск API как Windows-службы NSSM. Самые рискованные изменения — любое изменение маршрутов `/v1/chat/completions` и `/v1/messages`, схемы БД, OAuth-потоков, путей storage (`~/.ungate/`), хардкоженного туннель-URL, и логики leader-window election. Документ нужен AI-агенту, чтобы безопасно модифицировать проект без потери production-контекста.

---

## 1. Project Identity

| Поле | Значение | Evidence |
|---|---|---|
| Project name | Ungate (Local sources) | `apps/extension/package.json:3` — `displayName: "Ungate (Local sources)"` |
| Package name (extension) | `ungate-local` | `apps/extension/package.json:2` |
| Package name (api) | `@ungate/api` | `apps/api/package.json:2` |
| Root package | `@ungate/root` (private) | `package.json:2` |
| Version | `1.7.1-local.7` | `apps/extension/package.json:5` — **Drift**: `LOCAL-SETUP.md:7` и `SOURCE-INFO.md:21` утверждают `1.7.1-local.0` |
| Publisher | `orchidfiles` | `apps/extension/package.json:6` |
| Primary language | TypeScript (ESM) | `package.json:4` — `"type": "module"` |
| Runtime | Node.js >= 22 | `package.json:7`, `apps/api/tsup.config.ts:7` — `target: 'node22'` |
| Framework (API) | Fastify ~5.8.5 | `apps/api/package.json:25` |
| Framework (web) | Svelte ~5.55 + Vite ~8.0 | `apps/web/package.json:29,34` |
| ORM | Drizzle-ORM ~0.43 + better-sqlite3 12.9 | `apps/api/package.json:23,24` |
| Package manager | pnpm 11.8.0 | `package.json:5` |
| Project type | VS Code / Cursor extension + bundled local API proxy + webview dashboard | `apps/extension/package.json:43` — `main: ./dist/extension.js` |
| Extension ID | `orchidfiles.ungate-local` | publisher + name |
| VS Code engine | `^1.96.0` | `apps/extension/package.json:34` |
| Version source of truth | `apps/extension/package.json` поле `version` | `scripts/build-and-install.ps1:34-46` auto-bump `x.y.z-local.N → N+1` |
| Min runtime requirements | Node 22 на машине (расширение спавнит system Node для API) | `README.md:78`, `apps/extension/src/utils/node-resolver.ts` |

Evidence:
- `package.json` — root manifest, engines, packageManager.
- `apps/extension/package.json` — extension identity, version, contributes.
- `apps/api/package.json` — API dependencies, scripts.

---

## 2. Project Role

Ungate решает задачу: использовать подписочные квоты Claude/ChatGPT/MiniMax в Cursor, который поддерживает только custom OpenAI Base URL. Проект находится **между** бэкендом Cursor и API провайдеров.

**Surfaces:**
- **HTTP API** (Fastify, порт 47821 по умолчанию) — принимает OpenAI-формат запросов от Cursor backend, транслирует и форвардит к провайдеру. `Confirmed by code` — `apps/api/src/server.ts:102`.
- **VS Code extension** — управляет lifecycle API процесса, туннелем, OAuth, dashboard webview, status bar. `Confirmed by code` — `apps/extension/src/extension.ts:8`.
- **Webview dashboard** (Svelte) — UI для настройки провайдеров, туннеля, моделей, аналитики. `Confirmed by code` — `apps/extension/src/dashboard.ts:150`.
- **CLI** — `pnpm tunnel` standalone cloudflared туннель для dev. `Confirmed by code` — `scripts/tunnel/main.ts`.
- **Windows service** (NSSM `ungate-api`) — API может запускаться как служба, отдельно от extension-spawned процесса. `Confirmed by config` — `scripts/build-and-install.ps1:117-123`.

**Основные сценарии:**
1. Пользователь отправляет chat-запрос в Cursor → Cursor backend → туннель → локальный API → провайдер → обратно.
2. Пользователь настраивает провайдера через dashboard (OAuth для Claude/ChatGPT, API key для MiniMax).
3. Wake Ping периодически пингует Claude для поддержания квоты.

Evidence:
- `README.md:17-48` — архитектурная mermaid-диаграмма.
- `apps/api/src/routes/openai.ts:13` — `/v1/chat/completions` entry.
- `apps/api/src/routes/anthropic.ts:13` — `/v1/messages` entry.

---

## 3. Responsibility Boundaries

**Проект делает:**
- Транслирует OpenAI chat completion requests → Anthropic Messages API / OpenAI Codex `/responses` / MiniMax `/v1/text/chatcompletion_v2`.
- Управляет OAuth-токенами Claude и ChatGPT (получение, хранение, refresh).
- Хранит API key MiniMax.
- Запускает и поддерживает публичный туннель к локальному API.
- Хранит analytics (запросы, токены, estimated cost) в локальной SQLite.
- Поддерживает Wake Ping (периодический ping Claude).
- Re-enables Cursor's `OpenAI API Key` setting когда Cursor его отключает.

**Проект НЕ делает:**
- Не управляет подписками провайдеров (пользователь сам подключает аккаунт).
- Не хранит chat history (только metadata запросов для analytics).
- Не является source of truth для Cursor settings (только toggles один ключ).
- Не деплоит ничего в облако (всё локальное, кроме туннеля).

**Canonical source of truth:**
- `~/.ungate/data.db` — OAuth-токены, API key прокси, model mappings, analytics. `Confirmed by code` — `apps/api/src/database/index.ts:21`.
- `~/.ungate/runtime-state.json` — runtime state (API/tunnel status, leader window, commands). `Confirmed by code` — `apps/extension/src/runtime-state/config.ts:9`.

**Cache/mirror/orchestration only:**
- `~/.ungate/extension.log` — shared log buffer (derived, trimmable). `Confirmed by code` — `apps/extension/src/runtime-state/shared-log-store.ts:8`.
- `bundled/api/wake-ping.json` — конфиг wake-ping (source: `apps/api/wake-ping.json`, копируется при билде). `Confirmed by config` — `scripts/build-package/run.ps1:52`.

**Соседние сервисы / external:**
- Cursor backend (вызывает прокси через туннель).
- Anthropic API (`api.anthropic.com`).
- OpenAI Codex API (`chatgpt.com/backend-api/codex`).
- MiniMax API (`api.minimax.io` / `api.minimaxi.com`).
- Cloudflare tunnel binary (cloudflared) — **но в local fork НЕ используется** (см. §15).
- **frpc** (FRP Client) — туннель к VPS `212.22.94.19:7000`, прокси `ungate-api-47821` (local 127.0.0.1:47821 → remote 47821). Управляется через NSSM-службу `frpc`. **local fork заменил cloudflared на frpc**.
- **NSSM Windows service `ungate-api`** — API запускается как служба через панель `J:\Dev\panel-nssm-service-manager` (импорт JSON в `config/services.json`).

Evidence:
- `apps/api/src/config.ts:5-44` — все external endpoints.
- `apps/extension/src/tunnel-manager.ts:140` — hardcoded tunnel URL.

---

## 4. Runtime and Bootstrap

### API bootstrap
1. `apps/api/src/main.ts:22` — `startServer().catch(...)`.
2. `main.ts:6-20` — регистрируется `uncaughtException` handler: при EPIPE exit(1) молча, иначе пишет crash log в `~/.ungate/extension.log` и exit(1).
3. `server.ts:27` — `getDb()` открывает SQLite, применяет миграции.
4. `server.ts:28-29` — `Settings.get()` (создаёт app_settings row если нет, генерирует API key), `getConfig(settings)`.
5. `server.ts:30` — `setQuietMode(config.quietMode)`.
6. `server.ts:32-35` — создаёт Fastify (`logger: false`), регистрирует `@fastify/cors` (`origin: '*'`).
7. `server.ts:37-43` — регистрирует route plugins: health, auth, anthropic, openai, models, analytics, settings.
8. `server.ts:46-100` — регистрирует `/wake-ping` GET/POST (local addition).
9. `server.ts:102` — `app.listen({ port: config.port, host: '0.0.0.0' })`.
10. `server.ts:106` — `globalThis.console.log('[ungate] listening on localhost:${port}')` — **extension парсит эту строку для детекта порта**.
11. `server.ts:108` — `startWakePingScheduler()`.

### Extension bootstrap
1. `apps/extension/src/extension.ts:8` — `activate()` создаёт `ExtensionController`, вызывает `app.activate()`.
2. `extension-controller.ts:48-144` — создаёт outputChannel, statusBar, dashboard, keyFix, tunnelManager, apiServer; регистрирует 5 команд; запускает heartbeat, runtimeSync, runtimeStateWatch; `bootstrapRuntime()` → `keyFix.activate()`.
3. `extension-controller.ts:549-554` — `bootstrapRuntime`: touchClient, prepareApiForBootstrap, startApiAsLeaderIfNeeded, syncFromRuntimeState.
4. `extension-controller.ts:692-711` — leader window запускает API через `apiServer.start()`.
5. `api-server.ts:128-168` — `doStart()`: проверяет existing port health, ensureNativeDeps (better-sqlite3), spawn.
6. `api-server.ts:184-218` — `spawn()`: dev mode → `dist/main.js` + `DB_PATH=~/.ungate/data-dev.db`; prod → `bundle/main.cjs` + `DRIZZLE_PATH=cwd/drizzle`. Env: `UNGATE_BETTER_SQLITE3_NATIVE_BINDING`. `cp.spawn(runtime, nodeArgs, { cwd, env, stdio: 'pipe', detached: true })`, `unref()`.
7. `api-server.ts:220-238` — `onStdout`: парсит `localhost:(\d+)` для детекта порта.

### Shutdown
- `extension.ts:15-18` — `deactivate()` → `stopBackendServices()`.
- `extension-controller.ts:146-182` — stopBackendServices: removeClient, если leader → `apiServer.stop()`, очищает timers/watchers, `keyFix.stop()`, если нет live clients → `tunnelManager.stop()`.

### Config loading
- `apps/api/src/config.ts:48-63` — `getConfig()`: port из `process.env.PORT` иначе `settings.port` (default 47821); apiKey из settings; quietMode из settings.
- `apps/extension/src/runtime-state/config.ts` — hardcoded paths и intervals (не env-configurable).

Evidence:
- `apps/api/src/main.ts` — entry + EPIPE guard.
- `apps/api/src/server.ts:26-109` — full bootstrap.
- `apps/extension/src/api-server.ts:184-218` — spawn logic.
- `apps/extension/src/extension-controller.ts:48-144` — activation.

---

## 5. Main Modules

### API (`apps/api/`)

| Модуль | Роль | Ключевые файлы | Читает | Пишет | Side effects | Риски |
|---|---|---|---|---|---|---|
| Server | Fastify bootstrap, route registration, wake-ping scheduler start | `src/server.ts` | DB, config | — | listen 0.0.0.0, start scheduler | Изменение route order, порта |
| Database | SQLite + Drizzle, migrations | `src/database/index.ts`, `schema.ts`, `*.ts` | `~/.ungate/data.db` | same | WAL mode, migrations on startup | Schema change без миграции |
| Auth | OAuth Claude/ChatGPT, MiniMax API key | `src/auth/oauth.ts`, `openai/*`, `minimax-provider.ts` | DB provider_settings | DB provider_settings | PKCE sessions in-memory, callback server на :1455 | Token expiry, refresh failure |
| Proxy | Запросы к провайдерам | `src/proxy/anthropic-client.ts`, `openai-client.ts`, `minimax-client.ts` | DB tokens, config | — | HTTP к Anthropic/OpenAI/MiniMax | 401 retry, rate limit |
| Orchestration | Routing, streaming gateway | `src/orchestration/openai/*` | model mappings | — | SSE streaming | Tool mapping, stream errors |
| Routes | HTTP endpoints | `src/routes/*.ts` | DB | DB (requests, settings) | — | Public contract |
| Wake Ping | Periodic Claude ping | `src/wake-ping.ts`, `wake-ping-scheduler.ts` | `wake-ping.json` | `wake-ping.json` | setTimeout scheduler, Claude API call | **Local addition** |
| Adapter | OpenAI↔Anthropic conversion | `src/adapter/*.ts` | — | — | — | Format fidelity |

### Extension (`apps/extension/`)

| Модуль | Роль | Ключевые файлы | Side effects | Риски |
|---|---|---|---|---|
| ExtensionController | Lifecycle, leader election, command queue | `src/extension-controller.ts` | runtime-state.json writes | Race conditions multi-window |
| ApiServer | Spawn/manage API child process | `src/api-server.ts` | cp.spawn, health checks | Port conflicts, process crash loop |
| TunnelManager | Tunnel lifecycle | `src/tunnel-manager.ts` | **Hardcoded URL** | **Не использует cloudflared** |
| Dashboard | Webview panel | `src/dashboard.ts` | Injects WAKE_PING_SCRIPT into HTML | DOM-polling fragility |
| OpenAiKeyFix | Re-enable Cursor OpenAI key | `src/openai-key-fix.ts` | Reads Cursor state.vscdb, executes VS Code command | **Writes to Cursor state** |
| RuntimeStateStore | Cross-window state | `src/runtime-state/*.ts` | runtime-state.json, lock file | Lock contention |
| NodeResolver | Find system Node | `src/utils/node-resolver.ts` | spawnSync | Platform paths |
| BetterSqlite3Installer | Download prebuilt native binary | `src/utils/better-sqlite3-installer.ts` | Downloads from GitHub, writes .node file | Network, ABI mismatch |

### Web (`apps/web/`)
Svelte 5 dashboard. Communicates with extension via `postMessage` (`acquireVsCodeApi`), с API via `fetch` to `localhost:PORT`. Port injected as `window.__PORT__` в HTML. `Confirmed by code` — `apps/web/src/shared/api.ts:11`, `apps/extension/src/dashboard.ts:374`.

### Shared (`packages/shared/`)
Types, schemas (zod), constants, helpers. Dual ESM/CJS build (tsup). Consumed by api, extension, web. `Confirmed by config` — `packages/shared/package.json:4-17`.

### Dev-kit (`packages/dev-kit/`)
ESLint configs, vitest config, `tsconfig.base.json`. Foundation TS config: `target: ES2022`, `module: ESNext`, `moduleResolution: Bundler`, `strict: true`. `Confirmed by config` — `packages/dev-kit/tsconfig.base.json`.

Evidence:
- `apps/api/src/server.ts` — module structure.
- `apps/extension/src/extension-controller.ts` — controller structure.
- `packages/dev-kit/tsconfig.base.json` — base TS config.

---

## 6. Integration Points

### HTTP Routes (API)

| Method | Path | Auth | Вызывает | Мутирует | Contract |
|---|---|---|---|---|---|
| GET | `/health` | нет | — | — | `{status:'ok'}` — используется extension health check |
| POST | `/v1/chat/completions` | proxy API key | Cursor backend (через туннель) | requests table | OpenAI chat completion format |
| POST | `/v1/messages` | proxy API key | Cursor/Anthropic clients | requests table | Anthropic Messages format |
| GET | `/v1/models` | нет | dashboard | — | OpenAI models list format |
| GET | `/settings` | нет | dashboard | — | AppSettings |
| POST | `/settings` | нет | dashboard | app_settings, model_mappings | Zod-validated |
| GET | `/analytics` | нет | dashboard | — | summary by period |
| GET | `/analytics/requests` | нет | dashboard | — | recent requests (max 1000) |
| GET | `/analytics/tokens` | нет | dashboard | — | token time series |
| POST | `/analytics/reset` | нет | dashboard | **DELETE requests** | **Destructive** |
| POST | `/auth/claude/start` | нет | dashboard | — | returns authUrl + sessionId |
| POST | `/auth/claude/complete` | нет | dashboard | provider_settings | OAuth code exchange |
| GET | `/auth/claude/status` | нет | dashboard | — | — |
| POST | `/auth/claude/logout` | нет | dashboard | **DELETE provider_settings** | — |
| GET/POST | `/auth/minimax/*` | нет | dashboard | provider_settings | API key auth |
| GET | `/auth/openai/start` | нет | dashboard | — | starts callback server :1455 |
| GET | `/auth/openai/callback` | нет | browser redirect | provider_settings | HTML response |
| GET/POST | `/auth/openai/*` | нет | dashboard | provider_settings | — |
| GET | `/wake-ping` | нет | extension | — | **Local addition** |
| POST | `/wake-ping` | нет | extension | **wake-ping.json** | **Local addition** |

`Confirmed by code` — `apps/api/src/routes/*.ts`, `apps/api/src/server.ts:46-100`.

### CLI Commands (extension)

| Command ID | Title | Действие |
|---|---|---|
| `ungate.openDashboard` | Open Dashboard | show webview panel |
| `ungate.copyTunnelUrl` | Copy Tunnel URL | clipboard |
| `ungate.restartTunnel` | Restart Tunnel | enqueueCommand |
| `ungate.toggleKeyFix` | Toggle OpenAI Key Fix | enable/disable key fix |
| `ungate.toggleWakePing` | Toggle Wake Ping | POST /wake-ping |

`Confirmed by code` — `apps/extension/package.json:45-66`, `apps/extension/src/extension-commands.ts`.

### Webview messages (extension ↔ webview)
- **Webview → Extension:** `webview-ready`, `restart-server`, `start-tunnel`, `stop-tunnel`, `restart-tunnel`, `toggle-wake-ping`, `set-key-fix-enabled`, `set-wake-ping-schedule`, `clear-logs`, `open-external-url`. `Confirmed by code` — `packages/shared/src/frontend.ts:20-29`.
- **Extension → Webview:** `port`, `tunnel-status`, `key-fix-state`, `wake-ping-state`, `log`, `log-bulk`, `logs-cleared`. `Confirmed by code` — `packages/shared/src/frontend.ts:11-18`.

### External API clients
- **Anthropic:** `https://api.anthropic.com/v1/messages?beta=true` — Bearer token, headers: `anthropic-beta: claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14`, `anthropic-version: 2023-06-01`, `User-Agent: claude-cli/2.1.9`. `Confirmed by code` — `apps/api/src/proxy/anthropic-client.ts:42-62`.
- **OpenAI Codex:** `https://chatgpt.com/backend-api/codex/responses` — Bearer token, `chatgpt-account-id`, `originator: codex_cli_rs`, SSE. `Confirmed by code` — `apps/api/src/proxy/openai-client.ts:87-97`.
- **MiniMax:** `{baseUrl}/v1/text/chatcompletion_v2` — Bearer API key. `Confirmed by code` — `apps/api/src/proxy/minimax-client.ts:61`.

### OAuth callback server
- OpenAI OAuth callback: `http://localhost:1455/auth/callback` — временный HTTP server, auto-shutdown через 10 мин. `Confirmed by code` — `apps/api/src/auth/openai/callback-server.ts:24,37`.

Evidence:
- `apps/api/src/routes/*.ts` — все routes.
- `apps/api/src/plugins/auth.ts:4-14` — proxy API key auth.
- `apps/api/src/config.ts:28-43` — OpenAI OAuth config.

---

## 7. Data Model and Storage

### Database: `~/.ungate/data.db` (SQLite, WAL mode)

| Table | PK | Columns | Source of truth | Создание | Обновление | Invalidation |
|---|---|---|---|---|---|---|
| `app_settings` | `id` (always 1) | `port` (default 47821), `api_key`, `quiet`, `extra_instruction` | **Yes** | `Settings.get()` если row нет | `Settings.update()` | — |
| `provider_settings` | `provider` | `access_token`, `refresh_token`, `expires_at`, `email`, `account_id`, `created_at`, `base_url` | **Yes** (OAuth tokens, API keys) | OAuth login / API key login | refresh, upsert | logout (DELETE) |
| `model_mappings` | `id` (text) | `label`, `provider`, `upstream_model`, `sort_order`, `reasoning_budget` | **Yes** | migrations + dashboard | `ModelMappings.replace()` (transactional delete+insert) | — |
| `requests` | `id` (autoincrement) | `timestamp`, `model`, `source`, `input_tokens`, `output_tokens`, `estimated_cost`, `stream`, `latency_ms`, `error` | **Yes** (analytics) | каждый запрос | `updateTokens()` | `Analytics.reset()` (DELETE all) |
| `__drizzle_migrations` | — | drizzle internal | **Yes** (migration state) | `migrate()` on startup | — | — |

`Confirmed by code` — `apps/api/src/database/schema.ts:3-44`, `apps/api/src/database/index.ts:35-41`.

### Migrations
- 6 миграций: `_0000` → `_0005`. `Confirmed by config` — `apps/api/drizzle/meta/_journal.json`.
- `_0000` — creates `app_settings`, `oauth_tokens`, `requests`. `Confirmed by code` — `apps/api/drizzle/_0000.sql`.
- Schema эволюционировала: `oauth_tokens` → `provider_settings` (migration _0001+, `Inferred from structure`).
- `_0005` — добавляет model mappings для GPT-5.5 и Opus-4.7 (INSERT OR IGNORE). `Confirmed by code` — `apps/api/drizzle/_0005.sql`.
- Миграции применяются **на startup** через `migrate(_db, { migrationsFolder: MIGRATIONS_PATH })`. `Confirmed by code` — `apps/api/src/database/index.ts:41`.
- `MIGRATIONS_PATH` = `process.env.DRIZZLE_PATH ?? __dirname/../drizzle`. В prod extension передаёт `DRIZZLE_PATH=cwd/drizzle`. `Confirmed by code` — `apps/api/src/database/index.ts:13`, `apps/extension/src/api-server.ts:199`.

### Filesystem state

| Path | Type | Source of truth | Создание | Retention |
|---|---|---|---|---|
| `~/.ungate/data.db` | SQLite DB | **Yes** | API startup | persistent |
| `~/.ungate/data.db-wal`, `-shm` | WAL files | derived | SQLite WAL mode | auto-checkpoint |
| `~/.ungate/runtime-state.json` | JSON | **Yes** (runtime) | extension activate | persistent, overwritten |
| `~/.ungate/runtime-state.lock` | lock file | runtime | CrossProcessLock | auto-release |
| `~/.ungate/extension.log` | NDJSON log | derived (cache) | extension/api logging | trim 500 entries/source |
| `~/.ungate/bin/cloudflared[.exe]` | binary | cache | TunnelManager.ensureBinary | **Не используется в local fork** |
| `bundled/api/wake-ping.json` | JSON config | **Yes** (wake-ping) | build copy | persistent, mutable at runtime |
| `~/.cursor/extensions/.../state.vscdb` | SQLite (Cursor) | **external** (Cursor) | Cursor | — |

`Confirmed by code` — `apps/extension/src/runtime-state/config.ts:6-12`, `apps/extension/src/runtime-state/shared-log-store.ts:7`.

### Cache / derived state
- `~/.ungate/extension.log` — shared log, trimmable, не source of truth.
- In-memory PKCE sessions (`OAuth.pkceStore`, `OpenAIPkceSessionStore`) — TTL 10-15 мин, in-memory only. `Confirmed by code` — `apps/api/src/auth/oauth.ts:22-23`.

Evidence:
- `apps/api/src/database/schema.ts` — full schema.
- `apps/api/drizzle/_journal.json` — migration count.
- `apps/extension/src/runtime-state/config.ts` — filesystem paths.

---

## 8. Configuration and Environment

### Environment variables

| Var | Где читается | Default | Назначение | Critical? |
|---|---|---|---|---|
| `PORT` | `apps/api/src/config.ts:51` | `settings.port` (47821) | API listen port | **Yes** — extension парсит stdout для детекта порта |
| `DB_PATH` | `apps/api/src/database/index.ts:21` | `~/.ungate/data.db` | SQLite path | **Yes** — смена = другая БД |
| `DRIZZLE_PATH` | `apps/api/src/database/index.ts:13` | `__dirname/../drizzle` | migrations folder | **Yes** — prod extension передаёт `cwd/drizzle` |
| `UNGATE_BETTER_SQLITE3_NATIVE_BINDING` | `apps/api/src/database/index.ts:18` | — | path to .node native binding | **Yes** — без него better-sqlite3 может не загрузиться |
| `UNGATE_NODE_BIN` | `apps/extension/src/utils/node-resolver.ts:56` | system search | override Node binary path | No |
| `CHATGPT_INSTRUCTIONS` | `apps/api/src/proxy/openai-client.ts:18` | — | extra Codex instructions | No |
| `UNGATE_BETTER_SQLITE3_NATIVE_BINDING` | `apps/extension/src/api-server.ts:198` | installer path | set by extension for API process | **Yes** |

### Config files (runtime)
- `bundled/api/wake-ping.json` — wake-ping config (enabled, intervalHours, workStart, workEnd, sendOnStartup, model, maxTokens, pingMessage). `Confirmed by code` — `apps/api/src/wake-ping.ts:27,33-51`.
- `apps/api/wake-ping.json` — source (копируется в bundled при билде). `Confirmed by config` — `scripts/build-package/run.ps1:52`.

### Hardcoded config (не env)
- `apps/api/src/config.ts:5-44` — Claude clientId, OAuth URLs, Anthropic API URL, beta headers, MiniMax base URLs, OpenAI OAuth config (clientId, redirectUri `localhost:1455`), Codex URL, Claude Code system prompt.
- `apps/extension/src/runtime-state/config.ts` — все intervals и paths (heartbeat 2s, sync 2s, health check 1s, stale client 5s, etc.).

### Defaults опасные
- `app_settings.port` default **47821** — `build-and-install.ps1` убивает процессы на этом порту. Смена порта требует координации.
- `wake-ping.json` `enabled: true` — wake-ping **включён по умолчанию**, будет пинговать Claude при старте API. `Confirmed by code` — `apps/api/wake-ping.json:2`.
- `DEFAULT_KEY_FIX_ENABLED = false` — key fix off по умолчанию. `Confirmed by code` — `packages/shared/src/constants.ts:1`.
- CORS `origin: '*'` — API принимает запросы с любого origin. `Confirmed by code` — `apps/api/src/server.ts:35`.

### Значения, которые нельзя менять без координации
- `app_settings.api_key` — Cursor использует его для авторизации к прокси. Смена = нужно обновить в Cursor settings.
- `app_settings.port` — Cursor OpenAI Base URL указывает на туннель, который форвардит на этот порт.
- Tunnel URL (`https://ungate.ahref.cyou`) — Cursor OpenAI Base URL указывает на него. `Confirmed by code` — `apps/extension/src/tunnel-manager.ts:140`.

Evidence:
- `apps/api/src/config.ts` — all hardcoded config.
- `apps/api/src/database/index.ts:13,18,21` — env vars.
- `apps/extension/src/runtime-state/config.ts` — extension config.

---

## 9. External Dependencies and Environment Contracts

| Dependency | Зачем | Контракт | Что сломается |
|---|---|---|---|
| **Anthropic API** (`api.anthropic.com`) | Claude proxy | OAuth Bearer, beta headers, `/v1/messages` | OAuth expiry, rate limit 429 |
| **OpenAI Codex** (`chatgpt.com/backend-api/codex`) | ChatGPT proxy | Bearer + account-id, `/responses` SSE | Token expiry, account id missing |
| **MiniMax API** (`api.minimax.io` / `api.minimaxi.com`) | MiniMax proxy | API key Bearer, `/v1/text/chatcompletion_v2` | API key invalid |
| **Anthropic OAuth** (`console.anthropic.com`) | Claude login | PKCE, clientId `9d1c250a-...`, redirect `console.anthropic.com/oauth/code/callback` | clientId change = re-auth |
| **OpenAI OAuth** (`auth.openai.com`) | ChatGPT login | PKCE, clientId `app_EMoamEEZ73f0CkXaXp7hrann`, redirect `localhost:1455/auth/callback` | clientId change, port 1455 занят |
| **better-sqlite3** (native) | SQLite driver | prebuilt binary с GitHub WiseLibs/better-sqlite3 releases | ABI mismatch, network failure |
| **cloudflared** (binary) | Tunnel (upstream) | `cloudflared` npm package, binary в `~/.ungate/bin/` | **Local fork НЕ использует — заменён на frpc** |
| **frpc** (FRP Client, `J:\Tools\Gost\frp\frp_0.68.1_windows_amd64\frpc.exe`) | Tunnel (local fork) | NSSM-служба `frpc` → `start-frpc.ps1` → frpc.exe с `frpc.toml`; VPS `212.22.94.19:7000`, token auth; прокси `ungate-api-47821` (local 47821 → remote 47821) | **Если VPS down или frpc-служба остановлена — туннель не работает** |
| **VPS `212.22.94.19`** (frps + reverse proxy) | Tunnel server | frps на :7000, reverse proxy (nginx/caddy) терминирует TLS для `ungate.ahref.cyou` → :47821 | Управляется через `ssh vps-212.22.94.19-root` |
| **NSSM-панель** (`J:\Dev\panel-nssm-service-manager`) | Service management | PHP-панель, `config/services.json` — source of truth для служб `frpc` и `ungate-api` | Смена config = пересоздание службы |
| **Cursor** | Host extension | VS Code API ^1.96, `state.vscdb` SQLite, command `aiSettings.usingOpenAIKey.toggle` | Cursor update меняет schema/state |
| **System Node 22** | API runtime | extension спавнит system node | Node < 22 = API не запустится |
| **NSSM** (Windows) | Service manager | `ungate-api` service | service config = separate от extension |
| **sqlite3 CLI** | Read Cursor state.vscdb | `CursorStateDbReader` через `Sqlite3CliResolver` | CLI unavailable = key fix off |

Evidence:
- `apps/api/src/config.ts:5-44` — all external endpoints.
- `apps/extension/src/utils/cursor-state-db-reader.ts:29-40` — sqlite3 CLI usage.
- `apps/extension/src/utils/better-sqlite3-installer.ts:91-92` — GitHub prebuilt download.
- `scripts/build-and-install.ps1:117-123` — NSSM service.

---

## 10. End-to-End Operational Flows

### A. Chat request flow (основной)
1. Cursor → `OpenAI Base URL` (туннель) → `https://ungate.ahref.cyou/v1/chat/completions` → локальный API порт 47821.
2. `routes/openai.ts:13` — `apiKeyAuth` проверяет `Authorization: Bearer` или `x-api-key` против `config.apiKey`. `Confirmed by code` — `apps/api/src/plugins/auth.ts:7-9`.
3. `ModelMappings.resolveForChatCompletion(openaiBody.model)` — ищет model mapping по id/upstream (case-insensitive). `Confirmed by code` — `apps/api/src/database/model-mappings.ts:75-109`.
4. Routing: MiniMax (mapping provider или name prefix) → `MiniMaxChatHandler`; OpenAI mapped → `OpenAiMappedChatHandler`; default → `ClaudeChatHandler`. `Confirmed by code` — `apps/api/src/routes/openai.ts:19-27`.
5. Claude path: `openaiToAnthropic` конверсия → `proxyRequest` → `makeClaudeCodeRequest` → Anthropic API. При 401 — refresh token + retry. `Confirmed by code` — `apps/api/src/proxy/anthropic-client.ts:70-108`.
6. Streaming: `CompletionStreamingGateway.sendClaudeAsOpenAiStream` — Anthropic SSE → OpenAI SSE. `Confirmed by code` — `apps/api/src/orchestration/openai/provider-handlers/claude-chat-handler.ts:54`.
7. Telemetry: `CompletionRequestTelemetry.record` → `requests` table. `Confirmed by code` — `apps/api/src/database/requests.ts:11-37`.

### B. OAuth login flow (Claude)
1. Dashboard → `POST /auth/claude/start` → `OAuth.startLogin()` → PKCE, `authUrl = claude.ai/oauth/authorize?...`. `Confirmed by code` — `apps/api/src/auth/oauth.ts:50-76`.
2. User открывает URL, авторизуется, получает code.
3. Dashboard → `POST /auth/claude/complete` `{code, sessionId}` → `OAuth.completeLogin` → token exchange → `ProviderSettings.upsertOAuth('claude', ...)`. `Confirmed by code` — `apps/api/src/auth/oauth.ts:78-138`.
4. PKCE session in-memory, TTL 15 мин. `Confirmed by code` — `apps/api/src/auth/oauth.ts:23`.

### C. OAuth login flow (OpenAI/ChatGPT)
1. Dashboard → `GET /auth/openai/start` → `OpenAIOAuthService.startLogin()` → PKCE + **starts callback server на localhost:1455**. `Confirmed by code` — `apps/api/src/auth/openai/openai-oauth-service.ts:20-45`.
2. User открывает authUrl, браузер редиректит на `localhost:1455/auth/callback?code=...&state=...`.
3. Callback server → `handleCallbackRequest` → `completeLogin` → token exchange → `ProviderSettings.upsertOAuth('openai', ...)`. `Confirmed by code` — `apps/api/src/auth/openai/openai-oauth-service.ts:146-193`.
4. Callback server auto-shutdown через 10 мин. `Confirmed by code` — `apps/api/src/auth/openai/callback-server.ts:37`.

### D. Wake Ping flow (local addition)
1. API startup → `startWakePingScheduler()` → `loadWakePingConfig()` (из `wake-ping.json`) → если `enabled` → `sendWakePing()` (если `sendOnStartup`) → `scheduleNextPing()`. `Confirmed by code` — `apps/api/src/wake-ping.ts:103-122`.
2. `sendWakePing` → `makeClaudeCodeRequest('/v1/messages', {model, max_tokens:10, messages:[{role:'user',content:'ping'}], stream:false}, {})`. `Confirmed by code` — `apps/api/src/wake-ping.ts:63-81`.
3. `getNextPingTime` — anchor scheduling: workStart + N*interval, skip если >= workEnd, overnight не поддерживается. `Confirmed by code` — `apps/api/src/wake-ping-scheduler.ts:42-75`.
4. Extension toggle: `ungate.toggleWakePing` → `POST /wake-ping {enabled}` → `saveWakePingConfig` + restart/stop scheduler. `Confirmed by code` — `apps/extension/src/extension-controller.ts:427-454`, `apps/api/src/server.ts:63-100`.

### E. OpenAI Key Fix flow
1. `OpenAiKeyFix.activate()` → `refreshReaderAvailability` (init sqlite3 CLI) → `applySharedState`. `Confirmed by code` — `apps/extension/src/openai-key-fix.ts:88-94`.
2. `startMonitoring` — initial check (3s), FileSystemWatcher на `state.vscdb*`, poll interval (5s). `Confirmed by code` — `apps/extension/src/openai-key-fix.ts:154-194`.
3. `checkAndFix` → `readUseOpenAiKey` (sqlite3 CLI query ItemTable) → если `false` → `vscode.commands.executeCommand('aiSettings.usingOpenAIKey.toggle')`. `Confirmed by code` — `apps/extension/src/openai-key-fix.ts:262-273`.
4. **Write side effect на read-like poll**: периодически выполняет VS Code command (toggle). `Potential risk` — может включить key даже если пользователь намеренно выключил.

### F. Build & install flow (local)
1. `scripts/build-and-install.ps1` — auto-bump version, clean extensions.json, pnpm install (if needed), `build-package/run.ps1`, uninstall marketplace, **kill Cursor**, **kill port 47821**, install vsix --force, start Cursor, **restart NSSM ungate-api service**. `Confirmed by code` — `scripts/build-and-install.ps1`.
2. `build-package/run.ps1` — build shared → api (tsup bundle) → web (vite) → extension (tsup); copy bundle (api bundle + drizzle + wake-ping.json + web dist + better-sqlite3 + bindings + file-uri-to-path); trim build/deps; `vsce package --no-dependencies --out out/ungate.vsix`; cleanup bundled dir. `Confirmed by code` — `scripts/build-package/run.ps1`.

### G. Multi-window leader election
1. Каждый extension window имеет `windowId = ${pid}-${Date.now()}-${random}`. `Confirmed by code` — `apps/extension/src/extension-controller.ts:34`.
2. Heartbeat каждые 2s → `RuntimeStateStore.touchClient`. `Confirmed by code` — `extension-controller.ts:514-519`.
3. Leader = первый sorted live client id. `Confirmed by code` — `apps/extension/src/runtime-state/runtime-state-store.ts:56-64`.
4. Только leader запускает/останавливает API и tunnel. `Confirmed by code` — `extension-controller.ts:692-711`.
5. Stale client = нет heartbeat 5s. `Confirmed by code` — `runtime-state/config.ts:15`.

Evidence:
- `apps/api/src/routes/openai.ts` — chat flow.
- `apps/api/src/auth/oauth.ts` — Claude OAuth.
- `apps/extension/src/openai-key-fix.ts` — key fix.
- `scripts/build-and-install.ps1` — build & install.

---

## 11. Critical Contracts and Invariants

### A. Proxy API Key Auth
- **Current behavior:** `/v1/chat/completions` и `/v1/messages` требуют `Authorization: Bearer <key>` или `x-api-key: <key>` matching `app_settings.api_key`. Если `apiKey` null — auth пропускается. `Confirmed by code` — `apps/api/src/plugins/auth.ts:6`.
- **Why it matters:** Это единственная защита прокси от неавторизованного использования через туннель.
- **What will break:** Смена формата auth header = Cursor не сможет подключиться.
- **What must remain compatible:** Bearer token / x-api-key semantics, 403 on mismatch.
- **Evidence:** `apps/api/src/plugins/auth.ts`, `apps/api/src/routes/openai.ts:13`.

### B. Port Detection Contract
- **Current behavior:** Extension парсит stdout API процесса на `localhost:(\d+)` для детекта порта. API пишет `[ungate] listening on localhost:${port}` через `globalThis.console.log` (bypasses quiet mode). `Confirmed by code` — `apps/api/src/server.ts:106`, `apps/extension/src/api-server.ts:228`.
- **Why it matters:** Extension не знает порт заранее (берётся из DB settings). Без этой строки port detection ломается.
- **What will break:** Изменение формата stdout = extension не найдёт порт.
- **Evidence:** `apps/api/src/server.ts:104-106`, `apps/extension/src/api-server.ts:220-238`.

### C. Tunnel URL Contract (LOCAL FORK — frpc, не cloudflared)
- **Current behavior:** `TunnelManager.spawnTunnel()` создаёт fake Tunnel object с hardcoded URL `https://ungate.ahref.cyou` и запускает **periodic health check** (`checkTunnelHealth`) через `fetch(${url}/health)` каждые 5s (timeout 3s). Если health check OK → status `running`; если fail → status `error` с сообщением `Tunnel endpoint unreachable`. `ensureBinary()` (cloudflared download) **пропущен** в `start()` — frpc NSSM-managed. Реальный туннель — **frpc** (FRP Client), NSSM-служба `frpc` запускает `J:\Scripts\startup\start-frpc.ps1` → `frpc.exe -c J:\Tools\Gost\frp\frpc.toml`. frpc подключается к VPS `212.22.94.19:7000` (token auth), прокси `ungate-api-47821` мапит `local 127.0.0.1:47821 → remote 47821`. На VPS nginx (`/etc/nginx/conf.d/domains/ungate.ahref.cyou.ssl.conf`) терминирует TLS и форвардит `/health`, `/v1/*`, `/v1beta/`, `/v1internal`, `/api/provider/` на `127.0.0.1:47821`. `Confirmed by code` — `apps/extension/src/tunnel-manager.ts:135-182`; `Confirmed by config` — `J:\Tools\Gost\frp\frpc.toml:59-65`, `J:\Dev\panel-nssm-service-manager\config\services.json:181-194`, VPS nginx config.
- **Why it matters:** Cursor `OpenAI Base URL` указывает на `https://ungate.ahref.cyou`. Health check проверяет всю цепочку: frpc → VPS → reverse proxy → API. Если любой компонент down — статус меняется на `error`.
- **What will break:** Смена URL = нужно обновить Cursor settings + hardcoded URL в `tunnel-manager.ts:138`. Если VPS down, frpc-служба остановлена, или API down — health check fail, статус `error`.
- **What must remain compatible:** URL `ungate.ahref.cyou` должен быть публично достижим; VPS reverse proxy → VPS:47821; frpc прокси `ungate-api-47821` → local 47821; `ungate-api` NSSM-служба на local 47821.
- **UI changes:** Restart и Stop кнопки убраны из TunnelPanel. "Cloudflare Tunnel" → "FRP Tunnel". Текст "The URL changes on each restart" → "The URL is managed by frpc (NSSM service)".
- **Evidence:** `apps/extension/src/tunnel-manager.ts:135-182`, `apps/web/src/features/tunnel/TunnelPanel.svelte:47,89`, `J:\Tools\Gost\frp\frpc.toml:59-65`.

### D. Database Schema Invariants
- **Current behavior:** `app_settings.id` всегда = 1 (singleton). `provider_settings.provider` ∈ {claude, minimax, openai}. `model_mappings` replace = transactional DELETE + INSERT. `Confirmed by code` — `apps/api/src/database/schema.ts`, `apps/api/src/database/model-mappings.ts:111-130`.
- **Why it matters:** Settings.get() ожидает singleton row. ModelMappings.replace() стирает все mappings.
- **What will break:** Добавление column без миграции = runtime error. Смена provider enum = routing ломается.
- **Evidence:** `apps/api/src/database/app-settings.ts:17-27`, `apps/api/src/database/model-mappings.ts:114`.

### E. Migration Application Contract
- **Current behavior:** `migrate()` вызывается в `getDb()` при первом открытии DB. `MIGRATIONS_PATH` = `DRIZZLE_PATH` env или `__dirname/../drizzle`. `Confirmed by code` — `apps/api/src/database/index.ts:41,13`.
- **Why it matters:** Без migrations folder API падает при старте. В prod extension передаёт `DRIZZLE_PATH`.
- **What will break:** Удаление drizzle folder из vsix = API не запустится.
- **Evidence:** `apps/api/src/database/index.ts:41`, `apps/extension/src/api-server.ts:199`.

### F. Wake Ping Config Path Contract
- **Current behavior:** `wake-ping.ts:27` — `configPath = join(__dirname, '..', 'wake-ping.json')`. В bundled CJS `__dirname` = `bundled/api/bundle`, config = `bundled/api/wake-ping.json`. `Confirmed by code` — `apps/api/src/wake-ping.ts:27`.
- **Why it matters:** POST /wake-ping пишет в этот файл. Если путь не существует — config не сохраняется.
- **What will break:** Реструктуризация bundle = config path ломается.
- **Evidence:** `apps/api/src/wake-ping.ts:27`, `scripts/build-package/run.ps1:52`.

### G. Runtime State File Contract
- **Current behavior:** `~/.ungate/runtime-state.json` — JSON, atomic write (tmp + rename), cross-process lock `runtime-state.lock`. `Confirmed by code` — `apps/extension/src/runtime-state/file-store.ts:32-52`.
- **Why it matters:** Multi-window coordination, leader election, command queue.
- **What will break:** Смена path или формата = все windows теряют sync.
- **Evidence:** `apps/extension/src/runtime-state/config.ts:9`, `file-store.ts:34-36`.

### H. OpenAI Key Fix Command Contract
- **Current behavior:** Выполняет VS Code command `aiSettings.usingOpenAIKey.toggle`. Читает `state.vscdb` ItemTable key `src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser`. `Confirmed by code` — `apps/extension/src/openai-key-fix.ts:14-16`, `cursor-state-db-reader.ts:34-36`.
- **Why it matters:** Зависит от внутреннего Cursor command id и SQLite schema.
- **What will break:** Cursor update переименовывает command или меняет storage key = key fix молча перестаёт работать.
- **Evidence:** `apps/extension/src/openai-key-fix.ts:14-16`.

### I. Anthropic Beta Headers Contract
- **Current behavior:** `anthropic-beta: claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14`, `User-Agent: claude-cli/2.1.9 (external, claude-vscode, agent-sdk/0.2.7)`, `x-app: cli`. `Confirmed by code` — `apps/api/src/proxy/anthropic-client.ts:49-59`.
- **Why it matters:** Anthropic API требует эти beta headers для OAuth-доступа к Claude Code.
- **What will break:** Устаревание beta version = 403/400.
- **Evidence:** `apps/api/src/config.ts:14-19`, `apps/api/src/proxy/anthropic-client.ts:49-59`.

### J. Model Routing Contract
- **Current behavior:** `/v1/chat/completions` routing: MiniMax (mapping.provider=='minimax' OR model name prefix `minimax`/`mini-max`) → MiniMax; OpenAI (mapping.provider=='openai') → OpenAi; default → Claude. `Confirmed by code` — `apps/api/src/routes/openai.ts:19-27`, `apps/api/src/orchestration/openai/model-routing.ts:7-27`.
- **Why it matters:** Неправильный routing = запрос не туда.
- **What will break:** Изменение prefix detection или branch order.
- **Evidence:** `apps/api/src/orchestration/openai/model-routing.ts`.

---

## 12. Source of Truth by Concern

| Concern | Source of truth | NOT source of truth |
|---|---|---|
| Proxy API key | `app_settings.api_key` в `~/.ungate/data.db` | — |
| OAuth tokens (Claude, OpenAI) | `provider_settings` в `~/.ungate/data.db` | in-memory PKCE sessions (transient) |
| MiniMax API key + base URL | `provider_settings` в `~/.ungate/data.db` | — |
| Model mappings | `model_mappings` в `~/.ungate/data.db` | — |
| Analytics | `requests` в `~/.ungate/data.db` | — |
| API port | `app_settings.port` (overridden by `PORT` env) | runtime-state.json (derived) |
| API/tunnel runtime status | `~/.ungate/runtime-state.json` | in-memory controller state (derived) |
| Leader window | `~/.ungate/runtime-state.json` clients | — |
| Wake ping config | `bundled/api/wake-ping.json` | — |
| Extension version | `apps/extension/package.json` | LOCAL-SETUP.md (stale) |
| Cursor OpenAI key state | Cursor `state.vscdb` (external) | runtime-state.json keyFix.enabled (mirror) |
| Logs | `~/.ungate/extension.log` (derived, trimmable) | outputChannel (in-memory) |
| Tunnel URL | `https://ungate.ahref.cyou` (hardcoded) | runtime-state.json tunnel.url (derived) |
| Build artifact | `apps/extension/out/ungate.vsix` (generated) | bundled/ (intermediate, deleted) |

Evidence:
- `apps/api/src/database/schema.ts` — DB tables.
- `apps/extension/src/runtime-state/config.ts` — runtime paths.
- `apps/extension/src/tunnel-manager.ts:140` — hardcoded URL.

---

## 13. Security and Permission Model

### Auth model
- **Proxy API key:** единственный auth для `/v1/chat/completions` и `/v1/messages`. Bearer или x-api-key. Если `apiKey` null в DB — auth пропускается (open proxy). `Confirmed by code` — `apps/api/src/plugins/auth.ts:6`.
- **Dashboard/API routes** (`/settings`, `/analytics`, `/auth/*`, `/wake-ping`, `/health`, `/v1/models`) — **без auth**. `Confirmed by code` — routes не используют preHandler.
- **CORS:** `origin: '*'` — любой origin. `Confirmed by code` — `apps/api/src/server.ts:35`.

### Roles/permissions
- Нет ролей. Любой с proxy API key + tunnel URL может слать chat requests.
- Dashboard routes доступны любому, кто может достучаться до localhost:PORT (без key).

### Secrets handling
- OAuth tokens, API keys хранятся **plaintext** в SQLite `~/.ungate/data.db`. `Confirmed by code` — `apps/api/src/database/schema.ts:13-22`.
- `local-config/data.db.snapshot` — **полный снимок БД со всеми секретами**, в `.gitignore`. `Confirmed by config` — `.gitignore:71`, `local-config/README.md:8-13`.
- ClientId/OpenAI clientId — hardcoded в `apps/api/src/config.ts:7,33` (не секреты, но фиксированы).

### Input validation
- `/settings` POST — Zod schema validation. `Confirmed by code` — `apps/api/src/routes/settings.ts:9-31`.
- `/wake-ping` POST — ручная валидация (TIME_RE, workStart < workEnd). `Confirmed by code` — `apps/api/src/server.ts:77-87`.
- `/v1/chat/completions` — body cast без глубокой валидации. `Potential risk`.

### Filesystem write risks
- `OpenAiKeyFix` выполняет VS Code command (toggle) — модифицирует Cursor state. `Confirmed by code` — `apps/extension/src/openai-key-fix.ts:272`.
- `wake-ping.ts` пишет `wake-ping.json` рядом с bundle. `Confirmed by code` — `apps/api/src/wake-ping.ts:53-55`.
- `runtime-state.json` atomic write (tmp+rename). `Confirmed by code` — `apps/extension/src/runtime-state/file-store.ts:34-36`.
- `extension.log` append-only, trimmable. `Confirmed by code` — `shared-log-store.ts:19`.

### Network/SSRF risks
- API форвардит к hardcoded URLs (Anthropic, OpenAI, MiniMax) — нет user-controlled URL. `Confirmed by code` — `apps/api/src/config.ts`.
- MiniMax `baseUrl` — user-configurable через dashboard (`/auth/minimax/base-url`). `Potential risk` — SSRF если не валидируется. `Confirmed by code` — `apps/api/src/routes/auth.ts:58-73` (нет URL validation).

### Command execution risks
- `OpenAiKeyFix` — `vscode.commands.executeCommand`. `Confirmed by code`.
- `ApiServer` — `cp.spawn` system node. `Confirmed by code` — `apps/extension/src/api-server.ts:206`.
- `NodeResolver` — `cp.spawnSync` для проверки node. `Confirmed by code` — `apps/extension/src/utils/node-resolver.ts:124-128`.
- `CursorStateDbReader` — `execFile` sqlite3 CLI с SQL query (escaped quotes). `Confirmed by code` — `apps/extension/src/utils/cursor-state-db-reader.ts:34-36`. `Potential risk` — SQL injection если key содержит одинарные кавычки (escaped, но стоит проверить).

### Known gaps
- Dashboard routes без auth — `Potential risk` если API доступен не только localhost.
- CORS `*` — `Potential risk`.
- MiniMax baseUrl без URL validation — `Potential risk`.
- Нет rate limiting на proxy.
- Нет audit logging (только analytics metadata).

Evidence:
- `apps/api/src/plugins/auth.ts` — auth model.
- `apps/api/src/server.ts:35` — CORS.
- `apps/extension/src/openai-key-fix.ts:272` — command execution.

---

## 14. Build / Test / Deploy / Update Rules

### Build commands

| Command | Что делает | Где |
|---|---|---|
| `pnpm --filter @ungate/dev-kit build` | tsc build dev-kit | root |
| `pnpm --filter @ungate/shared build` | tsup build shared (ESM+CJS) | root |
| `pnpm --filter @ungate/shared build:watch` | tsup watch | root |
| `pnpm --filter @ungate/api build` | tsc + tsc-alias → `dist/` | root |
| `pnpm --filter @ungate/api build:watch` | tsc-watch | root |
| `pnpm --filter @ungate/api build:bundle` | tsup → `bundle/main.cjs` (CJS, single file) | root |
| `pnpm --filter @ungate/web build` | vite build → `dist/` | root |
| `pnpm --filter @ungate/web build:watch` | vite build --watch | root |
| `pnpm --filter @ungate/extension build` (или `pnpm build` в ext dir) | tsup → `dist/extension.js` (CJS) | root/ext |
| `pnpm run package:build` | `scripts/build-package/run.ps1` — full build + vsix | root |
| `pwsh scripts/build-and-install.ps1` | build + install в Cursor + restart NSSM | root |

`Confirmed by code` — `package.json:11-15`, `apps/api/package.json:4-17`, `apps/extension/package.json:68-74`.

### Build order (dependency graph)
`dev-kit` → `shared` → `api` (build:bundle) → `web` (build) → `extension` (build) → assemble bundled → `vsce package`. `Confirmed by code` — `scripts/build-package/run.ps1:16-32`.

### Test commands
- `pnpm test` (root) → `pnpm --filter ungate test && pnpm --filter @ungate/api test`. **Drift**: filter `ungate` не совпадает с actual package name `ungate-local`. `Confirmed by code` — `package.json:14`. `Needs verification` — может падать.
- `apps/api`: `test:unit` (vitest, `tests/unit/vitest.config.ts`), `test:integration` (vitest, `tests/integration/vitest.config.ts`). `Confirmed by code` — `apps/api/package.json:13-15`.
- `apps/extension`: `vitest run`. `Confirmed by code` — `apps/extension/package.json:73`.
- Test files: `apps/api/tests/unit/*`, `apps/api/tests/integration/*`, `apps/extension/tests/unit/*`. `Confirmed by structure`.

### Lint
- `pnpm lint:fix` (root) → `pnpm -r --parallel run lint:fix`. `Confirmed by code` — `package.json:13`.
- ESLint flat config, shared из `@ungate/dev-kit/eslint`. `Confirmed by config` — `packages/dev-kit/package.json:5-6`.

### CI/CD
- **Not found.** `.github/workflows/` отсутствует. `Confirmed by structure` — glob вернул 0 файлов.

### Husky / git hooks
- `.husky/pre-commit` — `pnpm run lint:fix && git add -A && pnpm test`. `Confirmed by code` — `.husky/pre-commit`.
- `prepare: husky`. `Confirmed by code` — `package.json:15`.

### VS Code tasks
- `build:watch all` — dependsOn: dev-kit build, shared build-watch, web build-watch, api build-watch. `Confirmed by code` — `.vscode/tasks.json:85-96`.
- `extension build` — default build task. `Confirmed by code` — `.vscode/tasks.json:58-69`.
- Launch: `Run Extension` (extensionHost, F5, preLaunchTask `extension build`). `Confirmed by code` — `.vscode/launch.json`.

### Deploy/publish
- Upstream: `ovsx publish out/ungate.vsix`. `Confirmed by code` — `apps/extension/package.json:70`.
- **Local fork deploy:** `pwsh scripts/build-and-install.ps1` — build, uninstall marketplace, kill Cursor, kill port 47821, install vsix --force, start Cursor, restart NSSM. `Confirmed by code` — `scripts/build-and-install.ps1`.

### Generated artifacts (deployed в vsix)
- `dist/extension.js` — extension bundle (tsup, CJS). `Confirmed by code` — `apps/extension/tsup.config.ts`.
- `bundled/api/bundle/main.cjs` — API bundle (tsup, CJS, single file). `Confirmed by code` — `apps/api/tsup.config.ts`.
- `bundled/api/drizzle/` — migration SQL files. `Confirmed by code` — `scripts/build-package/run.ps1:49`.
- `bundled/api/wake-ping.json` — wake-ping config. `Confirmed by code` — `run.ps1:52`.
- `bundled/api/node_modules/better-sqlite3/` — native module. `Confirmed by code` — `run.ps1:58-61`.
- `bundled/web/dist/` — web assets. `Confirmed by code` — `run.ps1:55`.
- **Все generated, не коммитятся** (`.gitignore`: `dist/`, `bundled/`, `out/`, `*.vsix`). `Confirmed by config` — `.gitignore:6,64,65`.

### Drift: docs vs artifacts
- `LOCAL-SETUP.md:7` говорит version `1.7.1-local.0` — actual `1.7.1-local.7`. `Confirmed by code`.
- `LOCAL-SETUP.md:51` говорит "НЕ запускать pnpm install" — но `build-and-install.ps1` делает pnpm install. `Confirmed by code`.
- `README.md:140-146` говорит `pnpm run package:build` → `cursor --install-extension` — actual `build-and-install.ps1` делает больше (auto-bump, kill Cursor, NSSM). `Confirmed by code`.
- `PATCHES-MAP.md` описывает wake-ping как "не применённый" — **уже в source**. `Confirmed by code` — `apps/api/src/wake-ping.ts` существует.

Evidence:
- `package.json:10-15` — root scripts.
- `scripts/build-package/run.ps1` — build flow.
- `scripts/build-and-install.ps1` — deploy flow.
- `.gitignore` — artifact exclusion.

---

## 15. Operational Gotchas

1. **Tunnel hardcoded to `https://ungate.ahref.cyou`** — `TunnelManager.spawnTunnel()` не использует cloudflared, создаёт fake Tunnel object с hardcoded URL. Реальный туннель — **frpc** (NSSM-служба `frpc` → `J:\Tools\Gost\frp\frpc.exe` + `frpc.toml` → VPS `212.22.94.19:7000`, прокси `ungate-api-47821`). **Health check** через `fetch(https://ungate.ahref.cyou/health)` каждые 5s — если fail (VPS down, frpc остановлена, или API down), статус меняется на `error`. `ensureBinary()` (cloudflared download) пропущен в `start()`. UI: Restart/Stop кнопки убраны, "Cloudflare Tunnel" → "FRP Tunnel". `Confirmed by code` — `apps/extension/src/tunnel-manager.ts:47-62,135-182`; `Confirmed by config` — `J:\Tools\Gost\frp\frpc.toml:59-65`.

2. **Wake Ping включён по умолчанию** — `apps/api/wake-ping.json:2` `enabled: true`, `sendOnStartup: true`. API будет пинговать Claude при каждом старте. Это тратит квоту и делает запросы без ведома пользователя. `Confirmed by code`.

3. **NSSM `ungate-api` service vs extension-spawned process coexistence** — `ungate-api` NSSM-служба (создана через `J:\Dev\panel-nssm-service-manager`, config в `config/services.json:196-213`) запускает `C:\Program Files\nodejs\node.exe bundle\main.cjs` с `cwd=J:\Dev\ungate-local\apps\api`, `PORT=47821`, `logonMode=account` (user `PC\kalvinclein`), `autoStart=true`, `restartOnCrash=true`, logs в `J:\Dev\ungate-local\apps\api\ungate-api.log`. Extension тоже спавнит API процесс, но `ApiServer.doStart()` сначала проверяет health существующего порта (`checkPortHealth(existingPort)`) — если NSSM-служба уже слушает 47821 и health OK, extension **attachается к этому порту** вместо spawn. При EADDRINUSE также пытается attach. `Confirmed by code` — `apps/extension/src/api-server.ts:136-147,311-317`; `Confirmed by config` — `J:\Dev\panel-nssm-service-manager\config\services.json:196-213`. **Важно**: NSSM-служба запускает `bundle\main.cjs` — требует `pnpm --filter @ungate/api run build:bundle` перед первым запуском.

4. **`pnpm test` filter mismatch** — root `test` script использует `pnpm --filter ungate test`, но package name `ungate-local`. `Confirmed by code` — `package.json:14`. `Needs verification` — падает ли pre-commit hook.

5. **Dashboard Wake Ping UI — DOM polling** — `WAKE_PING_SCRIPT` в `dashboard.ts:14-118` каждые 500ms ищет label "OpenAI API Key" и вставляет wake-ping card рядом. Хрупко — ломается при изменении web UI текста/структуры. `Confirmed by code`.

6. **OpenAI Key Fix silently toggles** — poll каждые 5s + FS watcher. Если пользователь намеренно выключил OpenAI key, extension включит обратно (если key fix enabled). `Confirmed by code` — `apps/extension/src/openai-key-fix.ts:262-273`.

7. **`local-config/data.db.snapshot` содержит secrets** — полный снимок БД с API keys, OAuth tokens. В `.gitignore`, но при копировании репо можно унести. `Confirmed by config` — `local-config/README.md:8-13`.

8. **better-sqlite3 native binary download** — при первом запуске extension скачивает prebuilt binary с GitHub. Если network недоступен или ABI mismatch — API не запустится, `suppressApiAutoStart`. `Confirmed by code` — `apps/extension/src/utils/better-sqlite3-installer.ts:86-128`.

9. **DB path drift dev vs prod** — dev: `DB_PATH=~/.ungate/data-dev.db`; prod: default `~/.ungate/data.db`. Different DB = different OAuth tokens, settings. `Confirmed by code` — `apps/extension/src/api-server.ts:199`.

10. **Migrations applied on every startup** — `migrate()` в `getDb()`. Idempotent (CREATE TABLE IF NOT EXISTS, INSERT OR IGNORE), но новая миграция с breaking change = применяется автоматически. `Confirmed by code` — `apps/api/src/database/index.ts:41`.

11. **`ModelMappings.replace()` — destructive** — DELETE all + INSERT. Если dashboard отправит пустой models array = все mappings стёрты. `Confirmed by code` — `apps/api/src/database/model-mappings.ts:114-116`.

12. **`Analytics.reset()` — destructive** — DELETE all requests. `Confirmed by code` — `apps/api/src/database/analytics.ts:110`.

13. **OAuth callback server port 1455** — если порт занят, OpenAI OAuth login падает. `Confirmed by code` — `apps/api/src/auth/openai/callback-server.ts:24`.

14. **Multi-window race** — leader election через file-based runtime-state.json с cross-process lock. При crash leader — другой window берёт leadership через 5s stale timeout. `Confirmed by code` — `runtime-state-store.ts:56-64`, `config.ts:15`.

15. **Version auto-bump** — `build-and-install.ps1:36-46` инкрементирует `local.N` при каждом build. `apps/extension/package.json` мутируется скриптом. `Confirmed by code`.

16. **Empty files in shared** — `packages/shared/src/constants/index.ts` и `constants/routes.ts` пустые (0 bytes). `Confirmed by code`. `Needs verification` — почему существуют, возможно planned.

17. **Root junk files** — в root лежат файлы с именами `{const`, `{console.error('Timeout')`, `console.error(e))`, `k.toLowerCase().includes('api')` и т.д. — артефакты, не валидный код. `Confirmed by structure`.

Evidence:
- `apps/extension/src/tunnel-manager.ts:137-146` — hardcoded tunnel.
- `apps/api/wake-ping.json:2` — wake-ping default.
- `scripts/build-and-install.ps1:117-123` — NSSM.
- `package.json:14` — test filter.

---

## 16. What This Project Must NOT Directly Change

- **Cursor `state.vscdb`** — project только читает (key fix) и toggles через command. Не должен писать в Cursor SQLite напрямую. `Confirmed by code` — `apps/extension/src/openai-key-fix.ts` только читает.
- **Cursor user settings** (`AppData/Roaming/Cursor/User/`) — `LOCAL-SETUP.md:28` явно говорит НЕ ТРОГАТЬ.
- **Provider API contracts** (Anthropic/OpenAI/MiniMax request/response formats) — project транслирует, не должен менять формат провайдера.
- **OAuth clientId / redirectUri** — hardcoded, смена = re-auth всех пользователей. `Confirmed by code` — `apps/api/src/config.ts:7,33`.
- **`~/.ungate/data.db` schema** — только через drizzle migrations. Не raw SQL.
- **Tunnel URL** (`https://ungate.ahref.cyou`) — если менять, нужно координировать с Cursor OpenAI Base URL. `Confirmed by code`.
- **`bundled/` contents** — generated при build, не редактировать вручную.
- **`pnpm-lock.yaml`** — не менять без `pnpm install`.
- **Anthropic beta headers / User-Agent** — required для OAuth access. `Confirmed by code` — `apps/api/src/proxy/anthropic-client.ts:49-59`.
- **Extension ID** (`orchidfiles.ungate-local`) — смена = конфликт с marketplace version или потеря данных.

Evidence:
- `LOCAL-SETUP.md:28` — Cursor settings warning.
- `apps/api/src/config.ts` — hardcoded OAuth config.

---

## 17. Change Impact Map

- **If you change `apps/api/src/server.ts`** (routes, port, startup): verify extension port detection (`localhost:(\d+)` regex), verify wake-ping scheduler start, verify all route plugins still register.
- **If you change `apps/api/src/database/schema.ts`**: generate migration (`pnpm --filter @ungate/api run db:generate`), verify migration is idempotent, verify `getDb()` still applies it, verify `drizzle/` folder is copied in `build-package/run.ps1`.
- **If you change `apps/api/src/plugins/auth.ts`**: verify both `/v1/chat/completions` and `/v1/messages` still auth, verify Cursor can still connect (Bearer + x-api-key).
- **If you change `apps/api/src/config.ts`** (OAuth clientId, endpoints): verify Claude/OpenAI OAuth still works, verify redirectUri port 1455 not conflicting.
- **If you change `apps/extension/src/tunnel-manager.ts`**: verify tunnel URL still reachable, verify Cursor OpenAI Base URL matches, verify `runtime-state.json` tunnel state still persisted.
- **If you change `apps/extension/src/api-server.ts`** (spawn, port detection): verify stdout `[ungate] listening on localhost:PORT` format preserved, verify dev/prod cwd and args, verify `UNGATE_BETTER_SQLITE3_NATIVE_BINDING` env.
- **If you change `apps/extension/src/openai-key-fix.ts`**: verify Cursor command id `aiSettings.usingOpenAIKey.toggle` still valid, verify `state.vscdb` ItemTable key still correct, verify leader-only monitoring.
- **If you change `apps/extension/src/dashboard.ts`** (WAKE_PING_SCRIPT): verify DOM polling still finds "OpenAI API Key" label, verify message types match `packages/shared/src/frontend.ts`.
- **If you change `packages/shared/src/frontend.ts`** (message types): verify `dashboard.ts` MSGS_SIMPLE, verify `extension-controller.ts` handleDashboardMessage, verify web `api.ts`.
- **If you change `apps/api/src/wake-ping.ts`** (config path): verify `__dirname/../wake-ping.json` resolves in bundled CJS, verify `build-package/run.ps1` copies `wake-ping.json`.
- **If you change `apps/api/src/proxy/anthropic-client.ts`** (headers, retry): verify Anthropic beta headers, verify 401 refresh+retry, verify `makeClaudeCodeRequest` still used by wake-ping.
- **If you change `scripts/build-package/run.ps1`**: verify vsix contains `bundled/api/bundle/main.cjs`, `drizzle/`, `wake-ping.json`, `web/dist/`, `better-sqlite3/`, `dist/extension.js`.
- **If you change `scripts/build-and-install.ps1`**: verify NSSM service name, verify port 47821, verify version bump regex.
- **If you change `apps/extension/package.json`** (commands, version): verify `extension-commands.ts` matches, verify `build-and-install.ps1` version bump regex `^(\d+\.\d+\.\d+)-local\.(\d+)$`.
- **If you change model routing** (`apps/api/src/orchestration/openai/model-routing.ts`): verify MiniMax/OpenAI/Claude branch order in `routes/openai.ts`, verify `detectProviderByModel` in shared.
- **If you touch `~/.ungate/` paths** (`runtime-state/config.ts`): verify all consumers (file-store, shared-log-store, cross-process-lock, better-sqlite3-installer).

Evidence:
- `apps/api/src/server.ts:106` — port detection contract.
- `apps/extension/src/tunnel-manager.ts:140` — tunnel URL.
- `scripts/build-and-install.ps1:36` — version regex.

---

## 18. Pre-Release Checklist

- [ ] Version bumped (`apps/extension/package.json` — `build-and-install.ps1` делает auto-bump)
- [ ] `pnpm --filter @ungate/shared build` проходит
- [ ] `pnpm --filter @ungate/api build:bundle` проходит (tsup → `bundle/main.cjs`)
- [ ] `pnpm --filter @ungate/web build` проходит (vite → `dist/`)
- [ ] `pnpm --filter @ungate/extension build` проходит (tsup → `dist/extension.js`)
- [ ] `pnpm run package:build` производит `apps/extension/out/ungate.vsix`
- [ ] vsix содержит: `dist/extension.js`, `bundled/api/bundle/main.cjs`, `bundled/api/drizzle/`, `bundled/api/wake-ping.json`, `bundled/web/dist/`, `bundled/api/node_modules/better-sqlite3/`
- [ ] Миграции idempotent (CREATE IF NOT EXISTS / INSERT OR IGNORE)
- [ ] `pnpm test` проходит (или `pnpm --filter @ungate/api test` если root test broken)
- [ ] `pnpm lint:fix` проходит
- [ ] Proxy API key auth работает на `/v1/chat/completions` и `/v1/messages`
- [ ] Tunnel URL `https://ungate.ahref.cyou` достижим
- [ ] Wake Ping config `bundled/api/wake-ping.json` присутствует и валиден
- [ ] `~/.ungate/data.db` не удалена (persistent data preserved)
- [ ] NSSM service `ungate-api` рестартован (если используется)
- [ ] Smoke test: OAuth login Claude, chat request через туннель, dashboard открывается, wake-ping card видна
- [ ] `local-config/data.db.snapshot` НЕ в коммите

---

## 19. AI Agent Working Rules

Before modifying this project:

1. **Read this file first.** Особое внимание к §11 (Contracts), §15 (Gotchas), §17 (Impact Map).
2. **Do not change public API contracts**: route paths (`/v1/chat/completions`, `/v1/messages`, `/v1/models`, `/settings`, `/analytics/*`, `/auth/*`, `/wake-ping`, `/health`), proxy auth (Bearer/x-api-key), response formats (OpenAI/Anthropic), unless all consumers updated.
3. **Do not change tunnel URL** (`https://ungate.ahref.cyou`) without coordinating Cursor OpenAI Base URL. Это custom FRP, не cloudflared.
4. **Do not change DB schema** without drizzle migration. Generate via `pnpm --filter @ungate/api run db:generate`. Verify idempotent. Verify `drizzle/` copied in build.
5. **Do not change `~/.ungate/` paths** without updating all consumers in `apps/extension/src/runtime-state/config.ts`.
6. **Do not change OAuth clientId/redirectUri** — смена требует re-auth всех пользователей.
7. **Do not change stdout port detection format** (`[ungate] listening on localhost:PORT`) — extension парсит его.
8. **If touching `apps/api/src/wake-ping.ts`**: verify config path `__dirname/../wake-ping.json`, verify `build-package/run.ps1` copies `wake-ping.json`, verify `makeClaudeCodeRequest` import.
9. **If touching auth/security**: verify every entry point (`/v1/chat/completions`, `/v1/messages` — authed; dashboard routes — currently NOT authed, be careful).
10. **If touching `OpenAiKeyFix`**: verify Cursor command id and state.vscdb key still valid against current Cursor version.
11. **If touching build scripts**: verify vsix contents (bundle, drizzle, wake-ping.json, web dist, better-sqlite3).
12. **If a fact in this document conflicts with current code, treat current code as source of truth and update this document.**
13. **Never commit `local-config/data.db.snapshot`** — содержит secrets.
14. **Never run `pnpm install` / migrations / `build-and-install.ps1`** without явного разрешения пользователя — эти команды мутируют state.
15. **Local fork drift**: `LOCAL-SETUP.md`, `SOURCE-INFO.md`, `PATCHES-MAP.md` частично устарели (version, wake-ping status). Код — source of truth.

---

## 20. Needs Verification / Open Questions

1. **NSSM `ungate-api` service** — `Resolved`. Служба создана через панель `J:\Dev\panel-nssm-service-manager` (импорт JSON в `config/services.json:196-213`). Config: `node.exe bundle\main.cjs`, `cwd=J:\Dev\ungate-local\apps\api`, `PORT=47821`, `logonMode=account` (`PC\kalvinclein`), `autoStart=true`, `restartOnCrash=true`, `managedPorts=[47821]`, logs `J:\Dev\ungate-local\apps\api\ungate-api.log`. Extension coexist с NSSM через health-check attach (см. §15.3). `build-and-install.ps1:117-123` рестартует службу через `nssm restart ungate-api`. `Confirmed by config` — `J:\Dev\panel-nssm-service-manager\config\services.json`.

2. **`pnpm test` filter mismatch** — root `test` script `pnpm --filter ungate test` не совпадает с package name `ungate-local`. `Needs verification` — падает ли pre-commit hook (`pnpm test`). Проверить: `pnpm --filter ungate test` (safe, read-only).

3. **frpc tunnel `ungate.ahref.cyou`** — `Resolved`. frpc (FRP Client) управляется NSSM-службой `frpc` (`J:\Dev\panel-nssm-service-manager\config\services.json:181-194`), запускает `J:\Scripts\startup\start-frpc.ps1` → `J:\Tools\Gost\frp\frp_0.68.1_windows_amd64\frpc.exe -c J:\Tools\Gost\frp\frpc.toml`. frpc.toml: VPS `212.22.94.19:7000`, token auth (`<redacted>`), прокси `ungate-api-47821` (local 127.0.0.1:47821 → remote 47821, `transport.useEncryption=true`). На VPS reverse proxy терминирует TLS для `ungate.ahref.cyou` → :47821. VPS управляется через `ssh vps-212.22.94.19-root`. `Confirmed by config` — `J:\Tools\Gost\frp\frpc.toml:59-65`, `J:\Scripts\startup\start-frpc.ps1:9-10`. `Needs verification` — точный reverse proxy config на VPS (nginx/caddy), проверить через SSH.

4. **`packages/shared/src/constants/index.ts` и `constants/routes.ts` пустые** — 0 bytes. `Needs verification` — planned feature или артефакт. Не ломают build (re-export из `constants.ts`).

5. **Root junk files** — `{const`, `{console.error('Timeout')`, `console.error(e))`, `k.toLowerCase().includes('api')`, `console.log(res.statusCode`, `console.log('API`, `console.error('API`. `Needs verification` — артефакты копирования или accidental creation. Безопасно удалить? Не используются в code.

6. **MiniMax baseUrl SSRF** — `/auth/minimax/base-url` принимает любой URL без валидации. `Needs verification` — может ли пользователь направить прокси на arbitrary URL (SSRF). `Potential risk`.

7. **Dashboard routes без auth** — `/settings`, `/analytics`, `/auth/*`, `/wake-ping` доступны без proxy API key. `Needs verification` — если API слушает на 0.0.0.0 (а не только localhost), любой в сети может читать/менять settings. `apps/api/src/server.ts:102` — `host: '0.0.0.0'`. `Potential risk`.

8. **`data.db.snapshot` актуальность** — `local-config/README.md:41` говорит "6 миграций применены", но `_journal.json` тоже 6. `Confirmed by config`. Но snapshot от 2026-06-17 — может быть stale если DB менялась. `Needs verification`.

9. **OpenAI Codex `/responses` endpoint** — `chatgpt.com/backend-api/codex/responses`. `Needs verification` — требует ли этот endpoint специального access tier (ChatGPT Plus/Pro). Если tier меняется — OpenAI proxy ломается.

10. **Anthropic beta headers актуальность** — `claude-code-20250219`, `oauth-2025-04-20`, `interleaved-thinking-2025-05-14`. `Needs verification` — могут быть deprecated Anthropic. Если устарели — 403/400.

11. **`cursor --install-extension` availability** — `build-and-install.ps1` вызывает `cursor` CLI. `Needs verification` — если Cursor не в PATH, скрипт падает.

12. **Extension `activationEvents: onStartupFinished`** — extension активируется при каждом старте Cursor. `Needs verification` — это запускает API процесс всегда, даже если пользователь не использует Ungate. Может конфликтовать с NSSM service.
