#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PipeName,
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$WorkingDirectory
)

$ErrorActionPreference = 'Stop'

$pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
    '.',
    $PipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::None
)
try {
    $pipe.Connect(15000)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $reader = [System.IO.StreamReader]::new($pipe, $encoding, $false, 1024, $true)
    $writer = [System.IO.StreamWriter]::new($pipe, $encoding, 1024, $true)
    $writer.AutoFlush = $true
    try {
        $payload = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($payload)) {
            throw 'The package launcher did not receive its environment payload.'
        }

        # Payload: {"Environment":{...},"Arguments":[...]}; arguments arrive here to avoid command-line quoting.
        $payloadValues = $payload | ConvertFrom-Json -AsHashtable
        $launchEnvironment = @{}
        foreach ($entry in $payloadValues['Environment'].GetEnumerator()) {
            $launchEnvironment[[string]$entry.Key] = [string]$entry.Value
        }
        $arguments = @($payloadValues['Arguments'] | Where-Object { $_ } | ForEach-Object { [string]$_ })

        $startParams = @{
            FilePath = $ExecutablePath
            WorkingDirectory = $WorkingDirectory
            Environment = $launchEnvironment
            PassThru = $true
            ErrorAction = 'Stop'
        }
        if ($arguments.Count -gt 0) {
            $startParams['ArgumentList'] = $arguments
        }

        $process = Start-Process @startParams
        $writer.WriteLine("OK:$($process.Id)")
    }
    catch {
        $writer.WriteLine("ERROR:$($_.Exception.Message)")
        throw
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
    }
}
finally {
    $pipe.Dispose()
}
