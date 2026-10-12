# ТЗ: вынос встроенных моделей launcher из кода в JSON

## 1. Цель

Убрать список встроенных моделей из PowerShell-кода (`New-UngateModelSet` в `scripts/codex-desktop-launcher/Models.psm1`) и хранить его в JSON. После этого любую модель можно удалить из launcher и picker настоящим удалением записи, без правки `.psm1`, а новую модель можно добавить или вернуть из шаблона без правки кода.

Результат для пользователя:

- «Удалить» работает для любой модели: консольное меню launcher (`R`) и вкладка Codex Beta в dashboard.
- Удалённая модель не возвращается при следующем запуске и после обновления репозитория.
- Удалённую модель можно вернуть из списка шаблонов.
- Скрытие (`ungate-hidden-models.json`) заменяется настоящим удалением.

## 2. Текущее состояние

| Что | Где | Проблема |
| --- | --- | --- |
| 10 встроенных моделей | `New-UngateModelSet`, массив `$BuiltInUngateModelDefinitions` | Удаление требует правки кода и тестов |
| Свои модели | `~/.codex-ungate/ungate-model-definitions.json` (version 1) | Схема не вмещает поля встроенных (см. п. 4.3) |
| Скрытие встроенных | `ungate-hidden-models.json`, фильтр в `Get-UngateModelDefinitions` | Временный обход: запись остаётся в коде и в списке «Скрытые» |
| Правки версии, контекста, prefix, возможностей | `ungate-model-overrides.json` | Остаётся без изменений |
| Picker | `ungate-picker-models.json` | Остаётся без изменений |

Встроенные определения ссылаются на `$Context` (`ProviderName`, `ProxyBaseUrl`, `CliProxyBaseUrl`, `OmniRouteBaseUrl`). Поэтому в JSON их нельзя класть как есть: хранить нужно транспорт, а адреса и ключи вычислять при загрузке.

Фиксированный контракт, который нельзя сломать: тест `preserves all builtin model fields and exact identity bytes from the monolith` в `scripts/codex-desktop-launcher/tests/Launcher.Tests.ps1` и снимок `tests/fixtures/models.json`, включая `IdentitySha256`.

## 3. Решение

Два уровня данных.

1. **Шаблон** `scripts/codex-desktop-launcher/models.default.json`: версионируется в git, только для чтения, содержит 10 нынешних встроенных моделей. Это каталог готовых записей, а не список активных моделей.
2. **Реестр профиля** `~/.codex-ungate/ungate-model-registry.json`: единственный источник списка активных моделей (и бывших встроенных, и своих). Удаление модели означает удаление её записи отсюда.

Правила:

- Реестр профиля создаётся при первом запуске новой версии копированием шаблона. Дальше launcher не дописывает в него записи сам.
- Новые модели из обновлённого шаблона в существующий профиль автоматически не попадают. Их можно добавить явно: пункт «Добавить из шаблонов» в меню и в dashboard показывает записи шаблона, которых нет в реестре.
- Благодаря этому не нужны «надгробия» удалённых моделей: удалённая модель просто отсутствует в реестре и появляется снова только по явному действию пользователя.
- `codex-fallback` (`OmniRouteFallbackModelDefinition`), alias `ungate-memory`, фоновый shell `gpt-5.6-luna` и shell pool остаются в коде: это механизмы, а не пользовательские модели.

## 4. Формат

### 4.1. Файлы

| Файл | Версия | Роль |
| --- | --- | --- |
| `scripts/codex-desktop-launcher/models.default.json` | `version: 1` | Шаблон, только чтение |
| `~/.codex-ungate/ungate-model-registry.json` | `version: 1` | Реестр профиля, чтение и запись |
| `ungate-model-definitions.json`, `ungate-hidden-models.json` | как сейчас | Устаревшие, используются только миграцией, дальше не читаются и не изменяются |

