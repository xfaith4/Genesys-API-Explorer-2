### BEGIN FILE: Get-GCQueueWaitingSkillMatchReport.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GCRequest {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [hashtable]$Query,
        [object]$Body,
        [int]$MaxRetries = 6
    )

    $uriBuilder = [System.UriBuilder]::new(($BaseUri.TrimEnd('/') + '/' + $Path.TrimStart('/')))
    if ($Query) {
        $pairs = foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($null -ne $v -and "$v" -ne '') {
                '{0}={1}' -f [System.Uri]::EscapeDataString($k), [System.Uri]::EscapeDataString([string]$v)
            }
        }
        $uriBuilder.Query = ($pairs -join '&')
    }

    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept        = 'application/json'
    }

    $attempt = 0
    while ($true) {
        try {
            $irmParams = @{
                Method  = $Method
                Uri     = $uriBuilder.Uri.AbsoluteUri
                Headers = $headers
            }
            if ($null -ne $Body) {
                $irmParams.ContentType = 'application/json'
                $irmParams.Body = ($Body | ConvertTo-Json -Depth 15)
            }
            return Invoke-RestMethod @irmParams
        }
        catch {
            $attempt++

            $resp = $_.Exception.Response
            $status = $null
            if ($resp -and $resp.StatusCode) { $status = [int]$resp.StatusCode }

            # Backoff on 429 / transient 5xx
            if ($attempt -le $MaxRetries -and ($status -eq 429 -or ($status -ge 500 -and $status -le 599))) {
                $sleepMs = [Math]::Min(30000, (250 * [Math]::Pow(2, $attempt)))
                Start-Sleep -Milliseconds $sleepMs
                continue
            }

            throw
        }
    }
}

function Get-GCPaged {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$Path,
        [hashtable]$Query = @{},
        [string]$ItemsProperty = 'entities',
        [int]$PageSize = 100
    )

    $pageNumber = 1
    $all = New-Object System.Collections.Generic.List[object]

    while ($true) {
        $q = @{}
        foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] }
        $q.pageSize = $PageSize
        $q.pageNumber = $pageNumber

        $resp = Invoke-GCRequest -BaseUri $BaseUri -AccessToken $AccessToken -Method GET -Path $Path -Query $q

        $items = $null
        if ($resp.PSObject.Properties.Name -contains $ItemsProperty) {
            $items = $resp.$ItemsProperty
        } elseif ($resp.PSObject.Properties.Name -contains 'items') {
            $items = $resp.items
        }

        if ($items) { foreach ($i in $items) { $all.Add($i) } }

        # Common Genesys list shape includes pageCount/pageNumber OR nextUri
        $pageCount = $null
        if ($resp.PSObject.Properties.Name -contains 'pageCount') { $pageCount = [int]$resp.pageCount }

        if ($pageCount -and $pageNumber -lt $pageCount) {
            $pageNumber++
            continue
        }

        # If no paging metadata, stop when fewer than requested returned
        if (-not $pageCount -and ($items.Count -ge $PageSize)) {
            $pageNumber++
            continue
        }

        break
    }

    return $all
}

function Resolve-GCSkillNames {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken
    )

    $skills = Get-GCPaged -BaseUri $BaseUri -AccessToken $AccessToken -Path '/api/v2/routing/skills' -ItemsProperty 'entities' -PageSize 100
    $map = @{}
    foreach ($s in $skills) {
        if ($s.id) { $map[$s.id] = $s.name }
    }
    return $map
}

function Get-GCQueueMembers {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$QueueId,
        [switch]$ExpandPresence
    )

    $q = @{ joined = 'true' }
    if ($ExpandPresence) { $q.expand = 'presence' }

    # Community examples show /members supports joined + expand=presence :contentReference[oaicite:8]{index=8}
    return Get-GCPaged -BaseUri $BaseUri -AccessToken $AccessToken -Path "/api/v2/routing/queues/$QueueId/members" -Query $q -ItemsProperty 'entities' -PageSize 100
}

function Get-GCUserRoutingSkills {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$UserId
    )
    # /api/v2/users/{userId}/routingskills is used to retrieve skills + proficiency :contentReference[oaicite:9]{index=9}
    return Invoke-GCRequest -BaseUri $BaseUri -AccessToken $AccessToken -Method GET -Path "/api/v2/users/$UserId/routingskills"
}

