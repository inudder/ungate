# LOCAL-SETUP.md

Локальный форк `ungate` для разработки без зависимости от маркетплейса.

## Что это

Эта папка — **исходники** расширения `Ungate` (`orchidfiles/ungate` v1.7.1) с вашими ручными правками, **зафиксированные в `local-config/PATCHES-MAP.md`**.

Текущая распакованная установка
`C:\Users\kalvinclein\.cursor\extensions\orchidfiles.ungate-1.7.1\`
**остаётся как есть** — её можно продолжать использовать.

## Что здесь есть

- `apps/`, `packages/`, `scripts/`, `pnpm-workspace.yaml` — стандартный монорепо
- `apps/extension/package.json` — переименовано: `name: "ungate-local"`, `version: "1.7.1-local.0"`, `displayName: "Ungate (Local sources)"`
- `local-config/` — **ваша** часть: снэпшот БД, диффы ваших правок, скрипт восстановления
- `.git/` — git-история оригинального репо (можно использовать как baseline)

## Что НЕ здесь (и где оно)

| Что | Где | Удалять? |
|---|---|---|
| Текущая распакованная установка | `C:\Users\kalvinclein\.cursor\extensions\orchidfiles.ungate-1.7.1\` | НЕТ, пока используется |
| Бэкап распакованной установки | `C:\Users\kalvinclein\.cursor\extensions\orchidfiles.ungate-1.7.1_backup\` | НЕТ, ваша страховка |
| Runtime-данные (БД, токены, бинарь) | `C:\Users\kalvinclein\.ungate\` | НЕТ, рабочая runtime |
| Оригинальные чистые исходники | `C:\Users\kalvinclein\ungate\` | Можно удалить ПОЗЖЕ, когда убедитесь, что `J:\Dev\ungate-local\` полный |
| Cursor settings | `C:\Users\kalvinclein\AppData\Roaming\Cursor\User\` | НЕ ТРОГАТЬ |

## Что внутри `local-config/`

```
local-config/
├── README.md                 ← этот файл (короткий)
├── SOURCE-INFO.md            ← откуда скопировано, версия, sha
├── PATCHES-MAP.md            ← карта ваших ручных правок
├── data.db.snapshot          ← ПОЛНЫЙ снимок ~/.ungate/data.db (СЕКРЕТЫ!)
├── restore-config.ps1        ← скрипт восстановления БД
└── diffs/
    ├── package.json.diff
    ├── wake-ping.ts.recovered.ts   ← восстановленный исходник нового модуля
    ├── server.ts.fragment.txt      ← что вставить в server.ts
    ├── dashboard.ts.fragment.txt   ← что вставить в dashboard.ts
    ├── extension-commands.ts.fragment.txt
    ├── wake-ping.extension.json    ← дефолт (extension-side)
    └── wake-ping.api.json          ← дефолт (api-side)
```

## Что СЕЙЧАС не нужно делать

- **НЕ запускать** `pnpm install` — может понадобиться для билда, но не сейчас
- **НЕ запускать** `pnpm run package:build` — соберёт VSIX, но НЕ перенесёт ваши правки
- **НЕ удалять** текущую распакованную установку
- **НЕ коммитить** `local-config/data.db.snapshot` (он в `.gitignore`)

## Что делать, когда будете готовы к полному переходу

См. `local-config/PATCHES-MAP.md` — там пошаговый план переноса правок в исходники.

Краткий чек-лист:
1. `cd J:\Dev\ungate-local`
2. `pnpm install`
3. Скопировать `local-config/diffs/wake-ping.ts.recovered.ts` → `apps/api/src/wake-ping.ts`
4. Применить фрагменты из `diffs/*.fragment.txt` к соответствующим файлам
5. Добавить `ungate.toggleWakePing` в `apps/extension/package.json` → `contributes.commands`
6. `pnpm run package:build` → получите `apps/extension/out/ungate.vsix`
7. `cursor --install-extension apps/extension/out/ungate.vsix --force`
8. `cursor --uninstall-extension orchidfiles.ungate`
9. В `~/.ungate/data.db` БД уже на месте — подхватится автоматически
10. Опционально: `pin` в Cursor → правой кнопкой по расширению → «Pin Extension»

## Преимущества `J:\Dev\ungate-local\` перед распакованной установкой

- Реальные `.ts` исходники вместо минифицированных `.js` — можно нормально править
- Git-история оригинального репо для `diff` и `blame`
- Все workspace-зависимости (`@ungate/shared`, `@ungate/dev-kit`, `apps/api`, `apps/web`) на месте — можно собрать одной командой
- `local-config/PATCHES-MAP.md` — карта ваших правок, чтобы не потерять
- `local-config/data.db.snapshot` — снимок runtime-БД (включая API-ключи, OAuth-токены, 30 моделей)

## Размер и верификация

- Исходники: ~0.97 МБ (без `node_modules` и `.git`)
- С `.git`: ~1.52 МБ
- `data.db.snapshot`: ~100 КБ
- Сравнение с эталоном (бэкапом) — см. `local-config/PATCHES-MAP.md`
