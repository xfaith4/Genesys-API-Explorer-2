# Capability Map (Pillars → Interfaces → Owners)

This document keeps the project synchronized by making responsibilities explicit.

## Pillars

### 1) Explorer UI
**Purpose:** Human-first exploration and safe execution.

**Interfaces**
- Calls module functions only (no direct REST in UI code).
- Exposes templates, parameter validation, and exports.

**Definition of done**
- Read-only safety defaults; mutating actions require explicit arming.

### 2) Automation
**Purpose:** Turn a “thing you clicked” into something runnable and shareable.

**Interfaces**
- PowerShell export (reusable snippets)
- cURL export (portable)
- Template import/export + validation
- Snapshot capture/replay

### 3) Ops Insights
**Purpose:** Curated “packs” that answer ops questions with evidence and drilldowns.

**Interfaces (contracts)**
- Pack schema: `insights/schema/insightpack.schema.json`
- Runner: `Invoke-GCInsightPack`
- Evidence packet: `New-GCInsightEvidencePacket`

### 4) Correlation Engine
**Purpose:** Connect symptoms to causes (changes, releases, dependencies).

**Interfaces**
- Enrichment: `Add-GCInsightCorrelations` (writes into `Result.Evidence.Correlations.*`)
- Drilldowns: structured objects attached to results (and exported)

### 5) AI Copilot Layer
**Purpose:** AI features that operate over stable primitives with safety gates.

**Interfaces**
- Prompt library (versioned, tested) for tasks like:
  - “Explain anomaly”, “Draft evidence narrative”, “Propose next drilldowns”
  - “Generate Insight Pack skeleton”
  - “Generate PR plan + patch for scoped change”
- Agent tool registry (explicit allowed tools + constraints)
- Orchestrator (swarming) that can decompose tasks into sub-tasks but must:
  - respect read-only constraints
  - emit reproducible artifacts (packs, prompts, snapshots)

## Stable Primitives (Do Not Break)
- Transport: `Invoke-GCRequest`
- Pack schema: `insights/schema/insightpack.schema.json`
- Evidence shape: `Result.Evidence`
- Exports: snapshot + HTML + Excel

