# ТЗ: usage (токены) в ответах Chat Completions для провайдера OpenAI в Ungate API

Дата исследования: 14 октября 2026. Репозиторий: J:/Dev/ungate-local. Исследован HEAD 46d849585811965d69101d6eb6e66318c1e544a0, рабочее дерево было чистым. Перед реализацией перечитать актуальные `AGENTS.md` и исходники; сохранить появившиеся пользовательские изменения.

## 1. Задача для новой сессии

Нестримовый `POST /v1/chat/completions` для **любой модели с провайдером `openai`** (`ModelMappingConfig.provider === 'openai'`) возвращает `usage` с нулями (`prompt_tokens: 0, completion_tokens: 0, total_tokens: 0`), хотя апстрим (ChatGPT Codex `/responses`) присылает настоящие числа. Нужно отдавать реальный `usage`, добавить в него детализацию (кэш и reasoning-токены, если апстрим их прислал) и записывать те же числа в телеметрию.

Исправление делается в общем коде провайдера `openai`, а не под конкретную модель: `gpt-6.1-sol` — единственная OpenAI-модель, которая сейчас включена в шлюзе, и используется в приёмке как пример. Любые будущие модели с `provider: 'openai'` должны получить usage тем же кодом без правок.

Провайдеры `claude` и `minimax` **не трогать**: они уже отдают usage (проверено, см. п. 3.2).

## 2. Зачем

Лендинг-генератор (`J:\Dev\gambling-landing-generator`) выбирает модели и провайдеров для переводов и хочет сравнивать их по скорости. Провайдеры скорость не отдают: они отдают **число токенов**, а скорость (токены в секунду) генератор считает сам: `completion_tokens / время HTTP-запроса` по каждому успешному вызову (поле `output_tokens_per_second` в журнале вызова, `tokens_per_second` в сводке задачи, колонка `tok/s` в Job Detail). Для `gpt-6.1-sol` в журнале все вызовы имеют `usage` с нулями, скорость посчитать нельзя, и в интерфейсе стоит «tok/s n/a · provider reports no usage».

Вторая жертва — dashboard Ungate: запрос OpenAI-модели записывается в таблицу `requests` с `inputTokens = outputTokens = 0`, поэтому Analytics и `estimatedCost` по этим моделям нулевые.

## 3. Что установлено исследованием

### 3.1. Маршрут запроса и место ошибки

| Звено | Где | Что делает |
| --- | --- | --- |
| Роут | `apps/api/src/routes/openai.ts` | `POST /v1/chat/completions` → `ModelMappings.resolveForChatCompletion`; порядок ветвей: MiniMax → `OpenAiMappedChatHandler` (если `provider === 'openai'`) → `ClaudeChatHandler` |
| Обработчик | `apps/api/src/orchestration/openai/provider-handlers/openai-mapped-chat-handler.ts` | `proxyOpenAIRequest(upstreamBody, 'openai')`; для `stream: false` читает `response.json()` и отправляет как есть; в телеметрию пишет `context.inputTokens ?? 0` и `context.outputTokens ?? 0` |
| Клиент | `apps/api/src/proxy/openai-client.ts` → `OpenAiClient.proxy` | всегда запрашивает `${config.openai.codexUrl}/responses` с `accept: text/event-stream`, то есть апстрим всегда отвечает SSE |
| Нестримовая ветка | `openai-client.ts`, `bufferedResponse` (строка ~206) | читает SSE через `ResponsesSseProcessor`, собирает только `delta.content` и **жёстко** возвращает `usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }` (строка ~258) |
| Контекст | `openai-client.ts`, `openAiContext` (строка ~271) | создаёт `RequestContext` с `inputTokens: 0, outputTokens: 0`, поэтому телеметрия и dashboard тоже получают нули |
| Стримовая ветка | `responses-event-router.ts`, `handleCompletedEvent` (строка ~294) + `stream-diagnostics.ts`, `mapUsage` (строка ~26) | на событии `response.completed` кладёт `usage` в финальный чанк, но только три поля: `prompt_tokens`, `completion_tokens`, `total_tokens` |

То есть апстрим usage присылает (в событии `response.completed`), а нестримовая ветка его отбрасывает. Это не данные апстрима и не ограничение модели.

### 3.2. Живая проверка 14 октября 2026

Запросы `POST http://127.0.0.1:47821/v1/chat/completions`, один короткий промпт («Reply with the single word OK.», `max_tokens: 64`):

