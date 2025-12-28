# Phase 1 (Ops Insights) Exit Checklist

This is the “ready for Phase 2” bar for the Insight Packs engine + Ops Console integration.

## Exit criteria (now)

- Offline test suite passes (`Invoke-Pester -Path ./tests -CI`).
- Packs validate in **strict + schema** mode (`Test-GCInsightPack -Strict -Schema`).
- UI can run: Pack runner, Dry Run, Compare, Cache, Export Briefing.
- Caching is deterministic and does not block execution when disabled.
- Evidence packet renders in UI + HTML (Severity/Impact/Why/Likely causes/Recommended actions/Blast radius).

## Known gaps (Phase 2)

- Full dependency graph (“why” correlation): flows ↔ data actions ↔ integrations ↔ queues (beyond the pack-level blast radius lists).
- Broader “answers-first” pack coverage (flow regression, API usage/limits, change correlation).
- Resilience enhancements (rate-limit manager, retry/backoff policy tuning, concurrency controls).
