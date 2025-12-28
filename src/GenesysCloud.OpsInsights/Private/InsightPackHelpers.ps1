### BEGIN FILE: Private\InsightPackHelpers.ps1
function Get-GCInsightPackParameters {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Pack,
        [Parameter()]
        [hashtable]$Overrides
    )

    $result = [ordered]@{}
    $meta = @{}
    if ($Pack.parameters) {
        foreach ($prop in $Pack.parameters.PSObject.Properties) {
            $definition = $prop.Value

            $hasSchema = $false
            if ($definition -is [psobject]) {
                $propNames = @($definition.PSObject.Properties.Name)
                $hasSchema = ($propNames -contains 'type') -or ($propNames -contains 'required') -or ($propNames -contains 'default') -or ($propNames -contains 'description')
            }

            if ($hasSchema) {
                $meta[$prop.Name] = $definition
                $result[$prop.Name] = if ($definition.PSObject.Properties.Name -contains 'default') { $definition.default } else { $null }
            }
            else {
                $result[$prop.Name] = $definition
            }
        }
    }

    if ($Overrides) {
        foreach ($key in $Overrides.Keys) {
            $result[$key] = $Overrides[$key]
        }
    }

    foreach ($paramName in $meta.Keys) {
        $definition = $meta[$paramName]
        $isRequired = $false
        if ($definition.PSObject.Properties.Name -contains 'required') {
            $isRequired = [bool]$definition.required
        }

        $value = $result[$paramName]
        if ($isRequired) {
            $missing = ($null -eq $value) -or (($value -is [string]) -and [string]::IsNullOrWhiteSpace($value))
            if ($missing) {
                throw "Insight pack parameter '$paramName' is required."
            }
        }

        if ($definition.PSObject.Properties.Name -contains 'type' -and $definition.type) {
            $target = ([string]$definition.type).ToLowerInvariant()
            try {
                switch ($target) {
                    'string' { if ($null -ne $value) { $result[$paramName] = [string]$value } }
                    'int' { if ($null -ne $value) { $result[$paramName] = [int]$value } }
                    'number' { if ($null -ne $value) { $result[$paramName] = [double]$value } }
                    'bool' { if ($null -ne $value) { $result[$paramName] = [bool]$value } }
                    'datetime' { if ($null -ne $value) { $result[$paramName] = [datetime]$value } }
                    'timespan' { if ($null -ne $value) { $result[$paramName] = [timespan]$value } }
                }
            }
            catch {
                throw "Insight pack parameter '$paramName' could not be converted to type '$target': $($_.Exception.Message)"
            }
        }
    }

    return $result
}

function Resolve-GCInsightPackPath {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackPath
    )

    if (Test-Path -LiteralPath $PackPath) {
        return (Resolve-Path -LiteralPath $PackPath).ProviderPath
    }

    $leaf = Split-Path -Leaf $PackPath
    if (-not [string]::IsNullOrWhiteSpace($leaf)) {
        $candidates = @(
            (Join-Path -Path (Get-Location).ProviderPath -ChildPath (Join-Path -Path 'insights/packs' -ChildPath $leaf)),
            (Join-Path -Path (Get-Location).ProviderPath -ChildPath (Join-Path -Path 'insightpacks' -ChildPath $leaf))
        )

        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
        }
    }

    $normalized = $PackPath -replace '\\', '/'
    if ($normalized -match '(^|/)insightpacks(/|$)') {
        $rewritten = ($normalized -replace '(^|/)insightpacks(/|$)', '$1insights/packs$2')
        $rewritten = $rewritten -replace '/', '\\'
        if (Test-Path -LiteralPath $rewritten) { return (Resolve-Path -LiteralPath $rewritten).ProviderPath }
    }

    return $PackPath
}