| Модель (провайдер в шлюзе) | Режим | usage в ответе |
| --- | --- | --- |
| `gpt-6.1-sol` (openai) | не стрим | `{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}` — **нули** |
| `gpt-6.1-sol` (openai) | стрим (`stream_options` не нужен) | в финальном чанке `{prompt_tokens: 37, completion_tokens: 5, total_tokens: 42}` — **числа есть** |
| `claude-haiku-5-5` (claude) | не стрим | `{prompt_tokens: 42, completion_tokens: 4, total_tokens: 46, prompt_cache_hit_tokens: 0, prompt_cache_miss_tokens: 0}` — корректно |
| `miniMax-M3` (minimax) | не стрим | `{prompt_tokens: 183, completion_tokens: 28, total_tokens: 211, completion_tokens_details: {reasoning_tokens: 24}, prompt_tokens_details: {cached_tokens: 128}, total_characters: 0}` — корректно |

Выводы:

- Провайдер `claude` отдаёт usage (подтверждено и пользователем, и замером: токены в генераторе считаются, у линии `claude-sonnet-5-5` скорость была 132–135 tok/s).
- Провайдер `minimax` тоже отдаёт usage; пользователь его не проверял, замер выше проверил. Формат MiniMax (`prompt_tokens_details.cached_tokens`, `completion_tokens_details.reasoning_tokens`) — образец того, как нужно отдавать детализацию для OpenAI.
- Провайдер `openai` не отдаёт usage **только в нестримовом режиме**; в стриме числа приходят, значит апстрим их присылает.

### 3.3. Модели шлюза на момент исследования

`GET /v1/models`: `miniMax-M3` (minimax), `claude-haiku-5-5`, `claude-sonnet-5-5` (claude), `gpt-6.1-sol` (openai). Модели хранятся как `AppSettings.models` / `ModelMappingConfig` (провайдеры `claude` / `minimax` / `openai`).

### 3.4. Как usage потребляет генератор

`backend/services/llm_service.py::_normalize_openai_usage` в генераторе читает стандартные поля Chat Completions: `prompt_tokens`, `completion_tokens`, `total_tokens`, кэш из `prompt_tokens_details.cached_tokens` (или `input_tokens_details.cached_tokens`), сырые числовые `completion_tokens_details` (для reasoning). Ответ без `usage` генератор трактует как «usage неизвестен» (счётчик `unknown_usage`), а нули как «известные нулевые токены». Поэтому нули хуже, чем отсутствие поля.

`completion_tokens` в стандартной семантике включает reasoning-токены: для скорости генерации это правильная величина (модель реально их выдаёт).

## 4. Требования

### 4.1. Формат usage

Один и тот же формат для нестримового ответа и финального стримового чанка.

| Апстрим (Responses `response.completed`.`response.usage`) | Ответ шлюза (Chat Completions) |
| --- | --- |
| `input_tokens` (или `prompt_tokens`) | `prompt_tokens` |
| `output_tokens` (или `completion_tokens`) | `completion_tokens` (включает reasoning-токены, как у апстрима) |
| `total_tokens`; если нет или не больше нуля — `input + output` | `total_tokens` |
| `input_tokens_details.cached_tokens` | `prompt_tokens_details.cached_tokens` |
| `output_tokens_details.reasoning_tokens` | `completion_tokens_details.reasoning_tokens` |

Правила:

1. Числами считаются только конечные неотрицательные целые; всё остальное пропускается.
2. Вложенные объекты `*_details` добавляются **только если** соответствующее поле пришло от апстрима. Не выдумывать нули для отсутствующих полей.
3. Ключи, которые уже отдаются сейчас (`prompt_tokens`, `completion_tokens`, `total_tokens`), остаются на тех же местах: изменение обратно совместимо (только добавление полей).
4. Если апстрим usage не прислал вовсе (например, поток закончился без `response.completed`), нестримовый ответ **не содержит поле `usage`**, а не нулевой объект. Перед удалением поля найти всех потребителей `usage` из ответов `/v1/chat/completions` в репозитории (`apps/*`, `scripts/*`, `tests/*`); если кто-то обязательно требует поле, зафиксировать решение в `docs/model-routing.md` и в тесте.

### 4.2. Нестримовый ответ

