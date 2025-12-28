### BEGIN FILE: tests\JoinStep.Offline.Tests.ps1
# Requires: Pester 5+

Describe 'Insight Pack step type: join (Offline)' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
        Set-GCContext -ApiBaseUri 'https://api.example.local' -AccessToken 'test-token' | Out-Null
    }

    It 'enriches items by key using lookup uri template' {
        Set-GCInvoker -Invoker {
            param([hashtable]$Request)
            if ($Request.Method -eq 'GET' -and $Request.Uri -match '/api/v2/things/([^/?]+)$') {
                $id = $Matches[1]
                return [pscustomobject]@{ id = $id; name = "Thing $id" }
            }
            throw "No fixture mapped for: $($Request.Method) $($Request.Uri)"
        }

        $pack = @{
            id = 'test.join.v1'
            name = 'Test Pack (Join)'
            version = '1.0.0'
            pipeline = @(
                @{
                    id = 'items'
                    type = 'compute'
                    script = "param(`$ctx) return @([pscustomobject]@{ thingId='a' }, [pscustomobject]@{ thingId='b' })"
                },
                @{
                    id = 'itemsEnriched'
                    type = 'join'
                    sourceStepId = 'items'
                    key = 'thingId'
                    assign = 'thing'
                    lookup = @{ method='GET'; uri='/api/v2/things/{id}' }
                },
                @{
                    id = 'assertEnriched'
                    type = 'assert'
                    message = 'Expected join to add thing.name to each row.'
                    script = 'param($ctx) return ((@($ctx.Data.itemsEnriched) | Where-Object { -not $_.thing.name }).Count -eq 0)'
                }
            )
        }

        $packPath = Join-Path $TestDrive 'test.join.v1.json'
        ($pack | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $packPath -Encoding utf8

        $result = Invoke-GCInsightPack -PackPath $packPath -StrictValidation
        @($result.Data.itemsEnriched).Count | Should -Be 2
        $result.Data.itemsEnriched[0].thing.name | Should -Be 'Thing a'
        $result.Data.itemsEnriched[1].thing.name | Should -Be 'Thing b'
    }
}
