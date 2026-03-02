# ADR-002: Compact Multi-Account UI Architecture — Accordion State, Row Density, and File Decomposition

**Date:** 2026-03-01
**Status:** Proposed
**Deciders:** Architecture team (adr-architect, tech-analyst, adr-writer)

---

## Context

### Current State

The Phase C/D multi-account UI (implemented per ADR-001 D5, shipped in v1.9) introduces a `DisclosureGroup` accordion layout in `UsageView.swift` for users with two or more accounts. The implementation works correctly for the two-account case it was designed for, but exhibits five structural problems when three or more accounts are present — a realistic scenario for users with personal + work + contractor accounts.

**Problem 1 — Per-row independent expand/collapse overflows the ScrollView.**
`AccountDisclosureGroup` holds `@State private var isExpanded` at `UsageView.swift:523`. Each row expands and collapses independently. With two accounts, one expanded and one collapsed: `~236pt + ~56pt = ~292pt` content fits within the 380pt `ScrollView` cap. With two accounts both expanded: `~236pt + ~236pt = ~472pt` — still fits. With three accounts and two expanded: `~236pt + ~236pt + ~56pt = ~528pt` — overflows. The overflow causes content clipping rather than graceful scrolling, because the `ScrollView`'s `maxHeight` of 380pt means a height hard-coded in `AccountList.frame(maxHeight: 380)` was set assuming few expanded rows simultaneously.

**Problem 2 — 56pt collapsed rows consume excessive vertical space for 3+ accounts.**
`AccountHeader` has `.frame(height: 56)` at `UsageView.swift:490` and always displays both email and organization name. At 56pt per collapsed row, three collapsed accounts consume `3 × 56 = 168pt`. Reducing to 48pt yields `3 × 48 = 144pt`, recovering 24pt — enough for one additional collapsed account before overflow.

**Problem 3 — Full-height footer is identical in single-account and multi-account modes.**
`footerView()` at `UsageView.swift:188–262` renders ~100pt of vertical space: a "Check for Updates" button, a "Launch at Login" toggle, a divider, a timestamp/button row, another divider, and a display name. In multi-account mode, this fixed ~100pt footprint reduces the space available for account rows. Compressing the footer to ~48pt in multi-account mode recovers ~52pt — equivalent to nearly one full collapsed row.

**Problem 4 — 718-line monolith impedes maintenance.**
`UsageView.swift` currently contains 11 view types and helper functions (`UsageView`, `UsageRow`, `LiveIndicator`, `CachedBadge`, `StaleBadge`, `AccountHeader`, `AccountDisclosureGroup`, `AccountList`, `colorForPercentage` ×2, `formatTimeRemaining`, `launchClaudeCLI`). No file in the project approaches this length; the next largest is `UsageManager.swift` at ~687 lines. Files of this size make it difficult to navigate, review, and reason about view isolation.

**Problem 5 — `colorForPercentage` is duplicated.**
Identical implementations exist at `UsageView.swift:264–268` (free function on `UsageView`) and `UsageView.swift:685–689` (method on `AccountDisclosureGroup`). These will diverge if thresholds ever change.

**Problem 6 — `highestUtilization` has no canonical source of truth.**
The "worst-case utilization" concept is computed in three places:
- `AccountDisclosureGroup.highestUtilization` (`UsageView.swift:534–537`): `max(sessionPercentage, weeklyPercentage)` — excludes sonnet.
- `UsageManager.worstCaseUtilization` (`UsageManager.swift:95–102`): `max(sessionUtilization, weeklyUtilization)` — excludes sonnet.
- `UsageManager.statusEmoji` (`UsageManager.swift:83–92`): same exclusion.

The exclusion of `sonnetPercentage` from these calculations was not a deliberate design choice documented in ADR-001 — it was an oversight. Sonnet-only rate limits are real constraints that affect the user's ability to use the product. A user at 95% sonnet utilization with 20% session and weekly utilization sees a green status bar indicator, which is misleading.

### Business Driver

Real-world usage by multi-account users (personal + work, personal + org contractor) exposes the overflow and density problems at three accounts. The compact UI refactor addresses all six problems without introducing new dependencies, changing the data model, or affecting single-account behavior.

### Constraints (inherited from ADR-001)

- Zero new Swift package dependencies.
- No changes to `AccountRecord` or `AccountUsage` data model fields.
- No changes to persistence (UserDefaults) or refresh architecture (60s polling, `TaskGroup`).
- Popover width remains 280pt; max popover height remains capped at 480pt.
- Single-account view (`manager.accounts.count <= 1`) must remain pixel-identical to v1.7.
- The `security` CLI approach for keychain access is fixed; no changes to token reading.

