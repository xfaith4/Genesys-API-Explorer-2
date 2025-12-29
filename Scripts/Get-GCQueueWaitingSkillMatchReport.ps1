### BEGIN FILE: Get-GCQueueWaitingSkillMatchReport.ps1
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$QueueId,

  # Interval window for analytics detail query. Examples:
  # "2025-12-29T12:00:00.000Z/2025-12-29T12:15:00.000Z"
  # "2025-12-29T12:00:00.000Z/2025-12-29T12:20:00.000Z"
  [Parameter(Mandatory)]
  [string]$Interval,

  # If you already have a conversations details response saved (like your uploaded sample),
  # you can point to it for offline/fast dev.
  [string]$AnalyticsDetailsJsonPath = "",

  # If you want to try true real-time queue inventory first (recommended)
  [switch]$PreferRoutingQueueConversations,

  # Output
  [ValidateSet('Object','Json','Csv')]
  [string]$OutputMode = 'Object',

  [string]$OutPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Request plumbing
# -----------------------------
function Invoke-GCRequestLocal {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [object]$Body = $null,
    [hashtable]$Query = $null
  )

  if (-not $script:GC_BaseUri -or -not $script:GC_AccessToken) {
    throw "Missing `$GC_BaseUri and/or `$GC_AccessToken. If you're in the API Explorer, provide an Invoke-GCRequest function OR set these globals."
  }

  $uri = $script:GC_BaseUri.TrimEnd('/') + $Path
  if ($Query) {
    $qs = ($Query.GetEnumerator() | ForEach-Object {
      "{0}={1}" -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    if ($qs) { $uri = "$($uri)?$($qs)" }
  }

  $headers = @{
    Authorization = "Bearer $($script:GC_AccessToken)"
    Accept        = 'application/json'
  }

  $irmParams = @{
    Method  = $Method
    Uri     = $uri
    Headers = $headers
  }

  if ($null -ne $Body) {
    $irmParams.ContentType = 'application/json'
    $irmParams.Body = ($Body | ConvertTo-Json -Depth 20)
  }

  # Minimal backoff for 429/5xx
  $maxAttempts = 6
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      return Invoke-RestMethod @irmParams
    } catch {
      $msg = "$_"
      $retry = ($msg -match '\b429\b') -or ($msg -match '\b5\d\d\b')
      if (-not $retry -or $attempt -eq $maxAttempts) { throw }

      $sleepSec = [Math]::Min(30, [Math]::Pow(2, $attempt))
      Start-Sleep -Seconds $sleepSec
    }
  }
}

# If your Explorer already has Invoke-GCRequest, we’ll use it.
function Invoke-GCRequestCompat {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [object]$Body = $null,
    [hashtable]$Query = $null
  )

  if (Get-Command -Name Invoke-GCRequest -ErrorAction SilentlyContinue) {
    # Adapt if your Invoke-GCRequest signature differs
    return Invoke-GCRequest -Method $Method -Path $Path -Body $Body -Query $Query
  }

  return Invoke-GCRequestLocal -Method $Method -Path $Path -Body $Body -Query $Query
}

# -----------------------------
# Helpers: Extract required skills from Analytics conversation details
# -----------------------------
function Get-RequiredSkillIdsFromConversationDetails {
  param(
    [Parameter(Mandatory)][object]$Conversation,
    [Parameter(Mandatory)][string]$QueueId
  )

  $skillIds = New-Object System.Collections.Generic.HashSet[string]

  # Walk all participants/sessions/segments and capture requestedRoutingSkillIds on any segment in this queue.
  foreach ($p in @($Conversation.participants)) {
    foreach ($s in @($p.sessions)) {
      foreach ($seg in @($s.segments)) {
        if ($seg.queueId -and ($seg.queueId -eq $QueueId)) {
          foreach ($sid in @($seg.requestedRoutingSkillIds)) {
            if ($sid) { [void]$skillIds.Add([string]$sid) }
          }
        }
      }
    }

    # Fallback: some orgs stuff a CSV into an attribute like ivr.Skills
    if ($p.attributes -and $p.attributes.'ivr.Skills') {
      foreach ($sid in ($p.attributes.'ivr.Skills' -split '\s*,\s*')) {
        if ($sid) { [void]$skillIds.Add([string]$sid) }
      }
    }
  }

  return @($skillIds)
}

