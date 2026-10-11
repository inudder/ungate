Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -DisableNameChecking -ErrorAction Stop

function Format-UngateTokenCount {
    param([Parameter(Mandatory)][long]$Value)
    $text = [string]$Value
    $parts = [System.Collections.Generic.List[string]]::new()
    while ($text.Length -gt 3) {
        $parts.Insert(0, $text.Substring($text.Length - 3, 3))
        $text = $text.Substring(0, $text.Length - 3)
    }
    $parts.Insert(0, $text)
    return ($parts -join ' ')
}

function Get-OmniRouteDefaultDatabasePath {
    $legacy = Join-Path $env:USERPROFILE '.omniroute'
    $root = if (Test-Path -LiteralPath $legacy -PathType Container) {
        $legacy
    } else {
        Join-Path $env:APPDATA 'OmniRoute'
    }
    return (Join-Path $root 'storage.sqlite')
}

function Read-OmniRouteProcessEnvironment {
    param([Parameter(Mandatory)][int]$ProcessId)
    $ErrorActionPreference = 'Stop'
    if (-not ('Ungate.OmniRouteProcessEnvironment' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Ungate {
    public static class OmniRouteProcessEnvironment {
        const uint ProcessQueryInformation = 0x0400;
        const uint ProcessVmRead = 0x0010;
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessBasicInformation {
            public IntPtr Reserved1;
            public IntPtr PebBaseAddress;
            public IntPtr Reserved2_0;
            public IntPtr Reserved2_1;
            public IntPtr UniqueProcessId;
            public IntPtr InheritedFromUniqueProcessId;
        }
        [DllImport("ntdll.dll")]
        static extern int NtQueryInformationProcess(IntPtr process, int pic, ref ProcessBasicInformation info, int length, out int returned);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, int size, out int read);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);
        static IntPtr ReadPointer(IntPtr process, IntPtr address) {
            byte[] buffer = new byte[8];
            int read;
            if (!ReadProcessMemory(process, address, buffer, 8, out read) || read != 8) return IntPtr.Zero;
            return (IntPtr)BitConverter.ToInt64(buffer, 0);
        }
        public static string ReadBlock(int pid) {
            if (IntPtr.Size != 8) return null;
            IntPtr handle = OpenProcess(ProcessQueryInformation | ProcessVmRead, false, pid);
            if (handle == IntPtr.Zero) return null;
            try {
                ProcessBasicInformation info = new ProcessBasicInformation();
                int returned;
                int status = NtQueryInformationProcess(handle, 0, ref info, Marshal.SizeOf(typeof(ProcessBasicInformation)), out returned);
                if (status != 0 || info.PebBaseAddress == IntPtr.Zero) return null;
                IntPtr parameters = ReadPointer(handle, info.PebBaseAddress + 0x20);
                if (parameters == IntPtr.Zero) return null;
                IntPtr environment = ReadPointer(handle, parameters + 0x80);
                if (environment == IntPtr.Zero) return null;
                byte[] sizeBuffer = new byte[8];
                int sizeRead;
                int length = 262144;
                if (ReadProcessMemory(handle, parameters + 0x3F0, sizeBuffer, 8, out sizeRead) && sizeRead == 8) {
                    long reported = BitConverter.ToInt64(sizeBuffer, 0);
                    if (reported >= 4 && reported <= 4194304) length = (int)reported;
                }
                byte[] buffer = new byte[length];
                int read;
                if (!ReadProcessMemory(handle, environment, buffer, buffer.Length, out read) || read < 4) return null;
                int end = -1;
                for (int index = 0; index + 3 < read; index += 2) {
                    if (buffer[index] == 0 && buffer[index + 1] == 0 && buffer[index + 2] == 0 && buffer[index + 3] == 0) {
                        end = index;
                        break;
                    }
                }
                if (end < 0) return null;
                return Encoding.Unicode.GetString(buffer, 0, end);
            } finally {
                CloseHandle(handle);
            }
        }
    }
}
'@
    }
    $block = [Ungate.OmniRouteProcessEnvironment]::ReadBlock($ProcessId)
    if ([string]::IsNullOrEmpty($block)) { return $null }
    $allowed = @{}
    foreach ($entry in ($block -split [char]0)) {
        $separator = $entry.IndexOf('=')
        if ($separator -lt 1) { continue }
        $name = $entry.Substring(0, $separator)
        if ($name -notmatch '^(CONTEXT_LENGTH_[A-Z0-9_]+|DATA_DIR|DISABLE_CONTEXT_WINDOW_CHECKS)$') { continue }
        $allowed[$name] = $entry.Substring($separator + 1)
    }
    return $allowed
}

