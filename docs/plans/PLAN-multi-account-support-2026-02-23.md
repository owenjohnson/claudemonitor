# Implementation Plan: Multi-Account Support

**Date:** 2026-02-23
**Status:** Draft
**ADR Reference:** `docs/adr/ADR-001-multi-account-support.md`
**Design Reference:** `docs/designs/DESIGN-multi-account-support-2026-02-23.md`
**Target Version:** v1.8

**Effort Estimates:**
- Optimistic: 26 hours (no blockers, clean implementation)
- Realistic: 46 hours (includes learning curve, debugging, manual testing)
- Pessimistic: 78 hours (blocker resolution, rework from atomic interface change issues)

---

## Overview

ClaudeUsage is a macOS menubar app (~833 lines across 3 Swift files) that currently monitors Claude Code API usage for a single account. This plan implements multi-account support: detecting when the active Claude Code account changes via keychain polling, persisting account metadata in UserDefaults, and displaying usage history for all known accounts with clear live/stale distinction.

The central architectural constraint is that macOS stores exactly one Claude Code credential in the keychain at any time. This feature is therefore **account history**, not concurrent live monitoring. Only the current active account can fetch live data. All previously-seen accounts display their last-known usage marked as stale. This must be communicated clearly in UI labeling and release notes — it is not a limitation to hide.

The implementation is structured as four sequential phases that can be gated at milestones: Phase A establishes token capture and the new data model; Phase B moves `Process`/`Pipe` off `@MainActor` and enables concurrent per-account fetches; Phase C delivers the full multi-account UI; Phase D handles polish, edge cases, and release preparation. Single-account users must experience zero visible change after the update — the single-account layout is pixel-identical to v1.7.

---

## Prerequisites

| # | Prerequisite | Status | Blocking? | Notes |
|---|-------------|--------|-----------|-------|
| P1 | Xcode 15+ with Swift concurrency | MET | No | Required for `async/await`, `TaskGroup`, `nonisolated` |
| P2 | macOS 13+ deployment target | MET | No | `DisclosureGroup` available since macOS 11; `SMAppService` requires macOS 13 |
| P3 | Second Claude Code account for integration testing | **UNMET** | **Yes — blocks Phase B/D validation** | Need a real second account to test account-switch detection, staleness display, and token longevity |
| P4 | Understanding of `Process`/`Pipe` Sendable constraints | MET | No | Documented in ADR D4 and Design spec; `nonisolated` wrapper pattern defined |
| P5 | Instruments profiling setup for main thread verification | **UNMET** | Soft (Phase B) | Needed to verify `Process` is off main thread after B1; set up Instruments Time Profiler before Phase B |
| P6 | Backup of current working state | MET | No | Git: working state is on `main`, recent commit `8f5310a` |
| P7 | Read complete codebase | MET | No | 3 files, 833 lines: `UsageManager.swift`, `ClaudeUsageApp.swift`, `UsageView.swift` |
| P8 | v1.7 security CLI approach reviewed | MET | No | Commit `8f5310a` — `security` CLI is the correct approach, not `SecItemCopyMatching` |
| P9 | Decision on OQ-3 (stale accounts in menubar worst-case) | **UNMET** | **Yes — blocks C8** | Design spec recommends excluding stale accounts from worst-case calculation; this must be decided before C8 |
| P10 | Fix recursive retry defer bug (R17) | **UNMET** | **Yes — blocks Phase B** | Bug in `refreshWithRetry` must be fixed before Phase B builds on the refresh path |

### Resolving Unmet Prerequisites Before Starting

- **P3**: Arrange access to a second Claude Code account before starting Phase B. Phase A can proceed without it.
- **P5**: Open Instruments → Time Profiler against the app before starting B1. Confirm you can identify `getClaudeCodeToken` on the main thread baseline.
- **P9**: **Adopt the Design spec recommendation** — exclude stale accounts from worst-case menubar calculation. Stale accounts showing historical high usage would produce persistent false alarms. Record this decision as a task comment in C8.
- **P10**: Fix the recursive retry bug as a pre-task before Phase B begins (see task B-pre in Phase B).

---

## Phases and Tasks

### Phase A: Token Capture & Storage

**Goal:** Establish the new data model, 60-second token-comparison polling, UserDefaults persistence, and updated `AppDelegate` subscribers. At the end of Phase A, the app works identically to v1.7 for single-account users but internally uses the new `[AccountUsage]` model.