Новый файл вместо смены версии у `ungate-model-definitions.json` выбран ради обратной совместимости: прежняя версия launcher продолжает читать старые файлы, и откат возможен.

### 4.2. Запись модели

```json
{
  "version": 1,
  "models": [
    {
      "slug": "deepseek-v4-pro",
      "displayName": "DeepSeek V4 Pro (OmniRoute)",
      "description": "DeepSeek V4 Pro through the local OmniRoute proxy on port 20128.",
      "upstreamModel": "deepseek/deepseek-v4-pro",
      "aliases": ["deepseek-pro", "ds/deepseek-v4-pro"],
      "transport": "omniroute",
      "defaultReasoningLevel": "high",
      "supportsImageInput": false,
      "contextWindow": 1000000,
      "maxContextWindow": 1000000,
      "supportsReasoningSummaries": true,
      "supportsParallelToolCalls": true,
      "responsesAdapter": "deepseek-responses",
      "supportedReasoningLevels": [
        { "effort": "none", "description": "Disable Thinking" },
        { "effort": "low", "description": "Low Thinking" },
        { "effort": "high", "description": "High Thinking" },
        { "effort": "max", "description": "Max Thinking" }
      ]
    }
  ]
}
```

Шаблон и реестр используют одну схему записи. Порядок записей в массиве задаёт `Priority` (0, 1, 2 и так далее), поэтому поле `priority` в JSON не хранится.

### 4.3. Поля

Обязательные: `slug`, `displayName`, `transport` (`ungate`, `cliproxyapi`, `omniroute`), `defaultReasoningLevel`, `supportsImageInput`. `upstreamModel` обязателен, кроме явного `null` для транспорта `ungate` (сейчас так устроен `miniMax-M3`: провайдер сам нормализует id).

Необязательные: `description`, `aliases`, `contextWindow`, `maxContextWindow`, `effectiveContextWindowPercent`, `supportsImageDetailOriginal`, `supportsReasoningSummaries`, `supportsParallelToolCalls`, `responsesAdapter`, `truncationPolicy` (`{ "mode": "bytes", "limit": 10000 }`), `supportedReasoningLevels`, `defaultReasoningSummary`, `supportVerbosity`, `defaultVerbosity`.

Не хранятся, а вычисляются при загрузке:

| Поле определения | Источник |
| --- | --- |
| `ProviderName`, `ProviderDisplayName`, `ProxyBaseUrl`, `EnvKey`, `RequiresUngate`, `TransportDescription` | таблица транспортов (п. 5.2) и `$Context` |
| `Identity` | `Get-UngateModelIdentity` (без изменений) |
| `InputModalities`, `WebSearchToolType` | из `supportsImageInput` (`text,image` / `text_and_image` либо `text` / `text`) |
| `SupportsImageDetailOriginal` | из `supportsImageDetailOriginal`, иначе равен `supportsImageInput` |
| `Priority` | позиция записи |
| `Description` | поле `description`, иначе как сейчас у своих моделей |

`supportedReasoningLevels` принимает и строку, и объект `{effort, description}`. Сегодня реестр сохраняет только имена уровней, и описания теряются.

## 5. Поведение

### 5.1. Загрузка

`Get-UngateModelDefinitions` читает реестр профиля, превращает каждую запись в определение через общий конвертер и применяет `ungate-model-overrides.json`. Старые параметры (`-BuiltInDefinitions`, `-RegistryPath`) сохраняются или заменяются одним объектом набора, но все вызывающие стороны (Launcher, Picker, Management, Memories, Capabilities, Routing) обновляются и не должны знать о двух источниках.

### 5.2. Таблица транспортов

Единая функция, например `Get-UngateTransportProfile`, которую используют и загрузка реестра, и `ConvertTo-UngateModelDefinition`:

| transport | ProviderName | ProviderDisplayName | ProxyBaseUrl | EnvKey | RequiresUngate | TransportDescription |
| --- | --- | --- | --- | --- | --- | --- |
| ungate | `$Context.ProviderName` | Ungate Proxy | `$Context.ProxyBaseUrl` | `UNGATE_API_KEY` | true | the local Ungate Responses proxy |
| cliproxyapi | `$Context.CliProxyProviderName` | CLIProxyAPI | `$Context.CliProxyBaseUrl` | `CLIPROXYAPI_API_KEY` | false | the local CLIProxyAPI compatibility bridge |
| omniroute | `$Context.OmniRouteProviderName` | OmniRoute | `$Context.OmniRouteBaseUrl` | `OMNIROUTE_API_KEY` | false | the local OmniRoute proxy |

Значения берутся из уже существующего кода `ConvertTo-UngateModelDefinition`; дублировать их в двух местах нельзя.

### 5.3. Удаление

Для любой модели: убрать запись из реестра, убрать её запись из `ungate-model-overrides.json`, убрать из `ungate-picker-models.json` (если остался пустой выбор, удалить файл picker), сбросить `ungate-background-model.json`, если он указывает на эту модель. Это уже реализовано для своих моделей в `Remove-UngateProfileModel` в `Picker.psm1`; логика распространяется на все записи.

Запреты: нельзя удалить последнюю модель; нельзя удалить `ungate-memory`.

### 5.4. Добавление из шаблона

Новое действие «Добавить из шаблонов»: список записей `models.default.json`, чьих `slug` нет в реестре; выбранная запись копируется в конец реестра. Если `slug` уже занят, действие отклоняется с понятной ошибкой.

### 5.5. Модель по умолчанию

`Context.psm1` задаёт `Model = 'ungate-opus-4-8'` и тот же default стоит в параметрах `start-codex-desktop-ungate.ps1`. Если пользователь удалил эту модель, запуск без `-Model` (в том числе `-PrepareOnly`) должен выбирать первую модель picker, а при её отсутствии первую модель реестра, а не падать с «unknown model». Явный `-Model` на несуществующую модель остаётся ошибкой.

### 5.6. Целостность и параллелизм

- Запись атомарно: temp-файл в той же директории и `Replace`/`Move`, резервная копия `.bak` остаётся как ручной путь восстановления (как у остальных файлов профиля).
- Все записи под `Enter-UngateProfileLock`.
- Повреждённый или неподдерживаемой версии реестр не заменяется пустым или шаблонным: показывается явная ошибка, как для остальных файлов (`definitionError` в state).
- Ревизия реестра для защиты от устаревшего вида (409 `stale_revision`) считается хэшем файла, как сейчас.

## 6. Миграция существующих профилей

Выполняется один раз и автоматически, когда `ungate-model-registry.json` отсутствует, под блокировкой профиля:

1. Прочитать шаблон. Ошибка шаблона (нет файла, неверная схема, повторы slug) останавливает запуск с понятным сообщением.
2. Прочитать `ungate-hidden-models.json`, если он есть: эти slug в реестр не попадают.
3. Прочитать `ungate-model-definitions.json`, если он есть: его записи добавляются после шаблонных в прежнем порядке.
4. Записать реестр. Старые файлы не удалять и не менять, чтобы можно было откатиться на прежнюю версию кода.
5. Сообщить пользователю в консоли и в state, что реестр создан и сколько моделей перенесено.

Критерий корректности: на профиле без скрытых и своих моделей результат загрузки совпадает с нынешним снимком байт в байт.

После миграции `ungate-hidden-models.json` и `ungate-model-definitions.json` не читаются; hide-логика (`Read-UngateHiddenModelSlugs`, `Write-UngateHiddenModelSlugs`, фильтр в `Get-UngateModelDefinitions`, `Restore-UngateProfileModel`, `models.restore`) удаляется.

## 7. Изменения по компонентам