function Read-OmniRouteListenerEnvironment {
    $ErrorActionPreference = 'Stop'
    try {
        $connections = @(Get-NetTCPConnection -LocalPort 20128 -State Listen -ErrorAction Stop)
    } catch {
        return $null
    }
    $listener = $connections |
        Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::') -and $_.OwningProcess -gt 0 } |
        Select-Object -First 1
    if (-not $listener) { return $null }
    try {
        return (Read-OmniRouteProcessEnvironment -ProcessId ([int]$listener.OwningProcess))
    } catch {
        return $null
    }
}

function Get-OmniRouteContextLimitReport {
    param(
        [Parameter(Mandatory)][string]$Route,
        [string]$DatabasePath,
        [hashtable]$ListenerEnv = @{},
        [bool]$ListenerEnvReadable = $true,
        [hashtable]$StaticCatalog,
        [hashtable]$Fixture,
        [switch]$StaticProbe,
        [string]$AppRoot
    )
    $ErrorActionPreference = 'Stop'
    if (-not $AppRoot) {
        $AppRoot = Join-Path $env:LOCALAPPDATA 'Programs\OmniRoute\resources\app'
    }
    $request = [ordered]@{
        route = $Route
        dbPath = $DatabasePath
        listenerEnvReadable = [bool]$ListenerEnvReadable
        listenerEnv = $ListenerEnv
        appRoot = $AppRoot
        staticProbe = [bool]$StaticProbe
    }
    if ($StaticCatalog) { $request.staticCatalog = $StaticCatalog }
    if ($Fixture) { $request.fixture = $Fixture }
    $helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'omniroute-context-limit.mjs'
    $requestPath = Join-Path ([IO.Path]::GetTempPath()) ('ungate-omniroute-context-' + [guid]::NewGuid().ToString('n') + '.json')
    $previousLiveDatabase = $env:OMNIROUTE_LIVE_DATABASE
    $previousNodeWarnings = $env:NODE_NO_WARNINGS
    try {
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Compress -Depth 12), [Text.UTF8Encoding]::new($false))
        if ($DatabasePath) { $env:OMNIROUTE_LIVE_DATABASE = $DatabasePath }
        $env:NODE_NO_WARNINGS = '1'
        $output = & node $helper $requestPath
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$output)) { return $null }
        return (($output | Out-String).Trim() | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        if ($null -eq $previousLiveDatabase) {
            Remove-Item Env:OMNIROUTE_LIVE_DATABASE -ErrorAction SilentlyContinue
        } else {
            $env:OMNIROUTE_LIVE_DATABASE = $previousLiveDatabase
        }
        if ($null -eq $previousNodeWarnings) {
            Remove-Item Env:NODE_NO_WARNINGS -ErrorAction SilentlyContinue
        } else {
            $env:NODE_NO_WARNINGS = $previousNodeWarnings
        }
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    }
}

function Format-OmniRouteLimitRoute {
    param([string]$SelectedRoute, [string]$TargetRoute)
    if ($TargetRoute -and $TargetRoute -ne $SelectedRoute) { return "$SelectedRoute → $TargetRoute" }
    return $SelectedRoute
}

