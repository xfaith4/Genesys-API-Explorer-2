# Simulation Results

Source: `tools/Run-UxSimulations.ps1` (100 synthetic runs)

- Completion rate: **32%**
- Mean duration: **59.64s**
- Error rate: **67%**
- Rage-click rate: **54%**
- Stuck detection: **2%** flagged in runs (`stuck=true`)

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
