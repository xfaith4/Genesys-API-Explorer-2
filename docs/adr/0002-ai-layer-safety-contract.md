# ADR 0002: AI Layer Safety Contract

## Status
Accepted

## Context
We want AI-driven orchestration, agent workflows, prompt libraries, and repo enhancements, but the product must remain safe and deterministic (especially in read-only mode) and preserve reproducibility (snapshots/exports).

## Decision
The AI Copilot Layer is a tooling plane that operates over stable primitives and cannot bypass safety gates:
- AI may only invoke explicitly registered tools/commands.
- AI must respect read-only safety constraints (mutating calls require explicit arming).
- AI outputs must be versioned and testable (prompt library, pack schema validation, snapshot/export invariants).

## Consequences
- “Agent tool registry” is required before broad AI automation.
- Prompt templates must be stored and versioned in-repo with tests/fixtures.
- Any AI-driven repo enhancement must produce a PR with tests for the scoped change.

