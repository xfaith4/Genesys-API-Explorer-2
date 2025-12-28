### BEGIN FILE: src\GenesysCloud.OpsInsights\Public\Get-GCConversationDetails.ps1
function Get-GCConversationDetails {
  <#
      .SYNOPSIS
        Wrapper for /api/v2/analytics/conversations/details
      .NOTES
        PR2: Keep it dead simple + fixture-friendly.
        Auth is expected to be handled elsewhere; transport will use $global:AccessToken if present.
    #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ParameterSetName = 'ByQuery')]
    [ValidateNotNullOrEmpty()]
    [hashtable]$Query,

    # ISO interval string: "start/end" (UTC recommended)
    [Parameter(Mandatory, ParameterSetName = 'ByInterval')]
    [ValidateNotNullOrEmpty()]
    [string]$Interval,

    [Parameter(ParameterSetName = 'ByInterval')]
    [int]$PageSize = 100,

    [Parameter(ParameterSetName = 'ByInterval')]
    [string]$Cursor,

    # Optional body filters you may add later; PR2 keeps it flexible
    [Parameter(ParameterSetName = 'ByInterval')]
    [hashtable]$Filter
  )

  $path = '/api/v2/analytics/conversations/details/query'

  $body = if ($PSCmdlet.ParameterSetName -eq 'ByQuery') {
    $Query
  }
  else {
    $request = @{
      interval = $Interval
      paging   = @{ pageSize = $PageSize; pageNumber = 1 }
    }

    if ($Cursor) { $request.cursor = $Cursor }
    if ($Filter) { $request.filter = $Filter }

    $request
  }

  $resp = Invoke-GCRequest -Method POST -Path $path -Body $body

  return $resp
}
### END FILE
