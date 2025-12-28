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

    return [pscustomobject]@{
        EvidenceId     = $evidenceId
        PackId         = $Pack.id
        PackName       = $Pack.name
        GeneratedUtc   = (Get-Date).ToUniversalTime()
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
}
### END FILE: Private\New-GCInsightComparisonEvidencePacket.ps1
