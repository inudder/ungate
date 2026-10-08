# Raw-catalog CLI substitute; reads only the disposable test profile.
if ($args[0] -ne 'debug' -or $args[1] -ne 'models') {
    throw 'fixture CLI received an unexpected command'
}
$global:LASTEXITCODE = 0
if ($args -contains '--help') {
    'Print the raw model catalog'
    return
}
$catalogPath = Join-Path $env:CODEX_HOME 'resolved-models.json'
if (-not (Test-Path -LiteralPath $catalogPath)) {
    $catalogPath = Join-Path $env:CODEX_HOME 'ungate-models.json'
}
Get-Content -LiteralPath $catalogPath -Raw
