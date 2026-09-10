#requires -Version 7.4
# Routing: internal Desktop launcher module. No per-launch module state.
Import-Module (Join-Path $PSScriptRoot 'Toml.psm1') -DisableNameChecking -ErrorAction Stop

function Get-ProviderDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'

    $byName = [ordered]@{}
    foreach ($definition in $Selection.Definitions) {
        if (-not $byName.Contains($definition.ProviderName)) {
            $byName[$definition.ProviderName] = [pscustomobject][ordered]@{
                Name = $definition.ProviderName
                DisplayName = $definition.ProviderDisplayName
                ProxyBaseUrl = $definition.ProxyBaseUrl
                EnvKey = $definition.EnvKey
            }
        }
    }
    return @($byName.Values)
}

function Set-CodexModelShellSlugs {
    param(
        [Parameter(Mandatory)][psobject]$Context,

        [Parameter(Mandatory = $true)]
        [object[]]$Definitions
    )
    $ErrorActionPreference = 'Stop'

    if ($Context.CodexModelShellPool.Count -lt $Context.CodexDesktopPickerCapacity) {
        throw "Codex shell pool has $($Context.CodexModelShellPool.Count) slots, but the picker requires $($Context.CodexDesktopPickerCapacity)."
    }
    if ($Definitions.Count -gt $Context.CodexDesktopPickerCapacity) {
        throw "Codex Beta can expose at most $($Context.CodexDesktopPickerCapacity) custom provider models in its native picker. Remove a model or increase the picker capacity."
    }

    $withShellSlugs = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Definitions.Count; $index++) {
        $properties = [ordered]@{}
        foreach ($property in $Definitions[$index].PSObject.Properties) {
            $properties[$property.Name] = $property.Value
        }
        $properties['ShellSlug'] = $Context.CodexModelShellPool[$index]
        [void]$withShellSlugs.Add([pscustomobject]$properties)
    }

    return @($withShellSlugs)
}

function Get-CodexCatalogModelSlug {
    param(
        [Parameter(Mandatory)][psobject]$Selection,

        [Parameter(Mandatory = $true)]
        [object]$Definition
    )
    $ErrorActionPreference = 'Stop'

    if ($Selection.EnableProviderFallback) {
        return [string]$Definition.Slug
    }

    if (-not $Definition.PSObject.Properties['ShellSlug'] -or [string]::IsNullOrWhiteSpace($Definition.ShellSlug)) {
        throw "Model '$($Definition.Slug)' does not have a Codex shell model ID."
    }

    return [string]$Definition.ShellSlug
}

function Get-CodexConfigProviderDefinitions {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'

    if ($Selection.EnableProviderFallback) {
        return @(
            [pscustomobject][ordered]@{
                Name = $Selection.FallbackDefinition.ProviderName
                DisplayName = $Selection.FallbackDefinition.ProviderDisplayName
                ProxyBaseUrl = $Selection.FallbackDefinition.ProxyBaseUrl
                EnvKey = $Selection.FallbackDefinition.EnvKey
            }
        )
    }

    return @($Context.CodexModelShellRouterProviderDefinition)
}

function Get-CodexModelShellRoutes {
    param(
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'

    $routes = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $Selection.Definitions) {
        $shellSlug = Get-CodexCatalogModelSlug -Selection $Selection -Definition $definition
        $upstreamModelValue = if ($definition.PSObject.Properties['UpstreamModel'] -and $definition.UpstreamModel) {
            [string]$definition.UpstreamModel
        } else {
            [string]$definition.Slug
        }
        [void]$routes.Add([ordered]@{
            clientModel = $shellSlug
            upstreamModel = $upstreamModelValue
            upstreamBaseUrl = [string]$definition.ProxyBaseUrl
            apiKeyEnv = [string]$definition.EnvKey
            responsesAdapter = if ($definition.PSObject.Properties['ResponsesAdapter']) { [string]$definition.ResponsesAdapter } else { $null }
        })
    }

    return @($routes)
}

function Get-ProviderTomlBlock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Provider
    )
    $ErrorActionPreference = 'Stop'

    return @"

[model_providers.$($Provider.Name)]
name = "$($Provider.DisplayName)"
base_url = "$($Provider.ProxyBaseUrl)/v1"
env_key = "$($Provider.EnvKey)"
wire_api = "responses"
"@
}

function Ensure-ModelProvidersInConfig {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    $ErrorActionPreference = 'Stop'

    $updated = $Content
    $managedProviderNames = @(
        $Context.ProviderName,
        $Context.CliProxyProviderName,
        $Context.OmniRouteProviderName,
        $Context.CodexModelShellRouterProviderName
    )
    foreach ($providerNameToRemove in $managedProviderNames) {
        $updated = Remove-TomlTable -Content $updated -TableName "model_providers.$providerNameToRemove"
    }
    foreach ($provider in (Get-CodexConfigProviderDefinitions -Context $Context -Selection $Selection)) {
        $updated = Remove-TomlTable -Content $updated -TableName "model_providers.$($provider.Name)"
        $updated = $updated.TrimEnd() + "`r`n" + (Get-ProviderTomlBlock -Provider $provider).TrimStart() + "`r`n"
    }
    return $updated
}

Export-ModuleMember -Function @(
    'Get-ProviderDefinitions',
    'Set-CodexModelShellSlugs',
    'Get-CodexCatalogModelSlug',
    'Get-CodexConfigProviderDefinitions',
    'Get-CodexModelShellRoutes',
    'Ensure-ModelProvidersInConfig'
)
