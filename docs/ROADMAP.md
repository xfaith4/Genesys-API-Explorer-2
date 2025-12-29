# Roadmap (Canonical)

This is the **single source of truth** for project direction, sequencing, and “what a phase means”.

If another document conflicts with this file, this file wins.

## North Star
Deliver an Ops-grade workstation that consistently produces **Answers → Evidence → Drilldown → Action**, with **read-only safety** and **reproducible exports** (snapshot + HTML + Excel).

## Product Pillars (Capability Map)
See `docs/CAPABILITY_MAP.md` for the full map. The stable pillars are:
- Explorer UI
- Automation
- Ops Insights
- Correlation Engine
- AI Copilot Layer (agents/prompts/orchestration)

## Stable Primitives (Contracts)
These primitives are the platform; everything else builds on them:
- `Invoke-GCRequest` (single transport, mockable, rate-limit safe)
- Insight Pack schema (`insights/schema/insightpack.schema.json`)
- Evidence packet shape (`Result.Evidence` produced by `New-GCInsightEvidencePacket`)
- Snapshot/export formats (`Export-GCInsightPackSnapshot`, `Export-GCInsightPackHtml`, `Export-GCInsightPackExcel`)

## Milestones (Delivery Increments)
Milestones are **capability increments**, not “phase numbers”. Each milestone ships a coherent slice across pillars.

### M1 — Roadmap Convergence + Contracts Locked
**Goal:** One shared plan, stable interfaces, no competing “Phase 3”.

**Acceptance criteria**
- `docs/ROADMAP.md` is canonical and referenced from `README.md`.
- `docs/CAPABILITY_MAP.md` defines pillars + ownership boundaries.
- Repo workflow templates exist (issues/PRs must tie to a milestone + acceptance checks).
- At least 2 ADRs capturing key architectural decisions.

### M2 — Automation v1 (Templates + Exports Coherent)
**Goal:** The Explorer UI and module exports form one “automation surface”.

**Acceptance criteria**
- Script exports are consistent across UI + module APIs (PowerShell + cURL).
- Templates are versioned and export/importable with validation.
- Snapshots + briefing bundle are reproducible (same inputs → same artifacts).

### M3 — Correlation Engine v1 (Change-Audit Correlation)
**Goal:** Correlate operational anomalies to configuration changes.

**Acceptance criteria**
- Insight Pack results can include `Evidence.Correlations.ChangeAudit`.
- Correlations render in HTML exports and are included in snapshots.
- Offline tests cover correlation enrichment behavior.

### M4 — Correlation Engine v2 (Release Windows + Dependency Graph)
**Goal:** Move from “audit correlation” to “what changed and why it matters”.

**Acceptance criteria**
- Release window correlation (deploy window markers → spikes).
- Dependency correlation (flow → data action → integration) surfaced in Evidence + drilldowns.
- Evidence packets include “blast radius” and “recommended actions” grounded in correlated signals.

### M5 — AI Copilot Layer v1 (Safe Agentic Workflows)
**Goal:** Introduce AI features without eroding safety or determinism.

**Acceptance criteria**
- Prompt library is versioned and testable (inputs/outputs, constraints, redaction).
- Agent tool registry is explicit; AI cannot bypass read-only constraints.
- “Pack builder” workflow can draft/validate an Insight Pack from a natural-language question.
- “Repo enhancement loop” workflow can produce a PR with tests for a scoped task.

## Mapping (Legacy Phase Names → Pillars/Milestones)
Legacy docs use “Phase 3” to mean different things:
- `docs/PROJECT_PLAN.md` “Phase 3” = **Automation v1** (maps mainly to **M2**).
- `docs/ROADMAP_MANIFESTO.md` “Phase 3” = **Correlation Engine** (maps mainly to **M3/M4**).

Going forward: **do not add new phase numbering** to non-canonical docs.

