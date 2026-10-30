BeforeAll {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $moduleRoot 'Context.psm1') -DisableNameChecking
    Import-Module (Join-Path $moduleRoot 'Launcher.psm1') -DisableNameChecking
}

Describe 'Standalone output-limit commands' {
    BeforeEach {
        Mock -ModuleName Launcher Get-CodexBetaPackageInfo { throw 'Must not discover or stop Desktop' }
        Mock -ModuleName Launcher Get-UngateModelDefinitions { @([pscustomobject]@{ Slug = 'test'; UpstreamModel = 'test'; Aliases = @() }) }
        Mock -ModuleName Launcher Invoke-UngateOutputLimits { return 2 }
    }
    It 'passes standalone check status through without touching Desktop' {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome $TestDrive -LaunchParameters @{ CheckOutputLimits = $true; Model = 'test' }
        Invoke-CodexDesktopLauncher -Context $context | Should -Be 2
        Should -Invoke -ModuleName Launcher Invoke-UngateOutputLimits -Times 1 -ParameterFilter { -not $Probe }
        Should -Invoke -ModuleName Launcher Get-CodexBetaPackageInfo -Times 0
    }
    It 'requires one explicit model for paid tests and rejects conflicting launch modes' {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome $TestDrive -LaunchParameters @{ TestOutputLimits = $true }
        { Invoke-CodexDesktopLauncher -Context $context } | Should -Throw '*requires -Model*'
        $context = New-CodexDesktopLaunchContext -CustomCodexHome $TestDrive -LaunchParameters @{ CheckOutputLimits = $true; PrepareOnly = $true }
        { Invoke-CodexDesktopLauncher -Context $context } | Should -Throw '*cannot be combined*'
    }
    It 'rejects paid options attached to a read-only check' {
        $context = New-CodexDesktopLaunchContext -CustomCodexHome $TestDrive -LaunchParameters @{ CheckOutputLimits = $true; FullOutputTest = $true }
        { Invoke-CodexDesktopLauncher -Context $context } | Should -Throw '*require -TestOutputLimits*'
    }
}
