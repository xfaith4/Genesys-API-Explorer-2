$script:UxTelemetryState = @{
    Path      = $null
    SessionId = $null
}

function Get-UxTelemetryDefaultPath {
    param(
        [string]$RootPath
    )

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
        $script:UxTelemetryState.Path = $resolvedPath
    }
    catch {
        # If the path cannot be created, silently disable telemetry
        $script:UxTelemetryState.Path = $null
    }

    if (-not $SessionId) {
        $SessionId = [guid]::NewGuid().ToString()
    }
    $script:UxTelemetryState.SessionId = $SessionId
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
        ($payload | ConvertTo-Json -Depth 6 -Compress) | Add-Content -LiteralPath $script:UxTelemetryState.Path -Encoding utf8
    }
    catch {
        # Telemetry should never break the experience
    }
}
