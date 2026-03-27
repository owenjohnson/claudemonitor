# Implementation Plan: ClaudeMonitor Interface Redesign

**Date:** 2026-03-02
**Status:** Draft
**ADR Reference:** [ADR-003](../adr/ADR-003-compact-usage-row-and-keychain-migration.md)
**Design Spec:** [DESIGN-claudemonitor-interface-redesign-2026-03-02](../designs/DESIGN-claudemonitor-interface-redesign-2026-03-02.md)
**Estimated Effort:** 4 phases, 7 tasks, 3 commits

---

## Overview

This plan implements four decisions from ADR-003 that redesign the ClaudeMonitor macOS menu bar popover to improve information density, correctness, and code quality.

**D1** replaces the ~70pt card-style `UsageRow` (with progress bar and subtitle) with a 20pt compact single-line `HStack` at all 9 call sites across `UsageRow.swift`, `AccountDetail.swift`, and `UsageView.swift`. This recovers ~88pt per expanded account in the multi-account popover and supersedes ADR-002's single-account pixel-identity constraint. **D2** fixes a systematic rounding bug in `UsageData` where `Int(value)` truncation understates percentages by 0–1%, replacing three calls with `Int(value.rounded())` (IEEE 754 half-to-even). **D3** updates the hardcoded `expandedRowHeight` constant from 228pt to 140pt in both `AccountList.swift` and `ClaudeMonitorApp.swift` to reflect the reduced row height after D1, and includes the RF4 single-account fallback update from 320pt to 240pt. **D4** migrates keychain access from a `Process`/`Pipe`-based `security` CLI invocation to a synchronous `SecItemCopyMatching` call, removing the `nonisolated` async wrapper, the `withCheckedThrowingContinuation` pattern, and the `securityCommandFailed` error case.

The implementation is ordered to minimize regression risk: D2 (correctness fix, no visual impact) lands first, D4 (infrastructure, no visual impact) lands second, then D1 + D3 (visual redesign and coupled height constants) land together in a single atomic commit. All changes are in `ClaudeMonitor/` Swift files only. No data model, persistence, network, or dependency changes are required.

---

## Prerequisites

| Prerequisite | Status | Notes |
|---|---|---|
| ADR-003 accepted | Required | Plan proceeds on "Proposed" — implementor confirms before committing |
| Xcode project builds cleanly | Required | Run build before starting; resolve any pre-existing warnings |
| SwiftUI Previews functional | Required | Used for D1 visual verification at 1–5 accounts |
| VoiceOver available for testing | Required | macOS Accessibility must be enabled for R5 mitigation |
| Keychain entry present (`Claude Code-credentials` or `Claude Code`) | Required | D4 verification requires a live keychain entry |
| No uncommitted changes in `ClaudeMonitor/` | Required | Clean working tree before starting |

---

## Phase 1: Infrastructure Fixes (No UI Impact)

**Goal:** Land correctness and infrastructure changes that are independent of the visual redesign. Both tasks are independent of each other and can be done in either order, but each is its own commit.

### Tasks

| # | Task | Description | Files | Size | Depends On | Acceptance Criteria |
|---|------|-------------|-------|------|------------|---------------------|
| 1.1 | Fix percentage rounding (D2) | Change 3 `Int(value)` truncation calls to `Int(value.rounded())` in `UsageData` at `UsageManager.swift:12-14`. Verify IEEE 754 half-to-even rounding: 69.5→70, 89.5→90, 89.4→89, 88.5→88. | `UsageManager.swift:12-14` | S | None | `Int(value.rounded())` on all 3 percentage computed properties; build succeeds; no new warnings |
| 1.2 | Migrate keychain to `SecItemCopyMatching` (D4) | Replace `readKeychainRawJSON(service:)` (nonisolated async, Process/Pipe) with synchronous `readKeychainNative(service:)` using `SecItemCopyMatching`. Update `getClaudeCodeToken()`, `getAccessTokenFromAlternateKeychain()`, and `getAccessTokenWithChangeDetection()` to drop `async`/`await`. Add `KeychainError.from(status:)` static factory. Remove `securityCommandFailed` case. Update `isRetryable` to remove `securityCommandFailed`. Update catch clauses per ADR-003 D4 code sample: catch both `notLoggedIn` and `accessDenied` in `getClaudeCodeToken()` (so the alternate `"Claude Code"` keychain is tried before giving up). `refreshWithRetry()` drops `await` on `getAccessTokenWithChangeDetection()` but remains `async`. | `UsageManager.swift` (keychain section, KeychainError enum) | M | None | `readKeychainNative` uses `SecItemCopyMatching` with `kSecClassGenericPassword`; `getClaudeCodeToken()`, `getAccessTokenFromAlternateKeychain()`, `getAccessTokenWithChangeDetection()` are synchronous `throws`; `securityCommandFailed` case removed; `KeychainError.from(status:)` maps `errSecItemNotFound`, `errSecAuthFailed`, `errSecInteractionNotAllowed`, `errSecInvalidData`; `nonisolated` + `withCheckedThrowingContinuation` pattern eliminated; `getClaudeCodeToken()` catches both `notLoggedIn` and `accessDenied` before trying alternate keychain; build succeeds; app reads keychain and displays usage data |