function Test-GCInsightPackDefinition {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Pack,

        [Parameter()]
        [switch]$Strict
    )

    if (-not $Pack.id) { throw "Insight pack is missing 'id'." }
    if (-not $Pack.name) { throw "Insight pack '$($Pack.id)' is missing 'name'." }
    if (-not $Pack.version) { throw "Insight pack '$($Pack.id)' is missing 'version'." }
    if (-not $Pack.pipeline) { throw "Insight pack '$($Pack.id)' is missing 'pipeline'." }

    if ($Strict) {
        if ($Pack.maturity) {
            $m = [string]$Pack.maturity
            if ($m -notin @('alpha','beta','stable','deprecated')) {
                throw "Insight pack '$($Pack.id)' has invalid maturity '$m' (allowed: alpha, beta, stable, deprecated)."
            }
        }
        if ($null -ne $Pack.expectedRuntimeSec) {
            try { [void][int]$Pack.expectedRuntimeSec } catch { throw "Insight pack '$($Pack.id)' expectedRuntimeSec must be an integer." }
        }
        foreach ($arrField in @('scopes','tags','owners')) {
            if ($Pack.PSObject.Properties.Name -contains $arrField -and $null -ne $Pack.$arrField) {
                if (-not ($Pack.$arrField -is [System.Collections.IEnumerable])) {
                    throw "Insight pack '$($Pack.id)' field '$arrField' must be an array."
                }
            }
        }

        if ($Pack.parameters) {
            foreach ($prop in $Pack.parameters.PSObject.Properties) {
                $name = [string]$prop.Name
                $def = $prop.Value
                if ($def -is [psobject]) {
                    $names = @($def.PSObject.Properties.Name)
                    $isSchema = ($names -contains 'type') -or ($names -contains 'required') -or ($names -contains 'default') -or ($names -contains 'description')
                    if ($isSchema -and ($names -contains 'type') -and $def.type) {
                        $t = ([string]$def.type).ToLowerInvariant()
                        $allowed = @('string','int','number','bool','datetime','timespan','array','object')
                        if ($t -notin $allowed) {
                            throw "Insight pack '$($Pack.id)' parameter '$name' has unsupported type '$t' (allowed: $($allowed -join ', '))."
                        }
                    }
                }
            }
        }
    }

    $stepIds = @{}
    foreach ($step in @($Pack.pipeline)) {
        if (-not $step.id) { throw "Insight pack step missing 'id' property." }
        if ($stepIds.ContainsKey($step.id)) { throw "Insight pack has duplicate step id '$($step.id)'." }
        $stepIds[$step.id] = $true
        if (-not $step.type) { throw "Insight pack step '$($step.id)' is missing 'type'." }

	        $type = ([string]$step.type).ToLowerInvariant()
	        if ($Strict) {
	            $allowedTypes = @('gcrequest','compute','metric','drilldown','assert','foreach','jobpoll','cache','join')
	            if ($type -notin $allowedTypes) {
	                throw "Insight pack '$($Pack.id)' step '$($step.id)' has unsupported type '$type' (allowed: $($allowedTypes -join ', '))."
	            }
	        }
        switch ($type) {
            'gcrequest' {
                if (-not ($step.uri -or $step.path)) { throw "gcRequest step '$($step.id)' requires 'uri' or 'path'." }
                if ($step.method) {
                    $method = ([string]$step.method).ToUpperInvariant()
                    if ($method -notin @('GET','POST','PUT','PATCH','DELETE')) {
                        throw "gcRequest step '$($step.id)' has unsupported method '$method'."
                    }
                }
            }
            'compute' {
                if (-not $step.script) { throw "Compute step '$($step.id)' requires a script block." }
            }
            'metric' {
                if (-not $step.script) { throw "Metric step '$($step.id)' requires a script block." }
            }
            'drilldown' {
                if (-not $step.script) { throw "Drilldown step '$($step.id)' requires a script block." }
            }
            'assert' {
                if (-not $step.script) { throw "Assert step '$($step.id)' requires a script block that returns `$true/`$false." }
                if ($step.message -and -not ($step.message -is [string])) { throw "Assert step '$($step.id)' message must be a string." }
            }
            'foreach' {
                if (-not $step.itemsScript) { throw "Foreach step '$($step.id)' requires 'itemsScript'." }
                if (-not $step.itemScript) { throw "Foreach step '$($step.id)' requires 'itemScript'." }
            }
            'jobpoll' {
                if (-not $step.create) { throw "JobPoll step '$($step.id)' requires 'create' definition." }
            }
            'cache' {
                if (-not $step.script) { throw "Cache step '$($step.id)' requires a script block." }
                if ($step.ttlMinutes) {
                    try {
                        $ttl = [int]$step.ttlMinutes
                        if ($ttl -lt 1) { throw "Cache step '$($step.id)' ttlMinutes must be >= 1." }
                    }
                    catch {
                        throw "Cache step '$($step.id)' ttlMinutes must be an integer >= 1."
                    }
                }
                if ($step.keyTemplate -and -not ($step.keyTemplate -is [string])) { throw "Cache step '$($step.id)' keyTemplate must be a string." }
                if ($step.cacheDirectory -and -not ($step.cacheDirectory -is [string])) { throw "Cache step '$($step.id)' cacheDirectory must be a string." }
            }
            'join' {
                if (-not $step.sourceStepId) { throw "Join step '$($step.id)' requires 'sourceStepId'." }
                if (-not $step.key) { throw "Join step '$($step.id)' requires 'key'." }
                if (-not $step.lookup) { throw "Join step '$($step.id)' requires 'lookup' definition." }
                if (-not ($step.lookup.uri -or $step.lookup.path)) { throw "Join step '$($step.id)' lookup requires 'uri' or 'path'." }
            }
        }

        if ($Strict -and $step.script) {
            try { [void][scriptblock]::Create([string]$step.script) }
            catch { throw "Insight pack '$($Pack.id)' step '$($step.id)' has an invalid script block: $($_.Exception.Message)" }
        }
    }

    return $true
}