**Milestone M1:** Single-account UI works with new data model; token-change detection is active; `AppDelegate` compiles against `$accounts`.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|-----------|---------------------|
| A1 | Create `AccountRecord` and `AccountUsage` types in new `AccountModels.swift` | Define both `Codable` structs per ADR D2. `AccountRecord` fields: `email`, `displayName`, `organizationName`, `subscriptionType`, `tokenExpiresAt`, `tokenCapturedAt`, `addedAt`. `AccountUsage` fields: `account`, `usage`, `error`, `isLoading`, `lastUpdated`, `isCurrentAccount`. | S (1h) | — | Types compile cleanly; `AccountRecord` round-trips through `JSONEncoder`/`JSONDecoder` in a playground/test |
| A2 | Implement UserDefaults persistence for `[AccountRecord]` | Add `loadAccounts() -> [AccountRecord]` and `saveAccounts(_ records: [AccountRecord])` to `UsageManager` using key `"claudeusage.accounts"`. Use `JSONEncoder`/`JSONDecoder`. | S (1h) | A1 | Accounts survive app relaunch; empty array on fresh install |
| A3 | Extract `getClaudeCodeToken()` into standalone `async` function | Create `private func readKeychainRawJSON() async throws -> String` that moves `Process`/`Pipe` execution off `@MainActor` using the `nonisolated` + `withCheckedThrowingContinuation` + `terminationHandler` pattern (defined verbatim in Design spec, Process/Pipe Sendability section). The existing synchronous `getClaudeCodeToken` is the critical risk point; do not break existing callers until A7. | M (2h) | — | `readKeychainRawJSON` compiles without Sendable warnings; `getClaudeCodeToken` still works as-is |
| A4 | Implement token-change comparison logic with `lastSeenToken` | Add `private var lastSeenToken: String?` to `UsageManager`. Add helper `private func extractAccessToken(from rawJSON: String) -> String?`. On each poll: if new token == `lastSeenToken`, skip profile call. If different or nil, call profile API and update `lastSeenToken`. | S (1h) | A3 | Token comparison correctly identifies same-token (no API call) vs. new-token (API call triggers) in manual test |
| A5 | Gate profile API call on token-change detection | Modify (or replace) the existing `refresh()` path so `/api/oauth/profile` is called only when the token has changed. On unchanged token, reuse the cached `AccountRecord` from UserDefaults to match the current account. | M (2h) | A3, A4 | Profile API is not called on consecutive refreshes when account is unchanged; confirmed by logging |
| A6 | Create/update `AccountRecord` on token change | When a new token is detected: call `/api/oauth/profile`, extract `email`/`displayName`/`org`. Look up existing `AccountRecord` by `email`. If found, update `lastTokenCapturedAt`; if not found, create new record. Persist to UserDefaults. Mark previous `isCurrentAccount` = false; mark new one = true (tracked in `AccountUsage`, not stored in `AccountRecord`). | S (1h) | A5 | After simulated token change, UserDefaults contains a new `AccountRecord`; existing record is not duplicated on re-auth to same account |
| A7 | Replace 5 `@Published` vars with single `accounts: [AccountUsage]` | Remove `@Published var usage`, `error`, `isLoading`, `lastUpdated`, `displayName`. Add `@Published var accounts: [AccountUsage]`. Update all `UsageManager` internal logic to write to `accounts`. **This is an atomic breaking change** — `AppDelegate` and `UsageView` will not compile until A8 and the C-phase UI work. Plan to do A7 + A8 in a single non-compiling edit session. | M (3h) | A1, A2 | App compiles and runs with single account after A7+A8 are both complete; behavior is identical to v1.7 for single account |
| A8 | Update `AppDelegate` Combine subscribers for `$accounts` | Rewrite all `sink`/`assign` chains in `AppDelegate` that read `$usage`, `$error`, `$isLoading`, `$displayName`, `$lastUpdated` to use `$accounts`. Update `updateStatusItem()` to extract worst-case utilization from the live account in `accounts`. | M (2h) | A7 | App compiles; menubar title updates correctly; single-account behavior is pixel-identical to v1.7 |

**Phase A Critical Path:** A3 → A4 → A5 → A6 → A7 → A8

**Parallelizable:** A1–A2 can be done in parallel with A3–A4 (independent of each other).

**Risk Mitigations in Phase A:**
- **R9 (Atomic interface change):** Perform A7 and A8 in the same editing session without attempting to build until both files are updated. Do not merge a partial state.
- **R10 (Combine chain rewrite):** Read all `AppDelegate` Combine subscribers before touching A8. List every `sink` on `$usage`/`$error` etc. and map each to its `$accounts` equivalent before writing any code.
- **R11 (UsageView GeometryReader):** UsageView is not touched in Phase A. It will fail to compile after A7 until Phase C. Suppress or stub the view temporarily if needed to validate A8 in isolation.
- **R16 (Profile API called every refresh):** Fixed by A5 (token-comparison gate).

---

### Phase B: Multi-Account Refresh

**Goal:** Move `Process`/`Pipe` off `@MainActor`, add `isRefreshing` guard, enable concurrent per-account usage fetches via `TaskGroup`, and reduce timer to 60 seconds.

