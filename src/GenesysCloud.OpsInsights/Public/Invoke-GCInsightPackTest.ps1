### BEGIN FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPackTest.ps1
function Invoke-GCInsightPackTest {
    <#
      .SYNOPSIS
        Runs an insight pack offline using fixture-backed HTTP responses.
      .DESCRIPTION
        Uses Set-GCInvoker to intercept Invoke-GCRequest calls and return JSON fixtures from disk.
        Fixture key: SHA256( "{METHOD}|{PathAndQuery}|{BodyJsonString}" ) stored as "<hash>.json" in the fixture directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FixturesDirectory,

        [Parameter()]
        [hashtable]$Parameters,

        [Parameter()]
        [switch]$Strict
    )

    if (-not (Test-Path -LiteralPath $PackPath)) {
        throw "Pack not found: $PackPath"
    }
    if (-not (Test-Path -LiteralPath $FixturesDirectory)) {
        throw "Fixtures directory not found: $FixturesDirectory"
    }

    if ($null -eq $Parameters) { $Parameters = @{} }

    function Get-FixtureHash {
        param(
            [Parameter(Mandatory)][string]$Method,
            [Parameter(Mandatory)][string]$PathAndQuery,
            [Parameter()][string]$Body
        )

        $source = "{0}|{1}|{2}" -f $Method.ToUpperInvariant(), $PathAndQuery, ($Body ?? '')
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($source)
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }

    $missing = New-Object System.Collections.Generic.List[object]
    $calls = 0

    $invoker = {
        param([hashtable]$Request)

        $calls++
        $method = [string]$Request.Method
        $uri = [uri]$Request.Uri
        $pathAndQuery = [string]$uri.PathAndQuery
        $body = if ($Request.Body) { [string]$Request.Body } else { '' }

        $hash = Get-FixtureHash -Method $method -PathAndQuery $pathAndQuery -Body $body
        $fixturePath = Join-Path -Path $FixturesDirectory -ChildPath ("{0}.json" -f $hash)

        if (-not (Test-Path -LiteralPath $fixturePath)) {
            $missing.Add([pscustomobject]@{
                Method      = $method
                PathAndQuery= $pathAndQuery
                Body        = $body
                Hash        = $hash
                FixturePath = $fixturePath
            }) | Out-Null

            throw "Missing fixture for $method $pathAndQuery (hash=$hash). Expected: $fixturePath"
        }

        $raw = Get-Content -LiteralPath $fixturePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return ($raw | ConvertFrom-Json)
    }

    $originalInvoker = $script:GCInvoker
    try {
        Set-GCInvoker -Invoker $invoker
        $result = Invoke-GCInsightPack -PackPath $PackPath -Parameters $Parameters

        return [pscustomobject]@{
            PackPath          = $PackPath
            FixturesDirectory = $FixturesDirectory
            Calls             = $calls
            MissingFixtures   = $missing.ToArray()
            Result            = $result
        }
    }
    catch {
        if ($Strict) { throw }
        return [pscustomobject]@{
            PackPath          = $PackPath
            FixturesDirectory = $FixturesDirectory
            Calls             = $calls
            MissingFixtures   = $missing.ToArray()
            Error             = $_.Exception.Message
        }
    }
    finally {
        $script:GCInvoker = $originalInvoker
    }
}
### END FILE: src\GenesysCloud.OpsInsights\Public\Invoke-GCInsightPackTest.ps1
