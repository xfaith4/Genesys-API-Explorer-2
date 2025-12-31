# Friction Log

| ID | Journey | Symptom | Root cause (hypothesis) | Evidence | Sev (0-5) | Freq % | Fix strategy | Confidence | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | Submit API | Rage clicks on Submit | No inline feedback when validation blocks | telemetry `rage_click`, sims | 3 | 18 | Debounce + visible status + HUD ping | Medium | Done |
| F2 | Submit API | Dead clicks without method/path | Missing selection guidance | `dead_click`, log entries | 2 | 24 | Add inline status text, keep disabled buttons styled | High | Done |
| F3 | Validation | Hidden validation errors | Errors only in dialog | `validation_error` entries | 3 | 22 | Surface errors in status + log | Medium | Done |
| F4 | Favorites | Unclear empty state | No indicator when empty | `empty_state_seen` | 1 | 100 (first run) | Emit empty-state note, telemetry | High | Done |
| F5 | Observability | Hard to reproduce UI state | No HUD/context | Dev HUD absent | 2 | 100 | Add debug HUD + telemetry session id | High | Done |

Statuses reflect current PR scope; revisit after live user data.
