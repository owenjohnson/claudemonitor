# ADR-001: Add Multi-Account Support with Keychain Polling and Account Tracking

**Date:** 2026-02-23
**Status:** Proposed
**Deciders:** Architecture team (adr-architect, tech-analyst, adr-writer)

---

## Context

### Current State

ClaudeUsage is a macOS menubar app (~833 lines across 3 Swift files) that monitors Claude Code API usage for a single account. `UsageManager` reads one keychain entry via the `security` CLI, calls `/api/oauth/usage` and `/api/oauth/profile`, and publishes a single `@Published var usage: UsageData?`. A 120-second `Timer` drives periodic refresh. The entire class is `@MainActor`.

### Business Driver

Users who work across multiple Claude Code accounts (personal + work, multiple orgs) want to see usage for all accounts without manually switching contexts. This requires tracking usage history across account switches.

### The Critical Constraint: One Active Token at a Time

Claude Code stores exactly **one** credential in the macOS keychain under `Claude Code-credentials` (with `Claude Code` as a fallback). When a user authenticates as a different account, the previous credential is **overwritten**. There is no mechanism to hold credentials for multiple accounts simultaneously.

Consequence: "multi-account support" cannot mean concurrent live monitoring of N accounts. It means:

1. Detecting when the active account changes (token rotation).
2. Persisting metadata about previously-seen accounts.
3. Showing the last-known usage for inactive accounts alongside live data for the current account.
4. Marking inactive accounts as stale when their tokens are expired or absent.

This distinction is the single most important architectural fact in this feature.

### Additional Constraints

- No keychain change notification API exists on macOS. Detection must be polling-based.
- The app must not cache tokens in its own keychain items. Doing so creates a stale second source of truth and risks the app presenting an expired token as valid.
- The `security` CLI (not `SecItemCopyMatching`) must be used to read Claude Code's keychain entry, as established in v1.7. Using `SecItemCopyMatching` directly triggers an ACL security dialog on first access.
- No new Swift package dependencies. The app currently has zero runtime dependencies.
- The codebase has no automated tests. All refactoring carries regression risk.

---

## Decision

### D1: Storage Strategy

**UserDefaults for account metadata. No app-owned keychain token cache.**

Account metadata (`AccountRecord`, defined in D2) is stored in `UserDefaults` under a namespaced key. This covers display name, email, organization, subscription type, token expiry metadata, and timestamps. At most ~10 records are expected; UserDefaults is appropriate at this scale.

The app **never** writes tokens into its own keychain items. Every refresh reads the live token from Claude Code's keychain via the `security` CLI. This is the only way to guarantee the app always sees the current active credential.

### D2: Data Model

Two new types replace the current `UsageData`-centric model:

**`AccountRecord` (Codable, stored in UserDefaults):**

```swift
struct AccountRecord: Codable, Identifiable {
    let email: String          // canonical key; from /api/oauth/profile
    var displayName: String?
    var organizationName: String?
    var subscriptionType: String?
    var tokenExpiresAt: Date?
    var lastTokenCapturedAt: Date
    var addedAt: Date
    var id: String { email }
}
```

**`AccountUsage` (in-memory view model, not persisted):**

```swift
struct AccountUsage: Identifiable {
    let account: AccountRecord
    var usage: UsageData?
    var error: String?
    var isLoading: Bool
    var lastUpdated: Date?
    var isCurrentAccount: Bool  // true if this account holds the live keychain token
    var id: String { account.email }
}
```

**`UsageManager` published interface change:**

```swift
// Before:
@Published var usage: UsageData?
@Published var error: String?
@Published var isLoading: Bool
@Published var lastUpdated: Date?
@Published var displayName: String?

// After:
@Published var accounts: [AccountUsage]   // replaces all five above
@Published var updateAvailable: String?   // unchanged
```

All `AppDelegate` Combine subscribers and `UsageView`'s view contract must be updated atomically with this change.

### D3: Account Detection and Identity

**60-second polling via `security` CLI. Token-change comparison gates profile API calls. Email is the canonical account key.**

The polling loop runs every 60 seconds (down from the current 120s for general refresh). On each tick:

