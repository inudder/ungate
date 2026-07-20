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

        $launchEnvironment = @{}
        $environmentValues = $payload | ConvertFrom-Json -AsHashtable
        foreach ($entry in $environmentValues.GetEnumerator()) {
            $launchEnvironment[[string]$entry.Key] = [string]$entry.Value
        }

        $process = Start-Process `
            -FilePath $ExecutablePath `
            -WorkingDirectory $WorkingDirectory `
            -Environment $launchEnvironment `
            -PassThru `
            -ErrorAction Stop
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
