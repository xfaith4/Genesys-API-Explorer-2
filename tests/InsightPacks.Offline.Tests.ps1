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

    It 'honors BaseUri/AccessToken overrides and restores context' {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $packPath = Join-Path $repo 'tests\fixtures\insightpacks\test.simple.v1.pack.json'

        $moduleState = Get-Module -Name 'GenesysCloud.OpsInsights'
        $originalInvoker = $moduleState.SessionState.PSVariable.GetValue('GCInvoker')

        Set-GCContext -ApiBaseUri 'https://api.original.local' -AccessToken 'orig-token' | Out-Null

        $captured = New-Object System.Collections.ArrayList
        $stubInvoker = {
            param([hashtable]$Request)
            $null = $captured.Add($Request)
            return @{ name = 'Test User' }
        }

        try {
            Set-GCInvoker -Invoker $stubInvoker
            Invoke-GCInsightPack -PackPath $packPath -Parameters @{} -BaseUri 'https://api.override.local' -AccessToken 'override-token' | Out-Null

            $captured.Count | Should -Be 1
            ([string]$captured[0].Uri) | Should -Match '^https://api\.override\.local/'
            $captured[0].Headers['Authorization'] | Should -Match 'override-token'

            $ctxAfter = $moduleState.SessionState.PSVariable.GetValue('GCContext')
            $ctxAfter.ApiBaseUri | Should -Be 'https://api.original.local'
            $ctxAfter.AccessToken | Should -Be 'orig-token'
        }
        finally {
            if ($null -ne $originalInvoker) {
                $moduleState.SessionState.PSVariable.Set('GCInvoker', $originalInvoker) | Out-Null
            }
            else {
                $moduleState.SessionState.PSVariable.Remove('GCInvoker') | Out-Null
            }

            Set-GCContext -ApiBaseUri 'https://api.example.local' -AccessToken 'test-token' | Out-Null
        }
    }
}
### END FILE: tests\InsightPacks.Offline.Tests.ps1