**Prerequisite Pre-Task (B-pre): Fix recursive retry defer bug (R17)**
Before starting Phase B, locate and fix the recursive retry bug in `refreshWithRetry`. The `defer` block placement creates a risk of double-firing or never-firing the guard reset. Read the function carefully, fix the control flow, and commit. This must be resolved before Phase B adds `isRefreshing` and concurrent fetches that depend on the retry path.

**Milestone M2:** Multi-account refresh is working; `Process` is off the main thread (confirmed with Instruments); `isRefreshing` guard prevents overlapping refreshes.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|-----------|---------------------|
| B-pre | Fix recursive retry defer bug (R17) | Read `refreshWithRetry`. Identify the `defer` block bug. Fix control flow so that: (a) `isRefreshing` is reliably reset on all exit paths, and (b) the recursive retry does not inadvertently re-enter the function in a broken state. | S (1h) | — | Can manually trigger a refresh failure and verify retry fires exactly once; `isRefreshing` is false after retry completes |
| B1 | Create `nonisolated` async `Process`/`Pipe` wrapper | Implement the `readKeychainRawJSON()` function from A3 as a fully `nonisolated` function using `withCheckedThrowingContinuation` + `terminationHandler` (not `process.waitUntilExit()`). `Process` and `Pipe` must be instantiated within the `nonisolated` scope; return only `String`. This is the highest-risk task in Phase B. | M (3h) | A3 | No Swift concurrency compiler warnings; Instruments Time Profiler shows no main thread blocking during keychain reads |
| B2 | Add `isRefreshing` guard to `refresh()` | Add `private var isRefreshing = false` to `UsageManager`. At the start of `refresh()`: if `isRefreshing` is true, return immediately. Set `isRefreshing = true` at start; set `false` in `defer`. Must be placed before reducing timer interval. | S (0.5h) | B-pre | Two concurrent `refresh()` calls do not race; second call returns immediately and no double-refresh occurs |
| B3 | Reduce timer from 120s to 60s | Change `Timer.scheduledTimer` interval from 120 to 60 seconds. Must not be done before B2 is in place. | S (0.5h) | B2 | Timer fires every 60 seconds; `isRefreshing` guard prevents overlap |
| B4 | Implement `TaskGroup` for concurrent per-account usage fetches | Use `withTaskGroup(of: AccountUsage.self)` to fetch `/api/oauth/usage` for each account concurrently. For the live account: read live token, fetch usage. For stale accounts: skip the usage fetch (they display last-known data only). Publish updated `accounts` array on `@MainActor` after group completes. | M (3h) | B1 | Refresh does not block main thread; log shows concurrent fetches starting; accounts array updates after all complete |
| B5 | Add per-account error isolation | Each account's fetch in the `TaskGroup` must catch its own errors independently. A network failure on account A must not cancel the fetch for account B. Set `AccountUsage.error` on the failing account; other accounts complete normally. | S (1h) | B4 | Simulated network failure on one account leaves other accounts' data intact and displayed correctly |
| B6 | Integrate new refresh into polling loop | Wire the new `TaskGroup`-based refresh into the 60-second timer and the manual refresh button. Remove the old single-account refresh path. Ensure `isRefreshing` is correctly managed across this new path. | M (2h) | B1, B2, B3, B4, B5 | Full end-to-end refresh cycle works; `accounts` publishes updated data every 60 seconds; manual refresh button triggers the same path |

**Phase B Critical Path:** B-pre → B1 → B4 → B5 → B6

**Parallelizable:** B2 and B3 can be done in parallel with B1 (B3 depends on B2 only).

**Risk Mitigations in Phase B:**
- **R2 (Process on @MainActor):** B1 is the explicit fix. Do not proceed to B4 until Instruments confirms the main thread is unblocked.
- **R4 (Timer overlap):** B2 must be merged before B3 reduces the interval.
- **R8 (Pipe not Sendable):** Enforced by instantiating `Process` and `Pipe` entirely within the `nonisolated` scope. Return only `String`. The compiler will enforce this.
- **R7 (getClaudeCodeToken is synchronous):** Fixed by B1 (async `nonisolated` wrapper).

---

### Phase C: Multi-Account UI

**Goal:** Deliver the full multi-account UI: conditional single/multi layout, `DisclosureGroup` accordion, stale indicators, dynamic popover sizing, and menubar title aggregation.

**Pre-Phase C Decision Required:**
- **OQ-3 (resolved):** Exclude stale accounts from worst-case menubar calculation. Implement C8 with live-accounts-only worst-case.
- **OQ-1 (move "Remove account" to Phase C):** Per Design spec recommendation, include a minimal "Remove account" context menu on stale account rows in Phase C, not Phase D. Users who switch accounts daily will otherwise accumulate stale rows with no pruning path until v2 auto-prune ships. This is a small change that prevents a first-launch experience complaint.
- **OQ-4 (NSPopover animation strategy):** Use `NSAnimationContext.runAnimationGroup` for popover height changes during row expand/collapse. If rapid toggling causes visual jitter, fall back to unanimated `contentSize` update.

