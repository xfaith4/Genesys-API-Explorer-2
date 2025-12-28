### BEGIN FILE: tests\InsightPackValidation.Tests.ps1
# Requires: Pester 5+

Describe 'Insight Pack validation' {
    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $repo = Split-Path -Parent $here
        $module = Join-Path $repo 'src\GenesysCloud.OpsInsights\GenesysCloud.OpsInsights.psd1'
        Import-Module $module -Force -ErrorAction Stop
    }

    It 'validates all packs (schema + strict)' {
        $repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $packsDir = Join-Path $repo 'insights\packs'
        $packFiles = Get-ChildItem -LiteralPath $packsDir -Filter '*.json' -File | Sort-Object Name
        $packFiles.Count | Should -BeGreaterThan 0

        foreach ($f in $packFiles) {
            $res = Test-GCInsightPack -PackPath $f.FullName -Strict -Schema
            $res.IsValid | Should -BeTrue -Because $f.Name
        }
    }
}

