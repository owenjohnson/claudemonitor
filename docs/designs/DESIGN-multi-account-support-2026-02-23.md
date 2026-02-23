# UI/UX Design Specification: Multi-Account Support

**Date:** 2026-02-23
**Status:** Draft
**Feature:** Multi-Account Support (v1.8)
**ADR Reference:** ADR-001-multi-account-support.md
**Platform:** macOS 13+ menubar app (NSPopover, SwiftUI)

---

## Overview

This specification defines the UI/UX requirements for adding multi-account support to the ClaudeUsage macOS menubar application. The feature allows users who work across multiple Claude Code accounts — personal and organizational — to see usage history for each account without switching between them manually.

The defining constraint of this feature is architectural: macOS stores exactly one Claude Code credential in the keychain at any time. When a user authenticates as a different account, the previous credential is overwritten. This means "multi-account" in this application does not mean concurrent live monitoring of N accounts. It means one live account with a valid token, alongside N-1 historical accounts showing their last-known usage data marked as stale. This distinction is not a limitation to be hidden; it is a fact that must be communicated clearly and consistently throughout the interface.

The design must satisfy three tiers of users simultaneously: single-account users who should see zero visual or behavioral change, multi-account users who need to read and reason about both live and stale data, and power users who understand the technical constraint and appreciate the honest staleness signaling. The single-account pixel-identical guarantee and the multi-account DisclosureGroup accordion approach are both load-bearing decisions from the ADR that this specification operationalizes.

---

## User Personas

### Persona 1: Maya — Freelance Developer, Dual-Account User

**Context:** Maya works for two separate organizations, each with its own Claude Code subscription. She switches her active account roughly twice per day by running `claude auth login` in the terminal.

**Goals:**
- Know whether she is approaching usage limits on either account before starting a long task.
- See at a glance which account is currently active.
- Not be surprised by stale data when she checks her usage after switching accounts.

**Pain Points:**
- Currently has to check usage separately for each account by switching manually.
- Does not always remember which account she last used, leading to confusion about which limit she is monitoring.
- Needs instant orientation when she opens the popover: which account is live right now?

**Technical Literacy:** High. Understands the concept of token expiry and cached data. Will read a "stale" badge and immediately understand its implications.

---

### Persona 2: Carlos — Software Engineer, Single-Account User

**Context:** Carlos uses a single personal Claude Max subscription. He has never authenticated as a second account.

**Goals:**
- Monitor his daily and weekly usage without any friction.
- The app should work exactly as it does today.

**Pain Points:**
- Any new UI complexity added for multi-account users would be noise and clutter for him.
- Feature flags or mode-switching UI would be confusing.

**Technical Literacy:** Medium. Uses the app as a passive monitor, not an active management tool.

**Specification requirement:** Carlos must experience zero visible change after the v1.8 update. The single-account layout must be pixel-identical to the current 280x320pt view.

---

### Persona 3: Priya — Engineering Lead, Multi-Org User

**Context:** Priya manages Claude Code access across three organizational accounts and switches between them several times per week. She uses the app to answer "how much of this org's budget has this session consumed?"

**Goals:**
- See all three accounts in one place without opening multiple tools.
- Understand the age of stale data so she can decide whether it is actionable.
- Manually remove old accounts she no longer uses.

**Pain Points:**
- A stale reading from last week is not useful if she cannot tell it is from last week.
- Confusing live and stale data could cause her to over- or under-budget.
- Accumulation of obsolete account records over time creates visual clutter.

**Technical Literacy:** High. Expects explicit timestamps, not ambiguous "stale" labels alone.

---

## User Flows

### Flow 1: First Launch After Update (Single Account)

1. User updates from v1.7 to v1.8.
2. App launches. UserDefaults is empty (no existing `AccountRecord` entries).
3. Boot delay logic runs: if system uptime < 60s, app waits before accessing keychain.
4. On first 60-second poll tick, app reads keychain via `security` CLI.
5. Token is new (no `lastSeenToken` in memory). App calls `/api/oauth/profile` to get email, display name, and organization.
6. App creates first `AccountRecord`, persists to UserDefaults, marks as `isCurrentAccount: true`.
7. App fetches usage data for the account.
8. **UI renders in single-account mode** (one AccountRecord in UserDefaults). Layout is pixel-identical to v1.7.
9. No visible change from the user's perspective. Menubar button shows same emoji + session percentage format.