**Milestone M3:** Full multi-account UI is functional; single-account layout is pixel-identical to v1.7; accordion expands/collapses correctly; stale accounts are clearly distinguished.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|-----------|---------------------|
| C1 | Create `UsageRow` with `.card`/`.inline` style parameter | Add `enum UsageRowStyle { case card, inline }` and `var style: UsageRowStyle = .card` to the existing `UsageRow` struct. `.card` = current behavior (padded, rounded-rect background). `.inline` = no card background, reduced vertical padding. Default to `.card` so existing single-account usage is unchanged. | M (3h) | A7 | Existing single-account view is pixel-identical to v1.7; inline variant renders without background card |
| C2 | Create `AccountHeader` component | `AccountHeader` shows: email (`.headline`), org (`.subheadline .secondary`, truncated), `LiveIndicator` or `StaleBadge`, highest utilization % (`.title3 .bold`, colored). Height: 56pt. Hover background: `NSColor.controlBackgroundColor`. | S (1h) | A7 | Component renders correctly in Xcode preview for both Live and Stale variants |
| C3 | Create `StaleBadge` component | `StaleBadge`: SF Symbol `clock` (`.caption2`) + `Text("Stale")` (`.caption`, `staleGray` = `Color(NSColor.secondaryLabelColor)`). Note: use `NSColor.secondaryLabelColor` (system-adaptive), **not** hardcoded `#8E8E93`, to satisfy accessibility contrast requirements on high-contrast mode. | S (0.5h) | — | Badge renders in both light and dark mode; passes Accessibility Inspector contrast check |
| C4 | Create `AccountDisclosureGroup` wrapping header + UsageRows | `AccountDisclosureGroup` uses `DisclosureGroup` with `AccountHeader` as the label and three `UsageRow(.inline)` items as the content. Stale variant: rows use `.secondary` color; `staleGray` bars; timestamp line "Updated [relative] ago" at bottom. Live variant: rows use full color; shows `isLoading` spinner. | M (3h) | C1, C2, C3 | Live account row expands/collapses; stale account row shows muted colors and timestamp; both work in Xcode preview |
| C5 | Create conditional layout logic: 1 account → single view, 2+ → accordion | In `UsageView` (or a new `ContentView`), add: `if accounts.count == 1 { existingSingleAccountView } else { AccountList(accounts) }`. The `AccountList` renders `AccountDisclosureGroup` per account inside a `ScrollView`. Default expansion state: current/live account expanded, stale accounts collapsed. | M (2h) | C4 | With 1 account: UI matches v1.7 exactly. With 2 accounts: accordion renders. No `if` branch entered incorrectly. |
| C6 | Add `ScrollView` with 480pt max height for multi-account | Wrap the account list in `ScrollView(.vertical, showsIndicators: true)` with `.frame(maxHeight: 380)` (480pt total minus ~100pt for header/footer). Scroll indicators visible when content exceeds max height. | S (1h) | C5 | With 5+ accounts, popover does not overflow screen; ScrollView becomes scrollable |
| C7 | Implement dynamic `NSPopover` contentSize management | In `AppDelegate`, observe `$accounts` to compute and set `popover.contentSize`. Formula: `headerHeight(~44) + updateBannerHeight(0 or ~44) + accountListHeight + footerHeight(~100)`. accountListHeight: `56pt × collapsedRows + (56 + usageDetailHeight) × expandedRows`. Single-account: always `NSSize(280, 320)`. Use `NSAnimationContext.runAnimationGroup` for row expand/collapse. See OQ-4 note above. | M (3h) | C5, C6 | Popover resizes smoothly when rows expand/collapse; does not overflow screen at any account count; single-account remains 280×320 |
| C8 | Update menubar title aggregation for worst-case across **live** accounts | Compute `worstCasePercentage` as `max(sessionPercentage, weeklyPercentage)` across accounts where `isCurrentAccount == true` only (stale accounts excluded — OQ-3 resolution). Apply same emoji thresholds (green <70%, orange 70-89%, red ≥90%). | S (1h) | A8 | Menubar shows live-account worst-case only; a stale 95% account does not force a persistent red indicator |
| C9 | Add SF Symbols replacing emoji indicators | Replace emoji status indicators in the menubar and UI with SF Symbol template images: `circle.fill` (liveGreen/warningOrange/criticalRed), `questionmark.circle` (unknown), `xmark.circle.fill` (error), `clock.arrow.circlepath` (loading). Use `.renderingMode(.template)`. | S (1h) | C8 | Menubar icon respects dark/light mode; no emoji visible in the menubar |
| C10 | Add accessibility labels to progress bars and status indicators | Add `.accessibilityLabel("\(title) usage")` and `.accessibilityValue("\(percentage) percent")` to each `UsageRow` `ZStack`. Add `accessibilityLabel` and `accessibilityHint` to `AccountHeader` per the Design spec's accessibility table. Add `LiveIndicator` label "Live account", `StaleBadge` label "Stale account". | S (1h) | C4 | Accessibility Inspector shows correct labels for all progress bars and account rows; VoiceOver reads meaningful descriptions |
| C11 | Implement three-layer staleness signal | Layer 1 (badge): `StaleBadge` on collapsed row (C3). Layer 2 (muted colors): all stale account content in `.secondary` / `staleGray` bars (C4). Layer 3 (timestamp): "Updated [relative] ago" line in expanded stale detail (C4). Add tooltip on stale utilization % hover: "Data from [absolute datetime]. This account is not currently active." | M (2h) | C3, C4 | All three layers are visible/readable; color is not the sole staleness signal; VoiceOver announces stale status |
| C12 | Add "Remove account" context menu to stale rows (moved from Phase D) | Right-click / secondary-click on a stale `AccountHeader` shows a context menu with "Remove account". Confirms removal, removes from UserDefaults, removes from `accounts`. This is a minimal implementation (no undo). | M (2h) | C4, C5 | Removing a stale account removes it from UserDefaults; it does not reappear on next poll unless that account re-authenticates |

