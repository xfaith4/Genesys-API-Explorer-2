### BEGIN FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPack.ps1
function Invoke-GCInsightPack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackPath,

        [Parameter()]
        [hashtable]$Parameters,

        [Parameter()]
        [switch]$StrictValidation,

        [Parameter()]
        [switch]$DryRun,

        [Parameter()]
        [string]$BaseUri,

        [Parameter()]
        [string]$AccessToken,

        [Parameter()]
        [scriptblock]$TokenProvider,

        [Parameter()]
        [switch]$UseCache,

        [Parameter()]
        [ValidateRange(1, 43200)]
        [int]$CacheTtlMinutes = 60,

        [Parameter()]
        [string]$CacheDirectory
    )

    $resolvedPackPath = Resolve-GCInsightPackPath -PackPath $PackPath
    if (-not (Test-Path -LiteralPath $resolvedPackPath)) {
        throw "Insight pack not found: $PackPath"
    }

    $effectiveBaseUri = $BaseUri
    $effectiveAccessToken = $AccessToken
    $effectiveTokenProvider = $TokenProvider
    $contextWasOverridden = $false
    $previousContext = $null

    if (-not $effectiveBaseUri -and $script:GCContext) {
        if ($script:GCContext.PSObject.Properties.Name -contains 'ApiBaseUri' -and $script:GCContext.ApiBaseUri) {
            $effectiveBaseUri = $script:GCContext.ApiBaseUri
        }
        elseif ($script:GCContext.PSObject.Properties.Name -contains 'BaseUri' -and $script:GCContext.BaseUri) {
            $effectiveBaseUri = $script:GCContext.BaseUri
        }
    }
    if (-not $effectiveAccessToken -and $script:GCContext -and ($script:GCContext.PSObject.Properties.Name -contains 'AccessToken')) {
        $effectiveAccessToken = $script:GCContext.AccessToken
    }
    if (-not $effectiveAccessToken -and $global:AccessToken) {
        $effectiveAccessToken = $global:AccessToken
    }
    if (-not $effectiveTokenProvider -and $script:GCContext -and ($script:GCContext.PSObject.Properties.Name -contains 'TokenProvider')) {
        $effectiveTokenProvider = $script:GCContext.TokenProvider
    }

    if ($PSBoundParameters.ContainsKey('BaseUri') -or $PSBoundParameters.ContainsKey('AccessToken') -or $PSBoundParameters.ContainsKey('TokenProvider')) {
        $previousContext = $script:GCContext
        $contextWasOverridden = $true

        $regionDomain = $null
        if ($script:GCContext -and ($script:GCContext.PSObject.Properties.Name -contains 'RegionDomain') -and $script:GCContext.RegionDomain) {
            $regionDomain = $script:GCContext.RegionDomain
        }
        if (-not $regionDomain -and $effectiveBaseUri) {
            try {
                $uri = [uri]$effectiveBaseUri
                if ($uri.Host -match '^api\.(.+)$') {
                    $regionDomain = $Matches[1]
                }
            }
            catch { }
        }

        Set-GCContext -RegionDomain (if ($regionDomain) { $regionDomain } else { 'usw2.pure.cloud' }) -ApiBaseUri $effectiveBaseUri -AccessToken $effectiveAccessToken -TokenProvider $effectiveTokenProvider | Out-Null
    }

    if ($script:GCContext) {
        if (-not $effectiveBaseUri -and ($script:GCContext.PSObject.Properties.Name -contains 'ApiBaseUri') -and $script:GCContext.ApiBaseUri) {
            $effectiveBaseUri = $script:GCContext.ApiBaseUri
        }
        if (-not $effectiveBaseUri -and ($script:GCContext.PSObject.Properties.Name -contains 'BaseUri') -and $script:GCContext.BaseUri) {
            $effectiveBaseUri = $script:GCContext.BaseUri
        }
        if (-not $effectiveAccessToken -and ($script:GCContext.PSObject.Properties.Name -contains 'AccessToken')) {
            $effectiveAccessToken = $script:GCContext.AccessToken
        }
        if (-not $effectiveTokenProvider -and ($script:GCContext.PSObject.Properties.Name -contains 'TokenProvider')) {
            $effectiveTokenProvider = $script:GCContext.TokenProvider
        }
    }

    $baseSignature = ''
    if ($effectiveBaseUri) {
        try {
            $baseSignature = ([uri]$effectiveBaseUri).GetLeftPart('Authority').TrimEnd('/').ToLowerInvariant()
        }
        catch { $baseSignature = $effectiveBaseUri.TrimEnd('/').ToLowerInvariant() }
    }

    try {
        if ($null -eq $Parameters) { $Parameters = @{} }

		    $packJson = Get-Content -LiteralPath $resolvedPackPath -Raw
		    if ($StrictValidation) {
		        Test-GCInsightPackSchema -Json $packJson | Out-Null
		    }
		    $pack = $packJson | ConvertFrom-Json

        Test-GCInsightPackDefinition -Pack $pack -Strict:$StrictValidation | Out-Null
        $resolvedParameters = Get-GCInsightPackParameters -Pack $pack -Overrides $Parameters

        $ctx = [pscustomobject]@{
            Pack       = $pack
            Parameters = $resolvedParameters
            Data       = [ordered]@{}
            Metrics    = New-Object System.Collections.ArrayList
            Drilldowns = New-Object System.Collections.ArrayList
            Steps      = New-Object System.Collections.ArrayList
            GeneratedUtc = (Get-Date).ToUniversalTime()
        }

		    $effectiveCacheRootDir = $null
		    $effectiveRequestCacheDir = $null
		    $effectivePackCacheDir = $null
		    if ($UseCache -and (-not $DryRun)) {
		        $effectiveCacheRootDir = if ($CacheDirectory) { $CacheDirectory } else { Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'GenesysCloud.OpsInsights.Cache' }
		        $effectiveRequestCacheDir = Join-Path -Path $effectiveCacheRootDir -ChildPath 'requests'
		        $effectivePackCacheDir = Join-Path -Path $effectiveCacheRootDir -ChildPath 'packs'

		        foreach ($dir in @($effectiveCacheRootDir, $effectiveRequestCacheDir, $effectivePackCacheDir)) {
		            if (-not (Test-Path -LiteralPath $dir)) {
		                New-Item -ItemType Directory -Path $dir -Force | Out-Null
		            }
		        }
		    }

        function Get-CacheKeyHex {
            param([Parameter(Mandatory)][string]$Value)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
            return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
        }

        function Invoke-GCInsightCachedRequest {
            param(
                [Parameter(Mandatory)][string]$StepId,
                [Parameter(Mandatory)][string]$Method,
                [Parameter()][string]$PathWithQuery,
                [Parameter()][string]$Uri,
                [Parameter()][hashtable]$Headers,
                [Parameter()][object]$Body
            )

		        $cacheHit = $false
		        $cachePath = $null
		        $legacyCachePath = $null
		        if ($effectiveRequestCacheDir) {
		            $bodyJson = if ($Body) { ($Body | ConvertTo-Json -Depth 50) } else { '' }
		            $pathPart = if ($null -ne $PathWithQuery) { [string]$PathWithQuery } else { '' }
		            $uriPart = if ($null -ne $Uri) { [string]$Uri } else { '' }
		            $keyValue = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f $pack.id, $StepId, $Method, $pathPart, $uriPart, $bodyJson, $baseSignature
		            $cacheKey = Get-CacheKeyHex -Value $keyValue
		            $cachePath = Join-Path -Path $effectiveRequestCacheDir -ChildPath ("{0}.json" -f $cacheKey)
		            $legacyCachePath = if ($effectiveCacheRootDir) { Join-Path -Path $effectiveCacheRootDir -ChildPath ("{0}.json" -f $cacheKey) } else { $null }

	            $readPath = $null
	            if (Test-Path -LiteralPath $cachePath) { $readPath = $cachePath }
	            elseif ($legacyCachePath -and (Test-Path -LiteralPath $legacyCachePath)) { $readPath = $legacyCachePath }

	            if ($readPath) {
	                $ageMinutes = ((Get-Date) - (Get-Item -LiteralPath $readPath).LastWriteTime).TotalMinutes
	                if ($ageMinutes -lt $CacheTtlMinutes) {
	                    try {
	                        $cachedRaw = Get-Content -LiteralPath $readPath -Raw
	                        if (-not [string]::IsNullOrWhiteSpace($cachedRaw)) {
	                            $cacheHit = $true
	                            return [pscustomobject]@{
	                                CacheHit = $true
                                Value    = ($cachedRaw | ConvertFrom-Json)
                            }
                        }
                    }
                    catch { }
                }
            }
        }

        $splat = @{ Method = $Method; Headers = $Headers }
        if ($Uri) { $splat.Uri = $Uri }
        elseif ($PathWithQuery) { $splat.Path = $PathWithQuery }
        else { throw "Invoke-GCInsightCachedRequest requires Uri or PathWithQuery." }
        if ($effectiveBaseUri) { $splat.BaseUri = $effectiveBaseUri }
        if ($effectiveAccessToken) { $splat.AccessToken = $effectiveAccessToken }
        if ($Body) { $splat.Body = $Body }

	        $response = Invoke-GCRequest @splat
	        if ($cachePath) {
	            try { ($response | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $cachePath -Encoding utf8 -Force } catch { }
	        }
        return [pscustomobject]@{
            CacheHit = $false
            Value    = $response
        }
    }

    foreach ($step in @($pack.pipeline)) {
        if (-not $step.id) { throw "Insight pack step missing 'id' property." }

        $log = New-GCInsightStepLog -StepDefinition $step
        $started = Get-Date

        try {
            switch ($step.type.ToLowerInvariant()) {
                'gcrequest' {
                    $method = if ($step.method) { $step.method.ToUpper() } else { 'GET' }
                    $pathTemplate = if ($step.uri) { $step.uri } elseif ($step.path) { $step.path } else { throw "gcRequest step '$($step.id)' requires 'uri' or 'path'." }
                    $resolvedPath = Resolve-GCInsightTemplateString -Template $pathTemplate -Parameters $ctx.Parameters
                    $querySuffix = Resolve-GCInsightPackQueryString -QueryTemplate $step.query -Parameters $ctx.Parameters

                    $headers = Resolve-GCInsightPackHeaders -HeadersTemplate $step.headers -Parameters $ctx.Parameters

                    $body = $null
                    if ($step.bodyTemplate) {
                        $body = Get-TemplatedObject -Template $step.bodyTemplate -Parameters $ctx.Parameters
                    }

                    $requestSplat = @{
                        Method = $method
                        Headers = $headers
                    }

                    $pathWithQuery = $resolvedPath + $querySuffix
                    if ($pathWithQuery -match '^https?://') {
                        $requestSplat.Uri = $pathWithQuery
                    }
                    else {
                        $requestSplat.Path = $pathWithQuery
                    }

                    if ($body) {
                        $requestSplat.Body = $body
                    }

                    if ($DryRun) {
                        $planned = [pscustomobject]@{
                            Method  = $method
                            Path    = if ($requestSplat.ContainsKey('Path')) { $requestSplat.Path } else { $null }
                            Uri     = if ($requestSplat.ContainsKey('Uri')) { $requestSplat.Uri } else { $null }
                            Headers = $headers
                            Body    = $body
                        }
                        $ctx.Data[$step.id] = $planned
                        $log.ResultSummary = "DRY RUN: HTTP $method → $pathWithQuery"
                    }
                    else {
                        $cacheResult = Invoke-GCInsightCachedRequest -StepId $step.id -Method $method -PathWithQuery ($requestSplat.Path) -Uri ($requestSplat.Uri) -Headers $headers -Body $body
	        $ctx.Data[$step.id] = $cacheResult.Value
	        if ($cacheResult.CacheHit) {
	            $log.ResultSummary = "CACHE HIT: HTTP $method → $pathWithQuery"
	        }
	        else {
	            $log.ResultSummary = "HTTP $method → $pathWithQuery (received status: $($cacheResult.Value.statusCode -or 'OK'))"
	        }
	    }
                }

                'compute' {
                    if (-not $step.script) { throw "Compute step '$($step.id)' requires a script block." }
                    $scriptBlock = [scriptblock]::Create($step.script)
                    $result = & $scriptBlock $ctx
                    $ctx.Data[$step.id] = $result
                    $log.ResultSummary = if ($DryRun) { "DRY RUN: Computed '$($step.id)'" } else { "Computed '$($step.id)'" }
                }

                'metric' {
                    if (-not $step.script) { throw "Metric step '$($step.id)' requires a script block." }
                    $scriptBlock = [scriptblock]::Create($step.script)
                    $metric = & $scriptBlock $ctx
                    if ($metric) {
                        $ctx.Metrics.Add($metric) | Out-Null
                        $title = if ($metric.PSObject.Properties.Name -contains 'title') { $metric.title } else { $step.id }
                        $log.ResultSummary = if ($DryRun) { "DRY RUN: Metric '$title'" } else { "Metric '$title'" }
                    }
                }

                'drilldown' {
                    if (-not $step.script) { throw "Drilldown step '$($step.id)' requires a script block." }
                    $scriptBlock = [scriptblock]::Create($step.script)
                    $drilldown = & $scriptBlock $ctx
                    if ($drilldown) {
                        $ctx.Drilldowns.Add($drilldown) | Out-Null
                        $log.ResultSummary = if ($DryRun) { "DRY RUN: Drilldown '$($step.id)'" } else { "Drilldown '$($step.id)'" }
                    }
                }

                'assert' {
                    if (-not $step.script) { throw "Assert step '$($step.id)' requires a script block." }
                    $scriptBlock = [scriptblock]::Create($step.script)
                    $ok = & $scriptBlock $ctx
                    $passed = [bool]$ok
                    if (-not $passed) {
                        $msg = if ($step.message) { [string]$step.message } else { "Assertion failed in step '$($step.id)'." }
                        throw $msg
                    }
                    $log.ResultSummary = if ($DryRun) { "DRY RUN: Assert '$($step.id)'" } else { "Assert '$($step.id)' passed" }
                }

                'foreach' {
                    if (-not $step.itemsScript) { throw "Foreach step '$($step.id)' requires 'itemsScript'." }
                    if (-not $step.itemScript) { throw "Foreach step '$($step.id)' requires 'itemScript'." }

                    $itemsBlock = [scriptblock]::Create([string]$step.itemsScript)
                    $itemBlock = [scriptblock]::Create([string]$step.itemScript)

                    $items = @(& $itemsBlock $ctx)
                    $results = New-Object System.Collections.ArrayList

                    $oldItem = $null
                    $hadOldItem = $ctx.Data.Contains('item')
                    if ($hadOldItem) { $oldItem = $ctx.Data['item'] }

                    try {
                        foreach ($item in $items) {
                            $ctx.Data['item'] = $item
                            $res = & $itemBlock $ctx $item
                            if ($null -ne $res) { [void]$results.Add($res) }
                        }
                    }
                    finally {
                        if ($hadOldItem) { $ctx.Data['item'] = $oldItem } else { [void]$ctx.Data.Remove('item') }
                    }

                    $ctx.Data[$step.id] = @($results)
                    $log.ResultSummary = if ($DryRun) { "DRY RUN: Foreach '$($step.id)' ($($items.Count) items)" } else { "Foreach '$($step.id)' ($($items.Count) items)" }
                }

	                'jobpoll' {
                    if (-not $step.create) { throw "JobPoll step '$($step.id)' requires 'create' definition." }

                    $pollIntervalSec = 2
                    if ($step.pollIntervalSec) {
                        try { $pollIntervalSec = [int]$step.pollIntervalSec } catch { $pollIntervalSec = 2 }
                    }
                    if ($pollIntervalSec -lt 1) { $pollIntervalSec = 1 }

                    $maxWaitSec = 900
                    if ($step.maxWaitSec) {
                        try { $maxWaitSec = [int]$step.maxWaitSec } catch { $maxWaitSec = 900 }
                    }
                    if ($maxWaitSec -lt 10) { $maxWaitSec = 10 }

                    $maxPages = 2000
                    if ($step.maxPages) {
                        try { $maxPages = [int]$step.maxPages } catch { $maxPages = 2000 }
                    }
                    if ($maxPages -lt 1) { $maxPages = 1 }

                    $doneRegex = if ($step.doneRegex) { [string]$step.doneRegex } else { 'FULFILLED|COMPLETED' }
                    $failRegex = if ($step.failRegex) { [string]$step.failRegex } else { 'FAILED|ERROR' }
                    $resultsItemField = if ($step.collect) { [string]$step.collect } else { 'conversations' }

                    $createMethod = if ($step.create.method) { ([string]$step.create.method).ToUpperInvariant() } else { 'POST' }
                    $createPathTemplate = if ($step.create.uri) { [string]$step.create.uri } elseif ($step.create.path) { [string]$step.create.path } else { '/api/v2/analytics/conversations/details/jobs' }
                    $createPath = Resolve-GCInsightTemplateString -Template $createPathTemplate -Parameters $ctx.Parameters
                    $createHeaders = Resolve-GCInsightPackHeaders -HeadersTemplate $step.create.headers -Parameters $ctx.Parameters
                    $createBody = $null
                    if ($step.create.bodyTemplate) {
                        $createBody = Get-TemplatedObject -Template $step.create.bodyTemplate -Parameters $ctx.Parameters
                    }

                    $statusPathTemplate = if ($step.statusPath) { [string]$step.statusPath } else { '/api/v2/analytics/conversations/details/jobs/{{jobId}}' }
                    $resultsPathTemplate = if ($step.resultsPath) { [string]$step.resultsPath } else { '/api/v2/analytics/conversations/details/jobs/{{jobId}}/results' }

                    if ($DryRun) {
                        $ctx.Data[$step.id] = [pscustomobject]@{
                            Planned = @(
                                [pscustomobject]@{ Method = $createMethod; Path = $createPath; Body = $createBody },
                                [pscustomobject]@{ Method = 'GET'; Path = $statusPathTemplate },
                                [pscustomobject]@{ Method = 'GET'; Path = $resultsPathTemplate }
                            )
                        }
                        $log.ResultSummary = "DRY RUN: JobPoll $createMethod → $createPath"
                    }
                    else {
                        $createSplat = @{ Method = $createMethod; Headers = $createHeaders }
                        if ($effectiveBaseUri) { $createSplat.BaseUri = $effectiveBaseUri }
                        if ($effectiveAccessToken) { $createSplat.AccessToken = $effectiveAccessToken }
                        if ($createPath -match '^https?://') { $createSplat.Uri = $createPath } else { $createSplat.Path = $createPath }
                        if ($createBody) { $createSplat.Body = $createBody }

                        $job = Invoke-GCRequest @createSplat
                        $jobId = $job.id
                        if ([string]::IsNullOrWhiteSpace([string]$jobId)) { throw "JobPoll step '$($step.id)' did not receive a job id." }

                            $statusPath = Resolve-GCInsightTemplateString -Template $statusPathTemplate -Parameters (@{ jobId = $jobId })
                            $deadline = (Get-Date).AddSeconds($maxWaitSec)
                            $state = $null
                            while ($true) {
                                if ((Get-Date) -gt $deadline) { throw "JobPoll step '$($step.id)' timed out after ${maxWaitSec}s waiting for job $jobId." }
                                Start-Sleep -Seconds $pollIntervalSec
	                            $status = Invoke-GCRequest -Method GET -Path $statusPath -BaseUri $effectiveBaseUri -AccessToken $effectiveAccessToken
	                            $stateValue = ''
	                            if ($status) {
	                                if (($status.PSObject.Properties.Name -contains 'state') -and $status.state) { $stateValue = $status.state }
	                                elseif (($status.PSObject.Properties.Name -contains 'status') -and $status.status) { $stateValue = $status.status }
	                            }
	                            $state = [string]$stateValue
	                            if ($state -match $doneRegex) { break }
	                            if ($state -match $failRegex) { throw "Job $jobId failed (state=$state)" }
	                        }

                        $resultsPathBase = Resolve-GCInsightTemplateString -Template $resultsPathTemplate -Parameters (@{ jobId = $jobId })
                        $cursor = $null
                        $pages = 0
                        $itemsOut = New-Object System.Collections.ArrayList
                        do {
                            $pages++
                            if ($pages -gt $maxPages) { throw "JobPoll step '$($step.id)' exceeded maxPages=$maxPages." }

                            $path = $resultsPathBase
                            if ($cursor) {
                                $path = $path + "?cursor=" + [System.Uri]::EscapeDataString([string]$cursor)
                            }
                            $page = Invoke-GCRequest -Method GET -Path $path -BaseUri $effectiveBaseUri -AccessToken $effectiveAccessToken

                            $batch = @()
                            if ($page -and ($page.PSObject.Properties.Name -contains $resultsItemField)) {
                                $batch = @($page.$resultsItemField)
                            }
                            foreach ($it in $batch) { [void]$itemsOut.Add($it) }

                            $cursor = $page.cursor
                        } while ($cursor)

                        $ctx.Data[$step.id] = [pscustomobject]@{
                            JobId     = $jobId
                            FinalState= $state
                            Pages     = $pages
                            Items     = @($itemsOut)
                        }
                        $log.ResultSummary = "JobPoll completed: jobId=$jobId items=$($itemsOut.Count) pages=$pages"
                    }
	                }

	                'cache' {
	                    if (-not $step.script) { throw "Cache step '$($step.id)' requires a script block." }

	                    if (-not $UseCache -or $DryRun) {
	                        $scriptBlock = [scriptblock]::Create([string]$step.script)
	                        $result = & $scriptBlock $ctx
	                        $ctx.Data[$step.id] = $result
	                        $log.ResultSummary = if ($DryRun) { "DRY RUN: Cache disabled; computed '$($step.id)'" } else { "Cache disabled; computed '$($step.id)'" }
	                        break
	                    }

	                    $ttl = $CacheTtlMinutes
	                    if ($step.ttlMinutes) {
	                        try { $ttl = [int]$step.ttlMinutes } catch { $ttl = $CacheTtlMinutes }
	                    }
	                    if ($ttl -lt 1) { $ttl = 1 }

	                    $cacheDir = if ($step.cacheDirectory) { [string]$step.cacheDirectory } else { $effectivePackCacheDir }
	                    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

	                    $keyTemplate = if ($step.keyTemplate) { [string]$step.keyTemplate } else { '' }
	                    $keyMaterial = if ($keyTemplate) { Resolve-GCInsightTemplateString -Template $keyTemplate -Parameters $ctx.Parameters } else { '' }
	                    $paramsJson = ($ctx.Parameters | ConvertTo-Json -Depth 30)
	                    $keyValue = "{0}|{1}|{2}|{3}|{4}|{5}" -f $pack.id, $pack.version, $step.id, $keyMaterial, $paramsJson, $baseSignature
	                    $cacheKey = Get-CacheKeyHex -Value $keyValue
	                    $cachePath = Join-Path -Path $cacheDir -ChildPath ("{0}.json" -f $cacheKey)

	                    if (Test-Path -LiteralPath $cachePath) {
	                        $ageMinutes = ((Get-Date) - (Get-Item -LiteralPath $cachePath).LastWriteTime).TotalMinutes
	                        if ($ageMinutes -lt $ttl) {
	                            try {
	                                $cachedRaw = Get-Content -LiteralPath $cachePath -Raw
	                                if (-not [string]::IsNullOrWhiteSpace($cachedRaw)) {
	                                    $cached = $cachedRaw | ConvertFrom-Json
	                                    $value = if ($cached -and ($cached.PSObject.Properties.Name -contains 'Value')) { $cached.Value } else { $cached }
	                                    $ctx.Data[$step.id] = $value
	                                    $log.ResultSummary = "CACHE HIT: '$($step.id)' (ttl=${ttl}m key=$cacheKey)"
	                                    break
	                                }
	                            }
	                            catch { }
	                        }
	                    }

	                    $scriptBlock = [scriptblock]::Create([string]$step.script)
	                    $value = & $scriptBlock $ctx
	                    $ctx.Data[$step.id] = $value

	                    try {
	                        $envelope = [pscustomobject]@{
	                            CachedAtUtc = (Get-Date).ToUniversalTime()
	                            PackId      = $pack.id
	                            PackVersion = $pack.version
	                            StepId      = $step.id
	                            KeyMaterial = $keyMaterial
	                            Parameters  = $ctx.Parameters
	                            Value       = $value
	                        }
	                        ($envelope | ConvertTo-Json -Depth 60) | Set-Content -LiteralPath $cachePath -Encoding utf8 -Force
	                    }
	                    catch { }

	                    $log.ResultSummary = "CACHE MISS: '$($step.id)' wrote key=$cacheKey (ttl=${ttl}m)"
	                }

	                'join' {
	                    $sourceStepId = [string]$step.sourceStepId
	                    if (-not $ctx.Data.Contains($sourceStepId)) { throw "Join step '$($step.id)' cannot find sourceStepId '$sourceStepId'." }

                    $itemsProperty = if ($step.itemsProperty) { [string]$step.itemsProperty } else { 'Items' }
                    $sourceObj = $ctx.Data[$sourceStepId]
                    $items = @()
                    if ($sourceObj -is [System.Collections.IEnumerable] -and -not ($sourceObj -is [string]) -and -not ($sourceObj -is [hashtable]) -and -not ($sourceObj.PSObject.Properties.Name -contains $itemsProperty)) {
                        $items = @($sourceObj)
                    }
                    else {
                        if ($sourceObj -and ($sourceObj.PSObject.Properties.Name -contains $itemsProperty)) {
                            $items = @($sourceObj.$itemsProperty)
                        }
                        elseif ($sourceObj -is [System.Collections.IEnumerable] -and -not ($sourceObj -is [string])) {
                            $items = @($sourceObj)
                        }
                    }

                    $keyName = [string]$step.key
                    $assignProperty = if ($step.assign) { [string]$step.assign } else { 'joined' }
                    $maxUnique = if ($step.maxUnique) { [int]$step.maxUnique } else { 200 }
                    if ($maxUnique -lt 1) { $maxUnique = 1 }

                    $lookup = $step.lookup
                    $method = if ($lookup.method) { ([string]$lookup.method).ToUpperInvariant() } else { 'GET' }
                    $template = if ($lookup.uri) { [string]$lookup.uri } else { [string]$lookup.path }
                    $headers = Resolve-GCInsightPackHeaders -HeadersTemplate $lookup.headers -Parameters $ctx.Parameters

                    $ids = New-Object System.Collections.Generic.HashSet[string]
                    foreach ($it in $items) {
                        if (-not $it) { continue }
                        $val = $null
                        try {
                            if ($it.PSObject.Properties.Name -contains $keyName) { $val = $it.$keyName }
                        }
                        catch { }
                        if ($null -eq $val) { continue }
                        $s = [string]$val
                        if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$ids.Add($s) }
                    }

                    $idList = @($ids)
                    if ($idList.Count -gt $maxUnique) { $idList = @($idList | Select-Object -First $maxUnique) }

                    $lookupById = @{}
                    foreach ($id in $idList) {
                        $resolvedPath = Resolve-GCInsightTemplateString -Template $template -Parameters (@{ id = $id })

                        if ($DryRun) {
                            $lookupById[$id] = [pscustomobject]@{ Planned = $resolvedPath }
                            continue
                        }

                        $pathWithQuery = $resolvedPath
                        $cacheResult = if ($pathWithQuery -match '^https?://') {
                            Invoke-GCInsightCachedRequest -StepId $step.id -Method $method -Uri $pathWithQuery -Headers $headers
                        } else {
                            Invoke-GCInsightCachedRequest -StepId $step.id -Method $method -PathWithQuery $pathWithQuery -Headers $headers
                        }
                        $lookupById[$id] = $cacheResult.Value
                    }

                    $enriched = foreach ($it in $items) {
                        if (-not $it) { continue }
                        $copy = $it | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                        $id = $null
                        try { if ($copy.PSObject.Properties.Name -contains $keyName) { $id = [string]$copy.$keyName } } catch { }
                        if ($id -and $lookupById.ContainsKey($id)) {
                            $copy | Add-Member -MemberType NoteProperty -Name $assignProperty -Value $lookupById[$id] -Force
                        }
                        $copy
                    }

                    $ctx.Data[$step.id] = @($enriched)
                    $log.ResultSummary = if ($DryRun) { "DRY RUN: Join '$($step.id)' ($($idList.Count) lookups)" } else { "Join '$($step.id)' ($($idList.Count) lookups)" }
                }

                default {
                    throw "Unsupported insight pack step type: $($step.type)"
                }
            }

            $log.Status = 'Success'
        }
        catch {
            $log.Status = 'Failed'
            $log.ErrorMessage = $_.Exception.Message
            throw
        }
        finally {
            $ended = Get-Date
            $log.EndedUtc = $ended.ToUniversalTime()
            $log.DurationMs = [math]::Round(($ended - $started).TotalMilliseconds, 0)
            $ctx.Steps.Add($log) | Out-Null
        }
    }

    $result = [pscustomobject]@{
        Pack        = $pack
        Parameters  = $ctx.Parameters
        Data        = $ctx.Data
        Metrics     = $ctx.Metrics
        Drilldowns  = $ctx.Drilldowns
        Steps       = $ctx.Steps
        GeneratedUtc= $ctx.GeneratedUtc
    }

    # Optional evidence script (pack-authored) to populate richer evidence fields
    if ($pack.PSObject.Properties.Name -contains 'evidenceScript' -and $pack.evidenceScript) {
        try {
            $evidenceBlock = [scriptblock]::Create([string]$pack.evidenceScript)
            $evidenceOverride = & $evidenceBlock $ctx
            if ($evidenceOverride) {
                $result | Add-Member -MemberType NoteProperty -Name EvidenceOverride -Value $evidenceOverride -Force
            }
        }
        catch {
            # Don't block results on evidence enrichment issues; surface in Evidence
            $result | Add-Member -MemberType NoteProperty -Name EvidenceOverride -Value ([pscustomobject]@{ Narrative = "Evidence script error: $($_.Exception.Message)" }) -Force
        }
    }

        $result | Add-Member -MemberType NoteProperty -Name Evidence -Value (New-GCInsightEvidencePacket -Result $result) -Force

        return $result
    }
    finally {
        if ($contextWasOverridden) {
            $script:GCContext = $previousContext
        }
    }
}
### END FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPack.ps1