1. Read the raw JSON from the `security` CLI.
2. Extract the `accessToken` string.
3. Compare it byte-for-byte against `lastSeenToken` (held in memory, not persisted).
4. **If the token is unchanged:** skip the profile API call; use the cached `AccountRecord` from UserDefaults to match the account.
5. **If the token has changed or is absent:** call `/api/oauth/profile` to get the email, display name, and org. Look up or create an `AccountRecord`. Update `lastSeenToken`.

Email from `/api/oauth/profile` is the canonical identity key for matching accounts across token rotations. Display name and org are supplementary.

This reduces profile API calls from ~1,440/day (once per 60s poll) to ~1-5/day (only on actual account switches).

There is no user-facing confirmation dialog when an account switch is detected. Detection is silent and automatic.

### D4: Refresh Architecture

**Single 60-second timer. `Process()` moved off `@MainActor`. `TaskGroup` for concurrent per-account fetches. `isRefreshing` guard prevents overlap.**

Current problems:
- The 120s `Timer` fires refresh on the main thread.
- `getClaudeCodeToken()` calls `Process()` and `process.waitUntilExit()` while `@MainActor` is held, blocking the main thread.
- There is no guard against overlapping timer fires (e.g., if a refresh takes >120s during retries on a slow network).

Changes:
- Reduce timer interval from 120s to 60s to support account-change detection.
- Extract `Process`/`Pipe` execution into a `nonisolated` async function (or `Task.detached`) so it does not block the main thread.
- Add `private var isRefreshing = false` guard at the start of `refresh()`. If `isRefreshing` is true, return immediately.
- Use `async let` or `TaskGroup` to fetch usage for all known accounts concurrently. Each account's fetch is isolated; one account's network error does not prevent others from completing.

Note: `Process` and `Pipe` are not `Sendable`. The `nonisolated` wrapper must instantiate them entirely within its scope and return only the `String` result to the caller.

### D5: UI Strategy

**Conditional layout. Single-account view is pixel-identical to current (280x320). Multi-account view uses `DisclosureGroup` accordion with `ScrollView`.**

Single account (only one `AccountRecord` in UserDefaults): `UsageView` renders exactly as it does today. No visual change for existing single-account users.

Multiple accounts:
- Popover width remains 280pt.
- Each account gets a `DisclosureGroup` row (56pt collapsed height) showing account email, current/stale indicator, and highest utilization percentage.
- Expanded row reveals the three `UsageRow` gauges (session, weekly, sonnet-only).
- A `ScrollView` wraps the accordion with a 480pt max height to prevent the popover from overflowing the screen.
- The menubar button title shows the worst-case (highest) utilization across all accounts, using the same emoji thresholds (green/orange/red).
- Stale accounts (token expired) display a muted "stale" badge and do not show a loading spinner.

### D6: Token Longevity Policy

**Never attempt OAuth token refresh. Mark expired tokens as stale. Auto-prune accounts after 30 days of expiry (deferred to v2).**

The app must not call any OAuth token refresh endpoint. Doing so risks invalidating Claude Code's own session, because Claude Code manages the refresh lifecycle independently.

When a token's `expiresAt` is in the past and the token is no longer the live keychain entry:
- Set `AccountRecord.tokenExpiresAt` to the known expiry.
- The corresponding `AccountUsage.isCurrentAccount` is `false`.
- Display a "stale" indicator in the accordion header.
- Do not attempt to fetch live usage for stale accounts.

Auto-pruning (removing `AccountRecord` entries older than 30 days past expiry) is deferred to v2. The v1 implementation retains all records indefinitely.

The longevity of a token after an account switch is not empirically known. This must be validated before shipping to determine whether the "stale" threshold is appropriate.

---

## Alternatives Considered

### D1 Alternatives: Storage

**UserDefaults + SecItem API token cache:** Caching tokens in app-owned `SecItem` entries solves nothing. The cached token becomes stale the moment the user switches accounts in Claude Code. The app would then have a false sense of having a valid token for a second account. Rejected: stale second source of truth.

**CoreData / SwiftData:** Appropriate for relational data at scale. For fewer than 10 `Codable` records with no relationships and no querying requirements, this is massive overkill. Rejected: disproportionate complexity.

**File-based JSON in Application Support:** Functionally equivalent to UserDefaults for this use case but requires manual file path management, atomic write discipline, and error handling for I/O failures. No advantages at this scale. Rejected: unnecessary complexity.

