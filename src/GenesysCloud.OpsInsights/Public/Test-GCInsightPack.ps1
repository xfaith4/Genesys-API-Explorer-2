function Test-GCInsightPack {
    <#
      .SYNOPSIS
        Validates an Insight Pack JSON definition (optionally strict).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackPath,

        [Parameter()]
        [switch]$Strict
    )

    $resolvedPackPath = Resolve-GCInsightPackPath -PackPath $PackPath
    if (-not (Test-Path -LiteralPath $resolvedPackPath)) {
        throw "Insight pack not found: $PackPath"
    }

    $raw = Get-Content -LiteralPath $resolvedPackPath -Raw
    $pack = $raw | ConvertFrom-Json

    try {
        Test-GCInsightPackDefinition -Pack $pack -Strict:$Strict | Out-Null
        return [pscustomobject]@{
            PackPath = $resolvedPackPath
            PackId   = $pack.id
            IsValid  = $true
            Errors   = @()
            Pack     = $pack
        }
    }
    catch {
        return [pscustomobject]@{
            PackPath = $resolvedPackPath
            PackId   = $pack.id
            IsValid  = $false
            Errors   = @([string]$_.Exception.Message)
            Pack     = $pack
        }
    }
}

