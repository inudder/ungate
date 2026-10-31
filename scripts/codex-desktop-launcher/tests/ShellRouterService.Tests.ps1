BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ProxyRuntime.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ShellRouterService.psm1') -Force -DisableNameChecking
}

Describe 'Compatibility bridge port discovery' {
    It 'uses the shared TCP endpoint check before starting another bridge' {
        Mock Get-LocalTcpPortListeners -ModuleName ProxyRuntime { [pscustomobject]@{ OwningProcess = 400 } }
        & (Get-Module ProxyRuntime) { Test-LocalTcpListener -Port 8318 } | Should -BeTrue
        Should -Invoke Get-LocalTcpPortListeners -ModuleName ProxyRuntime -Times 1 -Exactly -ParameterFilter { $Port -eq 8318 }
    }
}

Describe 'Shell router service port ownership' {
    BeforeEach {
        $script:routerHealth = [pscustomobject]@{ service = 'codex-model-shell-router'; pid = 300 }
        $script:routerTcp = [pscustomobject]@{
            LocalAddress = '127.0.0.1'; LocalPort = 8319
            RemoteAddress = '0.0.0.0'; RemotePort = 0
            State = 'Listen'; OwningProcess = 300
        }
        $script:routerWrapper = [pscustomobject]@{
            State = 'Running'; ProcessId = 100
            PathName = 'C:\ProgramData\Ungate\shell-router\runtime\nssm.exe'
        }
        $script:routerProcess = [pscustomobject]@{
            ProcessId = 300; ParentProcessId = 200
            ExecutablePath = 'C:\Program Files\nodejs\node.exe'
            CommandLine = 'node.exe C:\ProgramData\Ungate\shell-router\runtime\codex-model-shell-router-service.mjs'
        }
        $script:routerSupervisor = [pscustomobject]@{
            ProcessId = 200; ParentProcessId = 100
            ExecutablePath = 'C:\Program Files\nodejs\node.exe'
            CommandLine = 'node.exe C:\ProgramData\Ungate\shell-router\runtime\codex-shell-router-supervisor.mjs'
        }
        Mock Get-NetTCPConnection -ModuleName ShellRouterService {
            param($State)
            if (-not $State -or $script:routerTcp.State -in $State) { $script:routerTcp }
        }
        Mock Get-CimInstance -ModuleName ShellRouterService {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') { return $script:routerWrapper }
            if ($Filter -eq 'ProcessId=300') { return $script:routerProcess }
            if ($Filter -eq 'ProcessId=200') { return $script:routerSupervisor }
            throw "Unexpected process query: $ClassName $Filter"
        }
    }

    It 'accepts the verified NSSM router with a normal listening state' {
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Not -Throw
    }

    It 'accepts a verified router whose CIM TCP state is zero after Windows boot' {
        $script:routerTcp.State = $null
        $script:routerTcp | Add-Member CimInstanceProperties @{ State = [pscustomobject]@{ Value = 0 } }
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Not -Throw
    }

    It 'accepts a verified router whose unadapted TCP state is zero' {
        $script:routerTcp.State = 0
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Not -Throw
    }

    It 'rejects an unconnected endpoint with state <State>' -ForEach @(
        @{ State = 'Bound' }, @{ State = 'Closed' }, @{ State = $null }
    ) {
        $script:routerTcp.State = $State
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Throw '*not owned*'
    }

    It 'rejects a connection with a remote peer even when the state is zero' {
        $script:routerTcp.State = 0
        $script:routerTcp.RemoteAddress = '127.0.0.1'
        $script:routerTcp.RemotePort = 50000
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Throw '*not owned*'
    }

    It 'rejects a foreign listener that advertises the real router PID' {
        $script:routerTcp.OwningProcess = 400
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Throw '*not owned*'
    }

    It 'rejects ambiguous listener ownership' {
        Mock Get-NetTCPConnection -ModuleName ShellRouterService { $script:routerTcp; $script:routerTcp }
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Throw '*not owned*'
    }

    It 'rejects a listener outside the protected runtime even with TCP state zero' {
        $script:routerTcp.State = 0
        $script:routerProcess.CommandLine = 'node.exe C:\Users\Public\router.mjs'
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Throw '*not the expected NSSM service process*'
    }

    It 'rejects a supervisor outside the NSSM process tree even with TCP state zero' {
        $script:routerTcp.State = 0
        $script:routerSupervisor.ParentProcessId = 999
        { Assert-ShellRouterServiceIdentity -Health $script:routerHealth } | Should -Throw '*not a child*'
    }

    It 'refuses to start the service over a foreign wildcard endpoint with TCP state zero' {
        $script:routerTcp.State = 0
        $script:routerTcp.LocalAddress = '0.0.0.0'
        $script:routerTcp.OwningProcess = 400
        Mock Get-Service -ModuleName ShellRouterService { [pscustomobject]@{ Status = 'Stopped' } }
        Mock Start-Service -ModuleName ShellRouterService {}
        Mock Get-ShellRouterServiceHealth -ModuleName ShellRouterService { $script:routerHealth }
        { Start-ShellRouterServiceIfNeeded } | Should -Throw '*occupied*'
        Should -Invoke Start-Service -ModuleName ShellRouterService -Times 0 -Exactly
    }
}
