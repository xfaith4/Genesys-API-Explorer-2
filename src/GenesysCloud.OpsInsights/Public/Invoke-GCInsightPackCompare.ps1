### BEGIN FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPackCompare.ps1
function Invoke-GCInsightPackCompare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackPath,

        [Parameter()]
        [hashtable]$Parameters,

        [Parameter()]
        [hashtable]$BaselineParameters,

        [Parameter()]
        [switch]$StrictValidation,

        [Parameter()]
        [ValidateSet('PreviousWindow', 'ShiftDays')]
        [string]$BaselineMode = 'PreviousWindow',

        [Parameter()]
        [int]$BaselineShiftDays = 7,

        [Parameter()]
        [string]$BaseUri,

        [Parameter()]
        [string]$AccessToken,

        [Parameter()]
        [scriptblock]$TokenProvider
    )

    if ($null -eq $Parameters) { $Parameters = @{} }

    if (-not $BaselineParameters) {
        if (-not ($Parameters.ContainsKey('startDate') -and $Parameters.ContainsKey('endDate'))) {
            throw "BaselineParameters not provided; Parameters must include 'startDate' and 'endDate' to derive a baseline window."
        }

        function Parse-GcUtc {
            param([Parameter(Mandatory)][string]$Value)
            return [datetime]::Parse(
                $Value,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }

        try { $currentStart = Parse-GcUtc -Value ([string]$Parameters.startDate) } catch { throw "Parameters.startDate must be parseable as datetime." }
        try { $currentEnd = Parse-GcUtc -Value ([string]$Parameters.endDate) } catch { throw "Parameters.endDate must be parseable as datetime." }
        if ($currentEnd -le $currentStart) { throw "Parameters.endDate must be after Parameters.startDate." }

        $BaselineParameters = @{}
        foreach ($k in $Parameters.Keys) { $BaselineParameters[$k] = $Parameters[$k] }

        if ($BaselineMode -eq 'ShiftDays') {
            $BaselineParameters.startDate = $currentStart.AddDays(-1 * $BaselineShiftDays).ToUniversalTime().ToString('o')
            $BaselineParameters.endDate = $currentEnd.AddDays(-1 * $BaselineShiftDays).ToUniversalTime().ToString('o')
        }
        else {
            $span = ($currentEnd - $currentStart)
            $BaselineParameters.startDate = $currentStart.Subtract($span).ToUniversalTime().ToString('o')
            $BaselineParameters.endDate = $currentStart.ToUniversalTime().ToString('o')
        }
    }

    $invokePackSplat = @{
        PackPath          = $PackPath
        Parameters        = $Parameters
        StrictValidation  = $StrictValidation
    }
    if ($PSBoundParameters.ContainsKey('BaseUri')) { $invokePackSplat.BaseUri = $BaseUri }
    if ($PSBoundParameters.ContainsKey('AccessToken')) { $invokePackSplat.AccessToken = $AccessToken }
    if ($PSBoundParameters.ContainsKey('TokenProvider')) { $invokePackSplat.TokenProvider = $TokenProvider }

    $current = Invoke-GCInsightPack @invokePackSplat
    $invokePackSplat.Parameters = $BaselineParameters
    $baseline = Invoke-GCInsightPack @invokePackSplat

    $metricComparisons = Compare-GCInsightMetrics -CurrentResult $current -BaselineResult $baseline

    $deltaMetrics = foreach ($cmp in $metricComparisons) {
        if ($null -eq $cmp.Delta) { continue }
        $pct = if ($null -ne $cmp.PercentChange) { "$($cmp.PercentChange)%" } else { '' }
        [pscustomobject]@{
            title = "Δ $($cmp.Title)"
            value = $cmp.Delta
            items = @([pscustomobject]@{
                title = $cmp.Title
                baseline = $cmp.BaselineValue
                current = $cmp.CurrentValue
                delta = $cmp.Delta
                percentChange = $pct
            })
        }
    }

    $result = [pscustomobject]@{
        Pack         = $current.Pack
        Parameters   = [ordered]@{
            Mode = 'Compare'
            Current  = $current.Parameters
            Baseline = $baseline.Parameters
        }
        Data         = [ordered]@{
            Current  = $current
            Baseline = $baseline
            Comparison = $metricComparisons
        }
        Metrics      = New-Object System.Collections.ArrayList
        Drilldowns   = New-Object System.Collections.ArrayList
        Steps        = New-Object System.Collections.ArrayList
        GeneratedUtc = (Get-Date).ToUniversalTime()
    }

    foreach ($m in @($deltaMetrics)) {
        [void]$result.Metrics.Add($m)
    }

    [void]$result.Drilldowns.Add([pscustomobject]@{
        title = 'Metric Deltas'
        items = @($metricComparisons)
    })

    $result | Add-Member -MemberType NoteProperty -Name Evidence -Value (New-GCInsightComparisonEvidencePacket -Pack $current.Pack -CurrentResult $current -BaselineResult $baseline -MetricComparisons $metricComparisons) -Force
    return $result
}
### END FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPackCompare.ps1
