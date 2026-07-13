# SOURCE-INFO.md

Метаданные исходного копирования.

## Источник

| Поле | Значение |
|---|---|
| Откуда | `C:\Users\kalvinclein\ungate\` |
| Дата копирования | 2026-06-17 |
| Способ копирования | `robocopy /E /XD node_modules` (многопоточно) |
| Исключено | `node_modules/` (все вложенные), `*.log` |
| Сохранено | `.git/` (для истории), `.husky/`, `.vscode/`, `pnpm-lock.yaml`, `LICENSE` |

## Версия

| Поле | Значение |
|---|---|
| upstream version | `1.7.1` (см. `apps/extension/package.json` оригинала, поле `version`) |
| local name | `ungate-local` (переименовано) |
| local version | `1.7.1-local.0` (переименовано) |
| publisher | `orchidfiles` (не менялось — чтобы локальный билд имел ID `orchidfiles.ungate-local`, отличный от маркетплейсного `orchidfiles.ungate`) |
| displayName | `Ungate (Local sources)` (переименовано) |

## Целостность

| Файл | SHA-256 (source) | SHA-256 (destination) |
|---|---|---|
| `apps/extension/package.json` | до редактирования (см. коммит) | `5AE56847C809C6AB911415E1AF5203C11373323F5800856F233D41A01A4154D7` (после переименования) |

> SHA-256 в колонке «destination» — **после** правки `name`/`version`/`displayName`,
> поэтому не совпадает с source. Это нормально.

## Объём

| Что | Размер |
|---|---|
| Все скопированные файлы | 1.52 МБ (включая `.git`) |
| Только исходники (без `.git`) | 0.97 МБ |
| `data.db.snapshot` (отдельно) | 100 КБ |

## Сравнение с распакованной установкой (baseline)

| Файл (в установке) | SHA-256 | Δ байт | Где описание |
|---|---|---|---|
| `package.json` | — | +91 | `diffs/package.json.diff` |
| `dist/extension.js` | `F34804A165D6364DAE132BE6F43C0E66B9485D9D628B31D22331C3FF30E2127B` | +6 138 | см. `PATCHES-MAP.md` пп. 4-5 |
| `bundled/api/bundle/main.cjs` | `4AFA4352401A5D45DBFD334BB85F003A2CC2234681E5504B1756A6A511799EB8` | +4 449 | см. `PATCHES-MAP.md` пп. 2-3 |
| `bundled/wake-ping.json` | — | NEW | `diffs/wake-ping.extension.json` |
| `bundled/api/wake-ping.json` | — | NEW | `diffs/wake-ping.api.json` |
| `resources/icon.png` | `456984D4FAD38838A3B85C052019D57878385A9A2C08C849ABD7A0221A63139C` | 0 | без изменений |
| `bundled/web/dist/*` | (идентично) | 0 | без изменений |

## Что НЕ копировалось

- `node_modules/` (все вложенные) — будет пересоздан при `pnpm install`
- `*.log` — runtime-логи
- `apps/extension/out/` (в source этого нет — генерится билдом)
- `apps/extension/dist/` (в source этого нет — генерится билдом)
- `apps/extension/bundled/` (в source этого нет — генерится билдом)
