# Implementation Plan: Compact Multi-Account UI

**Date:** 2026-03-02
**Status:** Draft
**ADR Reference:** `docs/adr/ADR-002-compact-multi-account-ui.md`
**Design Reference:** `docs/designs/DESIGN-compact-multi-account-swift-ui-2026-03-02.md`
**Target Version:** v2.0

**Effort Estimates:**
- Optimistic: 2h15m (no blockers, clean implementation)
- Realistic: 4h05m (includes Toggle/Menu verification, constants cross-check)
- Pessimistic: 6h45m (Binding adapter visual issues, pbxproj rework, SMAppService regression)

---

## Overview

ADR-002 addresses six structural problems in the v1.9 multi-account UI that become visible with three or more accounts: per-row independent expand/collapse state overflowing the `ScrollView`, 56pt collapsed rows consuming excessive vertical space, a full-height footer wasting 52pt in multi-account mode, a 718-line `UsageView.swift` monolith, `colorForPercentage` duplicated in two places, and sonnet utilization silently excluded from worst-case calculations.

The implementation resolves all six problems through six ADR decisions (D1–D6): lifting accordion state to `AccountList` for exclusive expand/collapse, reducing collapsed row height to 48pt, introducing a 48pt compressed footer behind a gear icon for multi-account mode, adding a `bottleneck` computed property on `UsageData` as the single source of truth for utilization (including sonnet), decomposing `UsageView.swift` into six focused files, and extracting `colorForPercentage` to a `Color` extension in `SharedStyles.swift`.

The implementation proceeds in four sequential phases: Phase 1 performs pure zero-risk refactors (D6, D4) with no behavioral change except the intentional and documented sonnet inclusion in the status bar; Phase 2 implements the exclusive accordion and compact rows (D1, D2); Phase 3 adds the compressed footer and updates the popover height formula (D3, RF1); Phase 4 extracts the six files and updates the Xcode project file (D5). Single-account mode remains pixel-identical to v1.7 throughout all phases. No new Swift package dependencies are introduced.

---

## Prerequisites

| # | Prerequisite | Status | Blocking? | Notes |
|---|-------------|--------|-----------|-------|
| P1 | Xcode 15+ with Swift concurrency | MET | No | Required for `async/await`; project already uses it |
| P2 | macOS 13+ deployment target | MET | No | `SMAppService` requires macOS 13; already in use in `footerView()` |
| P3 | Read `UsageView.swift` fully before modifying | Required before Phase 1 | Yes | 718-line monolith; all line numbers in this plan are from the current version |
| P4 | Read `UsageManager.swift` lines 4–102 | Required before Task 1.3 | Yes | `UsageData` struct (lines 4–15), `statusEmoji` (lines 83–92), `worstCaseUtilization` (lines 95–102) |
| P5 | Read `ClaudeUsageApp.swift` lines 156–171 | Required before Task 3.3 | Yes | `computePopoverHeight()` current implementation |
| P6 | Git working state clean before starting | Required | Yes | Each task should be committed individually to enable per-step rollback |
| P7 | Verify build before Phase 1 | Required | Yes | Confirm `xcodebuild` passes on current state before any changes |

---

## Phases and Tasks

### Phase 1: Foundation — Pure Refactors (No Behavioral Change)

**Goal:** Deduplicate `colorForPercentage` (D6) and add the `bottleneck` computed property (D4). These are zero-risk refactors with no visible behavior change, except for the intentional and documented inclusion of sonnet in status bar utilization.