### Milestone 1

App builds and reads keychain natively. Percentages display correctly rounded values. No `security` process spawned during refresh (verify with Activity Monitor or Instruments).

### Commit 1: D2 — Rounding Fix

```
fix: replace Int(value) truncation with Int(value.rounded()) in UsageData percentages (D2)
```

Files: `ClaudeMonitor/UsageManager.swift` (lines 12–14)

### Commit 2: D4 — Keychain Migration

```
refactor: migrate keychain access from security CLI to SecItemCopyMatching (D4)
```

Files: `ClaudeMonitor/UsageManager.swift` (keychain section, `KeychainError` enum)

---

## Phase 2: Compact Row Layout (D1)

**Goal:** Rewrite `UsageRow` to the compact 20pt single-line layout and update all 9 call sites.

### Tasks

| # | Task | Description | Files | Size | Depends On | Acceptance Criteria |
|---|------|-------------|-------|------|------------|---------------------|
| 2.1 | Rewrite `UsageRow` to compact 20pt `HStack` (D1) | Full rewrite of `UsageRow.swift`. Remove `UsageRowStyle` enum, `subtitle` parameter, `style` parameter, progress bar (`GeometryReader` + `RoundedRectangle`), and card background. Add single-line `HStack`: title (`.caption`), conditional timer at `percentage >= 70` (`.caption2`, `.secondary`), `Spacer()`, percentage (`.caption`, `.bold`, colored). `.frame(height: 20)`, `.padding(.horizontal, 4)`. Transfer accessibility: `.accessibilityElement(children: .ignore)`, `.accessibilityLabel("\(title) usage")`, `.accessibilityValue("\(percentage) percent")`. Add RF5 `accessibilityValueText` computed property. Retain `formatTimeRemaining()` as private method. Add RF3 `tooltipText` parameter (optional String, default nil). | `UsageRow.swift` (full rewrite, ~35 lines) | S | None | `UsageRowStyle` has zero references in codebase; `subtitle` parameter absent from `UsageRow` init; progress bar absent; `.frame(height: 20)` present; accessibility annotations present on `HStack`; VoiceOver announces "Session usage, N percent" |
| 2.2 | Update all 9 `UsageRow` call sites | Remove `subtitle:` and `style:` parameters from 6 call sites in `AccountDetail.swift` (3 in `LiveAccountDetail`, 3 in `StaleAccountDetail`) and 3 call sites in `UsageView.usageContent()`. Add RF3 `tooltipText` values at each call site. Change `VStack(spacing: 16)` to `VStack(spacing: 8)` in `usageContent()`. Update pixel-identity comments (grep for `pixel-identical to v1.7` must return zero results in `UsageView.swift`). | `AccountDetail.swift`, `UsageView.swift` | S | 2.1 | Zero `subtitle:` parameters in codebase; zero `style:` parameters in codebase; zero `UsageRowStyle` references; `VStack(spacing: 8)` in `usageContent()`; grep for `pixel-identical to v1.7` returns zero results in `UsageView.swift`; SwiftUI Previews at 1, 2, 3, 5 accounts render correctly |

### Milestone 2

