### BEGIN FILE: Private\Compare-GCInsightMetrics.ps1
function Compare-GCInsightMetrics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $CurrentResult,

        [Parameter(Mandatory)]
        $BaselineResult
    )

    $currentMetrics = @($CurrentResult.Metrics)
    $baselineMetrics = @($BaselineResult.Metrics)

    $baselineByTitle = @{}
    foreach ($m in $baselineMetrics) {
        if ($m -and $m.PSObject.Properties.Name -contains 'title' -and $m.title) {
            $baselineByTitle[[string]$m.title] = $m
        }
    }

    $comparisons = foreach ($m in $currentMetrics) {
        if (-not $m -or -not ($m.PSObject.Properties.Name -contains 'title')) { continue }
        $title = [string]$m.title
        if ([string]::IsNullOrWhiteSpace($title)) { continue }

        $b = $baselineByTitle[$title]

        $curValue = if ($m.PSObject.Properties.Name -contains 'value') { $m.value } else { $null }
        $baseValue = if ($b -and ($b.PSObject.Properties.Name -contains 'value')) { $b.value } else { $null }

        $curNum = $null
        $baseNum = $null
        $delta = $null
        $pct = $null

        if ($null -ne $curValue -and $null -ne $baseValue) {
            try { $curNum = [double]$curValue } catch {}
            try { $baseNum = [double]$baseValue } catch {}

            if ($null -ne $curNum -and $null -ne $baseNum) {
                $delta = [math]::Round(($curNum - $baseNum), 4)
                if ($baseNum -ne 0) {
                    $pct = [math]::Round((($delta / $baseNum) * 100), 2)
                }
            }
        }

        [pscustomobject]@{
            Title          = $title
            CurrentValue   = $curValue
            BaselineValue  = $baseValue
            Delta          = $delta
            PercentChange  = $pct
        }
    }

    return @($comparisons)
}
### END FILE: Private\Compare-GCInsightMetrics.ps1
