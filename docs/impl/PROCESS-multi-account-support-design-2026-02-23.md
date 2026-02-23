# Design Process: Multi-Account Support -- UI/UX Specification

## Session Info
- Date: 2026-02-23
- Team: 5 agents (UX designer, UI designer, platform specialist, design writer, design reviewer)
- Model: sonnet x4 (UX, UI, platform, writer, reviewer)
- Target platforms: macOS (menubar app via NSPopover)
- Review cycle iterations: 1
- Specification file: docs/designs/DESIGN-multi-account-support-2026-02-23.md

## Input Artifacts
- ADR: `docs/adr/ADR-001-multi-account-support.md`
- Conceptualize artifact (KnowledgeItem `184ec003-bad2-4736-81ec-0683df815c34`)
- Source files: `ClaudeUsage/UsageManager.swift`, `ClaudeUsage/ClaudeUsageApp.swift`, `ClaudeUsage/UsageView.swift`

## Agent Contributions
- **UX Designer:** Analyzed mental models (dashboard vs account history), identified 4 user flows, rated 10 Nielsen heuristics (weakest: error prevention 5/10, system status visibility 6/10). Top recommendation: 3-layer staleness signal system.
- **UI Designer:** Defined 8-component inventory with states and variants. Identified critical color threshold discrepancy (code 70/90% vs ADR 50/80%). Proposed composable UsageRow with .card/.inline style parameter. Full design token tables.
- **Platform Specialist:** Flagged Process() blocking as urgent with N accounts. Identified NSPopover auto-resize limitation requiring explicit contentSize management. Recommended Task.detached with terminationHandler pattern. Battery impact analysis for 60s subprocess polling.
- **Design Writer:** Synthesized all three expert analyses into ~1,800 line specification. Key synthesis decisions: resolved color thresholds to match existing code (70/90%), elevated NSPopover sizing to layout requirement, identified OQ-3 (stale in worst-case) as original finding not in any single expert analysis.
- **Design Reviewer:** Scored 82/100 across 5 dimensions. Found 2 critical (OQ-3 contradiction, missing AccountDetail spec), 3 high (height calc inaccuracy, liveGreen contrast, isCurrentAccount field location), 4 medium, 4 low.

## Key Design Decisions
1. **Three-layer staleness signal** -- Badge + muted colors + timestamp to make stale/live distinction unmistakable
2. **Conditional layout** -- Single-account pixel-identical to current; multi-account uses DisclosureGroup accordion with ScrollView
3. **Dynamic popover sizing** -- Fixed 280pt width, variable height (320pt single, 200-480pt multi) with explicit NSPopover.contentSize
4. **Color threshold alignment** -- Resolved to match existing code: green <70%, orange 70-89%, red ≥90% (not ADR's 50/80)
5. **UsageRow composability** -- .card style (single-account) vs .inline style (multi-account accordion) via style parameter
6. **SF Symbols over emoji** -- Replace emoji status indicators with template images for menubar consistency

## Review Cycle Log
### Iteration 1
- Reviewer score: 82/100
- Key findings: OQ-3 normative contradiction (C-1), missing AccountDetail component spec (C-2), popover height calculation inaccurate (H-1), liveGreen contrast insufficient (H-2), isCurrentAccount field location inconsistency (H-3)
- Decision: auto-accept (score >= 80 threshold)

## Conflicts & Resolutions
- UX recommended including stale accounts in worst-case menubar; Platform analysis was silent; Writer flagged as OQ-3 recommending exclusion. Reviewer identified this as a normative contradiction — left for implementation to resolve.
- UI proposed hardcoded hex colors for staleGray (#8E8E93); Reviewer flagged contrast ratio 2.8:1 below AA — recommended system-adaptive `.secondary` instead.

## Final Review Assessment
- Readiness score: 82/100
- Dimension scores: Completeness 85, Feasibility 88, Consistency 84, Accessibility 80, Actionability 79
- Remaining findings: 2 critical, 3 high, 4 medium, 4 low
- Reviewer recommendation: Iterate (but auto-accepted on score threshold)

## Recommendation
**Accept.** The specification is comprehensive and provides an implementation-ready UI/UX design. Critical findings (OQ-3 contradiction, AccountDetail spec gap) are documentation gaps that can be resolved during implementation planning. Phase A and Phase B can proceed without changes; Phase C should resolve the 2 critical items before starting.