Compact 20pt rows at all 9 call sites. VoiceOver works correctly. SwiftUI Previews verified at 1, 2, 3, 5 accounts. `UsageRowStyle` and `subtitle` are fully dead.

---

## Phase 3: Height Constant Update (D3)

**Goal:** Update coupled height constants to match the new 20pt row height. Must be done atomically with Phase 2 in the same commit.

### Tasks

| # | Task | Description | Files | Size | Depends On | Acceptance Criteria |
|---|------|-------------|-------|------|------------|---------------------|
| 3.1 | Update height constants (D3) | Update `expanded` from 228 to 140 in `AccountList.computedScrollHeight` (`AccountList.swift:52`). Update `expandedRowHeight` from 228 to 140 in `ClaudeMonitorApp.computePopoverHeight()` (`ClaudeMonitorApp.swift:164`). Include RF4: update single-account fallback from 320 to 240 in `computePopoverHeight()` (`ClaudeMonitorApp.swift:158`). Update comments in both files. Both files must be in the same commit as tasks 2.1 and 2.2. | `AccountList.swift:52`, `ClaudeMonitorApp.swift:158,164` | S | 2.1, 2.2 | `expanded = 140` in `computedScrollHeight`; `expandedRowHeight = 140` in `computePopoverHeight()`; single-account fallback = 240; popover height correct at N=2 (280pt), N=3 (328pt), N=6 (472pt); no excess whitespace in popover |

### Milestone 3

Correct popover heights at all account counts. Three accounts fit at 328pt. The 480pt cap is not hit until N≈7–8 accounts.

### Commit 3: D1 + D3 — Compact Rows + Height Updates (Atomic)

```
feat(D1+D3): compact 20pt UsageRow at all 9 call sites, update expandedRowHeight to 140pt
```

Files: `ClaudeMonitor/UsageRow.swift`, `ClaudeMonitor/AccountDetail.swift`, `ClaudeMonitor/UsageView.swift`, `ClaudeMonitor/AccountList.swift`, `ClaudeMonitor/ClaudeMonitorApp.swift`

**Critical:** D1 and D3 must be in the same commit. Height constants without compact rows produce excess whitespace. Compact rows without height constant updates leave the popover oversized.

---

## Phase 4: Verification

**Goal:** Confirm the build is clean, dead code is swept, and no regressions are introduced.

### Tasks

| # | Task | Description | Files | Size | Depends On | Acceptance Criteria |
|---|------|-------------|-------|------|------------|---------------------|
| 4.1 | Build verification and dead code sweep | Build with `xcodebuild -scheme ClaudeMonitor -configuration Debug build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`. Grep for dead references: `UsageRowStyle`, `subtitle:`, `securityCommandFailed`, `readKeychainRawJSON`, `withCheckedThrowingContinuation`, `pixel-identical to v1.7`. Verify zero warnings. Run full 29-scenario manual test matrix (see below). | All changed files | S | 3.1 | Build succeeds with zero errors and zero warnings; all dead symbol greps return no results; 29 manual test scenarios pass |

### Milestone 4

Build passes. Dead code eliminated. All 29 manual test scenarios verified.

---

## Dependency Graph

```
Task 1.1 (D2: rounding fix) [INDEPENDENT]       Task 1.2 (D4: keychain migration) [INDEPENDENT]
                                    \                           /
                                     \                         /
                                      v                       v
                               Task 2.1 (D1: UsageRow rewrite) [no structural dep on 1.1]
                                              |
                                              v
                               Task 2.2 (D1: 9 call sites)
                                              |
                                              v
                               Task 3.1 (D3: height constants) [ATOMIC with 2.1+2.2]
                                              |
                                              v
                               Task 4.1 (verification)
```

**Critical path:** `2.1 → 2.2 → 3.1 → 4.1`

Tasks 1.1 and 1.2 are both fully independent of each other and of Phase 2. They can be done in any order or in parallel. D2 (task 1.1) should ideally land before D1 (task 2.1) so that manual testing of the compact row uses correctly rounded percentages, but this is a testing-quality preference, not a structural code dependency — `UsageRow` receives `percentage: Int` as a parameter and has no direct dependency on `UsageData`'s rounding logic.

---

## Risk Register

