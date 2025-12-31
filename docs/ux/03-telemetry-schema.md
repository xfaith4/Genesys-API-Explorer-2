# Telemetry Schema

Events are appended as JSONL to `artifacts/ux-simulations/runs/telemetry-<date>.jsonl`.

```json
{
  "ts": "2025-01-01T00:00:00.0000000Z",
  "session": "<guid>",
  "event": "api_call",
  "props": { "route": "Response", "statusCode": 200, "durationMs": 312 }
}
```

## Event types
- `page_view` – tab change; props: `route`
- `cta_click` – key buttons; props: `control`, `path`, `method`
- `validation_error` – blocked submission; props: `errors[]`
- `api_call_start` – request sent; props: `method`, `path`, `url`
- `api_call` – success; props: `statusCode`, `durationMs`, `pagination`
- `api_error` – failure; props: `status`, `message`
- `empty_state_seen` – empty lists (favorites)
- `rage_click` – ≥3 submit clicks within 2s; props: `control`
- `dead_click` – blocked action; props: `reason`
- `time_to_interactive` – UI ready; props: `ready`
- `log` – transparency log mirror; props: `message`

## Privacy
- No PII collected; endpoint paths and status codes only
- File is local-only; delete `artifacts/ux-simulations/runs` to reset
