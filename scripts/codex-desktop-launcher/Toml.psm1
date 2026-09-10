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
    'Remove-TomlTable',
    'Get-TomlTableFamilyContent'
)