| Компонент | Что сделать |
| --- | --- |
| `Models.psm1` | Новые `Read-UngateModelRegistry`, `Write-UngateModelRegistry`, `Read-UngateModelTemplate`, `Get-UngateTransportProfile`, `Initialize-UngateModelRegistry` (миграция). Убрать массив встроенных; `New-UngateModelSet` оставить для `FallbackDefinition`. Валидатор записи общий для шаблона и реестра. Убрать hide-функции |
| `Context.psm1` | Пути `ModelRegistryPath`, `ModelTemplatePath`; убрать `HiddenModelsPath` |
| `Picker.psm1` | `Remove-UngateProfileModel` без ветки «скрыть»; меню `R`: удаление любой модели и пункт добавления из шаблонов; убрать возврат скрытых |
| `Management.psm1` | state: без `hidden` и `origin`; `inTemplate` вычисляется по шаблону; `templates` — записи шаблона, которых нет в реестре; ревизия — хэш реестра; `models.remove` и `models.addTemplate`; без `models.restore` |
| `Launcher.psm1`, `Capabilities.psm1`, `Memories.psm1`, `Routing.psm1` | Перейти на единый вызов загрузки определений; учесть п. 5.5 |
| `apps/control/src/launcher-routes.ts` | Маршруты `models/remove` и `models/add-template`; убрать `models/restore` |
| `packages/shared/src/types/launcher.ts` | Обновить `LauncherState` и `LauncherModelState`; пересобрать `@ungate/shared` |
| `apps/web/.../CodexBetaPage.svelte` | Кнопка «Удалить модель» для всех записей; блок «Добавить из шаблонов» вместо «Скрытые встроенные модели» |
| Документация | `docs/model-routing.md` (раздел «Adding a model»: шаг 3 теперь правит `models.default.json`), `docs/desktop-launcher.md` (таблица модулей), `docs/codex-beta-dashboard-spec.md` (файлы и маршруты), `AGENTS.md` (описание путей) |

## 8. Совместимость и ограничения

- Командная строка launcher и параметры не меняются, включая алиасы (`-Model deepseek-flash`).
- Алиасы остаются полем записи и участвуют в разрешении `-Model` так же, как сейчас.
- Новые встроенные модели из будущих версий шаблона не появляются у существующих пользователей сами, только через «Добавить из шаблонов». Это сознательное решение (п. 3).
- Откат на прежнюю версию кода работает за счёт нетронутых старых файлов; модели, добавленные или удалённые уже в новой версии, прежняя версия не увидит.
- Шаблон не содержит секретов; ключи по-прежнему берутся из окружения, SQLite и OmniRoute.

## 9. Тесты и приёмка

Обязательные автоматические проверки:

1. Существующий снимок `preserves all builtin model fields and exact identity bytes from the monolith` проходит без изменения `fixtures/models.json`: по шаблону собираются те же 10 определений, те же `IdentitySha256`.
2. Шаблон: валидируется целиком, slug уникальны, порядок даёт `Priority` 0 и далее, все транспорты допустимы, MiniMax с `upstreamModel: null` собирается без ошибок.
3. Миграция: чистый профиль; профиль со скрытой моделью (не попадает в реестр); профиль со своей моделью (попадает в конец); повторный запуск ничего не меняет; повреждённый старый файл даёт явную ошибку и реестр не создаётся.
4. Удаление: встроенная модель удаляется из реестра, picker, overrides и фоновой настройки; после повторных запусков не возвращается; последняя модель не удаляется; `ungate-memory` не удаляется.
5. Добавление из шаблона: удалённая модель возвращается; уже существующий slug отклоняется; ревизия устаревшего вида даёт 409.
6. Модель по умолчанию: при удалённой `ungate-opus-4-8` запуск без `-Model` выбирает первую доступную модель.
7. Маршруты `apps/control` (`models/remove`, `models/add-template`) пересылают действие и отклоняют неизвестные поля.
8. `pwsh scripts/test-codex-desktop-launcher.ps1` проходит целиком; для web и control проходят `svelte-check`, `eslint`, `tsc`, `vitest`.

