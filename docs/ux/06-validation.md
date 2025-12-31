# Validation Checklist

## Commands
- Syntax: `pwsh -NoLogo -Command "[System.Management.Automation.Language.Parser]::ParseFile('./GenesysCloudAPIExplorer.ps1',[ref]$null,[ref]$null)"` (errors surfaced)
- JSON catalog: `pwsh -NoLogo -Command "Get-Content './GenesysCloudAPIEndpoints.json' -Raw | ConvertFrom-Json | Out-Null"`
- Tests: `Invoke-Pester -Script './tests'`
- Sims: `pwsh -File tools/Run-UxSimulations.ps1`

## Accessibility
- Keyboard focusable HUD toggle via env var (dev-only)
- WPF control focus order unchanged; high-contrast friendly token palette

## Performance
- Telemetry write is async-safe and silent on failure
- HUD opt-in; no impact to prod users

## Evidence
- `artifacts/ux-simulations/simulation-summary.json`
- `artifacts/ux-simulations/runs/telemetry-*.jsonl`
- `artifacts/ux-simulations/screenshots/after.png`