**SecItemCopyMatching (Security framework) for reading Claude Code's keychain:** This was the original approach before v1.7. It triggers an ACL dialog on first access because the app is not in the keychain item's trusted application list. The `security` CLI is already in that list. Rejected: reintroduces the exact UX problem v1.7 solved.

### D3 Alternatives: Account Detection

**Push-based keychain notifications:** macOS does not expose keychain change notifications to third-party apps. Not available.

**NSDistributedNotificationCenter observation for Claude Code events:** Claude Code does not publish distributed notifications. Not available.

**Per-refresh profile API call (no token comparison):** Calls `/api/oauth/profile` every 60 seconds unconditionally. Results in ~1,440 profile API calls/day. Risk of rate limiting. Rejected: wasteful and fragile.

### D4 Alternatives: Refresh Architecture

**Keep `@MainActor` on `UsageManager` and use `DispatchQueue.global()` workaround:** Calling `process.waitUntilExit()` from a `DispatchQueue.global()` hop inside an `@MainActor` function still risks priority inversion and is architecturally inconsistent. Rejected: fragile.

**Separate `ObservableObject` per account:** Each `AccountUsage` as its own `ObservableObject` published through the parent. Adds complexity for no UI benefit at this scale. Rejected: premature abstraction.

### D5 Alternatives: UI Strategy

**Tab bar per account:** Requires permanent screen real estate. A 280pt-wide tab bar for 2-5 accounts is cramped and doesn't scale. Rejected: poor space efficiency.

**Flat list (no accordion):** Shows all accounts expanded simultaneously. With 3+ accounts each showing 3 usage rows, the popover overflows the screen. Rejected: does not scale.

---

## Consequences

### Positive

- Users with multiple accounts can see usage history for each without manual switching.
- Token-comparison caching reduces profile API calls by ~99% compared to polling every refresh.
- Moving `Process()` off `@MainActor` eliminates main thread blocking, improving UI responsiveness during refresh.
- `isRefreshing` guard prevents cascading refresh backlog on slow networks.
- Single-account users see zero visual or behavioral change.
- Zero new dependencies introduced.

### Negative

- `UsageManager`'s published interface is a breaking change. All consumers (`AppDelegate` subscribers, `UsageView`) must be updated atomically in one PR.
- The feature does not provide simultaneous live data for all accounts; inactive accounts show last-known data with a stale indicator. This must be communicated clearly in release notes.
- `nonisolated` async wrappers around `Process`/`Pipe` require careful scoping to avoid Swift concurrency Sendable violations, which the compiler will enforce at warning or error level.
- UserDefaults is not encrypted. `AccountRecord` contains email addresses and organization names. These are low-sensitivity but not zero-sensitivity. Acceptable given the app's scope.

### Risks

**R1 (HIGH): "Multi-account" is account history, not live multi-account monitoring.** Only one account has a valid live token at any time. If users expect to see real-time usage for a second account while logged in as the first, the feature will disappoint. Mitigation: clear "stale" labeling in UI; explicit wording in release notes.

**R2 (HIGH): `Process()` on `@MainActor` blocks the main thread.** The existing `getClaudeCodeToken()` calls `process.waitUntilExit()` while `@MainActor` is held. This must be fixed as part of Phase B. Until fixed, adding `TaskGroup` concurrency without moving off the main actor would make the blocking worse. Mitigation: Phase B must fix the actor isolation before enabling concurrent account fetches.

**R3 (MEDIUM): Profile API rate limiting without token-comparison guard.** If the token-comparison logic has a bug (e.g., always treats tokens as changed), the app will call `/api/oauth/profile` every 60 seconds. Mitigation: unit test the token-comparison logic explicitly; add defensive logging.

**R4 (MEDIUM): Timer overlap without `isRefreshing` guard.** A refresh cycle that takes longer than 60 seconds (retries on slow network) will overlap with the next timer fire. Without the guard, this creates a queue of concurrent refreshes. Mitigation: implement `isRefreshing` guard before reducing timer interval to 60 seconds.

