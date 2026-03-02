# UI/UX Design Specification: Compact Multi-Account SwiftUI
**Date:** 2026-03-02
**Status:** Draft
**Deciders:** Design team (design-architect, ux-designer, ui-designer, platform-specialist, design-writer)
**ADR References:** ADR-002 (primary), ADR-001 (data model constraints)

---

## 1. Overview

### Problem Statement

The Phase C/D multi-account UI (v1.9, per ADR-001) uses per-row independent expand/collapse state, a 56pt collapsed row height, and a full-height footer in all modes. This combination causes visual overflow and wasted space when three or more accounts are present — a realistic scenario for personal + work + contractor users.

ADR-002 resolves six structural problems through six decisions (D1–D6):

| Decision | Problem Solved |
|----------|---------------|
| D1: Exclusive accordion via lifted state | Per-row independent state overflows ScrollView at 3+ accounts |
| D2: 48pt compact collapsed rows | 56pt rows waste 24pt per 3-account view |
| D3: 48pt compressed footer (multi only) | Full ~100pt footer consumes space needed for account rows |
| D4: `bottleneck` computed property | Sonnet exclusion from utilization was an undocumented oversight |
| D5: File decomposition (6 files) | 718-line monolith impedes maintenance |
| D6: `colorForPercentage` deduplication | Identical implementations will diverge on threshold changes |

### Design Goals

1. Three accounts fit comfortably in the popover without overflow.
2. Single-account mode is pixel-identical to v1.7 — no visual regression.
3. Status bar reflects true bottleneck including sonnet utilization.
4. Gear menu provides settings access without consuming fixed vertical space.
5. All new files remain under 150 lines.
6. Zero new Swift package dependencies introduced.

---

## 2. Target Platform

| Attribute | Value |
|-----------|-------|
| Platform | macOS 13.0+ (Ventura and later) |
| UI Framework | SwiftUI inside NSPopover |
| Process type | `.accessory` (no Dock icon) |
| Popover width | 280pt (fixed) |
| Popover max height | 480pt (NSPopover constraint) |
| Deployment target | macOS 13.0 — no `#available` guards required |
| Available APIs | `SMAppService`, `SwiftUI.Menu`, `DisclosureGroup(isExpanded:content:label:)` |

---

## 3. User Personas

### Persona 1: Solo Developer (Primary)

**Profile:** Single Claude Code account. Checks the app dozens of times per day for 2-second glance checks. Relies on the status bar color and percentage.

**Goals:**
- Instant at-a-glance status from the menu bar icon.
- One-tap popover open for detailed three-gauge view.
- Zero friction — no new UI concepts to learn.

**Constraint:** Any visual regression from v1.7 is unacceptable. Single-account mode MUST be pixel-identical to v1.7.

---

### Persona 2: Multi-Account Professional (Target)

**Profile:** 2–3 accounts (personal + work). Switches contexts 1–5 times per day. Needs to identify which account is closest to a rate limit and whether data is live or stale.

**Goals:**
- Scan collapsed rows to identify utilization hotspots quickly.
- Expand the critical account to see detailed gauges.
- Understand at a glance whether each account's data is live or stale.

**Constraint:** Must fit 3 accounts comfortably, 4–5 with scroll, 6+ gracefully degraded. Only one account expanded at a time. On first launch (before first poll completes), accounts with no usage data show 0% — this is expected and acceptable.

---

### Persona 3: Power User / Contractor

**Profile:** 4–6 accounts across multiple organizations. Encounters edge cases: all-collapsed, multiple stale accounts, frequent context switches.

**Goals:**
- Scrollable list remains usable at 5+ accounts.
- Gear menu accessible without hunting.
- Stale badge meaning is clear without documentation.

**Constraint:** Usable with scroll at 5+ accounts. Gear menu must not feel hidden.

---

## 4. User Journeys

### Journey 1: Glance Check (all personas, 10+/day)

**Entry:** Status bar icon visible in menu bar.
**Flow:**
1. User glances at status bar icon color (green / orange / red).
2. User reads the percentage in the icon label.
3. Bottleneck includes sonnet — icon reflects true rate-limit proximity (D4).
4. No popover interaction required.

**Exit:** User returns to work.

**Design note:** D4 ensures the status bar reflects sonnet utilization when it exceeds session/weekly. A user at 95% sonnet with low session/weekly now correctly sees red rather than green.

---

### Journey 2: Detailed Usage Check (Persona 1, 3–5/day)

**Entry:** User clicks menu bar icon.
**Flow:**
1. Popover opens. Single-account layout renders (unchanged from v1.7).
2. User reads three usage gauges: session, weekly, sonnet-only.
3. User closes popover.

**Exit:** Popover dismissed.

**Design note:** Single-account conditional path is entirely unchanged. No new UI components are encountered.

---

### Journey 3: Multi-Account Triage (Persona 2–3, 1–3/day)

**Entry:** User clicks menu bar icon.
**Flow:**
1. Popover opens. AccountList renders with collapsed rows.
2. Live account is auto-expanded on `onAppear`.
3. User scans collapsed row headers for utilization percentages and badges.
4. User identifies high-utilization account (e.g., 87%).
5. User clicks that account's row header to expand it.
6. Previously expanded account collapses (exclusive accordion, D1).
7. User reads detailed gauges for high-utilization account.
8. User closes popover.