**Phase C Critical Path:** C1 → C4 → C5 → C6 → C7

**Parallelizable:** C1–C3 can start in parallel (independent components). C8–C10 can run in parallel (independent UI polish). C11 depends on C3 and C4.

**Risk Mitigations in Phase C:**
- **R14 (NSPopover contentSize has no precedent):** C7 is the spike for this. Prototype the height calculation in isolation before integrating. If `NSAnimationContext` causes jitter (OQ-4), fall back to unanimated `contentSize` update.
- **R6 (Popover height overflow):** Handled by C6 (ScrollView + 480pt max).
- **R15 (SF Symbols availability):** `DisclosureGroup` available since macOS 11; all SF Symbols used are available since macOS 11. No version gate needed.
- **R11 (UsageView GeometryReader layout):** C1 is the surgical change to `UsageRow`; adding `.card`/`.inline` style preserves the existing GeometryReader layout in card mode.
- **OQ-1 (Remove account):** Addressed by C12 (moved from Phase D).

---

### Phase D: Polish & Edge Cases

**Goal:** Validate edge cases, verify correctness against a real second account, test battery impact, and prepare v1.8 release.

**Milestone M4:** All edge cases validated; release notes drafted; version bumped to v1.8.

| # | Task | Description | Size | Depends On | Acceptance Criteria |
|---|------|-------------|------|-----------|---------------------|
| D1 | Handle `KeychainError.notLoggedIn` with zero accounts gracefully | If `notLoggedIn` and `accounts` is empty: show existing "Not Signed In" error view (v1.7 pixel-identical). If `notLoggedIn` and `accounts` is non-empty: show "No active account" banner at top; render all accounts as stale; all rows expanded by default. | S (1h) | C5 | Both error states render correctly without crash; VoiceOver announces the banner |
| D2 | Validate boot delay behavior with multiple accounts | Confirm that the boot delay logic (pause if system uptime < 60s) works correctly when `accounts` has existing records. The app should render stale data from UserDefaults immediately and then update on first poll tick after delay. | S (1h) | D1 | On fast relaunch, app shows stale data immediately; updates within 60s of first poll |
| D3 | Validate token longevity after account switch (P3, OQ-2) | Using a real second account: switch accounts via `claude auth login`; observe how long the previous token remains valid (does it expire immediately, after minutes, after hours?). Update the staleness threshold logic if necessary. Document the empirical finding. **Requires P3 (second account).** | M (2h) | All prior phases; P3 | Token longevity documented; staleness display threshold validated against empirical data; no false-stale before ADR token expiry policy kicks in |
| D4 | Implement "Remove account" for live account (Phase D scope only if C12 shipped stale-only) | Note: "Remove account" for stale accounts was moved to C12. If during Phase C a live account removal use case is identified, implement it here. Otherwise verify C12 covers all needed removal flows. | M (2h) | C12 | User can remove any non-live account record; removal persists across relaunches |
| D5 | Verify wake-from-sleep handler with multi-account state | On wake from sleep, the existing wake notification handler fires a refresh. Verify this works correctly with `accounts` containing multiple entries; `isRefreshing` guard prevents pile-up if sleep-wake fires rapidly. | S (1h) | B2, B6 | Wake from sleep triggers one refresh; multiple rapid wakes do not queue multiple refreshes |
| D6 | Battery impact testing of 60-second polling | Run Instruments Energy Log with 60-second polling active. Compare vs. 120-second baseline. Document CPU and energy impact. Consider implementing the "pause polling when popover not visible for 5+ minutes" optimization if impact is unacceptable. | S (1h) | B3 | Energy impact is documented; if high, implement popover-visibility-gated polling pause |
| D7 | Manual regression test suite for all flows | Execute each of the 6 E2E scenarios: (1) first launch single account, (2) account switch detection, (3) accordion expand/collapse, (4) stale account awareness, (5) no active account with/without UserDefaults records, (6) remove account. Also run 8 unit test scenarios: AccountRecord encode/decode, token comparison, UserDefaults persistence (4 unit), full refresh cycle with mock data (4 integration). | M (2h) | All phases | All 6 E2E scenarios pass; all 8 unit/integration tests pass or explicitly documented as manual-only |
| D8 | Update version to v1.8, prepare release notes | Bump `CFBundleShortVersionString` to `1.8`. Write release notes covering: (a) multi-account support with account history semantics (not live multi-account), (b) stale indicator explanation, (c) account accumulation behavior and future auto-prune notice (OQ-1 communication), (d) single-account pixel-identical guarantee. | S (1h) | D7 | Version string shows 1.8 in About panel and update check; release notes accurately describe the feature |