**Milestone M1:** `colorForPercentage` has exactly one definition in the codebase; `bottleneck` is the single source of truth for utilization including sonnet; status bar reflects sonnet when it is the highest category; build succeeds.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|------------|---------------------|
| 1.1 | Create `SharedStyles.swift` with `Color.forUtilization` | Create `ClaudeUsage/SharedStyles.swift`. Copy (do not yet remove) `LiveIndicator`, `CachedBadge`, `StaleBadge` from `UsageView.swift` (lines 366–423). Add `extension Color { static func forUtilization(_ percentage: Int) -> Color }` per D6. Do not remove the originals from `UsageView.swift` yet — wait until 1.2 confirms build. | New: `ClaudeUsage/SharedStyles.swift`; Modify: `ClaudeUsage/UsageView.swift` | S | — | `SharedStyles.swift` compiles standalone; `LiveIndicator`, `CachedBadge`, `StaleBadge` present |
| 1.2 | Update all `colorForPercentage` call sites to `Color.forUtilization` | Replace calls in `UsageView` (lines 103, 112, 123) and `AccountDisclosureGroup` (lines 544, 607, 615, 624). Remove both function definitions (lines 264–268, 685–689). Also update `utilizationColor` (line 539–545). Remove the original `LiveIndicator`, `CachedBadge`, `StaleBadge` definitions from `UsageView.swift` now that build is verified. Verify `grep colorForPercentage` returns zero hits. | `ClaudeUsage/UsageView.swift` | S | 1.1 | `grep colorForPercentage ClaudeUsage/UsageView.swift` returns zero hits; build succeeds |
| 1.3 | Add `bottleneck` computed property to `UsageData` | Add `var bottleneck: (percentage: Int, category: String)` to `UsageData` in `UsageManager.swift` after line 14, comparing session, weekly, and sonnet percentages per D4. **Risk note (RF2):** This is a pure computed property with no side effects — a strong candidate for unit tests if XCTest infra is added. | `ClaudeUsage/UsageManager.swift` (lines 4–15) | — | `bottleneck` compiles; manual test: sonnet=95, session=20, weekly=30 → `bottleneck.percentage == 95` |
| 1.4 | Update `worstCaseUtilization` and `statusEmoji` to use `bottleneck` | Replace inline `max(sessionUtilization, weeklyUtilization)` in `worstCaseUtilization` (lines 95–102) and `statusEmoji` (lines 83–92) with `bottleneck.percentage`. Replace `AccountDisclosureGroup.highestUtilization` (lines 534–537) with `accountUsage.usage?.bottleneck.percentage ?? 0`. Also update `utilizationColor` in `AccountDisclosureGroup` (lines 539–545) to use `Color.forUtilization` with `bottleneck.percentage`. | `ClaudeUsage/UsageManager.swift`, `ClaudeUsage/UsageView.swift` | 1.3 | Build succeeds; status bar shows orange/red when sonnet exceeds 70%/90% threshold |

**Phase 1 Critical Path:** 1.3 (independent) → 1.4; 1.1 → 1.2 (independent chain)

**Risk Mitigations:**
- **RF2:** `bottleneck` is a pure computed property — no side effects, no dependencies. It is safe to implement in isolation and verify with manual inspection before updating call sites.
- **Sonnet inclusion (D4):** This is the only user-visible behavioral change in Phase 1. The status bar will change from green to orange/red for users with high sonnet utilization. This is intentional and documented in ADR-002 D4. Release notes must call this out.

---

### Phase 2: Behavior — Exclusive Accordion + Compact Rows

**Goal:** Lift accordion state to `AccountList` (D1), enforce exclusive expand/collapse, and reduce row height to 48pt with conditional org name display (D2).

**Milestone M2:** Only one account can be expanded at a time; all-collapsed is a valid state; auto-expand targets the live account on popover open; collapsed rows are 48pt; org name is hidden when collapsed.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|------------|---------------------|
| 2.1 | Lift accordion state to `AccountList` | Add `@State private var expandedEmail: String?` to `AccountList` (`UsageView.swift` lines 694–714). Add `onAppear` to auto-expand the live account: `expandedEmail = accounts.first(where: { $0.isCurrentAccount })?.account.email`. Create `Binding<Bool>` adapter per ADR-002 D1 code sample. Pass `isExpanded: Binding<Bool>` to `AccountDisclosureGroup`. Replace `.frame(maxHeight: 380)` with `computedScrollHeight` (see 2.3). | `ClaudeUsage/UsageView.swift` — `AccountList` (lines 694–714) | Phase 1 complete | Expanding A collapses B; collapsing all rows leaves no expansion; live account auto-expands on open |
| 2.2 | Modify `AccountDisclosureGroup` to accept external binding | Replace `@State private var isExpanded` (line 523) with `let isExpanded: Binding<Bool>`. Remove auto-expand from `init` (line 529 — `_isExpanded = State(initialValue: accountUsage.isCurrentAccount || accountUsage.isActivelyRefreshing)`). All expansion decisions now made by `AccountList`. | `ClaudeUsage/UsageView.swift` — `AccountDisclosureGroup` (lines 520–690) | 2.1 | `AccountDisclosureGroup` compiles with `Binding<Bool>` param; no `@State` for expansion; build succeeds |
| 2.3 | Add `computedScrollHeight` to `AccountList` | Add `private var computedScrollHeight: CGFloat` to `AccountList`. Formula: `min(228 + (n-1) * 48, 380)` where n is `accounts.count`. **Risk note (RF5):** The constants 48pt (collapsed) and 228pt (expanded) are shared with `computePopoverHeight()` in `ClaudeUsageApp.swift` (Task 3.3). These constants MUST be updated together — changing one without the other will cause the popover height formula to diverge from actual layout. | `ClaudeUsage/UsageView.swift` — `AccountList` | 2.1 | N=1: height=228; N=2: height=276; N=3: height=324; N=6: height=380 (capped) |
| 2.4 | Reduce `AccountHeader` to 48pt with conditional org name | Change `.frame(height: 48)` (was line 490 with 56pt). Change `.padding(.vertical, 4)` (was 8pt). Add `isExpanded: Bool` parameter. Wrap org name in `if isExpanded { ... }`. Update all `AccountHeader` call sites to pass `isExpanded`. | `ClaudeUsage/UsageView.swift` — `AccountHeader` (lines 427–516) | 2.2 | Collapsed rows are 48pt; org name visible only when expanded; email always visible; three collapsed accounts = 144pt |

