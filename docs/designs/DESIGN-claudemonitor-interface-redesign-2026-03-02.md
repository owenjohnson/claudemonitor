# UI/UX Design Specification: ClaudeMonitor Interface Redesign

**Date:** 2026-03-02
**Status:** Draft v2 (Revision 1 — targeted fixes applied)
**ADR Reference:** ADR-003 (Compact UsageRow layout, percentage rounding, height constants, keychain migration)
**Authors:** Design team (design-architect, ux-designer, ui-designer, platform-specialist, design-writer)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Target Platform](#2-target-platform)
3. [User Personas](#3-user-personas)
4. [User Journeys](#4-user-journeys)
5. [Design Decisions](#5-design-decisions)
6. [Component Specification](#6-component-specification)
7. [Call Site Updates](#7-call-site-updates)
8. [Height Calculations](#8-height-calculations)
9. [Accessibility Specification](#9-accessibility-specification)
10. [Error States](#10-error-states)
11. [Design Tokens](#11-design-tokens)
12. [Risks and Mitigations](#12-risks-and-mitigations)
13. [Verification Checklist](#13-verification-checklist)
14. [Out of Scope](#14-out-of-scope)

---

## 1. Overview

This specification defines the UI/UX design for the ClaudeMonitor interface redesign described in ADR-003. The primary goal is to increase information density in the macOS menu bar popover by replacing the ~70pt card-style `UsageRow` with a 20pt compact single-line row, while simultaneously fixing percentage rounding accuracy, updating height constants, and migrating keychain access to a native synchronous API.

### Scope Summary

Four design decisions are in scope:

| Decision | Summary | Primary File |
|----------|---------|--------------|
| **D1** | Replace 70pt card-style `UsageRow` with 20pt compact `HStack` at all 9 call sites | `UsageRow.swift` |
| **D2** | Fix `Int(value)` truncation to `Int(value.rounded())` in `UsageData` | `UsageManager.swift` |
| **D3** | Update `expandedRowHeight` from 228pt to ~140pt in both height constant locations | `AccountList.swift`, `ClaudeMonitorApp.swift` |
| **D4** | Migrate keychain reads from `security` CLI subprocess to `SecItemCopyMatching` | `UsageManager.swift` |

### Implementation Order

Implementation MUST follow this sequence to minimize regression risk:

```
D2 (rounding fix) → D4 (keychain migration) → D1 (compact row) → D3 (height constants)
```

**Rationale:** D2 lands first so that D1's visual output shows correctly rounded values during manual testing. D4 is independent infrastructure that can land after D2 without affecting UI. D1 is the visual redesign that depends on D2 accuracy. D3 depends on D1's final measured row height.

---

## 2. Target Platform

### Environment

| Property | Value |
|----------|-------|
| Platform | macOS only (no iOS, iPadOS, or Mac Catalyst) |
| Minimum OS | macOS 13 (Ventura) |
| UI Paradigm | `NSStatusItem` + `NSPopover` + SwiftUI |
| Popover behavior | `.transient` (dismisses on click-outside) |
| Popover edge | `.minY` (drops below menu bar) |
| Popover width | 280pt (fixed, unchanged) |
| Popover height | Dynamic, 200pt–480pt cap |
| Rendering target | `NSPopover` content area |

### Popover Constraints

The 280pt fixed width is an inherited constraint from ADR-001 and ADR-002. The 480pt cap is enforced by `min(max(...), 480)` in `computePopoverHeight()`. These constraints are not modified by this ADR.

### Typography Rendering Context

All text renders in a `NSPopover` over the macOS desktop. System font metrics apply. `.caption` (12pt SF Pro) is the primary row font. `.caption2` (11pt SF Pro) is the secondary timer font. Both use Dynamic Type but are not expected to resize significantly in menu bar popover context.

---

## 3. User Personas

### Persona 1: Solo Developer (Primary)

**Context:** Single Claude account, personal use. Opens the popover 5-15 times per day for quick utilization glances. Session typically lasts 1-3 hours between checks.

**Goals:**
- Instantly know current utilization at a glance
- Notice when approaching a rate limit (orange/red) before hitting it
- Know how long until the current window resets when near a limit

**Pain Points (current design):**
- 70pt card rows are visually heavy for a single piece of information (a percentage)
- Progress bar is redundant with the numeric percentage — it adds height without adding information
- Subtitle text ("5-hour window") provides context that is only needed once, not on every glance

**Resolution in D1:** 20pt single-line row eliminates redundancy. Tooltip (`.help()`) preserves the subtitle context on hover without consuming vertical space.

---

### Persona 2: Multi-Account Developer (Secondary)

**Context:** 2-5 Claude accounts (personal + work, or multiple org accounts). Monitors all accounts to track aggregate usage across contexts. Power user.

**Goals:**
- See all account utilization states at a glance in collapsed accordion view
- Quickly expand specific accounts to see row-level detail
- Fit all accounts within the popover without scrolling (up to 5-6 accounts)

**Pain Points (current design):**
- With 3 expanded accounts: `3 × 228pt + 92pt = 776pt` — far exceeds the 480pt cap; only 1 expanded account fits without scrolling
- 228pt expanded height makes it impractical to compare multiple accounts simultaneously

**Resolution in D1 + D3:** Expanded row height drops to ~140pt. At 3 accounts: `92 + 140 + 96 = 328pt` — all 3 fit comfortably within the 480pt cap.

---

### Persona 3: VoiceOver User (Accessibility)

**Context:** Uses macOS VoiceOver for navigation. Interacts with the popover via keyboard and VO cursor.

**Goals:**
- Navigate the popover and understand each usage row via audio announcement
- Hear both the utilization percentage and the reset timer when near a limit (>= 70%)
- Receive clear, semantic announcements without noise from structural elements

**Pain Points (current design):**
- Accessibility annotations are on the `GeometryReader` progress bar — an implementation detail, not a semantic element
- No reset timer in `accessibilityValue` — users at 72% hear "72 percent" but not "resets in 2 hours 15 minutes"

**Resolution in D1:** Accessibility annotations transfer to the `HStack` container. Reset timer is conditionally included in `accessibilityValue` when `percentage >= 70`. VoiceOver will announce: "Session usage, 72 percent, resets in 2 hours 15 minutes."

---

## 4. User Journeys

### Journey 1: Quick Status Check

**Frequency:** >80% of all popover interactions (2-4 seconds total)
**Persona:** Primarily Persona 1 (Solo Developer)

| Step | Action | UI Response |
|------|--------|-------------|
| 1 | User clicks menu bar icon | Popover opens below menu bar icon |
| 2 | User scans percentage values | Colored percentage text (green/orange/red) communicates status instantly |
| 3 | User observes color summary | Green = safe, orange = elevated, red = critical |
| 4 | User closes popover | Popover dismisses (`.transient` behavior) |

**Design consideration:** The right-aligned bold colored percentage is the primary focal point. It must be visually dominant. The label is secondary context; the timer is tertiary urgency information.

---

### Journey 2: Multi-Account Overview

**Frequency:** Common for Persona 2
**Persona:** Persona 2 (Multi-Account Developer)

| Step | Action | UI Response |
|------|--------|-------------|
| 1 | User clicks menu bar icon | Popover opens; accordion shows N accounts in collapsed 48pt rows |
| 2 | User identifies account of interest via color/name | Collapsed header shows worst-case utilization color |
| 3 | User clicks account header to expand | `DisclosureGroup` reveals 3 compact rows (Session, Weekly, Sonnet Only) |
| 4 | User reads row-level utilization | 3 × 20pt compact rows show label, conditional timer, percentage |
| 5 | User collapses and expands another account | Exclusive accordion behavior ensures only one expanded at a time |
| 6 | User closes popover | Dismisses |

**Design consideration:** Exclusive accordion (ADR-002 D1) means only one account expands at a time. D1's 140pt expanded height means 3-4 accounts easily fit simultaneously.

---

### Journey 3: Rate Limit Awareness

**Frequency:** Elevated during heavy usage periods
**Persona:** Persona 1 and 2

| Step | Action | UI Response |
|------|--------|-------------|
| 1 | User notices orange/red menu bar icon | Menu bar icon reflects worst-case utilization color |
| 2 | User opens popover | Popover opens; orange/red percentage visible immediately |
| 3 | User reads usage row | Percentage bold in orange or red; timer text ("in 1h 30m") visible because >= 70% |
| 4 | User assesses remaining time | Timer text in `.caption2` secondary color to right of label |
| 5 | User decides to throttle or wait | Popover dismissed |

**Design consideration:** The conditional timer (visible only at >= 70%) ensures users see the reset time precisely when it is decision-relevant. At < 70% (green), the timer would be noise.

---

### Journey 4: Post-Update First Launch (D4 Keychain ACL Dialog)

**Frequency:** Once per installation after D4 ships
**Persona:** All personas

| Step | Action | UI Response |
|------|--------|-------------|
| 1 | User updates app; launches for first time | App starts; `SecItemCopyMatching` attempts keychain access |
| 2 | macOS displays security dialog | "ClaudeMonitor wants to access 'Claude Code-credentials' in your keychain." |
| 3 | User clicks "Always Allow" | Dialog dismissed; keychain read succeeds; normal operation |
| 4 | User clicks "Deny" | `KeychainError.accessDenied` thrown; specific error view displayed (see Section 10) |
| 5 | (If denied) User follows guidance | Error view shows "Open Privacy Settings" button; user re-allows access |

**Design consideration:** This is a one-time friction event. Release notes MUST mention this dialog and instruct users to click "Always Allow." The error view for "Deny" must be actionable, not generic.

---

### Journey 5: VoiceOver Navigation

**Frequency:** Every session for Persona 3
**Persona:** Persona 3 (VoiceOver User)

| Step | Action | VoiceOver Announcement |
|------|--------|------------------------|
| 1 | User activates menu bar item | "ClaudeMonitor, menu bar extra" |
| 2 | VO cursor enters popover | App header announced |
| 3 | VO cursor moves to usage rows | "Session usage, 45 percent" (green: no timer) |
| 4 | VO cursor moves to next row | "Weekly usage, 72 percent, resets in 2 hours 15 minutes" (orange: timer included) |
| 5 | VO cursor moves to third row | "Sonnet Only usage, 91 percent, resets in 45 minutes" (red: timer included) |
| 6 | VO cursor moves to footer | Footer controls announced |

**Design consideration:** `accessibilityValue` MUST include the reset timer when `percentage >= 70`. This is a unanimous three-expert requirement (see Part 5 convergences in brief).

---

## 5. Design Decisions

### D1: 20pt CompactUsageRow Replaces Card-Style UsageRow

#### What Changes

The ~70pt card-style `UsageRow` is replaced with a 20pt single-line `HStack`. Applied at all 9 call sites (3 in `UsageView.swift`, 6 in `AccountDetail.swift`).

**Removed:**
- `GeometryReader`-based progress bar (8pt tall `RoundedRectangle` fill)
- `subtitle` parameter and visible subtitle `Text` ("5-hour window", etc.)
- `UsageRowStyle` enum (`.card` / `.inline`)
- `style` parameter from `UsageRow` init
- Card background (`Color(NSColor.controlBackgroundColor)` fill + `cornerRadius(8)`)

**Added:**
- `tooltip: String` parameter (replaces `subtitle` semantically — context moves from visible text to `.help()` hover tooltip)
- Conditional timer text (visible only when `percentage >= 70`)
- `.frame(minHeight: 20)` for accessibility text size support (platform expert requirement)
- `.help(tooltip)` on label text (UX + platform convergence)
- `accessibilityValue` with conditional timer text (unanimous expert requirement)

#### SwiftUI Code

```swift
struct UsageRow: View {
    let title: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color
    let tooltip: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.primary)
                .help(tooltip)

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
        .frame(minHeight: 20)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) usage")
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        // IMPORTANT: Uses full words ("hours", "minutes") for VoiceOver clarity.
        // Does NOT use formatTimeRemaining() which returns abbreviated "h"/"m".
        if percentage >= 70, let resetsAt = resetsAt {
            let remaining = resetsAt.timeIntervalSinceNow
            guard remaining > 0 else { return "\(percentage) percent, resets now" }
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            let timeString: String
            if hours > 0 {
                timeString = "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) minute\(minutes == 1 ? "" : "s")"
            } else {
                timeString = "\(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return "\(percentage) percent, resets in \(timeString)"
        }
        return "\(percentage) percent"
    }

    private func formatTimeRemaining(_ date: Date) -> String {
        // Retained unchanged from current UsageRow implementation
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "in \(hours)h \(minutes)m"
        }
        return "in \(minutes)m"
    }
}
```

**Note on row height:** 20pt is the target. Use `.frame(minHeight: 20)` (not `.frame(height: 20)`) to support Dynamic Type accessibility text sizes. Verify in SwiftUI Previews on the minimum deployment target (macOS 13). If text clips at `.caption` (12pt) with standard line height (~14pt), increase to `minHeight: 24`. The 24pt fallback does not affect architectural decisions.

#### Tooltip Values by Row

| Row | `title` | `tooltip` |
|-----|---------|-----------|
| Session | `"Session"` | `"5-hour window"` |
| Weekly | `"Weekly"` | `"7-day window"` |
| Sonnet Only | `"Sonnet Only"` | `"Model-specific"` |

#### Affected Files

- `ClaudeMonitor/UsageRow.swift` — Full rewrite (~35 lines)
- `ClaudeMonitor/AccountDetail.swift` — Remove `subtitle:` and `style:` from 6 call sites; add `tooltip:`
- `ClaudeMonitor/UsageView.swift` — Remove `subtitle:` and `style:` from 3 call sites; add `tooltip:`; update `VStack` spacing from 16 to 8; remove pixel-identity comments

#### Acceptance Criteria

- [ ] `UsageRowStyle` enum has zero remaining references
- [ ] `subtitle` parameter has zero remaining references in `UsageRow` init
- [ ] All 9 call sites compile without `subtitle:` or `style:` parameters
- [ ] All 9 call sites pass `tooltip:` with appropriate window description
- [ ] `.help()` tooltip displays on hover over label text in macOS
- [ ] Timer text is visible only when `percentage >= 70`
- [ ] VoiceOver announces timer in `accessibilityValue` when `percentage >= 70`
- [ ] Rows render without text clipping in SwiftUI Previews at 1/2/3/5 accounts

---

### D2: Replace `Int(value)` with `Int(value.rounded())` in UsageData

#### What Changes

Three computed properties in `UsageData` use `Int(value)` (floor truncation). This is replaced with `Int(value.rounded())` (IEEE 754 round-half-to-even).

**Impact:** Displayed percentages increase by 0-1% for users near threshold boundaries. A user at 89.7% utilization previously saw "89%" (green/borderline); they will now see "90%" (red). This is a correctness fix, not a behavioral regression. Release notes must note this change.

#### SwiftUI Code

Current (`UsageManager.swift:12-14`):
```swift
var sessionPercentage: Int { Int(sessionUtilization) }
var weeklyPercentage: Int { Int(weeklyUtilization) }
var sonnetPercentage: Int? { sonnetUtilization.map { Int($0) } }
```

Fixed:
```swift
var sessionPercentage: Int { Int(sessionUtilization.rounded()) }
var weeklyPercentage: Int { Int(weeklyUtilization.rounded()) }
var sonnetPercentage: Int? { sonnetUtilization.map { Int($0.rounded()) } }
```

#### Affected Files

- `ClaudeMonitor/UsageManager.swift` — 3 lines in `UsageData` struct (lines 12-14)

#### Acceptance Criteria

- [ ] 89.7 displays as "90%" (rounds up)
- [ ] 89.4 displays as "89%" (rounds down)
- [ ] 69.5 displays as "70%" (orange threshold, rounds up to trigger orange)
- [ ] 69.4 displays as "69%" (stays green)
- [ ] ADR-002 D4 precision note is superseded (no longer referenced as active)

---

### D3: Update `expandedRowHeight` Constant from 228pt to ~140pt

#### What Changes

After D1 reduces row height from ~70pt to 20pt, the hardcoded `expandedRowHeight` constant (228pt) becomes stale by ~88pt. Updated in two locations.

**These two constants MUST be updated in the same atomic commit.** They are coupled (RF5 in ADR-002); updating only one produces mismatched popover height and `ScrollView` height.

#### Updated Constants

```swift
// ClaudeMonitor/AccountList.swift — computedScrollHeight
let expanded: CGFloat = 140   // updated from 228pt
                               // D1: 3 × 20pt compact rows + 48pt header + ~16pt DisclosureGroup padding
let collapsed: CGFloat = 48   // unchanged (ADR-002 D2)

// ClaudeMonitor/ClaudeMonitorApp.swift — computePopoverHeight()
let expandedRowHeight: CGFloat = 140  // updated from 228pt
let collapsedRowHeight: CGFloat = 48  // unchanged (ADR-002 D2)
let headerFooter: CGFloat = 92        // unchanged (44pt app header + 48pt compressed footer)
```

#### Height Formula Derivation

```
expandedRowHeight ≈ 140pt
  = 48pt  (AccountHeader frame height, unchanged from ADR-002 D2)
  + ~8pt  (DisclosureGroup internal content top padding, estimated — verify empirically)
  + 76pt  (VStack content: 3 × 20pt compact rows + 2 × 8pt inter-row spacing)
  + ~8pt  (DisclosureGroup internal content bottom padding, estimated)
  = 140pt
```

**Note on DisclosureGroup padding:** The ~8pt top and bottom padding is not formally documented by Apple and may vary across macOS 13/14/15. The 140pt value must be verified empirically with SwiftUI Previews at 2, 3, 4, and 5 accounts. Adjust if observed height differs materially. The 480pt cap in `min(max(...), 480)` bounds any overestimate.

#### Affected Files

- `ClaudeMonitor/AccountList.swift` — `computedScrollHeight`, line ~52
- `ClaudeMonitor/ClaudeMonitorApp.swift` — `computePopoverHeight()`, line ~164

#### Acceptance Criteria

- [ ] Both constants updated in the same commit
- [ ] 3 accounts fit without overflow at ~328pt (verify in Previews and at runtime)
- [ ] 6 accounts at ~472pt — within 480pt cap (verify)
- [ ] 9 accounts at ~616pt → scrollable at 480pt cap (verify scroll behavior)
- [ ] No excess whitespace below account detail at 2 accounts (2-row variant: ~112pt)

---

### D4: Migrate Keychain Access from `security` CLI to `SecItemCopyMatching`

#### What Changes

`readKeychainRawJSON(service:)` — which spawned a `security` subprocess via `Process`/`Pipe` — is replaced by synchronous `readKeychainNative(service:)`. The `nonisolated` async wrapper and `withCheckedThrowingContinuation` pattern are eliminated. `KeychainError.securityCommandFailed` is removed.

#### SwiftUI Code

New `readKeychainNative`:
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

`KeychainError.from(status:)` factory:
```swift
static func from(status: OSStatus) -> KeychainError {
    switch status {
    case errSecItemNotFound:          return .notLoggedIn
    case errSecAuthFailed:            return .accessDenied
    case errSecInteractionNotAllowed: return .interactionNotAllowed
    case errSecInvalidData:           return .invalidData
    default:                          return .unexpectedError(status: status)
    }
}
```

Updated `getClaudeCodeToken()` (becomes synchronous `throws`):
```swift
private func getClaudeCodeToken() throws -> String {
    let jsonString: String
    do {
        jsonString = try readKeychainNative(service: "Claude Code-credentials")
    } catch KeychainError.notLoggedIn {
        // Note: accessDenied is NOT caught here — it propagates to the UI layer
        // to surface the specific "Keychain Access Required" error view (Section 10.1).
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

**Note on `accessDenied` catch clause:** This is an intentional deviation from the ADR-003 D4 code sample, which catches both `notLoggedIn` and `accessDenied` together. The spec separates them so that the `accessDenied` error view in Section 10.1 is reachable — `accessDenied` propagates up the call stack to the UI layer unchanged.

#### Caller Cascade

`getClaudeCodeToken()` and `getAccessTokenFromAlternateKeychain()` become synchronous `throws`. `getAccessTokenWithChangeDetection()` also becomes synchronous `throws` (its only async dependency was `getClaudeCodeToken()`). Call sites in `refreshWithRetry()` drop `await` on `getAccessTokenWithChangeDetection()` but retain `try`. `refreshWithRetry()` and `refresh()` remain `async` (they depend on `refreshAllAccounts(liveToken:)` and `Task.sleep`, which are independently async).

#### Affected Files

- `ClaudeMonitor/UsageManager.swift`:
  - Replace `readKeychainRawJSON(service:)` with `readKeychainNative(service:)`
  - Update `getClaudeCodeToken()` (synchronous, see above)
  - Update `getAccessTokenFromAlternateKeychain()` (synchronous, see above)
  - Update `getAccessTokenWithChangeDetection()` (drop `async`, retain `throws`)
  - Add `KeychainError.from(status:)` static factory
  - Remove `securityCommandFailed` case from `KeychainError`
  - Retain `missingOAuthToken(availableKeys:)` case
  - Remove `nonisolated` modifier from removed function
  - Update callers of `securityCommandFailed` to catch `accessDenied` / `interactionNotAllowed`

#### Acceptance Criteria

- [ ] `securityCommandFailed` case has zero remaining references
- [ ] No `Process` or `Pipe` objects created during keychain reads (verify with Instruments)
- [ ] App reads keychain and displays usage data normally after migration
- [ ] ACL dialog appears at most once per installation after D4 ships
- [ ] `KeychainError.accessDenied` is surfaced as actionable error view (see Section 10)
- [ ] `KeychainError.interactionNotAllowed` is handled (treated as access denied)
- [ ] `readKeychainNative` is synchronous (no `async`, no `nonisolated`, no continuation)

---

## 6. Component Specification

### 6.1 UsageRow Component

#### Layout Diagram

```
┌─────────────────────────────── 280pt popover width ────────────────────────────────┐
│  [12pt left padding from AccountDetail VStack]   [12pt right padding]              │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │ HStack(spacing: 4)                              minHeight: 20pt              │  │
│  │                                                                              │  │
│  │  [Label(.caption, .primary)]  [Timer(.caption2, .secondary)]  [Spacer]  [%] │  │
│  │  "Session"                    "in 1h 30m" (>=70% only)                 "72%"│  │
│  │  + .help("5-hour window")                                        (.bold,    │  │
│  │                                                                   .orange)  │  │
│  └──────────────────────────────────────────────────────────────────────────────┘  │
│  [4pt horizontal padding inside HStack]                                            │
└────────────────────────────────────────────────────────────────────────────────────┘
```

**Horizontal padding layers:**
- `AccountDetail VStack`: `.padding(.horizontal, 12)` — outer container padding
- `UsageRow HStack`: `.padding(.horizontal, 4)` — inner element breathing room
- Total label left offset: 16pt from popover edge

#### Component Parameters

```swift
struct UsageRow: View {
    let title: String      // "Session", "Weekly", "Sonnet Only"
    let percentage: Int    // 0-100 (correctly rounded via D2)
    let resetsAt: Date?    // nil when no reset data available
    let color: Color       // via Color.forUtilization(percentage)
    let tooltip: String    // "5-hour window", "7-day window", "Model-specific"
}
```

#### States

| State | Condition | Percentage Color | Timer Visible | Notes |
|-------|-----------|-----------------|---------------|-------|
| Green | `percentage < 70` | `.green` (via `Color.forUtilization`) | No | Most common state |
| Orange | `percentage >= 70 && < 90` | `.orange` | Yes (if `resetsAt != nil`) | Timer visible |
| Red | `percentage >= 90` | `.red` | Yes (if `resetsAt != nil`) | Timer visible, urgent |
| Stale | Account data is stale | `.secondary` (dimmed) | No | Parent `StaleAccountDetail` handles; row renders with last-known values |
| Loading | `UsageManager` mid-refresh | Loading indicator in parent | Row not rendered | Parent `AccountRow`/header shows spinner |
| No Sonnet | `sonnetPercentage == nil` | — | — | Row not rendered; only Session + Weekly shown |

#### Conditional Timer Logic

```
if percentage >= 70 AND resetsAt != nil:
    show Text(formatTimeRemaining(resetsAt))
        font: .caption2
        foregroundColor: .secondary
else:
    (timer Text is omitted from HStack entirely)
```

**Timer format examples:**
- `"in 2h 15m"` — 2 hours and 15 minutes remaining
- `"in 30m"` — less than 1 hour remaining
- `"now"` — reset time has passed (guard `remaining > 0`)

#### Accessibility Annotations

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel("\(title) usage")
.accessibilityValue(accessibilityValueText)

// accessibilityValueText:
// percentage < 70:  "45 percent"
// percentage >= 70, resetsAt non-nil: "72 percent, resets in 2 hours 15 minutes"
// percentage >= 70, resetsAt nil:     "72 percent"
```

The `accessibilityValue` timer format MUST spell out time in full words for VoiceOver clarity (e.g., "2 hours 15 minutes"), not the abbreviated display format ("in 2h 15m"). Implement a separate `accessibilityTimeRemaining(_:)` helper if needed, or compute inline in `accessibilityValueText`.

#### `formatTimeRemaining()` Implementation

Retained unchanged from current `UsageRow` implementation as a `private func`. No behavioral changes.

---

## 7. Call Site Updates

### 7.1 UsageView.swift — `usageContent()` (3 call sites)

**VStack spacing change:** Update `VStack` spacing in `usageContent()` from 16 to 8 to match the `AccountDetail` spacing. This is mandatory — mismatched spacing would cause inconsistent vertical rhythm between single-account and multi-account modes.

```swift
// Before
VStack(spacing: 16) {
    UsageRow(title: "Session", percentage: data.sessionPercentage,
             resetsAt: data.sessionResetsAt, color: sessionColor,
             subtitle: "5-hour window", style: .card)
    UsageRow(title: "Weekly", percentage: data.weeklyPercentage,
             resetsAt: data.weeklyResetsAt, color: weeklyColor,
             subtitle: "7-day window", style: .card)
    if let sp = data.sonnetPercentage {
        UsageRow(title: "Sonnet Only", percentage: sp,
                 resetsAt: data.weeklyResetsAt, color: sonnetColor,
                 subtitle: "Model-specific", style: .card)
    }
}

// After
VStack(spacing: 8) {
    UsageRow(title: "Session", percentage: data.sessionPercentage,
             resetsAt: data.sessionResetsAt, color: sessionColor,
             tooltip: "5-hour window")
    UsageRow(title: "Weekly", percentage: data.weeklyPercentage,
             resetsAt: data.weeklyResetsAt, color: weeklyColor,
             tooltip: "7-day window")
    if let sp = data.sonnetPercentage {
        UsageRow(title: "Sonnet Only", percentage: sp,
                 resetsAt: data.weeklyResetsAt, color: sonnetColor,
                 tooltip: "Model-specific")
    }
}
```

**Comment updates required:**
- Line ~55: Remove or update pixel-identity comment ("pixel-identical to v1.7" is no longer accurate after D1)
- Line ~75: Same — update or remove "Single-account content — pixel-identical to v1.7" comment

### 7.2 AccountDetail.swift — `LiveAccountDetail` (3 call sites)

```swift
// Before (LiveAccountDetail, inline style)
UsageRow(title: "Session", percentage: data.sessionPercentage,
         resetsAt: data.sessionResetsAt, color: sessionColor,
         subtitle: "5-hour window", style: .inline)
UsageRow(title: "Weekly", percentage: data.weeklyPercentage,
         resetsAt: data.weeklyResetsAt, color: weeklyColor,
         subtitle: "7-day window", style: .inline)
if let sp = data.sonnetPercentage {
    UsageRow(title: "Sonnet Only", percentage: sp,
             resetsAt: data.weeklyResetsAt, color: sonnetColor,
             subtitle: "Model-specific", style: .inline)
}

// After
UsageRow(title: "Session", percentage: data.sessionPercentage,
         resetsAt: data.sessionResetsAt, color: sessionColor,
         tooltip: "5-hour window")
UsageRow(title: "Weekly", percentage: data.weeklyPercentage,
         resetsAt: data.weeklyResetsAt, color: weeklyColor,
         tooltip: "7-day window")
if let sp = data.sonnetPercentage {
    UsageRow(title: "Sonnet Only", percentage: sp,
             resetsAt: data.weeklyResetsAt, color: sonnetColor,
             tooltip: "Model-specific")
}
```

### 7.3 AccountDetail.swift — `StaleAccountDetail` (3 call sites)

Same parameter changes as `LiveAccountDetail`. Replace `subtitle:` and `style:` with `tooltip:`. The `StaleAccountDetail` rendering context (stale data visual treatment) is handled by the parent view, not by `UsageRow` itself.

```swift
// After (StaleAccountDetail — same pattern as LiveAccountDetail)
UsageRow(title: "Session", percentage: data.sessionPercentage,
         resetsAt: data.sessionResetsAt, color: sessionColor,
         tooltip: "5-hour window")
UsageRow(title: "Weekly", percentage: data.weeklyPercentage,
         resetsAt: data.weeklyResetsAt, color: weeklyColor,
         tooltip: "7-day window")
if let sp = data.sonnetPercentage {
    UsageRow(title: "Sonnet Only", percentage: sp,
             resetsAt: data.weeklyResetsAt, color: sonnetColor,
             tooltip: "Model-specific")
}
```

### 7.4 Call Site Summary Table

| File | View | Call Site | `subtitle:` | `style:` | `tooltip:` |
|------|------|-----------|-------------|---------|------------|
| `UsageView.swift` | `usageContent()` | Session row | Remove `"5-hour window"` | Remove `.card` | Add `"5-hour window"` |
| `UsageView.swift` | `usageContent()` | Weekly row | Remove `"7-day window"` | Remove `.card` | Add `"7-day window"` |
| `UsageView.swift` | `usageContent()` | Sonnet row | Remove `"Model-specific"` | Remove `.card` | Add `"Model-specific"` |
| `AccountDetail.swift` | `LiveAccountDetail` | Session row | Remove `"5-hour window"` | Remove `.inline` | Add `"5-hour window"` |
| `AccountDetail.swift` | `LiveAccountDetail` | Weekly row | Remove `"7-day window"` | Remove `.inline` | Add `"7-day window"` |
| `AccountDetail.swift` | `LiveAccountDetail` | Sonnet row | Remove `"Model-specific"` | Remove `.inline` | Add `"Model-specific"` |
| `AccountDetail.swift` | `StaleAccountDetail` | Session row | Remove `"5-hour window"` | Remove `.inline` | Add `"5-hour window"` |
| `AccountDetail.swift` | `StaleAccountDetail` | Weekly row | Remove `"7-day window"` | Remove `.inline` | Add `"7-day window"` |
| `AccountDetail.swift` | `StaleAccountDetail` | Sonnet row | Remove `"Model-specific"` | Remove `.inline` | Add `"Model-specific"` |

---

## 8. Height Calculations

### 8.1 Updated expandedRowHeight Formula

```
expandedRowHeight = 140pt (3-row, worst case)

Derivation:
  48pt  AccountHeader (.frame(height: 48), ADR-002 D2, unchanged)
+  8pt  DisclosureGroup internal content top padding (estimated, verify empirically)
+ 76pt  VStack content:
          3 × 20pt UsageRow (minHeight: 20)
        + 2 × 8pt  VStack(spacing: 8) inter-row gaps
+  8pt  DisclosureGroup internal content bottom padding (estimated, verify empirically)
= 140pt

2-row variant (sonnetPercentage == nil):
  48 + 8 + (2 × 20 + 1 × 8) + 8 = 112pt
  (28pt whitespace overallocation vs. 140pt constant — acceptable)
```

### 8.2 Popover Height Formula

```
popoverHeight = min(max(92 + expandedRowHeight + (N-1) × 48, 200), 480)

Where:
  92pt  = headerFooter (44pt app header + 48pt compressed footer, unchanged)
  140pt = expandedRowHeight (updated from 228pt)
  48pt  = collapsedRowHeight (unchanged, ADR-002 D2)
  N     = number of accounts (1 account always expanded; rest collapsed)
```

### 8.3 Multi-Account Height Table

| Accounts (N) | Formula | Height | Within 480pt cap? |
|:---:|---------|-------:|:-----------------:|
| 1 | 92 + 140 | 232pt | Yes |
| 2 | 92 + 140 + 48 | 280pt | Yes |
| 3 | 92 + 140 + 96 | 328pt | Yes |
| 4 | 92 + 140 + 144 | 376pt | Yes |
| 5 | 92 + 140 + 192 | 424pt | Yes |
| 6 | 92 + 140 + 240 | 472pt | Yes |
| 7 | 92 + 140 + 288 | 520pt → 480pt (cap) | Scrollable |
| 8+ | ... | > 480pt → 480pt (cap) | Scrollable |

### 8.4 Single-Account Popover Height (Expert Recommendation)

The current single-account `computePopoverHeight()` likely produces a fixed value of ~320pt (from pre-D1 constants). After D1, single-account content height drops substantially. N=1 formula: `92 + 140 = 232pt`.

The current 320pt single-account value will result in ~60-80pt of whitespace at the bottom of the popover after D1. This MUST be addressed as part of D3. If not addressed in D3, it should be tracked as a follow-on item.

**Recommendation:** Update single-account height to 240pt (232pt computed + 8pt breathing room) in `computePopoverHeight()`. This eliminates the whitespace without requiring a separate constant.

---

## 9. Accessibility Specification

### 9.1 VoiceOver Behavior

| Element | `accessibilityLabel` | `accessibilityValue` | Notes |
|---------|---------------------|---------------------|-------|
| UsageRow (green) | `"Session usage"` | `"45 percent"` | No timer |
| UsageRow (orange) | `"Weekly usage"` | `"72 percent, resets in 2 hours 15 minutes"` | Timer included |
| UsageRow (red) | `"Sonnet Only usage"` | `"91 percent, resets in 45 minutes"` | Timer included |
| UsageRow (orange, no resetsAt) | `"Session usage"` | `"72 percent"` | Timer omitted |
| UsageRow (>= 70%, resetsAt in past) | `"Session usage"` | `"72 percent, resets now"` | Timer expired edge case |

### 9.2 accessibilityValue Construction

```swift
private var accessibilityValueText: String {
    if percentage >= 70, let resetsAt = resetsAt {
        // Full words for VoiceOver clarity
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "\(percentage) percent, resets now" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let timeString: String
        if hours > 0 {
            timeString = "\(hours) hour\(hours == 1 ? "" : "s") \(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            timeString = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(percentage) percent, resets in \(timeString)"
    }
    return "\(percentage) percent"
}
```

**Important:** The display format (`formatTimeRemaining`) uses abbreviated "h"/"m". The accessibility format uses full words "hours"/"minutes" for VoiceOver clarity. These are separate implementations.

### 9.3 Focus Order

VoiceOver traversal order within the popover (top to bottom, following SwiftUI natural order):
1. App header (app name, version)
2. Account header (account name + worst-case utilization color indicator)
3. UsageRow: Session
4. UsageRow: Weekly
5. UsageRow: Sonnet Only (when present)
6. Footer (refresh time, settings)

### 9.4 WCAG Notes

- **WCAG 1.4.3 Contrast:** The `.caption` (12pt) text requires at minimum 4.5:1 contrast ratio. macOS system colors (`.primary`, `.secondary`, `.green`, `.orange`, `.red`) meet this requirement in both light and dark mode on macOS.
- **WCAG 1.4.4 Resize Text:** `.frame(minHeight: 20)` supports larger text sizes under macOS accessibility settings without clipping. Verify at "Larger Text" accessibility setting.
- **WCAG 2.1.1 Keyboard:** `NSPopover` is keyboard-accessible via macOS standard mechanisms. No custom keyboard handling required.
- **WCAG 4.1.2 Name, Role, Value:** `accessibilityLabel` + `accessibilityValue` satisfy name and value requirements. Role is inferred as `.staticText` by default; this is appropriate for a read-only status row.

### 9.5 Reduce Motion Gap

The `LiveIndicator` animation in account headers does not respect macOS "Reduce Motion" accessibility setting. This is a known gap, documented here for tracking, but is out of scope for this ADR. File as a follow-on issue. (See Section 14, Out of Scope.)

---

## 10. Error States

### 10.1 KeychainError.accessDenied (D4 — User Clicked "Deny")

When the user clicks "Deny" on the macOS ACL dialog for `SecItemCopyMatching`, `errSecAuthFailed` is returned, which maps to `KeychainError.accessDenied`. This error requires a specific, actionable error view — not a generic error triangle.

**Error View Requirements:**

```
┌─────────────────────────────────────────────────────┐
│  [Warning icon]  Keychain Access Required           │
│                                                     │
│  ClaudeMonitor needs access to your keychain to     │
│  read your Claude credentials.                      │
│                                                     │
│  To allow access:                                   │
│  1. Open System Settings                            │
│  2. Go to Privacy & Security > Keychain             │
│  3. Find ClaudeMonitor and set to "Always Allow"    │
│                                                     │
│  [ Open Privacy Settings ]                          │
└─────────────────────────────────────────────────────┘
```

- "Open Privacy Settings" button opens `x-apple.systempreferences:com.apple.preference.security` via `NSWorkspace.shared.open(_:)`
- This error state replaces the generic error triangle / "Keychain access denied" text currently used
- `KeychainError.interactionNotAllowed` should display the same error view (same resolution path)

### 10.2 Other KeychainError States

| Error | Display | User Action |
|-------|---------|-------------|
| `.notLoggedIn` | "Not logged in to Claude. Please sign in via Claude Code." | Sign in to Claude Code |
| `.missingOAuthToken(availableKeys:)` | "Credential format unexpected. [Debug: keys]" | Contact support |
| `.invalidCredentialFormat` | "Could not read Claude credentials." | Re-install or re-sign-in |
| `.unexpectedError(status:)` | "Keychain error (\(status))." | Contact support |

### 10.3 Release Notes Guidance

The following MUST appear in the release notes for the version shipping D4:

> **Keychain Access Dialog:** After updating, ClaudeMonitor will ask for permission to access your Claude Code credentials in the macOS keychain. When the dialog appears, click **"Always Allow"** to continue using the app. This dialog appears only once.

---

## 11. Design Tokens

### 11.1 Color Tokens

| Token | Value | Usage |
|-------|-------|-------|
| `utilization.green` | `Color.green` (system) | Percentage < 70% |
| `utilization.orange` | `Color.orange` (system) | 70% <= percentage < 90% |
| `utilization.red` | `Color.red` (system) | Percentage >= 90% |
| `label.primary` | `Color.primary` (system) | Row label text, percentage text |
| `label.secondary` | `Color.secondary` (system) | Timer text, stale/dimmed states |
| `background.control` | `Color(NSColor.controlBackgroundColor)` | Removed from UsageRow in D1; retained in AccountHeader |
| `accent` | `Color.accentColor` (system) | Interactive elements (buttons, links) |
| `separator` | `Color(NSColor.separatorColor)` | Footer separator, section dividers |
| `warning` | `Color.orange` (system) | Warning icon in KeychainError error view |

### 11.2 Typography Tokens

| Token | Value | Usage |
|-------|-------|-------|
| `row.label` | `.font(.caption)` — 12pt SF Pro Regular | UsageRow title |
| `row.percentage` | `.font(.caption).fontWeight(.bold)` — 12pt SF Pro Bold | UsageRow percentage |
| `row.timer` | `.font(.caption2)` — 11pt SF Pro Regular | UsageRow conditional timer |
| `header.title` | `.font(.subheadline).fontWeight(.semibold)` | Account header name |
| `header.subtitle` | `.font(.caption)` | Account header utilization summary |
| `app.title` | `.font(.headline)` | App name in app header |
| `app.version` | `.font(.caption2)` | Version string in app header |
| `footer.label` | `.font(.caption2)` | Footer refresh time, labels |

### 11.3 Spacing Tokens

| Token | Value | Usage |
|-------|-------|-------|
| `spacing.row` | `8pt` | `VStack(spacing: 8)` inter-row gap in AccountDetail and usageContent() |
| `spacing.rowHStack` | `4pt` | `HStack(spacing: 4)` within UsageRow |
| `spacing.rowHPad` | `4pt` | `.padding(.horizontal, 4)` inside UsageRow |
| `spacing.sectionHPad` | `12pt` | `.padding(.horizontal, 12)` on AccountDetail VStack |
| `spacing.headerV` | `8pt` | Vertical padding in AccountHeader |

### 11.4 Border / Shape Tokens

| Token | Value | Usage |
|-------|-------|-------|
| `shape.cornerRadius.card` | `8pt` | Removed from UsageRow in D1; retained for modal/sheet contexts |
| `shape.cornerRadius.row` | `0pt` | UsageRow has no corner radius |
| `shape.cornerRadius.button` | `6pt` | Error view CTA button |

### 11.5 Height Tokens

| Token | Value | Usage |
|-------|-------|-------|
| `height.usageRow` | `20pt` (minHeight) | `UsageRow.frame(minHeight: 20)` |
| `height.accountHeader` | `48pt` | `AccountHeader.frame(height: 48)` (unchanged) |
| `height.expandedRow` | `140pt` | `computedScrollHeight`, `computePopoverHeight()` |
| `height.collapsedRow` | `48pt` | `computedScrollHeight`, `computePopoverHeight()` |
| `height.headerFooter` | `92pt` | `computePopoverHeight()` (44 + 48) |
| `height.popoverMax` | `480pt` | `computePopoverHeight()` cap |
| `height.popoverMin` | `200pt` | `computePopoverHeight()` floor |

---

## 12. Risks and Mitigations

### R1 (HIGH, Accepted): Progress Bar Removed

**Risk:** Users accustomed to the spatial gauge lose proportional visual representation of utilization. The percentage text communicates the value numerically but not spatially.

**Expert consensus:** Accepted per SME consensus and user decision (ADR-003 context). The compact row design is the explicit goal of this ADR.

**Mitigation:** None required. `.help()` tooltips compensate for the removed subtitle context. Colored percentage provides sufficient utilization signal.

---

### R2 (MEDIUM): DisclosureGroup Internal Padding Variance

**Risk:** The ~8pt top/bottom padding within `DisclosureGroup` content area is not formally documented by Apple. It may vary across macOS versions (13/14/15), causing the 140pt `expandedRowHeight` constant to be slightly inaccurate.

**Mitigation:** Verify empirically with SwiftUI Previews on macOS 13 (minimum deployment target) and the current macOS version. Adjust the constant if observed height differs by more than 4pt. The 480pt `min(...)` cap bounds any overestimate.

---

### R3 (MEDIUM): Single-Account Popover Whitespace After D1

**Risk:** The single-account popover height constant (currently ~320pt) will produce ~60-80pt of excess whitespace at the bottom after D1 reduces content height to ~232pt.

**Mitigation:** Address as part of D3 by updating the single-account path in `computePopoverHeight()` to 240pt. If deferred, document as a known visual defect in the release.

---

### R4 (MEDIUM): Height Constants Must Update Atomically

**Risk:** `expandedRowHeight` in `AccountList.swift` and `ClaudeMonitorApp.swift` must be updated in the same commit. If only one file is updated, `ScrollView` height and popover height diverge, causing clipped content or excess whitespace.

**Mitigation:** D3 implementation step MUST touch both files in a single atomic commit. CI should fail if one file has 228 and the other has 140.

---

### R5 (MEDIUM): VStack Spacing Mismatch

**Risk:** If `usageContent()` VStack spacing is not updated from 16 to 8, single-account mode will have wider inter-row gaps than multi-account expanded mode — inconsistent vertical rhythm across modes.

**Mitigation:** Treat the spacing change as a mandatory part of D1, not optional cleanup. Listed explicitly in Section 7.1 and the verification checklist.

---

### R6 (MEDIUM): ACL Dialog User Denies Access

**Risk:** Users who click "Deny" on the `SecItemCopyMatching` keychain dialog see `KeychainError.accessDenied`. If this surfaces as a generic error, users cannot self-resolve.

**Mitigation:** Specific `accessDenied` error view with "Open Privacy Settings" button (Section 10.1). Release notes MUST mention the dialog (Section 10.3).

---

### R7 (LOW): Accessibility Regression from Progress Bar Removal

**Risk:** The current `accessibilityLabel` / `accessibilityValue` on the progress bar `GeometryReader` must transfer correctly to the compact `HStack`. Incorrect transfer causes VoiceOver to read nothing or structural noise.

**Mitigation:** D1 includes explicit `.accessibilityElement(children: .ignore)`, `.accessibilityLabel`, and `.accessibilityValue` on the `HStack` (see Section 6.1). Verify with VoiceOver on macOS before shipping.

---

### R8 (LOW): No Automated Test Coverage

**Risk:** D1-D4 have no automated test coverage. All validation is manual.

**Mitigation:** SwiftUI Previews at 1/2/3/5 accounts; manual VoiceOver testing; manual boundary testing at 69.5% and 89.5%; keychain dialog test on a fresh install or after revoking permissions.

---

### R9 (LOW): D2 Rounding Causes Apparent Percentage Increases

**Risk:** Users near threshold boundaries will see displayed percentages increase by 0-1% after D2. A user at 89.7% who previously saw "89%" will now see "90%" (and red status). This may surprise users who expect continuity.

**Mitigation:** Release notes MUST note: "Percentage display values may increase by up to 1% due to a rounding accuracy fix." This is a correctness improvement, not a regression.

---

## 13. Verification Checklist

### Manual Testing Steps

#### D2 Verification (Rounding)
- [ ] Mock `sessionUtilization = 89.7` → `sessionPercentage` displays "90%" (was "89%")
- [ ] Mock `sessionUtilization = 89.4` → `sessionPercentage` displays "89%"
- [ ] Mock `sessionUtilization = 69.5` → `sessionPercentage` displays "70%" (triggers orange)
- [ ] Mock `sessionUtilization = 69.4` → `sessionPercentage` displays "69%" (stays green)
- [ ] Mock `weeklyUtilization = 0.5` → `weeklyPercentage` displays "0%" (banker's rounding: 0.5 → 0, round-half-to-even)
- [ ] `bottleneck` computed property returns correct result with rounded values

#### D4 Verification (Keychain)
- [ ] Fresh install / revoke permissions: ACL dialog appears on first launch
- [ ] Clicking "Always Allow" → app reads keychain, displays usage normally
- [ ] Clicking "Deny" → `accessDenied` error view appears with "Open Privacy Settings" button
- [ ] "Open Privacy Settings" button opens System Settings > Privacy & Security
- [ ] After allowing access in System Settings → app recovers on next refresh
- [ ] Instruments: no `security` subprocess spawned during keychain read
- [ ] `readKeychainNative` is called synchronously (no continuation, no `nonisolated`)

#### D1 Verification (Compact Row)
- [ ] SwiftUI Preview: 1 account — rows render without clipping at `minHeight: 20`
- [ ] SwiftUI Preview: 2 accounts — rows render without clipping
- [ ] SwiftUI Preview: 3 accounts — rows render without clipping
- [ ] SwiftUI Preview: 5 accounts — rows render without clipping
- [ ] Timer visible when `percentage >= 70` and `resetsAt != nil`
- [ ] Timer NOT visible when `percentage < 70`
- [ ] `.help()` tooltip appears on hover over label text
- [ ] `UsageRowStyle` — zero references in codebase (`grep -r UsageRowStyle`)
- [ ] `subtitle:` parameter — zero references in UsageRow call sites (`grep -r "subtitle:"`)
- [ ] `style:` parameter — zero references in UsageRow call sites (`grep -r "style: \.card\|style: \.inline"`)
- [ ] `VStack(spacing: 8)` in `usageContent()` (was 16)
- [ ] Pixel-identity comments removed/updated in `UsageView.swift`

#### D1 VoiceOver Verification
- [ ] Enable VoiceOver; open popover
- [ ] Navigate to Session row at 45% → hears "Session usage, 45 percent"
- [ ] Navigate to Weekly row at 72% with timer → hears "Weekly usage, 72 percent, resets in 2 hours 15 minutes"
- [ ] Navigate to Sonnet row at 91% with timer → hears "Sonnet Only usage, 91 percent, resets in N minutes"
- [ ] Navigate to Session row at 72%, `resetsAt == nil` → hears "Session usage, 72 percent" (no timer)
- [ ] Navigate to row at 72% with resetsAt in past → hears "Session usage, 72 percent, resets now"

#### D3 Verification (Height Constants)
- [ ] Both `AccountList.swift` and `ClaudeMonitorApp.swift` updated in the same commit
- [ ] `expandedRowHeight = 140` in both files (or empirically-adjusted value)
- [ ] 3 accounts: popover height ≈ 328pt (visible without scrolling)
- [ ] 6 accounts: popover height ≈ 472pt (just within cap)
- [ ] 7+ accounts: popover scrollable at 480pt cap
- [ ] Single-account path in `computePopoverHeight()` updated to ~240pt (no excess whitespace with 1 account)
- [ ] Single-account popover: ≤ 240pt (no significant whitespace)
- [ ] No clipped content at bottom of expanded account detail

---

## 14. Out of Scope

The following items were explicitly evaluated and excluded from this ADR's scope. They should not be addressed in D1-D4 implementation:

| Item | Reason for Exclusion |
|------|---------------------|
| Collapsed header countdown timer | Complex animation state; separate design decision needed |
| `AccountRecord` / `AccountUsage` Decodable migration | Data model change; separate ADR scope |
| OAuth WKWebView refresh flow | Auth architecture; separate ADR scope |
| `UsageManager` decomposition into services | Refactoring; no user-visible benefit in this ADR |
| Summary Strip (aggregate utilization) | Additive feature; separate design + ADR required |
| Row transition animations / hysteresis | Animation complexity; separate design decision |
| Persistence changes (UserDefaults) | Not required for layout changes |
| Refresh architecture changes (60s polling, TaskGroup) | Not impacted by layout or keychain changes |
| Menu bar status item changes | Not impacted by popover layout changes |
| `LayoutConstants` enum extraction | Noted as worthwhile if a fourth height change occurs; deferred |
| `LiveIndicator` Reduce Motion fix | Accessibility gap noted (Section 9.5); out of D1 scope |
| Snapshot testing dependency | New test infrastructure; separate decision required |
| Unit tests for `readKeychainNative` | Security framework mocking complexity; deferred |

---

*End of Specification*

**Next Steps:**
1. Send to design-reviewer for review
2. Address reviewer feedback in revision iterations
3. Upon spec acceptance, hand off to implementation team referencing ADR-003