**Parallelizable in Phase D:** D1–D2 can be done in parallel. D5–D6 can be done in parallel. D3 requires P3 (second account) and all prior phases.

---

## Dependency Graph

```
Phase A (Token Capture & Storage)
─────────────────────────────────
A1 ──┐
A2 ──┤──► A7 ──► A8 ──► [M1]
     │
A3 ──┤
A4 ──┤──► A5 ──► A6 ──► A7
     │
(A1-A2 parallel with A3-A4)

Phase B (Multi-Account Refresh)
────────────────────────────────
[Prerequisite: B-pre (fix retry bug)]
B-pre ──► B1 ──► B4 ──► B5 ──► B6 ──► [M2]
          B2 ──► B3

Phase C (Multi-Account UI)
───────────────────────────
[Depends on A7, A8 from Phase A; B5 from Phase B]
C1 ──┐
C2 ──┤──► C4 ──► C5 ──► C6 ──► C7 ──► [M3]
C3 ──┘    │
          └──► C11
C8 ──┐
C9 ──┤  (parallel with C1-C7 where unblocked)
C10 ─┘
C12 (depends on C4, C5)

Phase D (Polish & Edge Cases)
──────────────────────────────
[Depends on all prior phases]
D1 ──► D2
D3 (requires P3: second account)
D5 ──┐
D6 ──┘ (parallel)
D7 ──► D8 ──► [M4]

Cross-Phase Dependencies:
Phase B depends on: A3 (async token func), A7 (accounts array)
Phase C depends on: A7 (data model), A8 (AppDelegate), B5 (error isolation)
Phase D depends on: all prior phases
```

---

## Critical Path

```
A3 → A4 → A5 → A6 → A7 → A8
                          ↓
                    B-pre → B1 → B4 → B5 → B6
                                           ↓
                                 C1 → C4 → C5 → C6 → C7
                                                       ↓
                                            D3 → D7 → D8
```

Total critical path tasks: 17 tasks
Total critical path estimated hours (realistic): ~28h

The single highest-risk point on the critical path is **A7** (atomic interface change — all 5 `@Published` vars replaced simultaneously). The second highest risk is **B1** (nonisolated Process/Pipe wrapper). Both must be fully resolved before proceeding to the next phase.

---

## Milestones

| Milestone | Reached After | Verification |
|-----------|--------------|-------------|
| M1 | A8 complete | App compiles and runs; single-account UI works; token-change detection active; `@Published var accounts` drives the UI |
| M2 | B6 complete | Multi-account refresh working; Process off main thread (Instruments confirms); isRefreshing guard active; timer at 60s |
| M3 | C7 complete (all of Phase C) | Full multi-account accordion UI functional; single-account layout pixel-identical to v1.7; staleness signals all three layers working |
| M4 | D8 complete | All edge cases validated; version = 1.8; release notes written; ready to ship |

---

## Risk Register