**Error state:** If the keychain read fails with `notLoggedIn`, the existing error view ("Not Signed In" + terminal prompt) renders identically to v1.7.

---

### Flow 2: Account Switch Detection (Silent, Background)

1. User switches their active account in Claude Code CLI (`claude auth login`).
2. At the next 60-second poll tick, app reads keychain.
3. App extracts `accessToken` string and compares byte-for-byte against `lastSeenToken` (held in memory only).
4. Token has changed. App calls `/api/oauth/profile` for the new token.
5. Profile returns a new email. App looks up UserDefaults; no matching `AccountRecord` exists.
6. App creates a new `AccountRecord` for the new account. Marks it `isCurrentAccount: true`.
7. Previous `AccountRecord` is updated: `isCurrentAccount` set to `false`.
8. **UI transitions to multi-account mode** (two AccountRecord entries now in UserDefaults).
9. Accordion renders: new (live) account row is default-expanded; previous (stale) account row is default-collapsed.
10. Menubar button title updates to reflect worst-case utilization across both accounts.
11. No confirmation dialog. No notification. Detection is silent and automatic.

**Edge case — same account re-authenticating:** Token changes but profile email matches an existing `AccountRecord`. App updates `lastTokenCapturedAt` on the existing record. No new account row is added. No UI change.

**Edge case — token unchanged:** Profile call is skipped entirely. App uses cached `AccountRecord` from UserDefaults. No network request made.

---

### Flow 3: Viewing Multi-Account Usage (Accordion Interaction)

1. User clicks the menubar button. NSPopover opens with multi-account view.
2. **Current account row** is shown at the top, default-expanded. Live indicator (pulsing green dot + "Live" label) is visible.
3. **Stale account rows** appear below, default-collapsed. Each collapsed row shows: account email, organization name (truncated if needed), StaleBadge (clock icon + "Stale"), and highest utilization percentage for that account at the time it was last updated.
4. User sees the live account's three UsageRow gauges (Session, Weekly, Sonnet Only) inside the expanded row.
5. User taps a collapsed stale account row to expand it.
6. Stale account expands. Its three UsageRow gauges are shown with muted colors (secondary text, reduced opacity). No loading spinner. No refresh action available.
7. A timestamp line reads: "Last updated [relative time] ago" (e.g., "Last updated 2 days ago"). This is a tooltip-style caption, not a badge.
8. User can collapse the live account row and expand a stale row independently. Multiple rows can be expanded simultaneously if space permits (ScrollView handles overflow).
9. Popover height adjusts dynamically as rows expand and collapse, up to the 480pt maximum. Beyond the maximum, the ScrollView becomes scrollable.
10. User dismisses popover by clicking outside (NSPopover.Behavior.transient).

**Accessibility:** VoiceOver announces each DisclosureGroup row as "[email], [Live/Stale], [highest utilization]%" when navigating with keyboard. Expanded state is announced on toggle.

---

### Flow 4: Stale Account Awareness

1. User opens the popover. A stale account is visible.
2. User notices the StaleBadge and muted colors on the stale row's collapsed header.
3. User expands the stale row and reads the timestamp: "Last updated 3 hours ago."
4. User hovers over the usage percentage in the stale row. Tooltip appears: "Data from [absolute datetime]. This account's token is no longer active."
5. **No refresh action is available** for stale accounts. The refresh button in the footer refreshes only the live account.
6. User decides the stale data is too old to be useful. In Phase D, a "Remove account" action will be available. In v1.8 Phase A-C, there is no removal UI; accounts accumulate until the v2 auto-prune feature ships.

**Communication gap (open question OQ-1):** Phase A-C have no account removal UI. The release notes must explicitly state that accounts accumulate and will be pruned automatically in a future version.

---

### Flow 5: No Active Account (KeychainError.notLoggedIn)

