### BEGIN FILE: GenesysAPIExplorer_ExtractedPagination.ps1
<#
  Extracted from Ben's phone photos (GenesysAPItoolbox.psm1 snippets).

  Notes:
  - I did my best to transcribe exactly; spot-check anything mission-critical.
  - I sanitized ONE environment-specific path (UNC log share) so this is portable.
    If you want it exact, replace $LogDirectory with your original UNC path.
#>

### BEGIN: Invoke-WithRetry
function Invoke-WithRetry {
    <#
    .DESCRIPTION
      Runs the provided scriptblock, retrying on exceptions up to the specified maximum attempts with a delay between attempts.
      If a rate limit error is detected with a "Retry the request in [xx] seconds" message, the delay will be dynamically set
      based on the value provided in the error response.

    .PARAMETER ScriptBlock
      The code to execute.

    .PARAMETER MaxRetries
      Maximum number of retries (default: 3).

    .PARAMETER DelaySeconds
      Default delay in seconds between retries (default: 2).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$ScriptBlock,

        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $errorMessage = $_.Exception.Message
            $responseContent = $null

            # Attempt to extract the Response body if available (for Invoke-RestMethod/WebException)
            if ($_.Exception.PSObject.Properties['Response']) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $responseContent = $reader.ReadToEnd()
                    $reader.Close()
                }
                catch { }
            }

            # If we have a JSON response, try to parse it for the message
            $retryDelay = $DelaySeconds
            $parsedMessage = $errorMessage

            if ($responseContent) {
                try {
                    $json = $responseContent | ConvertFrom-Json
                    if ($json.message) {
                        $parsedMessage = $json.message

                        # Regex: find "Retry the request in [xx] seconds"
                        if ($parsedMessage -match 'Retry the request in \[(\d+)\] seconds') {
                            $retryDelay = [int]$matches[1]
                        }
                    }
                }
                catch { }
            }
            else {
                # Fallback: parse the exception message text
                if ($errorMessage -match 'Retry the request in \[(\d+)\] seconds') {
                    $retryDelay = [int]$matches[1]
                }
            }

            if ($attempt -eq $MaxRetries) {
                return "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')Operation failed after $MaxRetries attempts: $parsedMessage"
            }
            else {
                Write-Warning "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') Transient error detected: $parsedMessage. Retrying in $retryDelay seconds ($attempt/$MaxRetries)..."

                # Optional: custom logging function, replace or remove as needed
                if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') Transient error detected: $parsedMessage. Retrying in $retryDelay seconds ($attempt/$MaxRetries)..." -Level "WARN" -ScriptName "Invoke-WithRetry"
                    Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') Transient error detected: $parsedMessage. Retrying in $retryDelay seconds ($attempt/$MaxRetries)..."
                }

                Start-Sleep -Seconds $retryDelay
            }
        }
    }
}
### END: Invoke-WithRetry

### BEGIN: Get-DateInterval
function Get-DateInterval {
    $startDate = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd") + 'T04:00:00.000Z'
    $endDate = (Get-Date).ToString("yyyy-MM-dd") + 'T04:00:00.000Z'
    $interval = "$startDate" + "/" + "$endDate"
    return $interval
}
### END: Get-DateInterval

### BEGIN: Write-Log
function Write-Log {
    <#
    .SYNOPSIS
      Writes a log entry to a specified file.

    .DESCRIPTION
      Writes a log entry to a specified file. The log entry includes the current timestamp, log level, and message.
      The log file is created in the specified directory if it does not exist.
      The log file is rotated (archived) if it exceeds a specified size.

    .PARAMETER Message
      The log message.

    .PARAMETER Level
      The log level.
      Valid values: TRACE, DEBUG, INFO, WARN, ERROR, FATAL.

    .PARAMETER ScriptName
      The name of the script.

    .EXAMPLE
      Write-Log -Message "This is a log message" -Level INFO
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL")]
        [string]$Level = "INFO",

        [Parameter(Mandatory = $false)]
        [string]$ScriptName
    )

    # Define the log file path (SANITIZED for portability)
    # Original was a UNC share. Swap this back if desired.
    # $LogDirectory = "\\louvappwps1943.rsc.humad.com\automationlogs"
    $LogDirectory = Join-Path -Path $PSScriptRoot -ChildPath "automationlogs"

    if (-not (Test-Path -Path $LogDirectory)) {
        try {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Error "Failed to create log directory '$LogDirectory'. Error: $_"
            return
        }
    }

    $LogFile = Join-Path -Path $LogDirectory -ChildPath "$ScriptName.log"
    $timeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timeStamp [$Level] $Message"

    # Implement log rotation (e.g., rotate if file exceeds 5MB)
    $maxSize = 5MB
    if (Test-Path -Path $LogFile) {
        try {
            if ((Get-Item $LogFile).Length -gt $maxSize) {
                $archivePath = "$LogFile.$((Get-Date).ToString('yyyyMMddHHmmss')).bak"
                Move-Item -Path $LogFile -Destination $archivePath -Force
            }
        }
        catch {
            Write-Error "Failed to rotate log file '$LogFile'. Error: $_"
            return
        }
    }

    # Write log entry with error handling
    try {
        Add-Content -Path $LogFile -Value $logEntry
    }
    catch {
        Write-Error "Failed to write to log file '$LogFile'. Error: $_"
    }
}
### END: Write-Log