Ручная приёмка на копии профиля: удалить встроенную модель в dashboard и в консольном меню, перезапустить launcher и убедиться, что она не вернулась; вернуть её из шаблонов; убедиться, что предупреждение о лимите picker не появляется после сохранения выбора.

## 10. Развёртывание

По правилам `AGENTS.md`:

1. Изменения только в `scripts/**` launcher подхватываются при следующем запуске; фоновый агент управления (`codex-launcher-control-agent.ps1`) нужно перезапустить через `scripts/start-codex-launcher-control.ps1`, иначе он продолжает работать со старым модулем.
2. Для изменений в dashboard: `pnpm --filter @ungate/shared build`, `pnpm --filter @ungate/control build:bundle`, `nssm restart ungate-dashboard`, проверка `http://127.0.0.1:47820/` и нового хэшированного asset.
3. `ungate-api` не перезапускается.

## 11. Риски

| Риск | Мера |
| --- | --- |
| Дрейф идентичности моделей при переносе | Снимок `IdentitySha256` как обязательный тест |
| Шаблон испорчен или отсутствует | Явная ошибка запуска, проверка схемы шаблона в тестах |
| Пользователь удалил все полезные модели | Запрет удаления последней, «Добавить из шаблонов» всегда доступен |
| Две версии launcher работают с одним профилем | Старые файлы не меняются; в документации указано, какие данные прежняя версия не увидит |
| Забыли обновить вызывающую сторону | Один вход загрузки определений; поиск по `BuiltInDefinitions` в `scripts/` должен вернуть ноль использований вне `Models.psm1` |

## 12. Вне объёма

- Редактор шаблонов в dashboard (шаблон меняется в git).
- Автоматическое добавление новых моделей из шаблона в существующие профили.
- SQLite или другое хранилище вместо JSON.
- Изменение портов провайдеров, shell pool, фонового маршрута и `codex-fallback`.
- Перенос `ungate-model-overrides.json` в реестр (правки версии, контекста, prefix и возможностей остаются отдельным слоем).

## 13. Принятые решения

- `description` — необязательное поле JSON. В шаблон скопированы нынешние строки 10 моделей, включая порты. Пустое или отсутствующее поле при загрузке даёт `"{displayName} maps to upstream model '{upstream}' through {transportDescription}."`. Если upstream пустой, фраза без кавычек: `"{displayName} maps through {transportDescription}."`. Подстановка нового display name в description при override сохраняется. Порт в тексте сам не обновляется.
- Поле `source` / `origin` в реестр не пишется и из state уходит. `LauncherModelState.inTemplate` вычисляется: slug есть в шаблоне. Кнопка везде «Удалить модель». Для модели из шаблона предупреждение говорит, что вернётся запись шаблона, не текущие правки; для своей — что её придётся ввести заново.
- `upstreamModel` в каждой записи обязателен. `null` допустим только при `transport: "ungate"` (MiniMax и свои модели Ungate). Для `cliproxyapi` и `omniroute` нужна непустая строка без пробелов и кавычек. Пустая строка и пропуск поля — ошибка на всех транспортах. В определении `null` остаётся `null`: запрос уходит со slug, в identity нет скобки `(upstream model …)`.

## 14. Этапы

1. Шаблон и загрузка: `models.default.json`, `Get-UngateTransportProfile`, чтение и запись реестра, общий валидатор, снимок проходит.
2. Миграция и переключение вызывающих сторон на единый вход, hide-логика удалена, п. 5.5.
3. Удаление и добавление из шаблона в консольном меню и в `Management.psm1`, тесты Pester.
4. Маршруты, типы и интерфейс dashboard, сборка и перезапуск.
5. Документация и ручная приёмка на копии профиля.