function Get-GCQueueWaitingConversations {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$QueueId
    )

    # Try “all media” endpoint first; fall back to media-specific.
    $pathsToTry = @(
        "/api/v2/routing/queues/$QueueId/conversations",
        "/api/v2/routing/queues/$QueueId/conversations/calls",
        "/api/v2/routing/queues/$QueueId/conversations/chats",   # confirmed exists :contentReference[oaicite:10]{index=10}
        "/api/v2/routing/queues/$QueueId/conversations/emails",
        "/api/v2/routing/queues/$QueueId/conversations/messages"
    )

    $all = New-Object System.Collections.Generic.List[object]

    foreach ($p in $pathsToTry) {
        try {
            $resp = Invoke-GCRequest -BaseUri $BaseUri -AccessToken $AccessToken -Method GET -Path $p -Query @{ pageSize = 100; pageNumber = 1 }

            # Different endpoints return slightly different shapes; normalize into items
            $items = $null
            foreach ($prop in @('entities','conversations','calls','chats','emails','messages','items')) {
                if ($resp.PSObject.Properties.Name -contains $prop) { $items = $resp.$prop; break }
            }
            if (-not $items -and $resp) { $items = @($resp) }

            foreach ($it in @($items)) {
                # Standardize a minimal record
                $convId = $it.id
                if (-not $convId -and $it.conversationId) { $convId = $it.conversationId }

                if ($convId) {
                    $all.Add([pscustomobject]@{
                        conversationId = $convId
                        mediaType      = $it.mediaType
                        raw            = $it
                        sourcePath     = $p
                    })
                }
            }
        }
        catch {
            # ignore 404/400 on non-existent variants
            $resp = $_.Exception.Response
            $status = $null
            if ($resp -and $resp.StatusCode) { $status = [int]$resp.StatusCode }
            if ($status -in 400,404) { continue }
            throw
        }
    }

    # De-dupe by conversationId
    return $all | Group-Object conversationId | ForEach-Object { $_.Group[0] }
}

function Get-GCRoutingConversation {
    param(
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,
        [Parameter(Mandatory)] [string]$ConversationId
    )

    # Routing Conversation resource (also used for setting/removing skills while waiting) :contentReference[oaicite:11]{index=11}
    return Invoke-GCRequest -BaseUri $BaseUri -AccessToken $AccessToken -Method GET -Path "/api/v2/routing/conversations/$ConversationId"
}

function Extract-RequiredSkills {
    param(
        [Parameter(Mandatory)] [object]$RoutingConversation
    )

    # Best-effort schema support (because orgs/features can differ).
    # We try several likely places skills might appear.
    $candidates = @()

    foreach ($path in @(
        'acds',                       # sometimes list of skills/requirements
        'acdSkills',
        'routingData.acdSkills',
        'routingData.skills',
        'skills',
        'requestedRoutingSkills'
    )) {
        $cur = $RoutingConversation
        $ok = $true
        foreach ($seg in $path.Split('.')) {
            if ($null -eq $cur) { $ok = $false; break }
            if ($cur.PSObject.Properties.Name -contains $seg) { $cur = $cur.$seg } else { $ok = $false; break }
        }
        if ($ok -and $cur) { $candidates += @($cur) }
    }

    # Normalize into @([pscustomobject]@{ id=''; proficiency=0 })
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($cand in $candidates) {
        foreach ($s in @($cand)) {
            if ($s -is [string]) {
                $out.Add([pscustomobject]@{ id = $s; proficiency = $null })
            }
            elseif ($s.PSObject.Properties.Name -contains 'id') {
                $prof = $null
                foreach ($pName in @('proficiency','minimumProficiency','minProficiency')) {
                    if ($s.PSObject.Properties.Name -contains $pName) { $prof = $s.$pName; break }
                }
                $out.Add([pscustomobject]@{ id = $s.id; proficiency = $prof })
            }
            elseif ($s.PSObject.Properties.Name -contains 'skillId') {
                $out.Add([pscustomobject]@{ id = $s.skillId; proficiency = ($s.proficiency) })
            }
        }
    }

    # De-dupe
    return $out | Group-Object id | ForEach-Object { $_.Group[0] }
}

function Get-GCQueueWaitingSkillMatchReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$QueueId,

        # Interval here is “how often to refresh”, not a historical time window
        [int]$PollSeconds = 0,
        [int]$Iterations  = 1,

        # Genesys region host, example: https://api.usw2.pure.cloud
        [Parameter(Mandatory)] [string]$BaseUri,
        [Parameter(Mandatory)] [string]$AccessToken,

        [switch]$ExpandPresence,
        [switch]$OnlyJoinedMembers = $true,
        [switch]$OnlyRoutableAgents = $false
    )

    $skillNameMap = Resolve-GCSkillNames -BaseUri $BaseUri -AccessToken $AccessToken

    $members = Get-GCQueueMembers -BaseUri $BaseUri -AccessToken $AccessToken -QueueId $QueueId -ExpandPresence:$ExpandPresence
    $memberIds = @($members | ForEach-Object { $_.id } | Where-Object { $_ })

    # Cache agent skills
    $agentSkillCache = @{}
    foreach ($uid in $memberIds) {
        try {
            $rs = Get-GCUserRoutingSkills -BaseUri $BaseUri -AccessToken $AccessToken -UserId $uid
            $skills = @()

            # typical shape: entities/items; normalize
            if ($rs.PSObject.Properties.Name -contains 'entities') { $skills = @($rs.entities) }
            elseif ($rs.PSObject.Properties.Name -contains 'items') { $skills = @($rs.items) }
            else { $skills = @($rs) }

            $agentSkillCache[$uid] = $skills | ForEach-Object {
                [pscustomobject]@{
                    id          = ($_.id ?? $_.skillId)
                    name        = ($skillNameMap[($_.id ?? $_.skillId)])
                    proficiency = ($_.proficiency ?? $_.rating)
                }
            }
        }
        catch {
            $agentSkillCache[$uid] = @()
        }
    }

    for ($i = 1; $i -le $Iterations; $i++) {
        $waiting = Get-GCQueueWaitingConversations -BaseUri $BaseUri -AccessToken $AccessToken -QueueId $QueueId

        $rows = foreach ($w in $waiting) {
            $routing = $null
            $required = @()
            try {
                $routing = Get-GCRoutingConversation -BaseUri $BaseUri -AccessToken $AccessToken -ConversationId $w.conversationId
                $required = Extract-RequiredSkills -RoutingConversation $routing
            }
            catch {
                # keep going; required skills will be unknown
                $routing = $null
                $required = @()
            }

            $requiredNamed = $required | ForEach-Object {
                [pscustomobject]@{
                    id          = $_.id
                    name        = ($skillNameMap[$_.id] ?? $null)
                    proficiency = $_.proficiency
                }
            }

            $candidates = New-Object System.Collections.Generic.List[object]
            foreach ($uid in $memberIds) {
                $agentSkills = @($agentSkillCache[$uid])

                $ok = $true
                foreach ($req in $required) {
                    $match = $agentSkills | Where-Object { $_.id -eq $req.id } | Select-Object -First 1
                    if (-not $match) { $ok = $false; break }

                    if ($null -ne $req.proficiency -and $null -ne $match.proficiency) {
                        if ([int]$match.proficiency -lt [int]$req.proficiency) { $ok = $false; break }
                    }
                }

                if ($ok) {
                    $mem = $members | Where-Object { $_.id -eq $uid } | Select-Object -First 1
                    $candidates.Add([pscustomobject]@{
                        userId    = $uid
                        name      = ($mem.name ?? $mem.user.name ?? $null)
                        presence  = ($mem.presence.presenceDefinition.systemPresence ?? $mem.presence ?? $null)
                        skillsHit = $requiredNamed
                    })
                }
            }

            [pscustomobject]@{
                queueId             = $QueueId
                conversationId      = $w.conversationId
                mediaType           = $w.mediaType
                requiredSkills      = $requiredNamed
                candidateAgents     = @($candidates)
                candidateAgentCount = @($candidates).Count
                sourcePath          = $w.sourcePath
                routingRaw          = $routing
                queueItemRaw        = $w.raw
                capturedAt          = (Get-Date).ToString('o')
            }
        }

        $rows | Sort-Object -Property candidateAgentCount, conversationId

        if ($i -lt $Iterations -and $PollSeconds -gt 0) {
            Start-Sleep -Seconds $PollSeconds
        }
    }
}

### END FILE: Get-GCQueueWaitingSkillMatchReport.ps1

<#
# One snapshot
. .\Get-GCQueueWaitingSkillMatchReport.ps1

$report = Get-GCQueueWaitingSkillMatchReport `
  -QueueId 'YOUR-QUEUE-GUID' `
  -BaseUri 'https://api.usw2.pure.cloud' `
  -AccessToken $env:GC_ACCESS_TOKEN `
  -ExpandPresence

$report | Select-Object conversationId, mediaType, candidateAgentCount,
  @{n='requiredSkills';e={($_.requiredSkills.name -join ', ')}} |
  Format-Table -AutoSize

#>