**R5 (MEDIUM): No automated tests.** The codebase has zero tests. The `UsageManager` interface change (D2) and actor isolation change (D4) touch every code path. Manual testing is the only safety net. Mitigation: test the full account-switching flow manually against a real second account before shipping. Consider adding at minimum unit tests for `AccountRecord` encoding/decoding and token-comparison logic.

**R6 (LOW): Popover height overflow with many accounts.** The 480pt `ScrollView` max height is sufficient for ~8 accounts. If a user has more, the scroll view handles it correctly. The menubar button title aggregation (worst-case utilization) remains unaffected by account count.

---

## Implementation

### Affected Components

| File | Change |
|------|--------|
| `UsageManager.swift` | Add `AccountRecord`, `AccountUsage`. Replace 5 published vars with `accounts: [AccountUsage]`. Add `lastSeenToken` in-memory state. Add 60s poll loop with token-comparison. Move `Process` call off `@MainActor`. Add `isRefreshing` guard. Persist/load `AccountRecord` via UserDefaults. |
| `ClaudeUsageApp.swift` (`AppDelegate`) | Update Combine subscribers from `$usage`/`$error` to `$accounts`. Update `updateStatusItem()` to aggregate worst-case utilization across all accounts. |
| `UsageView.swift` | Add conditional layout: single-account (unchanged) vs. multi-account (`DisclosureGroup` accordion + `ScrollView`). Add stale account indicator. |

No new files are strictly required, though extracting `AccountRecord` and `AccountUsage` into a separate `AccountModels.swift` is recommended for clarity.

### Migration Strategy

UserDefaults starts empty on first launch after update. The polling loop will detect the current token on the first 60s tick, call `/api/oauth/profile`, and create the first `AccountRecord`. There is no migration of existing data; the current `@Published var usage` state is transient and not persisted.

**Phase A: Token capture and storage**
- Add `AccountRecord` and `AccountUsage` types.
- Implement 60s polling loop with token-comparison logic.
- Persist/load `AccountRecord` via UserDefaults.
- Call `/api/oauth/profile` only on token change.
- Publish `accounts: [AccountUsage]` with a single entry (the current account).
- Update `AppDelegate` subscribers.

**Phase B: Multi-account refresh**
- Move `Process`/`Pipe` execution off `@MainActor` into a `nonisolated` async helper.
- Add `isRefreshing` guard.
- Implement `TaskGroup` for concurrent per-account usage fetches.
- Add per-account error isolation.

**Phase C: Multi-account UI**
- Add conditional layout in `UsageView`.
- Implement `DisclosureGroup` accordion with `ScrollView`.
- Add stale account indicator.
- Update menubar button title aggregation.

**Phase D: Polish and edge cases**
- Validate boot delay behavior with multiple accounts.
- Handle `KeychainError.notLoggedIn` gracefully when no account is active.
- Add "Remove account" action for manually pruning stale records.
- Validate token longevity empirically after account switch.

### Rollback Plan

Rollback is a revert of the Phase A-D PRs. UserDefaults keys written by this feature can be deleted on rollback via a one-time migration guard keyed on bundle version. The `security` CLI interaction is unchanged from v1.7; keychain behavior is unaffected by rollback.

### Success Metrics

- A user who switches Claude Code accounts sees the new account appear in the UI within 60 seconds.
- The previous account's last-known usage is preserved and marked stale.
- `/api/oauth/profile` is called at most 5 times per day under normal use (no account switching).
- The main thread is not blocked during keychain reads (verify with Instruments Time Profiler).
- Single-account users report no visible change in behavior or appearance.
- No reports of the ACL keychain permission dialog reappearing.

---

## References

- v1.7 commit `8f5310a` — Security CLI keychain access, removal of first-launch dialog (established `security` CLI approach)
- `ClaudeUsage/UsageManager.swift` — Current keychain read implementation (`getClaudeCodeToken`, `getAccessTokenFromAlternateKeychain`)
- `ClaudeUsage/ClaudeUsageApp.swift` — Current timer and Combine subscriber setup
- Anthropic OAuth API: `GET https://api.anthropic.com/api/oauth/profile` (returns `account.email`, `account.display_name`, `organization`)
- Anthropic OAuth API: `GET https://api.anthropic.com/api/oauth/usage` (returns `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`)
- `docs/SCOPE-multi-account-support.md` — Feature scope document
