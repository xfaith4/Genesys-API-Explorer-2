### BEGIN FILE: Private\Get-TemplatedObject.ps1
function Get-TemplatedObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter()]
        [hashtable]$Parameters
    )

    # Very small templating helper:
    # - Replace '{{paramName}}' tokens inside strings
    # - Return a hashtable/array/object suitable for ConvertTo-Json
    $json = ($Template | ConvertTo-Json -Depth 80)

    foreach ($k in ($Parameters.Keys | Sort-Object -Descending)) {
        $value = if ($Parameters[$k] -eq $null) { '' } else { [string]$Parameters[$k] }
        $tokenDouble = '{{' + [string]$k + '}}'
        $tokenSingle = '{' + [string]$k + '}'
        $json = $json -replace [regex]::Escape($tokenDouble), $value
        $json = $json -replace [regex]::Escape($tokenSingle), $value
    }

    $json | ConvertFrom-Json
}
### END FILE: Private\Get-TemplatedObject.ps1
