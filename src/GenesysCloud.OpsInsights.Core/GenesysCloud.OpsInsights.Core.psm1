# GenesysCloud.OpsInsights.Core: Pure, offline-safe helpers used by the main module.

$moduleRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath $moduleRoot)) {
    throw "Module root not found: $($moduleRoot)"
}

function Get-ScriptFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(Get-ChildItem -Path $Directory -Filter '*.ps1' -File | Sort-Object Name)
}

$publicDir = Join-Path $moduleRoot 'Public'
foreach ($file in (Get-ScriptFiles -Directory $publicDir)) { . $file.FullName }

# Export everything dot-sourced from Public/ (manifest uses wildcard too, but keep explicit export behavior).
$publicFunctions = @(
    'Export-GCInsightPackHtml'
)

Export-ModuleMember -Function $publicFunctions