**Phase 2 Critical Path:** 2.1 → 2.2 → 2.4 (2.3 can be done alongside 2.1)

**Risk Mitigations:**
- **R1 (Binding adapter visual glitches):** Verify `DisclosureGroup(isExpanded: binding)` animation with 2, 3, and 4 accounts in SwiftUI Preview before committing. If the expand/collapse animation stutters, the parent-driven state update cycle differs from internal `@State` — this is a known trade-off documented in ADR-002 RF2.
- **RF5 (constants sync):** See Task 2.3 risk note. After completing 2.3, immediately add a code comment in `computedScrollHeight` and `computePopoverHeight()` noting they share these constants.

---

### Phase 3: Layout — Compressed Footer + Popover Height

**Goal:** Add 48pt compressed footer for multi-account mode (D3) and update `computePopoverHeight()` to reflect all new constants.

**Milestone M3:** Multi-account mode uses the compressed footer with gear menu; single-account footer is unchanged; popover height formula produces correct values (N=3: 416pt; N=1: 320pt).

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|------------|---------------------|
| 3.1 | Add `compressedFooterView()` to `UsageView` | Per D3: 48pt `HStack` with timestamp, gear `Menu` (Check for Updates + Launch at Login), refresh, globe, quit buttons. `.menuStyle(.borderlessButton)` for native `NSMenu` behavior. **CRITICAL (R6/RF1):** The ADR-002 D3 code sample OMITS the `.onChange(of: launchAtLogin)` handler for `SMAppService` register/unregister. This handler exists in `footerView()` (look for the `.onChange` block that calls `SMAppService.mainApp.register()` / `.unregister()`). It MUST be added to `compressedFooterView()` — without it, the Launch at Login toggle will update the UI state but fail to register/unregister with `SMAppService`. **Risk (RF3):** SwiftUI `Toggle` inside `SwiftUI.Menu` may not fire `.onChange` on macOS. Before committing, verify: (a) toggle the Launch at Login item and confirm the `.onChange` fires (check with logging or `SMAppService.mainApp.status`). If `.onChange` does not fire inside `Menu`, move the `Toggle` outside the `Menu` or replace with a `Button` that calls the register/unregister directly. | `ClaudeUsage/UsageView.swift` | Phase 2 complete | Gear menu shows on multi-account; "Launch at Login" toggle updates `SMAppService` status; refresh/globe/quit buttons work; footer height is 48pt |
| 3.2 | Conditional footer selection | Replace the bare `footerView()` call at line 66 with: `if manager.accounts.count > 1 { compressedFooterView() } else { footerView() }`. This wraps the existing unconditional footer call in a conditional — the multi-account content conditional at lines 57–61 is a separate block and must not be modified. Single-account mode must remain identical to v1.7. | `ClaudeUsage/UsageView.swift` — body | 3.1 | Single-account (N=1): full footer visible; multi-account (N=2+): compressed footer visible; manual switch between accounts validates both paths |
| 3.3 | Update `computePopoverHeight()` | In `ClaudeUsageApp.swift` (lines 156–171): update `collapsedRowHeight` 56→48, `expandedRowHeight` 236→228, `headerFooter` 144→92 (44pt header + 48pt compressed footer). Assume 1 expanded + (N-1) collapsed rows per RF1. Formula: `44 + 48 + 228 + (N-1) * 48`. **Risk (RF5):** These constants MUST match `computedScrollHeight` in `AccountList` (Task 2.3). After updating, verify: N=3 → 416pt; N=6 → 560pt (capped to 480pt); N=1 → 320pt (single-account path unchanged). | `ClaudeUsage/ClaudeUsageApp.swift` (lines 156–171) | 3.1, Phase 2 | N=3: `computePopoverHeight()` returns 416; N=6: returns 480 (capped); N=1: returns 320 |

