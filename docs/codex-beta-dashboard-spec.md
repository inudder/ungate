# ТЗ: настройки launcher Codex Beta в существующем dashboard Ungate

Дата исследования: 9 октября 2026. Репозиторий: J:/Dev/ungate-local. Исследован HEAD cbe8f97333bf4e354168ab4cad208d39938c1c02. Перед реализацией перечитать актуальные AGENTS.md и исходники; сохранить появившиеся пользовательские изменения.

## 1. Задача для новой сессии

Встроить управление настройками PowerShell launcher Codex Beta в действующий dashboard Ungate. Добавить вкладку «Codex Beta», сохранив консольный launcher и двустороннюю совместимость настроек. Реализовать интерфейс, локальный management API, выполнение диагностики, тесты, документацию и внедрение dashboard по правилам проекта.

Использовать существующие apps/web и apps/control. Не создавать отдельную панель на Pode/Pode.Web и отдельный HTTP-сервер для интерфейса.

Первая версия охватывает все существующие редакторы launcher, выбор провайдера при добавлении модели, информацию о маршрутах, сохранённые настройки и диагностику. Запуск/остановка Beta, автоматический restart router, изменение портов провайдеров и управление внешними gateway не входят в первую версию. Для применения настроек UI формирует команду существующего launcher, которую пользователь запускает в своей PowerShell-сессии.

## 2. Что установлено исследованием

