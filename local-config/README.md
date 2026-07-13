# local-config/

Эта папка содержит **только локальные, не подлежащие коммиту** артефакты:
снэпшот runtime-БД, диффы ваших ручных правок и скрипт восстановления.

## ⚠️ Секреты

`data.db.snapshot` — это **полный снимок** `~/.ungate/data.db` **со всеми секретами**:
- API-ключ Ungate-прокси (`app_settings.api_key`)
- OAuth-токены Claude (`provider_settings.access_token`, `refresh_token`)
- (в будущем — ключи MiniMax, OpenAI и т.п., если добавите провайдеров)

**НЕ КОММИТЬТЕ** эту папку в публичный git. Файл `data.db.snapshot` уже в
`.gitignore` верхнего уровня. Если добавите свои секреты — добавьте их тоже.

## Состав

| Файл | Назначение | Чувствительный? |
|---|---|---|
| `README.md` | Этот файл | Нет |
| `SOURCE-INFO.md` | Метаданные копирования (откуда, когда, sha) | Нет |
| `PATCHES-MAP.md` | Карта ваших ручных правок | Нет |
| `data.db.snapshot` | Полный снимок `~/.ungate/data.db` | **ДА — секреты!** |
| `restore-config.ps1` | Скрипт восстановления БД | Нет (но требует секрет) |
| `diffs/package.json.diff` | Минимальный diff package.json | Нет |
| `diffs/wake-ping.ts.recovered.ts` | Восстановленный исходник wake-ping.ts | Нет |
| `diffs/server.ts.fragment.txt` | Что вставить в server.ts | Нет |
| `diffs/dashboard.ts.fragment.txt` | Что вставить в dashboard.ts | Нет |
| `diffs/extension-commands.ts.fragment.txt` | Что добавить в extension-commands.ts | Нет |
| `diffs/wake-ping.extension.json` | Дефолтный конфиг (extension-side) | Нет |
| `diffs/wake-ping.api.json` | Дефолтный конфиг (api-side) | Нет |

## Что внутри `data.db.snapshot`

Извлечено `2026-06-17` из `C:\Users\kalvinclein\.ungate\data.db`:

- `app_settings`: port=47821, api_key=`<16 hex>`, quiet=0
- `model_mappings`: 30 моделей (Claude, OpenAI, без MiniMax)
- `provider_settings`: Claude OAuth (access+refresh, expires 2026-06-16)
- `requests`: 983 записи, 0 ошибок
- `__drizzle_migrations`: все 6 миграций применены

## Как восстановить (если что-то сломалось)

Из корня `J:\Dev\ungate-local\`:

```powershell
powershell -ExecutionPolicy Bypass -File local-config\restore-config.ps1
```

Скрипт:
1. Проверит, что `local-config/data.db.snapshot` существует
2. Если `~/.ungate/data.db` уже есть — сделает бэкап `data.db.bak.<timestamp>`
3. Скопирует снэпшот в `~/.ungate/data.db`
4. Напечатает итог (N моделей, N провайдеров, N запросов)

## Если хотите **обновить** снэпшот (например, добавили нового провайдера)

```powershell
Copy-Item -LiteralPath "$env:USERPROFILE\.ungate\data.db" -Destination "J:\Dev\ungate-local\local-config\data.db.snapshot" -Force
```

⚠️ После обновления снэпшота перепишется файл с **новыми** секретами. Убедитесь,
что `.gitignore` по-прежнему его исключает (он там).
