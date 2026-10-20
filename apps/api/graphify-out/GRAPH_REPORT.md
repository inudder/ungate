# Graph Report - api  (2026-10-15)

## Corpus Check
- 177 files · ~61,675 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1032 nodes · 2748 edges · 43 communities (37 shown, 6 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 14 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `79ae3dbf`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- types/openai.ts
- logger.ts
- responses-stream-synthesizer.ts
- responses-non-stream-synthesizer.ts
- responses-request-normalizer.ts
- routes-reasoning-effort.test.ts
- RequestContext
- openai-oauth-service.ts
- server.ts
- provider-model-catalog.ts
- anthropic-client.ts
- routes-health-settings-models-analytics.test.ts
- claude-token-manager.ts
- auth-providers-and-index.test.ts
- database/index.ts
- package.json
- .get
- vitest
- routes/anthropic.ts
- claude-chat-handler.ts
- model-validator.ts
- ext_packages_shared_lib_index_js
- devDependencies
- minimax-client.ts
- OAuth
- getDb
- scripts
- claude-proxy.test.ts
- responses.ts
- orchestration/openai/index.ts
- dependencies
- routes/openai.ts
- CompletionModelRouting
- responses-synthesizer.test.ts
- compilerOptions
- tsconfig.json
- pricing.ts
- ModelMappings
- xml-tool-parser.ts
- vite-tsconfig-paths
- fastify.d.ts
- global-setup.ts

## God Nodes (most connected - your core abstractions)
1. `vitest` - 57 edges
2. `OpenAIChatRequest` - 33 edges
3. `getDb()` - 31 edges
4. `logger` - 28 edges
5. `ProviderSettings` - 25 edges
6. `ResponsesEventEmitter` - 25 edges
7. `StreamState` - 23 edges
8. `OAuth` - 22 edges
9. `ThinkingStats` - 22 edges
10. `RequestContext` - 22 edges

## Surprising Connections (you probably didn't know these)
- `ChatCompletionJson` --references--> `ChatCompletionUsage`  [EXTRACTED]
  tests/unit/proxy/openai-client.test.ts → src/types/openai.ts
- `resetIntegrationDatabase()` --calls--> `getSqlite()`  [EXTRACTED]
  tests/integration/vitest.setup.ts → src/database/index.ts
- `send()` --calls--> `fetchClaude()`  [EXTRACTED]
  src/proxy/anthropic-client.ts → src/proxy/claude-transport.ts
- `proxyOpenAIRequest()` --calls--> `openaiToAnthropic()`  [EXTRACTED]
  src/proxy/proxy-client.ts → src/adapter/openai-to-anthropic.ts
- `performRefresh()` --calls--> `fetchClaude()`  [EXTRACTED]
  src/auth/claude-token-manager.ts → src/proxy/claude-transport.ts

## Import Cycles
- None detected.

## Communities (43 total, 6 thin omitted)

### Community 0 - "types/openai.ts"
Cohesion: 0.06
Nodes (39): AnthropicModelOverride, convertContent(), normalizeAssistantContentBlock(), normalizeAssistantContentBlocks(), normalizeModelName(), openaiToAnthropic(), supportsAssistantPrefill(), hasMiniMaxExecCommand() (+31 more)

### Community 1 - "logger.ts"
Cohesion: 0.07
Nodes (24): ENV_CHATGPT_INSTRUCTIONS, OpenAiClient, ResponsesSseProcessor, ResponsesEventRouter, AssistantTextExtractor, asRecord(), StreamDiagnostics, tokenCount() (+16 more)

### Community 2 - "responses-stream-synthesizer.ts"
Cohesion: 0.07
Nodes (34): extractMiniMaxInlineToolCalls(), inlineToolCallPendingSuffix(), MiniMaxInlineExtraction, MiniMaxInlineToolCall, parseInvokeBlock(), parseJsonBlock(), parseToolCallBlock(), stripMarkers() (+26 more)

### Community 3 - "responses-non-stream-synthesizer.ts"
Cohesion: 0.06
Nodes (33): AnthropicToOpenai, anthropicOutputItems(), anthropicStopToStatus(), anthropicToolItem(), ChatFinishReason, chatOutputItems(), finishToStatus(), itemId() (+25 more)

### Community 4 - "responses-request-normalizer.ts"
Cohesion: 0.08
Nodes (38): addBareCandidate(), cloneNamespaceFunctionTool(), directToolName(), flattenedToolName(), flattenResponsesNamespaceTools(), isRecord(), MutableNamespaceToolMapping, namespaceToolKey() (+30 more)

### Community 5 - "routes-reasoning-effort.test.ts"
Cohesion: 0.05
Nodes (36): proxyRequestMock, telemetryRecordMock, oauthCompleteLoginMock, oauthLogoutMock, oauthRefreshMock, oauthStartLoginMock, oauthStatusMock, openaiCompleteLoginMock (+28 more)

### Community 6 - "RequestContext"
Cohesion: 0.07
Nodes (23): ProxyOpenAiResult, getPartialTagSuffix(), MiniMaxStreamEvent, MiniMaxStreamHandler, MiniMaxStreamState, MiniMaxToolCallDelta, parseMiniMaxDelta(), OpenAIStreamHandler (+15 more)

### Community 7 - "openai-oauth-service.ts"
Cohesion: 0.12
Nodes (8): OpenAICallbackServer, OpenAIOAuthClient, OpenAIOAuthUtils, OpenAIPkceSessionStore, CodexAuthInfo, PkceSession, Config, getConfig()

### Community 8 - "server.ts"
Cohesion: 0.11
Nodes (21): closeClaudeTransport(), plugin(), startServer(), setQuietMode(), clearLastPingError(), configPath, getLastPingAt(), getLastPingError() (+13 more)

### Community 9 - "provider-model-catalog.ts"
Cohesion: 0.13
Nodes (22): FALLBACK_CODEX_CLIENT_VERSION, refresh(), resetCodexClientVersionCache(), resolveCodexClientVersion(), claudeHeaders(), CONTEXT_WINDOW_KEYS, fetchCatalogJson(), fetchClaudeModels() (+14 more)

### Community 10 - "anthropic-client.ts"
Cohesion: 0.14
Nodes (13): anthropicThinkingEffort(), chatThinkingEffort(), logThinkingSummary(), ThinkingStats, extractUsage(), RequestResult, TOOL_NAME_MAPPING, ToolMapper (+5 more)

### Community 11 - "routes-health-settings-models-analytics.test.ts"
Cohesion: 0.10
Nodes (18): zod, Settings, ModelValidateSchema, plugin(), ModelMappingUpdateSchema, plugin(), SettingsUpdateSchema, TokenLimitSchema (+10 more)

### Community 12 - "claude-token-manager.ts"
Cohesion: 0.13
Nodes (12): ClaudeAuthError, ClaudeTokenManager, Credentials, diagnostic(), flights, performRefresh(), recordFailure(), RETRY_DELAYS (+4 more)

### Community 13 - "auth-providers-and-index.test.ts"
Cohesion: 0.16
Nodes (13): AIProvider, AIProviderName, ClaudeProvider, getProvider(), providers, MiniMaxProvider, OpenAIProvider, StaticTokenProvider (+5 more)

### Community 14 - "database/index.ts"
Cohesion: 0.17
Nodes (10): drizzle-orm, closeDatabase(), DrizzleDb, getCurrentDbPath(), getSqlite(), resolveDbPath(), appSettings, modelMappings (+2 more)

### Community 15 - "package.json"
Cohesion: 0.09
Nodes (20): name, type, better-sqlite3, drizzle-kit, esbuild, @fastify/cors, lodash-es, source-map-support (+12 more)

### Community 16 - ".get"
Cohesion: 0.14
Nodes (7): OAuthCredentials, validatedTokenResponse(), OpenAIOAuthService, plugin(), seed(), seed(), configureProvider()

### Community 17 - "vitest"
Cohesion: 0.16
Nodes (8): vitest, PkceSession, TokenExchangeResponse, ProviderSettings, TokenRefreshResponse, model, request, requestRecordMock

### Community 18 - "routes/anthropic.ts"
Cohesion: 0.18
Nodes (8): HeadersExtractor, ClaudeChatHandler, apiKeyAuth(), instrumentAnthropicStream(), plugin(), plugin(), recordError(), sendResponsesJson()

### Community 19 - "claude-chat-handler.ts"
Cohesion: 0.24
Nodes (3): fastify, CompletionRequestTelemetry, CompletionStreamingGateway

### Community 20 - "model-validator.ts"
Cohesion: 0.17
Nodes (11): makeClaudeCodeRequest(), send(), ModelValidator, probeBody(), readErrorMessage(), makeClaudeCodeRequestMock, model(), openaiAuthStatusMock (+3 more)

### Community 21 - "ext_packages_shared_lib_index_js"
Cohesion: 0.20
Nodes (5): CACHE_WRITE_PROVIDERS, Requests, requests, TelemetryRecord, record()

### Community 22 - "devDependencies"
Cohesion: 0.13
Nodes (15): devDependencies, drizzle-kit, esbuild, tsc-alias, tsc-watch, tsup, @types/better-sqlite3, @types/lodash-es (+7 more)

### Community 23 - "minimax-client.ts"
Cohesion: 0.20
Nodes (12): buildMiniMaxRequestBody(), getMiniMaxReasoning(), jsonContentType(), miniMaxErrorBody(), MiniMaxResponseBody, MiniMaxResponseNormalization, normalizeMiniMaxContent(), normalizeMiniMaxMessages() (+4 more)

### Community 25 - "getDb"
Cohesion: 0.26
Nodes (6): date-fns, Analytics, getDb(), PERIOD_OFFSETS, plugin(), toPeriod()

### Community 26 - "scripts"
Cohesion: 0.14
Nodes (14): scripts, build, build:bundle, build:postbuild, build:watch, clean, db:generate, db:migrate (+6 more)

### Community 27 - "claude-proxy.test.ts"
Cohesion: 0.21
Nodes (10): undici, ClaudeTransportError, dispatcher(), fetchClaude(), hasPreSendError(), PRE_SEND_ERRORS, listen(), proxy() (+2 more)

### Community 28 - "responses.ts"
Cohesion: 0.29
Nodes (7): proxyRequest(), proxyMiniMaxRequest(), detectProvider(), proxyOpenAIRequest(), proxyRequest(), callUpstream(), ProxyResult

### Community 29 - "orchestration/openai/index.ts"
Cohesion: 0.24
Nodes (4): CompletionErrorMapper, MiniMaxErrorContext, openaiChatErrorMessages, errorMessageFor()

### Community 30 - "dependencies"
Cohesion: 0.17
Nodes (12): dependencies, better-sqlite3, date-fns, drizzle-orm, fastify, @fastify/cors, lodash-es, source-map-support (+4 more)

### Community 31 - "routes/openai.ts"
Cohesion: 0.21
Nodes (4): MiniMaxChatHandler, OpenAiMappedChatHandler, OPENAI_MULTIMODAL_BODY_LIMIT_BYTES, plugin()

### Community 32 - "CompletionModelRouting"
Cohesion: 0.21
Nodes (3): CompletionModelRouting, ResponsesRouteDecision, ResponsesRouteTarget

### Community 33 - "responses-synthesizer.test.ts"
Cohesion: 0.18
Nodes (3): ResponsesStreamSynthesizer, sendResponsesStream(), requestsRecordMock

### Community 34 - "compilerOptions"
Cohesion: 0.20
Nodes (9): ./tsconfig.json, compilerOptions, declaration, noEmit, outDir, rootDir, sourceMap, extends (+1 more)

### Community 35 - "tsconfig.json"
Cohesion: 0.20
Nodes (9): @ungate/dev-kit/tsconfig-base, compilerOptions, baseUrl, paths, types, exclude, extends, include (+1 more)

### Community 36 - "pricing.ts"
Cohesion: 0.28
Nodes (4): DEFAULT_PRICING, MODEL_PRICING, ModelPricing, Pricing

### Community 41 - "global-setup.ts"
Cohesion: 0.67
Nodes (3): globalSetup(), removeTestDb(), TEST_DB_PATH

## Knowledge Gaps
- **15 isolated node(s):** `@ungate/shared`, `source-map-support`, `tslib`, `@types/better-sqlite3`, `@types/lodash-es` (+10 more)
  These have ≤1 connection - possible missing edges. (Counts symbols only; 293 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `vitest` connect `vitest` to `types/openai.ts`, `logger.ts`, `responses-non-stream-synthesizer.ts`, `responses-request-normalizer.ts`, `routes-reasoning-effort.test.ts`, `RequestContext`, `openai-oauth-service.ts`, `server.ts`, `provider-model-catalog.ts`, `anthropic-client.ts`, `routes-health-settings-models-analytics.test.ts`, `auth-providers-and-index.test.ts`, `database/index.ts`, `package.json`, `routes/anthropic.ts`, `claude-chat-handler.ts`, `model-validator.ts`, `ext_packages_shared_lib_index_js`, `minimax-client.ts`, `claude-proxy.test.ts`, `orchestration/openai/index.ts`, `CompletionModelRouting`, `responses-synthesizer.test.ts`, `pricing.ts`, `ModelMappings`, `xml-tool-parser.ts`, `vite-tsconfig-paths`?**
  _High betweenness centrality (0.197) - this node is a cross-community bridge._
- **What connects `@ungate/shared`, `source-map-support`, `tslib` to the rest of the system?**
  _15 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `types/openai.ts` be split into smaller, more focused modules?**
  _Cohesion score 0.05745658835546476 - nodes in this community are weakly interconnected._
- **Why does `logger` connect `logger.ts` to `types/openai.ts`, `responses-stream-synthesizer.ts`, `responses-non-stream-synthesizer.ts`, `routes-reasoning-effort.test.ts`, `RequestContext`, `openai-oauth-service.ts`, `anthropic-client.ts`, `claude-token-manager.ts`, `vitest`, `routes/anthropic.ts`, `claude-chat-handler.ts`, `ext_packages_shared_lib_index_js`, `minimax-client.ts`, `responses.ts`, `routes/openai.ts`?**
  _High betweenness centrality (0.050) - this node is a cross-community bridge._
- **Should `logger.ts` be split into smaller, more focused modules?**
  _Cohesion score 0.06744956338452274 - nodes in this community are weakly interconnected._
- **Why does `OpenAIChatRequest` connect `types/openai.ts` to `CompletionModelRouting`, `logger.ts`, `responses-request-normalizer.ts`, `anthropic-client.ts`, `routes/anthropic.ts`, `claude-chat-handler.ts`, `model-validator.ts`, `minimax-client.ts`, `responses.ts`, `routes/openai.ts`?**
  _High betweenness centrality (0.044) - this node is a cross-community bridge._
- **Should `responses-stream-synthesizer.ts` be split into smaller, more focused modules?**
  _Cohesion score 0.07486338797814207 - nodes in this community are weakly interconnected._