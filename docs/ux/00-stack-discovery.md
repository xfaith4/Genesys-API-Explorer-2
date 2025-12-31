# Stack Discovery

## Framework and runtime
- **Shell/UI**: Windows PowerShell 5.1+ WPF window defined in `apps/OpsConsole/Resources/GenesysCloudAPIExplorer.UI.ps1`
- **Modules**: Ops console module `apps/OpsConsole/OpsConsole.psm1` plus core `src/GenesysCloud.OpsInsights`
- **Rendering**: XAML parsed at runtime; styling now tokenized via `design-tokens.psd1`

## Build / run
- Entrypoint: `.\GenesysCloudAPIExplorer.ps1`
- Dependencies: WPF assemblies (Windows), `ImportExcel` for exports, Genesys Cloud token + endpoint catalog JSON
- Tests: Pester under `tests/*.Tests.ps1`, workflow mirrors syntax + JSON validation

## Tooling
- Lint: syntax parse step `[System.Management.Automation.Language.Parser]::ParseFile`
- Tests: Pester `Invoke-Pester` (Windows)
- Packaging: optional `tools/Build.ps1`

## UX instrumentation
- Telemetry helper: `apps/OpsConsole/Resources/UxTelemetry.ps1`
- Default log file: `artifacts/ux-simulations/runs/telemetry-<date>.jsonl`
- Debug HUD flag: `GENESYS_API_EXPLORER_DEBUG_UI=1`