function Get-GCInsightPackSchemaPath {
    $moduleBase = Split-Path -Parent $PSScriptRoot
    $candidates = @(
        (Join-Path -Path $moduleBase -ChildPath 'schema/insightpack.schema.json'),
        (Join-Path -Path $moduleBase -ChildPath '..\..\insights\schema\insightpack.schema.json'),
        (Join-Path -Path (Get-Location).ProviderPath -ChildPath 'insights/schema/insightpack.schema.json')
    )

    foreach ($p in $candidates) {
        try {
            $resolved = (Resolve-Path -LiteralPath $p -ErrorAction Stop).ProviderPath
            if (Test-Path -LiteralPath $resolved) { return $resolved }
        }
        catch { }
    }
    return $null
}

function Test-GCInsightPackSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [Parameter()]
        [string]$SchemaPath
    )

    $testJson = Get-Command -Name Test-Json -ErrorAction SilentlyContinue
    if (-not $testJson) { return $true }

    if (-not $SchemaPath) {
        $SchemaPath = Get-GCInsightPackSchemaPath
    }

    if (-not $SchemaPath) { return $true }

    try {
        $ok = Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction Stop
        if (-not $ok) {
            throw "Insight pack JSON does not match schema: $SchemaPath"
        }
        return $true
    }
    catch {
        throw "Schema validation failed: $($_.Exception.Message)"
    }
}

function Resolve-GCInsightTemplateString {
    param(
        [Parameter(Mandatory)]
        [string]$Template,
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    if (-not $Template) { return $Template }

    $result = $Template
    foreach ($paramName in $Parameters.Keys) {
        $value = if ($Parameters[$paramName] -eq $null) { '' } else { [string]$Parameters[$paramName] }
        $tokenDouble = '{{' + [string]$paramName + '}}'
        $tokenSingle = '{' + [string]$paramName + '}'
        $result = $result -replace [regex]::Escape($tokenDouble), $value
        $result = $result -replace [regex]::Escape($tokenSingle), $value
    }

    return $result
}

function Resolve-GCInsightPackQueryString {
    param(
        [Parameter()]
        $QueryTemplate,
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    if (-not $QueryTemplate) { return '' }

    $parts = @()
    foreach ($key in $QueryTemplate.Keys) {
        $valueTemplate = $QueryTemplate[$key]
        $value = if ($valueTemplate -is [string]) {
            Resolve-GCInsightTemplateString -Template $valueTemplate -Parameters $Parameters
        } else {
            $valueTemplate
        }
        if ($null -eq $value) { continue }
        $parts += "{0}={1}" -f $key, [System.Uri]::EscapeDataString([string]$value)
    }

    if ($parts.Count -eq 0) { return '' }
    return ('?' + ($parts -join '&'))
}

function Resolve-GCInsightPackHeaders {
    param(
        [Parameter()]
        $HeadersTemplate,
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    if (-not $HeadersTemplate) { return @{} }

    $headers = @{}
    foreach ($key in $HeadersTemplate.Keys) {
        $valueTemplate = $HeadersTemplate[$key]
        $value = if ($valueTemplate -is [string]) {
            Resolve-GCInsightTemplateString -Template $valueTemplate -Parameters $Parameters
        } else {
            $valueTemplate
        }
        if ($null -ne $value) {
            $headers[$key] = $value
        }
    }

    return $headers
}

function New-GCInsightStepLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$StepDefinition
    )

    return [ordered]@{
        Id           = $StepDefinition.id
        Type         = $StepDefinition.type
        Description  = if ($StepDefinition.description) { $StepDefinition.description } else { $null }
        StartedUtc   = (Get-Date).ToUniversalTime()
        EndedUtc     = $null
        DurationMs   = 0
        Status       = 'Pending'
        ErrorMessage = $null
        ResultSummary= $null
    }
}
