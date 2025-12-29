### BEGIN FILE: src\GenesysCloud.OpsInsights.Core\Public\Export-GCInsightPackHtml.ps1
function Export-GCInsightPackHtml {
    <#
      .SYNOPSIS
        Exports an Insight Pack execution result to a portable HTML report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $packId   = [string]$Result.Pack.id
    $packName = [string]$Result.Pack.name
    $genUtc   = [string]$Result.GeneratedUtc

    $metrics = @($Result.Metrics)
    $steps   = @($Result.Steps)
    $drilldowns = @($Result.Drilldowns)
    function Encode-Html {
        param([object]$Value)
        [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    function To-PrettyString {
        param([object]$Value)

        if ($null -eq $Value) { return '' }
        if ($Value -is [string]) { return [string]$Value }

        $typeName = $Value.GetType().FullName
        if ($typeName -match '^(System\\.Collections\\.|System\\.Management\\.Automation\\.PSCustomObject)') {
            try { return ($Value | ConvertTo-Json -Depth 30) } catch { }
        }
        return [string]$Value
    }

    function Is-CompareResult {
        param($Result)
        try {
            if ($Result.Parameters -and ($Result.Parameters.PSObject.Properties.Name -contains 'Mode') -and $Result.Parameters.Mode -eq 'Compare') { return $true }
        } catch {}
        try {
            if ($Result.Data -and ($Result.Data.PSObject.Properties.Name -contains 'Comparison') -and $Result.Data.Comparison) { return $true }
        } catch {}
        return $false
    }

    $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; }
h1 { margin-bottom: 4px; }
.meta { color: #666; margin-bottom: 16px; }
.card { border: 1px solid #ddd; border-radius: 10px; padding: 12px 14px; margin: 12px 0; }
.kv { display: grid; grid-template-columns: 180px 1fr; gap: 6px 12px; }
.kv pre { margin: 0; white-space: pre-wrap; }
table { border-collapse: collapse; width: 100%; margin-top: 8px; }
th, td { border-bottom: 1px solid #eee; padding: 8px; text-align: left; vertical-align: top; }
th { background: #fafafa; }
.delta-pos { color: #B00020; font-weight: 600; }
.delta-neg { color: #0B6E4F; font-weight: 600; }
.pill { display: inline-block; padding: 2px 8px; border-radius: 999px; background: #EEF2FF; color: #2B3A67; font-size: 12px; }
</style>
"@

    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine("<html><head><meta charset='utf-8'/>$style</head><body>")
    [void]$html.AppendLine("<h1>$((Encode-Html $packName))</h1>")
    [void]$html.AppendLine("<div class='meta'>Pack: <b>$((Encode-Html $packId))</b> &nbsp; Generated (UTC): <b>$((Encode-Html $genUtc))</b></div>")

    $isCompare = Is-CompareResult -Result $Result
    if ($isCompare) {
        [void]$html.AppendLine("<div class='meta'><span class='pill'>Compare run</span></div>")
    }

    # Evidence
    if ($Result.PSObject.Properties.Name -contains 'Evidence' -and $Result.Evidence) {
        $narrative = ''
        $notes = ''
        $severity = ''
        $impact = ''
        $why = ''
        $likelyCauses = @()
        $recommended = @()
        $blast = $null

        if ($Result.Evidence.PSObject.Properties.Name -contains 'Narrative') { $narrative = [string]$Result.Evidence.Narrative }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'DrilldownNotes') { $notes = [string]$Result.Evidence.DrilldownNotes }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'Severity') { $severity = [string]$Result.Evidence.Severity }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'Impact') { $impact = [string]$Result.Evidence.Impact }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'WhyThisMatters') { $why = [string]$Result.Evidence.WhyThisMatters }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'LikelyCauses') { $likelyCauses = @($Result.Evidence.LikelyCauses) }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'RecommendedActions') { $recommended = @($Result.Evidence.RecommendedActions) }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'BlastRadius') { $blast = $Result.Evidence.BlastRadius }

        [void]$html.AppendLine("<div class='card'><h2>Evidence</h2>")
        if (-not [string]::IsNullOrWhiteSpace($severity)) {
            [void]$html.AppendLine("<div><b>Severity:</b> <span class='pill'>$((Encode-Html $severity))</span></div>")
        }
        if (-not [string]::IsNullOrWhiteSpace($narrative)) {
            [void]$html.AppendLine("<div><b>Narrative:</b> $((Encode-Html $narrative))</div>")
        }
        if (-not [string]::IsNullOrWhiteSpace($impact)) {
            [void]$html.AppendLine("<div style='margin-top:6px'><b>Impact:</b> $((Encode-Html $impact))</div>")
        }
        if (-not [string]::IsNullOrWhiteSpace($why)) {
            [void]$html.AppendLine("<div style='margin-top:6px'><b>Why this matters:</b> $((Encode-Html $why))</div>")
        }
        if ($likelyCauses.Count -gt 0) {
            [void]$html.AppendLine("<div style='margin-top:10px'><b>Likely causes</b><ul>")
            foreach ($c in $likelyCauses) { [void]$html.AppendLine("<li>$((Encode-Html $c))</li>") }
            [void]$html.AppendLine("</ul></div>")
        }
        if ($recommended.Count -gt 0) {
            [void]$html.AppendLine("<div style='margin-top:10px'><b>Recommended actions</b><ul>")
            foreach ($a in $recommended) { [void]$html.AppendLine("<li>$((Encode-Html $a))</li>") }
            [void]$html.AppendLine("</ul></div>")
        }

	        if ($blast) {
	            $actions = @()
	            $integrations = @()
	            $queues = @()
	            $flows = @()
	            try { if ($blast.PSObject.Properties.Name -contains 'Actions') { $actions = @($blast.Actions) } } catch {}
	            try { if ($blast.PSObject.Properties.Name -contains 'Integrations') { $integrations = @($blast.Integrations) } } catch {}
	            try { if ($blast.PSObject.Properties.Name -contains 'Queues') { $queues = @($blast.Queues) } } catch {}
	            try { if ($blast.PSObject.Properties.Name -contains 'Flows') { $flows = @($blast.Flows) } } catch {}
	            if ($actions.Count -gt 0 -or $integrations.Count -gt 0 -or $queues.Count -gt 0 -or $flows.Count -gt 0) {
	                [void]$html.AppendLine("<div style='margin-top:10px'><b>Blast radius</b><div class='kv'>")
	                if ($actions.Count -gt 0) {
	                    [void]$html.AppendLine("<div><b>Actions</b></div><div>$((Encode-Html (($actions | Select-Object -First 20) -join ', ')))</div>")
	                }
	                if ($integrations.Count -gt 0) {
	                    [void]$html.AppendLine("<div><b>Integrations</b></div><div>$((Encode-Html (($integrations | Select-Object -First 20) -join ', ')))</div>")
	                }
	                if ($queues.Count -gt 0) {
	                    [void]$html.AppendLine("<div><b>Queues</b></div><div>$((Encode-Html (($queues | Select-Object -First 20) -join ', ')))</div>")
	                }
	                if ($flows.Count -gt 0) {
	                    [void]$html.AppendLine("<div><b>Flows</b></div><div>$((Encode-Html (($flows | Select-Object -First 20) -join ', ')))</div>")
	                }
	                [void]$html.AppendLine("</div></div>")
	            }
	        }

        # Correlations (optional)
        try {
            if ($Result.Evidence.PSObject.Properties.Name -contains 'Correlations' -and $Result.Evidence.Correlations) {
                $changeAudit = $null
                if ($Result.Evidence.Correlations.PSObject.Properties.Name -contains 'ChangeAudit') { $changeAudit = $Result.Evidence.Correlations.ChangeAudit }
                if ($changeAudit -and $changeAudit.AuditChanges) {
                    $audit = $changeAudit.AuditChanges
                    $summary = if ($audit.PSObject.Properties.Name -contains 'Summary') { [string]$audit.Summary } else { '' }
                    $total = if ($audit.PSObject.Properties.Name -contains 'Total') { [int]$audit.Total } else { 0 }
                    $highCount = 0
                    try { if ($audit.PSObject.Properties.Name -contains 'HighSignal') { $highCount = @($audit.HighSignal).Count } } catch {}

                    [void]$html.AppendLine("<div style='margin-top:10px'><b>Correlations</b></div>")
                    [void]$html.AppendLine("<div class='kv'>")
                    [void]$html.AppendLine("<div><b>Change audit</b></div><div>$((Encode-Html $summary))</div>")
                    [void]$html.AppendLine("<div><b>Total events</b></div><div>$((Encode-Html $total))</div>")
                    [void]$html.AppendLine("<div><b>High-signal events</b></div><div>$((Encode-Html $highCount))</div>")
                    [void]$html.AppendLine("</div>")

                    $byType = @()
                    try { if ($audit.PSObject.Properties.Name -contains 'ByEntityType') { $byType = @($audit.ByEntityType) } } catch {}
                    if ($byType.Count -gt 0) {
                        [void]$html.AppendLine("<table><thead><tr><th>EntityType</th><th>Count</th></tr></thead><tbody>")
                        foreach ($row in ($byType | Select-Object -First 10)) {
                            [void]$html.AppendLine("<tr><td>$((Encode-Html $row.EntityType))</td><td>$((Encode-Html $row.Count))</td></tr>")
                        }
                        [void]$html.AppendLine("</tbody></table>")
                    }

                    $sample = @()
                    try { if ($audit.PSObject.Properties.Name -contains 'Sample') { $sample = @($audit.Sample) } } catch {}
                    if ($sample.Count -gt 0) {
                        [void]$html.AppendLine("<div style='margin-top:10px'><b>Audit sample</b></div>")
                        [void]$html.AppendLine("<table><thead><tr><th>When</th><th>EntityType</th><th>Action</th><th>Status</th><th>Name</th><th>Service</th></tr></thead><tbody>")
                        foreach ($row in ($sample | Select-Object -First 25)) {
                            [void]$html.AppendLine("<tr><td>$((Encode-Html $row.EventDate))</td><td>$((Encode-Html $row.EntityType))</td><td>$((Encode-Html $row.Action))</td><td>$((Encode-Html $row.Status))</td><td>$((Encode-Html $row.EntityName))</td><td>$((Encode-Html $row.ServiceName))</td></tr>")
                        }
                        [void]$html.AppendLine("</tbody></table>")
                    }
                }
            }
        } catch {}

        if (-not [string]::IsNullOrWhiteSpace($notes)) {
            [void]$html.AppendLine("<div style='margin-top:6px'><b>Notes:</b> $((Encode-Html $notes))</div>")
        }
        [void]$html.AppendLine("</div>")
    }

    # Parameters
    [void]$html.AppendLine("<div class='card'><h2>Parameters</h2>")
    if ($isCompare -and ($Result.Parameters.PSObject.Properties.Name -contains 'Current') -and ($Result.Parameters.PSObject.Properties.Name -contains 'Baseline')) {
        $currentParams = $Result.Parameters.Current
        $baselineParams = $Result.Parameters.Baseline
        $keys = New-Object System.Collections.Generic.HashSet[string]
        foreach ($p in @($currentParams.PSObject.Properties)) { [void]$keys.Add([string]$p.Name) }
        foreach ($p in @($baselineParams.PSObject.Properties)) { [void]$keys.Add([string]$p.Name) }
        [void]$html.AppendLine("<table><thead><tr><th>Key</th><th>Current</th><th>Baseline</th></tr></thead><tbody>")
        foreach ($k in ($keys | Sort-Object)) {
            $cur = $currentParams.$k
            $base = $baselineParams.$k
            [void]$html.AppendLine("<tr><td><b>$((Encode-Html $k))</b></td><td><pre>$((Encode-Html (To-PrettyString $cur)))</pre></td><td><pre>$((Encode-Html (To-PrettyString $base)))</pre></td></tr>")
        }
        [void]$html.AppendLine("</tbody></table>")
    }
    else {
        [void]$html.AppendLine("<div class='kv'>")
        foreach ($prop in ($Result.Parameters.PSObject.Properties | Sort-Object Name)) {
            $k = [string]$prop.Name
            $v = $prop.Value
            $text = To-PrettyString $v
            if ($text -match '^[\\[{]') {
                [void]$html.AppendLine("<div><b>$((Encode-Html $k))</b></div><div><pre>$((Encode-Html $text))</pre></div>")
            }
            else {
                [void]$html.AppendLine("<div><b>$((Encode-Html $k))</b></div><div>$((Encode-Html $text))</div>")
            }
        }
        [void]$html.AppendLine("</div>")
    }
    [void]$html.AppendLine("</div>")

    # Comparison (if present)
    $comparisons = @()
    if ($Result.Data -and ($Result.Data.PSObject.Properties.Name -contains 'Comparison') -and $Result.Data.Comparison) {
        $comparisons = @($Result.Data.Comparison)
    }
    elseif ($Result.Evidence -and ($Result.Evidence.PSObject.Properties.Name -contains 'Comparison') -and $Result.Evidence.Comparison -and ($Result.Evidence.Comparison.PSObject.Properties.Name -contains 'Metrics')) {
        $comparisons = @($Result.Evidence.Comparison.Metrics)
    }

    if ($comparisons.Count -gt 0) {
        [void]$html.AppendLine("<div class='card'><h2>Comparison</h2>")
        [void]$html.AppendLine("<table><thead><tr><th>Metric</th><th>Baseline</th><th>Current</th><th>Δ</th><th>%</th></tr></thead><tbody>")
        foreach ($cmp in $comparisons) {
            $title = [string]$cmp.Title
            $baseValue = To-PrettyString $cmp.BaselineValue
            $curValue = To-PrettyString $cmp.CurrentValue
            $delta = if ($null -ne $cmp.Delta) { [string]$cmp.Delta } else { '' }
            $pct = if ($null -ne $cmp.PercentChange) { "$($cmp.PercentChange)%" } else { '' }
            $cls = ''
            try {
                if ($null -ne $cmp.Delta) {
                    if ([double]$cmp.Delta -gt 0) { $cls = "delta-pos" }
                    elseif ([double]$cmp.Delta -lt 0) { $cls = "delta-neg" }
                }
            } catch {}
            [void]$html.AppendLine("<tr><td>$((Encode-Html $title))</td><td>$((Encode-Html $baseValue))</td><td>$((Encode-Html $curValue))</td><td class='$cls'>$((Encode-Html $delta))</td><td>$((Encode-Html $pct))</td></tr>")
        }
        [void]$html.AppendLine("</tbody></table></div>")
    }

    # Metrics
    [void]$html.AppendLine("<div class='card'><h2>Metrics</h2>")
    if ($metrics.Count -eq 0) {
        [void]$html.AppendLine("<div>(No metrics produced.)</div>")
    } else {
        foreach ($m in $metrics) {
            $title = [string]$m.title
            $value = [string]$m.value
            [void]$html.AppendLine("<h3>$((Encode-Html $title))</h3>")
            if ($value) {
                [void]$html.AppendLine("<div><b>Value:</b> $((Encode-Html $value))</div>")
            }

            if ($m.PSObject.Properties.Name -contains 'items' -and $null -ne $m.items) {
                $items = @($m.items)
                if ($items.Count -gt 0) {
                    $cols = @($items[0].PSObject.Properties.Name)
                    [void]$html.AppendLine("<table><thead><tr>")
                    foreach ($c in $cols) {
                        [void]$html.AppendLine("<th>$((Encode-Html $c))</th>")
                    }
                    [void]$html.AppendLine("</tr></thead><tbody>")
                    foreach ($row in $items) {
                        [void]$html.AppendLine("<tr>")
                        foreach ($c in $cols) {
                            $cell = $row.PSObject.Properties[$c].Value
                            [void]$html.AppendLine("<td>$((Encode-Html $cell))</td>")
                        }
                        [void]$html.AppendLine("</tr>")
                    }
                    [void]$html.AppendLine("</tbody></table>")
                }
            }
        }
    }
    [void]$html.AppendLine("</div>")

    # Drilldowns (summary)
    if ($drilldowns.Count -gt 0) {
        [void]$html.AppendLine("<div class='card'><h2>Drilldowns</h2>")
        foreach ($d in $drilldowns) {
            $title = if ($d.PSObject.Properties.Name -contains 'title') { [string]$d.title } else { 'drilldown' }
            $items = if ($d.PSObject.Properties.Name -contains 'items') { @($d.items) } else { @() }
            [void]$html.AppendLine("<h3>$((Encode-Html $title))</h3>")
            if ($items.Count -eq 0) {
                [void]$html.AppendLine("<div>(No rows.)</div>")
                continue
            }

            $cols = @($items[0].PSObject.Properties.Name)
            if ($cols.Count -gt 0) {
                [void]$html.AppendLine("<table><thead><tr>")
                foreach ($c in $cols) { [void]$html.AppendLine("<th>$((Encode-Html $c))</th>") }
                [void]$html.AppendLine("</tr></thead><tbody>")
                foreach ($row in $items | Select-Object -First 200) {
                    [void]$html.AppendLine("<tr>")
                    foreach ($c in $cols) {
                        $cell = $row.PSObject.Properties[$c].Value
                        [void]$html.AppendLine("<td>$((Encode-Html (To-PrettyString $cell)))</td>")
                    }
                    [void]$html.AppendLine("</tr>")
                }
                [void]$html.AppendLine("</tbody></table>")
                if ($items.Count -gt 200) {
                    [void]$html.AppendLine("<div class='meta'>(Showing first 200 rows; see snapshot for full data.)</div>")
                }
            }
        }
        [void]$html.AppendLine("</div>")
    }

    # Steps
    [void]$html.AppendLine("<div class='card'><h2>Pipeline Steps</h2>")
    if ($steps.Count -gt 0) {
        $table = $steps | Select-Object Id,Type,DurationMs,StartedUtc,EndedUtc |
            ConvertTo-Html -Fragment -As Table
        $table | ForEach-Object { [void]$html.AppendLine($_) }
    } else {
        [void]$html.AppendLine("<div>(No step timing captured.)</div>")
    }
    [void]$html.AppendLine("</div>")

    [void]$html.AppendLine("</body></html>")

    $html.ToString() | Set-Content -LiteralPath $fullPath -Encoding utf8
    return $fullPath
}
### END FILE