### Source

The six decisions below emerged from a structured conceptualize session (2026-03-01, 4 SME domains: data design, info architecture, UX, system architecture; 6 phases; unanimous ACCEPT; composite score 7.75/10). The accordion overflow resolution in particular was driven by concrete arithmetic: two SMEs independently computed that 2 expanded accounts = ~540pt of content, which exceeds the 480pt max. This evidence-based constraint settled the exclusive-vs-independent accordion debate.

---

## Decision

### D1: Exclusive Accordion via Lifted State

**Replace per-row `@State private var isExpanded` with `@State var expandedEmail: String?` lifted to `AccountList`. Bridge to `DisclosureGroup(isExpanded:content:label:)` with a `Binding` adapter.**

The current design stores expand/collapse state in each `AccountDisclosureGroup` instance. This makes it structurally impossible to enforce mutual exclusivity without cross-component communication. The fix is to lift the expanded state one level up to `AccountList`, which owns the row collection.

The `Binding` adapter bridges the parent `String?` state to the `Bool` that `DisclosureGroup` requires:

```swift
struct AccountList: View {
    let accounts: [AccountUsage]
    let onRemoveAccount: ((String) -> Void)?
    @State private var expandedEmail: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(accounts) { accountUsage in
                    let email = accountUsage.account.email
                    let binding = Binding<Bool>(
                        get: { expandedEmail == email },
                        set: { isExpanded in
                            expandedEmail = isExpanded ? email : nil
                        }
                    )
                    AccountDisclosureGroup(
                        accountUsage: accountUsage,
                        isExpanded: binding,
                        onRemove: accountUsage.isCurrentAccount ? nil : {
                            onRemoveAccount?(email)
                        }
                    )
                    Divider()
                }
            }
        }
        .frame(maxHeight: computedScrollHeight)
        .onAppear {
            // Auto-expand the live account on open
            expandedEmail = accounts.first(where: { $0.isCurrentAccount })?.account.email
        }
    }

    /// Estimated scroll area height: header + footer are excluded from this frame.
    /// Assumes 1 expanded row + (N-1) collapsed rows, matching the AppDelegate formula in RF1.
    /// expandedRowHeight ≈ 228pt (48pt header + ~180pt detail)
    /// collapsedRowHeight = 48pt
    private var computedScrollHeight: CGFloat {
        let n = CGFloat(accounts.count)
        let expanded: CGFloat = 228
        let collapsed: CGFloat = 48
        let content = expanded + (n - 1) * collapsed
        return min(content, 380) // 380pt = 480pt cap minus ~44pt app header minus ~56pt update banner area
    }
}
```

`AccountDisclosureGroup` receives `isExpanded: Binding<Bool>` as an init parameter rather than holding its own `@State`.

**All-collapsed is a valid state.** If the user collapses the last expanded row, `expandedEmail` becomes `nil` and all rows display in collapsed form. There is no snap-back logic. This was validated as the correct behavior by the conceptualize team: forcing an expansion creates unexpected visual jumps and fights user intent.

**Expanded state resets on popover dismiss.** When the NSPopover is closed and reopened, SwiftUI recreates the `AccountList` view hierarchy, resetting `expandedEmail` to `nil`. The `onAppear` handler re-expands the live account. This is documented as intended behavior, not a bug. Persisting expanded state across popover sessions would require `@AppStorage` or `UserDefaults`, adding complexity for negligible user benefit.

**Auto-expand behavioral change.** In the prior independent-accordion model, both the live account and any actively-refreshing accounts were auto-expanded on init (`_isExpanded = State(initialValue: accountUsage.isCurrentAccount || accountUsage.isActivelyRefreshing)` at `UsageView.swift:529`). In the exclusive accordion model, only one row can be expanded. The live account is chosen as the auto-expand default because it has the most current data. Actively-refreshing accounts, which were also auto-expanded in the independent model, remain collapsed by default. Their status is visible in the collapsed row header (the `CachedBadge` indicator), so the behavioral change does not hide relevant information.

**`DisclosureGroup` is retained.** A custom `VStack`+`onTapGesture` implementation was considered (see Alternatives) but rejected because `DisclosureGroup` provides built-in VoiceOver support: focus management, Space-to-toggle activation, and "expanded"/"collapsed" state announcements. Replacing it would require re-implementing these behaviors manually.

