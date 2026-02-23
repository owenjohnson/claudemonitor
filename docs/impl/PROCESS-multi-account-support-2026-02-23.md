# Conceptualize Process: Multi-Account Support — 2026-02-23

## Session Info
- Date: 2026-02-23
- Team: 4 SMEs, 1 synthesis expert (consolidated phases 3-6)
- Model: opus for all agents
- Problem statement: Add multi-account support to ClaudeUsage macOS menubar app
- Phases completed: 6/6 (Phases 3-6 consolidated for efficiency)
- Phase 6 vote: MODIFY (simplify over-engineered elements)

## Phase Log

### Phase 1: Breadth
- SME domains: data-design, info-arch, ux, sys-arch
- Key contributions: 30+ approaches cataloged across 4 dimensions. 7 storage approaches, 10 UI patterns, 7 architecture patterns, 5 token capture strategies.
- User input: none
- Synthesis: Strong convergence on hybrid storage, summary+drill-down UI, single UsageManager with account array

### Phase 2: Depth
- SME domains: data-design, info-arch, ux, sys-arch
- Key contributions: Complete Codable data models, SecItem keychain code, 56pt accordion layout spec, refactored UsageManager API with TaskGroup concurrency, step-by-step token capture flow with error matrix
- User input: none
- Synthesis: All dimensions reached 8/10 with implementation-ready specifications

### Phases 3-6: Edge Cases, Debate, Resolution, Final Vote (Consolidated)
- SME domains: senior-expert (consolidated analysis)
- Key contributions: Identified over-engineering in Phase 2 design. Cut SHA-256 hashing, dual timers, soft-delete, TokenProvider protocol, detection banner, avatars. Simplified to single 60s timer, plain string comparison, 3-state model. Validated against 630-line codebase reality.
- User input: none (unattended mode)
- Synthesis: MODIFY vote with clear simplification directives

## Expert Contributions
| SME Domain | Key Ideas | Phases Active |
|------------|-----------|---------------|
| Data Design | AccountRecord model, app-owned keychain, token capture flow, schema versioning | 1-2 |
| Info Architecture | Summary+drill-down, 56pt rows, accordion, menubar aggregation, account ordering | 1-2 |
| User Experience | New account detection UX, error states per account, popover sizing, onboarding flow | 1-2 |
| System Architecture | UsageManager refactor, TaskGroup concurrency, dual-timer (later simplified), error isolation | 1-2 |
| Senior Expert | Edge case analysis, over-engineering critique, simplification, final recommendation | 3-6 |

## Key Decisions
1. Hybrid storage: UserDefaults for metadata + app-owned Keychain for tokens
2. Email as canonical account key (from /api/oauth/profile)
3. Single 60-second timer for both keychain polling and usage refresh
4. Never attempt OAuth refresh tokens (risk of invalidating Claude Code's tokens)
5. Silent account detection (no confirmation banner)
6. Pixel-identical single-account UI when only 1 account present
7. Worst-case percentage in menubar across all active accounts

## Recommendation
**Implement** with simplifications. Build in 4 phases: (A) Token capture & storage, (B) Multi-account refresh, (C) Multi-account UI, (D) Polish & edge cases. Validate token longevity empirically before committing to stored-token architecture.
