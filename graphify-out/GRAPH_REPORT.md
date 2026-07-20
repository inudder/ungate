# Graph Report - ungate-local  (2026-07-19)

## Corpus Check
- 293 files · ~101,411 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2100 nodes · 3766 edges · 176 communities (120 shown, 56 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 38 edges (avg confidence: 0.64)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `47653cde`
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
- Community 85
- Community 86
- Community 87
- Community 88
- Community 89
- Community 92
- Community 94
- Community 100
- Community 101
- Community 102
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
- reflect-metadata
- tsc-watch
- @types/better-sqlite3
- svelte
- vite
- OpenAiKeyFixInternals
- @skeletonlabs/skeleton
- constants.ts
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
- @stylistic/eslint-plugin
- svelte-eslint-parser
- typescript
- vite-tsconfig-paths
- vitest
- @vitest/eslint-plugin
- SettingsStore
- AnalyticsStore
- svelte-check

## God Nodes (most connected - your core abstractions)
1. `ExtensionController` - 41 edges
2. `getDb()` - 28 edges
3. `OpenAIChatRequest` - 27 edges
4. `Api` - 27 edges
5. `OpenAiKeyFix` - 26 edges
6. `RuntimeStateStore` - 25 edges
7. `ApiServer` - 24 edges
8. `logger` - 23 edges
9. `Dashboard` - 23 edges
10. `ResponsesEventEmitter` - 22 edges

## Surprising Connections (you probably didn't know these)
- `createBridgeServer()` --indirect_call--> `mapping()`  [INFERRED]
  scripts/cliproxy-namespace-bridge.mjs → apps/api/tests/unit/orchestration/openai-model-routing.test.ts
- `createBridgeServer()` --indirect_call--> `request()`  [INFERRED]
  scripts/cliproxy-namespace-bridge.mjs → apps/api/tests/unit/proxy/minimax-client.test.ts
- `plugin()` --indirect_call--> `context()`  [INFERRED]
  apps/api/src/routes/responses.ts → apps/api/tests/unit/orchestration/responses-synthesizer.test.ts
- `ResponsesToChatRequestResult` --references--> `OpenAIChatRequest`  [EXTRACTED]
  apps/api/src/orchestration/responses/responses-request-normalizer.ts → apps/api/src/types/openai.ts
- `plugin()` --indirect_call--> `request()`  [INFERRED]
  apps/api/src/routes/openai.ts → apps/api/tests/unit/proxy/minimax-client.test.ts

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Ungate Visual Branding** — apps_extension_resources_icon_logo, apps_extension_resources_icon_interlocking_triangle_concept, apps_extension_resources_icon_brand_identity [INFERRED 0.85]

## Communities (176 total, 56 thin omitted)

### Community 0 - "Shared Schemas and Helpers"
Cohesion: 0.05
Nodes (44): MINIMAX_BASE_URLS, ExtensionToWebview, WebviewToExtension, isModelMappingProvider(), isReasoningBudgetTier(), detectProviderByModel(), detectProviderBySource(), detectProviderBySourceOrModel() (+36 more)

### Community 1 - "OpenAI Proxy and SSE Stream Mapper"
Cohesion: 0.14
Nodes (11): ResponsesSseProcessor, ResponsesEventRouter, AssistantTextExtractor, StreamDiagnostics, StreamChunkMapper, PendingFunctionCallState, StreamProcessResult, StreamState (+3 more)

### Community 2 - "VS Code Extension Package Manifest"
Cohesion: 0.09
Nodes (21): activationEvents, bugs, url, categories, contributes, commands, description, displayName (+13 more)

### Community 3 - "Codex Input Normalization"
Cohesion: 0.06
Nodes (34): assertSupportedRequest(), ChatReasoningEffort, contentPartToChatText(), contentToChatContent(), functionCallToToolCall(), functionOutputToChatMessage(), imagePartToChatPart(), inputToItems() (+26 more)

### Community 4 - "Web UI Logs and Settings Store"
Cohesion: 0.12
Nodes (16): name, scripts, build, build:bundle, build:postbuild, build:watch, clean, db:generate (+8 more)

### Community 5 - "Backend API Server Dependencies"
Cohesion: 0.08
Nodes (17): CompletionStreamingGateway, ENV_CHATGPT_INSTRUCTIONS, ProxyOpenAiResult, getPartialTagSuffix(), MiniMaxStreamEvent, MiniMaxStreamHandler, MiniMaxStreamState, MiniMaxToolCallDelta (+9 more)

### Community 6 - "Anthropic Claude Authentication Provider"
Cohesion: 0.12
Nodes (5): ApiServer, ApiServerCallbacks, HEALTH_CHECK_URL(), execFileAsync, NssmService

### Community 7 - "Cloudflare Tunnel and Database Installation"
Cohesion: 0.23
Nodes (11): defaultState, getTunnelStore(), keyFixEnabled, restartTunnel(), setKeyFixEnabled(), startTunnel(), stopTunnel(), tunnel (+3 more)

### Community 8 - "Dev Kit Linting & Prettier Tooling"
Cohesion: 0.10
Nodes (21): dependencies, better-sqlite3, date-fns, drizzle-orm, fastify, @fastify/cors, lodash-es, source-map-support (+13 more)

### Community 9 - "Web Analytics and Auth Pages"
Cohesion: 0.19
Nodes (18): ../auth/ChatGPTAuthSection.svelte, ../auth/ClaudeAuthSection.svelte, ../auth/MiniMaxAuthSection.svelte, ./ModelsSection.svelte, ./ProviderPanel.svelte, virtual:icons/lucide/check, virtual:icons/lucide/copy, virtual:icons/lucide/external-link (+10 more)

### Community 10 - "Web Analytics UI Store"
Cohesion: 0.15
Nodes (12): dependencies, tslib, files, lib, src, tsconfig.base.json, tslib, name (+4 more)

### Community 11 - "VS Code Extension Controller"
Cohesion: 0.22
Nodes (14): completeRestart(), error, extractError(), getSettingsStore(), load(), loading, resetStatus(), restarting (+6 more)

### Community 12 - "Web Charting and Visualization"
Cohesion: 0.15
Nodes (13): closeDatabase(), DrizzleDb, getCurrentDbPath(), getDb(), getSqlite(), resolveDbPath(), ModelMappings, Requests (+5 more)

### Community 13 - "Streaming Gateway and Handlers"
Cohesion: 0.05
Nodes (47): anthropicOutputItems(), anthropicStopToStatus(), anthropicToolItem(), ChatFinishReason, chatOutputItems(), finishToStatus(), itemId(), mapUsage() (+39 more)

### Community 14 - "Web Settings UI and Authentication APIs"
Cohesion: 0.11
Nodes (9): Formatter, virtual:icons/lucide/bar-chart-3, ./analytics-store.svelte, ./logs-store.svelte, svelte/reactivity, virtual:icons/lucide/refresh-cw, virtual:icons/lucide/settings, virtual:icons/lucide/terminal (+1 more)

### Community 15 - "Community 15"
Cohesion: 0.11
Nodes (22): apiTyped, availableModels(), ConfiguredModelEntry, configuredModels, detectProviderBySourceOrModelTyped, error, filteredRequests(), formatModelName() (+14 more)

### Community 16 - "tunnel-store.svelte.ts"
Cohesion: 0.11
Nodes (4): Dashboard, SharedLogStore, sharedLogTestBaseDir, sharedLogTestPath

### Community 18 - "Community 18"
Cohesion: 0.07
Nodes (22): apiServerGetPortMock, apiServerIsStartupInProgressMock, apiServerRestartMock, apiServerStartMock, apiServerStopMock, apiServerSyncLeaderHealthMonitorMock, createContext(), createController() (+14 more)

### Community 19 - "Community 19"
Cohesion: 0.07
Nodes (27): dependencies, zod, devDependencies, tsup, typescript, @ungate/dev-kit, exports, ./frontend (+19 more)

### Community 20 - "Community 20"
Cohesion: 0.07
Nodes (25): proxyRequestMock, oauthCompleteLoginMock, oauthLogoutMock, oauthStartLoginMock, oauthStatusMock, openaiCompleteLoginMock, openaiLogoutMock, openaiStartLoginMock (+17 more)

### Community 21 - "Community 21"
Cohesion: 0.31
Nodes (10): apiLogs, clearApi(), clearTunnel(), copyApi(), copyTunnel(), formatLogs(), getLogsStore(), handleMessage() (+2 more)

### Community 22 - "Community 22"
Cohesion: 0.13
Nodes (14): Settings, plugin(), ModelValidateSchema, plugin(), ModelMappingUpdateSchema, plugin(), SettingsUpdateSchema, validateSettingsUpdate() (+6 more)

### Community 23 - "Community 23"
Cohesion: 0.18
Nodes (10): name, private, scripts, build, build:watch, check, lint, lint:fix (+2 more)

### Community 24 - "Community 24"
Cohesion: 0.13
Nodes (12): AIProvider, AIProviderName, ClaudeProvider, providers, MiniMaxProvider, OpenAIProvider, StaticTokenProvider, oauthGetAuthStatusMock (+4 more)

### Community 25 - "Community 25"
Cohesion: 0.17
Nodes (17): startServer(), setQuietMode(), configPath, getLastPingAt(), getLastPingError(), isWakePingRunning(), loadWakePingConfig(), saveWakePingConfig() (+9 more)

### Community 26 - "Community 26"
Cohesion: 0.33
Nodes (4): Analytics, PERIOD_OFFSETS, plugin(), toPeriod()

### Community 27 - "Community 27"
Cohesion: 0.25
Nodes (6): getAuthStatusMock, makeClaudeCodeRequestMock, openaiAuthStatusMock, providerSettingsGetMock, proxyMiniMaxRequestMock, proxyOpenAIRequestMock

### Community 28 - "SettingsStore"
Cohesion: 0.08
Nodes (17): BetterSqlite3Installer, execFile, InstallCallbacks, NodeResolver, RuntimeInfo, copyFileSyncMock, ExecFileCallback, execFileMock (+9 more)

### Community 30 - "Formatter"
Cohesion: 0.11
Nodes (12): CursorStateDbReader, execFileAsync, InstallLogger, BIN_DIR, execFileAsync, InstallLogger, Sqlite3CliResolver, execFileAsync (+4 more)

### Community 31 - "Community 31"
Cohesion: 0.10
Nodes (20): husky, devDependencies, eslint, husky, @ungate/dev-kit, engines, node, pnpm (+12 more)

### Community 32 - "Community 32"
Cohesion: 0.15
Nodes (11): config, Logger, OpenAiKeyState, RuntimeState, ServiceState, StateChangeHandler, baseDir, config (+3 more)

### Community 33 - "Community 33"
Cohesion: 0.07
Nodes (19): OAuth, PkceSession, TokenExchangeResponse, OpenAICallbackServer, OpenAIOAuthClient, OpenAIOAuthService, OpenAIOAuthUtils, OpenAIPkceSessionStore (+11 more)

### Community 34 - "Community 34"
Cohesion: 0.13
Nodes (11): AnthropicToOpenai, PARAMETER_NAME_MAP, ToolTranslator, AnthropicResponse, OpenAIChatResponse, OpenAIResponseOutputItem, OpenAIResponseOutputText, OpenAIResponseReasoningEffort (+3 more)

### Community 35 - "Community 35"
Cohesion: 0.10
Nodes (19): compilerOptions, allowJs, emitDecoratorMetadata, esModuleInterop, experimentalDecorators, forceConsistentCasingInFileNames, importHelpers, isolatedModules (+11 more)

### Community 36 - "Community 36"
Cohesion: 0.12
Nodes (19): RequestResult, RequestBuilder, resolveEffort(), VALID_EFFORTS, TOOL_NAME_MAPPING, ToolMapper, VALID_CLAUDE_CODE_TOOLS, AnthropicError (+11 more)

### Community 38 - "Community 38"
Cohesion: 0.19
Nodes (5): CLOUDFLARED_BIN_DIR, getCloudflaredBinPath(), getCloudflaredLegacyBinPath(), TunnelManager, mocks

### Community 40 - "Community 40"
Cohesion: 0.09
Nodes (22): dependencies, cloudflared, devDependencies, tsx, @types/node, typescript, @ungate/dev-kit, cloudflared (+14 more)

### Community 41 - "Community 41"
Cohesion: 0.20
Nodes (11): AnthropicModelOverride, convertContent(), normalizeAssistantContentBlock(), normalizeAssistantContentBlocks(), normalizeModelName(), openaiToAnthropic(), detectProvider(), proxyOpenAIRequest() (+3 more)

### Community 42 - "Community 42"
Cohesion: 0.20
Nodes (13): HeadersExtractor, ResponsesRouteDecision, ResponsesRouteTarget, apiKeyAuth(), extractUsage(), proxyRequest(), plugin(), callUpstream() (+5 more)

### Community 43 - "Community 43"
Cohesion: 0.40
Nodes (4): Answer, Outcome, Q: J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 после обновления Codex Beta перестал запускаться: plugin list --json reports openai-bundled marketplace root does not contain a supported manifest., Source Nodes

### Community 44 - "Community 44"
Cohesion: 0.07
Nodes (27): compilerOptions, baseUrl, noEmit, paths, types, verbatimModuleSyntax, exclude, extends (+19 more)

### Community 45 - "openai.ts"
Cohesion: 0.10
Nodes (21): devDependencies, drizzle-kit, esbuild, tsc-alias, tsup, @types/lodash-es, @types/node, @ungate/dev-kit (+13 more)

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
Cohesion: 0.21
Nodes (27): Assert-StagedPluginInstallation(), Commit-StagedPluginIsolation(), Copy-IsolatedMarketplace(), Get-BrowserClientVerification(), Get-BundledMarketplacePluginIds(), Get-CodexPluginDirectoryState(), Get-CodexPluginInventory(), Get-ComparablePath() (+19 more)

### Community 50 - "Community 50"
Cohesion: 0.13
Nodes (15): eslint-import-resolver-typescript, eslint-plugin-import-x, eslint-plugin-svelte, devDependencies, eslint-import-resolver-typescript, eslint-plugin-import-x, eslint-plugin-svelte, prettier-plugin-tailwindcss (+7 more)

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

### Community 60 - "Community 60"
Cohesion: 0.15
Nodes (13): devDependencies, @iconify-json/lucide, @skeletonlabs/skeleton-svelte, @sveltejs/vite-plugin-svelte, @tsconfig/svelte, @types/node, unplugin-icons, @types/node (+5 more)

### Community 61 - "OpenAiKeyFixInternals"
Cohesion: 0.14
Nodes (20): addBareCandidate(), BridgeRequestError, canonicalizeArguments(), cloneFunctionTool(), copyHeaders(), createBridgeServer(), createSseTransform(), flattenResponsesRequest() (+12 more)

### Community 62 - "RequestBuilder"
Cohesion: 0.22
Nodes (9): dependencies, d3-scale, date-fns, layerchart, @ungate/shared, date-fns, layerchart, @ungate/shared (+1 more)

### Community 63 - "Community 63"
Cohesion: 0.17
Nodes (4): Msg, MSGS_SIMPLE, extensionCommands, LogRingBuffer

### Community 64 - "Community 64"
Cohesion: 0.15
Nodes (12): 12. Source of Truth by Concern, 15. Operational Gotchas, 16. What This Project Must NOT Directly Change, 17. Change Impact Map, 18. Pre-Release Checklist, 19. AI Agent Working Rules, 1. Project Identity, 20. Needs Verification / Open Questions (+4 more)

### Community 65 - "Community 65"
Cohesion: 0.22
Nodes (8): compilerOptions, noEmit, outDir, rootDir, extends, include, src, ./tsconfig.json

### Community 66 - "Community 66"
Cohesion: 0.18
Nodes (10): ./**/*.mjs, ./**/*.ts, compilerOptions, types, exclude, extends, include, node (+2 more)

### Community 67 - "Community 67"
Cohesion: 0.14
Nodes (13): compilerOptions, baseUrl, types, exclude, extends, include, ./eslint.config.mjs, lib (+5 more)

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
Cohesion: 0.09
Nodes (27): Assert-UngateCodexConfig(), Ensure-CliProxyBridge(), Ensure-ModelProvidersInConfig(), Get-CliProxyBridgeHealth(), Get-CodexBetaProcesses(), Get-CodexCliExecutable(), Get-ProviderDefinitions(), Get-ProviderTomlBlock() (+19 more)

### Community 85 - "Community 85"
Cohesion: 0.23
Nodes (3): RuntimeStateFileStore, CrossProcessLock, { mkdirSyncMock, writeFileSyncMock, rmSyncMock, rmdirSyncMock, existsSyncMock, readFileSyncMock, sleepMock, killMock }

### Community 87 - "Community 87"
Cohesion: 0.23
Nodes (3): OAuthCredentials, ProviderSettings, providerSettings

### Community 88 - "Community 88"
Cohesion: 0.20
Nodes (10): keywords, ai, anthropic, chatgpt, claude, cursor, gpt, minimax (+2 more)

### Community 89 - "Community 89"
Cohesion: 0.22
Nodes (9): dependencies, cloudflared, tar, @ungate/shared, zod, cloudflared, @ungate/shared, zod (+1 more)

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
Cohesion: 0.12
Nodes (11): CompletionRequestTelemetry, CompletionModelRouting, hasMiniMaxExecCommand(), MINIMAX_FILE_EDITING_INSTRUCTION, withMiniMaxFileEditingInstruction(), ClaudeChatHandler, MiniMaxChatHandler, OpenAiMappedChatHandler (+3 more)

### Community 108 - "Community 108"
Cohesion: 0.20
Nodes (8): Преимущества `J:\Dev\ungate-local\` перед распакованной установкой, Размер и верификация, Что внутри `local-config/`, Что делать, когда будете готовы к полному переходу, Что здесь есть, Что НЕ здесь (и где оно), Что СЕЙЧАС не нужно делать, Что это

### Community 109 - "Community 109"
Cohesion: 0.22
Nodes (9): 13. Security and Permission Model, Auth model, Command execution risks, Filesystem write risks, Input validation, Known gaps, Network/SSRF risks, Roles/permissions (+1 more)

### Community 111 - "Community 111"
Cohesion: 0.25
Nodes (6): Версия, Источник, Объём, Сравнение с распакованной установкой (baseline), Целостность, Что НЕ копировалось

### Community 112 - "Community 112"
Cohesion: 0.25
Nodes (8): 10. End-to-End Operational Flows, A. Chat request flow (основной), B. OAuth login flow (Claude), C. OAuth login flow (OpenAI/ChatGPT), D. Wake Ping flow (local addition), E. OpenAI Key Fix flow, F. Build & install flow (local), G. Multi-window leader election

### Community 114 - "Community 114"
Cohesion: 0.29
Nodes (6): local-config/, Если хотите **обновить** снэпшот (например, добавили нового провайдера), Как восстановить (если что-то сломалось), ⚠️ Секреты, Состав, Что внутри `data.db.snapshot`

### Community 115 - "Formatter"
Cohesion: 0.33
Nodes (6): scripts, build, lint, lint:fix, publish, test

### Community 116 - "routes-health-settings-models-analytics.test.ts"
Cohesion: 0.21
Nodes (5): CompletionErrorMapper, MiniMaxErrorContext, openaiChatErrorMessages, errorMessageFor(), mapping()

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
Nodes (5): createRuntimeState(), createRuntimeState(), TestHelper, createLeaderKeyFix(), mocks

### Community 134 - "minimax-client.ts"
Cohesion: 0.21
Nodes (15): getProvider(), buildMiniMaxRequestBody(), getMiniMaxReasoning(), jsonContentType(), miniMaxErrorBody(), MiniMaxResponseBody, MiniMaxResponseNormalization, normalizeMiniMaxContent() (+7 more)

### Community 135 - ".response"
Cohesion: 0.50
Nodes (4): author, email, name, url

### Community 138 - ".get"
Cohesion: 0.24
Nodes (3): loadConfiguredModels(), createAuthStates(), refreshAuthStates()

### Community 140 - "shared-log-store.test.ts"
Cohesion: 0.67
Nodes (3): repository, type, url

### Community 147 - "OpenAiKeyFixInternals"
Cohesion: 0.22
Nodes (4): isApiStartSuppressedMock, resetApiForRestartMock, {
	runtimeReadMock,
	runtimeHasLiveClientsMock,
	runtimeMutateMock,
	sleepMock,
	nssmRestartMock,
	settingsInitMock,
	settingsReadPortMock
}, suppressApiAutoStartMock

### Community 151 - "constants.ts"
Cohesion: 0.50
Nodes (3): DEFAULTS, PERIODS, REQUEST_LIMITS

## Knowledge Gaps
- **656 isolated node(s):** `name`, `type`, `start`, `build`, `build:watch` (+651 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **56 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ExtensionController` connect `Community 17` to `Community 37`, `Anthropic Claude Authentication Provider`, `Community 38`, `tunnel-store.svelte.ts`, `Community 18`, `Community 59`, `Community 63`?**
  _High betweenness centrality (0.012) - this node is a cross-community bridge._
- **Why does `Dashboard` connect `tunnel-store.svelte.ts` to `Community 17`, `Community 63`?**
  _High betweenness centrality (0.010) - this node is a cross-community bridge._
- **Why does `plugin()` connect `Community 42` to `OpenAI Proxy and SSE Stream Mapper`, `Codex Input Normalization`, `minimax-client.ts`, `routes-responses.test.ts`, `Streaming Gateway and Handlers`, `routes-health-settings-models-analytics.test.ts`, `Community 20`, `Community 25`?**
  _High betweenness centrality (0.009) - this node is a cross-community bridge._
- **What connects `name`, `type`, `start` to the rest of the system?**
  _656 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Shared Schemas and Helpers` be split into smaller, more focused modules?**
  _Cohesion score 0.054098360655737705 - nodes in this community are weakly interconnected._
- **Should `OpenAI Proxy and SSE Stream Mapper` be split into smaller, more focused modules?**
  _Cohesion score 0.13742071881606766 - nodes in this community are weakly interconnected._
- **Should `VS Code Extension Package Manifest` be split into smaller, more focused modules?**
  _Cohesion score 0.09090909090909091 - nodes in this community are weakly interconnected._