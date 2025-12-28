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

    Test-GCInsightPackDefinition -Pack $pack | Out-Null
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
