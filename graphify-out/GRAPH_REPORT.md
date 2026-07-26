# Graph Report - ungate-local  (2026-07-26)

## Corpus Check
- 318 files · ~117,284 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2377 nodes · 4275 edges · 191 communities (138 shown, 53 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 45 edges (avg confidence: 0.64)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `5e11d200`
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
- analytics-store.svelte.ts
- tunnel-store.svelte.ts
- ExtensionController
- extension-controller-runtime-sync.test.ts
- shared/package.json
- routes-openai.test.ts
- logs-store.svelte.ts
- routes-health-settings-models-analytics.test.ts
- scripts
- auth/index.ts
- server.ts
- plugin
- better-sqlite3-installer.test.ts
- SettingsStore
- Api
- Formatter
- package.json
- extension-controller.ts
- openai-oauth-service.ts
- AnthropicToOpenai
- compilerOptions
- request-builder.ts
- RuntimeStateStore
- TunnelManager
- Sqlite3CliResolver
- scripts
- orchestration/openai/index.ts
- model-validator.test.ts
- Q: J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 после обновления Codex Beta перестал запускаться: plugin list --json reports openai-bundled marketplace root does not contain a supported manifest.
- compilerOptions
- openai.ts
- devDependencies
- pricing.ts
- compilerOptions
- codex-plugin-isolation.psm1
- devDependencies
- dashboard-set-port.test.ts
- settings-ui-store.svelte.ts
- compilerOptions
- OpenAiClient
- compilerOptions
- wake-ping.ts.recovered.ts
- api/tsconfig.json
- compilerOptions
- OpenAiKeyFix
- devDependencies
- OpenAiKeyFixInternals
- RequestBuilder
- extension.ts
- Ungate (Local) AI Context
- extension/tsconfig.build.json
- scripts/tsconfig.json
- dev-kit/tsconfig.json
- minimax-stream-handler.ts
- post-commit
- shared/tsconfig.json
- global-setup.ts
- PATCHES-MAP.md
- Ungate Extension Icon
- ExtensionControllerInternals
- start-codex-desktop-ungate.ps1
- wake-ping-state.test.ts
- fastify.d.ts
- run.sh
- tunnel/main.ts
- icons.d.ts
- RuntimeStateFileStore
- provider-settings.ts
- keywords
- dependencies
- Ungate Logo
- config-eslint-svelte.mjs
- OpenAI Key Fix
- svelte-check
- SQLite Database
- 11. Critical Contracts and Invariants
- 14. Build / Test / Deploy / Update Rules
- routes-responses.test.ts
- LOCAL-SETUP.md
- 13. Security and Permission Model
- xml-tool-parser.ts
- SOURCE-INFO.md
- 10. End-to-End Operational Flows
- SettingsStore
- local-config/
- Formatter
- routes-health-settings-models-analytics.test.ts
- Cursor Custom Model Bypass
- LogsStore
- 5. Main Modules
- 6. Integration Points
- 8. Configuration and Environment
- 4. Runtime and Bootstrap
- 7. Data Model and Storage
- AGENTS.md
- CLAUDE.md
- post-checkout
- responses-stream-synthesizer.ts
- wake-ping.test.ts
- OpenAIOAuthService
- .response
- minimax-client.ts
- completion-request-telemetry.test.ts
- openai-stream-handler.ts
- model-validator.test.ts
- shared-log-store.test.ts
- reflect-metadata
- tsc-watch
- @types/better-sqlite3
- ../auth/ChatGPTAuthSection.svelte
- vite
- OpenAiKeyFixInternals
- responses.ts
- constants.ts
- @tailwindcss/vite
- @types/d3-scale
- typescript
- api-server-health-check.test.ts
- vite
- routes-auth.test.ts
- eslint-plugin-prettier
- eslint-plugin-simple-import-sort
- eslint-plugin-sort-class-members
- globals
- @html-eslint/eslint-plugin
- eslint
- prettier
- prettier-plugin-svelte
- @skeletonlabs/skeleton-svelte
- @stylistic/eslint-plugin
- svelte-eslint-parser
- typescript
- vite-tsconfig-paths
- vitest
- @vitest/eslint-plugin
- ExtensionStatusBar
- types/settings.ts
- frontend.ts
- api/src/main.ts
- @skeletonlabs/skeleton
- smoke-browser.mjs
- smoke-bundle.mjs
- NssmService
- ModelMappings
- copy-web-assets.mjs
- eslint-config-prettier
- tunnel.ts
- tsup
- @ungate/dev-kit
- control/README.md

## God Nodes (most connected - your core abstractions)
1. `ExtensionController` - 41 edges
2. `getDb()` - 28 edges
3. `Api` - 28 edges
4. `OpenAIChatRequest` - 27 edges
5. `OpenAiKeyFix` - 26 edges
6. `RuntimeStateStore` - 25 edges
7. `logger` - 24 edges
8. `ApiServer` - 24 edges
9. `Dashboard` - 23 edges
10. `ResponsesEventEmitter` - 22 edges

## Surprising Connections (you probably didn't know these)
- `createBridgeServer()` --indirect_call--> `mapping()`  [INFERRED]
  scripts/cliproxy-namespace-bridge.mjs → apps/api/tests/unit/orchestration/openai-model-routing.test.ts
- `ProxyOpenAiResult` --references--> `RequestContext`  [EXTRACTED]
  apps/api/src/proxy/openai-client.ts → apps/api/src/types/proxy.ts
- `plugin()` --indirect_call--> `context()`  [INFERRED]
  apps/api/src/routes/responses.ts → apps/api/tests/unit/orchestration/responses-synthesizer.test.ts
- `StaticTokenProvider` --references--> `AIProviderName`  [EXTRACTED]
  apps/api/src/auth/static-token-provider.ts → apps/api/src/auth/base-provider.ts
- `proxyMiniMaxRequest()` --calls--> `getProvider()`  [EXTRACTED]
  apps/api/src/proxy/minimax-client.ts → apps/api/src/auth/index.ts

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Ungate Visual Branding** — apps_extension_resources_icon_logo, apps_extension_resources_icon_interlocking_triangle_concept, apps_extension_resources_icon_brand_identity [INFERRED 0.85]

## Communities (191 total, 53 thin omitted)

### Community 0 - "Shared Schemas and Helpers"
Cohesion: 0.16
Nodes (17): runtimeApiStateSchema, runtimeApiStatusSchema, runtimeClientEntrySchema, runtimeCommandActionSchema, runtimeCommandSchema, runtimeKeyFixStateSchema, runtimeLogLevelSchema, runtimeStateSchema (+9 more)

### Community 1 - "OpenAI Proxy and SSE Stream Mapper"
Cohesion: 0.10
Nodes (12): OpenAiClient, ResponsesSseProcessor, ResponsesEventRouter, AssistantTextExtractor, StreamDiagnostics, StreamChunkMapper, PendingFunctionCallState, StreamProcessResult (+4 more)

### Community 2 - "VS Code Extension Package Manifest"
Cohesion: 0.09
Nodes (21): activationEvents, bugs, url, categories, contributes, commands, description, displayName (+13 more)

### Community 3 - "Codex Input Normalization"
Cohesion: 0.10
Nodes (13): inputToItems(), CodexInputUtils, ResponsesBodyBuilder, ResponsesInputShape, ResponsesInputText, LEGACY_MODEL_PREFIX_ALIASES, LEGACY_MODEL_REASONING_DEFAULTS, ResponsesModelResolver (+5 more)

### Community 4 - "Web UI Logs and Settings Store"
Cohesion: 0.12
Nodes (16): name, scripts, build, build:bundle, build:postbuild, build:watch, clean, db:generate (+8 more)

### Community 5 - "Backend API Server Dependencies"
Cohesion: 0.10
Nodes (15): CompletionStreamingGateway, getPartialTagSuffix(), MiniMaxStreamEvent, MiniMaxStreamHandler, MiniMaxStreamState, MiniMaxToolCallDelta, parseMiniMaxDelta(), OpenAIStreamHandler (+7 more)

### Community 6 - "Anthropic Claude Authentication Provider"
Cohesion: 0.11
Nodes (12): CursorStateDbReader, execFileAsync, InstallLogger, BIN_DIR, execFileAsync, InstallLogger, Sqlite3CliResolver, execFileAsync (+4 more)

### Community 8 - "Dev Kit Linting & Prettier Tooling"
Cohesion: 0.10
Nodes (21): dependencies, better-sqlite3, date-fns, drizzle-orm, fastify, @fastify/cors, lodash-es, source-map-support (+13 more)

### Community 9 - "Web Analytics and Auth Pages"
Cohesion: 0.15
Nodes (8): ../auth/ClaudeAuthSection.svelte, ../auth/MiniMaxAuthSection.svelte, ./ModelsSection.svelte, ./ProviderPanel.svelte, WakePingStatus, ./settings-store.svelte, ./settings-ui-store.svelte, ./tunnel-store.svelte

### Community 10 - "Web Analytics UI Store"
Cohesion: 0.15
Nodes (12): dependencies, tslib, files, lib, src, tsconfig.base.json, tslib, name (+4 more)

### Community 11 - "VS Code Extension Controller"
Cohesion: 0.23
Nodes (14): completeRestart(), error, extractError(), getSettingsStore(), load(), loading, resetStatus(), restarting (+6 more)

### Community 12 - "Web Charting and Visualization"
Cohesion: 0.20
Nodes (11): closeDatabase(), DrizzleDb, getCurrentDbPath(), getSqlite(), resolveDbPath(), appSettings, modelMappings, providerSettings (+3 more)

### Community 13 - "Streaming Gateway and Handlers"
Cohesion: 0.06
Nodes (46): ResponsesNamespaceToolMapping, anthropicOutputItems(), anthropicStopToStatus(), anthropicToolItem(), ChatFinishReason, chatOutputItems(), finishToStatus(), itemId() (+38 more)

### Community 14 - "Web Settings UI and Authentication APIs"
Cohesion: 0.11
Nodes (3): Formatter, ./analytics-store.svelte, ./logs-store.svelte

### Community 15 - "analytics-store.svelte.ts"
Cohesion: 0.07
Nodes (33): AnalyticsStore, apiTyped, availableModels(), ConfiguredModelEntry, configuredModels, detectProviderBySourceOrModelTyped, error, extractError() (+25 more)

### Community 16 - "tunnel-store.svelte.ts"
Cohesion: 0.11
Nodes (4): Dashboard, SharedLogStore, sharedLogTestBaseDir, sharedLogTestPath

### Community 18 - "extension-controller-runtime-sync.test.ts"
Cohesion: 0.07
Nodes (22): apiServerGetPortMock, apiServerIsStartupInProgressMock, apiServerRestartMock, apiServerStartMock, apiServerStopMock, apiServerSyncLeaderHealthMonitorMock, createContext(), createController() (+14 more)

### Community 19 - "shared/package.json"
Cohesion: 0.07
Nodes (27): dependencies, zod, devDependencies, tsup, typescript, @ungate/dev-kit, exports, ./frontend (+19 more)

### Community 20 - "routes-openai.test.ts"
Cohesion: 0.07
Nodes (25): proxyRequestMock, oauthCompleteLoginMock, oauthLogoutMock, oauthStartLoginMock, oauthStatusMock, openaiCompleteLoginMock, openaiLogoutMock, openaiStartLoginMock (+17 more)

### Community 21 - "logs-store.svelte.ts"
Cohesion: 0.16
Nodes (10): restoreResponsesNamespaceValue(), ResponsesStreamSynthesizer, ResponsesRouteDecision, ResponsesRouteTarget, plugin(), recordError(), sendResponsesJson(), sendResponsesStream() (+2 more)

### Community 22 - "routes-health-settings-models-analytics.test.ts"
Cohesion: 0.23
Nodes (6): Analytics, getDb(), Requests, PERIOD_OFFSETS, plugin(), toPeriod()

### Community 23 - "scripts"
Cohesion: 0.18
Nodes (10): name, private, scripts, build, build:watch, check, lint, lint:fix (+2 more)

### Community 24 - "auth/index.ts"
Cohesion: 0.12
Nodes (12): AIProvider, ClaudeProvider, getProvider(), providers, MiniMaxProvider, OpenAIProvider, StaticTokenProvider, oauthGetAuthStatusMock (+4 more)

### Community 25 - "server.ts"
Cohesion: 0.19
Nodes (17): getConfig(), startServer(), setQuietMode(), configPath, getLastPingAt(), getLastPingError(), isWakePingRunning(), loadWakePingConfig() (+9 more)

### Community 26 - "plugin"
Cohesion: 0.16
Nodes (13): plugin(), ModelValidateSchema, plugin(), ModelMappingUpdateSchema, plugin(), SettingsUpdateSchema, validateSettingsUpdate(), analyticsRecentMock (+5 more)

### Community 27 - "better-sqlite3-installer.test.ts"
Cohesion: 0.09
Nodes (48): ADD_FILE_REMEDIATION, applyPatchTransaction(), applyUpdateChunks(), assertAbsent(), assertNonDevicePath(), assertNoReparsePoints(), assertParentDirectory(), byteLength() (+40 more)

### Community 28 - "SettingsStore"
Cohesion: 0.08
Nodes (17): BetterSqlite3Installer, execFile, InstallCallbacks, NodeResolver, RuntimeInfo, copyFileSyncMock, ExecFileCallback, execFileMock (+9 more)

### Community 29 - "Api"
Cohesion: 0.14
Nodes (5): loadConfiguredModels(), loadStatus(), createAuthStates(), refreshAuthStates(), Api

### Community 30 - "Formatter"
Cohesion: 0.11
Nodes (20): extractUsage(), RequestResult, RequestBuilder, resolveEffort(), VALID_EFFORTS, TOOL_NAME_MAPPING, ToolMapper, VALID_CLAUDE_CODE_TOOLS (+12 more)

### Community 31 - "package.json"
Cohesion: 0.10
Nodes (20): husky, devDependencies, eslint, husky, @ungate/dev-kit, engines, node, pnpm (+12 more)

### Community 32 - "extension-controller.ts"
Cohesion: 0.17
Nodes (4): RuntimeStateFileStore, RuntimeStateNormalizer, CrossProcessLock, { mkdirSyncMock, writeFileSyncMock, rmSyncMock, rmdirSyncMock, existsSyncMock, readFileSyncMock, sleepMock, killMock }

### Community 33 - "openai-oauth-service.ts"
Cohesion: 0.22
Nodes (4): OpenAIOAuthUtils, OpenAIPkceSessionStore, CodexAuthInfo, PkceSession

### Community 34 - "AnthropicToOpenai"
Cohesion: 0.16
Nodes (7): AnthropicToOpenai, PARAMETER_NAME_MAP, ToolTranslator, AnthropicResponse, OpenAIChatResponse, OpenAIStreamChunk, OpenAIStreamChunkToolCall

### Community 35 - "compilerOptions"
Cohesion: 0.10
Nodes (19): compilerOptions, allowJs, emitDecoratorMetadata, esModuleInterop, experimentalDecorators, forceConsistentCasingInFileNames, importHelpers, isolatedModules (+11 more)

### Community 36 - "request-builder.ts"
Cohesion: 0.31
Nodes (3): AIProviderName, OAuthCredentials, ProviderSettings

### Community 38 - "TunnelManager"
Cohesion: 0.20
Nodes (4): getCloudflaredBinPath(), getCloudflaredLegacyBinPath(), TunnelManager, mocks

### Community 40 - "scripts"
Cohesion: 0.07
Nodes (27): @modelcontextprotocol/sdk, dependencies, cloudflared, @modelcontextprotocol/sdk, zod, devDependencies, tsx, @types/node (+19 more)

### Community 41 - "orchestration/openai/index.ts"
Cohesion: 0.16
Nodes (20): assertSupportedRequest(), ChatReasoningEffort, contentPartToChatText(), contentToChatContent(), functionCallToToolCall(), functionOutputToChatMessage(), imagePartToChatPart(), isRecord() (+12 more)

### Community 42 - "model-validator.test.ts"
Cohesion: 0.25
Nodes (6): getAuthStatusMock, makeClaudeCodeRequestMock, openaiAuthStatusMock, providerSettingsGetMock, proxyMiniMaxRequestMock, proxyOpenAIRequestMock

### Community 43 - "Q: J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 после обновления Codex Beta перестал запускаться: plugin list --json reports openai-bundled marketplace root does not contain a supported manifest."
Cohesion: 0.40
Nodes (4): Answer, Outcome, Q: J:\Dev\ungate-local\scripts\start-codex-desktop-ungate.ps1 после обновления Codex Beta перестал запускаться: plugin list --json reports openai-bundled marketplace root does not contain a supported manifest., Source Nodes

### Community 44 - "compilerOptions"
Cohesion: 0.07
Nodes (27): compilerOptions, baseUrl, noEmit, paths, types, verbatimModuleSyntax, exclude, extends (+19 more)

### Community 45 - "openai.ts"
Cohesion: 0.10
Nodes (21): devDependencies, drizzle-kit, esbuild, tsc-alias, tsc-watch, @types/better-sqlite3, @types/lodash-es, @types/node (+13 more)

### Community 46 - "devDependencies"
Cohesion: 0.12
Nodes (17): devDependencies, ovsx, tsup, @types/node, @types/vscode, typescript, @ungate/dev-kit, vitest (+9 more)

### Community 47 - "pricing.ts"
Cohesion: 0.32
Nodes (4): DEFAULT_PRICING, MODEL_PRICING, ModelPricing, Pricing

### Community 48 - "compilerOptions"
Cohesion: 0.11
Nodes (17): compilerOptions, declaration, declarationDir, declarationMap, noEmit, outDir, removeComments, rootDir (+9 more)

### Community 49 - "codex-plugin-isolation.psm1"
Cohesion: 0.21
Nodes (27): Assert-StagedPluginInstallation(), Commit-StagedPluginIsolation(), Copy-IsolatedMarketplace(), Get-BrowserClientVerification(), Get-BundledMarketplacePluginIds(), Get-CodexPluginDirectoryState(), Get-CodexPluginInventory(), Get-ComparablePath() (+19 more)

### Community 50 - "devDependencies"
Cohesion: 0.13
Nodes (15): eslint-import-resolver-typescript, eslint-plugin-import-x, eslint-plugin-svelte, devDependencies, eslint-import-resolver-typescript, eslint-plugin-import-x, eslint-plugin-svelte, prettier-plugin-tailwindcss (+7 more)

### Community 51 - "dashboard-set-port.test.ts"
Cohesion: 0.15
Nodes (4): createWebviewPanelMock, Disposable, fileUriMock, sharedLogs

### Community 52 - "settings-ui-store.svelte.ts"
Cohesion: 0.20
Nodes (8): authStates, getProviderModelsCount(), getSettingsUiStore(), ProviderAuthState, providerLabels, selectedProvider, setSelectedProvider(), SettingsUiStore

### Community 53 - "compilerOptions"
Cohesion: 0.13
Nodes (14): compilerOptions, declaration, declarationDir, declarationMap, noEmit, outDir, removeComments, rootDir (+6 more)

### Community 54 - "OpenAiClient"
Cohesion: 0.10
Nodes (15): Msg, MSGS_SIMPLE, extensionCommands, config, Logger, OpenAiKeyState, RuntimeState, ServiceState (+7 more)

### Community 55 - "compilerOptions"
Cohesion: 0.11
Nodes (18): compilerOptions, importHelpers, lib, module, moduleResolution, noEmit, exclude, extends (+10 more)

### Community 56 - "wake-ping.ts.recovered.ts"
Cohesion: 0.27
Nodes (6): configPath, defaults, loadWakePingConfig(), sendWakePing(), startWakePingScheduler(), WakePingConfig

### Community 57 - "api/tsconfig.json"
Cohesion: 0.12
Nodes (16): compilerOptions, baseUrl, paths, types, exclude, extends, include, dist (+8 more)

### Community 58 - "compilerOptions"
Cohesion: 0.18
Nodes (10): compilerOptions, declaration, noEmit, outDir, rootDir, sourceMap, extends, include (+2 more)

### Community 60 - "devDependencies"
Cohesion: 0.15
Nodes (13): devDependencies, @iconify-json/lucide, @sveltejs/vite-plugin-svelte, tailwindcss, @tsconfig/svelte, @types/node, unplugin-icons, @types/node (+5 more)

### Community 61 - "OpenAiKeyFixInternals"
Cohesion: 0.12
Nodes (22): mapping(), addBareCandidate(), BridgeRequestError, canonicalizeArguments(), cloneFunctionTool(), copyHeaders(), createBridgeServer(), createSseTransform() (+14 more)

### Community 62 - "RequestBuilder"
Cohesion: 0.22
Nodes (9): dependencies, d3-scale, date-fns, layerchart, @ungate/shared, date-fns, layerchart, @ungate/shared (+1 more)

### Community 63 - "extension.ts"
Cohesion: 0.06
Nodes (24): ControlConfig, loadConfig(), parsePort(), trimTrailingSlash(), ControlRuntime, ServiceResult, sleep(), EventHub (+16 more)

### Community 64 - "Ungate (Local) AI Context"
Cohesion: 0.15
Nodes (12): 12. Source of Truth by Concern, 15. Operational Gotchas, 16. What This Project Must NOT Directly Change, 17. Change Impact Map, 18. Pre-Release Checklist, 19. AI Agent Working Rules, 1. Project Identity, 20. Needs Verification / Open Questions (+4 more)

### Community 65 - "extension/tsconfig.build.json"
Cohesion: 0.22
Nodes (8): compilerOptions, noEmit, outDir, rootDir, extends, include, src, ./tsconfig.json

### Community 66 - "scripts/tsconfig.json"
Cohesion: 0.18
Nodes (10): ./**/*.mjs, ./**/*.ts, compilerOptions, types, exclude, extends, include, node (+2 more)

### Community 67 - "dev-kit/tsconfig.json"
Cohesion: 0.14
Nodes (13): compilerOptions, baseUrl, types, exclude, extends, include, ./eslint.config.mjs, lib (+5 more)

### Community 69 - "post-commit"
Cohesion: 0.40
Nodes (4): post-commit script, GRAPHIFY_CHANGED, GRAPHIFY_REBUILD_LOG, PYTHONHASHSEED

### Community 70 - "shared/tsconfig.json"
Cohesion: 0.17
Nodes (11): compilerOptions, baseUrl, exclude, extends, include, eslint.config.mjs, lib, node_modules (+3 more)

### Community 71 - "global-setup.ts"
Cohesion: 0.67
Nodes (3): globalSetup(), removeTestDb(), TEST_DB_PATH

### Community 72 - "PATCHES-MAP.md"
Cohesion: 0.15
Nodes (11): 1. `apps/extension/package.json` (ОБНОВЛЁН), 2. `apps/api/src/wake-ping.ts` (НОВЫЙ ФАЙЛ), 3. `apps/api/src/server.ts` (ОБНОВЛЁН), 4. `apps/extension/src/extension-commands.ts` (ОБНОВЛЁН), 5. `apps/extension/src/dashboard.ts` (ОБНОВЛЁН), Изменения по исходным файлам, Параметры по умолчанию (`bundled/api/wake-ping.json`), Сводка (+3 more)

### Community 73 - "Ungate Extension Icon"
Cohesion: 0.67
Nodes (3): Ungate Brand Identity, Interlocking Triangle Logo Concept, Ungate Extension Icon

### Community 75 - "start-codex-desktop-ungate.ps1"
Cohesion: 0.08
Nodes (32): Assert-UngateCodexConfig(), Ensure-CliProxyBridge(), Ensure-ModelProvidersInConfig(), Get-CliProxyBridgeHealth(), Get-CodexBetaProcesses(), Get-CodexCliExecutable(), Get-CodexHistoryProfileInfo(), Get-ProviderDefinitions() (+24 more)

### Community 85 - "RuntimeStateFileStore"
Cohesion: 0.06
Nodes (30): dependencies, fastify, @fastify/static, @ungate/shared, devDependencies, tsup, @types/node, typescript (+22 more)

### Community 87 - "provider-settings.ts"
Cohesion: 0.14
Nodes (21): addBareCandidate(), cloneNamespaceFunctionTool(), directToolName(), flattenedToolName(), flattenResponsesNamespaceTools(), isRecord(), MutableNamespaceToolMapping, namespaceToolKey() (+13 more)

### Community 88 - "keywords"
Cohesion: 0.20
Nodes (10): keywords, ai, anthropic, chatgpt, claude, cursor, gpt, minimax (+2 more)

### Community 89 - "dependencies"
Cohesion: 0.22
Nodes (9): dependencies, cloudflared, tar, @ungate/shared, zod, cloudflared, @ungate/shared, zod (+1 more)

### Community 94 - "config-eslint-svelte.mjs"
Cohesion: 0.08
Nodes (23): config, defaultIgnores, languageOptions, prettierOptions, prettierPluginSveltePath, prettierPluginTailwindcssPath, require, resolverSettings (+15 more)

### Community 104 - "11. Critical Contracts and Invariants"
Cohesion: 0.18
Nodes (11): 11. Critical Contracts and Invariants, A. Proxy API Key Auth, B. Port Detection Contract, C. Tunnel URL Contract (LOCAL FORK — frpc, не cloudflared), D. Database Schema Invariants, E. Migration Application Contract, F. Wake Ping Config Path Contract, G. Runtime State File Contract (+3 more)

### Community 105 - "14. Build / Test / Deploy / Update Rules"
Cohesion: 0.18
Nodes (11): 14. Build / Test / Deploy / Update Rules, Build commands, Build order (dependency graph), CI/CD, Deploy/publish, Drift: docs vs artifacts, Generated artifacts (deployed в vsix), Husky / git hooks (+3 more)

### Community 107 - "routes-responses.test.ts"
Cohesion: 0.13
Nodes (13): HeadersExtractor, CompletionRequestTelemetry, CompletionModelRouting, ClaudeChatHandler, MiniMaxChatHandler, OpenAiMappedChatHandler, apiKeyAuth(), proxyRequest() (+5 more)

### Community 108 - "LOCAL-SETUP.md"
Cohesion: 0.20
Nodes (8): Преимущества `J:\Dev\ungate-local\` перед распакованной установкой, Размер и верификация, Что внутри `local-config/`, Что делать, когда будете готовы к полному переходу, Что здесь есть, Что НЕ здесь (и где оно), Что СЕЙЧАС не нужно делать, Что это

### Community 109 - "13. Security and Permission Model"
Cohesion: 0.22
Nodes (9): 13. Security and Permission Model, Auth model, Command execution risks, Filesystem write risks, Input validation, Known gaps, Network/SSRF risks, Roles/permissions (+1 more)

### Community 111 - "SOURCE-INFO.md"
Cohesion: 0.25
Nodes (6): Версия, Источник, Объём, Сравнение с распакованной установкой (baseline), Целостность, Что НЕ копировалось

### Community 112 - "10. End-to-End Operational Flows"
Cohesion: 0.25
Nodes (8): 10. End-to-End Operational Flows, A. Chat request flow (основной), B. OAuth login flow (Claude), C. OAuth login flow (OpenAI/ChatGPT), D. Wake Ping flow (local addition), E. OpenAI Key Fix flow, F. Build & install flow (local), G. Multi-window leader election

### Community 114 - "local-config/"
Cohesion: 0.29
Nodes (6): local-config/, Если хотите **обновить** снэпшот (например, добавили нового провайдера), Как восстановить (если что-то сломалось), ⚠️ Секреты, Состав, Что внутри `data.db.snapshot`

### Community 115 - "Formatter"
Cohesion: 0.33
Nodes (6): scripts, build, lint, lint:fix, publish, test

### Community 116 - "routes-health-settings-models-analytics.test.ts"
Cohesion: 0.19
Nodes (12): AnthropicModelOverride, convertContent(), normalizeAssistantContentBlock(), normalizeAssistantContentBlocks(), normalizeModelName(), openaiToAnthropic(), detectProvider(), proxyOpenAIRequest() (+4 more)

### Community 119 - "5. Main Modules"
Cohesion: 0.33
Nodes (6): 5. Main Modules, API (`apps/api/`), Dev-kit (`packages/dev-kit/`), Extension (`apps/extension/`), Shared (`packages/shared/`), Web (`apps/web/`)

### Community 120 - "6. Integration Points"
Cohesion: 0.33
Nodes (6): 6. Integration Points, CLI Commands (extension), External API clients, HTTP Routes (API), OAuth callback server, Webview messages (extension ↔ webview)

### Community 121 - "8. Configuration and Environment"
Cohesion: 0.33
Nodes (6): 8. Configuration and Environment, Config files (runtime), Defaults опасные, Environment variables, Hardcoded config (не env), Значения, которые нельзя менять без координации

### Community 122 - "4. Runtime and Bootstrap"
Cohesion: 0.40
Nodes (5): 4. Runtime and Bootstrap, API bootstrap, Config loading, Extension bootstrap, Shutdown

### Community 123 - "7. Data Model and Storage"
Cohesion: 0.40
Nodes (5): 7. Data Model and Storage, Cache / derived state, Database: `~/.ungate/data.db` (SQLite, WAL mode), Filesystem state, Migrations

### Community 124 - "AGENTS.md"
Cohesion: 0.50
Nodes (3): CLIProxy namespace bridge, graphify, ungate-api NSSM service

### Community 126 - "post-checkout"
Cohesion: 0.50
Nodes (3): post-checkout script, GRAPHIFY_REBUILD_LOG, PYTHONHASHSEED

### Community 127 - "responses-stream-synthesizer.ts"
Cohesion: 0.40
Nodes (5): exports, ./eslint, ./eslint-svelte, ./tsconfig-base, ./vitest

### Community 133 - "wake-ping.test.ts"
Cohesion: 0.11
Nodes (9): createRuntimeState(), isApiStartSuppressedMock, resetApiForRestartMock, {
	runtimeReadMock,
	runtimeHasLiveClientsMock,
	runtimeMutateMock,
	sleepMock,
	nssmRestartMock,
	settingsInitMock,
	settingsReadPortMock
}, suppressApiAutoStartMock, createRuntimeState(), TestHelper, createLeaderKeyFix() (+1 more)

### Community 134 - "OpenAIOAuthService"
Cohesion: 0.20
Nodes (3): OpenAICallbackServer, OpenAIOAuthService, plugin()

### Community 135 - ".response"
Cohesion: 0.50
Nodes (4): author, email, name, url

### Community 136 - "minimax-client.ts"
Cohesion: 0.24
Nodes (12): buildMiniMaxRequestBody(), getMiniMaxReasoning(), jsonContentType(), miniMaxErrorBody(), MiniMaxResponseBody, MiniMaxResponseNormalization, normalizeMiniMaxContent(), normalizeMiniMaxMessages() (+4 more)

### Community 138 - "openai-stream-handler.ts"
Cohesion: 0.32
Nodes (5): OpenAIOAuthClient, Config, ENV_CHATGPT_INSTRUCTIONS, ProxyOpenAiResult, ProxyConfig

### Community 139 - "model-validator.test.ts"
Cohesion: 0.16
Nodes (3): ApiServer, ApiServerCallbacks, HEALTH_CHECK_URL()

### Community 140 - "shared-log-store.test.ts"
Cohesion: 0.67
Nodes (3): repository, type, url

### Community 144 - "@types/better-sqlite3"
Cohesion: 0.15
Nodes (8): OAuth, PkceSession, TokenExchangeResponse, makeClaudeCodeRequest(), TokenInfo, TokenRefreshResponse, AuthStatus, LoginStart

### Community 145 - "../auth/ChatGPTAuthSection.svelte"
Cohesion: 0.25
Nodes (9): ../auth/ChatGPTAuthSection.svelte, authUrl, cancelled, handleCancel(), handleLogin(), handleLogout(), handleRetry(), lastAction (+1 more)

### Community 146 - "vite"
Cohesion: 0.11
Nodes (18): compilerOptions, baseUrl, noEmit, paths, types, exclude, extends, include (+10 more)

### Community 147 - "OpenAiKeyFixInternals"
Cohesion: 0.06
Nodes (30): apiLogs, clearApi(), clearTunnel(), copyApi(), copyTunnel(), error, formatLogs(), getLogsStore() (+22 more)

### Community 148 - "responses.ts"
Cohesion: 0.21
Nodes (4): CompletionErrorMapper, MiniMaxErrorContext, openaiChatErrorMessages, errorMessageFor()

### Community 155 - "api-server-health-check.test.ts"
Cohesion: 0.32
Nodes (6): hasMiniMaxExecCommand(), hasMiniMaxPatchTool(), MINIMAX_ADD_FILE_INSTRUCTION, MINIMAX_FILE_EDITING_INSTRUCTION, MINIMAX_UPDATE_FILE_INSTRUCTION, withMiniMaxFileEditingInstruction()

### Community 173 - "ExtensionStatusBar"
Cohesion: 0.16
Nodes (13): DashboardBootstrap, DashboardEvent, DashboardLogSource, DashboardLogsSnapshot, DashboardOperation, DashboardOperationState, DashboardServiceAction, DashboardServicePhase (+5 more)

### Community 174 - "types/settings.ts"
Cohesion: 0.21
Nodes (10): isModelMappingProvider(), isReasoningBudgetTier(), PROVIDER_LABELS, AppSettings, MODEL_MAPPING_PROVIDERS, ModelMappingConfig, ModelMappingProvider, ModelValidationResult (+2 more)

### Community 177 - "frontend.ts"
Cohesion: 0.25
Nodes (5): MINIMAX_BASE_URLS, ExtensionToWebview, WebviewToExtension, rejectAbort(), sleep()

### Community 178 - "api/src/main.ts"
Cohesion: 0.24
Nodes (8): detectProviderByModel(), detectProviderBySource(), detectProviderBySourceOrModel(), AnalyticsSummary, Period, RequestRecord, RequestSource, TokenSeriesPoint

### Community 183 - "smoke-browser.mjs"
Cohesion: 0.33
Nodes (3): child, controlRoot, output

### Community 184 - "smoke-bundle.mjs"
Cohesion: 0.40
Nodes (3): child, controlRoot, output

### Community 187 - "copy-web-assets.mjs"
Cohesion: 0.50
Nodes (3): controlRoot, source, target

## Knowledge Gaps
- **725 isolated node(s):** `name`, `type`, `start`, `build`, `build:watch` (+720 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **53 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `DashboardClient` connect `OpenAiKeyFixInternals` to `Web Analytics and Auth Pages`, `VS Code Extension Controller`?**
  _High betweenness centrality (0.056) - this node is a cross-community bridge._
- **Why does `plugin()` connect `logs-store.svelte.ts` to `OpenAI Proxy and SSE Stream Mapper`, `orchestration/openai/index.ts`, `routes-responses.test.ts`, `Streaming Gateway and Handlers`, `OpenAiKeyFixInternals`, `responses.ts`, `routes-openai.test.ts`, `server.ts`?**
  _High betweenness centrality (0.034) - this node is a cross-community bridge._
- **Why does `buildServer()` connect `extension.ts` to `RuntimeStateStore`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **What connects `name`, `type`, `start` to the rest of the system?**
  _725 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `OpenAI Proxy and SSE Stream Mapper` be split into smaller, more focused modules?**
  _Cohesion score 0.10324675324675325 - nodes in this community are weakly interconnected._
- **Should `VS Code Extension Package Manifest` be split into smaller, more focused modules?**
  _Cohesion score 0.09090909090909091 - nodes in this community are weakly interconnected._
- **Should `Codex Input Normalization` be split into smaller, more focused modules?**
  _Cohesion score 0.10359408033826638 - nodes in this community are weakly interconnected._