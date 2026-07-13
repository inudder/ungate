# PATCHES-MAP.md

Карта ручных правок пользователя, обнаруженных в распакованной установке
`C:\Users\kalvinclein\.cursor\extensions\orchidfiles.ungate-1.7.1\`
путём сравнения с бэкапом
`C:\Users\kalvinclein\.cursor\extensions\orchidfiles.ungate-1.7.1_backup\`
(представляющим стоковую v1.7.1).

## Сводка

| Файл (в установке) | Δ байт | SHA-256 | Тип правки |
|---|---|---|---|
| `package.json` | +91 | (см. ниже) | Добавлена команда `ungate.toggleWakePing` |
| `dist/extension.js` | +6 138 | F34804A1... | Изменения в `dashboard.ts` + `extension-commands.ts` |
| `bundled/api/bundle/main.cjs` | +4 449 | 4AFA4352... | Новый файл `src/wake-ping.ts` + изменения в `src/server.ts` |
| `bundled/wake-ping.json` | NEW | — | Конфиг wake-ping (extension-side) |
| `bundled/api/wake-ping.json` | NEW | — | Конфиг wake-ping (api-side) |

**Веб-ассеты не тронуты:** `index-DaGKeNNz.js`, `index-DGJgZfn1.css`, `favicon.png`, `index.html` — байт-в-байт идентичны между установкой и бэкапом.

## Что добавлено: новая функция "Wake Ping"

Полностью пользовательская фича, **отсутствующая в апстриме**. Судя по коду, это «Keep Claude quota active» — периодическая отправка маленького запроса к Claude через `makeClaudeCodeRequest`, чтобы провайдерский квотный счётчик не обнулялся.

### Параметры по умолчанию (`bundled/api/wake-ping.json`)

```json
{
  "enabled": true,
  "intervalHours": 5,
  "sendOnStartup": true,
  "model": "claude-sonnet-4-20250514",
  "maxTokens": 10,
  "pingMessage": "ping"
}
```

Файл `bundled/wake-ping.json` (extension-side) сейчас с `enabled: false` — UI-флаг для новой команды.

## Изменения по исходным файлам

### 1. `apps/extension/package.json` (ОБНОВЛЁН)

**Маркер**: `package.json.diff` (минимальный unified-diff)
**Сложность переноса**: тривиальная
**Что сделать**:
- В `contributes.commands[]` добавить пятый объект:
  ```json
  {
    "command": "ungate.toggleWakePing",
    "title": "Ungate: Toggle Wake Ping"
  }
  ```

### 2. `apps/api/src/wake-ping.ts` (НОВЫЙ ФАЙЛ)

**Маркер**: `wake-ping.ts.recovered.ts` в этой папке
**Сложность переноса**: средняя (нужно вписать в структуру проекта)
**Что сделать**:
- Создать `apps/api/src/wake-ping.ts` (восстановленный исходник в комплекте)
- Импортировать `makeClaudeCodeRequest` из существующего модуля (см. тело `sendWakePing`)
- Файл читает/пишет `bundled/api/wake-ping.json` относительно `__dirname` — путь при билде нужно сохранить (как в стоке: `node_modules.bundled.api.bundle` + `../wake-ping.json`)

### 3. `apps/api/src/server.ts` (ОБНОВЛЁН)

**Маркер**: `server.ts.fragment.txt` (конкретные строки, которые нужно добавить)
**Сложность переноса**: средняя
**Что сделать**:
- В функции `startServer()`, **перед** `await app.listen(...)`:
  - Зарегистрировать два маршрута `app.get('/wake-ping', ...)` и `app.post('/wake-ping', ...)`
  - Содержимое обработчиков — см. фрагмент
- В функции `startServer()`, **сразу после** `globalThis.console.log(...)` строки про `listening on localhost`:
  - Добавить вызов `startWakePingScheduler();`
- Импортировать wake-ping функции в начало файла (`import * as wakePing from './wake-ping'` или конкретные имена)

### 4. `apps/extension/src/extension-commands.ts` (ОБНОВЛЁН)

**Маркер**: строки 22348-22356 в `dist/extension.js` (после `// src/extension-commands.ts`)
**Сложность переноса**: тривиальная
**Что сделать**:
- В объект `COMMANDS` (или аналогичный) добавить свойство:
  ```ts
  toggleWakePing: 'ungate.toggleWakePing',
  ```
- В обработчик команд добавить case `ungate.toggleWakePing`, который вызывает `sendWakePingState(!currentState)` и обновляет состояние в runtime-state

### 5. `apps/extension/src/dashboard.ts` (ОБНОВЛЁН)

**Маркер**: строки 21926-22348 в `dist/extension.js` (после `// src/dashboard.ts`)
**Сложность переноса**: средняя (UI-логика)
**Что сделать**:
- В `MSGS_SIMPLE` (или аналогичный список типов сообщений) добавить строки:
  - `'toggle-wake-ping'`
  - `'wake-ping-state'`
- Добавить метод `sendWakePingState(enabled: boolean)` в dashboard controller
- В обработчике сообщений webview добавить ветки:
  - `type === 'toggle-wake-ping'` → `vs.postMessage({ type: 'toggle-wake-ping' })`
  - `type === 'wake-ping-state'` → обновить `wakePingEnabled` и состояние чекбокса
- В HTML webview (где рендерится «Keep Claude quota active (Wake Ping)» card) добавить:
  - Контейнер-карточку `#wake-ping-card` с `<input id="wake-ping-checkbox" type="checkbox">`
  - Обработчик `change` события, отправляющий `toggle-wake-ping` сообщение
  - Логику вставки карточки в DOM с проверкой дубликатов

## Файлы, которые НЕ тронуты

- `apps/extension/src/api-server.ts`
- `apps/extension/src/extension-controller.ts`
- `apps/extension/src/extension-status-bar.ts`
- `apps/extension/src/extension.ts`
- `apps/extension/src/openai-key-fix.ts`
- `apps/extension/src/tunnel-manager.ts`
- `apps/extension/src/runtime-state/*`
- `apps/extension/src/utils/*`
- `apps/api/src/database/*`
- `apps/api/src/auth/*`
- `apps/api/src/proxy/*`
- `apps/api/src/orchestration/*`
- `apps/api/src/streaming/*`
- `apps/api/src/routes/*`
- `apps/web/**`
- `packages/**`
- Любые `.json` кроме `package.json`

## Что делать дальше (когда будете готовы)

1. Скопировать `wake-ping.ts.recovered.ts` → `apps/api/src/wake-ping.ts`
2. Применить изменения из `server.ts.fragment.txt` к `apps/api/src/server.ts`
3. Применить изменения из `dashboard.ts.fragment.txt` к `apps/extension/src/dashboard.ts`
4. Применить изменения из `extension-commands.ts.fragment.txt` к `apps/extension/src/extension-commands.ts`
5. Добавить `toggleWakePing` в `apps/extension/package.json` → `contributes.commands`
6. Опционально: добавить `bundled/api/wake-ping.json` и `bundled/wake-ping.json` с дефолтами
7. Сборка: `pnpm run package:build` в корне `J:\Dev\ungate-local\`
