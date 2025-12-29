### BEGIN: Build-SwaggerEndpointIndex
param(
  [Parameter(Mandatory)]
  [string]$SwaggerPath,

  [string]$OutJson = ".\endpoint-index.json",
  [string]$OutCsv  = ".\endpoint-index.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SwaggerPath)) {
  throw "Swagger file not found: $SwaggerPath"
}

# ConvertFrom-Json needs a big Depth for this spec
$swagger = Get-Content -LiteralPath $SwaggerPath -Raw | ConvertFrom-Json -Depth 200

function Get-ApiGroupFromPath([string]$Path) {
  # Example: /api/v2/authorization/divisions/home  -> authorization
  $parts = $Path.Trim('/') -split '/'
  if ($parts.Length -ge 3 -and $parts[0] -eq 'api' -and $parts[1] -eq 'v2') { return $parts[2] }
  if ($parts.Length -ge 1) { return $parts[0] }
  return 'unknown'
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($p in $swagger.paths.PSObject.Properties) {
  $path = $p.Name
  $pathObj = $p.Value

  foreach ($m in $pathObj.PSObject.Properties) {
    $method = $m.Name.ToUpperInvariant()
    if ($method -notin @('GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS')) { continue }

    $op = $m.Value
    $tags = @()
    if ($op.tags) { $tags = @($op.tags) }

    # Collect parameters (path/query/body/header/formData)
    $params = @()
    if ($op.parameters) {
      foreach ($prm in @($op.parameters)) {
        $schemaRef = $null
        if ($prm.schema -and $prm.schema.'$ref') { $schemaRef = $prm.schema.'$ref' }

        $params += [pscustomobject]@{
          In         = $prm.in
          Name       = $prm.name
          Required   = [bool]$prm.required
          Type       = $prm.type
          Format     = $prm.format
          SchemaRef  = $schemaRef
          Enum       = if ($prm.enum) { ($prm.enum -join '|') } else { $null }
          Desc       = $prm.description
        }
      }
    }

    # Scopes are per-operation in Swagger 2.0: security: [{ "PureCloud OAuth": ["scope1","scope2"] }]
    $scopes = @()
    if ($op.security) {
      foreach ($sec in @($op.security)) {
        foreach ($secProp in $sec.PSObject.Properties) {
          if ($secProp.Value) { $scopes += @($secProp.Value) }
        }
      }
    }

    $rows.Add([pscustomobject]@{
      Group        = (Get-ApiGroupFromPath -Path $path)
      Tags         = ($tags -join ', ')
      Method       = $method
      Path         = $path
      OperationId  = $op.operationId
      Summary      = $op.summary
      Produces     = if ($op.produces) { ($op.produces -join ', ') } else { ($swagger.produces -join ', ') }
      Consumes     = if ($op.consumes) { ($op.consumes -join ', ') } else { ($swagger.consumes -join ', ') }
      OAuthScopes  = ($scopes | Sort-Object -Unique) -join ', '
      ParamCount   = $params.Count
      Parameters   = $params
    })
  }
}

# Write JSON for the app to load (keeps parameter detail)
$rows | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutJson -Encoding UTF8

# Write CSV for quick inspection (flattened)
$rows |
  Select-Object Group,Tags,Method,Path,OperationId,Summary,OAuthScopes,ParamCount |
  Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8

Write-Host "Wrote:"
Write-Host "  JSON: $OutJson"
Write-Host "  CSV : $OutCsv"
### END: Build-SwaggerEndpointIndex

<#
.\Build-SwaggerEndpointIndex.ps1 -SwaggerPath ".\publicapi-v2-latest.json"
#>
