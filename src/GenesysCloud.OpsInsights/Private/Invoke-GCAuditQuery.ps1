function Invoke-GCAuditQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Interval,

        [Parameter()]
        [string]$ServiceName,

        [Parameter()]
        [object[]]$Filters,

        [Parameter()]
        [ValidateSet('ascending','descending')]
        [string]$SortOrder = 'descending',

        [Parameter()]
        [int]$MaxWaitSec = 90,

        [Parameter()]
        [int]$PollIntervalSec = 2,

        [Parameter()]
        [int]$MaxPages = 200,

        [Parameter()]
        [int]$MaxResults = 500
    )

    if ($PollIntervalSec -lt 1) { $PollIntervalSec = 1 }
    if ($MaxWaitSec -lt 10) { $MaxWaitSec = 10 }
    if ($MaxPages -lt 1) { $MaxPages = 1 }
    if ($MaxResults -lt 1) { $MaxResults = 1 }

    $body = [ordered]@{
        interval = $Interval
        sort     = @(@{ name = 'Timestamp'; sortOrder = $SortOrder })
    }
    if ($ServiceName) { $body.serviceName = $ServiceName }
    if ($Filters -and $Filters.Count -gt 0) { $body.filters = @($Filters) }

    $exec = Invoke-GCRequest -Method POST -Path '/api/v2/audits/query' -Body $body
    $txId = $exec.id
    if ([string]::IsNullOrWhiteSpace([string]$txId)) {
        throw "Audit query did not return an execution id."
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $state = [string]$exec.state
    while ($true) {
        if ($state -match 'Succeeded') { break }
        if ($state -match 'Failed|Cancelled') { throw "Audit query $txId failed (state=$state)" }
        if ((Get-Date) -gt $deadline) { throw "Audit query $txId timed out after ${MaxWaitSec}s (last state=$state)" }

        Start-Sleep -Seconds $PollIntervalSec
        $status = Invoke-GCRequest -Method GET -Path ("/api/v2/audits/query/{0}" -f $txId)
        $state = if ($status -and $status.state) { [string]$status.state } else { '' }
    }

    $pages = 0
    $cursor = $null
    $out = New-Object System.Collections.ArrayList

    do {
        $pages++
        if ($pages -gt $MaxPages) { break }
        if ($out.Count -ge $MaxResults) { break }

        $path = "/api/v2/audits/query/{0}/results" -f $txId
        if ($cursor) { $path = $path + "?cursor=" + [System.Uri]::EscapeDataString([string]$cursor) }
        $page = Invoke-GCRequest -Method GET -Path $path

        $entities = @()
        if ($page -and ($page.PSObject.Properties.Name -contains 'entities')) {
            $entities = @($page.entities)
        }
        foreach ($e in $entities) {
            if ($out.Count -ge $MaxResults) { break }
            [void]$out.Add($e)
        }

        $cursor = $null
        if ($page -and ($page.PSObject.Properties.Name -contains 'cursor') -and $page.cursor) {
            $cursor = [string]$page.cursor
        }
    } while ($cursor)

    return [pscustomobject]@{
        ExecutionId = $txId
        Interval    = $Interval
        Count       = $out.Count
        Entities    = @($out)
    }
}

