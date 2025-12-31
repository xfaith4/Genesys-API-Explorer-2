$script:UxTelemetryState = @{
    Path            = $null
    SessionId       = $null
    Writer          = $null
    Buffer          = New-Object System.Collections.Generic.List[string]
    BufferThreshold = 5
    FlushTimer      = $null
}

function Get-UxTelemetryDefaultPath {
    param(
        [string]$RootPath
    )

    if ($RootPath -and -not (Test-Path -LiteralPath $RootPath)) {
        try {
            New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
        }
        catch {
            Write-Verbose "Telemetry root invalid or inaccessible: $RootPath"
            $RootPath = $null
        }
    }

    $targetRoot = if ($RootPath) { $RootPath } else { Join-Path -Path (Get-Location) -ChildPath 'artifacts/ux-simulations' }
    $targetDir = Join-Path -Path $targetRoot -ChildPath 'runs'
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $stamp = (Get-Date).ToString('yyyyMMdd')
    return Join-Path -Path $targetDir -ChildPath "telemetry-$stamp.jsonl"
}

function Initialize-UxTelemetry {
    param(
        [Parameter()]
        [string]$TargetPath,

        [Parameter()]
        [string]$SessionId
    )

    $resolvedPath = if ($TargetPath) { $TargetPath } else { Get-UxTelemetryDefaultPath -RootPath $null }

    try {
        $dir = Split-Path -Parent $resolvedPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        if ($script:UxTelemetryState.Writer) {
            $script:UxTelemetryState.Writer.Flush()
            $script:UxTelemetryState.Writer.Dispose()
        }
        if ($script:UxTelemetryState.FlushTimer) {
            $script:UxTelemetryState.FlushTimer.Stop()
            $script:UxTelemetryState.FlushTimer.Dispose()
        }

        $script:UxTelemetryState.Path = $resolvedPath
        $writer = New-Object System.IO.StreamWriter($resolvedPath, $true, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $false
        $script:UxTelemetryState.Writer = $writer
        $script:UxTelemetryState.Buffer = New-Object System.Collections.Generic.List[string]

        $timer = New-Object System.Timers.Timer 4000
        $timer.AutoReset = $true
        $timer.add_Elapsed({ Flush-UxTelemetryBuffer })
        $timer.Start()
        $script:UxTelemetryState.FlushTimer = $timer
    }
    catch {
        $script:UxTelemetryState.Path = $null
        if ($script:UxTelemetryState.Writer) {
            $script:UxTelemetryState.Writer.Dispose()
            $script:UxTelemetryState.Writer = $null
        }
        if ($script:UxTelemetryState.FlushTimer) {
            $script:UxTelemetryState.FlushTimer.Stop()
            $script:UxTelemetryState.FlushTimer.Dispose()
            $script:UxTelemetryState.FlushTimer = $null
        }
        Write-Verbose "Telemetry initialization failed: $($_.Exception.Message)"
    }

    if (-not $SessionId) {
        $SessionId = [guid]::NewGuid().ToString()
    }
    $script:UxTelemetryState.SessionId = $SessionId
}

function Flush-UxTelemetryBuffer {
    if (-not $script:UxTelemetryState.Buffer -or $script:UxTelemetryState.Buffer.Count -eq 0) { return }

    $lines = $script:UxTelemetryState.Buffer
    $script:UxTelemetryState.Buffer = New-Object System.Collections.Generic.List[string]

    try {
        if ($script:UxTelemetryState.Writer) {
            foreach ($line in $lines) {
                $script:UxTelemetryState.Writer.WriteLine($line)
            }
            $script:UxTelemetryState.Writer.Flush()
        }
        elseif ($script:UxTelemetryState.Path) {
            [System.IO.File]::AppendAllLines($script:UxTelemetryState.Path, $lines, [System.Text.Encoding]::UTF8)
        }
    }
    catch {
        Write-Verbose "Telemetry flush failed: $($_.Exception.Message)"
    }
}

function Write-UxEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [hashtable]$Properties
    )

    if (-not $script:UxTelemetryState.Path -or -not $script:UxTelemetryState.SessionId) { return }

    $payload = [ordered]@{
        ts      = (Get-Date).ToString('o')
        session = $script:UxTelemetryState.SessionId
        event   = $Name
        props   = $Properties
    }

    try {
        $line = ($payload | ConvertTo-Json -Depth 6 -Compress)
        $null = $script:UxTelemetryState.Buffer.Add($line)
        if ($script:UxTelemetryState.Buffer.Count -ge $script:UxTelemetryState.BufferThreshold) {
            Flush-UxTelemetryBuffer
        }
    }
    catch {
        Write-Verbose "Telemetry write skipped: $($_.Exception.Message)"
    }
}