**Exit:** Popover dismissed. Expanded state resets; live account re-expands on next open.

**Design note:** All-collapsed is a valid state (D1). No snap-back. User intent is respected.

---

### Journey 4: Settings Access (Persona 2–3, infrequent)

**Entry:** User is in multi-account mode with popover open.
**Flow:**
1. User locates gear icon in compressed footer (bottom-right).
2. User clicks gear icon — SwiftUI.Menu renders as native NSMenu.
3. User selects "Check for Updates" or "Launch at Login".
4. Menu dismisses.

**Exit:** Action taken. Popover remains open.

**Design note:** Gear menu discoverability is a known UX risk (R4 from UX expert). Icon placement at bottom-right follows macOS convention for secondary controls. Tooltip may assist discoverability (deferred, not D1-D6 scope).

---

### Journey 5: Account Switch Detection (automatic)

**Entry:** User switches Claude Code accounts externally.
**Flow:**
1. 60-second polling detects token change.
2. `UsageManager` calls `/api/oauth/profile` for new identity.
3. `accounts` array updated — new live account added, previous marked stale.
4. AccountList re-renders with updated badges and utilization.

**Exit:** No user action required. Transition is silent and automatic.

**Design note:** Implemented per ADR-001 Phase A/B. No UI change required for this journey in ADR-002 scope.

---

## 5. Visual Design

### 5.1 Three-Zone Layout

The popover is divided into three vertical zones:

```
┌─────────────────────────────┐
│  HEADER ZONE   (~44pt)      │  App title / branding
├─────────────────────────────┤
│                             │
│  CONTENT ZONE  (variable)   │  ScrollView → AccountList accordion
│                             │
├─────────────────────────────┤
│  FOOTER ZONE   (48/100pt)   │  Multi: compressed footer  Single: full footer
└─────────────────────────────┘
```

- **Header Zone:** Fixed ~44pt. App title, update banner if applicable.
- **Content Zone:** `ScrollView` wrapping `AccountList`. Height computed by `computedScrollHeight`. ScrollView activates at 5+ accounts.
- **Footer Zone:** 48pt in multi-account mode (D3). ~100pt full footer in single-account mode (unchanged from v1.7).

### 5.2 Height Budget Formula

Based on ADR-002 RF1, the popover height formula after D2 and D3:

```
headerHeight       = 44pt
footerHeight       = 48pt  (multi-account)  |  100pt (single-account)
expandedRowHeight  = 228pt  (48pt header + ~180pt detail)
collapsedRowHeight = 48pt

height = headerHeight + footerHeight + 1 × expandedRowHeight + (N−1) × collapsedRowHeight
       = 44 + 48 + 228 + (N−1) × 48
```

| Accounts (N) | Formula | Total | Fits 480pt cap? |
|:---:|---|:---:|:---:|
| 1 | Single-account layout | ~320pt | Yes |
| 2 | 44 + 48 + 228 + 48 | 368pt | Yes |
| 3 | 44 + 48 + 228 + 96 | 416pt | Yes |
| 4 | 44 + 48 + 228 + 144 | 464pt | Yes |
| 5 | 44 + 48 + 228 + 192 | 512pt → capped | ScrollView |
| 6+ | Capped at 480pt | 480pt | ScrollView |

`computedScrollHeight` uses: `min(expanded + (N-1) × collapsed, 380)` where the 380pt ceiling is a conservative approximation: 480pt total minus the fixed header zone and a buffer for the update banner when visible. The exact banner height is not fixed; 380pt was validated empirically with 2–6 accounts. Do not change this constant without re-validating overflow at N=3 and N=5.

**Note — two separate height computations:** `computedScrollHeight` (in `AccountList`) sizes the `ScrollView` frame within the popover. `computePopoverHeight()` (in `AppDelegate`/`ClaudeUsageApp.swift`) sets `NSPopover.contentSize`. These are different values. See §8 Step 6 for the `computePopoverHeight()` implementation.

### 5.3 Design Tokens

#### Colors

| Token | Value | Usage |
|-------|-------|-------|
| `Color.forUtilization(pct)` — green | `#34C759` (system `.green`) | 0–69% utilization |
| `Color.forUtilization(pct)` — orange | `#FF9F0A` (system `.orange`) | 70–89% utilization |
| `Color.forUtilization(pct)` — red | `#FF3B30` (system `.red`) | 90–100% utilization |
| `Color(NSColor.controlBackgroundColor)` | System semantic | Footer background |
| `.secondary` | System semantic | Org name, timestamps, captions |

**Note on green contrast:** `#34C759` against white at small sizes may not meet WCAG AA. This is a carry-forward concern from v1.9, not in scope for D1–D6.

#### Typography

| Role | Font | Usage |
|------|------|-------|
| Account email | `.headline` | AccountHeader primary label |
| Organization name | `.subheadline` + `.secondary` | AccountHeader secondary label (expanded only) |
| Usage category | `.body` | UsageRow label |
| Timestamps, captions | `.caption` + `.secondary` | Footer timestamp, badge text |

#### Spacing

| Token | Value | Usage |
|-------|-------|-------|
| Base unit | 4pt | Vertical padding in compact rows |
| Gap | 8pt | Horizontal spacing between HStack elements |
| Section padding | 12pt | Horizontal padding in row/footer |
| Edge insets | 16pt | ScrollView outer edges where applicable |

