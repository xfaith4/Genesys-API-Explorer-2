### BEGIN FILE: tests\Correlations.Offline.Tests.ps1
# Requires: Pester 5+

Describe 'Correlations (Offline)' {

    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
    }

    It 'Adds audit-change correlations to Evidence' {
        $result = [pscustomobject]@{
            Pack        = [pscustomobject]@{ id = 'test.pack.v1'; name = 'Test Pack' }
            Parameters  = [pscustomobject]@{ startDate = '2025-12-01T00:00:00Z'; endDate = '2025-12-01T01:00:00Z' }
            GeneratedUtc = (Get-Date).ToUniversalTime()
            Metrics     = @()
            Drilldowns  = @()
            Steps       = @()
            Evidence    = [pscustomobject]@{
                Severity = 'Info'
                Narrative = 'Test'
            }
        }

        $events = @(
            [pscustomobject]@{
                entityType = 'routingQueue'
                action     = 'UPDATE'
                status     = 'SUCCESS'
                eventDate  = '2025-12-01T00:10:00Z'
                serviceName = 'routing'
                entity     = [pscustomobject]@{ id = 'q1'; name = 'Support' }
            },
            [pscustomobject]@{
                entityType = 'architectFlow'
                action     = 'PUBLISH'
                status     = 'SUCCESS'
                eventDate  = '2025-12-01T00:20:00Z'
                serviceName = 'architect'
                entity     = [pscustomobject]@{ id = 'f1'; name = 'Main IVR' }
            }
        )

        $out = Add-GCInsightCorrelations -Result $result -AuditEvents $events
        $out.Evidence.Correlations.ChangeAudit.AuditChanges.Total | Should -Be 2
        @($out.Evidence.Correlations.ChangeAudit.AuditChanges.ByEntityType).Count | Should -BeGreaterThan 0
    }

    It 'Includes correlations in exported HTML when present' {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here

        $result = [pscustomobject]@{
            Pack        = [pscustomobject]@{ id = 'test.pack.v1'; name = 'Test Pack' }
            Parameters  = [pscustomobject]@{ startDate = '2025-12-01T00:00:00Z'; endDate = '2025-12-01T01:00:00Z' }
            GeneratedUtc = (Get-Date).ToUniversalTime()
            Metrics     = @()
            Drilldowns  = @()
            Steps       = @()
            Evidence    = [pscustomobject]@{
                Severity = 'Info'
                Narrative = 'Test'
            }
        }

        $events = @(
            [pscustomobject]@{
                entityType = 'routingQueue'
                action     = 'UPDATE'
                status     = 'SUCCESS'
                eventDate  = '2025-12-01T00:10:00Z'
                serviceName = 'routing'
                entity     = [pscustomobject]@{ id = 'q1'; name = 'Support' }
            }
        )

        $result = Add-GCInsightCorrelations -Result $result -AuditEvents $events

        $outDir = Join-Path ([System.IO.Path]::GetTempPath()) 'GenesysCloud.OpsInsights.Tests'
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $outPath = Join-Path $outDir 'correlations.test.html'

        Export-GCInsightPackHtml -Result $result -Path $outPath | Out-Null

        (Get-Content -LiteralPath $outPath -Raw) | Should -Match 'Correlations'
        (Get-Content -LiteralPath $outPath -Raw) | Should -Match 'Change audit'
    }
}

### END FILE: tests\Correlations.Offline.Tests.ps1