| Компонент | Фактическое устройство |
| --- | --- |
| Dashboard | http://127.0.0.1:47820; в момент исследования обслуживался node.exe с PID 7308. 7308 — PID, а не порт |
| Служба dashboard | ungate-dashboard, NSSM, учётная запись LocalSystem, apps/control/bundle/main.cjs |
| HTTP backend dashboard | apps/control, Fastify 5; loopback; allowlist backend routes, проверка Host/Origin, bootstrap CSRF, SSE /api/events |
| Frontend | apps/web, Svelte 5, Vite, Tailwind/Skeleton; вкладки Analytics, Settings, Logs в App.svelte |
| Ungate API | порт 47821, отдельная служба ungate-api; слушает 0.0.0.0 и используется внешним FRP-маршрутом |
| Launcher | scripts/start-codex-desktop-ungate.ps1 и scripts/codex-desktop-launcher/*.psm1 |
| Beta профиль | C:/Users/kalvinclein/.codex-ungate |
| Обычный профиль | C:/Users/kalvinclein/.codex; launcher читает его для первоначальной настройки и синхронизации MCP/auth/AGENTS |

Модели в существующем SettingsPage — AppSettings.models / ModelMappingConfig для Ungate API, с провайдерами claude/minimax/openai. Модели launcher — другой реестр, с транспортами ungate/cliproxyapi/omniroute, версиями, возможностями, shell aliases и picker. Не объединять эти два реестра и не сохранять launcher settings через существующий POST /settings.

Источники для реализации:

- [Frontend tabs](../apps/web/src/App.svelte), [SettingsPage](../apps/web/src/features/settings/SettingsPage.svelte), [ModelsSection](../apps/web/src/features/settings/ModelsSection.svelte).
- [Dashboard client](../apps/web/src/shared/dashboard-client.ts), [HTTP server](../apps/control/src/server.ts), [operations runtime](../apps/control/src/control-runtime.ts), [config](../apps/control/src/config.ts).
- [Shared dashboard types](../packages/shared/src/types/dashboard.ts), [service manifest](../deploy/nssm/ungate-dashboard.service.json).
- [Launcher contract](desktop-launcher.md), [routing matrix](model-routing.md), [launcher entry point](../scripts/start-codex-desktop-ungate.ps1).
- Launcher modules: Context, Models, ModelCapabilities, Capabilities, Picker, Memories, Logging, Routing, Catalog, ProxyRuntime, Launcher, ToolCompatibility, Profile.

Перед анализом связей использовать существующий Graphify graph согласно AGENTS.md. Граф служит навигацией; поведение подтверждать исходниками и тестами.

## 3. Архитектура и контекст пользователя

Поток управления:

    Svelte: вкладка Codex Beta
      -> apps/control: /api/control/launcher/* на 47820
      -> локальный агент в Windows-сессии владельца Beta профиля
      -> management functions PowerShell + существующие Node diagnostic runners
      -> существующие JSON-файлы launcher и диагностические отчёты

Служба LocalSystem не должна выводить профиль из своего HOME/USERPROFILE, использовать systemprofile вместо пользовательского профиля или запускать Codex Desktop в Session 0. Пользовательские переменные окружения и credential resolution также нельзя подменять окружением NSSM.

Для первой версии требуется небольшой локальный пользовательский агент, общий для dashboard management. Он читает/сохраняет настройки и выполняет диагностику от владельца профиля. Он не запускает Beta и не управляет рабочими службами. Это служебный компонент внутри проекта, без отдельного UI и HTTP-порта.

Транспорт между apps/control и агентом — Windows named pipe. Имя привязать к настроенному SID владельца и каноническому пути Beta home. Оба конца проверяют идентичность peer; pipe ACL разрешает только владельца и настроенную служебную учётную запись dashboard (сейчас LocalSystem), запрещает сетевой доступ. Обеспечить эксклюзивное создание endpoint, проверку PID/владельца серверного процесса и отказ при подмене. Не использовать world-readable pipe или небезопасный fallback, если ACL недоступен. Проверить поддержку выбранного механизма ACL на установленном PowerShell/.NET.

В deployment config dashboard явно указать SID владельца, допустимый Beta home и endpoint агента. Browser передаёт логический profileId, а не произвольный путь, SID, script path, executable или команду. Первая версия поддерживает один настроенный профиль. Пользовательский агент сверяет свой SID/home с конфигурацией. Нормальный Codex home остаётся read-only.

Предусмотреть отдельную команду запуска агента от пользователя, например scripts/start-codex-launcher-control.ps1. Она запускает фоновой процесс скрыто, сохраняет идентификатор собственного процесса, предотвращает дубликаты и возвращает результат готовности. Обычный пользовательский запуск launcher может запускать/переиспользовать этот агент. Не устанавливать молча scheduled task, новую NSSM-службу или системный autorun. Редактор/диагностика по-прежнему не запускают Beta и не перезапускают provider services.

При отсутствии агента существующий dashboard продолжает работать. Вкладка показывает «Компонент управления не запущен» и команду его запуска; недоступные действия явно disabled. Не имитировать загрузку пустого реестра и не сохранять настройки от LocalSystem в другой профиль.

IPC передаёт ограниченный JSON-протокол с requestId, version и allowlisted action. Задать лимит размера сообщений, framing, таймауты и обработку разрыва. Если используется дочерний PowerShell/Node worker, запускать executable с массивом аргументов, shell:false/windowsHide:true; JSON и ключи передавать через stdin. Запретить Invoke-Expression, shell command strings и разбор Write-Host как API.

## 4. Общая логика CLI и UI

Создать management module, например scripts/codex-desktop-launcher/Management.psm1, и неинтерактивный worker entry point. Отделить функции чтения/валидации/записи от Read-Host, Console.ReadKey, Write-Host и lifecycle launcher. CLI-редакторы и management worker вызывают одни бизнес-функции.

Не вызывать обычный Invoke-CodexDesktopLauncher для получения состояния или сохранения формы. Это может подготовить профиль, поднять/обновить transport и запустить Desktop. Импорт management modules не должен иметь таких side effects.

Повторно использовать New-UngateModelSet, Get-UngateModelDefinitions, Get-UngateModelCapabilities, Merge-UngateModelCapabilities, существующие registry/override/picker/memory/log helpers и Get-UngateRequestModel. При необходимости выделить из интерактивного V общую функцию изменения версии с той же валидацией. Не переписывать правила возможностей в TypeScript как второй источник истины.

API возвращает base values, effective values, raw explicit overrides, editable field names и provenance. Показывать происхождение значения: определение модели/каталог-шаблон/пользовательский override. Не объявлять всё «встроенным default», если значение реально унаследовано из models_cache.json.

Модель адресуется неизменным registryId/Slug. UpstreamModel, DisplayName, номер пункта меню и shell alias не являются ключами записи. Все модели доступны в редакторе, включая исключённые из picker.

## 5. Интерфейс

Добавить вкладку «Codex Beta» рядом с действующими Analytics/Settings/Logs. Внутри: «Модели», «Picker», «Память», «Логирование», «Диагностика». Провайдеры отображаются как фильтр и карточки маршрутов в «Моделях». Сохранить действующий стиль приложения, не вводить новый UI framework.

Показывать owner/profile home, состояние агента, загрузку/ошибки, количество выбранных picker моделей, наличие несохранённых изменений и статус последней диагностики. Основные подписи — по-русски; технические IDs и имена параметров оставить точными.

Таблица моделей: название, registryId, upstream, transport, context, image, reasoning default, присутствие в picker, override и последнее проверенное состояние. Поиск по названию/ID/upstream, фильтр по transport. Выбор строки открывает редактор; список не заменяет Desktop picker.

### 5.1. Версия модели — аналог V

Редактировать upstreamModel, displayName и contextWindow. Принимать контекст в токенах или формате 200k/500k/1M через существующий parser. Для custom registry сохранять тот же stable ID. Показывать native upstream и фактический request model отдельно.

В расширенной секции показывать/редактировать существующий transport override upstreamModelPrefix. Его валидация и преобразование должны использовать общие functions; это не флаг поддержки image. Сброс transport prefix — отдельное действие.

«Сбросить версию» удаляет только upstreamModel, displayName, contextWindow из override. Сохраняет capabilities, upstreamModelPrefix и соседние модели. «Сохранить» объединяет изменённые поля с существующей записью. «Отменить» возвращает сохранённые значения без записи.

Доступные upstream IDs запрашивать отдельно по кнопке через агент и штатный provider catalog. Недоступный или неполный /v1/models не должен запрещать вручную введённый совместимый upstream: каталог CLIProxyAPI/OmniRoute может не перечислять реально доступные модели. Не выбирать автоматически другую модель при ошибке discovery.

### 5.2. Возможности — аналог C

| Поле | UI и правила |
| --- | --- |
| text | Всегда включён, read-only |
| supportsImageInput | Переключатель image |
| supportsImageDetailOriginal | Отдельный переключатель; активен только при image |
| supportedReasoningLevels | Множественный выбор none/minimal/low/medium/high/xhigh/max/ultra; только реально выбранные уровни |
| defaultReasoningLevel | Select из effective allowed levels |
| supportsReasoningSummaries | Поддержка summaries; при Off defaultReasoningSummary становится none |
| defaultReasoningSummary | none/auto/concise/detailed; доступен при поддержке |
| supportsParallelToolCalls | Отдельный Boolean override |
| supportVerbosity | Поддержка параметра verbosity |
| defaultVerbosity | low/medium/high; при отключении поддержки null |

Для изменяемых полей различать «наследовать» и явное значение. Не превращать весь effective object в overrides после сохранения одного checkbox. Явное false не равно отсутствующему полю; null у defaultVerbosity — допустимое значение, а не команда наследования.

При выключении image существующая общая логика выключает original. При явной комбинации image=false/original=true возвращать validation error. Allowed reasoning list — непустой, уникальный, из разрешённых строк; default обязан присутствовать в effective list. Не расширять поддерживаемые уровни автоматически.

Действия: «Сохранить», «Отменить», «Сбросить возможности», «Проверить сохранённые настройки». Сброс удаляет только девять полей capabilities, сохраняя версию/контекст/prefix. Для несохранённой формы проверку либо disable с пояснением, либо запускать только после явного сохранения; скрытого Save and Test нет.

Audio, video, прямой PDF, генерацию изображений и provider-native search не добавлять. Сохранить уже существующие catalog flags supports_reasoning_summary_parameter и legacy summaries, а также optional route.parallelToolCalls. Поля с другой семантикой не объединять.

### 5.3. Добавление модели

Форма повторяет AddModel: уникальный registryId, название, upstream, контекстное окно, transport ungate/cliproxyapi/omniroute, default reasoning, image и original отдельно. Original новой модели по умолчанию выключен. Использовать существующую нормализацию и валидацию реестра, сохранять version:1.

Контекст принимает токены или 200k/1M (тот же parser, что и у версии). Пустое поле оставляет 200k. Заданное значение пишется в запись реестра как `contextWindow` (оно же max), а не в overrides, поэтому «Сбросить версию» возвращает к нему, а не к 200k. Интерактивный AddModel в launcher спрашивает то же значение.

Кнопка добавления берёт текст из строки поиска: если поиск ничего не нашёл, кнопка называется «Добавить «…»», а форма заполняет пустые поля ID, названия и upstream этим текстом и прокручивается в видимую область.

Перед записью models.add читает /v1/models выбранного transport тем же endpoint и ключом, что и launcher, и отклоняет модель с HTTP 422: `model_not_in_catalog`, если request model там нет (в ответе перечисляются похожие ID), или `catalog_unavailable`, если каталог не прочитан. Для omniroute действуют правила preflight (`Resolve-OmniRouteCatalogModel`): алиасы mimo/, deepseek/, ds/ и явные маршруты openai-compatible-*. Флаг `skipCatalogCheck: true` пропускает сверку для моделей, которые transport обслуживает, но не публикует в каталоге; live preflight при запуске остаётся решающим.

Модели профиля хранятся в ungate-model-registry.json. Удаление убирает запись; модель из шаблона возвращается копией из models.default.json, а не текущими правками. Переименование stable ID и перенос существующих моделей между transport не входят в эту версию. Изменение версии и возможностей выполняется через те же overrides.

### 5.4. Picker

Checkboxes по всему реестру, счётчик выбранных моделей. Допустимо от одной до Context.CodexDesktopPickerCapacity, сейчас шесть (gpt-5.6-luna зарезервирован под фоновые задачи Desktop). Не зашивать capacity в компонент. UI показывает порядок, который действительно использует launcher; текущий writer нормализует порядок по Definitions, поэтому drag-and-drop порядка в первой версии не делать.

Сохранение использует ungate-picker-models.json и общий validator. Модель вне picker остаётся доступной редактору и диагностике. ungate-memory не расходует picker slot и не отображается как обычная модель. Не менять shell pool или shell mapping автоматически.

### 5.5. Провайдеры и параметры следующего запуска

Показывать transport, endpoint/hops, route-specific adapter, доступность credentials как Boolean и источник ключа как безопасную метку. Значения ключей не отдавать UI. Проверка доступности/discovery — отдельная кнопка; открытие вкладки не отправляет платный запрос к модели и не стартует службы.

Действующие маршруты брать из Context/Models/Routing. На дату исследования: Ungate API 47821; CLIProxyAPI 8317 через bridge 8318; OmniRoute 20128; основной model-shell router 8319. Bridge нужен только соответствующему transport, Mimo adapter — только соответствующим моделям. ProviderName transport и физический provider внутри gateway — разные понятия.

Существующие API auth/settings Claude/MiniMax/OpenAI остаются на странице Settings; добавить понятную ссылку туда для Ungate transport. Не копировать provider credentials в новый JSON и не редактировать конфигурации OmniRoute/CLIProxyAPI из этой вкладки. URL/ports fixed transports показывать read-only; произвольный provider registry — отдельная будущая задача.

В секции «Следующий запуск» выбрать модель из сохранённого picker либо существующий OmniRoute fallback; показывать chain Claude -> Grok -> MiniMax -> Gemini, без её изменения. Форма генерирует PowerShell-команду launcher без ключей. При fallback исключить -Model: эти параметры несовместимы. Дополнительно разрешить -SkipWorkspaceRestore, -NoLogWatch или выбранный -LogLevel согласно CLI contract.

Выбор модели, fallback и SkipWorkspaceRestore сейчас являются параметрами запуска, а не сохранёнными настройками. В первой версии они остаются draft формы команды; не создавать молча новый файл «defaults» и не менять поведение start-codex без аргументов. PrepareOnly не считать безвредным редактором: он может обновлять рабочий transport/profile, поэтому не выполнять его из UI.

### 5.6. Память

Enabled, transport и точный upstream model в ungate-memory-settings.json. Показать documented default Off / cliproxyapi / gemini-3.8-flash-high и фактически сохранённое состояние, не заменяя его default.

Кнопки сохранения, восстановления штатных defaults и dedicated Responses validation. Для enable/смены модели при включённой памяти нужна штатная успешная проверка extraction/consolidation, как в CLI. Нельзя заменять её обычным text/image smoke. Повторная проверка при обычном запуске launcher сохраняется.

Ошибка validation не стирает сохранённую preference, не подменяет модель и не включает fallback. Показать сохранённое состояние и результат проверки отдельно; правила выключения для конкретного запуска оставить в launcher. Существующие key resolution и hidden alias ungate-memory сохранить.

### 5.7. Логирование

Выбор Full/Standard/Compact/Minimal/Off/Errors через ungate-log-settings.json. Смысл — детализация live logger launcher; не путать с quiet у Ungate API или Logs dashboard. Не обещать наличие live tail Beta в dashboard в первой версии: существующая Logs обслуживает API/tunnel.

Сохранение должно быть видно следующему CLI launch и уже работающему logger в той мере, в какой он штатно перечитывает этот файл. Не запускать Watch-CodexActivity в HTTP request и не держать worker ради terminal output.

## 6. Хранение, согласованность и ошибки записи

Источники настроек в настроенном Beta home:

| Файл | Данные |
| --- | --- |
| ungate-model-registry.json | Единственный список активных моделей профиля; version:1. Создаётся из шаблона models.default.json, когда файла ещё нет |
| ungate-model-definitions.json | Устаревший custom registry. Читается только при создании нового реестра и дальше не изменяется |
| ungate-model-overrides.json | Версия, название, контекст, transport prefix, capability overrides; version:1 |
| ungate-picker-models.json | Состав picker; version:1 |
| ungate-memory-settings.json | Настройки памяти; Version:1 |
| ungate-log-settings.json | LogLevel |
| model-capabilities/reports/*.json | Существующие capability reports |
| tool-compatibility/tools-schema-cache.json и reports/ | Штатная TT schema cache и отчёты |

Не редактировать ungate-models.json как пользовательский источник: это генерируемый каталог. Не переносить настройки в dashboard SQLite/localStorage как второй реестр. Сохранение формы меняет только нужный source file, не config.toml, auth.json, MCP, skills, истории или обычный профиль.

Ввести общую межпроцессную блокировку на канонический Beta home для read-modify-write. Все CLI writers тех же файлов должны участвовать; блокировка только внутри HTTP-процесса недостаточна. Не удерживать её во время сетевых diagnostic запросов. Под блокировкой сначала перечитать текущую запись, проверить revision, выполнить merge и validation, затем атомарную запись.

Каждая редактируемая resource имеет revision из актуальных исходных данных. Для capabilities учесть также базовые определения и catalog template, от которых зависят effective значения. UI отправляет expectedRevision. При изменении CLI/другой вкладкой вернуть 409 с текущим безопасным snapshot; сохранить draft, предложить перечитать/повторить изменение. Не применять last-write-wins ко всему файлу.

Patch contract: set с изменяемыми explicit полями и unset с полями для наследования. Один field не может присутствовать в обоих. Неизвестные fields отклонять. Отсутствующий field сохраняет соседнее значение. Массовые resets C/V имеют отдельные allowlisted field sets. Не добавлять универсальный «стереть весь override».

Атомарная запись через temp в той же директории и Replace/Move. Сохранять резервную копию как ручной recovery path. После failure сохранять effective state и evidence, вернуть честный результат и остановить зависимые действия. Не восстанавливать backup автоматически, не стирать failed transaction и не сообщать success при частичном применении. Раздельные Save по ресурсам предпочтительнее общего multi-file Save.

Ошибочный JSON/неподдерживаемая версия файла показываются явно. Не заменять повреждённый файл пустым реестром и не сохранять поверх него defaults. Для settings readers, которые сейчас молча возвращают defaults, добавить management diagnostic metadata без изменения безопасного CLI fallback поведения.

## 7. HTTP и DTO

Все launcher endpoints находятся только в apps/control. Не добавлять их в apps/api, /api/backend allowlist или FRP. Переиспользовать bootstrap CSRF и Host/Origin checks. Launcher reads/reports тоже требуют CSRF, поскольку возвращают пользовательские сведения; существующий общий /api/events остаётся защищённым штатным механизмом loopback/Origin.

Предлагаемый контракт:

| Method/path | Назначение |
| --- | --- |
| GET /api/control/launcher/state | Profile/agent metadata, transports, модели, effective/override данные, picker, memory/log, revisions, latest report summaries |
| POST /api/control/launcher/models/add | Добавление custom модели |
| POST /api/control/launcher/models/version | Patch версии/name/context для registryId |
| POST /api/control/launcher/models/capabilities | Patch возможностей для registryId |
| POST /api/control/launcher/models/reset | registryId и scope: version/capabilities/transport-prefix |
| POST /api/control/launcher/models/remove | Удаление любой модели из реестра; модель убирается из picker, overrides и фоновой настройки |
| POST /api/control/launcher/models/add-template | Копия записи шаблона в конец реестра |
| POST /api/control/launcher/picker | Сохранение выбранных registry IDs |
| POST /api/control/launcher/memories | Сохранение памяти с её правилами validation |
| POST /api/control/launcher/logging | Сохранение LogLevel |
| POST /api/control/launcher/catalog | Discovery по allowlisted transport; при необходимости async operation |
| POST /api/control/launcher/diagnostics | kind: capabilities/tools/memory, registryIds или memory revision; HTTP 202 operation |
| GET /api/control/launcher/operations/:id | Прогресс и terminal result |
| POST /api/control/launcher/operations/:id/cancel | Явная отмена диагностики |
| GET /api/control/launcher/reports/:id | Санитизированный структурированный отчёт |

Registry IDs могут содержать slash, поэтому mutation body содержит registryId, а не неэкранированный ID в URL. Paths reports/operation IDs — opaque identifiers. Нельзя принимать произвольный file path для чтения отчёта.

Request schema требует full JSON Schema для Fastify 5. Booleans должны быть настоящими Boolean, не строками; unknown properties отклонять, не удалять молча и не приводить типы автоматически. При необходимости использовать scoped validator compiler, не менять поведение всех старых маршрутов. DTO и response schema содержат только разрешённые безопасные поля. См. [официальную документацию Fastify: validation/serialization](https://github.com/fastify/fastify/blob/main/docs/Reference/Validation-and-Serialization.md) и [migration guide V5](https://github.com/fastify/fastify/blob/main/docs/Guides/Migration-Guide-V5.md).

Typed error envelope: code, message, безопасные fieldErrors/currentRevision/operationId по необходимости. Различать 400 malformed request, 403 origin/CSRF, 404 unknown resource, 409 stale revision/busy, 422 invalid combination, 503 agent unavailable. Детали upstream failure показывать в диагностике без credentials/raw request bodies.

Расширить shared frontend types отдельными LauncherState/LauncherModel/LauncherPatch/LauncherOperation/LauncherReport. Существующая DashboardOperation описывает target api/tunnel и action start/stop/restart; не записывать туда model diagnostics с фиктивным target. Для SSE добавить отдельный launcher-operation event, обновив DashboardClient подписку и event union; прежние status/log/operation сохранить.

## 8. Диагностика и фоновые операции

Проверки выполняет пользовательский агент через существующие Node runners. Browser не обращается напрямую к gateway и не получает API keys. State read/save не вызывают диагностические запросы.

Capabilities использует codex-model-capabilities.mjs и реальные implementations router/adapters. Контрольный text; синтетическая PNG с правильным ответом по неизвестному вопросу содержимому; original при включении; выбранные reasoning/summary/verbosity; два независимых inert function calls при parallel. Функции не исполнять. Сохранить проверку полного Responses lifecycle, 120 секунд на запрос, 512 output tokens, отсутствие retry.

TT использует codex-tool-compatibility.mjs, штатный schema cache и его provenance. Выбор checkbox по всему реестру, без изменения picker. При отсутствии/невалидности cache показать штатную причину, не генерировать фиктивную schema и не запускать Beta автоматически для её получения. Memory использует codex-memory-preflight.mjs.

Важная найденная неоднородность: Capabilities.psm1 уже получает qualified model через Get-UngateRequestModel; ToolCompatibility.psm1 в исследованном HEAD собирает model напрямую из UpstreamModel. Перед общим UI запуском TT проверить и устранить расхождение через общий route configuration builder. Аналогично проверить memory configuration для qualified моделей. Тесты должны доказать совпадение diagnostic и обычного маршрута; нельзя показывать результат другого provider как проверку выбранного.

Machine-readable runner output реализовать структурированно: использовать exports runners или добавить явный JSON/NDJSON режим, сохранив существующий console mode. Не парсить русский terminal text регулярными выражениями. Прогресс содержит operationId, model, stage, status и безопасную причину; без prompt/tool arguments/PNG data/ключей.

POST возвращает 202 и operationId сразу. Продолжительность диагностики больше существующих backend proxy timeout 15 секунд, control operation timeout 30 секунд и client wait timeout 45 секунд; не увеличивать эти значения глобально. Launcher jobs имеют отдельный deadline по числу probes/models, persistent report и recoverable status. На один профиль выполнять не более одной диагностической job одновременно; повторный запуск явно busy. Повтор HTTP request с тем же requestId не создаёт вторую платную job.

SSE сообщает прогресс; после reload/reconnect UI восстанавливает job через GET status. Разрыв browser connection не отменяет диагностику. Cancel вызывает AbortController/штатное завершение worker; ждёт освобождения принадлежащих ему ресурсов и сохраняет partial report. При crash агента/worker terminal status — interrupted/failed, а не success. Не повторять платные probes автоматически после restart.

Временные router/bridge слушают эксклюзивный порт 0; actual serving PID/service identity и точный HTTP readiness проверяются. Bridge создаётся только для CLIProxy transport. Все собственные серверы закрываются в finally; неизвестные listeners и обычные router/provider services не трогать. Ввод ключей — stdin/in-memory, без аргументов команд, config/report files и логов.

Отдельно показывать verified, parameter_accepted, unsupported, wrong_answer, inconclusive, timeout, provider_error, invalid_response, cancelled. Принятый reasoning/verbosity parameter не доказывает влияние на поведение. Parallel подтверждён только двумя вызовами в одном ответе; один вызов — неподтверждённый результат. HTTP 200 сам по себе не подтверждает image.

Последний report сопоставлять с текущим fingerprint upstream/request model, route, adapter и settings. После изменения показывать «Устарел», включая изменение CLI вне браузера. Сохранять fingerprint реально проверенного snapshot, даже если настройки изменились во время проверки. Проверка не изменяет настройки и не вызывает rollback. Экспорт отчёта содержит только санитизированный JSON.

## 9. Mimo и совместимость

Текущая модель имеет registryId mimo-v2.5-pro, пользовательский upstream mimo-v2.6-pro, название Mimo v2.6 Pro, context 1M, image=true, original=false. UI должен показывать обе идентичности и сохранять текущий override. Не создавать новую v2.6 запись автоматически и не менять builtin v2.5.

Transport prefix в текущем override: openai-compatible-chat-a4d5b027-617b-4d6b-a100-a99e059637e8. Фактический request model — prefix/native upstream. Prefix обязателен для корректного маршрута PNG через имеющееся подключение OmniRoute. Смена версии, Save capabilities, C reset и V reset сохраняют prefix. Не сокращать qualified ID до native ID в DTO->runner conversion.

Старые version:1 файлы без capability fields и старые custom records должны читаться без миграции или массовой перезаписи. Не менять автоматически возможности других моделей и сохранённую memory preference. Shell model aliases, обычный profile sync и текущая маршрутизация остаются функциями launcher.

## 10. Сохранение и применение

После Save UI пишет «Сохранено. Launcher применит настройки при следующем запуске; для обновления Desktop catalog требуется повторный запуск Beta». Сохранение не вызывает restart API/router/bridge/Beta, PrepareOnly, profile sync или MCP validation.

Не показывать «Применено в работающей Beta» по одному факту записи JSON или наличию процесса. Если UI отображает model из config.toml/ungate-models.json, подписать его как подготовленную конфигурацию, а не достоверно загруженную текущей Desktop сессией.

Команда применения использует существующий launcher entry point с корректно экранированными отдельными аргументами. Не вставлять secret -ApiKey. Для пользователя дать краткую инструкцию: дождаться завершения активных запросов, закрыть Beta и запустить команду. Автоматический Desktop restart — отдельный последующий scope.

Если в реализации всё же нужен runtime refresh для внедрения изменённых router/adapters, выполнить fresh drain проверку chatAdmission и adaptiveAdmission: ноль active/heavy/headroom/waiting/queued, с учётом TTL health snapshot 1 секунда. dedup=0 недостаточно. Не убивать активные запросы.

Profile.psm1 ещё содержит MCP transaction rollback по описанию текущего contract. В первой версии UI не вызывает этот путь. При расширении scope до автоматического apply сначала проверить и привести затрагиваемые failure paths к правилу AGENTS.md: forward repair, без автоматического восстановления.

## 11. Файлы и этапы реализации

1. Снять baseline CLI tests и изучить scopes функций через Graphify; подтвердить service/user identity и профиль. Зафиксировать protocol/DTO и resource revisions.
2. Выделить management функции PowerShell и общие writers/lock/validation. Сделать неинтерактивный worker, затем подключить к нему CLI-редакторы без изменения UX shortcuts/номеров.
3. Реализовать user agent и named pipe, onboarding/status, корректный lifecycle собственных workers и отдельные launcher jobs.
4. Добавить launcher endpoints/config в apps/control; shared types — в packages/shared; тесты server/IPC/jobs без live provider requests.
5. Добавить apps/web/src/features/codex-beta/*, api client/store и вкладку App.svelte; сохранить существующие Settings/Analytics/Logs.
6. Подключить структурированные capabilities/TT/memory jobs, reports, stale status и cancellation. Устранить найденную route qualification неоднородность с регрессионными тестами.
7. Обновить docs/desktop-launcher.md, docs/model-routing.md, apps/control/README.md и deployment manifest; выполнить gates и опубликовать change.

Имена новых files могут следовать конвенциям проекта. Ответственность обязательна: PowerShell владеет launcher settings/rules, user agent — правильным Windows context/operations, apps/control — HTTP/security/events, Svelte — forms/drafts/rendering.

## 12. Проверки и критерии приёмки

Pester:

- CLI и UI используют одинаковые effective values, validation и writes; fixtures с временным Codex home.
- Sparse patch/inherit, false vs missing, допустимый null, версии файлов и старые records.
- Независимые reset version/capabilities/prefix, сохранность соседних fields/models и текущего Mimo transport prefix.
- Отмена draft без записи, invalid combinations, parsing failures без затирания evidence.
- Concurrent CLI/UI saves: lock, stale revision 409, отсутствие lost update; serial read-modify-write.
- Picker capacity/order, memory dedicated validation, logging и отсутствие lifecycle/profile side effects у management.

Vitest / Node:

- Control endpoints: CSRF/Host/Origin, строгие DTO, stable registry IDs со slash, reject arbitrary paths/actions, отсутствие ключей в любой response/event/error/report.
- Pipe peer identity/ACL, single agent, agent offline и wrong owner/home; реальная интеграционная проверка user SID <-> LocalSystem для текущей deployment схемы.
- Async job start/reconnect/idempotency/busy/cancel/crash/deadline, partial report, stale snapshot при внешнем CLI edit.
- Qualified Mimo route в capabilities/TT и при соответствующей memory модели; bridge создаётся только для CLIProxy.
- Корректные/оборванные Responses SSE, image answer validation, parallel и классификация failures; переиспользовать существующие runner tests.
- Saving/diagnostics не вызывают NSSM restart, PrepareOnly, Desktop start/stop, MCP sync или обычный profile write.

Browser acceptance на disposable профиле/fake agent:

1. Новая вкладка работает; Analytics/Settings/Logs сохраняют поведение.
2. Отредактировать image/original и version; сохранить, reload UI, прочитать через CLI; обратное изменение CLI отражается после reload/refresh без перезаписи draft.
3. Наследование, sparse override tags, reset C/V и conflict 409 понятны; default reasoning нельзя выбрать вне allowed list.
4. Picker от одной до capacity моделей; memory/log settings сохраняются в свои файлы.
5. Проверка показывает stages/report, переживает reload, отменяется; устаревший report не выглядит актуальным.
6. При agent offline доступны объяснение/команда запуска, а старые dashboard функции продолжают работать.
7. Команда следующего запуска корректна для обычной модели и fallback; не содержит secrets и ничего не запускает при копировании.

Live acceptance после внедрения, отдельными явными действиями:

- UI читает текущую Mimo v2.6 запись с image=true/original=false и сохраняет её без потери upstream/name/context/prefix.
- Запущенная из UI диагностическая PNG правильно распознаётся через сохранённый qualified route; отчёт содержит completed Responses result.
- Пользователь повторно запускает Beta через launcher: изображение прикрепляется и распознаётся, сохранённые параметры сохраняются после смены версии и возврата.
- Негативная диагностика не откатывает settings, не включает memory и не меняет provider/model автоматически.

Синтаксис/quality gates для изменённых файлов: PowerShell Parser.ParseFile; node --check для JS/MJS; профильные Pester/Node/Vitest suites; apps/web check и apps/control check; соответствующий lint; bundle builds; git diff --check.

Команды существующих checks (по затронутому scope):

    pnpm --filter @ungate/scripts run launcher:test
    pnpm --filter @ungate/scripts run capabilities:test
    pnpm --filter @ungate/scripts run tool-compatibility:test
    pnpm --filter @ungate/scripts run memory-preflight:test
    pnpm --filter @ungate/scripts run shell-router:test
    pnpm --filter @ungate/scripts run mimo-adapter:test
    pnpm --filter @ungate/control test
    pnpm --filter @ungate/control check
    pnpm --filter @ungate/web check
    pnpm --filter @ungate/control lint
    pnpm --filter @ungate/web lint
    pnpm --filter @ungate/scripts lint
    pnpm --filter @ungate/control build:bundle
    git diff --check

При изменении bridge — дополнительно bridge:test; при затрагивании DeepSeek adapter — deepseek-adapter:test; при изменении plugin isolation — его tests. Новые проверки включить в package scripts, не оставлять ручными незадокументированными командами.

В текущих smoke-bundle.mjs/smoke-browser.mjs жёстко задан временный порт 47819, а loadConfig не принимает PORT=0. Прежде чем использовать их для новой acceptance, перевести disposable startup на реальное bind port 0 с сообщением assigned port; корректно учесть его в Host/Origin checks. Исключить probe-then-bind, общий browser session и неизвестные listeners. Перед browser URL проверить serving PID и exact HTTP response без proxy. stdout/stderr — stable files, cleanup собственных процессов в finally, bounded lifetime на случай прерывания.

Использовать совместимый runtime/pnpm из проекта; учитывать native SQLite ABI при API regression checks. На машине штатный Node из C:/Program Files/nodejs — ранее проверенный runtime; не менять глобальный Node или package manager ради тестов.

## 13. Внедрение и сдача

После изменения code выполнить graphify update . и опубликовать через project manager согласно AGENTS.md:

    pwsh -NoProfile -File J:/Dev/dev-project-manager/dev-projects.ps1 ungate-local push -m "Add Codex Beta launcher settings to dashboard"

Control build:bundle сам собирает apps/web и копирует frontend в apps/control/bundle/public. Обновить deployment config для user agent/profile, дождаться отсутствия собственных diagnostic jobs, затем перезапустить только ungate-dashboard и проверить /health, HTML, bootstrap, launcher state и browser UI. Смена dashboard bundle не требует restart ungate-api или model router.

Если реально изменён API runtime либо shared runtime code, импортируемый API, отдельно выполнить обязательный project gate: API build, build:bundle, NSSM restart ungate-api и Ungate preflight последовательно. Только types/frontend/scripts changes сами по себе не требуют API restart. Не включать управление Windows desktop в публичный API при любом варианте.

На failure сохранять состояние/логи/backups и выполнять проверенный forward repair; не объявлять внедрение успешным до реальной readiness/acceptance. Final новой сессии должен содержать scope изменений, выполненные tests, состояние публикации/dashboard runtime, инструкцию запуска пользовательского агента и применения settings через launcher, а также точные unresolved blockers, если они остались.
