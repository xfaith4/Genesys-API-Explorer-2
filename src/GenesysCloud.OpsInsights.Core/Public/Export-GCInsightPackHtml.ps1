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
    $encode  = [System.Net.WebUtility]::HtmlEncode

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
    [void]$html.AppendLine("<h1>$($encode($packName))</h1>")
    [void]$html.AppendLine("<div class='meta'>Pack: <b>$($encode($packId))</b> &nbsp; Generated (UTC): <b>$($encode($genUtc))</b></div>")

    $isCompare = Is-CompareResult -Result $Result
    if ($isCompare) {
        [void]$html.AppendLine("<div class='meta'><span class='pill'>Compare run</span></div>")
    }

    # Evidence
    if ($Result.PSObject.Properties.Name -contains 'Evidence' -and $Result.Evidence) {
        $narrative = ''
        $notes = ''
        if ($Result.Evidence.PSObject.Properties.Name -contains 'Narrative') { $narrative = [string]$Result.Evidence.Narrative }
        if ($Result.Evidence.PSObject.Properties.Name -contains 'DrilldownNotes') { $notes = [string]$Result.Evidence.DrilldownNotes }

        [void]$html.AppendLine("<div class='card'><h2>Evidence</h2>")
        if (-not [string]::IsNullOrWhiteSpace($narrative)) {
            [void]$html.AppendLine("<div><b>Narrative:</b> $($encode($narrative))</div>")
        }
        if (-not [string]::IsNullOrWhiteSpace($notes)) {
            [void]$html.AppendLine("<div style='margin-top:6px'><b>Notes:</b> $($encode($notes))</div>")
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
            [void]$html.AppendLine("<tr><td><b>$($encode($k))</b></td><td><pre>$($encode(To-PrettyString $cur))</pre></td><td><pre>$($encode(To-PrettyString $base))</pre></td></tr>")
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
                [void]$html.AppendLine("<div><b>$($encode($k))</b></div><div><pre>$($encode($text))</pre></div>")
            }
            else {
                [void]$html.AppendLine("<div><b>$($encode($k))</b></div><div>$($encode($text))</div>")
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
            [void]$html.AppendLine("<tr><td>$($encode($title))</td><td>$($encode($baseValue))</td><td>$($encode($curValue))</td><td class='$cls'>$($encode($delta))</td><td>$($encode($pct))</td></tr>")
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
            [void]$html.AppendLine("<h3>$($encode($title))</h3>")
            if ($value) {
                [void]$html.AppendLine("<div><b>Value:</b> $($encode($value))</div>")
            }

            if ($m.PSObject.Properties.Name -contains 'items' -and $null -ne $m.items) {
                $items = @($m.items)
                if ($items.Count -gt 0) {
                    $cols = @($items[0].PSObject.Properties.Name)
                    [void]$html.AppendLine("<table><thead><tr>")
                    foreach ($c in $cols) {
                        [void]$html.AppendLine("<th>$($encode($c))</th>")
                    }
                    [void]$html.AppendLine("</tr></thead><tbody>")
                    foreach ($row in $items) {
                        [void]$html.AppendLine("<tr>")
                        foreach ($c in $cols) {
                            $cell = $row.PSObject.Properties[$c].Value
                            [void]$html.AppendLine("<td>$($encode([string]$cell))</td>")
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
            [void]$html.AppendLine("<h3>$($encode($title))</h3>")
            if ($items.Count -eq 0) {
                [void]$html.AppendLine("<div>(No rows.)</div>")
                continue
            }

            $cols = @($items[0].PSObject.Properties.Name)
            if ($cols.Count -gt 0) {
                [void]$html.AppendLine("<table><thead><tr>")
                foreach ($c in $cols) { [void]$html.AppendLine("<th>$($encode($c))</th>") }
                [void]$html.AppendLine("</tr></thead><tbody>")
                foreach ($row in $items | Select-Object -First 200) {
                    [void]$html.AppendLine("<tr>")
                    foreach ($c in $cols) {
                        $cell = $row.PSObject.Properties[$c].Value
                        [void]$html.AppendLine("<td>$($encode(To-PrettyString $cell))</td>")
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