**Phase 3 Critical Path:** 3.1 → 3.2; 3.3 (can be done alongside 3.2 once 3.1 is done)

**Risk Mitigations:**
- **R6/RF1 (CRITICAL — missing SMAppService handler):** The `.onChange(of: launchAtLogin)` block in the existing `footerView()` is the authoritative implementation. Copy it verbatim into `compressedFooterView()`. Do not rely on the ADR-002 D3 code sample — it omits this handler. Verify with a live test before committing.
- **RF3 (Toggle in Menu):** Test `.onChange` behavior before shipping. If it does not fire inside `SwiftUI.Menu` on the target macOS version, use a `Button("Launch at Login") { toggleLaunchAtLogin() }` pattern instead, calling `SMAppService.mainApp.register()` / `.unregister()` directly in the closure.
- **RF5 (constants):** After completing 3.3, add inline comments in both `computedScrollHeight` and `computePopoverHeight()` noting the shared constants must stay in sync.
- **R2 (popover height divergence):** The 480pt cap in `min(...)` in `computePopoverHeight()` is the safety bound. If actual SwiftUI layout height differs slightly from the formula, the popover will be slightly tall rather than clipped — acceptable.

---

### Phase 4: Extraction — File Decomposition

**Goal:** Extract the refactored `UsageView.swift` into 6 focused files (D5) and update the Xcode project file. Each file targets <150 lines.

**Milestone M4:** All 6 files exist under `ClaudeUsage/`, all are <150 lines, clean build succeeds, no functionality regression.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|------------|---------------------|
| 4.1 | Extract `UsageRow.swift` | Move `UsageRow`, `UsageRowStyle`, `formatTimeRemaining` (~80 lines) from `UsageView.swift` to new `ClaudeUsage/UsageRow.swift`. Verify build after extraction. | New: `ClaudeUsage/UsageRow.swift`; Modify: `ClaudeUsage/UsageView.swift` | Phase 3 complete | `UsageRow.swift` compiles; build succeeds; `UsageView.swift` line count reduced |
| 4.2 | Extract `AccountRow.swift` | Move `AccountDisclosureGroup`, `AccountHeader` (~130 lines) to new `ClaudeUsage/AccountRow.swift`. Verify build. | New: `ClaudeUsage/AccountRow.swift`; Modify: `ClaudeUsage/UsageView.swift` | 4.1 | `AccountRow.swift` compiles; build succeeds; ~130 lines |
| 4.3 | Extract `AccountDetail.swift` | Move `liveAccountDetail`, `staleAccountDetail` (~90 lines) to new `ClaudeUsage/AccountDetail.swift`. Update `AccountDisclosureGroup` in `AccountRow.swift` to reference the extracted views. | New: `ClaudeUsage/AccountDetail.swift`; Modify: `ClaudeUsage/AccountRow.swift` | 4.2 | `AccountDetail.swift` compiles; build succeeds; ~90 lines |
| 4.4 | Extract `AccountList.swift` | Move `AccountList` with `expandedEmail` state and `computedScrollHeight` (~60 lines) to new `ClaudeUsage/AccountList.swift`. | New: `ClaudeUsage/AccountList.swift`; Modify: `ClaudeUsage/UsageView.swift` | 4.2 | `AccountList.swift` compiles; build succeeds; ~60 lines |
| 4.5 | Verify `UsageView.swift` residual | Confirm residual `UsageView.swift` is ~120 lines containing: root view, conditional layout, app header, update banner, single-account content, `loadingView`, `errorView`, `footerView`, `compressedFooterView`. Verify build. | `ClaudeUsage/UsageView.swift` | 4.1–4.4 | `wc -l UsageView.swift` reports ~120 lines; build succeeds; no missing view types |
| 4.6 | Update Xcode project file | Add 5 new Swift files (`AccountList.swift`, `AccountRow.swift`, `AccountDetail.swift`, `UsageRow.swift`, `SharedStyles.swift`) to the `ClaudeUsage` target in Xcode via "Add Files to ClaudeUsage…" (not manual `.pbxproj` editing). Verify clean build. **Risk (R3):** Manual `.pbxproj` editing is the primary risk of this step — incorrect UUID generation or cross-reference errors can break the build in ways that are hard to diagnose. Use Xcode's "Add Files" UI or `xcodebuild` tooling only. Commit the `.pbxproj` change in isolation. | `ClaudeUsage.xcodeproj/project.pbxproj` | 4.5 | `xcodebuild -scheme ClaudeUsage -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` succeeds with no errors |

