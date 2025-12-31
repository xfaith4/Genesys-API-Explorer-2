$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$telemetryScript = Join-Path $repoRoot 'apps/OpsConsole/Resources/UxTelemetry.ps1'
. $telemetryScript

$artifactsRoot = Join-Path $repoRoot 'artifacts/ux-simulations'
$runsDir = Join-Path $artifactsRoot 'runs'
$screensDir = Join-Path $artifactsRoot 'screenshots'
$tracesDir = Join-Path $artifactsRoot 'traces'
$null = New-Item -ItemType Directory -Force -Path $runsDir, $screensDir, $tracesDir

$simulationCount = 100
$rng = New-Object System.Random

function New-SimulatedUserProfile {
    $skillLevels = @("impatient", "careful", "power", "novice")
    $viewports = @("mobile", "tablet", "desktop")
    $networks = @("wifi", "fast4g", "slow3g")
    $a11y = @("keyboard-only", "standard", "reduced-motion", "high-contrast")
    return [pscustomobject]@{
        Skill    = $skillLevels[$rng.Next($skillLevels.Count)]
        Viewport = $viewports[$rng.Next($viewports.Count)]
        Network  = $networks[$rng.Next($networks.Count)]
        A11yMode = $a11y[$rng.Next($a11y.Count)]
    }
}

function Invoke-SimulatedJourney {
    param([int]$Index)

    $profile = New-SimulatedUserProfile
    $journey = @("onboarding", "submit-api", "inspect-response", "save-favorite", "run-report")[$rng.Next(5)]

    $errors = $rng.Next(0, 3)
    $rageClicks = $rng.Next(0, 2)
    $duration = [Math]::Round($rng.NextDouble() * 120 + 5, 2)
    $stuck = $rng.NextDouble() -lt 0.05

    return [pscustomobject]@{
        id            = "run-$Index"
        journey       = $journey
        profile       = $profile
        durationSec   = $duration
        errors        = $errors
        rageClicks    = $rageClicks
        stuck         = $stuck
        completed     = ($errors -eq 0) -and (-not $stuck)
        timestampUtc  = (Get-Date).ToUniversalTime().ToString("o")
    }
}

$runs = @()
for ($i = 1; $i -le $simulationCount; $i++) {
    $run = Invoke-SimulatedJourney -Index $i
    $runs += $run
    $run | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $runsDir "$($run.id).json") -Encoding utf8
}

$summary = [pscustomobject]@{
    totalRuns          = $simulationCount
    completionRate     = [Math]::Round((($runs | Where-Object { $_.completed }).Count / $simulationCount) * 100, 2)
    meanDurationSec    = [Math]::Round(($runs.durationSec | Measure-Object -Average).Average, 2)
    errorRate          = [Math]::Round((($runs | Where-Object { $_.errors -gt 0 }).Count / $simulationCount) * 100, 2)
    rageClickRate      = [Math]::Round((($runs | Where-Object { $_.rageClicks -gt 0 }).Count / $simulationCount) * 100, 2)
    stuckRate          = [Math]::Round((($runs | Where-Object { $_.stuck }).Count / $simulationCount) * 100, 2)
}

$summary | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $artifactsRoot 'simulation-summary.json') -Encoding utf8
Write-Host "Generated $simulationCount synthetic runs. Summary:`n$($summary | ConvertTo-Json -Depth 5)"
