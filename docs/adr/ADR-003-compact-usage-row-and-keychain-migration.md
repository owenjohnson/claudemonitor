# ADR-003: Compact UsageRow layout, fix percentage rounding, update height constants, and migrate keychain access to SecItemCopyMatching

**Date:** 2026-03-02
**Status:** Proposed
**Deciders:** Architecture team (adr-architect, tech-analyst, adr-writer)

---

## Context

### Current State

The app uses a card-style `UsageRow` (~70pt height per row) implemented in `ClaudeMonitor/UsageRow.swift` (84 lines). Each row renders: a title (`Text`, `.subheadline`), a subtitle (`Text`, `.caption`), a `GeometryReader`-based progress bar (8pt tall), and a reset timer (`Text`, `.caption`). A `UsageRowStyle` enum (`.card` / `.inline`) controls horizontal padding and background fill.

There are 9 call sites across the codebase:
- 3 in `UsageView.swift` (`usageContent()`, card style, single-account mode)
- 3 in `LiveAccountDetail` in `AccountDetail.swift` (inline style)
- 3 in `StaleAccountDetail` in `AccountDetail.swift` (inline style)

In multi-account mode, an expanded account row contains a `VStack` with 3 `UsageRow` instances plus 8pt spacing, yielding approximately 180pt of detail content. Combined with the 48pt header (from ADR-002 D2), this gives `expandedRowHeight = 228pt`. This constant is hardcoded in two places: `AccountList.computedScrollHeight` (`AccountList.swift:52`) and `AppDelegate.computePopoverHeight()` (`ClaudeMonitorApp.swift:164`).

`UsageData.sessionPercentage`, `weeklyPercentage`, and `sonnetPercentage` are computed as `Int(value)` (floor truncation). This means 89.7% is displayed as 89% and is compared against thresholds as 89, even though the user has crossed 89.5%.

The app reads Claude Code's keychain entry by spawning a `Process` that executes `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. This approach was established in v1.7 (ADR-001) to avoid an ACL security dialog that `SecItemCopyMatching` triggered, because the app was not in the keychain item's trusted application list. The approach requires a `nonisolated` async wrapper with `withCheckedThrowingContinuation` and a `terminationHandler` closure to avoid blocking `@MainActor`, and it creates a `Process` plus two `Pipe` objects per keychain read.

### Business Drivers

1. **Row density.** The ~70pt `UsageRow` consumes ~180pt of expanded account detail space per account. Reducing to 20pt per row saves ~120pt per expanded account, directly improving how many accounts fit within the 480pt popover cap established in ADR-001 D5 and ADR-002 RF1.

2. **Percentage rounding correctness.** `Int(value)` truncates fractionally. At a 70% threshold boundary (the orange/red transition in `Color.forUtilization()` in `SharedStyles.swift`), a true utilization of 89.7 displays and compares as 89% (green-eligible), not 90% (red). This is a correctness bug: displayed values systematically understate utilization, and threshold crossings occur 0-1% later than the underlying data warrants.

3. **Keychain access overhead.** The `security` CLI approach creates a subprocess per keychain read and requires `nonisolated` async wrappers for Swift concurrency safety. Native `SecItemCopyMatching` is synchronous, requires no subprocess, and is Sendable-safe without wrappers. The original ACL concern that motivated the CLI approach is a one-time dialog that the user can dismiss with "Always Allow."

### Constraint Changes from ADR-002

- **ADR-002's single-account pixel-identity promise is superseded.** ADR-002 D2 states: "Single-account view (`manager.accounts.count <= 1`) must remain pixel-identical to v1.7." This constraint is explicitly removed by this ADR. Compact rows apply to all 9 call sites — both single-account and multi-account modes. The comment at `UsageView.swift:55` ("pixel-identical to v1.7") and `UsageView.swift:75` ("Single-account content — pixel-identical to v1.7") become inaccurate after D1 is implemented; they should be updated.

- **Zero-dependency constraint is removed.** ADR-001 and ADR-002 both require zero new Swift package dependencies. This constraint is removed. Swift packages are now permitted if they provide clear benefit. No new packages are introduced in this ADR's scope, but the constraint is no longer an architectural invariant.

### Inherited Constraints (Unchanged)

- No changes to `AccountRecord` or `AccountUsage` data model fields.
- No changes to persistence (UserDefaults) or refresh architecture (60s polling, `TaskGroup`).
- Popover width remains 280pt; max popover height remains capped at 480pt.
- The `security` CLI service names ("Claude Code-credentials", "Claude Code") are retained as string constants in `getClaudeCodeToken()` — only the read mechanism changes.

---

## Decision