function Get-QueueConversationsFromAnalyticsDetails {
  param(
    [Parameter(Mandatory)][object]$AnalyticsDetails,
    [Parameter(Mandatory)][string]$QueueId
  )

  # The sample file shows the list is a top-level array of conversation objects (shape depends on how you saved it).
  $convs = @()
  if ($AnalyticsDetails -is [System.Collections.IEnumerable] -and -not ($AnalyticsDetails -is [string])) {
    $convs = @($AnalyticsDetails)
  } elseif ($AnalyticsDetails.conversations) {
    $convs = @($AnalyticsDetails.conversations)
  } else {
    $convs = @($AnalyticsDetails)
  }

  # Filter: any segment with this queueId
  return $convs | Where-Object {
    $c = $_
    foreach ($p in @($c.participants)) {
      foreach ($s in @($p.sessions)) {
        foreach ($seg in @($s.segments)) {
          if ($seg.queueId -eq $QueueId) { return $true }
        }
      }
    }
    return $false
  }
}

# -----------------------------
# Agent skills + queue membership
# -----------------------------
$script:UserSkillsCache = @{}
function Get-UserRoutingSkillIds {
  param([Parameter(Mandatory)][string]$UserId)

  if ($script:UserSkillsCache.ContainsKey($UserId)) {
    return $script:UserSkillsCache[$UserId]
  }

  $skills = Invoke-GCRequestCompat -Method GET -Path "/api/v2/users/$($UserId)/routingskills"
  # Typical response is an array of { id, name, proficiency, state } objects (shape may differ slightly).
  $ids = @($skills | Where-Object { $_.state -eq 'active' -or -not $_.state } | ForEach-Object { $_.id }) | Where-Object { $_ }
  $script:UserSkillsCache[$UserId] = $ids
  return $ids
}

function Test-HasAllSkills {
  param(
    [string[]]$UserSkillIds,
    [string[]]$RequiredSkillIds
  )

  if (-not $RequiredSkillIds -or $RequiredSkillIds.Count -eq 0) { return $true }
  if (-not $UserSkillIds) { return $false }

  $set = New-Object System.Collections.Generic.HashSet[string]
  foreach ($id in $UserSkillIds) { if ($id) { [void]$set.Add([string]$id) } }

  foreach ($req in $RequiredSkillIds) {
    if ($req -and -not $set.Contains([string]$req)) { return $false }
  }
  return $true
}

function Get-QueueMembersOnQueue {
  param([Parameter(Mandatory)][string]$QueueId)

  # Community guidance: use joined=true + presence=ON queue to avoid “member but not actually on-queue” cases. :contentReference[oaicite:5]{index=5}
  $resp = Invoke-GCRequestCompat -Method GET -Path "/api/v2/routing/queues/$($QueueId)/members" -Query @{
    joined   = 'true'
    presence = 'ON queue'
    pageSize = '100'
    pageNumber = '1'
  }

  # Handle either { entities: [...] } or straight array
  if ($resp.entities) { return @($resp.entities) }
  return @($resp)
}