#### Animation

| Token | Value | Usage |
|-------|-------|-------|
| Accordion transition | `withAnimation(.easeInOut(duration: 0.25))` | Expand/collapse state changes |
| Reduce Motion override | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` | Skip animation when enabled |

Both UX and UI experts independently recommended `withAnimation(.easeInOut(duration: 0.25))`. This is a **required** animation for accordion state changes. Platform expert requires a Reduce Motion guard.

**Authoritative location:** The animation and Reduce Motion guard live exclusively in the `Binding` setter inside `AccountList` (see §6.2). No other call site should wrap `expandedEmail` mutations in `withAnimation`. The code is shown in full in §6.2; it is not repeated here to avoid ambiguity.

---

## 6. Component Specifications

### 6.1 UsageView (modified)

**File:** `ClaudeUsage/UsageView.swift`
**Estimated lines after D5 extraction:** ~120

**Responsibilities:**
- Root view orchestrating conditional single-account vs. multi-account layout.
- App header bar.
- Update banner (unchanged).
- `loadingView` and `errorView` states.
- Conditional footer: calls `footerView()` (single) or `compressedFooterView()` (multi).

**Layout logic:**
```swift
if manager.accounts.count <= 1 {
    // single-account path — pixel-identical to v1.7
    singleAccountContent()
    footerView()
} else {
    AccountList(accounts: manager.accounts, onRemoveAccount: ...)
    compressedFooterView()
}
```

**Visual states:**
| State | Behavior |
|-------|----------|
| Loading | `loadingView()` — spinner centered |
| Error | `errorView()` — error message + retry |
| Single account | v1.7 layout unchanged |
| Multi-account | AccountList accordion + compressed footer |

---

### 6.2 AccountList (new)

**File:** `ClaudeUsage/AccountList.swift`
**Estimated lines:** ~60

**Responsibilities:**
- Owns `@State private var expandedEmail: String?` (lifted accordion state, D1).
- Computes `computedScrollHeight` for ScrollView frame.
- Auto-expands live account on `.onAppear`.
- Passes `Binding<Bool>` adapter to each `AccountDisclosureGroup`.

**Props:**
```swift
struct AccountList: View {
    let accounts: [AccountUsage]
    let onRemoveAccount: ((String) -> Void)?
}
```

**State:**
```swift
@State private var expandedEmail: String?
```

**Binding adapter (D1):**
```swift
let binding = Binding<Bool>(
    get: { expandedEmail == email },
    set: { isExpanded in
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            withAnimation(.easeInOut(duration: 0.25)) {
                expandedEmail = isExpanded ? email : nil
            }
        } else {
            expandedEmail = isExpanded ? email : nil
        }
    }
)
```

**Auto-expand:**
```swift
.onAppear {
    // Sets expandedEmail to the live account's email, or nil if no current account — all-collapsed state.
    expandedEmail = accounts.first(where: { $0.isCurrentAccount })?.account.email
}
```

**computedScrollHeight:**
```swift
private var computedScrollHeight: CGFloat {
    let n = CGFloat(accounts.count)
    let expanded: CGFloat = 228
    let collapsed: CGFloat = 48
    let content = expanded + (n - 1) * collapsed
    return min(content, 380)
}
```

**Visual states:**
| State | Behavior |
|-------|----------|
| Default | Live account expanded, others collapsed |
| All-collapsed | `expandedEmail == nil` — valid, no snap-back |
| Scrollable (5+) | ScrollView activates, indicators visible |

**Accessibility:**
- VoiceOver navigates rows via Tab.
- Each row announces email + expanded/collapsed state via `DisclosureGroup`.
- Screen reader reads utilization percentage from collapsed header.

---

### 6.3 AccountDisclosureGroup (modified)

**File:** `ClaudeUsage/AccountRow.swift`
**Estimated lines (with AccountHeader):** ~130

**Responsibilities:**
- Renders one accordion row using `DisclosureGroup(isExpanded:content:label:)`.
- Receives `isExpanded: Binding<Bool>` — no internal `@State` (D1).
- Shows `AccountHeader` as the label.
- Shows `AccountDetail` as the disclosure content.
- Uses `accountUsage.usage?.bottleneck.percentage ?? 0` for utilization (D4).

**Props:**
```swift
struct AccountDisclosureGroup: View {
    let accountUsage: AccountUsage
    let isExpanded: Binding<Bool>   // passed from AccountList; no internal @State
    let onRemove: (() -> Void)?
}
```

**Binding note:** The `@State private var isExpanded` and the custom `init(accountUsage:onRemove:)` in the current source (`UsageView.swift:523–529`) are removed. `DisclosureGroup(isExpanded: isExpanded, ...)` binds directly to the passed binding — no `@Binding` property wrapper, no wrapper synthesis.

**Visual states:**
| State | Behavior |
|-------|----------|
| Collapsed | AccountHeader at 48pt — email, utilization badge, status indicators |
| Expanded | AccountHeader + AccountDetail below |
| Error | Error SF Symbol visible in collapsed header (see 6.4) |
| Stale | `StaleBadge` in header, muted appearance |
| Loading | `CachedBadge` or `LiveIndicator` per current refresh state |
| Current account | `LiveIndicator` in header |

**Accessibility:**
- `DisclosureGroup` provides native VoiceOver: "Expanded" / "Collapsed" state announcement.
- Space or Enter toggles expansion.
- Tab navigates between rows.

---

### 6.4 AccountHeader (modified)

**File:** `ClaudeUsage/AccountRow.swift` (same file as AccountDisclosureGroup)

**Responsibilities:**
- Renders the 48pt collapsed/expanded label area for a disclosure row.
- Conditionally shows organization name only when `isExpanded == true` (D2).
- Shows bottleneck utilization percentage.
- Shows error SF Symbol when account is in error state (UX recommendation).
- Shows `LiveIndicator`, `CachedBadge`, or `StaleBadge` as appropriate.

**Parameter changes from current source (`UsageView.swift:~488`):**
1. `isLive` renamed to `isCurrentAccount` — aligns with `AccountUsage.isCurrentAccount` field name.
2. `isActivelyRefreshing` split: loading state now passed as `isLoading: Bool`; stale state passed as `isStale: Bool` (derived from `accountUsage.usage == nil && !accountUsage.isCurrentAccount` at the call site).
3. `highestUtilization: Int` + `utilizationColor: Color` replaced by single `utilization: Int` — color computed internally via `Color.forUtilization(utilization)`.
4. `lastUpdated: Date?` retained — used for VoiceOver accessibility label on stale accounts (see Accessibility below).

**Props:**
```swift
struct AccountHeader: View {
    let email: String
    let organizationName: String?
    let isExpanded: Bool          // new parameter (D2)
    let utilization: Int          // from bottleneck
    let isCurrentAccount: Bool
    let isLoading: Bool
    let hasError: Bool            // for error SF Symbol; derived from AccountUsage.error != nil
    let isStale: Bool
    let lastUpdated: Date?        // for stale accessibility label
}
```

**`hasError` data source:** Set to `true` when `accountUsage.error != nil`. This is the `error: String?` field on `AccountUsage` (ADR-001 D2). `hasError` and `isStale` can both be true simultaneously (e.g., a previously stale account that also produced an error on the last refresh attempt). See indicator priority table below.

**Status indicator priority (right-side of collapsed header):**

Only one badge/indicator is shown at a time from the status slot. The error SF Symbol is shown in a separate position and is independent of the badge slot. Priority from highest to lowest:

| Priority | Condition | Badge slot | Error symbol shown? |
|----------|-----------|------------|---------------------|
| 1 | `isStale == true` | `StaleBadge` | Yes, if `hasError` also true |
| 2 | `isLoading == true` | `CachedBadge` | Yes, if `hasError` also true |
| 3 | `isCurrentAccount == true` | `LiveIndicator` | Yes, if `hasError` also true |
| 4 | None of the above | (empty) | Yes, if `hasError` also true |

The error SF Symbol (`exclamationmark.triangle.fill`) always renders when `hasError == true`, regardless of which badge is showing. It appears between the `Spacer()` and the badge slot. This ensures error visibility even in stale or loading states.

**Layout (D2):**
```swift
HStack(spacing: 8) {
    VStack(alignment: .leading, spacing: 2) {
        Text(email)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
        if isExpanded, let org = organizationName {
            Text(org)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
    Spacer()
    // Error SF Symbol — shown independently of badge slot (UX recommendation)
    if hasError {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
    }
    // Status badge slot — mutually exclusive, highest-priority wins
    if isStale {
        StaleBadge()
    } else if isLoading {
        CachedBadge()
    } else if isCurrentAccount {
        LiveIndicator()
    }
    // Utilization percentage
    Text("\(utilization)%")
        .font(.caption)
        .foregroundColor(Color.forUtilization(utilization))
}
.frame(height: 48)           // reduced from 56pt (D2)
.padding(.horizontal, 12)
.padding(.vertical, 4)       // reduced from 8pt (D2)
```

**Visual states:**
| State | Collapsed Appearance |
|-------|---------------------|
| Default (live) | Email, LiveIndicator, utilization% |
| Expanded | Email + org name, LiveIndicator, utilization% |
| Error only | Email, exclamationmark.triangle.fill, utilization% |
| Stale | Email, StaleBadge, utilization% |
| Stale + Error | Email, exclamationmark.triangle.fill, StaleBadge, utilization% |
| Loading | Email, CachedBadge, utilization% |
| Loading + Error | Email, exclamationmark.triangle.fill, CachedBadge, utilization% |

**Email truncation note (UI risk R3):** At 280pt width with 12pt horizontal padding each side = 256pt usable. Email + badges + percentage consume ~100pt right-side. Email label has ~156pt. `.lineLimit(1)` + `.truncationMode(.tail)` handles long emails.

**Accessibility:**
- `accessibilityLabel` is set explicitly to combine email, status, and utilization. `DisclosureGroup` appends "Expanded"/"Collapsed" automatically — do not duplicate this in the label.
- **Live account:** `"\(email), \(utilization)%, Live"`
- **Stale account:** `"\(email), Stale, \(utilization)%, last updated \(lastUpdated?.formatted(.relative(presentation: .named)) ?? "unknown")"`
- **Loading account:** `"\(email), \(utilization)%, Loading"`
- **Error state:** prefix with "Error — " before the status label: e.g., `"Error — \(email), \(utilization)%, Live"`

---

### 6.5 AccountDetail (new)

**File:** `ClaudeUsage/AccountDetail.swift`
**Estimated lines:** ~90

**Responsibilities:**
- Renders the expanded disclosure content for an account row.
- Branches on `accountUsage.isCurrentAccount` and staleness to show `liveAccountDetail` or `staleAccountDetail`.
- Shows three `UsageRow` gauges: session, weekly, sonnet-only.

**Props:**
```swift
struct AccountDetail: View {
    let accountUsage: AccountUsage
}
```

**Branch condition:**
```swift
if accountUsage.isCurrentAccount || accountUsage.isActivelyRefreshing {
    liveAccountDetail(accountUsage)
} else {
    staleAccountDetail(accountUsage)
}
```

**Stale color token:** Stale gauge bars and text use `Color(NSColor.secondaryLabelColor)` (system semantic muted color). Stale rows also set `resetsAt: nil` for any reset-time display — no reset time is shown for stale accounts.

**Visual states:**
| State | Content |
|-------|---------|
| Live (current account) | Three UsageRow gauges, last updated timestamp |
| Actively refreshing | Three UsageRow gauges + `ProgressView` spinner with "Loading…" caption (carried forward from current source unchanged — in scope) |
| Stale | Three UsageRow gauges muted with `Color(NSColor.secondaryLabelColor)`, StaleBadge, last updated timestamp, `resetsAt: nil` |

**Accessibility:**
- UsageRow gauges have accessible labels describing category and percentage.
- Organization name appears here in expanded state (via AccountHeader conditional).
- Stale gauges include "Stale data" in their accessibility label prefix.

---

### 6.6 compressedFooterView() (new)

**File:** `ClaudeUsage/UsageView.swift` (method on UsageView)

**Responsibilities:**
- Renders the 48pt multi-account footer (D3).
- Contains: last-updated timestamp, gear menu (Check for Updates, Launch at Login), refresh button, globe button, quit button.
- Uses `SwiftUI.Menu` + `.menuStyle(.borderlessButton)` mapping to native NSMenu.

**Layout:**
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

**Display name omission:** `manager.displayName` is intentionally omitted from the compressed footer. In multi-account mode, each account's display name is accessible via the expanded detail view. The compressed footer shows only action controls (gear, refresh, globe, quit) and the timestamp.

**Footer boundary (UI risk R1 — HIGH):**
Do NOT add an explicit `Divider()` above the compressed footer. The `ScrollView` natural bottom boundary serves as the visual separator. Adding an explicit divider causes a double-divider artifact. Only a single visual divider should appear at the footer boundary:

```swift
// Correct:
AccountList(...)
compressedFooterView()

// Incorrect — produces double divider:
AccountList(...)
Divider()   // <-- remove this
compressedFooterView()
```

**Visual states:**
| State | Behavior |
|-------|----------|
| Default | Timestamp (left), gear/refresh/globe/quit icons (right) |
| Loading | Refresh button disabled |
| No timestamp | Timestamp area empty, icons remain |

**Accessibility:**
- Gear icon: `accessibilityLabel("Settings")`.
- Refresh icon: `accessibilityLabel("Refresh")`.
- Globe icon: `accessibilityLabel("Open Claude.ai")`.
- Quit icon: `accessibilityLabel("Quit")`.

---

### 6.7 UsageData.bottleneck (new computed property)

**File:** `ClaudeUsage/UsageManager.swift`

**Responsibilities:**
- Single authoritative source for highest utilization across session, weekly, and sonnet (D4).
- Used by: `AccountDisclosureGroup`, `UsageManager.worstCaseUtilization`, `UsageManager.statusEmoji`.

**Implementation:**
```swift
extension UsageData {
    /// The highest-utilization category across all available metrics.
    /// Includes sonnet — a deliberate change from prior implementations that excluded it.
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

**Behavioral change — sonnet inclusion (D4):** Prior implementations computed `max(session, weekly)`, silently omitting sonnet. This was an oversight. After D4, a user at 95% sonnet / 20% session / 20% weekly correctly sees red in the status bar. Release notes must call this out.

**Updated dependents:**
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

Both `worstCaseUtilization` and `statusEmoji` delegate through `bottleneck` — neither performs its own `max` computation. The prior inline `max(sessionUtilization, weeklyUtilization)` in `statusEmoji` is removed.

---

### 6.8 Color.forUtilization (new, deduplicated)

**File:** `ClaudeUsage/SharedStyles.swift`

**Responsibilities:**
- Single canonical implementation of utilization-to-color mapping (D6).
- Replaces both `colorForPercentage` implementations in `UsageView.swift`.

**Implementation:**
```swift
extension Color {
    static func forUtilization(_ percentage: Int) -> Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .green
    }
}
```

**Call sites after migration:** `Color.forUtilization(pct)` — replaces `colorForPercentage(pct)`.

---

### 6.9 SharedStyles.swift (new)

**File:** `ClaudeUsage/SharedStyles.swift`
**Estimated lines:** ~70

**Contents:**
- `Color.forUtilization(_:)` extension (D6).
- `LiveIndicator` view (moved from UsageView.swift, no changes).
- `CachedBadge` view (moved, no changes).
- `StaleBadge` view (moved, no changes).

---

## 7. File Decomposition Plan

Target: 6 focused files, all under 150 lines (D5).

| File | Contents | Est. Lines | Change Type |
|------|----------|:---:|------------|
| `UsageView.swift` | Root view, conditional layout, app header, update banner, single-account content, `loadingView`, `errorView`, `compressedFooterView()` | ~120 | Modify (shrink from 718) |
| `AccountList.swift` | `AccountList` with lifted `expandedEmail` state, `computedScrollHeight` | ~60 | New |
| `AccountRow.swift` | `AccountDisclosureGroup`, `AccountHeader` | ~130 | New |
| `AccountDetail.swift` | `liveAccountDetail`, `staleAccountDetail` | ~90 | New |
| `UsageRow.swift` | `UsageRow`, `UsageRowStyle`, `formatTimeRemaining` | ~80 | New |
| `SharedStyles.swift` | `Color.forUtilization`, `LiveIndicator`, `CachedBadge`, `StaleBadge` | ~70 | New |

**Xcode project note:** New files must be added via Xcode's "Add Files to ClaudeUsage…" UI (or equivalent tooling). Manual `.pbxproj` editing is prohibited — UUID generation errors cause build failures. This step is performed last (Step 8 of implementation ordering) to minimize conflict risk.

---

## 8. Implementation Ordering

Eight-step sequence minimizing regression risk (from ADR-002):

| Step | Decision | Action | Verification |
|------|----------|--------|--------------|
| 1 | D6 | Create `SharedStyles.swift` containing **only** `Color.forUtilization` (the `extension Color` block). Replace both `colorForPercentage` call sites in `UsageView.swift`. `LiveIndicator`, `CachedBadge`, and `StaleBadge` remain in `UsageView.swift` at this step — they move to `SharedStyles.swift` in Step 7. | SwiftUI Previews. Build succeeds. Zero usages of `colorForPercentage` remain. |
| 2 | D4 | Add `bottleneck` to `UsageData` in `UsageManager.swift`. Update `worstCaseUtilization` and `statusEmoji`. Update `AccountDisclosureGroup.highestUtilization`. | Status bar reflects sonnet when applicable. Previews look correct. |
| 3 | D1 | Lift `expandedEmail` to `AccountList`. Modify `AccountDisclosureGroup` to accept `Binding<Bool>`. Add animation + Reduce Motion guard. | Exclusive expand/collapse with 2+ accounts in Previews. |
| 4 | D2 | Update `AccountHeader`: 56pt → 48pt, add `isExpanded` param, hide org name when collapsed. | Verify at 2, 3, 4 accounts in Previews. Collapsed row is 48pt. |
| 5 | D3 | Add `compressedFooterView()`. Update conditional in `UsageView.body`. Verify single-account mode unchanged. | Single-account Previews unchanged. Multi-account shows 48pt footer. No double-divider. |
| 6 | — | Update `computePopoverHeight()` in `ClaudeUsageApp.swift` with new constants. See implementation below. | NSPopover contentSize matches height formula in §5.2 for N=2,3,4,5. |
| 7 | D5 | Extract files from refactored `UsageView.swift` in this order: (a) move `LiveIndicator`, `CachedBadge`, `StaleBadge` into `SharedStyles.swift` (completing it); (b) extract `AccountList` → `AccountList.swift`; (c) extract `AccountDisclosureGroup` + `AccountHeader` → `AccountRow.swift`; (d) extract detail views → `AccountDetail.swift`; (e) extract `UsageRow` → `UsageRow.swift`. Verify build after each extraction. | Build succeeds after each file. All files under 150 lines. |
| 8 | D5 | Add new files to Xcode target via Xcode UI. Commit `.pbxproj` in isolation. | Full build and run. No missing target membership errors. |

### Step 6 Detail: Updated `computePopoverHeight()` Implementation

`computePopoverHeight()` in `ClaudeUsageApp.swift` (AppDelegate) sets `NSPopover.contentSize`. It is separate from `computedScrollHeight` in `AccountList`, which sizes the ScrollView frame only.

Updated implementation using the constants from §5.2:

```swift
private func computePopoverHeight() -> CGFloat {
    let accounts = usageManager.accounts
    guard accounts.count > 1 else { return 320 }

    let headerHeight: CGFloat = 44
    let footerHeight: CGFloat = 48       // compressed footer (D3)
    let expandedRowHeight: CGFloat = 228 // 48pt header + ~180pt detail (D2)
    let collapsedRowHeight: CGFloat = 48 // (D2)

    // Exclusive accordion: always exactly 1 expanded + (N-1) collapsed (D1)
    let n = CGFloat(accounts.count)
    let total = headerHeight + footerHeight + expandedRowHeight + (n - 1) * collapsedRowHeight
    return min(max(total, 200), 480)
}
```

**Verification note:** Formula matches §5.2 height budget table. Old constants (56pt, 236pt, 144pt, multi-expanded formula) are removed. The `min(max(total, 200), 480)` clamp applies a 200pt floor (guards against degenerate 0-account state) and the 480pt NSPopover hard cap.

---

## 9. Interaction Patterns

### 9.1 Exclusive Accordion

Only one account row can be expanded at a time. Expanding row A automatically collapses any previously expanded row B.

- Mechanism: `@State var expandedEmail: String?` in `AccountList`. Setting it to a new email collapses the old.
- Animation: `withAnimation(.easeInOut(duration: 0.25))` wraps state change.
- Reduce Motion: state change happens without animation when system preference is enabled.
- **Animation placement:** The animation is applied inside the `Binding<Bool>` setter in `AccountList` (see §6.2 binding adapter code). Do not apply `withAnimation` at the `DisclosureGroup` call site — this would animate the disclosure independently from the exclusive-collapse of the previously expanded row, producing a visual mismatch between the two rows.

### 9.2 Auto-Expand on Open

When the popover opens (NSPopover presents → SwiftUI view hierarchy created):

- `AccountList.onAppear` sets `expandedEmail` to the live (current) account's email.
- If no current account exists, `expandedEmail` remains `nil` (all-collapsed state).

### 9.3 All-Collapsed Validity

All-collapsed (`expandedEmail == nil`) is a valid and intentional state. If the user collapses the last expanded row:

- No snap-back or forced re-expansion occurs.
- All rows show collapsed 48pt headers.
- User can expand any row by clicking.

Rationale: forcing re-expansion after explicit collapse fights user intent and creates unexpected visual jumps.

### 9.4 Expanded State Reset on Dismiss

When the popover closes, SwiftUI destroys and recreates the `AccountList` view hierarchy. `expandedEmail` resets to `nil`. `onAppear` re-expands the live account on next open.

This is documented intentional behavior, not a bug. Persisting expanded state across popover sessions requires `@AppStorage`, adding complexity for negligible user benefit. Deferred to a future enhancement.

### 9.5 Gear Menu Interaction

- Rendered via `SwiftUI.Menu` + `.menuStyle(.borderlessButton)`.
- Maps to native `NSMenu` on macOS — avoids nested NSPopover issues.
- Tapping gear opens menu above the footer.
- Menu items: "Check for Updates", divider, "Launch at Login" toggle.
- Menu dismisses on item selection or click-away.

---

## 10. Risk Mitigations

Consolidated from UX, UI, and Platform expert analyses plus ADR-002.

| ID | Severity | Source | Risk | Design Mitigation |
|----|----------|--------|------|-------------------|
| R-UI-1 | HIGH | UI Expert | Double-divider at footer boundary | Remove explicit `Divider()` above footer; use ScrollView natural boundary only. See §6.6. |
| R-UI-2 | MEDIUM | UI Expert | `computePopoverHeight()` constants diverge from actual layout | Sync with height formula in §5.2; document constants in code comments. |
| R-UI-3 | MEDIUM | UI Expert | Email truncation at 280pt in collapsed row | `.lineLimit(1)` + `.truncationMode(.tail)` enforced in AccountHeader spec. |
| R-UX-1 | MEDIUM | UX Expert | Collapsed error state ambiguity in 48pt row | Error SF Symbol (`exclamationmark.triangle.fill`) in collapsed AccountHeader. See §6.4. |
| R-UX-2 | MEDIUM | UX Expert | Sonnet behavioral change confusion | Document in release notes: "Status bar now reflects sonnet-only utilization." See §6.7 note. |
| R-UX-3 | MEDIUM | UX Expert | All-collapsed state confusing for first-time users | Live account auto-expands on `onAppear`. All-collapsed is reachable only by explicit user action. |
| R-P-1 | MEDIUM | Platform | NSPopover contentSize updates may not animate smoothly | Use `NSPopover.contentSize` updates within animation block. Test on macOS 13, 14, 15. |
| R-P-2 | MEDIUM | Platform | DisclosureGroup animation timing conflicts with popover resize | Test Binding adapter animation on macOS 13+; verify no conflict with NSPopover resize. |
| R-ADR-RF1 | MEDIUM | ADR-002 | Popover height formula does not track accordion state dynamically | Use conservative fixed formula (1 expanded + N-1 collapsed) with 480pt cap as safety bound. |
| R-ADR-RF4 | MEDIUM | ADR-002 | Sonnet inclusion is an undocumented prior behavior change | Explicit release notes callout required. |
| R-ADR-RF5 | MEDIUM | ADR-002 | No automated tests | SwiftUI Previews are minimum validation gate. `bottleneck` is a strong unit test candidate if test infrastructure is added in a future sprint — it is pure (no side effects, no dependencies) and covers the sonnet-inclusion behavioral change. Snapshot testing requires a new dependency (`swift-snapshot-testing`), which violates the zero-dependency constraint. |
| R-UX-4 | LOW | UX Expert | Gear icon discoverability | Standard bottom-right macOS convention. Tooltip deferred (not in D1-D6 scope). |
| R-UX-5 | LOW | UX Expert | Stale badge meaning unclear | `StaleBadge` label and color provide context; tooltip deferred. |
| R-UX-6 | LOW | UX Expert | No onboarding for multi-account features | Out of scope. Deferred. |
| R-P-3 | LOW | Platform | Menu keyboard shortcuts | Native NSMenu handles keyboard navigation automatically via SwiftUI.Menu. |
| R-UI-4 | LOW | UI Expert | Gear icon sizing | Use `Image(systemName: "gearshape")` with `.menuStyle(.borderlessButton)` + `.fixedSize()` per spec. |
| R-ADR-RF2 | LOW | ADR-002 | DisclosureGroup Binding adapter animation behavior differs from internal @State | Verify with SwiftUI Preview and on-device testing before shipping. |
| R-ADR-RF3 | LOW | ADR-002 | `Menu` requires macOS 12+; deployment target is macOS 13+ | No guard needed — deployment target already macOS 13 per scope. |

---

## 11. Acceptance Criteria

Testable criteria for each decision:

### D1: Exclusive Accordion
- [ ] Expanding account A collapses any currently expanded account B.
- [ ] All-collapsed state is reachable and stable (no snap-back).
- [ ] `onAppear` expands the live (current) account automatically.
- [ ] Popover dismiss + reopen resets to live account expanded.
- [ ] Animation plays at 0.25s easeInOut (unless Reduce Motion is enabled).
- [ ] When Reduce Motion is enabled, state change is instant with no animation.
- [ ] When no current account exists (e.g., first launch, all accounts stale), popover opens in all-collapsed state with no crash or snap-back.

### D2: 48pt Compact Collapsed Rows
- [ ] Collapsed row height is exactly 48pt.
- [ ] Organization name is hidden when row is collapsed.
- [ ] Organization name is visible when row is expanded.
- [ ] Email is visible in both collapsed and expanded states.
- [ ] Row is clickable with a comfortable target at 48pt height.

### D3: 48pt Compressed Footer (Multi-Account)
- [ ] Multi-account mode shows 48pt footer.
- [ ] Single-account mode shows full ~100pt footer unchanged from v1.7.
- [ ] Gear icon opens a menu with "Check for Updates" and "Launch at Login".
- [ ] Refresh, globe, and quit buttons are present and functional.
- [ ] No double-divider visible at footer boundary.
- [ ] Footer height is 48pt (measured).

### D4: `bottleneck` Computed Property
- [ ] `bottleneck.percentage` returns the highest of session, weekly, and sonnet.
- [ ] Status bar reflects orange when sonnet exceeds 70% and session/weekly are below 70%.
- [ ] Status bar reflects red when sonnet exceeds 90%.
- [ ] `worstCaseUtilization` returns the sonnet percentage when sonnet is the highest value across all active accounts (e.g., sonnet=80%, session=30%, weekly=40% → returns 80).
- [ ] `statusEmoji` returns "🟡" when sonnet utilization is 75% and session/weekly are both below 70%.
- [ ] `statusEmoji` delegates to `worstCaseUtilization` — no inline `max` computation remains in `statusEmoji`.
- [ ] `bottleneck` is defined exactly once in the codebase.

### D5: File Decomposition
- [ ] All new files are under 150 lines.
- [ ] `UsageView.swift` is under 130 lines after extraction.
- [ ] Build succeeds with all 6 files in the Xcode target.
- [ ] No types are missing or duplicated between files.
- [ ] SwiftUI Previews work for each file independently.

### D6: `colorForPercentage` Deduplication
- [ ] Exactly one definition of the utilization-to-color mapping exists (`Color.forUtilization`).
- [ ] Zero usages of `colorForPercentage` remain in the codebase.
- [ ] Call sites use `Color.forUtilization(pct)` syntax.

### Single-Account Regression
- [ ] Single-account mode is pixel-identical to v1.7 (visual inspection / screenshot comparison).
- [ ] No new UI elements appear in single-account popover.
- [ ] Footer layout in single-account mode is unchanged.

---

## 12. Scope Boundaries

### In Scope (D1–D6)

- Exclusive accordion state via lifted `expandedEmail` (D1).
- 48pt compact collapsed rows with conditional org-name display (D2).
- 48pt compressed footer with gear menu in multi-account mode (D3).
- `UsageData.bottleneck` computed property with sonnet inclusion (D4).
- 6-file decomposition of `UsageView.swift` (D5).
- `colorForPercentage` deduplication to `Color.forUtilization` in `SharedStyles.swift` (D6).
- `computePopoverHeight()` update with new constants.
- Error SF Symbol in collapsed AccountHeader (UX recommendation, within D1 scope as collapsed-row state indicator).
- Reduce Motion guard on accordion animation.
- `withAnimation(.easeInOut(duration: 0.25))` for accordion transitions.

### Deferred / Out of Scope

| Item | Deferral Reason |
|------|----------------|
| Full settings panel | Future ADR — ADR-002 covers gear icon placement only |
| `@AppStorage` for persisted expanded state | Low value; adds persistence coupling to ephemeral UI state |
| Auto-pruning stale accounts (30-day policy) | ADR-001 D6 — deferred to v2 |
| WCAG AA green contrast fix | Carry-forward from v1.9 — not introduced by D1–D6 |
| Snapshot / UI tests | Zero-dependency constraint prevents `swift-snapshot-testing`; no test infra in current codebase |
| Loading skeleton / placeholder in AccountDetail | Low priority; `CachedBadge` provides sufficient state feedback |
| Tooltip for gear icon discoverability | Low priority UX enhancement |
| Stale badge tooltip | Low priority UX enhancement |
| Onboarding for multi-account features | Out of scope |
| `@AppStorage` or UserDefaults schema changes | ADR-001 constraint — schema frozen |
| Data model changes to `AccountRecord` / `AccountUsage` | ADR-001 constraint — fields frozen; only computed properties allowed |

---

*End of specification. Written from scope analysis (design-architect) and expert analyses (ux-designer, ui-designer, platform-specialist). Cross-referenced against ADR-002 and ADR-001.*