### D1: 20pt CompactUsageRow Replaces Card-Style UsageRow at All Call Sites

**Replace the ~70pt card-style `UsageRow` with a 20pt fixed-height single-line `HStack`. Apply to all 9 call sites in both single-account and multi-account modes. Remove `UsageRowStyle`, the `subtitle` parameter, the progress bar, and the card background.**

The new layout is a single `HStack` with `.caption` font throughout:

```swift
struct UsageRow: View {
    let title: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.primary)

            if percentage >= 70, let resetsAt = resetsAt {
                Text(formatTimeRemaining(resetsAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(percentage)%")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .frame(height: 20)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue("\(percentage) percent")
    }
}
```

What is removed:
- **Progress bar** — the entire `GeometryReader` block with the `RoundedRectangle` fill. The percentage text renders the same information in less space.
- **Subtitle** — the `.caption` secondary text ("5-hour window", "7-day window", "Model-specific"). Removed from the `UsageRow` init; call sites in `AccountDetail.swift` and `UsageView.swift` drop the parameter.
- **Card background** — `Color(NSColor.controlBackgroundColor)` fill and `cornerRadius(8)`. Multi-account inline rows never had it; single-account card rows lose it.
- **`UsageRowStyle` enum** — no longer needed; there is one compact style everywhere. The enum at `UsageRow.swift:4` is removed. The `style` parameter is removed from the init. All 9 call sites drop `style: .inline` or `style: .card`.

The reset timer is shown conditionally: only when `percentage >= 70`. When `percentage >= 70`, the row is already rendering in orange or red via `Color.forUtilization()` (`SharedStyles.swift:9`), so the timer provides contextually appropriate urgency information. Below 70% (green), the reset time is secondary information that the user does not urgently need. Above 70%, the time remaining is decision-relevant — the user may want to know how soon the constraint resets.

The `formatTimeRemaining()` function is retained as a private method inside `UsageRow`. No behavior change.

**Accessibility.** The current progress bar carries `.accessibilityLabel("\(title) usage")` and `.accessibilityValue("\(percentage) percent")` at `UsageRow.swift:46-47`. These semantics are preserved on the `HStack` itself via `.accessibilityElement(children: .ignore)` with equivalent label and value annotations. VoiceOver will announce, e.g., "Session usage, 72 percent."

