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
        [pscustomobject]$Pack
    )

    if (-not $Pack.id) { throw "Insight pack is missing 'id'." }
    if (-not $Pack.name) { throw "Insight pack '$($Pack.id)' is missing 'name'." }
    if (-not $Pack.version) { throw "Insight pack '$($Pack.id)' is missing 'version'." }
    if (-not $Pack.pipeline) { throw "Insight pack '$($Pack.id)' is missing 'pipeline'." }

    $stepIds = @{}
    foreach ($step in @($Pack.pipeline)) {
        if (-not $step.id) { throw "Insight pack step missing 'id' property." }
        if ($stepIds.ContainsKey($step.id)) { throw "Insight pack has duplicate step id '$($step.id)'." }
        $stepIds[$step.id] = $true
        if (-not $step.type) { throw "Insight pack step '$($step.id)' is missing 'type'." }

        $type = ([string]$step.type).ToLowerInvariant()
        switch ($type) {
            'gcrequest' {
                if (-not ($step.uri -or $step.path)) { throw "gcRequest step '$($step.id)' requires 'uri' or 'path'." }
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
        }
    }

    return $true
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
        $token = "{{{0}}}" -f $paramName
        $value = if ($Parameters[$paramName] -eq $null) { '' } else { [string]$Parameters[$paramName] }
        $result = $result -replace [regex]::Escape($token), $value
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
