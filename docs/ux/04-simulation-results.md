# Simulation Results

Source: `tools/Run-UxSimulations.ps1` (100 synthetic runs)

- Completion rate: **44%**
- Mean duration: **64.42s**
- Error rate: **55%**
- Rage-click rate: **55%**
- Stuck detection: **3%** flagged in runs (`stuck=true`)

Artifacts:
- `artifacts/ux-simulations/runs/*.json`
- `artifacts/ux-simulations/simulation-summary.json`
- `artifacts/ux-simulations/screenshots/after.png` (UI snapshot)
- `artifacts/ux-simulations/traces/` (reserved)

How to regenerate:
```powershell
pwsh -File tools/Run-UxSimulations.ps1
Get-Content artifacts/ux-simulations/simulation-summary.json
```