| # | Severity | Risk | Phase Affected | Mitigation |
|---|----------|------|---------------|------------|
| R1 | HIGH | "Multi-account" is account history, not live monitoring — user expectation mismatch | All | Clear "Stale" badge + muted colors + timestamp (C3, C11); explicit wording in release notes (D8) |
| R2 | HIGH | `Process()` on `@MainActor` blocks main thread | B | B1 explicitly moves Process/Pipe off main actor using `nonisolated` + `terminationHandler`; verify with Instruments before proceeding to B4 |
| R3 | MEDIUM | Profile API rate limiting if token-comparison is buggy (always fires) | A | A4 unit tests token comparison; A5 adds defensive logging; R3 is caught in M1 validation |
| R4 | MEDIUM | Timer overlap without `isRefreshing` guard | B | B2 adds guard; B3 (timer reduction) is blocked on B2 being merged |
| R5 | MEDIUM | No automated tests in codebase | All | Minimum viable: unit tests for `AccountRecord` Codable, token comparison, UserDefaults persistence (D7). Manual E2E for remaining flows. Test infra overhead acknowledged. |
| R6 | LOW | Popover height overflow with many accounts | C | C6 adds ScrollView with 480pt max height |
| R7 | HIGH | `getClaudeCodeToken` is synchronous — must be async before TaskGroup | B | A3 creates the async wrapper; B1 makes it `nonisolated`; B4 (TaskGroup) is blocked on B1 |
| R8 | MEDIUM | Shared `Pipe` instance not Sendable | B | B1 enforces local instantiation within `nonisolated` scope; compiler will reject any cross-actor Pipe reference |
| R9 | HIGH | Atomic interface change — replacing 5 `@Published` vars breaks all consumers simultaneously | A | A7 + A8 done in a single editing session without intermediate compile; `UsageView` temporarily stubbed if needed during transition |
| R10 | MEDIUM | `AppDelegate` Combine subscriber chain must be rewritten atomically | A | A8 lists all subscribers before touching code; one-shot rewrite; compile confirms no missed references |
| R11 | MEDIUM | `UsageView` GeometryReader depends on specific `@Published` var bindings | A, C | C1 adds `.card`/`.inline` style without touching GeometryReader logic; Phase A does not modify `UsageView` |
| R12 | LOW | UserDefaults sync timing if app crashes during write | A | UserDefaults write is a single `JSONEncoder` operation; partial write risk is low; no transaction needed at this scale |
| R13 | LOW | Email as canonical key — format edge cases | A | Email comes directly from `/api/oauth/profile` response; normalized by the API; no client-side normalization needed |
| R14 | MEDIUM | `NSPopover` contentSize management has no precedent in codebase | C | C7 is the explicit spike; prototype height calculation before integration; OQ-4 fallback strategy defined |
| R15 | LOW | SF Symbols availability across macOS versions | C | All SF Symbols used are available on macOS 11+; deployment target is macOS 13+; no version gate needed |
| R16 | MEDIUM | Profile API called every refresh without token-comparison gate (pre-existing) | A | Fixed by A5 |
| R17 | MEDIUM | Recursive retry with `defer` bug in `refreshWithRetry` (pre-existing) | B | Fixed by B-pre before Phase B builds on the refresh path |
| R18 | LOW | Boot delay interaction with account detection timing | D | D2 validates; app shows stale UserDefaults data immediately; first poll updates after delay |

---

## Testing Strategy

### Unit Tests (~8 tests, new test file required)

Since the codebase has no test infrastructure, a minimal `XCTest` target must be added before writing tests (overhead ~1h, included in D7).

| Test | Subject | Validates |
|------|---------|-----------|
| T1 | `AccountRecord` Codable round-trip | Encoding and decoding produces identical struct |
| T2 | `AccountRecord` Codable with nil optional fields | Nil optionals decode correctly |
| T3 | Token comparison: same token → no profile call | `lastSeenToken` equality check works |
| T4 | Token comparison: new token → profile call fires | Token change detection triggers API call |
| T5 | UserDefaults persistence: save and reload | `[AccountRecord]` survives write-read cycle |
| T6 | UserDefaults persistence: empty array | Fresh install returns empty array, not crash |
| T7 | `AccountRecord` deduplication: re-auth same email | Existing record updated, not duplicated |
| T8 | Worst-case utilization: live accounts only | Stale accounts excluded from menubar calculation (OQ-3 resolution) |

### Integration Tests (~4 tests)

| Test | Scenario | Validates |
|------|---------|-----------|
| I1 | Full refresh cycle with mock keychain data (single account) | End-to-end: token read → profile → usage → `accounts` published |
| I2 | Token change triggers profile call and new `AccountRecord` | Account switch detection works end-to-end |
| I3 | Per-account error isolation: one account fails, others succeed | `TaskGroup` error isolation (B5) |
| I4 | `isRefreshing` guard: concurrent `refresh()` calls | Second call returns immediately |

### Manual E2E Scenarios (~6 scenarios, requires P3 for scenarios 2–4)

| Scenario | Steps | Pass Criteria |
|----------|-------|---------------|
| E1 | First launch (single account) after update from v1.7 | UI pixel-identical to v1.7; no visual change |
| E2 | Account switch detection (requires P3) | New account appears within 60s; previous account marked stale |
| E3 | Accordion expand/collapse | Each row expands independently; popover resizes smoothly |
| E4 | Stale account awareness (requires P3) | All three staleness layers visible; timestamp accurate |
| E5 | No active account (logout): zero accounts in UserDefaults | "Not Signed In" view identical to v1.7 |
| E6 | No active account (logout): accounts exist in UserDefaults | "No active account" banner; stale rows displayed |

