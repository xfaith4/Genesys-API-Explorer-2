# Local Runbook

## Prereqs
- Windows host with PowerShell 5.1+ and WPF assemblies
- Genesys Cloud OAuth token
- Endpoint catalog `GenesysCloudAPIEndpoints.json` in repo root
- Optional: `ImportExcel` module for exports (`Install-Module ImportExcel -Scope CurrentUser`)

## Run the UI
```powershell
Set-Location <repo-root>
.\GenesysCloudAPIExplorer.ps1
```

### Debug + telemetry
```powershell
$env:GENESYS_API_EXPLORER_DEBUG_UI = 1   # shows HUD overlay
.\GenesysCloudAPIExplorer.ps1
```
Telemetry writes to `artifacts/ux-simulations/runs/telemetry-<date>.jsonl`.

## Tests
```powershell
# Syntax + JSON check (CI equivalent)
pwsh -NoLogo -Command "$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile('./GenesysCloudAPIExplorer.ps1',[ref]$tokens,[ref]$errors)|Out-Null;if($errors){$errors|%{Write-Error $_};exit 1}"
pwsh -NoLogo -Command "$json=Get-Content './GenesysCloudAPIEndpoints.json' -Raw | ConvertFrom-Json; $json.PSObject.Properties.Count"

# Pester tests
Invoke-Pester -Script './tests' -Output Detailed
```

## Synthetic UX sims
```powershell
pwsh -File tools/Run-UxSimulations.ps1
# outputs artifacts/ux-simulations/runs/*.json and simulation-summary.json
```