- `StreamState` (`apps/api/src/proxy/responses-stream-mapper/stream-state.ts`) получает необязательное поле `usage` с типизированным результатом (тип положить рядом с `OpenAIChatRequest` в `apps/api/src/types/openai.ts`).
- `StreamDiagnostics.mapUsage` возвращает типизированный объект (сейчас `Record<string, number>`, вложенные объекты в него не помещаются) по таблице 4.1.
- `ResponsesEventRouter.handleCompletedEvent` записывает результат `mapUsage` в `state.usage` и по-прежнему кладёт его в финальный чанк.
- `OpenAiClient.bufferedResponse` берёт usage из `state.usage` после чтения потока и убирает жёсткие нули; при отсутствии usage поле не пишется.
- `OpenAiClient.successResult` строит `RequestContext` с `inputTokens`, `outputTokens` и `cacheReadTokens` из этого usage (сейчас `openAiContext` всегда ставит 0). Для нестримовых запросов контекст создаётся после чтения всего ответа, поэтому числа к этому моменту известны.

### 4.3. Стримовый ответ

- Тот же `mapUsage` и те же дополнительные поля в финальном чанке (`prompt_tokens_details`, `completion_tokens_details`); существующие поля не менять.
- Поведение потока (порядок чанков, `[DONE]`, tool calls) не менять.

### 4.4. Телеметрия и dashboard

- Нестримовый запрос OpenAI-модели записывается в `requests` с реальными `inputTokens`, `outputTokens` и `cacheReadTokens` (путь: `OpenAiMappedChatHandler` → `CompletionRequestTelemetry.recordAndApplyProxyHeaders` → `Requests.record`). Менять сам обработчик почти не нужно: он уже читает `context.*Tokens`.
- Стримовый запрос: `OpenAiMappedChatHandler` записывает телеметрию **до** отправки потока, с нулями. Перенос записи на конец потока (как это делает `OpenAIStreamHandler` для Claude, `apps/api/src/streaming/openai-stream-handler.ts`, около строк 200–225) — **необязательный этап Б**: сначала этап А (нестрим и формат usage), потом по решению владельца этап Б.
- Если для модели нет цены в `Pricing`, `estimatedCost` остаётся 0: это настройка цен, а не часть этой задачи.

### 4.5. Что не менять

- Маршруты и обработчики `claude` и `minimax`, `/v1/responses`, `/v1/messages`.
- Запрос к апстриму (тело, заголовки, reasoning, tools), выбор модели `ResponsesModelResolver`.
- Не логировать содержимое запросов, ответов и ключи; в диагностике допустимы только числа и имена моделей.

## 5. Файлы для правки

| Файл | Что |
| --- | --- |
| `apps/api/src/types/openai.ts` | тип `ChatCompletionUsage` (поля из 4.1 с необязательными `*_details`) |
| `apps/api/src/proxy/responses-stream-mapper/stream-state.ts` | `usage?: ChatCompletionUsage` в `StreamState` |
| `apps/api/src/proxy/responses-stream-mapper/stream-diagnostics.ts` | `mapUsage` по 4.1 |
| `apps/api/src/proxy/responses-stream-mapper/responses-event-router.ts` | `handleCompletedEvent` сохраняет `state.usage` |
| `apps/api/src/proxy/openai-client.ts` | `bufferedResponse` и `successResult`: usage из состояния, токены в `RequestContext`, без жёстких нулей |
| `docs/model-routing.md` | короткий подраздел: что отдаёт `/v1/chat/completions` в `usage` для каждого провайдера, формат OpenAI, правило «нет usage = нет поля» |
| тесты (п. 6) | см. ниже |

## 6. Тесты

Unit (`pnpm --filter @ungate/api test:unit`, каталог `apps/api/tests/unit/proxy`, образцы — `responses-stream-mapper.test.ts` и соседние):

1. `mapUsage` / роутер: `response.completed` с `input_tokens_details.cached_tokens` и `output_tokens_details.reasoning_tokens` даёт в финальном чанке `prompt_tokens_details.cached_tokens` и `completion_tokens_details.reasoning_tokens`; без `*_details` вложенных объектов нет; `total_tokens` пересчитывается, когда его нет или он 0; нечисловые и отрицательные значения пропускаются; `state.usage` заполнен.
2. `response.completed` без `usage`: `state.usage` не задан, финальный чанк без поля `usage`.
3. Нестримовая ветка (новый тест для `OpenAiClient`): подменить глобальный `fetch` SSE-ответом (`response.created`, `response.output_text.delta`, `response.completed` с usage) и учётные данные OpenAI; проверить, что `response.json().usage` содержит реальные числа, а `context.inputTokens`/`outputTokens`/`cacheReadTokens` совпадают.
4. Нестрим без `response.completed`: поле `usage` отсутствует, а не нулевое.
5. Модель выбирается без привязки к имени: тест с двумя разными `gpt-*` именами (например, `gpt-6.1-sol` и `gpt-5.4`) возвращает usage одним и тем же кодом.
6. Регрессия: стримовый тест из `responses-stream-mapper.test.ts` (`finish_reason: stop`, один `done`) проходит без изменений.