# -----------------------------
# Primary: build report rows
# -----------------------------
function New-QueueWaitingSkillMatchReport {
  param(
    [Parameter(Mandatory)][string]$QueueId,
    [Parameter(Mandatory)][string]$Interval,
    [string]$AnalyticsDetailsJsonPath,
    [switch]$PreferRoutingQueueConversations
  )

  # 1) Gather waiting conversations
  $waitingConversations = @()

  if ($PreferRoutingQueueConversations) {
    try {
      $qc = Invoke-GCRequestCompat -Method GET -Path "/api/v2/routing/queues/$($QueueId)/conversations"
      if ($qc.entities) { $waitingConversations = @($qc.entities) } else { $waitingConversations = @($qc) }
    } catch {
      # Not fatal; fall back to analytics details query path
      $waitingConversations = @()
    }
  }

  # 2) Pull analytics conversation details (either from file, or live query)
  $details = $null
  if ($AnalyticsDetailsJsonPath) {
    $details = Get-Content -LiteralPath $AnalyticsDetailsJsonPath -Raw | ConvertFrom-Json
  } else {
    # Live details query. Your Explorer likely already knows how to call this.
    # NOTE: The exact predicate shape varies; this is a common working pattern for queueId + interval.
    $body = @{
      interval   = $Interval
      order      = 'asc'
      orderBy    = 'conversationStart'
      paging     = @{ pageSize = 100; pageNumber = 1 }
      segmentFilters = @(
        @{
          type = 'and'
          predicates = @(
            @{ type = 'dimension'; dimension = 'queueId'; operator = 'matches'; value = $QueueId }
          )
        }
      )
    }
    $details = Invoke-GCRequestCompat -Method POST -Path "/api/v2/analytics/conversations/details/query" -Body $body
  }

  $detailConvs = Get-QueueConversationsFromAnalyticsDetails -AnalyticsDetails $details -QueueId $QueueId

  # If we successfully got real-time queue convs, restrict to those IDs; otherwise just use detail set
  if ($waitingConversations -and $waitingConversations.Count -gt 0) {
    $idSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($c in $waitingConversations) { if ($c.id) { [void]$idSet.Add([string]$c.id) } }
    $detailConvs = $detailConvs | Where-Object { $_.conversationId -and $idSet.Contains([string]$_.conversationId) -or $_.id -and $idSet.Contains([string]$_.id) }
  }

  # 3) Get candidate agents (on-queue members)
  $members = Get-QueueMembersOnQueue -QueueId $QueueId

  # Preload user skills (cached) + lightweight identity
  $agentIndex = foreach ($m in $members) {
    $uid = $m.user.id
    if (-not $uid) { $uid = $m.userId }
    if (-not $uid) { continue }

    $skillIds = Get-UserRoutingSkillIds -UserId $uid

    [pscustomobject]@{
      UserId       = $uid
      Name         = $m.user.name
      RoutingStatus = $m.routingStatus
      Presence     = $m.presence
      SkillIds     = $skillIds
    }
  }

  # 4) Assemble rows
  $rows = foreach ($c in $detailConvs) {
    $cid = $c.conversationId
    if (-not $cid) { $cid = $c.id }

    $req = Get-RequiredSkillIdsFromConversationDetails -Conversation $c -QueueId $QueueId

    $matchingAgents = $agentIndex | Where-Object { Test-HasAllSkills -UserSkillIds $_.SkillIds -RequiredSkillIds $req } |
      Select-Object UserId, Name, Presence, RoutingStatus

    # Try to surface ANI/DNIS if present
    $ani = $null
    $dnis = $null
    foreach ($p in @($c.participants)) {
      foreach ($s in @($p.sessions)) {
        if (-not $ani -and $s.ani) { $ani = $s.ani }
        if (-not $dnis -and $s.dnis) { $dnis = $s.dnis }
      }
    }

    [pscustomobject]@{
      QueueId            = $QueueId
      ConversationId     = $cid
      Ani                = $ani
      Dnis               = $dnis
      RequiredSkillIds   = $req
      MatchingAgentCount = @($matchingAgents).Count
      MatchingAgents     = $matchingAgents
    }
  }

  return $rows
}

$report = New-QueueWaitingSkillMatchReport -QueueId $QueueId -Interval $Interval -AnalyticsDetailsJsonPath $AnalyticsDetailsJsonPath -PreferRoutingQueueConversations:$PreferRoutingQueueConversations

switch ($OutputMode) {
  'Object' {
    $report
  }
  'Json' {
    $json = $report | ConvertTo-Json -Depth 10
    if ($OutPath) { Set-Content -LiteralPath $OutPath -Value $json -Encoding UTF8 }
    $json
  }
  'Csv' {
    if (-not $OutPath) { throw "OutputMode=Csv requires -OutPath" }
    # Flatten MatchingAgents for CSV
    $flat = $report | ForEach-Object {
      $row = $_
      if (-not $row.MatchingAgents -or $row.MatchingAgents.Count -eq 0) {
        [pscustomobject]@{
          QueueId = $row.QueueId
          ConversationId = $row.ConversationId
          Ani = $row.Ani
          Dnis = $row.Dnis
          RequiredSkillIds = ($row.RequiredSkillIds -join ',')
          AgentUserId = ''
          AgentName = ''
          Presence = ''
          RoutingStatus = ''
        }
      } else {
        foreach ($a in $row.MatchingAgents) {
          [pscustomobject]@{
            QueueId = $row.QueueId
            ConversationId = $row.ConversationId
            Ani = $row.Ani
            Dnis = $row.Dnis
            RequiredSkillIds = ($row.RequiredSkillIds -join ',')
            AgentUserId = $a.UserId
            AgentName = $a.Name
            Presence = $a.Presence
            RoutingStatus = $a.RoutingStatus
          }
        }
      }
    }
    $flat | Export-Csv -LiteralPath $OutPath -NoTypeInformation -Encoding UTF8
    Get-Item -LiteralPath $OutPath
  }
}

### END FILE: Get-GCQueueWaitingSkillMatchReport.ps1