1. No active Claude Code token exists in the keychain.
2. If no `AccountRecord` entries exist in UserDefaults: app shows the existing "Not Signed In" error view, pixel-identical to v1.7.
3. If one or more stale `AccountRecord` entries exist: the multi-account accordion renders all accounts as stale. A banner at the top of the content area reads: "No active account. Log in with `claude` to resume live tracking." This replaces the loading spinner in the header.
4. All stale account rows are expanded by default (since there is no live account to give top-of-hierarchy prominence).

---

## Information Architecture

### Content Hierarchy

```
Popover
  Header
    App title + version
    Loading indicator (live account only)
  Update Available Banner (optional)
  Content Area
    [Single-account mode: current layout, unchanged]
    [Multi-account mode:]
      Account List (ScrollView, max 480pt)
        Account Row (DisclosureGroup)
          [Collapsed] Email | Org | LiveIndicator or StaleBadge | Highest utilization %
          [Expanded]  UsageRow: Session
                      UsageRow: Weekly
                      UsageRow: Sonnet Only (if present)
                      Last Updated timestamp (stale accounts only)
  Footer
    Check for Updates button
    Launch at Login toggle
    Divider
    Last updated timestamp | Refresh button | Web button | Quit button
    Divider
    Display name credit
```

### Navigation Model

The popover has a flat, single-level navigation model. There are no subpages, no navigation stack. The accordion is the only navigation affordance. Expanding and collapsing rows does not navigate; it reveals or hides content within the same popover.

### Labeling Conventions

- Account identity: display email address as the primary label. Use `account.displayName` (from `/api/oauth/profile`) as a supplementary label where space permits. Use `account.organizationName` as the secondary label.
- Live indicator label: "Live" (not "Active", "Current", or "Online").
- Stale indicator label: "Stale" (not "Expired", "Inactive", or "Offline").
- Last updated: "Last updated [relative]" in collapsed header tooltip; "Updated [relative] ago" in expanded detail row.
- Worst-case menubar title: uses same emoji thresholds as current, with session percentage replaced by the highest percentage across all accounts and all metrics.

---

## Component Inventory

| Component | States | Variants | Used In |
|-----------|--------|----------|---------|
| AccountHeader | default (collapsed), expanded, hover | Live, Stale | Multi-account accordion row header |
| AccountDetail | visible (expanded), hidden (collapsed) | Live (full color), Stale (muted color + timestamp) | Inside AccountHeader DisclosureGroup |
| UsageRow | default, loading | Card (current single-account), Inline (inside accordion) | usageContent(), AccountDetail |
| LiveIndicator | animating (pulsing), static | — | AccountHeader (Live variant) |
| StaleBadge | default | — | AccountHeader (Stale variant) |
| ProgressBar | default, warning (orange), critical (red) | — | UsageRow |
| HeaderBar | default, loading | — | Top of popover |
| UpdateBanner | visible, hidden | — | Below HeaderBar |
| ErrorView | not-logged-in, generic-error | Single-account, Multi-account (with banner) | Content area |
| FooterView | default, refreshing | Single-account, Multi-account | Bottom of popover |
| NoActiveAccountBanner | visible | — | Multi-account content area when no live token |

### Component Detail: AccountHeader (collapsed row)

- Height: 56pt
- Layout: `[email (headline)] [org (subheadline, secondary)] [spacer] [LiveIndicator or StaleBadge] [highest utilization % (title3, bold, colored)]`
- Disclosure chevron: native DisclosureGroup chevron, trailing edge
- Background: `NSColor.controlBackgroundColor` on hover, transparent default

### Component Detail: UsageRow (style variants)

The existing `UsageRow` struct must gain a `style` parameter with two cases: `.card` (current behavior — padded, rounded-rect background, used in single-account mode) and `.inline` (no background, reduced vertical padding, used inside the multi-account accordion). This is the single most impactful composability change required.

```swift
enum UsageRowStyle { case card, inline }

struct UsageRow: View {
    // existing parameters unchanged
    var style: UsageRowStyle = .card
    // ...
}
```

### Component Detail: LiveIndicator