### D2: 48pt Compact Collapsed Rows

**Reduce `AccountHeader` collapsed height from 56pt to 48pt by reducing vertical padding from 8pt to 4pt and hiding organization name in the collapsed state.**

The organization name (`account.organizationName`) is shown in expanded state via the `AccountHeader` when the row is open. In collapsed state, it is omitted. Email remains visible in both states as the primary account identifier.

The 48pt height is derived from the minimum target for comfortable tap/click affordance on macOS (44pt for iOS, 44pt recommended on macOS). At 48pt, three collapsed rows consume 144pt vs. 168pt at 56pt — a 24pt improvement.

`AccountHeader` receives an `isExpanded: Bool` parameter to conditionally render the organization name:

```swift
struct AccountHeader: View {
    let email: String
    let organizationName: String?
    let isExpanded: Bool          // new
    // ... other params unchanged

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(email)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isExpanded, let org = organizationName {  // conditional on isExpanded
                    Text(org)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // ... rest unchanged
        }
        .frame(height: 48)          // reduced from 56
        .padding(.horizontal, 12)
        .padding(.vertical, 4)      // reduced from 8
    }
}
```

### D3: 48pt Compressed Footer (Multi-Account Mode Only)

**In multi-account mode (`manager.accounts.count > 1`), replace the full ~100pt footer with a 48pt compressed footer that places secondary actions behind a gear icon using `SwiftUI.Menu`.**

The full footer (`footerView()`) contains: a "Check for Updates" button, a "Launch at Login" checkbox toggle, a divider, a timestamp/refresh/globe/quit row, a second divider, and a display name label. The compressed footer retains the timestamp, refresh, and quit buttons in a compact `HStack`. The "Check for Updates" and "Launch at Login" actions move into a `Menu` labeled with a gear icon:

```swift
@ViewBuilder
func compressedFooterView() -> some View {
    HStack {
        if let lastUpdated = manager.lastUpdated {
            Text(lastUpdated.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Spacer()
        Menu {
            Button("Check for Updates") {
                Task { await manager.checkForUpdates() }
            }
            Divider()
            Toggle("Launch at Login", isOn: $launchAtLogin)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        Button { Task { await manager.refresh() } } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(manager.isLoading)
        Button {
            openURL(URL(string: "https://claude.ai")!)
        } label: {
            Image(systemName: "globe")
        }
        .buttonStyle(.borderless)
        Button { NSApplication.shared.terminate(nil) } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(height: 48)
    .background(Color(NSColor.controlBackgroundColor))
}
```

`SwiftUI.Menu` with `.menuStyle(.borderlessButton)` renders as an `NSMenu` natively on macOS, which avoids the nested-popover problem that would arise from a custom SwiftUI overlay inside an `NSPopover`.

**Scope boundary:** ADR-002 covers the compressed footer layout and gear icon placement only. A full settings panel (additional preferences, account management UI, about screen) is out of scope and deferred to a future ADR.

Single-account mode retains `footerView()` unchanged, pixel-identical to v1.7.

### D4: `bottleneck` Computed Property on `UsageData`

**Add a `bottleneck` computed property to `UsageData` that returns the highest utilization across session, weekly, and sonnet categories. Update `UsageManager.worstCaseUtilization` and `statusEmoji` to use it.**

```swift
extension UsageData {
    /// The highest-utilization category across all available metrics.
    /// Used as the single source of truth for status bar icon, accordion header percentage,
    /// and popover height computation.
    var bottleneck: (percentage: Int, category: String) {
        var highest = (percentage: sessionPercentage, category: "Session")
        if weeklyPercentage > highest.percentage {
            highest = (weeklyPercentage, "Weekly")
        }
        if let sonnet = sonnetPercentage, sonnet > highest.percentage {
            highest = (sonnet, "Sonnet")
        }
        return highest
    }
}
```

**Behavioral change — sonnet inclusion is intentional and documented here.** The current `worstCaseUtilization` and `statusEmoji` implementations in `UsageManager` explicitly compute `max(sessionUtilization, weeklyUtilization)`, excluding `sonnetUtilization`. This exclusion was not a documented design choice in ADR-001 — it was an oversight in the original implementation. Sonnet-only rate limits are enforced independently by the Anthropic API and directly limit the user's ability to use Claude. A user at 95% sonnet utilization with low session/weekly utilization is near a real rate limit that will affect their workflow. The status bar indicator and accordion header should reflect this. After this change, the status bar will show orange or red when sonnet utilization crosses the 70% or 90% threshold.

