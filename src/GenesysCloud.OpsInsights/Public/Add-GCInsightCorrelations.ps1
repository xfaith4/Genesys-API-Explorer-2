function Add-GCInsightCorrelations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Result,

        [Parameter()]
        [object[]]$AuditEvents,

        [Parameter()]
        [int]$BufferMinutes = 30,

        [Parameter()]
        [int]$MaxAuditEvents = 200,

        [Parameter()]
        [switch]$FetchAuditEvents,

        [Parameter()]
        [string]$AuditServiceName,

        [Parameter()]
        [object[]]$AuditFilters
    )

    function ConvertTo-UtcDateTime {
        param([Parameter(Mandatory)]$Value)
        if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        try { return ([datetime]$s).ToUniversalTime() } catch { return $null }
    }

    $start = $null
    $end = $null
    try {
        if ($Result.Parameters) {
            if ($Result.Parameters.PSObject.Properties.Name -contains 'startDate') { $start = ConvertTo-UtcDateTime -Value $Result.Parameters.startDate }
            if ($Result.Parameters.PSObject.Properties.Name -contains 'endDate') { $end = ConvertTo-UtcDateTime -Value $Result.Parameters.endDate }
        }
    } catch { }

    if (-not $start -or -not $end) {
        # Fallback: 1 hour window ending at GeneratedUtc
        $gen = $null
        try { $gen = ConvertTo-UtcDateTime -Value $Result.GeneratedUtc } catch { }
        if (-not $gen) { $gen = (Get-Date).ToUniversalTime() }
        $end = $gen
        $start = $gen.AddHours(-1)
    }

    if ($end -lt $start) {
        $tmp = $start
        $start = $end
        $end = $tmp
    }

    if ($BufferMinutes -lt 0) { $BufferMinutes = 0 }
    $bufferedStart = $start.AddMinutes(-1 * $BufferMinutes)
    $bufferedEnd = $end.AddMinutes($BufferMinutes)
    $interval = $bufferedStart.ToString('o') + '/' + $bufferedEnd.ToString('o')

    $events = @()
    if ($AuditEvents) {
        $events = @($AuditEvents)
    }
    elseif ($FetchAuditEvents) {
        try {
            $query = Invoke-GCAuditQuery -Interval $interval -ServiceName $AuditServiceName -Filters $AuditFilters -MaxResults $MaxAuditEvents
            $events = @($query.Entities)
        }
        catch {
            $events = @()
        }
    }

    $limited = @($events | Select-Object -First $MaxAuditEvents)
    $highSignalEntityTypes = @(
        'routingQueue','queue',
        'architectFlow','flow',
        'integration','dataAction','action',
        'oauthClient','clientApp',
        'telephonyProvidersEdge','edge','stations'
    )

    $simplified = foreach ($e in $limited) {
        if (-not $e) { continue }
        $entityType = ''
        $entityId = ''
        $entityName = ''
        $action = ''
        $status = ''
        $when = ''
        $service = ''

        try { if ($e.PSObject.Properties.Name -contains 'entityType') { $entityType = [string]$e.entityType } } catch { }
        try { if ($e.PSObject.Properties.Name -contains 'action') { $action = [string]$e.action } } catch { }
        try { if ($e.PSObject.Properties.Name -contains 'status') { $status = [string]$e.status } } catch { }
        try { if ($e.PSObject.Properties.Name -contains 'eventDate') { $when = [string]$e.eventDate } } catch { }
        try { if ($e.PSObject.Properties.Name -contains 'serviceName') { $service = [string]$e.serviceName } } catch { }

        try {
            if ($e.PSObject.Properties.Name -contains 'entity' -and $e.entity) {
                if ($e.entity.PSObject.Properties.Name -contains 'id') { $entityId = [string]$e.entity.id }
                if ($e.entity.PSObject.Properties.Name -contains 'name') { $entityName = [string]$e.entity.name }
            }
        } catch { }

        $isHigh = $false
        try {
            if ($entityType) {
                $t = $entityType.ToLowerInvariant()
                foreach ($needle in $highSignalEntityTypes) {
                    if ($t -like "*$needle*") { $isHigh = $true; break }
                }
            }
        } catch { }

        [pscustomobject]@{
            EventDate   = $when
            ServiceName = $service
            Action      = $action
            Status      = $status
            EntityType  = $entityType
            EntityId    = $entityId
            EntityName  = $entityName
            HighSignal  = $isHigh
        }
    }

    $byEntityType = @($simplified | Group-Object EntityType | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
        [pscustomobject]@{ EntityType = $_.Name; Count = $_.Count }
    })
    $byAction = @($simplified | Group-Object Action | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
        [pscustomobject]@{ Action = $_.Name; Count = $_.Count }
    })

    $summaryParts = New-Object System.Collections.Generic.List[string]
    if ($byEntityType.Count -gt 0) {
        $top = ($byEntityType | Select-Object -First 3 | ForEach-Object { "$($_.EntityType)=$($_.Count)" }) -join ', '
        $summaryParts.Add("Top entity types: $top") | Out-Null
    }
    if ($byAction.Count -gt 0) {
        $top = ($byAction | Select-Object -First 3 | ForEach-Object { "$($_.Action)=$($_.Count)" }) -join ', '
        $summaryParts.Add("Top actions: $top") | Out-Null
    }
    $summary = if ($summaryParts.Count -gt 0) { $summaryParts -join ' | ' } else { 'No audit changes correlated.' }

    $correlation = [pscustomobject]@{
        IntervalUtc         = ($start.ToString('o') + '/' + $end.ToString('o'))
        BufferedIntervalUtc = $interval
        AuditChanges        = [pscustomobject]@{
            Total      = $simplified.Count
            HighSignal = @($simplified | Where-Object { $_.HighSignal } | Select-Object -First 50)
            ByEntityType = $byEntityType
            ByAction   = $byAction
            Sample     = @($simplified | Select-Object -First 25)
            Summary    = $summary
        }
    }

    if (-not ($Result.PSObject.Properties.Name -contains 'Evidence') -or -not $Result.Evidence) {
        $Result | Add-Member -MemberType NoteProperty -Name Evidence -Value ([pscustomobject]@{}) -Force
    }

    if (-not ($Result.Evidence.PSObject.Properties.Name -contains 'Correlations') -or -not $Result.Evidence.Correlations) {
        $Result.Evidence | Add-Member -MemberType NoteProperty -Name Correlations -Value ([pscustomobject]@{}) -Force
    }

    $Result.Evidence.Correlations | Add-Member -MemberType NoteProperty -Name ChangeAudit -Value $correlation -Force

    return $Result
}

