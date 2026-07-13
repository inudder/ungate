<#
.SYNOPSIS
    Восстанавливает Ungate runtime-БД из снэпшота.

.DESCRIPTION
    Копирует J:\Dev\ungate-local\local-config\data.db.snapshot в
    $env:USERPROFILE\.ungate\data.db, предварительно сделав бэкап существующей.

.PARAMETER SnapshotPath
    Путь к снэпшоту. По умолчанию ищет в <корень репо>\local-config\data.db.snapshot.

.PARAMETER TargetDir
    Куда восстанавливать. По умолчанию $env:USERPROFILE\.ungate.

.PARAMETER Force
    Пропустить подтверждение "вы уверены?".

.EXAMPLE
    .\restore-config.ps1
    .\restore-config.ps1 -Force
    .\restore-config.ps1 -SnapshotPath C:\my\snapshot.db
#>

[CmdletBinding()]
param(
    [string]$SnapshotPath = "",
    [string]$TargetDir = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Определяем корень репо (родитель local-config)
if (-not $SnapshotPath) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepoRoot = Split-Path -Parent $ScriptDir
    $SnapshotPath = Join-Path $RepoRoot "local-config\data.db.snapshot"
}

if (-not $TargetDir) {
    $TargetDir = Join-Path $env:USERPROFILE ".ungate"
}

# Валидация
if (-not (Test-Path -LiteralPath $SnapshotPath)) {
    Write-Error "Снэпшот не найден: $SnapshotPath"
    exit 1
}

$TargetPath = Join-Path $TargetDir "data.db"

# Создать target dir если нет
if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Write-Host "Создал $TargetDir"
}

# Подтверждение
if (-not $Force) {
    if (Test-Path -LiteralPath $TargetPath) {
        $reply = Read-Host "ВНИМАНИЕ: $TargetPath уже существует и будет перезаписан (после бэкапа). Продолжить? [y/N]"
        if ($reply -notmatch '^[Yy]') {
            Write-Host "Отменено."
            exit 0
        }
    }
}

# Бэкап существующего
if (Test-Path -LiteralPath $TargetPath) {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $BackupPath = Join-Path $TargetDir "data.db.bak.$ts"
    Copy-Item -LiteralPath $TargetPath -Destination $BackupPath -Force
    Write-Host "Бэкап: $BackupPath"
}

# Копирование
Copy-Item -LiteralPath $SnapshotPath -Destination $TargetPath -Force
Write-Host "Восстановлено: $TargetPath"

# Верификация через sqlite3 (если доступен)
$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if ($sqlite) {
    Write-Host ""
    Write-Host "=== Содержимое восстановленной БД ==="
    & sqlite3 -header -column $TargetPath "SELECT 'app_settings:' as table, COUNT(*) as rows FROM app_settings UNION ALL SELECT 'model_mappings:', COUNT(*) FROM model_mappings UNION ALL SELECT 'provider_settings:', COUNT(*) FROM provider_settings UNION ALL SELECT 'requests:', COUNT(*) FROM requests;" | Out-String | Write-Host
    Write-Host "=== Порт и API-ключ (длина) ==="
    & sqlite3 -header $TargetPath "SELECT port, length(api_key) as key_len, quiet FROM app_settings;" | Out-String | Write-Host
    Write-Host "=== Провайдеры ==="
    & sqlite3 -header $TargetPath "SELECT provider, email, base_url, length(access_token) as tok_len, datetime(expires_at/1000, 'unixepoch') as expires_at FROM provider_settings;" | Out-String | Write-Host
} else {
    Write-Host "(sqlite3 CLI не найден — пропускаю верификацию)"
    Write-Host "Установите sqlite3 или проверьте вручную: sqlite3 '$TargetPath' 'SELECT COUNT(*) FROM model_mappings;'"
}

Write-Host ""
Write-Host "Готово. Перезапустите Cursor, чтобы расширение подхватило новую БД."