### BEGIN: Invoke-GenesysCloudAPI
function Invoke-GenesysCloudAPI {
    <#
    .SYNOPSIS
      Invokes Genesys Cloud API endpoints, supporting both page and cursor pagination.

    .DESCRIPTION
      Handles GET and POST requests, automatically paginating through results using either page-based or cursor-based approaches as indicated by the API response.
    #>
    param(
        [string]$ID,
        [string]$jobId,
        [string]$state,

        [Parameter(Mandatory = $true)]
        [string]$endpoint,

        [hashtable]$Headers = $null,
        [string]$Method = "GET",
        $Body = $null,

        [string]$InstanceName = "usw2.pure.cloud",

        [int]$pageNumber = 1,
        [int]$pageSize = 100,

        $Expand,
        [string]$OrgType,
        [switch]$DeleteJob,

        $queryParams = @{}
    )

    try {
        $ScriptName = $MyInvocation.MyCommand.Name
        $Global:results = New-Object System.Collections.Generic.List[object]
        $Global:response = @{}

        if (-not $Headers) {
            $Headers = @{}
        }

        $baseUrl = "https://api.$InstanceName/"

        if (-not $endpoint) {
            throw "Endpoint cannot be null or empty."
        }

        # Handle endpoints that include the literal '$ID' placeholder
        if ($endpoint -like '*$ID*') {
            # Replace the $ID placeholder with the provided ID value
            $endpoint = $endpoint.Replace('$ID', $ID)
            $uri = "$baseUrl$endpoint"
            $internalID = $true
        }
        else {
            $uri = "$baseUrl$endpoint"
            $internalID = $false
        }

        Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - $Method Query: $uri" -Level "INFO" -ScriptName $ScriptName
        Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - $Method Query: $uri"

        # Cursor-based pagination for fulfilled jobs
        if ($jobId -and ($state -eq "FULFILLED")) {
            $cursor = $null
            $pageCount = 1

            # Delete job if requested
            if ($DeleteJob) {
                $uri = "$baseUrl$endpoint/$jobId"
                try {
                    $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method "DELETE" }
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - DELETE Query: $uri" -Level "INFO" -ScriptName $ScriptName
                    Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - DELETE Query: $uri"
                    return $response
                }
                catch {
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - DELETE Query: $uri" -Level "ERROR" -ScriptName $ScriptName
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Error: $_" -Level "ERROR" -ScriptName $ScriptName
                    Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - DELETE Query: $uri - Error: $_"
                    return $null
                }
            }

            do {
                # Include cursor if present
                if ($cursor) {
                    $uri = "$($baseUrl)$($endpoint)/$($jobId)/results?cursor=$($cursor)"
                }
                else {
                    $uri = "$($baseUrl)$($endpoint)/$($jobId)/results"
                }

                $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method "GET" }
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "INFO" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri"

                if ($response.conversations) {
                    $results.AddRange($response.conversations)
                }

                $cursor = $response.cursor
                $pageCount++
            }
            while ($cursor)

            return $results
        }

        # If job is not fulfilled, return the job status
        if ($jobId -and ($state -ne "FULFILLED")) {
            $uri = "$baseUrl$endpoint/$jobId"

            try {
                $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method "GET" }
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "INFO" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri"
                return $response
            }
            catch {
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "ERROR" -ScriptName $ScriptName
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Error: $_" -Level "ERROR" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri - Error: $_"
                return $null
            }
        }

        # Build query string from parameters
        if ($pageSize) { $queryParams["pageSize"] = $pageSize }
        if ($pageNumber) { $queryParams["pageNumber"] = $pageNumber }
        if ($ID) { $queryParams["id"] = $ID }
        if ($Expand) { $queryParams["expand"] = $Expand }

        $queryString = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        if ($queryString) {
            $uri = "$($baseUrl)$($endpoint)?$($queryString)"
        }
        else {
            $uri = "$baseUrl$endpoint"
        }

        if (-not $uri) {
            throw "URI cannot be null or empty."
        }

        # If endpoint requires an ID (single object) or NoPage sentinel was passed, do not paginate
        if ($internalID -eq $true -or $ID -eq "NoPage") {
            try {
                $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method $Method }
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - $Method Query: $uri" -Level "INFO" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - $Method Query: $uri"
            }
            catch {
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - $Method Query: $uri" -Level "ERROR" -ScriptName $ScriptName
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Error: $_" -Level "ERROR" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - $Method Query: $uri - Error: $_"
                return $null
            }

            return $response
        }

        # Handle endpoints that use {conversationId}
        if ($endpoint -match '{conversationId}' -and $ID) {
            $endpoint = $endpoint.Replace('{conversationId}', $ID)
            $uri = "$baseUrl$endpoint"
        }

        # Send initial request
        try {
            if ($Method -eq "POST") {
                $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method $Method -Body $Body -ContentType 'application/json' }
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - POST Query: $uri" -Level "INFO" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - POST Query: $uri"
            }
            else {
                $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method $Method }
                Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "INFO" -ScriptName $ScriptName
                Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri"
            }
        }
        catch {
            Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "ERROR" -ScriptName $ScriptName
            Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Error: $_" -Level "ERROR" -ScriptName $ScriptName
            Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri - Error: $_"
            return $null
        }

        # Gather first page results
        if ($response.entities) { $results.AddRange($response.entities) }
        if ($response.results) { $results.AddRange($response.results) }
        if ($response.conversations) { $results.AddRange($response.conversations) }

        # Set cursor/page-based pagination
        $nextPage = $response.nextPage
        $nextUri = $response.nextUri
        $pageCount = $response.pageCount

        Write-Host "PageCount: $($pageCount)"
        Write-Host "NextPage:  $($nextPage)"
        Write-Host "NextUri:   $($nextUri)"
        Write-Host "PageNumber: $($pageNumber)"

        # Handle cursor/page-based pagination
        try {
            while ($nextPage -or $nextUri -or ($pageCount -gt 1)) {

                if ($nextPage) {
                    if ($nextPage -match "^[^/?]+=") {
                        $uri = "$baseUrl$endpoint?$nextPage"
                    }
                    elseif ($nextPage.StartsWith("/")) {
                        $uri = "$baseUrl$($nextPage.TrimStart('/'))"
                    }
                    else {
                        $uri = $nextPage
                    }
                }
                elseif ($nextUri) {
                    if ($nextUri -match "^[^/?]+=") {
                        $uri = "$baseUrl$endpoint?$nextUri"
                    }
                    elseif ($nextUri.StartsWith("/")) {
                        $uri = "$baseUrl$($nextUri.TrimStart('/'))"
                    }
                    else {
                        $uri = $nextUri
                    }
                }
                elseif ($pageCount -gt 1 -and $pageNumber -lt $pageCount) {
                    $pageNumber++
                    $uri = "$baseUrl$($endpoint)?pageSize=$($pageSize)&pageNumber=$($pageNumber)"
                }

                try {
                    $response = Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method $Method }
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "INFO" -ScriptName $ScriptName
                    Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri"
                }
                catch {
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "ERROR" -ScriptName $ScriptName
                    Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Error: $_" -Level "ERROR" -ScriptName $ScriptName
                    Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri - Error: $_"
                    return $null
                }

                if ($response.entities) { $results.AddRange($response.entities) }
                if ($response.results) { $results.AddRange($response.results) }
                if ($response.conversations) { $results.AddRange($response.conversations) }

                $nextPage = $response.nextPage
                $nextUri = $response.nextUri
                $pageNumber = $response.pageNumber

                if ($pageNumber -ge $pageCount) {
                    return $results
                }
            }
        }
        catch {
            Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri" -Level "ERROR" -ScriptName $ScriptName
            Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Error: $_" -Level "ERROR" -ScriptName $ScriptName
            Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - GET Query: $uri - Error: $_"
            return $null
        }

        if ($results.Count -gt 0) { return $results }
        else { return $response }
    }
    catch {
        Write-Log -Message "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Failed to invoke Genesys Cloud API. Error: $_" -Level "ERROR" -ScriptName "Invoke-GenesysCloudAPI"
        Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') - Failed to invoke Genesys Cloud API. Error: $_"
        return $null
    }
}
### END: Invoke-GenesysCloudAPI

### END FILE: GenesysAPIExplorer_ExtractedPagination.ps1