`UsageManager.worstCaseUtilization` and `statusEmoji` are updated to delegate to `bottleneck`:

```swift
var worstCaseUtilization: Int? {
    let activeAccounts = accounts.filter { $0.isCurrentAccount || $0.isActivelyRefreshing }
    guard !activeAccounts.isEmpty else { return nil }
    return activeAccounts.compactMap { $0.usage?.bottleneck.percentage }.max()
}

var statusEmoji: String {
    guard let pct = worstCaseUtilization else { return "❓" }
    if pct >= 90 { return "🔴" }
    if pct >= 70 { return "🟡" }
    return "🟢"
}
```

**Precision note — Double-to-Int comparison order change.** The current `worstCaseUtilization` compares raw `Double` values via `.reduce(0.0)` and truncates to `Int` at the end (`Int(maxUtil)`). The proposed `bottleneck` compares `Int` values first (via `sessionPercentage`, `weeklyPercentage`, `sonnetPercentage`, which each apply `Int(utilization)`), then returns an `Int`. This changes the comparison order: two categories differing by less than 1.0 (e.g., session = 69.8, weekly = 70.1) would both truncate to 69 and 70 respectively under the new implementation — the same result as today in this example, but the truncation happens before comparison rather than after. In edge cases where two categories sit on opposite sides of a 1.0 boundary, the selected category may differ between old and new implementations. This is acceptable: the UI displays integer percentages, and the 1% precision loss does not affect user-facing thresholds (70% and 90% are both whole numbers). The behavioral improvement of sonnet inclusion far outweighs this precision trade-off.

`AccountDisclosureGroup.highestUtilization` is replaced with `accountUsage.usage?.bottleneck.percentage ?? 0`.

### D5: File Decomposition

**Extract `UsageView.swift` into 6 focused files using Option A (6-file decomposition). All files target <150 lines.**

The current 718-line `UsageView.swift` is a monolith with no logical seams between its 11 view types. Both decomposition options are evaluated below (see Alternatives). The 6-file decomposition is preferred because it produces files with single clear responsibilities, makes the accordion state lift change easier to review in isolation, and avoids the "dumping ground" risk of a catch-all `AccountViews.swift`.

Proposed file boundaries:

| File | Contents | Estimated lines |
|------|----------|-----------------|
| `UsageView.swift` | Root view, conditional layout, app header, update banner, single-account content, `loadingView`, `errorView` | ~120 |
| `AccountList.swift` | `AccountList` with lifted `expandedEmail` state, `computedScrollHeight` | ~60 |
| `AccountRow.swift` | `AccountDisclosureGroup`, `AccountHeader` | ~130 |
| `AccountDetail.swift` | `liveAccountDetail`, `staleAccountDetail` | ~90 |
| `UsageRow.swift` | `UsageRow`, `UsageRowStyle`, `formatTimeRemaining` | ~80 |
| `SharedStyles.swift` | `colorForPercentage` (deduplicated), `LiveIndicator`, `CachedBadge`, `StaleBadge` | ~70 |

All files are placed under `ClaudeUsage/`. The existing `UsageView.swift` is modified in-place until the extract step; extraction is the final implementation step (see Implementation §ordering).

**Xcode project file.** Adding new Swift files to a target requires updating `ClaudeUsage.xcodeproj/project.pbxproj`. This file is text-based but has a complex structure. New files must be added via Xcode's UI ("Add Files to ClaudeUsage…") or the `xcodebuild` tooling — not by manually editing `.pbxproj`. Doing so outside Xcode is the primary practical risk of this step (merge conflicts, incorrect UUID generation). The `.pbxproj` edit is the last step in the implementation sequence to minimize the window of conflict.

### D6: `colorForPercentage` Deduplication

**Extract the duplicated `colorForPercentage` function to a `Color` extension in `SharedStyles.swift`.**

The function currently appears identically at `UsageView.swift:264–268` and `UsageView.swift:685–689`:

```swift
func colorForPercentage(_ pct: Int) -> Color {
    if pct >= 90 { return .red }
    if pct >= 70 { return .orange }
    return .green
}
```

The canonical form after extraction:

```swift
// SharedStyles.swift
extension Color {
    static func forUtilization(_ percentage: Int) -> Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .green
    }
}
```

