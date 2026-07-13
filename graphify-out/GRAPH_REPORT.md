# Graph Report - ungate-local  (2026-07-13)

## Corpus Check
- 285 files · ~91,228 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2059 nodes · 3387 edges · 185 communities (127 shown, 58 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 31 edges (avg confidence: 0.6)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `5b76eab0`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Shared Schemas and Helpers
- OpenAI Proxy and SSE Stream Mapper
- VS Code Extension Package Manifest
- Codex Input Normalization
- Web UI Logs and Settings Store
- Backend API Server Dependencies
- Anthropic Claude Authentication Provider
- Cloudflare Tunnel and Database Installation
- Dev Kit Linting & Prettier Tooling
- Web Analytics and Auth Pages
- Web Analytics UI Store
- VS Code Extension Controller
- Web Charting and Visualization
- Streaming Gateway and Handlers
- Web Settings UI and Authentication APIs
- Community 15
- tunnel-store.svelte.ts
- Community 17
- Community 18
- Community 19
- Community 20
- Community 21
- Community 22
- Community 23
- Community 24
- Community 25
- Community 26
- Community 27
- SettingsStore
- Community 29
- Formatter
- Community 31
- Community 32
- Community 33
- Community 34
- Community 35
- Community 36
- Community 37
- Community 38
- Community 39
- Community 40
- Community 41
- Community 42
- Community 43
- Community 44
- openai.ts
- Community 46
- Community 47
- Community 48
- Community 49
- Community 50
- Community 51
- Community 52
- Community 53
- Community 54
- Community 55
- Community 56
- Community 57
- Community 58
- Community 59
- Community 60
- OpenAiKeyFixInternals
- RequestBuilder
- Community 63
- Community 64
- Community 65
- Community 66
- Community 67
- minimax-stream-handler.ts
- Community 69
- Community 70
- Community 71
- Community 72
- Community 73
- Community 74
- Community 75
- Community 76
- Community 77
- Community 78
- Community 79
- Community 83
- Community 86
- Community 87
- Community 88
- Community 89
- Community 92
- Community 94
- Community 100
- Community 101
- Community 103
- Community 104
- Community 105
- routes-responses.test.ts
- Community 108
- Community 109
- xml-tool-parser.ts
- Community 111
- Community 112
- SettingsStore
- Community 114
- Formatter
- routes-health-settings-models-analytics.test.ts
- Community 117
- LogsStore
- Community 119
- Community 120
- Community 121
- Community 122
- Community 123
- Community 124
- Community 125
- post-checkout
- responses-stream-synthesizer.ts
- wake-ping.test.ts
- minimax-client.ts
- .response
- TunnelStore
- RuntimeStateFileStore
- .get
- model-validator.test.ts
- shared-log-store.test.ts
- constants.ts
- AnalyticsStore
- tsc-watch
- @types/better-sqlite3
- typescript
- vite
- OpenAiKeyFixInternals
- @skeletonlabs/skeleton
- @skeletonlabs/skeleton-svelte
- svelte
- svelte-check
- @tailwindcss/vite
- @types/d3-scale
- typescript
- @ungate/dev-kit
- vite
- eslint-config-prettier
- eslint-plugin-prettier
- eslint-plugin-simple-import-sort
- eslint-plugin-sort-class-members
- globals
- @html-eslint/eslint-plugin
- eslint
- prettier
- prettier-plugin-svelte
- reflect-metadata
- @stylistic/eslint-plugin
- svelte-eslint-parser
- typescript
- vite-tsconfig-paths
- vitest
- @vitest/eslint-plugin
- SettingsStore
- files
- runtime-state-store.test.ts
- frontend.ts
- tsc-alias
- @ungate/dev-kit
- vite-tsconfig-paths
- sqlite3-cli-resolver.test.ts
- prettier-plugin-tailwindcss

## God Nodes (most connected - your core abstractions)
1. `ExtensionController` - 40 edges
2. `getDb()` - 28 edges
3. `OpenAIChatRequest` - 27 edges
4. `Api` - 27 edges
5. `ApiServer` - 24 edges
6. `OpenAiKeyFix` - 24 edges
7. `Dashboard` - 23 edges
8. `ResponsesEventEmitter` - 22 edges
9. `RuntimeStateStore` - 22 edges
10. `Ungate (Local) AI Context` - 21 edges

## Surprising Connections (you probably didn't know these)
- `ResponsesToChatRequestResult` --references--> `OpenAIChatRequest`  [EXTRACTED]
  apps/api/src/orchestration/responses/responses-request-normalizer.ts → apps/api/src/types/openai.ts
- `plugin()` --indirect_call--> `context()`  [INFERRED]
  apps/api/src/routes/responses.ts → apps/api/tests/unit/orchestration/responses-synthesizer.test.ts
- `plugin()` --indirect_call--> `request()`  [INFERRED]
  apps/api/src/routes/responses.ts → apps/api/tests/unit/proxy/minimax-client.test.ts
- `proxyOpenAIRequest()` --calls--> `openaiToAnthropic()`  [EXTRACTED]
  apps/api/src/proxy/proxy-client.ts → apps/api/src/adapter/openai-to-anthropic.ts
- `startServer()` --calls--> `getDb()`  [EXTRACTED]
  apps/api/src/server.ts → apps/api/src/database/index.ts

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Ungate Visual Branding** — apps_extension_resources_icon_logo, apps_extension_resources_icon_interlocking_triangle_concept, apps_extension_resources_icon_brand_identity [INFERRED 0.85]

## Communities (185 total, 58 thin omitted)

### Community 0 - "Shared Schemas and Helpers"
Cohesion: 0.05
Nodes (42): MINIMAX_BASE_URLS, isModelMappingProvider(), isReasoningBudgetTier(), detectProviderByModel(), detectProviderBySource(), detectProviderBySourceOrModel(), PROVIDER_LABELS, rejectAbort() (+34 more)

### Community 1 - "OpenAI Proxy and SSE Stream Mapper"
Cohesion: 0.10
Nodes (13): ENV_CHATGPT_INSTRUCTIONS, OpenAiClient, ResponsesSseProcessor, ResponsesEventRouter, AssistantTextExtractor, StreamDiagnostics, StreamChunkMapper, PendingFunctionCallState (+5 more)

### Community 2 - "VS Code Extension Package Manifest"
Cohesion: 0.09
Nodes (21): activationEvents, bugs, url, categories, contributes, commands, description, displayName (+13 more)

### Community 3 - "Codex Input Normalization"
Cohesion: 0.06
Nodes (39): assertSupportedRequest(), ChatReasoningEffort, contentPartToChatText(), contentToChatContent(), functionCallToToolCall(), functionOutputToChatMessage(), imagePartToChatPart(), inputToItems() (+31 more)

### Community 4 - "Web UI Logs and Settings Store"
Cohesion: 0.12
Nodes (16): name, scripts, build, build:bundle, build:postbuild, build:watch, clean, db:generate (+8 more)

### Community 5 - "Backend API Server Dependencies"
Cohesion: 0.13
Nodes (12): ProxyOpenAiResult, getPartialTagSuffix(), MiniMaxStreamEvent, MiniMaxStreamHandler, MiniMaxStreamState, MiniMaxToolCallDelta, parseMiniMaxDelta(), OpenAIStreamHandler (+4 more)

### Community 6 - "Anthropic Claude Authentication Provider"
Cohesion: 0.06
Nodes (13): ApiServer, ApiServerCallbacks, HEALTH_CHECK_URL(), execFileAsync, NssmService, execFileAsync, InstallLogger, UngateSettingsReader (+5 more)

### Community 7 - "Cloudflare Tunnel and Database Installation"
Cohesion: 0.33
Nodes (9): defaultState, getTunnelStore(), keyFixEnabled, restartTunnel(), setKeyFixEnabled(), startTunnel(), stopTunnel(), tunnel (+1 more)

### Community 8 - "Dev Kit Linting & Prettier Tooling"
Cohesion: 0.10
Nodes (21): dependencies, better-sqlite3, date-fns, drizzle-orm, fastify, @fastify/cors, lodash-es, source-map-support (+13 more)

### Community 9 - "Web Analytics and Auth Pages"
Cohesion: 0.20
Nodes (15): ../auth/ChatGPTAuthSection.svelte, ../auth/ClaudeAuthSection.svelte, ../auth/MiniMaxAuthSection.svelte, ./ProviderPanel.svelte, virtual:icons/lucide/check, virtual:icons/lucide/copy, virtual:icons/lucide/external-link, @ungate/shared/frontend (+7 more)

### Community 10 - "Web Analytics UI Store"
Cohesion: 0.22
Nodes (8): dependencies, tslib, tslib, name, scripts, build, clean, type

### Community 11 - "VS Code Extension Controller"
Cohesion: 0.22
Nodes (14): completeRestart(), error, extractError(), getSettingsStore(), load(), loading, resetStatus(), restarting (+6 more)

### Community 12 - "Web Charting and Visualization"
Cohesion: 0.24
Nodes (8): closeDatabase(), DrizzleDb, getCurrentDbPath(), getDb(), getSqlite(), resolveDbPath(), Requests, resetIntegrationDatabase()

### Community 13 - "Streaming Gateway and Handlers"
Cohesion: 0.07
Nodes (39): anthropicOutputItems(), anthropicStopToStatus(), anthropicToolItem(), ChatFinishReason, chatOutputItems(), finishToStatus(), itemId(), mapUsage() (+31 more)

### Community 14 - "Web Settings UI and Authentication APIs"
Cohesion: 0.12
Nodes (7): Formatter, virtual:icons/lucide/bar-chart-3, svelte/reactivity, virtual:icons/lucide/refresh-cw, virtual:icons/lucide/settings, virtual:icons/lucide/terminal, virtual:icons/lucide/trash-2

### Community 15 - "Community 15"
Cohesion: 0.11
Nodes (22): apiTyped, availableModels(), ConfiguredModelEntry, configuredModels, detectProviderBySourceOrModelTyped, error, filteredRequests(), formatModelName() (+14 more)

### Community 17 - "Community 17"
Cohesion: 0.10
Nodes (5): Msg, MSGS_SIMPLE, extensionCommands, ExtensionController, ExtensionStatusBar

### Community 18 - "Community 18"
Cohesion: 0.07
Nodes (22): apiServerGetPortMock, apiServerIsStartupInProgressMock, apiServerRestartMock, apiServerStartMock, apiServerStopMock, apiServerSyncLeaderHealthMonitorMock, createContext(), createController() (+14 more)

### Community 19 - "Community 19"
Cohesion: 0.06
Nodes (35): *, default, dependencies, zod, devDependencies, tsup, typescript, @ungate/dev-kit (+27 more)

### Community 20 - "Community 20"
Cohesion: 0.11
Nodes (16): apiKeyAuth(), proxyRequestMock, oauthCompleteLoginMock, oauthLogoutMock, oauthStartLoginMock, oauthStatusMock, openaiCompleteLoginMock, openaiLogoutMock (+8 more)

### Community 21 - "Community 21"
Cohesion: 0.20
Nodes (12): apiLogs, clearApi(), clearTunnel(), copyApi(), copyTunnel(), formatLogs(), getLogsStore(), handleMessage() (+4 more)

### Community 23 - "Community 23"
Cohesion: 0.18
Nodes (10): name, private, scripts, build, build:watch, check, lint, lint:fix (+2 more)

### Community 24 - "Community 24"
Cohesion: 0.12
Nodes (12): AIProvider, ClaudeProvider, getProvider(), providers, MiniMaxProvider, OpenAIProvider, StaticTokenProvider, oauthGetAuthStatusMock (+4 more)

### Community 25 - "Community 25"
Cohesion: 0.10
Nodes (26): ModelMappingUpdateSchema, plugin(), SettingsUpdateSchema, validateSettingsUpdate(), startServer(), configPath, getLastPingAt(), getLastPingError() (+18 more)

### Community 26 - "Community 26"
Cohesion: 0.27
Nodes (5): Analytics, requests, PERIOD_OFFSETS, plugin(), toPeriod()

### Community 27 - "Community 27"
Cohesion: 0.11
Nodes (14): ResponsesStreamSynthesizer, ResponsesRouteDecision, ResponsesRouteTarget, callUpstream(), plugin(), recordError(), sendResponsesStream(), proxyMiniMaxRequestMock (+6 more)

### Community 28 - "SettingsStore"
Cohesion: 0.26
Nodes (3): BetterSqlite3Installer, execFile, InstallCallbacks

### Community 30 - "Formatter"
Cohesion: 0.16
Nodes (8): CursorStateDbReader, execFileAsync, InstallLogger, BIN_DIR, execFileAsync, InstallLogger, Sqlite3CliResolver, mocks

### Community 31 - "Community 31"
Cohesion: 0.10
Nodes (20): husky, devDependencies, eslint, husky, @ungate/dev-kit, engines, node, pnpm (+12 more)

### Community 32 - "Community 32"
Cohesion: 0.27
Nodes (5): baseDir, config, RuntimeStateDefaults, RuntimeStateNormalizer, SharedLogRecord

### Community 33 - "Community 33"
Cohesion: 0.10
Nodes (11): OpenAICallbackServer, OpenAIOAuthClient, OpenAIOAuthService, OpenAIOAuthUtils, OpenAIPkceSessionStore, CodexAuthInfo, PkceSession, Config (+3 more)

### Community 34 - "Community 34"
Cohesion: 0.10
Nodes (14): AnthropicToOpenai, HeadersExtractor, plugin(), PARAMETER_NAME_MAP, ToolTranslator, AnthropicError, AnthropicMessage, AnthropicRequest (+6 more)

### Community 35 - "Community 35"
Cohesion: 0.10
Nodes (19): compilerOptions, allowJs, emitDecoratorMetadata, esModuleInterop, experimentalDecorators, forceConsistentCasingInFileNames, importHelpers, isolatedModules (+11 more)

### Community 38 - "Community 38"
Cohesion: 0.19
Nodes (5): CLOUDFLARED_BIN_DIR, getCloudflaredBinPath(), getCloudflaredLegacyBinPath(), TunnelManager, mocks

### Community 39 - "Community 39"
Cohesion: 0.12
Nodes (15): 1.0.0 — 2026-03-31, 1.0.1 — 2026-04-02, 1.1.0 — 2026-04-03, 1.2.0 - 2026-04-04, 1.3.0 - 2026-04-04, 1.3.2 - 2026-04-15, 1.4.0 - 2026-04-20, 1.4.1 - 2026-04-22 (+7 more)

### Community 40 - "Community 40"
Cohesion: 0.10
Nodes (19): dependencies, cloudflared, devDependencies, tsx, @types/node, typescript, @ungate/dev-kit, cloudflared (+11 more)

### Community 41 - "Community 41"
Cohesion: 0.20
Nodes (10): AnthropicModelOverride, convertContent(), normalizeAssistantContentBlock(), normalizeAssistantContentBlocks(), normalizeModelName(), openaiToAnthropic(), CompletionModelRouting, hasMiniMaxExecCommand() (+2 more)

### Community 42 - "Community 42"
Cohesion: 0.10
Nodes (19): Add Models, Architecture, Configure Cursor, Connect a Provider, Development, Features, How it works, Installation (+11 more)

### Community 43 - "Community 43"
Cohesion: 0.16
Nodes (7): OAuth, PkceSession, TokenExchangeResponse, TokenInfo, TokenRefreshResponse, AuthStatus, LoginStart

### Community 44 - "Community 44"
Cohesion: 0.07
Nodes (27): compilerOptions, baseUrl, noEmit, paths, types, verbatimModuleSyntax, exclude, extends (+19 more)

### Community 45 - "openai.ts"
Cohesion: 0.10
Nodes (21): devDependencies, drizzle-kit, esbuild, tsc-watch, tsup, @types/lodash-es, @types/node, typescript (+13 more)

### Community 46 - "Community 46"
Cohesion: 0.12
Nodes (17): devDependencies, ovsx, tsup, @types/node, @types/vscode, typescript, @ungate/dev-kit, vitest (+9 more)

### Community 47 - "Community 47"
Cohesion: 0.32
Nodes (4): DEFAULT_PRICING, MODEL_PRICING, ModelPricing, Pricing

### Community 48 - "Community 48"
Cohesion: 0.11
Nodes (17): compilerOptions, declaration, declarationDir, declarationMap, noEmit, outDir, removeComments, rootDir (+9 more)

### Community 49 - "Community 49"
Cohesion: 0.13
Nodes (11): ToolNormalizer, AnthropicStreamBlock, AnthropicStreamDelta, AnthropicStreamEvent, AnthropicStreamInputJsonDelta, AnthropicStreamTextBlock, AnthropicStreamTextDelta, AnthropicStreamToolUseBlock (+3 more)

### Community 50 - "Community 50"
Cohesion: 0.13
Nodes (15): eslint-import-resolver-typescript, eslint-plugin-import-x, eslint-plugin-svelte, devDependencies, eslint-import-resolver-typescript, eslint-plugin-import-x, eslint-plugin-svelte, prettier (+7 more)

### Community 51 - "Community 51"
Cohesion: 0.15
Nodes (4): createWebviewPanelMock, Disposable, fileUriMock, sharedLogs

### Community 52 - "Community 52"
Cohesion: 0.20
Nodes (8): authStates, getProviderModelsCount(), getSettingsUiStore(), ProviderAuthState, providerLabels, selectedProvider, setSelectedProvider(), SettingsUiStore

### Community 53 - "Community 53"
Cohesion: 0.13
Nodes (14): compilerOptions, declaration, declarationDir, declarationMap, noEmit, outDir, removeComments, rootDir (+6 more)

### Community 54 - "Community 54"
Cohesion: 0.31
Nodes (7): extractError(), getAnalyticsStore(), load(), loadRequests(), loadSummary(), loadTokenSeries(), reset()

### Community 55 - "Community 55"
Cohesion: 0.11
Nodes (18): compilerOptions, importHelpers, lib, module, moduleResolution, noEmit, exclude, extends (+10 more)

### Community 56 - "Community 56"
Cohesion: 0.27
Nodes (6): configPath, defaults, loadWakePingConfig(), sendWakePing(), startWakePingScheduler(), WakePingConfig

### Community 57 - "Community 57"
Cohesion: 0.12
Nodes (16): compilerOptions, baseUrl, paths, types, exclude, extends, include, dist (+8 more)

### Community 58 - "Community 58"
Cohesion: 0.18
Nodes (10): compilerOptions, declaration, noEmit, outDir, rootDir, sourceMap, extends, include (+2 more)

### Community 59 - "Community 59"
Cohesion: 0.21
Nodes (5): Settings, ModelMappings, appSettings, modelMappings, schema

### Community 60 - "Community 60"
Cohesion: 0.15
Nodes (13): devDependencies, @iconify-json/lucide, @sveltejs/vite-plugin-svelte, tailwindcss, @tsconfig/svelte, @types/node, unplugin-icons, @types/node (+5 more)

### Community 61 - "OpenAiKeyFixInternals"
Cohesion: 0.15
Nodes (5): CompletionErrorMapper, MiniMaxErrorContext, openaiChatErrorMessages, CompletionStreamingGateway, errorMessageFor()

### Community 62 - "RequestBuilder"
Cohesion: 0.22
Nodes (9): dependencies, d3-scale, date-fns, layerchart, @ungate/shared, date-fns, layerchart, @ungate/shared (+1 more)

### Community 64 - "Community 64"
Cohesion: 0.15
Nodes (12): 12. Source of Truth by Concern, 15. Operational Gotchas, 16. What This Project Must NOT Directly Change, 17. Change Impact Map, 18. Pre-Release Checklist, 19. AI Agent Working Rules, 1. Project Identity, 20. Needs Verification / Open Questions (+4 more)

### Community 65 - "Community 65"
Cohesion: 0.22
Nodes (8): compilerOptions, noEmit, outDir, rootDir, extends, include, src, ./tsconfig.json

### Community 66 - "Community 66"
Cohesion: 0.18
Nodes (10): ./**/*.ts, compilerOptions, types, exclude, extends, include, eslint.config.mjs, node (+2 more)

### Community 67 - "Community 67"
Cohesion: 0.14
Nodes (13): compilerOptions, baseUrl, types, exclude, extends, include, ./eslint.config.mjs, lib (+5 more)

### Community 68 - "minimax-stream-handler.ts"
Cohesion: 0.25
Nodes (3): SharedLogStore, sharedLogTestBaseDir, sharedLogTestPath

### Community 69 - "Community 69"
Cohesion: 0.40
Nodes (4): post-commit script, GRAPHIFY_CHANGED, GRAPHIFY_REBUILD_LOG, PYTHONHASHSEED

### Community 70 - "Community 70"
Cohesion: 0.17
Nodes (11): compilerOptions, baseUrl, exclude, extends, include, eslint.config.mjs, lib, node_modules (+3 more)

### Community 71 - "Community 71"
Cohesion: 0.67
Nodes (3): globalSetup(), removeTestDb(), TEST_DB_PATH

### Community 72 - "Community 72"
Cohesion: 0.15
Nodes (11): 1. `apps/extension/package.json` (ОБНОВЛЁН), 2. `apps/api/src/wake-ping.ts` (НОВЫЙ ФАЙЛ), 3. `apps/api/src/server.ts` (ОБНОВЛЁН), 4. `apps/extension/src/extension-commands.ts` (ОБНОВЛЁН), 5. `apps/extension/src/dashboard.ts` (ОБНОВЛЁН), Изменения по исходным файлам, Параметры по умолчанию (`bundled/api/wake-ping.json`), Сводка (+3 more)

### Community 73 - "Community 73"
Cohesion: 0.67
Nodes (3): Ungate Brand Identity, Interlocking Triangle Logo Concept, Ungate Extension Icon

### Community 75 - "Community 75"
Cohesion: 0.12
Nodes (21): Assert-UngateCodexConfig(), Ensure-ModelProvidersInConfig(), Get-CodexBetaProcesses(), Get-CodexCliExecutable(), Get-ProviderDefinitions(), Get-ProviderTomlBlock(), Get-WorkspaceRootList(), Initialize-CodexWindowsSandbox() (+13 more)

### Community 87 - "Community 87"
Cohesion: 0.28
Nodes (4): AIProviderName, OAuthCredentials, ProviderSettings, providerSettings

### Community 88 - "Community 88"
Cohesion: 0.20
Nodes (10): keywords, ai, anthropic, chatgpt, claude, cursor, gpt, minimax (+2 more)

### Community 89 - "Community 89"
Cohesion: 0.22
Nodes (9): dependencies, cloudflared, tar, @ungate/shared, zod, @ungate/shared, zod, cloudflared (+1 more)

### Community 94 - "Community 94"
Cohesion: 0.08
Nodes (23): config, defaultIgnores, languageOptions, prettierOptions, prettierPluginSveltePath, prettierPluginTailwindcssPath, require, resolverSettings (+15 more)

### Community 104 - "Community 104"
Cohesion: 0.18
Nodes (11): 11. Critical Contracts and Invariants, A. Proxy API Key Auth, B. Port Detection Contract, C. Tunnel URL Contract (LOCAL FORK — frpc, не cloudflared), D. Database Schema Invariants, E. Migration Application Contract, F. Wake Ping Config Path Contract, G. Runtime State File Contract (+3 more)

### Community 105 - "Community 105"
Cohesion: 0.18
Nodes (11): 14. Build / Test / Deploy / Update Rules, Build commands, Build order (dependency graph), CI/CD, Deploy/publish, Drift: docs vs artifacts, Generated artifacts (deployed в vsix), Husky / git hooks (+3 more)

### Community 107 - "routes-responses.test.ts"
Cohesion: 0.26
Nodes (5): MiniMaxChatHandler, OpenAiMappedChatHandler, detectProvider(), proxyOpenAIRequest(), OpenAIChatRequest

### Community 108 - "Community 108"
Cohesion: 0.20
Nodes (8): Преимущества `J:\Dev\ungate-local\` перед распакованной установкой, Размер и верификация, Что внутри `local-config/`, Что делать, когда будете готовы к полному переходу, Что здесь есть, Что НЕ здесь (и где оно), Что СЕЙЧАС не нужно делать, Что это

### Community 109 - "Community 109"
Cohesion: 0.22
Nodes (9): 13. Security and Permission Model, Auth model, Command execution risks, Filesystem write risks, Input validation, Known gaps, Network/SSRF risks, Roles/permissions (+1 more)

### Community 110 - "xml-tool-parser.ts"
Cohesion: 0.29
Nodes (5): XmlToolParser, Tool, ParsedToolCall, ProxyResult, ToolMapResult

### Community 111 - "Community 111"
Cohesion: 0.25
Nodes (6): Версия, Источник, Объём, Сравнение с распакованной установкой (baseline), Целостность, Что НЕ копировалось

### Community 112 - "Community 112"
Cohesion: 0.25
Nodes (8): 10. End-to-End Operational Flows, A. Chat request flow (основной), B. OAuth login flow (Claude), C. OAuth login flow (OpenAI/ChatGPT), D. Wake Ping flow (local addition), E. OpenAI Key Fix flow, F. Build & install flow (local), G. Multi-window leader election

### Community 113 - "SettingsStore"
Cohesion: 0.15
Nodes (10): copyFileSyncMock, ExecFileCallback, execFileMock, existsSyncMock, fetchMock, isApiStartSuppressedMock, mkdirSyncMock, renameSyncMock (+2 more)

### Community 114 - "Community 114"
Cohesion: 0.29
Nodes (6): local-config/, Если хотите **обновить** снэпшот (например, добавили нового провайдера), Как восстановить (если что-то сломалось), ⚠️ Секреты, Состав, Что внутри `data.db.snapshot`

### Community 115 - "Formatter"
Cohesion: 0.33
Nodes (6): scripts, build, lint, lint:fix, publish, test

### Community 116 - "routes-health-settings-models-analytics.test.ts"
Cohesion: 0.17
Nodes (11): ModelValidateSchema, plugin(), ModelValidator, probeBody(), readErrorMessage(), getAuthStatusMock, makeClaudeCodeRequestMock, openaiAuthStatusMock (+3 more)

### Community 119 - "Community 119"
Cohesion: 0.33
Nodes (6): 5. Main Modules, API (`apps/api/`), Dev-kit (`packages/dev-kit/`), Extension (`apps/extension/`), Shared (`packages/shared/`), Web (`apps/web/`)

### Community 120 - "Community 120"
Cohesion: 0.33
Nodes (6): 6. Integration Points, CLI Commands (extension), External API clients, HTTP Routes (API), OAuth callback server, Webview messages (extension ↔ webview)

### Community 121 - "Community 121"
Cohesion: 0.33
Nodes (6): 8. Configuration and Environment, Config files (runtime), Defaults опасные, Environment variables, Hardcoded config (не env), Значения, которые нельзя менять без координации

### Community 122 - "Community 122"
Cohesion: 0.40
Nodes (5): 4. Runtime and Bootstrap, API bootstrap, Config loading, Extension bootstrap, Shutdown

### Community 123 - "Community 123"
Cohesion: 0.40
Nodes (5): 7. Data Model and Storage, Cache / derived state, Database: `~/.ungate/data.db` (SQLite, WAL mode), Filesystem state, Migrations

### Community 126 - "post-checkout"
Cohesion: 0.50
Nodes (3): post-checkout script, GRAPHIFY_REBUILD_LOG, PYTHONHASHSEED

### Community 127 - "responses-stream-synthesizer.ts"
Cohesion: 0.40
Nodes (5): exports, ./eslint, ./eslint-svelte, ./tsconfig-base, ./vitest

### Community 133 - "wake-ping.test.ts"
Cohesion: 0.18
Nodes (7): plugin(), proxyMiniMaxRequestMock, proxyOpenAIRequestMock, proxyRequestMock, requestsRecordMock, resolveForChatCompletionMock, request()

### Community 134 - "minimax-client.ts"
Cohesion: 0.26
Nodes (12): buildMiniMaxRequestBody(), getMiniMaxReasoning(), jsonContentType(), miniMaxErrorBody(), MiniMaxResponseBody, MiniMaxResponseNormalization, normalizeMiniMaxContent(), normalizeMiniMaxMessages() (+4 more)

### Community 135 - ".response"
Cohesion: 0.50
Nodes (4): author, email, name, url

### Community 138 - ".get"
Cohesion: 0.24
Nodes (3): loadConfiguredModels(), createAuthStates(), refreshAuthStates()

### Community 139 - "model-validator.test.ts"
Cohesion: 0.26
Nodes (4): NodeResolver, RuntimeInfo, existsSyncMock, spawnSyncMock

### Community 140 - "shared-log-store.test.ts"
Cohesion: 0.67
Nodes (3): repository, type, url

### Community 141 - "constants.ts"
Cohesion: 0.50
Nodes (3): DEFAULTS, PERIODS, REQUEST_LIMITS

### Community 143 - "tsc-watch"
Cohesion: 0.29
Nodes (3): CompletionRequestTelemetry, ClaudeChatHandler, requestRecordMock

### Community 145 - "typescript"
Cohesion: 0.27
Nodes (7): extractUsage(), makeClaudeCodeRequest(), proxyRequest(), RequestResult, TOOL_NAME_MAPPING, ToolMapper, VALID_CLAUDE_CODE_TOOLS

### Community 146 - "vite"
Cohesion: 0.29
Nodes (6): config, Logger, OpenAiKeyState, RuntimeState, ServiceState, StateChangeHandler

### Community 147 - "OpenAiKeyFixInternals"
Cohesion: 0.14
Nodes (5): createRuntimeState(), TestHelper, createLeaderKeyFix(), mocks, OpenAiKeyFixInternals

### Community 175 - "files"
Cohesion: 0.50
Nodes (4): files, lib, src, tsconfig.base.json

## Knowledge Gaps
- **685 isolated node(s):** `graphify`, `ungate-api NSSM service`, `graphify`, `Что это`, `Что здесь есть` (+680 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **58 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `OpenAIChatRequest` connect `routes-responses.test.ts` to `OpenAI Proxy and SSE Stream Mapper`, `Community 34`, `Codex Input Normalization`, `wake-ping.test.ts`, `minimax-client.ts`, `Community 41`, `tsc-watch`, `routes-health-settings-models-analytics.test.ts`, `Community 27`?**
  _High betweenness centrality (0.014) - this node is a cross-community bridge._
- **Why does `getDb()` connect `Web Charting and Visualization` to `Community 25`, `Community 26`, `Community 59`, `Community 87`?**
  _High betweenness centrality (0.010) - this node is a cross-community bridge._
- **Why does `logger` connect `Community 34` to `Community 33`, `OpenAI Proxy and SSE Stream Mapper`, `Backend API Server Dependencies`, `Community 43`, `Community 49`, `Community 26`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **What connects `graphify`, `ungate-api NSSM service`, `graphify` to the rest of the system?**
  _685 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Shared Schemas and Helpers` be split into smaller, more focused modules?**
  _Cohesion score 0.05323653962492438 - nodes in this community are weakly interconnected._
- **Should `OpenAI Proxy and SSE Stream Mapper` be split into smaller, more focused modules?**
  _Cohesion score 0.0998185117967332 - nodes in this community are weakly interconnected._
- **Should `VS Code Extension Package Manifest` be split into smaller, more focused modules?**
  _Cohesion score 0.09090909090909091 - nodes in this community are weakly interconnected._