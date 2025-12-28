### BEGIN FILE: tests\InsightPackCompare.Tests.ps1
# Requires: Pester 5+

Describe 'Insight Packs (Compare)' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
        Set-GCContext -ApiBaseUri 'https://api.example.local' -AccessToken 'test-token' | Out-Null
    }

    It 'derives previous-window baseline by default' {
        function ParseUtc([string]$Value) {
            return [datetime]::Parse(
                $Value,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }

        $pack = @{
            id = 'test.compare.v1'
            name = 'Test Pack (Compare)'
            version = '1.0.0'
            parameters = @{
                startDate = @{ type = 'string'; required = $true }
                endDate = @{ type = 'string'; required = $true }
            }
            pipeline = @(
                @{
                    id = 'metricSpanHours'
                    type = 'metric'
                    script = "param(`$ctx) `$s=[datetime]`$ctx.Parameters.startDate; `$e=[datetime]`$ctx.Parameters.endDate; `$h=[math]::Round((`$e-`$s).TotalHours,0); [pscustomobject]@{ title='SpanHours'; value=`$h; items=@() }"
                }
            )
        }

        $packPath = Join-Path $TestDrive 'test.compare.v1.json'
        ($pack | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $packPath -Encoding utf8

        $start = '2025-01-08T00:00:00Z'
        $end = '2025-01-15T00:00:00Z'
        $result = Invoke-GCInsightPackCompare -PackPath $packPath -Parameters @{ startDate = $start; endDate = $end } -StrictValidation

        $result.Parameters.Mode | Should -Be 'Compare'
        $result.Parameters.Current.startDate | Should -Be $start
        $result.Parameters.Current.endDate | Should -Be $end
        (ParseUtc $result.Parameters.Baseline.endDate).ToString('o') | Should -Be (ParseUtc $start).ToString('o')
    }

    It 'derives shift-days baseline when requested' {
        function ParseUtc([string]$Value) {
            return [datetime]::Parse(
                $Value,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }

        $pack = @{
            id = 'test.compare.shift.v1'
            name = 'Test Pack (Compare Shift)'
            version = '1.0.0'
            parameters = @{
                startDate = @{ type = 'string'; required = $true }
                endDate = @{ type = 'string'; required = $true }
            }
            pipeline = @(
                @{
                    id = 'metricStartDay'
                    type = 'metric'
                    script = "param(`$ctx) `$s=[datetime]`$ctx.Parameters.startDate; [pscustomobject]@{ title='StartDay'; value=`$s.Day; items=@() }"
                }
            )
        }

        $packPath = Join-Path $TestDrive 'test.compare.shift.v1.json'
        ($pack | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $packPath -Encoding utf8

        $start = '2025-01-15T00:00:00Z'
        $end = '2025-01-22T00:00:00Z'
        $result = Invoke-GCInsightPackCompare -PackPath $packPath -Parameters @{ startDate = $start; endDate = $end } -BaselineMode ShiftDays -BaselineShiftDays 7 -StrictValidation

        (ParseUtc $result.Parameters.Baseline.startDate).ToString('yyyy-MM-dd') | Should -Be '2025-01-08'
        (ParseUtc $result.Parameters.Baseline.endDate).ToString('yyyy-MM-dd') | Should -Be '2025-01-15'
    }
}