| ID | Risk | Likelihood | Impact | Phase Affected | Mitigation |
|----|------|-----------|--------|----------------|------------|
| R1 | Height constant drift — `AccountList.swift` and `ClaudeMonitorApp.swift` get out of sync | Med | High | Phase 3 | Atomic commit (D1+D3 together in Commit 3); verified in 4.1 |
| R2 | ACL dialog denial — user clicks Deny on `SecItemCopyMatching` dialog | Med | Med | Phase 1 (D4) | Existing `accessDenied` errorDescription is adequate guidance; release notes should instruct "Always Allow" |
| R3 | `isRetryable` behavior change from removing `securityCommandFailed` | Low | Low | Phase 1 (D4) | Moot — CLI path removed entirely; `isRetryable` is updated in task 1.2 |
| R4 | 20pt rows clip visually on minimum deployment target | Med | Low | Phase 2 (D1) | Use `.frame(minHeight: 20)` if clipping observed in Previews; fallback is 24pt (ADR-003 D1 note) |
| R5 | Accessibility regression from progress bar removal | Low | High | Phase 2 (D1) | Transfer `.accessibilityLabel` + `.accessibilityValue` to `HStack` in task 2.1; VoiceOver manual test in 4.1 |
| R6 | Async-to-sync cascade missed in D4 caller chain | Low | Low | Phase 1 (D4) | Swift compiler catches missing/extra `await`; build verification in 4.1 |
| R7 | Rounding change shifts displayed percentage by 0–1% | Low | Low | Phase 1 (D2) | Intended fix; verify boundary cases at 69.5% and 89.5% in manual test matrix |
| R8 | No automated tests for any of D1–D4 | High | Med | All phases | 29-scenario manual test matrix (see below); SwiftUI Previews at multiple account counts |
| R9 | ADR-003 vs design spec catch semantics diverge | Med | Med | Phase 1 (D4) | **Resolution: follow ADR-003 D4 code sample.** Catch both `notLoggedIn` and `accessDenied` in `getClaudeCodeToken()` so the alternate `"Claude Code"` keychain is tried before propagating. The ADR-003 code sample is the normative spec and supersedes the design spec summary. |
| R10 | Single-account height has excess whitespace after compact rows | Med | Low | Phase 3 (D3) | **Resolution: include 320→240 update** in task 3.1 (RF4) |
| R11 | `StaleAccountDetail` passes `nil` for `resetsAt` — timer must not show | Low | None | Phase 2 (D1) | No change needed; `percentage >= 70 && resetsAt != nil` guard handles this correctly |
| R12 | `.help()` tooltip may not render in `NSPopover`-hosted SwiftUI views | Low | Low | Phase 2 (D1) | Parameter is no-op safe if ineffective (passing `nil` or empty string applies no tooltip). Verify in manual testing (T11–T17). Omit `.help()` call if confirmed non-functional in popover context. |

---

## Red Flag Resolutions

| # | Red Flag | Decision |
|---|----------|----------|
| RF1 | Dedicated error view for `accessDenied` | **Defer.** Existing `errorDescription` "Keychain access denied. Please allow access in System Settings." is adequate. No new error view in scope. |
| RF2 | Catch semantics in `getClaudeCodeToken()` | **Follow ADR-003 D4 code sample** (supersedes design spec summary). Catch both `notLoggedIn` and `accessDenied`; try alternate `"Claude Code"` keychain before propagating. ADR-003 D4 catch clause updated in task 1.2. |
| RF3 | Tooltip parameter on `UsageRow` | **Include.** Add optional `tooltipText: String? = nil` parameter to `UsageRow` init and apply `.help(tooltipText ?? "")` on the row. One line per call site in task 2.2. |
| RF4 | Single-account height 320→240 | **Include in D3.** Update `computePopoverHeight()` fallback from 320 to 240 in task 3.1. |
| RF5 | `accessibilityValueText` computed property | **Include in D1 rewrite.** Add `private var accessibilityValueText: String` to `UsageRow` for richer VoiceOver announcement. Applied in task 2.1. |

---

## Manual Test Matrix (29 Scenarios)

### Category 1: Percentage Rounding (D2) — 5 scenarios