Call sites change from `colorForPercentage(pct)` to `Color.forUtilization(pct)`. The `extension Color` approach is preferred over a free function or enum namespace because: it is discoverable via Xcode autocomplete when working with `Color` values, it reads naturally at call sites (`Color.forUtilization(usage.sessionPercentage)`), and it follows Swift API design conventions for type-specific factory methods.

---

## Alternatives Considered

### D1 Alternatives: Accordion State Management

**Status quo (independent per-row `@State`):** No change. The overflow problem is not fixed. Three accounts with two expanded = 528pt, which clips content. Rejected: does not solve the problem this ADR addresses.

**Custom tap-based collapse (replace `DisclosureGroup`):** Replace `DisclosureGroup` with a `VStack` containing a custom header `Button` and a conditional detail view. This makes exclusive state trivial to manage (toggle `expandedEmail` in the button action). Rejected: loses built-in `DisclosureGroup` VoiceOver semantics (focus management, Space-to-toggle, expand/collapse announcements). Rebuilding these correctly is non-trivial and introduces regression risk in a codebase with no automated tests.

**`@AppStorage` for persisting expanded state:** Persist `expandedEmail` across popover sessions via `@AppStorage`. The expanded account survives popover close/reopen. Rejected for this version: adds persistence coupling to a purely ephemeral UI state; the live account auto-expand on `onAppear` provides a reasonable default without persistence overhead. Deferred to a future enhancement.

**Per-section animation with `withAnimation`:** Wrap `expandedEmail` updates in `withAnimation(.easeInOut)` for a smooth transition. Not rejected — this is orthogonal to the state management decision and can be added alongside D1.

### D2 Alternatives: Row Height

**Keep 56pt rows:** No change. At 56pt × 3 accounts = 168pt for collapsed rows. Works for three accounts but leaves little margin for four or five. Rejected: does not solve the density problem.

**44pt rows:** The minimum comfortable click target. Reduces three-account collapsed height to 132pt. Rejected by conceptualize consensus: 44pt was considered too tight for the email text at 12pt headline font, which has 14pt line height + 2pt descenders. 48pt provides 4pt breathing room.

**Variable height rows (dynamic based on content):** Rows with organizations expand to show more; single-email rows stay at 44pt. Rejected: inconsistent row heights make the accordion feel unstable and unpredictable. Consistent 48pt rows provide visual rhythm.

### D3 Alternatives: Footer Compression

**Status quo (full footer in all modes):** No change. Multi-account mode retains ~100pt footer. Rejected: wastes 52pt that cannot be reclaimed for account rows.

**Remove footer in multi-account mode entirely:** Show no footer controls when multiple accounts are visible. Rejected: "Check for Updates", "Launch at Login", and the quit button are meaningful in multi-account mode; hiding them entirely degrades usability.

**Floating gear icon overlaid on scroll content:** Place a gear button overlaid at the bottom-right of the `ScrollView`, floating above the content. Rejected: standard macOS popover design does not use floating overlays; this would look inconsistent with system conventions.

**NSMenu popover-based settings sheet:** Open a second `NSPopover` from the gear icon. Rejected: nested popovers require custom `NSPopoverDelegate` handling on macOS and have known focus and z-order issues. `SwiftUI.Menu` maps to `NSMenu` natively, which is the macOS-standard pattern for this interaction.

**Do nothing (defer footer compression):** Accept the lost space and address in a future version. Rejected: the 52pt recovery from footer compression directly enables one additional visible collapsed account in the 480pt cap, which makes the feature meaningfully better for 4+ account users.

### D4 Alternatives: Utilization Source of Truth

**Status quo (separate inline computations, sonnet excluded):** Three independent `max(session, weekly)` computations with no sonnet. Rejected: three divergent implementations create maintenance burden and silently omit a real rate limit category. The status bar misleads users with high sonnet utilization.

**`bottleneck` as a method on `AccountUsage`:** Place the computation on `AccountUsage` rather than `UsageData`. Rejected: `AccountUsage` is an in-memory view model composite; `UsageData` is the value that carries the raw metrics. The computation belongs on the type that owns the data.

**Separate `bottleneckExcludingSonnet` and `bottleneckIncludingSonnet`:** Provide both variants to allow callers to choose. Rejected: introducing two variants preserves the ambiguity that caused the oversight in the first place. The single `bottleneck` property with documented sonnet inclusion is the correct resolution. If a future requirement needs sonnet-excluded computations, that can be added with explicit naming.

