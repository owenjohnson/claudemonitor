# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the project.

## What is an ADR?

An ADR records a significant architectural decision made along with its context and consequences.

## ADR Index

| Number | Title | Status | Date |
|--------|-------|--------|------|
| [ADR-001](./ADR-001-multi-account-support.md) | Add Multi-Account Support with Keychain Polling and Account Tracking | Proposed | 2026-02-23 |
| [ADR-002](./ADR-002-compact-multi-account-ui.md) | Compact Multi-Account UI Architecture — Accordion State, Row Density, and File Decomposition | Proposed | 2026-03-01 |
| [ADR-003](./ADR-003-compact-usage-row-and-keychain-migration.md) | Compact UsageRow layout, percentage rounding fix, keychain migration | Proposed | 2026-03-02 |
| [ADR-004](./ADR-004-multi-provider-framework.md) | Plugin framework for usage monitoring with vault-backed secrets | Accepted | 2026-06-11 |
| [ADR-005](./ADR-005-anthropic-plugin.md) | Anthropic (Claude) usage plugin | Proposed | 2026-06-11 |
| [ADR-006](./ADR-006-codex-plugin.md) | OpenAI Codex usage plugin | Proposed | 2026-06-11 |
| [ADR-007](./ADR-007-antigravity-plugin.md) | Google Antigravity usage plugin | Proposed | 2026-06-11 |

## Creating a New ADR

1. Copy `TEMPLATE.md` to `NNNN-title-with-dashes.md`
2. Fill in the sections
3. Add entry to the index table above
4. Submit for review

## Statuses

- **Proposed** - Under discussion
- **Accepted** - Decision made
- **Deprecated** - No longer applies
- **Superseded** - Replaced by another ADR

## Template

See [TEMPLATE.md](./TEMPLATE.md) for the ADR template.