- Layout: `[pulsing green circle (8pt)] [Text("Live", .caption, liveGreen)]`
- Animation: `repeatForever` pulse on the green circle, scale from 1.0 to 1.3 and back, duration 1.5s
- SF Symbol alternative: `circle.fill` with liveGreen color (template image, no emoji)

### Component Detail: StaleBadge

- Layout: `[SF Symbol: clock (caption2)] [Text("Stale", .caption, staleGray)]`
- Colors: `staleGray` (#8E8E93) for both icon and text
- No animation

---

## Layout Specifications

### Single-Account Mode (unchanged)

- Width: 280pt (fixed)
- Height: 320pt (fixed)
- Layout: identical to current `UsageView`. No conditional code path is entered. The `accounts` array has exactly one entry and the view renders the existing content directly.
- Popover `contentSize`: `NSSize(width: 280, height: 320)` — same as today.

### Multi-Account Mode

- Width: 280pt (fixed, unchanged)
- Height: dynamic, calculated from expanded/collapsed state of all rows
  - Minimum height: 200pt (header + footer + at least one collapsed account row)
  - Maximum height: 480pt (enforced by ScrollView)
  - Between min and max: height matches content exactly
- `NSPopover.contentSize` must be set explicitly when account count changes or when rows expand/collapse. SwiftUI content size changes do not automatically resize NSPopover. The `AppDelegate` must observe account state and call `popover.contentSize = NSSize(width: 280, height: computedHeight)`.
- ScrollView: wraps the accordion list only (not the header or footer). `ScrollView(.vertical, showsIndicators: true)` with `.frame(maxHeight: 380)` (480pt total minus ~100pt for header and footer).

### Collapsed Account Row

- Height: 56pt
- Internal padding: 12pt horizontal, 8pt vertical
- Email: `.headline`, max 1 line, truncated with ellipsis at tail
- Org: `.subheadline`, `.secondary` color, max 1 line, truncated
- Utilization badge: `.title3`, `.bold`, colored by threshold

### Expanded Account Detail

- Internal padding: 12pt (matches collapsed row padding)
- UsageRow style: `.inline` (no card background, no extra corner radius)
- Row spacing: 12pt between UsageRow items
- Stale timestamp: `.caption`, `.secondary`, leading-aligned, 8pt top margin

### Popover Positioning

- `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)` — unchanged
- `NSPopover.Behavior.transient` — unchanged
- When popover is visible and height changes (row expanded/collapsed), update `contentSize` with animation disabled to prevent visual jump

### Grid and Spacing

- Base unit: 8pt
- Section padding: 12pt (horizontal insets for all content sections)
- Inner element spacing: 4pt (within a single row, between label and value)
- Section separation: 16pt (between UsageRow items in single-account mode)
- Accordion row internal spacing: 8pt (between UsageRow items in inline mode)

---

## Design Tokens

### Colors

| Category | Token | Value | Usage |
|----------|-------|-------|-------|
| Status | liveGreen | #34C759 (system green) | LiveIndicator dot, live account utilization color at low usage |
| Status | staleGray | #8E8E93 (system gray) | StaleBadge icon and text, stale account utilization bar |
| Status | warningOrange | #FF9500 (system orange) | UsageRow bar and percentage at 70-89% utilization |
| Status | criticalRed | #FF3B30 (system red) | UsageRow bar and percentage at >=90% utilization |
| Background | controlBackground | NSColor.controlBackgroundColor | Header, footer, card-style UsageRow background |
| Separator | separator | NSColor.separatorColor | ProgressBar track (empty portion) |
| Text | primary | NSColor.labelColor | Email, percentage values, row titles |
| Text | secondary | NSColor.secondaryLabelColor | Org name, subtitle, timestamp, stale account text |

### Color Thresholds (resolved)

The existing `colorForPercentage` function in `UsageView.swift` uses thresholds of 70% and 90%. The ADR mentions 50%/80% as a discrepancy to resolve. This specification resolves in favor of the existing code thresholds, which are already shipped and user-tested:

- Green (liveGreen): utilization < 70%
- Orange (warningOrange): utilization >= 70% and < 90%
- Red (criticalRed): utilization >= 90%

Stale account variant: all utilization bars and percentages render in `staleGray` regardless of utilization value. The stale state takes precedence over the utilization color. This prevents a stale 85% reading from appearing as an active orange warning.

### Typography

| Token | SwiftUI | Usage |
|-------|---------|-------|
| accountEmail | `.headline` | Account email address in collapsed AccountHeader |
| accountOrg | `.subheadline` + `.secondary` | Organization name in collapsed AccountHeader |
| utilizationValue | `.title3`, `.bold` | Utilization percentage in collapsed AccountHeader |
| rowTitle | `.subheadline`, `.medium` | UsageRow title (Session, Weekly, Sonnet Only) |
| rowSubtitle | `.caption` + `.secondary` | UsageRow subtitle (5-hour window, etc.) |
| rowValue | `.title2`, `.bold` | UsageRow percentage (large, colored) |
| timestamp | `.caption` + `.secondary` | Last updated time, reset time |
| liveLabel | `.caption` + liveGreen | "Live" label in LiveIndicator |
| staleLabel | `.caption` + staleGray | "Stale" label in StaleBadge |
| bannerText | `.subheadline` | No active account banner text |
| appTitle | `.headline` | "Claude Usage" in header |
| versionText | `.caption2` + `.secondary` | Version string in header |

### Spacing

| Token | Value | Usage |
|-------|-------|-------|
| baseUnit | 8pt | Grid base |
| sectionPadding | 12pt | Horizontal inset for all content |
| innerElementSpacing | 4pt | Within a row, between icon and label |
| sectionSpacing | 16pt | Between UsageRows in card mode |
| accordionRowSpacing | 8pt | Between UsageRows in inline mode |
| footerPadding | 8pt | Footer top padding |
| headerHeight | ~44pt | Fixed header bar |
| accountRowHeight | 56pt | Collapsed account row |

---

## Interaction Patterns

### Staleness Signal System (three-layer)

Stale accounts must be unambiguously distinguishable from live accounts. The three-layer system ensures that no single-point-of-failure in perception (color-blind users, glanceable view) causes a stale reading to be misread as current data.

Layer 1 — Badge: StaleBadge (clock icon + "Stale" text in staleGray) on the collapsed row. Always visible without interaction.

Layer 2 — Muted colors: All text and utilization values within a stale account's expanded detail use `.secondary` color. UsageRow bars render in `staleGray` regardless of utilization value. Color is not the only signal.

Layer 3 — Timestamp: When a stale row is expanded, a "Last updated [relative time]" line appears beneath the usage data. Users can see both the data and its age in the same view.

Tooltips: Hovering over the utilization percentage in a stale row shows a tooltip: "Data from [absolute datetime]. This account is not currently active." Tooltips are additive; the three-layer system works without them.

### Accordion Behavior

- Default state on popover open: current (live) account row is expanded; all other rows are collapsed.
- When a new account is detected (account switch): the new live account row auto-expands; the previously live (now stale) row auto-collapses. This animation runs on the next popover open after detection, not in the background.
- Expansion is independent: any number of rows can be simultaneously expanded. There is no forced single-expand behavior.
- Expand/collapse animation: SwiftUI default DisclosureGroup animation (spring, ~0.3s). No custom animation required.
- Touch target: entire 56pt header row is tappable, including the area outside the disclosure chevron.

### Menubar Button Title

Current format: `[emoji] [sessionPercentage]%`
New format (multi-account): `[emoji] [worstCasePercentage]%`

`worstCasePercentage` is a computed property: the maximum of `sessionPercentage` and `weeklyPercentage` across all accounts in `accounts`. Stale accounts are included in this calculation. The emoji uses the same thresholds (green/orange/red) applied to this worst-case value.

SF Symbols replacement (recommended, Phase D): Replace emoji status indicators with SF Symbol template images (`circle.fill` with tinted color). This produces a cleaner menubar appearance and respects macOS dark/light mode. Emoji are acceptable for v1.8 Phase A-C.

### Loading States

- Header loading indicator: shown only when the live account is refreshing. Not shown during stale account display.
- Individual account loading: each account's `AccountUsage.isLoading` flag is independent. A loading spinner may appear in the live account's expanded row during a refresh cycle.
- Stale accounts: never show a loading spinner. Their `isLoading` is always `false`.
- Footer "last updated" timestamp: shows the most recent update time of the live account.

### Error Handling

| Error Condition | Display Location | Behavior |
|----------------|-----------------|---------|
| notLoggedIn (no accounts in UserDefaults) | Content area (full-height) | Existing "Not Signed In" error view, pixel-identical to v1.7 |
| notLoggedIn (accounts exist in UserDefaults) | Banner at top of content area | "No active account" banner; stale account rows display below |
| Network error on live account | Live account expanded row | Error message replaces usage rows; other accounts unaffected |
| API error (401 on live account) | Live account expanded row | "Authentication expired. Run 'claude' to re-authenticate." |
| Stale account data unavailable | Stale account expanded row | "No usage data available for this account." in secondary text |

Per-account error isolation is a requirement: one account's fetch failure must not prevent other accounts from displaying their data.

### Refresh Behavior

- The footer refresh button and the 60-second timer both trigger a full refresh cycle.
- Refresh cycle: reads keychain, compares token, fetches usage for the live account.
- Stale accounts are not refreshed. They display the last known data indefinitely until a future session under that account updates them.
- `isRefreshing` guard: if a refresh is in progress when the timer fires, the timer tick is skipped silently. No error state is shown for skipped ticks.

### Popover Size Transitions

When the popover transitions from single-account to multi-account layout (on first account switch detection), the next time the popover is opened it renders in multi-account mode with the updated `contentSize`. The size change does not happen while the popover is open — it happens on the next open. This avoids a visible mid-session resize.

When rows are expanded or collapsed while the popover is open, `popover.contentSize` is updated with the new calculated height. This causes the popover to animate to the new height. Use `NSAnimationContext.runAnimationGroup` with `allowsImplicitAnimation: true` to smooth this transition.

---

## Accessibility Requirements

### WCAG Level

Target: WCAG 2.1 AA, with macOS-specific additions from NSAccessibility.

### Keyboard Navigation

- The menubar button must be focusable via keyboard (Control+F2 or configured menubar focus key).
- Once the popover is open, Tab moves focus through all interactive elements: accordion rows, footer buttons.
- Spacebar or Return toggles the focused DisclosureGroup row.
- Escape closes the popover (existing NSPopover.Behavior.transient handles this).
- Arrow keys within the accordion: Down arrow moves to next row header; Up arrow moves to previous.

### Screen Reader (VoiceOver)

Required accessibility labels:

| Element | accessibilityLabel | accessibilityHint |
|---------|-------------------|------------------|
| AccountHeader (live) | "[email], Live, [highest]% utilization" | "Press Space to expand usage details" |
| AccountHeader (stale) | "[email], Stale, [highest]% utilization, last updated [relative time]" | "Press Space to expand usage details" |
| ProgressBar | "[title] usage, [percentage]%" | — |
| LiveIndicator | "Live account" | — |
| StaleBadge | "Stale account" | — |
| Refresh button (footer) | "Refresh usage data" | — |
| Quit button (footer) | "Quit Claude Usage" | — |
| Web button (footer) | "Open Claude.ai in browser" | — |
| Check for Updates button | "Check for updates" | — |

VoiceOver must announce account switch detection. When `accounts` changes (new account detected), post an `NSAccessibility.Notification.announcement` with the text "Account switched to [new account email]". This announcement fires once, at the moment the model updates, not on every popover open.

ProgressBar VoiceOver: The existing `GeometryReader`-based progress bar has no accessibility label. Add `.accessibilityValue("\(percentage) percent")` and `.accessibilityLabel("\(title) usage")` to the ZStack wrapper.

### Color Contrast

- All text on `NSColor.controlBackgroundColor` must meet 4.5:1 contrast ratio (WCAG AA normal text).
- `staleGray` (#8E8E93) on white background: ~2.8:1. This is below AA for normal text. Use `.secondary` label color (system-adaptive) instead of hardcoded hex for stale text to ensure system contrast settings are respected. On macOS, `NSColor.secondaryLabelColor` adapts to increased contrast accessibility settings.
- `liveGreen` (#34C759) on white: ~1.9:1 as text. The "Live" label must not rely on color alone; the word "Live" and the pulse animation together carry the meaning. For high-contrast mode, add a visible border to the LiveIndicator.
- Utilization percentages (orange, red) on `controlBackgroundColor`: orange (#FF9500) ~2.5:1; red (#FF3B30) ~3.7:1. These are below AA for body text but acceptable for large bold text (`.title2`, `.bold` qualifies as "large text" under WCAG 2.1 at 18pt equivalent). Verify with the Accessibility Inspector.

### Cognitive Load

- The three-layer staleness signal is deliberately redundant to reduce cognitive load, not increase it. Users should not have to reason about whether data is current; the answer must be visible without interaction.
- Maximum account rows displayed simultaneously: no hard limit in v1.8, but the ScrollView with 480pt max height provides a natural constraint. With 5+ accounts, the popover feels long. The Phase D "Remove account" action mitigates accumulation.
- Avoid confirming actions the user did not initiate. Account switch detection is silent and automatic (no dialog, no notification sound).
- Do not show "no data" empty states inside expanded stale rows unless the account genuinely has no historical data. An empty expanded row is more confusing than a collapsed row with a "no data available" indicator in the header.

---

## Platform-Specific Adaptations

### NSPopover

- Use `NSPopover.Behavior.transient` (current, unchanged). Do not switch to `.semitransient` or `.applicationDefined`.
- `NSPopover` does not auto-resize to fit SwiftUI content. Explicit `contentSize` management is required:
  - Initial setup: single-account `NSSize(width: 280, height: 320)`, multi-account calculated dynamically.
  - On account count change: recalculate and set before opening popover.
  - On row expand/collapse: recalculate and set with `NSAnimationContext` animation.
  - Height calculation: `headerHeight (~44) + updateBannerHeight (0 or ~44) + accountListHeight + footerHeight (~100)`. Account list height: sum of (56pt per collapsed row) + (56 + usageDetailHeight per expanded row).
- Do not use NSWindow directly. `NSHostingController` wrapping the SwiftUI view inside the NSPopover is correct and unchanged.

### Process() and Sendability

The existing `getClaudeCodeToken()` calls `Process()` and `process.waitUntilExit()` while `@MainActor` is held, blocking the main thread. This is a known defect (ADR Risk R2). For the multi-account feature, this must be corrected as part of Phase B before `TaskGroup` concurrent fetches are enabled.

The required pattern:

```swift
private nonisolated func readKeychainToken() async throws -> String {
    return try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if proc.terminationStatus == 0,
               let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !result.isEmpty {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: KeychainError.notLoggedIn)
            }
        }
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: KeychainError.unexpectedError(status: -1))
        }
    }
}
```

`Process` and `Pipe` are not `Sendable`. Both must be instantiated entirely within the `nonisolated` scope. The function returns only a `String`, which is `Sendable`. This resolves the Swift concurrency compiler warning and eliminates main thread blocking.

### SF Symbols

Replace all emoji status indicators with SF Symbol template images for consistent rendering across macOS appearance modes:

| Current | Replacement SF Symbol | Note |
|---------|----------------------|------|
| "🟢" | `circle.fill` (liveGreen tint) | Menubar button |
| "🟡" | `circle.fill` (warningOrange tint) | Menubar button |
| "🔴" | `circle.fill` (criticalRed tint) | Menubar button |
| "❓" | `questionmark.circle` | Loading/unknown state |
| "❌" | `xmark.circle.fill` | Error state |
| "⏳" | `clock.arrow.circlepath` | Initial loading state |

Use `.renderingMode(.template)` for all menubar SF Symbols to respect the system tint. This is Phase D polish; emoji are acceptable in Phase A-C.

### Battery Impact

60-second polling that spawns a `/usr/bin/security` subprocess has measurable battery impact. Two mitigations apply:

1. Token-comparison guard (D3): on unchanged token, no subprocess is spawned for profile calls. The `security` CLI subprocess for keychain reading still runs every 60 seconds.
2. Recommended Phase D optimization: pause polling when the popover is not visible. Observe `popover.isShown` and suspend the 60-second timer when the popover is closed for more than 5 minutes. Resume on next popover open. This reduces background CPU from continuous polling to on-demand polling. This is a battery optimization, not a correctness requirement, and is deferred to Phase D.

Alternative: increase polling interval to 120 seconds when on battery power (`ProcessInfo.processInfo.isLowPowerModeEnabled`). This reduces keychain subprocess frequency by 50% on battery. Trade-off: account switch detection latency increases to up to 120 seconds on battery.

### macOS Version Compatibility

- Target: macOS 13+ (Ventura). `SMAppService` (Launch at Login) requires macOS 13. No change required.
- `DisclosureGroup` is available since macOS 11. No version gate needed.
- `NSPopover` explicit `contentSize` management is available on all supported versions.

---

## Open Questions

**OQ-1: Account removal UI in v1.8**
Phase D includes a "Remove account" action for stale accounts. The v1.8 Phase A-C implementation retains all `AccountRecord` entries indefinitely. Users with many accounts (5+) will accumulate a long list with no way to clean it. Should a minimal "Remove" action (swipe-to-delete on the row, or a context menu) be included in Phase C rather than Phase D? Decision needed before Phase C implementation begins.

**OQ-2: Token longevity validation**
ADR D6 notes that "the longevity of a token after an account switch is not empirically known." If a token remains valid for hours after an account switch, the stale indicator may be displayed prematurely. If it expires immediately, the stale indicator is correct. This must be validated against a real second account before shipping. The staleness threshold logic depends on this empirical data.

**OQ-3: Worst-case utilization includes stale accounts**
The menubar button title shows worst-case utilization across all accounts, including stale ones. A stale account showing 95% usage from last week will permanently show a red indicator in the menubar until the account's data is updated (which can only happen when that account is active again). This may create a persistent false alarm for users who have used an account heavily in the past. Should stale accounts be excluded from worst-case calculation, or capped at a lower visual priority? Recommend excluding stale accounts from the worst-case calculation and noting this in the release notes.

**OQ-4: NSPopover contentSize animation strategy**
When a user expands or collapses a row while the popover is open, the height changes. The recommended approach is `NSAnimationContext.runAnimationGroup`. However, abrupt height changes (user rapidly toggling rows) may look jerky. An alternative is to set `contentSize` without animation and let SwiftUI handle the internal content transition. Both approaches should be prototyped before Phase C.

**OQ-5: Multi-account mode activation timing**
The multi-account layout activates as soon as two `AccountRecord` entries exist in UserDefaults. This happens after the first account switch, which may surprise a user who switches accounts temporarily and expects to return to the single-account view. Should the multi-account layout deactivate if only one non-stale account exists (i.e., all other accounts are stale and older than N days)? This connects to OQ-1 (account removal) and OQ-2 (token longevity).

---

## Recommendation

**Implement** — proceed with Phase A through Phase D as defined in ADR-001.

The design is technically sound, platform-appropriate, and addresses the primary UX risk (stale data misread as live) through the three-layer staleness signal. The single-account pixel-identical guarantee eliminates regression risk for the majority of current users. The DisclosureGroup accordion is the correct pattern for this popover width and account count range.

The following items should be resolved before Phase C begins, as they affect component implementation:

1. Resolve OQ-3 (exclude stale accounts from worst-case utilization). The current ADR language includes stale accounts, but this will produce persistent false alarms in the menubar. Recommend changing to live-accounts-only for the menubar worst-case calculation.

2. Validate OQ-2 (token longevity) with a real two-account setup early in Phase A or B. The staleness display logic branches significantly depending on whether tokens expire immediately or after a delay.

3. Move the "Remove account" action (OQ-1) from Phase D into Phase C. The accumulation problem is a first-launch experience issue, not a polish item. A user who switches between two accounts daily will see both accounts in the list forever, with no way to prune stale ones until auto-prune ships in v2. A minimal context menu action in Phase C prevents this from becoming a user complaint.

4. Audit `UsageRow` for accessibility before Phase C. The existing `GeometryReader`-based progress bar has no VoiceOver label. This is a pre-existing defect that multi-account mode amplifies (three bars per account, N accounts).
