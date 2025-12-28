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

    if ($null -eq $Parameters) { $Parameters = @{} }

    $packJson = Get-Content -LiteralPath $resolvedPackPath -Raw
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

    $effectiveCacheDir = $null
    if ($UseCache -and (-not $DryRun)) {
        $effectiveCacheDir = if ($CacheDirectory) { $CacheDirectory } else { Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'GenesysCloud.OpsInsights.Cache' }
        if (-not (Test-Path -LiteralPath $effectiveCacheDir)) {
            New-Item -ItemType Directory -Path $effectiveCacheDir -Force | Out-Null
        }
    }

    function Get-CacheKeyHex {
        param([Parameter(Mandatory)][string]$Value)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
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
                        $cacheHit = $false
                        $cachePath = $null
                        if ($effectiveCacheDir) {
                            $bodyJson = if ($body) { ($body | ConvertTo-Json -Depth 50) } else { '' }
                            $cacheKey = Get-CacheKeyHex -Value ("{0}|{1}|{2}|{3}|{4}" -f $pack.id, $step.id, $method, $pathWithQuery, $bodyJson)
                            $cachePath = Join-Path -Path $effectiveCacheDir -ChildPath ("{0}.json" -f $cacheKey)

                            if (Test-Path -LiteralPath $cachePath) {
                                $ageMinutes = ((Get-Date) - (Get-Item -LiteralPath $cachePath).LastWriteTime).TotalMinutes
                                if ($ageMinutes -lt $CacheTtlMinutes) {
                                    try {
                                        $cachedRaw = Get-Content -LiteralPath $cachePath -Raw
                                        if (-not [string]::IsNullOrWhiteSpace($cachedRaw)) {
                                            $ctx.Data[$step.id] = ($cachedRaw | ConvertFrom-Json)
                                            $cacheHit = $true
                                        }
                                    }
                                    catch {
                                        $cacheHit = $false
                                    }
                                }
                            }
                        }

                        if ($cacheHit) {
                            $log.ResultSummary = "CACHE HIT: HTTP $method → $pathWithQuery"
                        }
                        else {
                            $response = Invoke-GCRequest @requestSplat
                            $ctx.Data[$step.id] = $response
                            $log.ResultSummary = "HTTP $method → $pathWithQuery (received status: $($response.statusCode -or 'OK'))"

                            if ($cachePath) {
                                try {
                                    ($response | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $cachePath -Encoding utf8
                                }
                                catch {
                                    # ignore cache write errors
                                }
                            }
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
                            $status = Invoke-GCRequest -Method GET -Path $statusPath
                            $state = [string]($status.state ?? $status.status ?? '')
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
                            $page = Invoke-GCRequest -Method GET -Path $path

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

    $result | Add-Member -MemberType NoteProperty -Name Evidence -Value (New-GCInsightEvidencePacket -Result $result) -Force

    return $result
}
### END FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPack.ps1