### Rollback Validation

After each phase, confirm rollback is possible before proceeding to the next phase.

---

## Rollback Strategy

| Phase | Rollback Action | UserDefaults Cleanup |
|-------|----------------|---------------------|
| Phase A | Revert Phase A PR; restore 5 `@Published` vars | Delete `UserDefaults.standard.removeObject(forKey: "claudeusage.accounts")` — add a one-time migration guard keyed on bundle version |
| Phase B | Revert Phase B PR; restore original `getClaudeCodeToken` synchronous implementation | No UserDefaults cleanup needed; B changes are in-memory only |
| Phase C | Revert Phase C PR; original `UsageView` is restored | No UserDefaults cleanup needed |
| Phase D | Individual cherry-pick reverts; each Phase D task is independent | No UserDefaults cleanup; D changes are all additive |

Rollback is clean in all phases because: (a) UserDefaults is additive and reversible, (b) each phase is a separate PR, (c) the `security` CLI keychain interaction is unchanged from v1.7.

---

## Open Questions

| # | Question | Status | Decision / Recommendation |
|---|---------|--------|--------------------------|
| OQ-1 | Account removal UI in v1.8 | **Resolved** | Move "Remove account" from Phase D into Phase C (task C12). Stale account accumulation with no pruning path is a first-launch UX problem, not a polish item. |
| OQ-2 | Token longevity after account switch | **Open — validate in D3** | Must be empirically tested with P3 (second account) before shipping. Staleness threshold logic may need adjustment. |
| OQ-3 | Stale accounts in worst-case menubar calculation | **Resolved** | Exclude stale accounts from worst-case calculation (C8 implements this). Stale historical high usage should not produce a persistent red menubar indicator. |
| OQ-4 | NSPopover contentSize animation strategy | **Open — resolve in C7 spike** | Default to `NSAnimationContext.runAnimationGroup`. If rapid toggling causes visual jitter, fall back to unanimated `contentSize` update. Decide during C7 implementation. |
| OQ-5 | Multi-account layout deactivation when only one non-stale account exists | **Deferred to v2** | Once in multi-account mode (two+ `AccountRecord` entries ever seen), stay in multi-account mode. Deactivation logic depends on account removal (OQ-1/C12) and token longevity (OQ-2). Too complex for v1.8. |

---

## Affected Files

| File | Changes |
|------|---------|
| `ClaudeUsage/AccountModels.swift` | **New file.** `AccountRecord` and `AccountUsage` types (A1). |
| `ClaudeUsage/UsageManager.swift` | Add `lastSeenToken`, `isRefreshing`. Replace 5 `@Published` vars with `accounts`. Add UserDefaults persistence. Add `nonisolated` keychain wrapper. Add 60s polling with token comparison. Add TaskGroup refresh. (A2–A7, B-pre–B6) |
| `ClaudeUsage/ClaudeUsageApp.swift` | Rewrite Combine subscribers for `$accounts`. Update `updateStatusItem()` for worst-case aggregation. Add popover `contentSize` management. (A8, C7, C8) |
| `ClaudeUsage/UsageView.swift` | Add `.card`/`.inline` UsageRow style. Add conditional single/multi layout. Add `AccountDisclosureGroup`, `AccountHeader`, `StaleBadge`, `LiveIndicator`, `NoActiveAccountBanner`. Add accessibility labels. (C1–C12) |

---

## Success Metrics (from ADR)

- A user who switches Claude Code accounts sees the new account appear in the UI within 60 seconds.
- The previous account's last-known usage is preserved and marked stale.
- `/api/oauth/profile` is called at most 5 times per day under normal use (no account switching).
- The main thread is not blocked during keychain reads (verified with Instruments Time Profiler).
- Single-account users report no visible change in behavior or appearance.
- No reports of the ACL keychain permission dialog reappearing.

---

## Getting Started

A developer reading this plan for the first time should:

1. Read `docs/adr/ADR-001-multi-account-support.md` (architecture decisions and rationale).
2. Read `docs/designs/DESIGN-multi-account-support-2026-02-23.md` (UI/UX specification and component details).
3. Read the three source files: `UsageManager.swift`, `ClaudeUsageApp.swift`, `UsageView.swift` (~833 lines total).
4. Verify prerequisites P1–P10. Arrange P3 (second account) before Phase B ends.
5. Fix B-pre (recursive retry bug) first — this is a pre-existing defect that must not be built upon.
6. Start with A1–A3 in parallel, then proceed along the critical path.
7. Gate on milestones: do not begin Phase B until M1 is reached; do not begin Phase C until M2 is reached.