Интеграционные тесты (`apps/api/tests/integration`, если harness позволяет подмену апстрима): `POST /v1/chat/completions` с OpenAI-маппингом возвращает ненулевой `usage`; запрос записывается в `requests` с ненулевыми токенами.

## 7. Приёмка

1. `pnpm --filter @ungate/api test:unit` проходит; новые тесты падают на текущем коде и проходят после правки.
2. Живой нестримовый запрос к `gpt-6.1-sol` возвращает `usage.prompt_tokens > 0`, `usage.completion_tokens > 0`, `total_tokens = prompt + completion` (или значение апстрима):

   ```powershell
   $key = '<ключ Ungate API>'   # тот же, что использует провайдер ungate в генераторе; не печатать и не коммитить
   $body = @{ model = 'gpt-6.1-sol'; max_tokens = 64
              messages = @(@{ role = 'user'; content = 'Reply with the single word OK.' }) } | ConvertTo-Json -Depth 5
   (Invoke-RestMethod -Uri 'http://127.0.0.1:47821/v1/chat/completions' -Method Post `
       -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body).usage
   ```
3. Для стрима (`"stream": true`) финальный чанк содержит те же числа и, если апстрим их прислал, `prompt_tokens_details` / `completion_tokens_details`.
4. Те же запросы к `claude-haiku-5-5` и `miniMax-M3` возвращают usage того же вида, что до правки (сравнить с таблицей п. 3.2).
5. В dashboard Ungate (Analytics) нестримовый запрос к OpenAI-модели показывает ненулевые токены.
6. В генераторе: новый перевод с линией `ungate / gpt-6.1-sol` даёт в журнале вызова (`output/generation-jobs/<job>/execution/<task>/calls/*.json`) `usage.completion_tokens > 0` и `output_tokens_per_second`, а в Job Detail в сводке Translation lanes у этой линии вместо «tok/s n/a» появляется число.

## 8. Выкат

Правка затрагивает `apps/api/src/**`, поэтому по `AGENTS.md` проекта (раздел «ungate-api NSSM service») после тестов выполнить последовательно:

```powershell
pnpm --filter @ungate/api build
pnpm --filter @ungate/api build:bundle
nssm restart ungate-api
pwsh -NoProfile -NonInteractive -File .\scripts\start-codex-desktop-ungate.ps1 -PrepareOnly
```

Перезапуск службы коротко прервёт текущие запросы к `:47821`. Перед ним проверить, что нет идущих генераций в ландинг-генераторе (`GET http://127.0.0.1:8003/api/generation-jobs/summaries?status=running&status=queued` — пустой список) и активных чатов Codex. Неудачный restart или preflight считать нерешённой задачей и сообщить явно. Закоммитить и запушить через `dev-projects.ps1 ungate-local push -m "..."` (правило проекта).

## 9. Решения и риски для владельца

1. **Нет usage = нет поля** (п. 4.1.4). Альтернатива — `usage: null`. Выбрать после поиска потребителей; по умолчанию отсутствие поля.
2. **Этап Б** (телеметрия стрима): нужен ли перенос записи на конец потока для OpenAI-маршрута. Без него dashboard по стримовым запросам к OpenAI остаётся нулевым.
3. **Reasoning-токены** входят в `completion_tokens`; это стандартная семантика, не двойной счёт: `completion_tokens_details.reasoning_tokens` — подмножество.
4. **Цены:** `estimatedCost` по `gpt-*` не заработает, пока в `Pricing` нет цены модели.

## 10. Что не входит в эту задачу (замечено по коду, живьём не проверялось)

Отдельные тикеты, не смешивать с этой правкой:

1. `OpenAiClient.bufferedResponse` собирает только `delta.content`: вызовы инструментов (`tool_calls`) в нестримовый ответ не попадают, а `finish_reason` всегда `stop`.
2. `ResponsesEventRouter` обрабатывает `response.completed`, но не `response.incomplete` и не `response.failed`. Для ответа, обрезанного лимитом токенов, нестримовый результат выглядит как нормальный `stop` без usage. Генератор определяет обрезку по `finish_reason: length` (запускает восстановление), поэтому вместо восстановления он получит ошибку разбора JSON. Рекомендуется маппить `response.incomplete` в `finish_reason: length` и забирать usage и из этого события.