**Keep sonnet excluded, add a separate `sonnetStatus` indicator:** Show a separate sonnet status badge in the UI without changing the main `worstCaseUtilization`. Rejected: adds UI complexity without a clear user benefit; the status bar is already the primary at-a-glance signal.

### D5 Alternatives: File Decomposition

**Status quo (718-line monolith):** No change. Rejected: 718 lines with 11 view types is objectively difficult to navigate and review. The monolith will grow further as features are added.

**Option A — 6-file decomposition (chosen):**
- `UsageView.swift`, `AccountList.swift`, `AccountRow.swift`, `AccountDetail.swift`, `UsageRow.swift`, `SharedStyles.swift`
- **Pros:** Each file has a single clear responsibility. No file exceeds 150 lines. `AccountDetail.swift` isolates the live-vs-stale detail rendering, which is the most complex view logic.
- **Cons:** Six files = six `.pbxproj` entries to add. `AccountRow.swift` at ~130 lines still contains two view types (`AccountDisclosureGroup` + `AccountHeader`), though they are tightly coupled.
- **Why chosen:** Cleaner separation than Option B; avoids large intermediate files.

**Option B — 4-file decomposition:**
- `UsageView.swift`, `AccountViews.swift`, `UsageRow.swift`, `UsageStyles.swift`
- **Pros:** Fewer files to add to Xcode project. `AccountViews.swift` consolidates all account-related views.
- **Cons:** `AccountViews.swift` would contain `AccountList`, `AccountDisclosureGroup`, `AccountHeader`, and potentially `AccountDetail` — ~280 lines, nearly as large as the monolith sections it replaces. "Account views" is a vague grouping that will accumulate more types over time.
- **Why rejected:** Trades one monolith for a smaller one. The 6-file decomposition has clearer invariants per file.

**Minimal decomposition (extract only `UsageRow` and `SharedStyles`):**
- `UsageView.swift` (~550 lines after extraction), `UsageRow.swift`, `SharedStyles.swift`
- **Pros:** Minimal `.pbxproj` changes (2 new files).
- **Cons:** The core account view logic remains in a 550-line file. This defers the maintenance benefit without avoiding the `.pbxproj` risk.
- **Why rejected:** Does not meaningfully address Problem 4.

### D6 Alternatives: Deduplication Location

**Status quo (two identical implementations):** Rejected: will diverge on threshold changes. The duplication is already present and will worsen as new callers appear.

**Free function at module scope:** `func colorForUtilization(_ pct: Int) -> Color { ... }`. Works but is not namespace-scoped; shows up in global autocomplete. Acceptable for an internal utility but less idiomatic than a `Color` extension.

**`enum UsageStyles` as namespace:** `enum UsageStyles { static func color(for pct: Int) -> Color { ... } }`. Namespaced but verbose at call sites (`UsageStyles.color(for: pct)`). The enum-as-namespace pattern is a common Swift workaround for missing module namespacing, but a `Color` extension is more natural for this use case.

**`extension Color` with `static func forUtilization(_:)` (chosen):** Discoverable via autocomplete when typing `Color.`, reads naturally at call sites, follows Swift API conventions.

---

## Consequences

### Positive

- Three or more accounts fit comfortably within the 480pt popover cap. Exclusive accordion prevents multi-row expansion overflow.
- 52pt reclaimed from footer compression in multi-account mode — sufficient for one additional collapsed account row.
- `UsageData.bottleneck` provides a single authoritative source for utilization across all six call sites that previously computed their own `max`.
- Sonnet utilization is included in the status bar calculation for the first time, accurately representing real API constraints to the user.
- All extracted files stay under 150 lines, improving navigability and review surface area.
- `colorForPercentage` deduplication eliminates future divergence risk.
- Zero new dependencies introduced.
- Single-account mode is unchanged: no visual, behavioral, or performance impact for existing single-account users.

### Negative

- **Expanded state resets on popover dismiss.** The user's last-expanded account is not remembered. The live account is re-expanded on open via `onAppear`, which is a reasonable default, but users who prefer a collapsed view must re-collapse on each open. This is acceptable per conceptualize team consensus; the alternative (persisting state) adds complexity for a low-value interaction.
- **Sonnet inclusion in `bottleneck` is a visible behavioral change.** Users with high sonnet utilization will see the status bar change from green to orange or red after this update. This may cause initial confusion. Release notes should call this out explicitly.
- **Xcode project file updates for file decomposition are merge-conflict-prone.** `.pbxproj` is a text file with UUIDs and cross-references that conflict badly in concurrent development. The decomposition must be performed as an isolated commit with no concurrent `.pbxproj` changes in flight.
- **No automated tests to catch regressions.** Inherited from ADR-001 Risk R5. The `UsageManager` interface is unchanged in this ADR, but the view hierarchy refactor has no safety net beyond manual testing and SwiftUI Previews.

