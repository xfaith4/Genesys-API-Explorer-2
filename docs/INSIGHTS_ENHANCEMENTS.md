# Insights Enhancement Checklist

This is a working checklist for making Insight Packs more powerful and the resulting briefings more actionable.

## Pack authoring & validation
- [ ] Add typed parameter definitions (`type`, `required`, `default`, `description`) across existing packs and UI parameter capture.
- [ ] Validate packs against `insights/schema/insightpack.schema.json` (optional strict mode).
- [ ] Add a `dryRun` mode: resolve templates + show planned requests without calling APIs.

## Pipeline engine features
- [ ] Add `assert` step type (fail fast with a clear message when expected conditions are not met).
- [ ] Add `foreach` step type to fan out requests/computations across a list.
- [ ] Add `paginate`/`jobPoll` helpers for analytics jobs endpoints.
- [ ] Add `cache` step type (file cache keyed by pack id + params + timeframe).
- [ ] Add `join` helpers for enriching IDs to names (queues/users/data actions).

## Evidence & briefing quality
- [ ] Evidence model: `severity`, `impact`, `likelyCauses`, `recommendedActions`, and “why this matters” narrative.
- [ ] Baselines: compare the selected window vs prior window (or 7/30 day baseline) and highlight deltas.
- [ ] “Blast radius” enrichment: link failures to affected integrations/flows/queues where possible.

## Discoverability & governance
- [ ] Pack catalog/index (tags, owner, scopes/permissions, expected runtime, maturity, examples).
- [ ] Pack testing harness (`Invoke-GCInsightPackTest`) with fixtures + snapshot assertions for computed metrics.

