#requires -Version 7.4
# Toml: internal Desktop launcher module. No per-launch module state.


function Set-TopLevelTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$TomlValue
    )
    $ErrorActionPreference = 'Stop'

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split '\r?\n'))
    $firstTableIndex = $lines.Count
    $found = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[') {
            $firstTableIndex = $index
            break
        }
        if ($lines[$index] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$index] = "$Key = $TomlValue"
            $found = $true
            break
        }
    }

    if (-not $found) {
        $lines.Insert($firstTableIndex, "$Key = $TomlValue")
    }

    return $lines -join "`r`n"
}

function Set-TomlTableValue {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$TomlValue
    )
    $ErrorActionPreference = 'Stop'

    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split '\r?\n'))
    $tableStart = -1
    $tableEnd = $lines.Count
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -notmatch '^\s*\[') { continue }
        if ($tableStart -ge 0) { $tableEnd = $index; break }
        if ($lines[$index] -match "^\s*\[$([regex]::Escape($TableName))\]\s*(?:#.*)?$") {
            $tableStart = $index
        }
    }

    if ($tableStart -lt 0) {
        return $Content.TrimEnd() + "$newline$newline[$TableName]$newline$Key = $TomlValue$newline"
    }
    $keyPattern = "^(\s*$([regex]::Escape($Key))\s*=\s*)[^\s#]+(\s*(?:#.*)?)$"
    for ($index = $tableStart + 1; $index -lt $tableEnd; $index++) {
        if ($lines[$index] -match $keyPattern) {
            $lines[$index] = $Matches[1] + $TomlValue + $Matches[2]
            return $lines -join $newline
        }
    }
    $lines.Insert($tableStart + 1, "$Key = $TomlValue")
    return $lines -join $newline
}

function Remove-TomlTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )
    $ErrorActionPreference = 'Stop'

    $result = [System.Collections.Generic.List[string]]::new()
    $skip = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches[1].Trim()
            if ($currentTable -eq $TableName -or $currentTable.StartsWith("$TableName.")) {
                $skip = $true
                continue
            }
            $skip = $false
        }

        if (-not $skip) {
            $result.Add($line)
        }
    }

    return $result -join "`r`n"
}

function Get-TomlTableFamilyContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )
    $ErrorActionPreference = 'Stop'

    $result = [System.Collections.Generic.List[string]]::new()
    $capture = $false

    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches[1].Trim()
            $capture = (
                $currentTable -eq $TableName -or
                $currentTable.StartsWith("$TableName.", [System.StringComparison]::Ordinal)
            )
        }

        if ($capture) {
            $result.Add($line)
        }
    }

    return ($result -join "`r`n").Trim()
}

Export-ModuleMember -Function @(
    'Set-TopLevelTomlValue',
    'Set-TomlTableValue',
    'Remove-TomlTable',
    'Get-TomlTableFamilyContent'
)