### Risks

**RF1 (MEDIUM): Popover height formula does not track accordion state dynamically.**
`computePopoverHeight()` in `AppDelegate` currently estimates height based on expanded/collapsed account count, using `expandedCount` derived from `isCurrentAccount || isActivelyRefreshing`. After D1 and D2, the formula must be updated to reflect: 1 expanded row × `expandedRowHeight` (adjusted for 48pt header) + (N-1) collapsed rows × 48pt + header + footer. The formula is an approximation; actual SwiftUI layout height depends on runtime content. Mitigation: use a conservative fixed formula (assume 1 expanded + N-1 collapsed) rather than attempting to track `expandedEmail` state from `AppDelegate`. The 480pt cap in `min(max(...), 480)` acts as a safety bound.

Updated formula (after D2 and D3):
```
headerHeight = 44pt
footerHeight = 48pt (multi-account) or 100pt (single-account)
expandedRowHeight = 48pt (header) + ~180pt (detail) = ~228pt
collapsedRowHeight = 48pt
height = headerHeight + footerHeight + 1 * expandedRowHeight + (N-1) * collapsedRowHeight
       = 44 + 48 + 228 + (N-1) * 48
```
For N=3: `44 + 48 + 228 + 96 = 416pt` — fits within 480pt cap.
For N=6: `44 + 48 + 228 + 240 = 560pt` → capped to 480pt, scrollable.

**RF2 (LOW): `DisclosureGroup` animation with external `Binding<Bool>`.**
Supplying a `Binding<Bool>` adapter to `DisclosureGroup` is a supported pattern but behaves slightly differently from the internal `@State` version — the animation is driven by the parent's state update cycle rather than the `DisclosureGroup` internals. The conceptualize Phase 6 confirmed the Binding adapter code pattern (see D1) works correctly. Mitigation: verify with SwiftUI Preview and on-device testing before shipping.

**RF3 (LOW): `Menu` in compressed footer on macOS 12.**
`SwiftUI.Menu` with `.menuStyle(.borderlessButton)` requires macOS 12+. The existing codebase uses `SMAppService` (macOS 13+) in `footerView()`. Check minimum deployment target — if it is already macOS 13, no additional guard is needed. If macOS 12 support is required, wrap with `if #available(macOS 13.0, *) { compressedFooterView() } else { footerView() }`.

**RF4 (MEDIUM): Sonnet inclusion is an undocumented prior behavior change.**
The prior exclusion of `sonnetPercentage` from `worstCaseUtilization` was never documented. Users who have relied on the status bar as a session/weekly indicator only may be surprised to see it reflect sonnet utilization after the update. Mitigation: document explicitly in release notes ("Status bar now reflects sonnet-only utilization when it is the highest active limit").

**RF5 (MEDIUM): No automated tests.**
The refactored view hierarchy and new `bottleneck` property have no test coverage. SwiftUI Previews are the minimum validation gate. The `bottleneck` computed property is pure (no side effects, no dependencies) and is a strong candidate for unit tests if test infrastructure is added in a future sprint. Snapshot testing would require a new dependency (e.g., `swift-snapshot-testing`), which violates the zero-dependency constraint.

---

## Implementation

### Ordering

The following sequence minimizes the risk of introducing regressions at each step. Steps 1–5 modify `UsageView.swift` in-place; Step 6 updates `AppDelegate`; Step 7 extracts files; Step 8 updates the Xcode project file.

1. **D6 — Deduplicate `colorForPercentage`:** Create `SharedStyles.swift` with `extension Color { static func forUtilization(...) }`. Replace both call sites in `UsageView.swift`. Verify with Previews. This is a pure refactor with no behavioral change.

2. **D4 — Add `bottleneck` to `UsageData`:** Add the computed property to `UsageManager.swift` (alongside `UsageData`). Update `AccountDisclosureGroup.highestUtilization`, `UsageManager.worstCaseUtilization`, and `UsageManager.statusEmoji` to use it. Verify status bar reflects sonnet utilization if applicable.

