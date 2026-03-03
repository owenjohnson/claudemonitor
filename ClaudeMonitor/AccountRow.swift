import SwiftUI
import AppKit

// MARK: - AccountHeader (C2)

struct AccountHeader: View {
    let email: String
    let organizationName: String?
    let isLive: Bool
    let isActivelyRefreshing: Bool
    let highestUtilization: Int
    let utilizationColor: Color
    let lastUpdated: Date?
    let isExpanded: Bool   // D2: controls org name visibility in collapsed state

    init(
        email: String,
        organizationName: String?,
        isLive: Bool,
        isActivelyRefreshing: Bool = false,
        highestUtilization: Int,
        utilizationColor: Color,
        lastUpdated: Date? = nil,
        isExpanded: Bool = false
    ) {
        self.email = email
        self.organizationName = organizationName
        self.isLive = isLive
        self.isActivelyRefreshing = isActivelyRefreshing
        self.highestUtilization = highestUtilization
        self.utilizationColor = utilizationColor
        self.lastUpdated = lastUpdated
        self.isExpanded = isExpanded
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(email)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // D2: org name only shown when row is expanded
                if isExpanded, let org = organizationName {
                    Text(org)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if isLive {
                    LiveIndicator()
                } else if isActivelyRefreshing {
                    CachedBadge()
                } else {
                    StaleBadge()
                }

                Group {
                    Text("\(highestUtilization)%")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(utilizationColor)
                }
                .help(staleTooltip)
            }
        }
        .frame(height: 48)         // D2: reduced from 56pt
        .padding(.horizontal, 12)
        .padding(.vertical, 4)     // D2: reduced from 8pt
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint("Press Space to expand usage details")
    }

    private var accessibilityLabelText: String {
        let statusPart = isLive ? "Live" : (isActivelyRefreshing ? "Active" : "Stale")
        if !isLive, let updated = lastUpdated {
            let relative = updated.formatted(.relative(presentation: .named))
            return "\(email), \(statusPart), \(highestUtilization)% utilization, last updated \(relative)"
        }
        return "\(email), \(statusPart), \(highestUtilization)% utilization"
    }

    private var staleTooltip: String {
        guard !isLive else { return "" }
        if isActivelyRefreshing { return "Refreshing with cached token" }
        if let updated = lastUpdated {
            let absolute = updated.formatted(date: .abbreviated, time: .shortened)
            return "Data from \(absolute). This account is not currently active."
        }
        return "This account is not currently active."
    }
}

// MARK: - AccountDisclosureGroup (C4)

struct AccountDisclosureGroup: View {
    let accountUsage: AccountUsage
    let isExpanded: Binding<Bool>   // D1: lifted state from AccountList
    let onRemove: (() -> Void)?

    private var account: AccountRecord { accountUsage.account }

    // Uses bottleneck (D4) as the single source of truth — includes sonnet utilization.
    private var highestUtilization: Int {
        accountUsage.usage?.bottleneck.percentage ?? 0
    }

    private var utilizationColor: Color {
        // Stale accounts (no cached token) render in secondary (muted) color
        guard accountUsage.isCurrentAccount || accountUsage.isActivelyRefreshing else {
            return Color(NSColor.secondaryLabelColor)
        }
        return Color.forUtilization(highestUtilization)
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: isExpanded,
            content: { accountDetail },
            label: {
                AccountHeader(
                    email: account.email,
                    organizationName: account.organizationName,
                    isLive: accountUsage.isCurrentAccount,
                    isActivelyRefreshing: accountUsage.isActivelyRefreshing,
                    highestUtilization: highestUtilization,
                    utilizationColor: utilizationColor,
                    lastUpdated: accountUsage.lastUpdated,
                    isExpanded: isExpanded.wrappedValue   // D2: pass expansion state to header
                )
            }
        )
        .contextMenu {
            if !accountUsage.isCurrentAccount, let remove = onRemove {
                Button(role: .destructive) {
                    remove()
                } label: {
                    Label("Remove account", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var accountDetail: some View {
        if accountUsage.isCurrentAccount || accountUsage.isActivelyRefreshing {
            LiveAccountDetail(accountUsage: accountUsage)
        } else {
            StaleAccountDetail(accountUsage: accountUsage)
        }
    }

}