**Phase 4 Critical Path:** 4.1 → 4.2 → 4.3; 4.4 (parallel with 4.3); → 4.5 → 4.6

**Risk Mitigations:**
- **R3 (pbxproj editing):** Always use Xcode's "Add Files to ClaudeUsage…" dialog rather than manual text editing. Commit the `.pbxproj` change in an isolated commit with no other changes in flight. If the build fails after `.pbxproj` update, `git revert` the commit and retry via Xcode UI.
- **Build verification after each extraction:** Run `xcodebuild` after every file extraction (not just at 4.5). Catching missing imports early is far cheaper than debugging a full-phase compilation failure.

---

## Dependency Graph

```
Phase 1: Foundation (Pure Refactors)
─────────────────────────────────────
1.1 ──► 1.2
1.3 ──► 1.4
(1.1/1.2 and 1.3/1.4 are independent chains; both must complete before Phase 2)

Phase 2: Exclusive Accordion + Compact Rows
─────────────────────────────────────────────
[Depends on: Phase 1 complete]

2.1 ──► 2.2 ──► 2.4
2.1 ──► 2.3 (parallel with 2.2)

Phase 3: Compressed Footer + Popover Height
─────────────────────────────────────────────
[Depends on: Phase 2 complete]

3.1 ──► 3.2
3.1 ──► 3.3 (parallel with 3.2)

Phase 4: File Decomposition
─────────────────────────────
[Depends on: Phase 3 complete]

4.1 ──► 4.2 ──► 4.3 ──► 4.5 ──► 4.6
              └──► 4.4 ──► 4.5

Cross-Phase Dependencies:
Phase 2 depends on: Phase 1 complete (all call sites use Color.forUtilization, bottleneck in place)
Phase 3 depends on: Phase 2 complete (compressed footer assumes 48pt rows are done)
Phase 4 depends on: Phase 3 complete (extract only after all in-place changes are done)
```

---

## Critical Path

```
1.1 → 1.2 → [M1]
1.3 → 1.4 → [M1]
              ↓
         2.1 → 2.2 → 2.4
         2.1 → 2.3
              ↓ [M2]
         3.1 → 3.2
         3.1 → 3.3
              ↓ [M3]
         4.1 → 4.2 → 4.3
                   → 4.4
              ↓ 4.5 → 4.6
                    ↓ [M4]
```

**Critical path tasks (12):** 1.3 → 1.4 → 2.1 → 2.2 → 2.4 → 3.1 → 3.2 → 3.3 → 4.1 → 4.2 → 4.5 → 4.6

The single highest-risk point is **Task 3.1** (compressed footer with the missing SMAppService handler and the Toggle-in-Menu behavior uncertainty). The second highest-risk point is **Task 4.6** (Xcode project file update). Both should be tested thoroughly before committing.

---

## Milestones

