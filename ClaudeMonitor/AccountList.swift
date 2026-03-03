import SwiftUI

// MARK: - AccountList (C5/C6/D1/D2): multi-account accordion with exclusive expand/collapse

struct AccountList: View {
    let accounts: [AccountUsage]
    let onRemoveAccount: ((String) -> Void)?
    // D1: lifted accordion state — only one account expanded at a time.
    // nil means all-collapsed (valid state per ADR-002 D1).
    @State private var expandedEmail: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(accounts) { accountUsage in
                    let email = accountUsage.account.email
                    // D1: Binding adapter bridges String? state to the Bool that DisclosureGroup needs.
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
                            onRemoveAccount?(accountUsage.account.email)
                        }
                    )
                    Divider()
                }
            }
        }
        // D2: computedScrollHeight replaces the hardcoded 380pt cap.
        // NOTE: These constants (48pt collapsed, 140pt expanded) are shared with
        // computePopoverHeight() in ClaudeMonitorApp.swift. Update both together (RF5).
        .frame(maxHeight: computedScrollHeight)
        .onAppear {
            // D1: Auto-expand the live account when the popover opens.
            // On popover close+reopen, SwiftUI recreates AccountList and this fires again.
            expandedEmail = accounts.first(where: { $0.isCurrentAccount })?.account.email
        }
    }

    /// Estimated scroll area height assuming 1 expanded row + (N-1) collapsed rows.
    /// expandedRowHeight ≈ 140pt (48pt header + ~16pt DisclosureGroup padding + 3 × 20pt compact rows + 2 × 8pt spacing)
    /// collapsedRowHeight = 48pt
    /// NOTE: Shared constants with computePopoverHeight() in ClaudeMonitorApp.swift (RF5).
    private var computedScrollHeight: CGFloat {
        let n = CGFloat(accounts.count)
        let expanded: CGFloat = 140   // matches expandedRowHeight in computePopoverHeight()
        let collapsed: CGFloat = 48   // matches collapsedRowHeight in computePopoverHeight()
        let content = expanded + (n - 1) * collapsed
        return min(content, 380) // 380pt = 480pt cap minus 44pt app header minus 48pt compressed footer (D3)
    }
}
