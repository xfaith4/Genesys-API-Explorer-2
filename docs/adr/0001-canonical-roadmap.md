# ADR 0001: Canonical Roadmap

## Status
Accepted

## Context
We had competing “Phase” definitions across multiple documents (e.g., “Phase 3” meaning automation in one place and correlation engine in another), causing planning drift and mismatched expectations.

## Decision
`docs/ROADMAP.md` is the single canonical roadmap for sequencing, milestones, and definitions.

Other documents may provide:
- Vision/principles (non-binding)
- Historical records of work completed
- Detailed design notes for a specific component

If a document conflicts with `docs/ROADMAP.md`, `docs/ROADMAP.md` wins.

## Consequences
- No new “phase numbering” is added outside `docs/ROADMAP.md`.
- Work items must map to a milestone and acceptance criteria.