| # | Input | Expected Display | Expected Color |
|---|-------|-----------------|----------------|
| T1 | sessionUtilization = 69.4 | 69% | Green |
| T2 | sessionUtilization = 69.5 | 70% | Orange (threshold crossed) |
| T3 | sessionUtilization = 89.4 | 89% | Orange |
| T4 | sessionUtilization = 89.5 | 90% | Red (threshold crossed) |
| T5 | sessionUtilization = 88.5 | 88% | Orange (banker's rounding: 88.5→88) |

### Category 2: Keychain Access (D4) — 5 scenarios

| # | Scenario | Expected Outcome |
|---|----------|-----------------|
| T6 | First launch after D4 ships | macOS ACL dialog appears for "Claude Code-credentials" |
| T7 | User clicks "Always Allow" on ACL dialog | App reads keychain, displays usage; no further dialogs |
| T8 | User clicks "Deny" on ACL dialog | `accessDenied` is caught; alternate `"Claude Code"` keychain tried; if also absent/denied, `notLoggedIn` error displayed: "Not logged in to Claude Code" |
| T9 | Keychain entry absent (not logged in to Claude Code) | `notLoggedIn` error: "Not logged in to Claude Code" |
| T10 | Normal launch after "Always Allow" granted | Keychain read succeeds silently; no subprocess visible in Activity Monitor |

### Category 3: Compact Row Layout (D1) — 7 scenarios

| # | Scenario | Expected Outcome |
|---|----------|-----------------|
| T11 | Single account, session < 70% | Single compact row; no timer visible; percentage in green |
| T12 | Single account, session >= 70% | Timer visible next to title; percentage in orange |
| T13 | Single account, session >= 90% | Timer visible; percentage in red |
| T14 | Single account, sonnetPercentage = nil | Only 2 rows (Session + Weekly) |
| T15 | Single account, sonnetPercentage present | 3 rows (Session + Weekly + Sonnet Only) |
| T16 | Multi-account (3 accounts), expand live account | 3 compact rows in expanded detail; other accounts collapsed |
| T17 | `StaleAccountDetail` with usage | Compact rows with stale color; no timer (resetsAt = nil) |

### Category 4: Height Calculations (D3) — 5 scenarios

| # | N accounts | Expected Popover Height |
|---|-----------|------------------------|
| T18 | 1 account | 240pt (single-account fallback, updated from 320) |
| T19 | 2 accounts | 92 (header+footer) + 140 (1 expanded) + 48 (1 collapsed) = 280pt |
| T20 | 3 accounts | 92 (header+footer) + 140 (1 expanded) + 96 (2 collapsed) = 328pt |
| T21 | 6 accounts | 92 + 140 + 240 = 472pt (within 480pt cap) |
| T22 | 9 accounts | Capped at 480pt; scroll area scrollable |

### Category 5: Accessibility (D1) — 3 scenarios

| # | Scenario | Expected VoiceOver Announcement |
|---|----------|--------------------------------|
| T23 | VoiceOver on Session row at 45% | "Session usage, 45 percent" |
| T24 | VoiceOver on Weekly row at 92% | "Weekly usage, 92 percent" |
| T25 | VoiceOver on Sonnet Only row at 0% | "Sonnet Only usage, 0 percent" |

### Category 6: Error States — 4 scenarios

| # | Scenario | Expected Outcome |
|---|----------|-----------------|
| T26 | Network unavailable during refresh | Error message visible in UI; no crash |
| T27 | API returns 401 | "Authentication expired. Run 'claude' to re-authenticate." |
| T28 | `missingOAuthToken` — keychain has JSON but no `claudeAiOauth` key | Diagnostic error with available keys displayed |
| T29 | `interactionNotAllowed` — device screen locked during refresh | Error message displayed: "Keychain interaction not allowed. Try unlocking your Mac."; app recovers automatically on next refresh cycle |

---

## Acceptance Criteria (Per Milestone)

### Milestone 1 (after Commits 1 and 2)
- `Int(value.rounded())` on all 3 percentage computed properties in `UsageData`
- `readKeychainNative` uses `SecItemCopyMatching` with `kSecClassGenericPassword`
- `getClaudeCodeToken()`, `getAccessTokenFromAlternateKeychain()`, `getAccessTokenWithChangeDetection()` are synchronous `throws` (no `async`)
- `securityCommandFailed` case removed from `KeychainError`
- `KeychainError.from(status:)` maps `errSecItemNotFound`, `errSecAuthFailed`, `errSecInteractionNotAllowed`, `errSecInvalidData`
- `nonisolated` modifier and `withCheckedThrowingContinuation` pattern eliminated from keychain code
- Build succeeds with zero errors

### Milestone 2 (after start of Commit 3 — pre-height update)
- `UsageRowStyle` has zero references in codebase
- `subtitle` parameter absent from `UsageRow` init and all call sites
- Progress bar (`GeometryReader` + `RoundedRectangle`) absent from `UsageRow`
- `.frame(height: 20)` present on `HStack`
- Accessibility annotations transferred: `.accessibilityElement(children: .ignore)`, `.accessibilityLabel`, `.accessibilityValue` on `HStack`
- `VStack(spacing: 8)` in `usageContent()`
- Grep for `pixel-identical to v1.7` returns zero results in `UsageView.swift`

### Milestone 3 (Commit 3 complete)
- `expanded = 140` in `AccountList.computedScrollHeight`
- `expandedRowHeight = 140` in `computePopoverHeight()`
- Single-account fallback = 240 in `computePopoverHeight()`
- Popover height correct at N=2 (280pt), N=3 (328pt), N=6 (472pt)
- No excess whitespace visible in popover at any account count

### Milestone 4 (after Phase 4)
- Build succeeds with zero errors and zero warnings
- Grep for `UsageRowStyle` returns zero results
- Grep for `subtitle:` in `UsageRow` context returns zero results
- Grep for `securityCommandFailed` returns zero results
- Grep for `readKeychainRawJSON` returns zero results
- Grep for `withCheckedThrowingContinuation` returns zero results
- All 29 manual test scenarios pass

---

## Rollback Strategy

### Rollback Commit 1 (D2: rounding fix)

```bash
git revert <commit-1-sha>
```

Effect: `Int(value.rounded())` reverts to `Int(value)`. Percentages display floor-truncated values again. No visual or structural impact beyond percentage display.

### Rollback Commit 2 (D4: keychain migration)

```bash
git revert <commit-2-sha>
```

Effect: `readKeychainNative` is replaced by `readKeychainRawJSON`. CLI subprocess approach resumes. The "Always Allow" ACL permission granted during D4 remains in the keychain ACL (harmless if `SecItemCopyMatching` is no longer called). `securityCommandFailed` case is restored.

### Rollback Commit 3 (D1+D3: compact rows + height constants)

```bash
git revert <commit-3-sha>
```

Effect: Card-style `UsageRow` is restored. Height constants revert to 228pt expanded and 320pt single-account. The rollback of D1 and D3 is atomic by design — reverting Commit 3 restores both changes together, preventing height constant mismatch. No UserDefaults or persistence cleanup required.

### Rollback Order

If all three commits need to be reverted, revert in reverse order: Commit 3, then Commit 2, then Commit 1. Each revert is a new commit on the branch (do not force-push).

---

## Open Questions

| # | Question | Owner | Resolution |
|---|----------|-------|------------|
| OQ-1 | Does 20pt row height clip `.caption` (12pt) text on the minimum macOS deployment target? | Implementor | Verify in SwiftUI Previews; fall back to 24pt if clipping observed |
| OQ-2 | Should `expandedRowHeight` be extracted to a shared `LayoutConstants` enum (ADR-003 D3 alternative)? | Architecture | Deferred per ADR-003: comment-based coupling is sufficient until a 4th height-relevant change occurs |
| OQ-3 | What is the exact DisclosureGroup internal content padding on the minimum macOS target? | Implementor | Empirically measure in Previews at 2, 3, 4, 5 accounts; adjust 140pt if observed height differs materially |
| OQ-4 | Should a dedicated error view be added for `accessDenied` (RF1)? | Product | Deferred: existing `errorDescription` is adequate for v1.x |
| OQ-5 | Is `tooltipText` parameter (RF3) surfaced in any macOS menu bar popover without a window? | Implementor | See R12. Verify `.help()` modifier works in `NSPopover`-hosted SwiftUI during T11–T17 testing; omit `.help()` call if confirmed non-functional. Parameter itself is safe to retain regardless. |
