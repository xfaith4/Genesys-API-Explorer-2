# Design System Snapshot

- **Tokens**: `apps/OpsConsole/Resources/design-tokens.psd1` (color, spacing, radius, typography, shadow, motion)
- **Core components**:
  - Buttons: Primary background `Primary`, radius `MD`, padding `SpacingMD`
  - Panels/Borders: `SurfaceMuted` background, `Border` stroke, radius `MD`
  - Text: Primary `TextPrimary`, secondary `TextSecondary`, base font Segoe UI 14
  - Debug HUD: Dev-only overlay using same tokens
- **Interaction**:
  - Focus-visible via native WPF cues
  - Loading indicator + status text on API calls
  - Empty states emit telemetry for observability
- **Accessibility**:
  - High-contrast-friendly palette (dark surface, high-luminance text)
  - Keyboard navigation preserved; HUD is non-modal
- **Usage**:
  - Import tokens in code-behind: `Import-PowerShellDataFile design-tokens.psd1`
  - Apply brushes via `Set-DesignSystemResources -Window $Window`