| Milestone | Reached After | Verification Criteria |
|-----------|--------------|----------------------|
| M1 | Tasks 1.1–1.4 | `grep colorForPercentage ClaudeUsage/*.swift` → zero hits; `bottleneck` includes sonnet (manual test: sonnet=95 → bottleneck.percentage=95); status bar orange/red at sonnet ≥70%/90%; build passes |
| M2 | Tasks 2.1–2.4 | Expanding account A collapses account B; all-collapsed valid; live account auto-expands on open; collapsed rows 48pt; org name hidden when collapsed; single-account mode unchanged |
| M3 | Tasks 3.1–3.3 | Multi-account (N≥2): compressed footer with gear menu; single-account: full footer unchanged; `computePopoverHeight(3)` = 416pt; `computePopoverHeight(1)` = 320pt; Launch at Login toggle updates SMAppService |
| M4 | Tasks 4.1–4.6 | 6 files under `ClaudeUsage/`, all <150 lines; `xcodebuild` clean build passes; no functionality regression vs. M3; release notes drafted for sonnet inclusion behavioral change (Q3) |

---

## Risk Register

> **Note on numbering:** Plan risk IDs (R1–R3, RF1–RF6) extend the ADR-002 risk numbering (RF1–RF5) with additional implementation risks identified during planning. R1–R3 are implementation-specific; RF1–RF6 map to or extend ADR-002 risks.

| # | Severity | Risk | Phase Affected | Mitigation |
|---|----------|------|---------------|------------|
| R6/RF1 | **HIGH** | `compressedFooterView()` in ADR-002 D3 code sample omits `.onChange(of: launchAtLogin)` for `SMAppService` register/unregister | Phase 3, Task 3.1 | MUST add handler manually — copy verbatim from existing `footerView()`. Verify with live test: toggle Launch at Login and confirm `SMAppService.mainApp.status` changes. Do not ship without this verification. |
| RF3 | MEDIUM | `Toggle` inside `SwiftUI.Menu` may not fire `.onChange` on macOS | Phase 3, Task 3.1 | Verify `.onChange` fires before committing. If it does not: replace `Toggle` with a `Button` that calls register/unregister directly, or move the `Toggle` outside the `Menu`. |
| RF5 | MEDIUM | `computedScrollHeight` (Task 2.3) and `computePopoverHeight()` (Task 3.3) share constants (48pt collapsed, 228pt expanded) that must stay in sync | Phase 2, Phase 3 | Add inline comments in both locations noting the dependency. Update both in the same commit. After Task 3.3, verify: N=3 → `computePopoverHeight`=416 and `computedScrollHeight`=324 (scroll area only). |
| R1 | MEDIUM | `DisclosureGroup` with external `Binding<Bool>` may produce visual glitches or animation stutters | Phase 2, Task 2.1 | Test with 2, 3, and 4 accounts in SwiftUI Preview before committing. The `Binding` adapter pattern is documented in ADR-002 D1 and confirmed by the architecture team. If animation issues appear, use `withAnimation(.easeInOut)` wrapper. |
| R2 | MEDIUM | Popover height formula may diverge from actual SwiftUI layout at edge cases | Phase 3, Task 3.3 | The 480pt cap provides a safety bound — popover will be slightly tall rather than clipped. Use conservative fixed formula (assume 1 expanded + N-1 collapsed). Verify manually at N=3 and N=6. |
| R3 | MEDIUM | `.pbxproj` manual editing breaks build (LOW likelihood, HIGH impact) | Phase 4, Task 4.6 | Use Xcode "Add Files to ClaudeUsage…" UI only. Never edit `.pbxproj` as text. Commit in isolation. If build fails, `git revert` and retry via Xcode. |
| RF2 | MEDIUM | No automated tests for `bottleneck` computation | Phase 1, Task 1.3 | `bottleneck` is a pure computed property — strong candidate for XCTest unit tests if test infra is added. For now: verify manually with three test cases: (a) sonnet highest, (b) session highest, (c) weekly highest. Document results as a comment on the commit. |
| RF4 | LOW | `AccountHeader` parameter change (`isExpanded: Bool`) must be threaded through all call sites | Phase 2, Task 2.4 | Implementation order in Phase 2 (2.2 before 2.4) ensures `isExpanded` binding is available when `AccountHeader` is updated. Compiler will catch any missed call sites. |
| RF6 | LOW | `hasError` addition from design spec is beyond ADR-002 scope | — | Omit from this implementation. Not referenced in decomposition or ADR-002. Defer to a future ADR. |

---

## Testing Strategy

This implementation has no automated test infrastructure (inherited from ADR-001 R5). The testing strategy relies on SwiftUI Previews and manual verification.

### SwiftUI Previews (6 views)