**Row height sub-alternative: 24pt.** The tech analyst noted that 20pt may feel cramped at `.caption` (12pt) font size with standard line height (~14pt). 24pt provides 4pt of vertical breathing room (matching the 4pt padding in ADR-002 D2's `AccountHeader`). The choice between 20pt and 24pt does not affect the architecture; it is a visual tuning decision. The ADR specifies 20pt as the target; implementors should verify with SwiftUI Previews and adjust to 24pt if the layout clips or reads poorly on the minimum deployment target.

**Affected files:** `UsageRow.swift` (full rewrite, ~35 lines), `AccountDetail.swift` (remove `subtitle` and `style` from all 6 call sites), `UsageView.swift` (remove `subtitle` and `style` from 3 call sites in `usageContent()`; remove card-specific `VStack` spacing; update pixel-identity comment).

### D2: Replace `Int(value)` with `Int(value.rounded())` in UsageData Percentages

**Change the three `Int(value)` truncation calls in `UsageData` to `Int(value.rounded())` to eliminate systematic understatement of utilization percentages.**

Current code (`UsageManager.swift:12-14`):

```swift
var sessionPercentage: Int { Int(sessionUtilization) }
var weeklyPercentage: Int { Int(weeklyUtilization) }
var sonnetPercentage: Int? { sonnetUtilization.map { Int($0) } }
```

Fixed code:

```swift
var sessionPercentage: Int { Int(sessionUtilization.rounded()) }
var weeklyPercentage: Int { Int(weeklyUtilization.rounded()) }
var sonnetPercentage: Int? { sonnetUtilization.map { Int($0.rounded()) } }
```

`Double.rounded()` applies IEEE 754 round-half-to-even (banker's rounding): 89.5 → 90, 89.4 → 89, 88.5 → 88. This is the standard `Foundation` rounding mode and matches user expectation for displayed percentages.

**Relationship to ADR-002 D4 (bottleneck precision note).** ADR-002 D4 introduced `UsageData.bottleneck` and documented a precision note: "truncation happens before comparison rather than after... the 1% precision loss does not affect user-facing thresholds." With this fix, truncation-before-comparison becomes rounding-before-comparison. The precision concern documented in ADR-002 D4 is eliminated: all `Int` percentage values are now correctly rounded before any comparison in `bottleneck`, `worstCaseUtilization`, `statusEmoji`, and `Color.forUtilization()`. The ADR-002 D4 precision note is superseded. Additionally, D1 removes the progress bar, which was the visual element where rounding imprecision was most perceptible — a bar rendered at 89% vs. 90% occupies visibly different widths at 280pt popover width.

**Affected files:** `UsageManager.swift` (3 lines, `UsageData` struct at lines 12-14).

### D3: Update `expandedRowHeight` Constant from 228pt to ~140pt

**Update the hardcoded `expandedRowHeight` constant in both `AccountList.computedScrollHeight` and `AppDelegate.computePopoverHeight()` to reflect the reduced detail area after D1.**

Current formula for expanded row height:
```
expandedRowHeight = 228pt
  = 48pt (AccountHeader frame height, from ADR-002 D2)
  + ~8pt (DisclosureGroup internal content top padding)
  + 3 × ~54pt (UsageRow at ~70pt card height, minus inline padding delta)
  + 2 × 8pt (VStack(spacing: 8) inter-row spacings)
  + ~8pt (DisclosureGroup internal content bottom padding)
  ≈ 228pt
```

After D1 (20pt compact rows, `VStack(spacing: 8)` in `AccountDetail`, no explicit vertical padding on the VStack itself, only `.padding(.horizontal, 12)`):
```
expandedRowHeight ≈ 140pt
  = 48pt (AccountHeader frame height, unchanged)
  + ~8pt (DisclosureGroup internal content top padding)
  + 76pt (VStack content: 3 × 20pt compact rows + 2 × 8pt inter-row spacing)
  + ~8pt (DisclosureGroup internal content bottom padding)
  = 48 + 8 + 76 + 8
  = 140pt
```

The ~8pt top and bottom padding is DisclosureGroup's internal content padding on macOS, not explicit padding on the `AccountDetail` `VStack`. `LiveAccountDetail` (`AccountDetail.swift:8`) uses `VStack(spacing: 8)` with only `.padding(.horizontal, 12)` — no top or bottom padding. The DisclosureGroup content area is what adds vertical space around the expanded content.

**Variable row count.** `sonnetPercentage` is optional; when `nil`, only 2 rows render (Session + Weekly), reducing the `VStack` content from 76pt to 48pt (2 × 20pt rows + 1 × 8pt spacing) and the effective expanded height from ~140pt to ~112pt. The constant uses the 3-row worst case (~140pt) to avoid undersizing the popover when sonnet data is present. For 2-row accounts, the ~28pt overallocation produces minor whitespace below the detail section, which is acceptable.

**Note:** DisclosureGroup's internal content padding is not formally documented by Apple and may vary across macOS versions. The ~8pt estimate is based on observed macOS 13/14 behavior. Implementors must verify empirically with SwiftUI Previews at 2, 3, 4, and 5 accounts and adjust the constant if the observed height differs materially. The 480pt popover cap in `min(max(...), 480)` bounds any overestimate.

Updated constants in both files:

```swift
// AccountList.swift — computedScrollHeight
let expanded: CGFloat = 140   // updated from 228pt (D1: 3 × 20pt compact rows + 48pt header + ~16pt DisclosureGroup padding)
let collapsed: CGFloat = 48   // unchanged (ADR-002 D2)

// ClaudeMonitorApp.swift — computePopoverHeight()
let expandedRowHeight: CGFloat = 140  // updated from 228pt (D1: compact rows)
let collapsedRowHeight: CGFloat = 48  // unchanged (ADR-002 D2)
let headerFooter: CGFloat = 92        // unchanged (44pt app header + 48pt compressed footer)
```

Updated popover height formula for reference (N = account count):
```
height = 92 + 140 + (N-1) × 48
N=2: 92 + 140 + 48 = 280pt
N=3: 92 + 140 + 96 = 328pt
N=6: 92 + 140 + 240 = 472pt → within 480pt cap
N=9: 92 + 140 + 384 = 616pt → capped to 480pt, scrollable
```

**Both constants must be updated atomically in the same commit.** ADR-002 RF5 flagged that these two constants are coupled and must stay in sync. The comments at `AccountList.swift:37` and `ClaudeMonitorApp.swift:162` already document this requirement.

**Affected files:** `AccountList.swift` (`computedScrollHeight`, line 52), `ClaudeMonitorApp.swift` (`computePopoverHeight()`, line 164).

### D4: Migrate Keychain Access from `security` CLI to `SecItemCopyMatching`

**Replace the `Process`/`Pipe`-based `readKeychainRawJSON(service:)` implementation with a synchronous `SecItemCopyMatching` call. Update `getClaudeCodeToken()` and `getAccessTokenFromAlternateKeychain()` to call the new method. Remove the `nonisolated` async wrapper and the `securityCommandFailed` error case.**

The new implementation:

```swift
private func readKeychainNative(service: String) throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let string = String(data: data, encoding: .utf8) else {
        throw KeychainError.from(status: status)
    }
    return string
}
```

`readKeychainNative` is a synchronous throwing function. It does not require `nonisolated`, `async`, or a `withCheckedThrowingContinuation` wrapper. It can be called from any isolation context, including `@MainActor`, without blocking because it does not perform a subprocess spawn — it issues a direct Security framework call that completes in microseconds.

`KeychainError` requires a `static func from(status: OSStatus) -> KeychainError` mapping:

```swift
static func from(status: OSStatus) -> KeychainError {
    switch status {
    case errSecItemNotFound:    return .notLoggedIn
    case errSecAuthFailed:      return .accessDenied
    case errSecInteractionNotAllowed: return .interactionNotAllowed
    case errSecInvalidData:     return .invalidData
    default:                    return .unexpectedError(status: status)
    }
}
```

`getClaudeCodeToken()` becomes synchronous. The `missingOAuthToken` diagnostic case (current `UsageManager.swift:383-388`) is preserved — only `securityCommandFailed` is removed:

```swift
private func getClaudeCodeToken() throws -> String {
    let jsonString: String
    do {
        jsonString = try readKeychainNative(service: "Claude Code-credentials")
    } catch KeychainError.notLoggedIn, KeychainError.accessDenied {
        if let token = try? getAccessTokenFromAlternateKeychain() {
            return token
        }
        throw KeychainError.notLoggedIn
    }

    if let jsonData = jsonString.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let accessToken = oauth["accessToken"] as? String {
            return accessToken
        }
        let keys = Array(json.keys).joined(separator: ", ")
        if let token = try? getAccessTokenFromAlternateKeychain() {
            return token
        }
        throw KeychainError.missingOAuthToken(availableKeys: keys)
    }

    if let token = try? getAccessTokenFromAlternateKeychain() {
        return token
    }
    throw KeychainError.invalidCredentialFormat
}

private func getAccessTokenFromAlternateKeychain() throws -> String {
    let jsonString = try readKeychainNative(service: "Claude Code")
    guard let jsonData = jsonString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let accessToken = oauth["accessToken"] as? String else {
        throw KeychainError.notLoggedIn
    }
    return accessToken
}
```

The `securityCommandFailed` case in `KeychainError` becomes dead code after this migration and is removed. `missingOAuthToken(availableKeys:)` is retained — it provides diagnostic information when the JSON structure is valid but lacks `claudeAiOauth`, which is a distinct failure mode from a missing or inaccessible keychain item. Call sites that currently catch `KeychainError.securityCommandFailed` (e.g., `getClaudeCodeToken()` at `UsageManager.swift:370`) are updated to catch `KeychainError.accessDenied` and `KeychainError.interactionNotAllowed` where appropriate.

**Caller cascade.** `getClaudeCodeToken()` and `getAccessTokenFromAlternateKeychain()` both become synchronous `throws` functions. `getAccessTokenWithChangeDetection()` (`UsageManager.swift:314`) also becomes synchronous `throws` — its only `async` dependency was `getClaudeCodeToken()`. Call sites in `refreshWithRetry()` drop `await` on the `getAccessTokenWithChangeDetection()` call but retain `try`. `refreshWithRetry()` and `refresh()` remain `async` because they call `refreshAllAccounts(liveToken:)` and `Task.sleep`, which are independently async. No callers outside `UsageManager` are affected.

The `nonisolated` modifier on `readKeychainRawJSON(service:)` (and the `withCheckedThrowingContinuation` pattern) is eliminated entirely.

**Why migrate now.** The original `security` CLI approach (ADR-001 D1, ADR-001 context) was adopted to avoid an ACL security dialog that appeared the first time `SecItemCopyMatching` attempted to access the `Claude Code-credentials` keychain item, because ClaudeMonitor was not in the item's trusted application list. The user has decided to accept this tradeoff: the dialog appears at most once, the user clicks "Always Allow," and it does not reappear. The operational cost of one dismissed dialog is acceptable in exchange for eliminating the subprocess machinery.

**Affected files:** `UsageManager.swift` (`readKeychainRawJSON` replaced by `readKeychainNative`, `getClaudeCodeToken` updated, `getAccessTokenFromAlternateKeychain` updated, `getAccessTokenWithChangeDetection` updated to drop `async`, `KeychainError.from(status:)` static factory added, `securityCommandFailed` case removed; `missingOAuthToken` case retained).

---

## Alternatives Considered

### D1 Alternatives: UsageRow Layout

**20pt single-line HStack (chosen).** Maximum density. Single line with label, conditional timer at ≥70%, and percentage. Saves ~120pt per expanded account (180pt → 60pt for 3 rows). The progress bar is removed; the percentage text communicates the same utilization value. The conditional timer ensures users near a rate limit see the most decision-relevant information. Accessibility is preserved via explicit `.accessibilityLabel` and `.accessibilityValue` on the containing `HStack`.

**Keep card style, remove progress bar only (~45pt).** Removes the `GeometryReader` block, retaining title, subtitle, and card background. Saves ~25pt per row vs. ~50pt with the full compact design. Three rows would yield ~135pt of detail (vs. ~180pt today or ~60pt with D1). The subtitle ("5-hour window") provides context but is not decision-relevant on repeated viewing. Rejected: moderate savings without the density gains that motivated this ADR.

**Two-line compact row (~32pt).** Line 1: label and percentage. Line 2: timer (always visible, not conditional). More space than the 20pt single-line but avoids the 20pt risk of feeling cramped. Three rows would yield ~96pt of detail vs. ~60pt. Rejected: the timer is not useful below 70% utilization, and always showing it wastes vertical space. The conditional-timer logic in D1 is the correct resolution.

**Status quo (~70pt card rows).** No change. Rejected: the ~180pt detail area per expanded account is the primary driver of popover height pressure at 3+ accounts. Retaining it defeats the purpose of this ADR.

### D2 Alternatives: Percentage Rounding

**`Int(value.rounded())` — standard half-to-even rounding (chosen).** `Double.rounded()` uses IEEE 754 round-half-to-even. 89.5 → 90, 89.4 → 89. This is the mathematically standard rounding mode, matches user intuition for displayed percentages, and eliminates the systematic understatement without overcounting. The `bottleneck` precision concern documented in ADR-002 D4 is resolved entirely.

**`Int(ceil(value))` — ceiling rounding.** Always rounds up. 0.3 → 1, 69.1 → 70 (triggering orange immediately), 89.1 → 90 (triggering red). Overcounts utilization: a user at 0.3% sees 1%. Rejected: overcounting is at least as misleading as undercounting, and the threshold boundary behavior is unpredictable.

**Adjust threshold checks to compensate for truncation.** Change `Color.forUtilization()`'s thresholds from `>= 70` and `>= 90` to `>= 69` and `>= 89` to account for 0-1% systematic understatement. Rejected: fragile and does not fix the displayed value. Users would see "89%" with a red status indicator, which is internally inconsistent. The displayed value and the threshold comparison would use different effective values.

**Status quo (`Int(value)` floor truncation).** Correctness bug persists. `Int(89.7)` = 89. Users near threshold boundaries see misleading values (89% instead of 90%, green instead of red). The `bottleneck` property in ADR-002 D4 compares already-truncated values, compounding the issue at threshold boundaries. Rejected: the systematic understatement is a correctness bug with user-visible impact.

### D3 Alternatives: Height Constant Strategy

**Update both hardcoded constants (chosen).** Simple, targeted change: update `expandedRowHeight` from 228 to ~140 in both `AccountList.swift` and `ClaudeMonitorApp.swift`. The RF5 comment in both files already flags them as coupled. No structural change to how the constants are defined. Matches the pattern established in ADR-002 when these constants were first introduced.

**Extract a shared `LayoutConstants` enum in `SharedStyles.swift`.** Define a single source of truth:
```swift
enum LayoutConstants {
    static let expandedRowHeight: CGFloat = 140
    static let collapsedRowHeight: CGFloat = 48
    static let headerFooterHeight: CGFloat = 92
}
```
Both `AccountList.computedScrollHeight` and `computePopoverHeight()` reference `LayoutConstants.expandedRowHeight`. Eliminates RF5 drift risk permanently. Adds ~10 lines to `SharedStyles.swift` and a dependency from `ClaudeMonitorApp.swift` to `SharedStyles.swift`. Rejected for this ADR: adds structural complexity for a constant that changes only when `UsageRow` layout changes, which is infrequent. The existing comment-based coupling documentation is sufficient. This alternative is worth reconsidering if a fourth height-relevant change occurs in a future ADR.

**Dynamic `GeometryReader`-based height measurement.** Measure actual rendered heights at runtime and propagate via `PreferenceKey`. Eliminates hardcoded constants entirely and adapts to font size accessibility settings. Rejected: adds significant complexity (`PreferenceKey`, `anchorPreference`, two-pass layout), introduces layout feedback loop risks in SwiftUI, and provides no practical benefit because the row height is fixed (20pt) and does not vary with content.

**Status quo (228pt constant).** After D1, the expanded detail area is ~76pt (3 × 20pt rows + 2 × 8pt spacing), but the constant still says 228pt. The popover and `ScrollView` would be ~88pt taller than necessary per expanded account. For N=3 accounts: `92 + 228 + 96 = 416pt` vs. the correct `92 + 140 + 96 = 328pt` — an 88pt overallocation. Rejected: the wasted height defeats the density improvement of D1.

### D4 Alternatives: Keychain Access Mechanism

**`SecItemCopyMatching` direct call (chosen).** Native Security framework API. Synchronous, no subprocess, no `nonisolated` wrapper required, Sendable-safe. One-time ACL dialog on first access; user clicks "Always Allow." Error codes map directly to `KeychainError` cases via OSStatus. Eliminates the `Process`/`Pipe`/`terminationHandler` machinery. The `securityCommandFailed` error case and its caller-side handling are removed.

**Status quo (`security` CLI via `Process`/`Pipe`).** Originally chosen in v1.7 (ADR-001) to avoid the ACL dialog. The subprocess approach creates two `Pipe` objects per read, requires `withCheckedThrowingContinuation` with a `terminationHandler`, and mandates `nonisolated` on the wrapper to satisfy Swift concurrency. The process spawn overhead is low in absolute terms but unnecessary given the synchronous alternative. The user has explicitly decided to accept the ACL tradeoff. Rejected: the constraint that motivated this choice (avoiding the ACL dialog permanently) is removed by user decision.

**`SecItemCopyMatching` with keychain-access-groups entitlement.** Add `com.apple.security.keychain-access-groups` to the app's entitlements, listing Claude Code's keychain group. This would allow `SecItemCopyMatching` to access the item without triggering the ACL dialog. Requires a specific provisioning profile and entitlement configuration. More complex to set up than accepting the one-time dialog. Rejected: the entitlement-based approach requires distribution infrastructure changes (signing, provisioning) that are out of scope. The one-time "Always Allow" dialog is an acceptable user experience.

**Hybrid: try `SecItemCopyMatching` first, fall back to `security` CLI.** If `SecItemCopyMatching` returns `errSecAuthFailed` or `errSecInteractionNotAllowed` (dialog denied), retry with the `security` CLI. Graceful degradation if the user denies the ACL dialog. Adds complexity: two independent read paths must be maintained, tested, and kept in sync. Rejected: maintaining the `security` CLI machinery solely as a fallback negates the simplification goal. If the user denies the dialog, the correct resolution is to guide them to re-allow access in System Settings, not to silently fall back to the CLI.

---

## Consequences

### Positive

- **~88pt recovered per expanded account.** Multi-account popover at 3 accounts is ~328pt (down from ~416pt). The 480pt cap is not reached until approximately 8 accounts (N=8: `92 + 140 + 336 = 568pt` → capped; N=7: `92 + 140 + 288 = 520pt` → capped; N=6: 472pt → fits).
- **Correct percentage rounding.** Systematic understatement is eliminated. Users near 70% or 90% thresholds see accurate values and accurate status bar color transitions.
- **Lighter, synchronous keychain access.** `SecItemCopyMatching` eliminates subprocess spawn overhead and Swift concurrency `nonisolated`/continuation machinery. Keychain reads are simpler, faster, and Sendable-safe.
- **Dead code removal.** `UsageRowStyle` enum, the `subtitle` parameter, and the `securityCommandFailed` error case are all removed. The codebase is smaller after this ADR than before.
- **ADR-002 D4 precision concern resolved.** The `bottleneck` property now compares correctly rounded integers; the precision footnote in ADR-002 D4 is superseded.

### Negative

- **ADR-002's single-account pixel-identity promise is broken.** `UsageView.singleAccountContent()` no longer renders identically to v1.7 after D1. The card-style rows with progress bars are replaced by compact single-line rows. Users upgrading from a version with card-style rows will notice a visual change. This is user-accepted per the constraint change noted in Context.
- **Progress bar is lost.** Users accustomed to the visual gauge lose it in both single-account and multi-account modes. The percentage text communicates the same information numerically, but the spatial/proportional representation is absent. No alternative visual gauge is introduced.
- **ACL keychain dialog appears once after update.** On first launch after the D4 change ships, macOS will show a security dialog asking whether ClaudeMonitor may access "Claude Code-credentials" in the keychain. Users who dismiss this with "Always Allow" see no further dialogs. Users who click "Deny" will see `KeychainError.accessDenied` surfaced as an error in the UI. The guidance in this case is to re-allow in System Settings > Privacy & Security > Keychain.
- **No automated tests.** Inherited from ADR-001 Risk R5. All four changes in this ADR have no automated test coverage. Manual testing and SwiftUI Previews remain the only validation gates.

### Risks

**R4 (MEDIUM): Height constants must be updated atomically.**
`expandedRowHeight` in `AccountList.swift` and `ClaudeMonitorApp.swift` must be updated in the same commit (D3). If only one is updated, the popover height and the `ScrollView` height diverge, producing clipped content or excess whitespace. The RF5 comment in both files documents this requirement; the D3 implementation step must enforce it. Mitigation: treat D3 as a single atomic commit touching both files.

**R5 (LOW): Accessibility regression from progress bar removal.**
The current `UsageRow` progress bar carries `.accessibilityLabel` and `.accessibilityValue` annotations at `UsageRow.swift:46-47`. These must be transferred to the compact row container. The D1 code sample includes `.accessibilityElement(children: .ignore)`, `.accessibilityLabel`, and `.accessibilityValue` on the `HStack`. Verify with VoiceOver on the target macOS version before shipping. Mitigation: manual VoiceOver testing as part of the D1 implementation step.

**R7 (MEDIUM): ACL dialog on `SecItemCopyMatching` first access.**
When D4 ships, users will see a macOS security dialog: "ClaudeMonitor wants to access 'Claude Code-credentials' in your keychain." Users who click "Deny" will see a persistent `accessDenied` error in the app UI. Mitigation: the error message for `KeychainError.accessDenied` (currently "Keychain access denied. Please allow access in System Settings.") is appropriate guidance. Release notes should explicitly mention this dialog and instruct users to click "Always Allow." This is a one-time friction event, not a recurring one.

**R8 (LOW): No automated tests for any of D1–D4.**
The `bottleneck` computed property (ADR-002 D4) and the new rounding behavior (D2) are pure functions and strong candidates for unit tests. `readKeychainNative` is a Security framework boundary — unit testing it requires mocking `SecItemCopyMatching`, which is non-trivial without dependency injection. The compact row layout (D1) could be validated with snapshot tests, but snapshot testing requires a new dependency (e.g., `swift-snapshot-testing`), which was previously prohibited and is now merely unrequired. Mitigation: SwiftUI Previews at multiple account counts; manual VoiceOver testing; manual percentage boundary testing at 69.5% and 89.5% utilization values.

---

## Implementation

### Ordering

The following sequence minimizes regression risk. D2 and D4 are independent infrastructure changes; D1 is the visual redesign; D3 depends on D1's final row height.

1. **D2 — Rounding fix.** Pure correctness change in `UsageManager.swift` (3 lines). No visual impact beyond percentage display accuracy. Independent of all other decisions. Land first so that D1's visual output shows correctly rounded values.

2. **D4 — Keychain migration.** Infrastructure change in `UsageManager.swift`. Independent of UI. Replace `readKeychainRawJSON` with `readKeychainNative`, update `getClaudeCodeToken` and `getAccessTokenFromAlternateKeychain`, add `KeychainError.from(status:)`, remove `securityCommandFailed` case. Verify that the app still reads the keychain and displays usage after the change.

3. **D1 — Compact row layout.** Visual redesign. Depends on D2 being landed (so that percentages display correctly during manual testing). Rewrite `UsageRow.swift`. Update all 9 call sites (6 in `AccountDetail.swift`, 3 in `UsageView.swift`) to remove `subtitle` and `style` parameters. Remove `UsageRowStyle` enum. Update pixel-identity comments in `UsageView.swift`. Verify with SwiftUI Previews at 1, 2, 3, 5 accounts. Verify VoiceOver semantics.

4. **D3 — Height constant update.** Depends on D1 being implemented and the actual rendered `expandedRowHeight` measured empirically. Update `AccountList.swift:52` and `ClaudeMonitorApp.swift:164` in the same commit. Verify popover height at 2, 3, 4, 5 accounts.

### Affected Files

| File | Change |
|------|--------|
| `ClaudeMonitor/UsageRow.swift` | D1: Full rewrite. Remove `UsageRowStyle`, `subtitle` parameter, progress bar, card background. Add compact single-line `HStack` layout. ~35 lines after rewrite. |
| `ClaudeMonitor/AccountDetail.swift` | D1: Remove `subtitle:` and `style:` parameters from all 6 `UsageRow` call sites in `LiveAccountDetail` and `StaleAccountDetail`. |
| `ClaudeMonitor/UsageView.swift` | D1: Remove `subtitle:` and `style:` parameters from 3 `UsageRow` call sites in `usageContent()`. Remove card-specific `VStack(spacing: 16)` if spacing is no longer appropriate. Update pixel-identity comment at line 55 and line 75. |
| `ClaudeMonitor/UsageManager.swift` | D2: Change 3 `Int(value)` to `Int(value.rounded())` at lines 12-14. D4: Replace `readKeychainRawJSON(service:)` with `readKeychainNative(service:)`. Update `getClaudeCodeToken()`, `getAccessTokenFromAlternateKeychain()`, and `getAccessTokenWithChangeDetection()` (all become synchronous `throws`). Add `KeychainError.from(status:)`. Remove `securityCommandFailed` case; retain `missingOAuthToken` case. |
| `ClaudeMonitor/AccountList.swift` | D3: Update `expanded` constant from 228 to ~140 in `computedScrollHeight`. |
| `ClaudeMonitor/ClaudeMonitorApp.swift` | D3: Update `expandedRowHeight` constant from 228 to ~140 in `computePopoverHeight()`. |

### Migration Strategy

No data migration is required. This ADR makes no changes to `AccountRecord`, `AccountUsage`, or UserDefaults persistence. The 60s polling loop and `TaskGroup` refresh are unchanged.

The keychain migration (D4) is transparent to the user after "Always Allow" is clicked. No stored data is affected — the same keychain item is read by both the CLI and the native API.

The percentage rounding change (D2) may cause displayed values to increase by 0-1% for users near threshold boundaries. No action is required from users; the change is automatically applied on the next refresh cycle.

The compact row change (D1) takes effect immediately on first launch after the update. There is no fallback to card-style rows.

### Rollback Plan

Rollback is a revert of the D1–D4 implementation commit(s). Because no persistence changes are made, rollback requires no UserDefaults cleanup.

If D4 (keychain migration) is reverted, the `security` CLI approach resumes. The "Always Allow" permission granted to `SecItemCopyMatching` during the D4 period remains in the keychain ACL and does not need to be revoked — it is harmless if `SecItemCopyMatching` is no longer called.

If D1 (compact rows) is reverted, the card-style `UsageRow` is restored. The D3 height constant revert must accompany D1 revert; otherwise the popover will be undersized for the card-style rows.

To minimize rollback complexity, implement D1 and D3 in the same commit.

### Success Metrics

- Three accounts fit within the popover without vertical overflow at 328pt (vs. 416pt previously). Verify at 3, 4, 5 accounts.
- A user at 89.7% utilization sees "90%" in the UI and an orange/red status bar indicator. Verify at 69.5% and 89.5% boundary cases.
- The keychain is read without spawning a subprocess. Verify with Instruments (no `security` process visible during refresh).
- The ACL dialog appears at most once per installation after D4 ships.
- VoiceOver announces "Session usage, N percent" for each compact row.
- `UsageRowStyle` enum has zero remaining references in the codebase.
- `subtitle` parameter has zero remaining references in `UsageRow` init.
- `securityCommandFailed` case has zero remaining references in the codebase.
- `expandedRowHeight` is 140pt (or measured empirically) in both `AccountList.swift` and `ClaudeMonitorApp.swift`.

---

## References

- ADR-001: `docs/adr/ADR-001-multi-account-support.md` — Established `security` CLI keychain approach (D1 context), `UsageData` struct, zero-dependency constraint
- ADR-002: `docs/adr/ADR-002-compact-multi-account-ui.md` — D2 (48pt rows), D4 (`bottleneck`, precision note superseded by D2 of this ADR), D5 (file decomposition), D6 (`Color.forUtilization`), RF1 (height formula), RF5 (height constant coupling)
- `ClaudeMonitor/UsageRow.swift` — Current 84-line card-style implementation (`UsageRowStyle` enum, `GeometryReader` progress bar)
- `ClaudeMonitor/AccountDetail.swift` — 6 inline `UsageRow` call sites (`LiveAccountDetail`, `StaleAccountDetail`)
- `ClaudeMonitor/UsageView.swift` — 3 card-style `UsageRow` call sites in `usageContent()`
- `ClaudeMonitor/AccountList.swift` — `computedScrollHeight` with `expandedRowHeight = 228`
- `ClaudeMonitor/ClaudeMonitorApp.swift` — `computePopoverHeight()` with `expandedRowHeight = 228`
- `ClaudeMonitor/UsageManager.swift` — `UsageData` (lines 12-14, `Int` truncation); keychain reading (lines 327-420)
- `ClaudeMonitor/SharedStyles.swift` — `Color.forUtilization()` (70% orange threshold)
- `ClaudeMonitor/AccountModels.swift` — `AccountRecord`, `AccountUsage` structs (unchanged by this ADR)
- Apple Security framework: `SecItemCopyMatching`, `kSecClassGenericPassword`, OSStatus error codes (`errSecItemNotFound`, `errSecAuthFailed`, `errSecInteractionNotAllowed`)
