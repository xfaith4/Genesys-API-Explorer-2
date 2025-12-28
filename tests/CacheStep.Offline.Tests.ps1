### BEGIN FILE: tests\CacheStep.Offline.Tests.ps1
# Requires: Pester 5+

Describe 'Insight Pack step type: cache (Offline)' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
        Set-GCContext -ApiBaseUri 'https://api.example.local' -AccessToken 'test-token' | Out-Null
    }

    It 'reuses cached value across runs (no re-execution)' {
        $global:CacheStepExecutionCount = 0
        $cacheDir = Join-Path $TestDrive 'packcache'

        $pack = @{
            id = 'test.cache.v1'
            name = 'Test Pack (Cache)'
            version = '1.0.0'
            parameters = @{
                startDate = @{ type = 'string'; required = $true }
                endDate   = @{ type = 'string'; required = $true }
            }
            pipeline = @(
                @{
                    id = 'cached'
                    type = 'cache'
                    ttlMinutes = 60
                    cacheDirectory = $cacheDir
                    keyTemplate = '{{startDate}}/{{endDate}}'
                    script = 'param($ctx) $global:CacheStepExecutionCount++; return [pscustomobject]@{ value = [guid]::NewGuid().ToString() }'
                }
            )
        }

        $packPath = Join-Path $TestDrive 'test.cache.v1.json'
        ($pack | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $packPath -Encoding utf8

        $params = @{
            startDate = '2025-12-01T00:00:00Z'
            endDate   = '2025-12-08T00:00:00Z'
        }

        $r1 = Invoke-GCInsightPack -PackPath $packPath -Parameters $params -StrictValidation -UseCache
        $r2 = Invoke-GCInsightPack -PackPath $packPath -Parameters $params -StrictValidation -UseCache

        $r1.Data.cached.value | Should -Be $r2.Data.cached.value
        $global:CacheStepExecutionCount | Should -Be 1

        ($r2.Steps | Where-Object { $_.Id -eq 'cached' }).ResultSummary | Should -Match '^CACHE HIT:'
    }
}
