### BEGIN FILE: tests\ForeachAndJobPoll.Offline.Tests.ps1
# Requires: Pester 5+

Describe 'Insight Pack step types (Offline)' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
        Set-GCContext -ApiBaseUri 'https://api.example.local' -AccessToken 'test-token' | Out-Null
    }

    It 'foreach step executes itemScript for each item' {
        $pack = @{
            id = 'test.foreach.v1'
            name = 'Test Pack (Foreach)'
            version = '1.0.0'
            pipeline = @(
                @{
                    id = 'items'
                    type = 'compute'
                    script = "param(`$ctx) return @(1,2,3)"
                },
                @{
                    id = 'mapped'
                    type = 'foreach'
                    itemsScript = "param(`$ctx) return @(`$ctx.Data.items)"
                    itemScript  = "param(`$ctx,`$item) return (`$item * 2)"
                },
                @{
                    id = 'assertMapped'
                    type = 'assert'
                    message = 'Expected mapped to be [2,4,6].'
                    script = "param(`$ctx) return ((@(`$ctx.Data.mapped) -join ',') -eq '2,4,6')"
                }
            )
        }

        $packPath = Join-Path $TestDrive 'test.foreach.v1.json'
        ($pack | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $packPath -Encoding utf8

        $result = Invoke-GCInsightPack -PackPath $packPath -StrictValidation
        @($result.Data.mapped).Count | Should -Be 3
        $result.Data.mapped[0] | Should -Be 2
        $result.Data.mapped[2] | Should -Be 6
    }

    It 'jobPoll step creates, polls, and collects items' {
        Set-GCInvoker -Invoker {
            param([hashtable]$Request)

            if ($Request.Method -eq 'POST' -and $Request.Uri -match '/api/v2/analytics/conversations/details/jobs$') {
                return [pscustomobject]@{ id = 'job-123' }
            }
            if ($Request.Method -eq 'GET' -and $Request.Uri -match '/api/v2/analytics/conversations/details/jobs/job-123$') {
                return [pscustomobject]@{ state = 'FULFILLED' }
            }
            if ($Request.Method -eq 'GET' -and $Request.Uri -match '/api/v2/analytics/conversations/details/jobs/job-123/results$') {
                return [pscustomobject]@{
                    conversations = @(
                        [pscustomobject]@{ conversationId = 'c1' },
                        [pscustomobject]@{ conversationId = 'c2' }
                    )
                    cursor = $null
                }
            }

            throw "No fixture mapped for: $($Request.Method) $($Request.Uri)"
        }

        $pack = @{
            id = 'test.jobpoll.v1'
            name = 'Test Pack (JobPoll)'
            version = '1.0.0'
            pipeline = @(
                @{
                    id = 'job'
                    type = 'jobPoll'
                    create = @{
                        method = 'POST'
                        uri = '/api/v2/analytics/conversations/details/jobs'
                        bodyTemplate = @{ interval = '2025-01-01T00:00:00Z/2025-01-02T00:00:00Z' }
                    }
                    statusPath = '/api/v2/analytics/conversations/details/jobs/{{jobId}}'
                    resultsPath = '/api/v2/analytics/conversations/details/jobs/{{jobId}}/results'
                    collect = 'conversations'
                    pollIntervalSec = 1
                    maxWaitSec = 10
                },
                @{
                    id = 'assertItems'
                    type = 'assert'
                    message = 'Expected two conversations collected.'
                    script = "param(`$ctx) return ((@(`$ctx.Data.job.Items).Count) -eq 2)"
                }
            )
        }

        $packPath = Join-Path $TestDrive 'test.jobpoll.v1.json'
        ($pack | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $packPath -Encoding utf8

        $result = Invoke-GCInsightPack -PackPath $packPath -StrictValidation
        $result.Data.job.JobId | Should -Be 'job-123'
        @($result.Data.job.Items).Count | Should -Be 2
    }
}

