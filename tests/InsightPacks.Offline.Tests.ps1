### BEGIN FILE: tests\InsightPacks.Offline.Tests.ps1
# Requires: Pester 5+

Describe 'Insight Packs (Offline)' {

    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
        Set-GCContext -ApiBaseUri 'https://api.example.local' -AccessToken 'test-token' | Out-Null
    }

    It 'Runs a fixture-backed pack' {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $packPath = Join-Path $repo 'tests\fixtures\insightpacks\test.simple.v1.pack.json'
        $fixtures = Join-Path $repo 'tests\fixtures\insightpacks'

        $result = Invoke-GCInsightPackTest -PackPath $packPath -FixturesDirectory $fixtures -Strict
        $result.MissingFixtures.Count | Should -Be 0
        $result.Result.Metrics.Count | Should -BeGreaterThan 0
        $result.Result.Metrics[0].value | Should -Be 'Test User'
        $result.Result.Evidence.Severity | Should -Be 'Info'
        $result.Result.Evidence.Impact | Should -Be 'Offline fixture run.'
    }
}
### END FILE: tests\InsightPacks.Offline.Tests.ps1
