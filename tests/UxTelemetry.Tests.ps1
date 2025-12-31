### BEGIN FILE: tests\UxTelemetry.Tests.ps1
Describe 'UxTelemetry' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $telemetryScript = Join-Path $repo 'apps/OpsConsole/Resources/UxTelemetry.ps1'
        . $telemetryScript
        $script:UxTelemetryState.Path = $null
        $script:UxTelemetryState.SessionId = $null
    }

    It 'initializes telemetry path and session' {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "ux-telemetry-test.jsonl"
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }

        Initialize-UxTelemetry -TargetPath $tempPath -SessionId "test-session"
        $script:UxTelemetryState.Path | Should -Be $tempPath
        $script:UxTelemetryState.SessionId | Should -Be "test-session"
    }

    It 'writes events as json lines' {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "ux-telemetry-test.jsonl"
        Initialize-UxTelemetry -TargetPath $tempPath -SessionId "test-session"

        Write-UxEvent -Name "page_view" -Properties @{ route = "home"; ts = "2025-01-01T00:00:00Z" }
        (Test-Path -LiteralPath $tempPath) | Should -BeTrue

        $line = Get-Content -LiteralPath $tempPath -TotalCount 1
        $obj = $line | ConvertFrom-Json
        $obj.event | Should -Be "page_view"
        $obj.session | Should -Be "test-session"
        $obj.props.route | Should -Be "home"
    }
}
### END FILE