| View | Preview Variants Required |
|------|--------------------------|
| `AccountHeader` | Collapsed (48pt, email only); Expanded (org name visible) |
| `AccountDisclosureGroup` | Live expanded; Live collapsed; Stale collapsed |
| `AccountList` | N=1 (single); N=3 (three accounts, live auto-expanded); N=6 (scroll kicks in) |
| `UsageRow` | Card style; Inline style |
| `UsageView` (single-account) | Pixel comparison against v1.7 baseline |
| `compressedFooterView` | Multi-account footer with gear menu visible |

### Manual Test Points (33 total)

**Phase 1 (4 tests):**
1. `grep colorForPercentage ClaudeUsage/*.swift` → zero hits
2. Status bar orange when sonnet = 75%, session = 20%, weekly = 30%
3. Status bar red when sonnet = 95%, session = 20%, weekly = 30%
4. Status bar green when all values < 70%

**Phase 2 (11 tests):**
5. Expand account A → account B collapses
6. Expand account B → account A collapses
7. Collapse expanded account → all-collapsed state valid (no snap-back)
8. Open popover → live account is auto-expanded
9. Close and reopen popover → live account is auto-expanded again
10. Collapsed row height = 48pt (verify with Accessibility Inspector)
11. Org name hidden when row is collapsed
12. Org name visible when row is expanded
13. Single-account: layout pixel-identical to v1.7
14. N=3: three collapsed rows = 144pt total (3 × 48pt)
15. N=3: scroll area height = 324pt (228 + 2×48)

**Phase 3 (10 tests):**
16. N=2: compressed footer visible (gear icon present)
17. N=1: full footer visible (no gear icon)
18. Gear menu opens on click
19. "Check for Updates" in gear menu functions correctly
20. "Launch at Login" toggle in gear menu: verify UI state updates
21. "Launch at Login" toggle: verify `SMAppService.mainApp.status` changes (CRITICAL — RF1)
22. Refresh button in compressed footer triggers refresh
23. Globe button opens claude.ai
24. Quit button terminates app
25. N=3: popover height ≈ 416pt (verify with Accessibility Inspector or layout debug)

**Phase 4 (8 tests):**
26. All 6 files exist under `ClaudeUsage/`
27. All 6 files are <150 lines (`wc -l ClaudeUsage/*.swift`)
28. `xcodebuild` clean build passes
29. Full regression: all Phase 2 and Phase 3 tests still pass after extraction
30. Single-account mode pixel-identical to v1.7 (final verification)
31. N=3 accordion exclusive expand still works after extraction
32. Compressed footer still works after extraction
33. No new compiler warnings introduced

---

## Rollback Strategy

Each task should be committed individually using the commit-per-step approach. This allows targeted `git revert` of any single step without unwinding all subsequent work.

**Recommended commit sequence:**
1. `D6: Create SharedStyles.swift with Color.forUtilization` (Task 1.1)
2. `D6: Update colorForPercentage call sites, remove duplicates` (Task 1.2)
3. `D4: Add bottleneck computed property to UsageData` (Task 1.3)
4. `D4: Update worstCaseUtilization and statusEmoji to use bottleneck` (Task 1.4)
5. `D1: Lift accordion state to AccountList with Binding adapter` (Tasks 2.1–2.3)
6. `D2: Reduce AccountHeader to 48pt with conditional org name` (Task 2.4)
7. `D3: Add compressedFooterView with SMAppService onChange handler` (Task 3.1–3.2)
8. `Update computePopoverHeight for 48pt rows and compressed footer` (Task 3.3)
9. `D5: Extract UsageRow, AccountRow, AccountDetail, AccountList, SharedStyles` (Tasks 4.1–4.5)
10. `D5: Add new files to Xcode project target` (Task 4.6 — isolated commit)

**Per-phase rollback:**

| Phase | Rollback Action | Data Migration Required |
|-------|----------------|------------------------|
| Phase 1 | `git revert` commits 1–4; restore original `colorForPercentage` functions | None — view layer only |
| Phase 2 | `git revert` commits 5–6; restore `@State private var isExpanded` in `AccountDisclosureGroup` | None — ephemeral SwiftUI state |
| Phase 3 | `git revert` commits 7–8; restore original `footerView()` call in body | None — view layer only |
| Phase 4 | `git revert` commits 9–10; files removed, `UsageView.swift` restored to full size | None — structural refactor only |

