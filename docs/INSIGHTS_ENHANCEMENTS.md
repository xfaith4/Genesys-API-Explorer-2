# Insights Enhancement Checklist

This is a working checklist for making Insight Packs more powerful and the resulting briefings more actionable.

## Pack authoring & validation

- [x] Add typed parameter definitions (`type`, `required`, `default`, `description`) across existing packs and UI parameter capture.
- [ ] Validate packs against `insights/schema/insightpack.schema.json` (optional strict mode).
- [x] Add a `dryRun` mode: resolve templates + show planned requests without calling APIs.
- [x] Add baseline comparison runner (previous window) for packs that accept `startDate`/`endDate`.
- [x] Add a pack catalog UI + dynamic parameter rendering in Ops Console.
- [x] Ensure Ops Insights runs use the UI OAuth token (no hidden global state).
- [x] Display pack metadata (tags/scopes/endpoints) in the Ops Console.
- [x] Add file+TTL caching for `gcRequest` steps (opt-in) to speed up weekly/monthly packs.
- [x] Standardize pack metadata: `owner`, `maturity`, `expectedRuntimeSec`, `scopes` (add across all packs).

## Pipeline engine features

- [x] Add `assert` step type (fail fast with a clear message when expected conditions are not met).
- [x] Add `foreach` step type to fan out requests/computations across a list.
- [x] Add `jobPoll` helper step type for analytics jobs endpoints.
- [ ] Add `cache` step type (file cache keyed by pack id + params + timeframe).
- [ ] Add `join` helpers for enriching IDs to names (queues/users/data actions).

## Evidence & briefing quality

- [ ] Evidence model: `severity`, `impact`, `likelyCauses`, `recommendedActions`, and “why this matters” narrative.
- [ ] Baselines: compare the selected window vs prior window (or 7/30 day baseline) and highlight deltas.
- [ ] “Blast radius” enrichment: link failures to affected integrations/flows/queues where possible.

## Discoverability & governance

- [ ] Pack catalog/index (tags, owner, scopes/permissions, expected runtime, maturity, examples).
- [x] Pack testing harness (`Invoke-GCInsightPackTest`) with fixtures + snapshot assertions for computed metrics.
- [x] Append export entries to a briefings `index.json` for lightweight run history.
- [x] Load and browse briefing history from `index.json` in the Ops Console.
- [x] Optional strict pack validation (`Test-GCInsightPack`, UI toggle).

## Next steps (Phase 1)

- [x] Add a “time window” picker (WoW/MoM presets) that feeds `startDate`/`endDate` for packs.
- [x] Improve briefing HTML for compare runs (deltas, highlights, and “what changed” narrative).
- [x] Add a basic pack “Examples” area (recommended params + expected runtime) shown in the catalog.
- [ ] Add stronger pack validation + friendly parameter errors (schema strict mode).

## Packs added (initial set)

- [x] Data Actions enrichment pack: `insights/packs/gc.dataActions.failures.enriched.v1.json`
- [x] Peak concurrency pack (voice sessions): `insights/packs/gc.calls.peakConcurrency.monthly.v1.json`