3. **D1 — Lift accordion state:** Modify `AccountList` to hold `@State var expandedEmail: String?`. Modify `AccountDisclosureGroup` to accept `isExpanded: Binding<Bool>`. Verify exclusive expand/collapse with 2+ accounts in Previews.

4. **D2 — Compress row height to 48pt:** Update `AccountHeader` from 56pt to 48pt; add `isExpanded: Bool` parameter; hide org name in collapsed state. Verify at multiple account counts in Previews.

5. **D3 — Compress footer for multi-account mode:** Add `compressedFooterView()` to `UsageView`. Update the conditional in `body` to use it when `manager.accounts.count > 1`. Verify single-account mode is unchanged.

6. **Update `computePopoverHeight()`:** Update `AppDelegate.computePopoverHeight()` with the corrected constants (48pt rows, 48pt compressed footer). Use the formula from RF1.

7. **D5 — File extraction:** Extract each file group from the now-refactored `UsageView.swift`. Verify build succeeds after each file extraction before proceeding to the next.

8. **Xcode project file update:** Add the new files to the `ClaudeUsage` target in Xcode via "Add Files to ClaudeUsage…". Verify the build target includes all new files. Commit the `.pbxproj` change in isolation.

### Affected Files

| File | Change |
|------|--------|
| `ClaudeUsage/UsageView.swift` | D1 accordion state lift, D2 row height, D3 compressed footer, D6 `colorForPercentage` removal; shrinks from 718 lines to ~120 lines after D5 extraction |
| `ClaudeUsage/UsageManager.swift` | D4: add `bottleneck` to `UsageData`; update `worstCaseUtilization`, `statusEmoji` |
| `ClaudeUsage/ClaudeUsageApp.swift` | Update `computePopoverHeight()` with new constants (D2, D3) |
| `ClaudeUsage/AccountList.swift` | New file (D5): `AccountList` with lifted accordion state |
| `ClaudeUsage/AccountRow.swift` | New file (D5): `AccountDisclosureGroup`, `AccountHeader` |
| `ClaudeUsage/AccountDetail.swift` | New file (D5): live and stale detail views |
| `ClaudeUsage/UsageRow.swift` | New file (D5): `UsageRow`, `UsageRowStyle`, `formatTimeRemaining` |
| `ClaudeUsage/SharedStyles.swift` | New file (D6 + D5): `Color.forUtilization`, `LiveIndicator`, `CachedBadge`, `StaleBadge` |
| `ClaudeUsage.xcodeproj/project.pbxproj` | Add 5 new source files to `ClaudeUsage` target (D5) |

### Migration Strategy

No data migration is required. This ADR touches only view layer and `UsageData` computed properties. `AccountRecord` and `AccountUsage` structs are unchanged. UserDefaults content is unchanged. The 60s polling loop and `TaskGroup` refresh are unchanged. The only user-visible behavioral change is sonnet inclusion in utilization (D4), which should be documented in release notes.

SwiftUI view state (`expandedEmail`) is ephemeral; it is not persisted and does not require migration.

### Rollback Plan

Rollback is a revert of the ADR-002 implementation PR(s). Because this ADR makes no data model or persistence changes, rollback has no UserDefaults cleanup requirement. If Step 7 (file extraction) and Step 8 (Xcode project) are committed as an isolated final commit, rollback can target that commit specifically if the build system changes are the only problem.

### Success Metrics

- Three accounts collapsed fit within the popover without overflow (verify at 3, 4, 5 accounts).
- Expanding one accordion row collapses any previously expanded row.
- Status bar reflects sonnet utilization when it exceeds session and weekly percentages.
- Single-account mode is visually identical to v1.7 (pixel comparison acceptable).
- All new files are under 150 lines.
- `colorForPercentage` has exactly one definition in the codebase.
- No ACL keychain dialog reappears (no changes to token reading path).

---

## References

- ADR-001: `docs/adr/ADR-001-multi-account-support.md` — D5 (UI Strategy), R5 (no automated tests), R6 (popover height)
- Conceptualize process log: `docs/impl/PROCESS-compact-multi-account-swift-ui-2026-03-01.md`
- Conceptualize stats: `docs/designs/STATS-compact-multi-account-swift-ui-2026-03-01.json`
- `ClaudeUsage/UsageView.swift` — Current monolith (718 lines, 11 view types)
- `ClaudeUsage/UsageManager.swift` — Current `worstCaseUtilization` and `statusEmoji` implementations
- `ClaudeUsage/ClaudeUsageApp.swift` — Current `computePopoverHeight()` implementation
