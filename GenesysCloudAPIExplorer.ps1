[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Start-GenesysCloudApiExplorer {
    [CmdletBinding()]
    param()

    $repoRoot = $PSScriptRoot
    if (-not $repoRoot) { $repoRoot = (Get-Location).Path }

    $opsInsightsCoreManifest = Join-Path -Path $repoRoot -ChildPath 'src/GenesysCloud.OpsInsights.Core/GenesysCloud.OpsInsights.Core.psd1'
    $opsInsightsManifest = Join-Path -Path $repoRoot -ChildPath 'src/GenesysCloud.OpsInsights/GenesysCloud.OpsInsights.psd1'
    $opsConsoleManifest = Join-Path -Path $repoRoot -ChildPath 'apps/OpsConsole/OpsConsole.psd1'

    foreach ($p in @($opsInsightsCoreManifest, $opsInsightsManifest, $opsConsoleManifest)) {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Required module manifest not found: $p`nMake sure you cloned the full repo (including `src/` and `apps/`)."
        }
    }

    # Ensure local modules are discoverable in this session (helps when launching from outside the repo root).
    try {
        $sep = [System.IO.Path]::PathSeparator
        $add = @(
            (Join-Path -Path $repoRoot -ChildPath 'src'),
            (Join-Path -Path $repoRoot -ChildPath 'apps')
        ) -join $sep
        if ($env:PSModulePath -notlike "*$add*") {
            $env:PSModulePath = "$add$sep$env:PSModulePath"
        }
    }
    catch { }

    Import-Module -Name $opsInsightsCoreManifest -Force -ErrorAction Stop
    Import-Module -Name $opsInsightsManifest -Force -ErrorAction Stop
    Import-Module -Name $opsConsoleManifest -Force -ErrorAction Stop

    Start-GCOpsConsole
}

Start-GenesysCloudApiExplorer