No UserDefaults or data model changes are made in any phase. All changes are view layer or `UsageData` computed properties. Rollback is clean at any step.

---

## Affected Files

| File | Status | Change | Phase |
|------|--------|--------|-------|
| `ClaudeUsage/SharedStyles.swift` | New | `Color.forUtilization`, `LiveIndicator`, `CachedBadge`, `StaleBadge` (D6 + D5) | 1, 4 |
| `ClaudeUsage/UsageManager.swift` | Modified | Add `bottleneck` to `UsageData`; update `worstCaseUtilization`, `statusEmoji` (D4) | 1 |
| `ClaudeUsage/UsageView.swift` | Modified → Reduced | D6 call site updates; D1 accordion state lift; D2 row height; D3 compressed footer; shrinks from 718 to ~120 lines after D5 extraction | 1, 2, 3, 4 |
| `ClaudeUsage/ClaudeUsageApp.swift` | Modified | Update `computePopoverHeight()` with new constants (D2, D3) | 3 |
| `ClaudeUsage/AccountList.swift` | New | `AccountList` with lifted `expandedEmail` state, `computedScrollHeight` (D5) | 4 |
| `ClaudeUsage/AccountRow.swift` | New | `AccountDisclosureGroup`, `AccountHeader` (D5) | 4 |
| `ClaudeUsage/AccountDetail.swift` | New | `liveAccountDetail`, `staleAccountDetail` (D5) | 4 |
| `ClaudeUsage/UsageRow.swift` | New | `UsageRow`, `UsageRowStyle`, `formatTimeRemaining` (D5) | 4 |
| `ClaudeUsage.xcodeproj/project.pbxproj` | Modified | Add 5 new source files to `ClaudeUsage` target (D5) | 4 |

---

## Open Questions

| # | Question | Source | Status | Recommendation |
|---|---------|--------|--------|----------------|
| Q1 | Does `Toggle` inside `SwiftUI.Menu` fire `.onChange` on macOS 13+? | Decomposition, Risk RF3 | **Open — verify in Task 3.1** | Test before committing. If `.onChange` does not fire, use `Button` with direct `SMAppService` calls instead. |
| Q2 | Should `expandedEmail` be persisted across popover sessions via `@AppStorage`? | ADR-002 D1 alternatives | **Deferred** | ADR-002 explicitly defers this. The `onAppear` auto-expand to live account is the approved default. Do not add persistence in this implementation. |
| Q3 | Release notes wording for sonnet inclusion in status bar | ADR-002 D4 consequences | **Open — pre-ship** | Suggested: "Status bar now reflects sonnet-only utilization when it is the highest active limit." Must appear in v2.0 release notes to avoid user surprise. |

---

## Success Metrics

From ADR-002:

- Three accounts collapsed fit within the popover without overflow — verify at 3, 4, and 5 accounts.
- Expanding one accordion row collapses any previously expanded row.
- Status bar reflects sonnet utilization when it exceeds session and weekly percentages.
- Single-account mode is visually identical to v1.7 (pixel comparison acceptable).
- All new files are under 150 lines.
- `colorForPercentage` has exactly one definition in the codebase.
- No ACL keychain dialog reappears (no changes to token reading path).
- `computePopoverHeight(3)` returns 416pt; popover does not exceed 480pt cap for any account count.

---

## Getting Started

A developer reading this plan for the first time should:

1. Read `docs/adr/ADR-002-compact-multi-account-ui.md` (architecture decisions D1–D6 and rationale).
2. Read `docs/designs/DESIGN-compact-multi-account-swift-ui-2026-03-02.md` (UI/UX specification).
3. Read the current source files: `ClaudeUsage/UsageView.swift` (~718 lines), `ClaudeUsage/UsageManager.swift`, `ClaudeUsage/ClaudeUsageApp.swift`.
4. Verify prerequisites P1–P7 above. Confirm `xcodebuild` passes on the current state.
5. Start with Phase 1 tasks 1.1 and 1.3 in parallel (they are independent).
6. Gate on milestones: do not begin Phase 2 until M1 is verified; do not begin Phase 3 until M2 is verified; do not begin Phase 4 until M3 is verified.
7. Pay special attention to the CRITICAL callout in Task 3.1 (SMAppService `.onChange` handler).
