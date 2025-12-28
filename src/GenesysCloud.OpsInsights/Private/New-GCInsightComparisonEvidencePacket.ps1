### BEGIN FILE: Private\New-GCInsightComparisonEvidencePacket.ps1
function New-GCInsightComparisonEvidencePacket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Pack,

        [Parameter(Mandatory)]
        $CurrentResult,

        [Parameter(Mandatory)]
        $BaselineResult,

        [Parameter(Mandatory)]
        [object[]]$MetricComparisons
    )

    $worsened = @($MetricComparisons | Where-Object { $null -ne $_.Delta -and $_.Delta -gt 0 } | Sort-Object Delta -Descending | Select-Object -First 5)
    $improved = @($MetricComparisons | Where-Object { $null -ne $_.Delta -and $_.Delta -lt 0 } | Sort-Object Delta | Select-Object -First 5)

    $parts = New-Object System.Collections.Generic.List[string]
    if ($worsened.Count -gt 0) {
        $items = ($worsened | ForEach-Object {
            $pct = if ($null -ne $_.PercentChange) { " ($($_.PercentChange)%)" } else { '' }
            "$($_.Title): +$($_.Delta)$pct"
        }) -join '; '
        $parts.Add("Worsened: $items") | Out-Null
    }
    if ($improved.Count -gt 0) {
        $items = ($improved | ForEach-Object {
            $pct = if ($null -ne $_.PercentChange) { " ($($_.PercentChange)%)" } else { '' }
            "$($_.Title): $($_.Delta)$pct"
        }) -join '; '
        $parts.Add("Improved: $items") | Out-Null
    }
    if ($parts.Count -eq 0) {
        $parts.Add("No numeric metric deltas were computed for this pack.") | Out-Null
    }

    $idStamp = (Get-Date -Format 'yyyyMMddHHmmss')
    $evidenceId = "{0}-compare-{1}" -f ($Pack.id -replace '[^A-Za-z0-9_\-]', '_'), $idStamp

    $severity = 'Info'
    if ($worsened.Count -gt 0) { $severity = 'Warning' }
    if ($worsened.Count -ge 3) { $severity = 'Critical' }

    $base = [pscustomobject]@{
        EvidenceId     = $evidenceId
        PackId         = $Pack.id
        PackName       = $Pack.name
        GeneratedUtc   = (Get-Date).ToUniversalTime()
        Severity       = $severity
        Impact         = 'Week-over-week / month-over-month deltas detected.'
        LikelyCauses   = @()
        RecommendedActions = @(
            'Review the largest worsened metrics and drill into contributing entities.',
            'Correlate the delta window to recent releases/config changes and downstream availability.'
        )
        WhyThisMatters = 'Leadership needs trendlines, not snapshots. Deltas highlight regressions and improvements.'
        BlastRadius    = $null
        Narrative      = ($parts -join ' | ')
        DrilldownNotes = "Current vs baseline comparison; see drilldowns for per-metric deltas."
        Metrics        = @($CurrentResult.Metrics)
        Drilldowns     = @($CurrentResult.Drilldowns)
        Comparison     = [pscustomobject]@{
            Current   = $CurrentResult.Parameters
            Baseline  = $BaselineResult.Parameters
            Metrics   = @($MetricComparisons)
        }
    }

    if ($CurrentResult.PSObject.Properties.Name -contains 'EvidenceOverride' -and $CurrentResult.EvidenceOverride) {
        foreach ($prop in @($CurrentResult.EvidenceOverride.PSObject.Properties)) {
            $name = [string]$prop.Name
            $value = $prop.Value
            $base | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
        }
    }

    return $base
}
### END FILE: Private\New-GCInsightComparisonEvidencePacket.ps1