function Assert-OmniRouteDesktopContextLimit {
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][psobject]$Selection
    )
    $ErrorActionPreference = 'Stop'
    $usesOmniRoute = [bool]$Selection.EnableProviderFallback -or (
        $Selection.SelectedModel.PSObject.Properties['ProviderName'] -and
        $Selection.SelectedModel.ProviderName -eq $Context.OmniRouteProviderName
    )
    if (-not $usesOmniRoute) {
        return [pscustomobject]@{ Status = 'skipped' }
    }
    $route = Get-UngateRequestModel -Definition $Selection.SelectedModel
    $expected = [long](Get-UngateModelContextWindow -Definition $Selection.SelectedModel).ContextWindow
    $displayName = [string]$Selection.SelectedModel.DisplayName
    $listener = Read-OmniRouteListenerEnvironment
    if ($null -eq $listener) {
        Write-Warning 'лимит контекста не подтверждён'
        return [pscustomobject]@{ Status = 'unconfirmed' }
    }
    $database = if ($listener.ContainsKey('DATA_DIR') -and -not [string]::IsNullOrWhiteSpace([string]$listener['DATA_DIR'])) {
        Join-Path ([string]$listener['DATA_DIR']) 'storage.sqlite'
    } else {
        Get-OmniRouteDefaultDatabasePath
    }
    $report = Get-OmniRouteContextLimitReport -Route $route -DatabasePath $database -ListenerEnv $listener
    if ($null -eq $report -or $report.status -eq 'unconfirmed') {
        Write-Warning 'лимит контекста не подтверждён'
        return [pscustomobject]@{ Status = 'unconfirmed' }
    }
    if ($report.status -eq 'checks-disabled') {
        Write-Host '[ungate] OmniRoute context-window checks are disabled; numeric limit is not enforced.' -ForegroundColor DarkGray
        return [pscustomobject]@{ Status = 'checks-disabled' }
    }
    if ($report.status -ne 'confirmed' -or -not $report.targets) {
        Write-Warning 'лимит контекста не подтверждён'
        return [pscustomobject]@{ Status = 'unconfirmed' }
    }
    $failures = [System.Collections.Generic.List[object]]::new()
    foreach ($target in @($report.targets)) {
        $shownRoute = Format-OmniRouteLimitRoute -SelectedRoute $route -TargetRoute ([string]$target.route)
        if ($null -eq $target.context -or $null -eq $target.context.limit) {
            Write-Warning 'лимит контекста не подтверждён'
            return [pscustomobject]@{ Status = 'unconfirmed' }
        }
        $contextLimit = [long]$target.context.limit
        if ($contextLimit -lt $expected) {
            $failures.Add([pscustomobject]@{ Kind = 'context'; Route = $shownRoute; Limit = $contextLimit; Source = [string]$target.context.source })
        }
        if ($null -ne $target.maxInput -and $null -ne $target.maxInput.limit) {
            $inputLimit = [long]$target.maxInput.limit
            if ($inputLimit -lt $expected) {
                $failures.Add([pscustomobject]@{ Kind = 'input'; Route = $shownRoute; Limit = $inputLimit; Source = [string]$target.maxInput.source })
            }
        }
    }
    if ($failures.Count -eq 0) {
        if ($report.combo) {
            Write-Host "[ungate] OmniRoute combo '$route' members cover launcher window $(Format-UngateTokenCount $expected)." -ForegroundColor DarkGray
        } else {
            $only = @($report.targets)[0]
            Write-Host "[ungate] OmniRoute context window $(Format-UngateTokenCount ([long]$only.context.limit)) ($($only.context.source)) covers launcher window $(Format-UngateTokenCount $expected) for '$route'." -ForegroundColor DarkGray
        }
        return [pscustomobject]@{ Status = 'ok' }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Запуск отменён: $displayName.")
    $lines.Add("Launcher: $(Format-UngateTokenCount $expected) токенов.")
    foreach ($failure in $failures) {
        if ($failure.Kind -eq 'context') {
            $lines.Add("OmniRoute: $(Format-UngateTokenCount $failure.Limit) токенов ($($failure.Source)).")
        } else {
            $lines.Add("OmniRoute max_input_tokens: $(Format-UngateTokenCount $failure.Limit) ($($failure.Source)).")
        }
        $lines.Add("Маршрут: $($failure.Route).")
    }
    $lines.Add('Увеличьте Context Window Override в OmniRoute либо измените окно модели в launcher.')
    Write-Host ($lines -join [Environment]::NewLine) -ForegroundColor Red
    return [pscustomobject]@{ Status = 'blocked' }
}

Export-ModuleMember -Function @(
    'Assert-OmniRouteDesktopContextLimit',
    'Get-OmniRouteContextLimitReport',
    'Read-OmniRouteListenerEnvironment',
    'Read-OmniRouteProcessEnvironment'
)
