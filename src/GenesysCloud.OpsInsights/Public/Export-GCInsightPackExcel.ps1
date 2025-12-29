### BEGIN FILE: src\GenesysCloud.OpsInsights\Public\Export-GCInsightPackExcel.ps1
function Export-GCInsightPackExcel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Result,

        [Parameter()]
        [string]$Path,

        [Parameter()]
        [switch]$Force
    )

    if (-not $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $Path = Join-Path -Path (Get-Location).Path -ChildPath ("GCInsights_{0}.xlsx" -f $stamp)
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $dir = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ($fullPath.ToLower().EndsWith('.csv')) {
        $fullPath = [System.IO.Path]::ChangeExtension($fullPath, 'xlsx')
    }

    $metricsRows = foreach ($metric in @($Result.Metrics)) {
        [pscustomobject]@{
            Title   = if ($metric.PSObject.Properties.Name -contains 'title') { $metric.title } else { $null }
            Value   = if ($metric.PSObject.Properties.Name -contains 'value') { $metric.value } else { $null }
            Items   = if ($metric.PSObject.Properties.Name -contains 'items') { @($metric.items).Count } else { 0 }
            Details = if ($metric.PSObject.Properties.Name -contains 'items') {
                ($metric.items | ConvertTo-Json -Depth 4)
            } else { $null }
        }
    }

    $stepsRows = foreach ($step in @($Result.Steps)) {
        [pscustomobject]@{
            Id           = $step.Id
            Type         = $step.Type
            Status       = $step.Status
            DurationMs   = $step.DurationMs
            StartedUtc   = $step.StartedUtc
            EndedUtc     = $step.EndedUtc
            ResultSummary= $step.ResultSummary
            ErrorMessage = $step.ErrorMessage
        }
    }

    $paths = @()
    $primaryPath = $fullPath
    $format = 'Xlsx'

    $hasImportExcel = $false
    try { $hasImportExcel = [bool](Get-Module -ListAvailable -Name ImportExcel) } catch { $hasImportExcel = $false }

    function Get-SafeWorksheetName {
        param(
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [hashtable]$Existing
        )

        $safe = ($Name -replace '[\\/:\\?\\*\\[\\]]', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Sheet' }
        if ($safe.Length -gt 31) { $safe = $safe.Substring(0, 31).Trim() }

        $base = $safe
        $i = 1
        while ($Existing.ContainsKey($safe)) {
            $suffix = " $i"
            $trimLen = 31 - $suffix.Length
            $safe = ($base.Substring(0, [Math]::Min($base.Length, $trimLen)).Trim() + $suffix)
            $i++
        }

        $Existing[$safe] = $true
        return $safe
    }

    if ($hasImportExcel) {
        Import-Module ImportExcel -ErrorAction Stop

        $used = @{}

        $metricsRows | Export-Excel -Path $primaryPath `
            -WorksheetName 'Metrics' `
            -TableName 'Metrics' `
            -AutoSize `
            -FreezeTopRow

        $stepsRows | Export-Excel -Path $primaryPath `
            -WorksheetName 'Steps' `
            -TableName 'Steps' `
            -AutoSize `
            -FreezeTopRow `
            -AppendSheet

        # Metric item sheets
        $metricIndex = 0
        foreach ($metric in @($Result.Metrics)) {
            $metricIndex++
            if (-not ($metric.PSObject.Properties.Name -contains 'items')) { continue }
            $items = @($metric.items)
            if ($items.Count -eq 0) { continue }

            $title = if ($metric.PSObject.Properties.Name -contains 'title' -and $metric.title) { [string]$metric.title } else { "Metric $metricIndex" }
            $sheet = Get-SafeWorksheetName -Name ("M{0} {1}" -f $metricIndex, $title) -Existing $used

            $items | Export-Excel -Path $primaryPath `
                -WorksheetName $sheet `
                -AutoSize `
                -FreezeTopRow `
                -AppendSheet
        }

        # Drilldown sheets
        $drillIndex = 0
        foreach ($drill in @($Result.Drilldowns)) {
            $drillIndex++
            if (-not $drill) { continue }
            if (-not ($drill.PSObject.Properties.Name -contains 'items')) { continue }
            $items = @($drill.items)
            if ($items.Count -eq 0) { continue }

            $title = if ($drill.PSObject.Properties.Name -contains 'title' -and $drill.title) { [string]$drill.title } else { "Drilldown $drillIndex" }
            $sheet = Get-SafeWorksheetName -Name ("D{0} {1}" -f $drillIndex, $title) -Existing $used

            $items | Export-Excel -Path $primaryPath `
                -WorksheetName $sheet `
                -AutoSize `
                -FreezeTopRow `
                -AppendSheet
        }

        $paths += $primaryPath
    }
    else {
        $format = 'Csv'
        $metricsCsv = [System.IO.Path]::ChangeExtension($primaryPath, 'Metrics.csv')
        $stepsCsv = [System.IO.Path]::ChangeExtension($primaryPath, 'Steps.csv')

        $extraCsv = @()
        $metricIndex = 0
        foreach ($metric in @($Result.Metrics)) {
            $metricIndex++
            if (-not ($metric.PSObject.Properties.Name -contains 'items')) { continue }
            $items = @($metric.items)
            if ($items.Count -eq 0) { continue }
            $title = if ($metric.PSObject.Properties.Name -contains 'title' -and $metric.title) { [string]$metric.title } else { "Metric $metricIndex" }
            $safe = ($title -replace '[^A-Za-z0-9_\\- ]', '') -replace '\\s+', ' '
            $safe = $safe.Trim()
            if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Metric$metricIndex" }
            if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40).Trim() }
            $extraCsv += ([System.IO.Path]::ChangeExtension($primaryPath, ("M{0}_{1}.csv" -f $metricIndex, ($safe -replace ' ', '_'))))
        }

        $drillIndex = 0
        foreach ($drill in @($Result.Drilldowns)) {
            $drillIndex++
            if (-not $drill) { continue }
            if (-not ($drill.PSObject.Properties.Name -contains 'items')) { continue }
            $items = @($drill.items)
            if ($items.Count -eq 0) { continue }
            $title = if ($drill.PSObject.Properties.Name -contains 'title' -and $drill.title) { [string]$drill.title } else { "Drilldown $drillIndex" }
            $safe = ($title -replace '[^A-Za-z0-9_\\- ]', '') -replace '\\s+', ' '
            $safe = $safe.Trim()
            if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Drilldown$drillIndex" }
            if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40).Trim() }
            $extraCsv += ([System.IO.Path]::ChangeExtension($primaryPath, ("D{0}_{1}.csv" -f $drillIndex, ($safe -replace ' ', '_'))))
        }

        foreach ($file in @($metricsCsv, $stepsCsv) + @($extraCsv)) {
            if ((Test-Path -LiteralPath $file) -and (-not $Force)) {
                throw "File already exists: $($file). Use -Force to overwrite."
            }
        }

        $metricsRows | Export-Csv -LiteralPath $metricsCsv -NoTypeInformation -Encoding utf8
        $stepsRows   | Export-Csv -LiteralPath $stepsCsv   -NoTypeInformation -Encoding utf8

        # Write metric/drilldown item CSVs
        $extraOut = @()
        $metricIndex = 0
        foreach ($metric in @($Result.Metrics)) {
            $metricIndex++
            if (-not ($metric.PSObject.Properties.Name -contains 'items')) { continue }
            $items = @($metric.items)
            if ($items.Count -eq 0) { continue }
            $path = $extraCsv[$extraOut.Count]
            $items | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8
            $extraOut += $path
        }

        $drillIndex = 0
        foreach ($drill in @($Result.Drilldowns)) {
            $drillIndex++
            if (-not $drill) { continue }
            if (-not ($drill.PSObject.Properties.Name -contains 'items')) { continue }
            $items = @($drill.items)
            if ($items.Count -eq 0) { continue }
            $path = $extraCsv[$extraOut.Count]
            $items | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8
            $extraOut += $path
        }

        $primaryPath = $metricsCsv
        $paths = @($metricsCsv, $stepsCsv) + @($extraOut)
    }

    return [pscustomobject]@{
        Format      = $format
        PrimaryPath = $primaryPath
        Paths       = $paths
    }
}
### END FILE: src\GenesysCloud.OpsInsights\Public/Export-GCInsightPackExcel.ps1
