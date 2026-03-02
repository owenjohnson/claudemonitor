import SwiftUI
import AppKit
import ServiceManagement

struct UsageView: View {
    @ObservedObject var manager: UsageManager
    @Environment(\.openURL) var openURL
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()

                if manager.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            // Update available banner
            if let newVersion = manager.updateAvailable {
                Button(action: {
                    openURL(URL(string: "https://github.com/richhickson/claudecodeusage/releases/latest")!)
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update Available: v\(newVersion)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            // C5: Conditional layout — single account uses existing layout (pixel-identical to v1.7);
            // two or more accounts use the multi-account accordion.
            if manager.accounts.count <= 1 {
                singleAccountContent()
            } else {
                multiAccountContent()
            }

            Divider()

            // Footer
            footerView()
        }
        .frame(width: 280)
    }

    // Single-account content — pixel-identical to v1.7
    @ViewBuilder
    func singleAccountContent() -> some View {
        if let error = manager.error {
            errorView(error)
        } else if let usage = manager.usage {
            usageContent(usage)
        } else {
            loadingView()
        }
    }

    // Multi-account accordion content
    @ViewBuilder
    func multiAccountContent() -> some View {
        AccountList(
            accounts: manager.accounts,
            onRemoveAccount: { email in
                manager.removeAccount(email: email)
            }
        )
    }
    
    @ViewBuilder
    func usageContent(_ usage: UsageData) -> some View {
        VStack(spacing: 16) {
            // Session usage
            UsageRow(
                title: "Session",
                subtitle: "5-hour window",
                percentage: usage.sessionPercentage,
                resetsAt: usage.sessionResetsAt,
                color: Color.forUtilization(usage.sessionPercentage)
            )

            // Weekly usage
            UsageRow(
                title: "Weekly",
                subtitle: "7-day window",
                percentage: usage.weeklyPercentage,
                resetsAt: usage.weeklyResetsAt,
                color: Color.forUtilization(usage.weeklyPercentage)
            )

            // Sonnet only (if available)
            if let sonnetPct = usage.sonnetPercentage {
                UsageRow(
                    title: "Sonnet Only",
                    subtitle: "Model-specific",
                    percentage: sonnetPct,
                    resetsAt: usage.sonnetResetsAt,
                    color: Color.forUtilization(sonnetPct)
                )
            }
        }
        .padding()
    }
    
    @ViewBuilder
    func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            if error.contains("Not logged in") {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text("Not Signed In")
                    .font(.headline)

                Text("This app uses credentials from Claude Code stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Please run `claude` in Terminal and log in first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Open Terminal & Run Claude") {
                    launchClaudeCLI()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Install Claude Code") {
                    openURL(URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func loadingView() -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading usage data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func footerView() -> some View {
        VStack(spacing: 8) {
            Button(action: {
                Task { await manager.checkForUpdates() }
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.top, 8)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }
                .padding(.horizontal)

            Divider()

            HStack {
                if let lastUpdated = manager.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    Task { await manager.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(manager.isLoading)

                Button(action: {
                    openURL(URL(string: "https://claude.ai")!)
                }) {
                    Image(systemName: "globe")
                }
                .buttonStyle(.borderless)

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)

            Divider()

            Text(manager.displayName ?? "Claude Usage")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    func launchClaudeCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

enum UsageRowStyle { case card, inline }

struct UsageRow: View {
    let title: String
    let subtitle: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color
    var style: UsageRowStyle = .card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100, height: 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title) usage")
                .accessibilityValue("\(percentage) percent")
            }
            .frame(height: 8)

            // Reset time
            if let resetsAt = resetsAt {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Resets \(formatTimeRemaining(resetsAt))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(style == .card ? 12 : 8)
        .background(style == .card ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .cornerRadius(style == .card ? 8 : 0)
    }
    
    func formatTimeRemaining(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)
        
        if diff <= 0 { return "soon" }
        
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        
        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "in \(days)d \(remainingHours)h"
        }
        
        return "in \(hours)h \(minutes)m"
    }
}

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
            liveAccountDetail
        } else {
            staleAccountDetail
        }
    }

    @ViewBuilder
    private var liveAccountDetail: some View {
        VStack(spacing: 8) {
            if accountUsage.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if let error = accountUsage.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 8)
            } else if let usage = accountUsage.usage {
                UsageRow(
                    title: "Session",
                    subtitle: "5-hour window",
                    percentage: usage.sessionPercentage,
                    resetsAt: usage.sessionResetsAt,
                    color: Color.forUtilization(usage.sessionPercentage),
                    style: .inline
                )
                UsageRow(
                    title: "Weekly",
                    subtitle: "7-day window",
                    percentage: usage.weeklyPercentage,
                    resetsAt: usage.weeklyResetsAt,
                    color: Color.forUtilization(usage.weeklyPercentage),
                    style: .inline
                )
                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        subtitle: "Model-specific",
                        percentage: sonnetPct,
                        resetsAt: usage.sonnetResetsAt,
                        color: Color.forUtilization(sonnetPct),
                        style: .inline
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var staleAccountDetail: some View {
        let staleColor = Color(NSColor.secondaryLabelColor)
        VStack(spacing: 8) {
            if let usage = accountUsage.usage {
                UsageRow(
                    title: "Session",
                    subtitle: "5-hour window",
                    percentage: usage.sessionPercentage,
                    resetsAt: nil,
                    color: staleColor,
                    style: .inline
                )
                UsageRow(
                    title: "Weekly",
                    subtitle: "7-day window",
                    percentage: usage.weeklyPercentage,
                    resetsAt: nil,
                    color: staleColor,
                    style: .inline
                )
                if let sonnetPct = usage.sonnetPercentage {
                    UsageRow(
                        title: "Sonnet Only",
                        subtitle: "Model-specific",
                        percentage: sonnetPct,
                        resetsAt: nil,
                        color: staleColor,
                        style: .inline
                    )
                }
            } else {
                Text("No usage data available for this account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }

            // Layer 3 staleness signal: timestamp
            if let updated = accountUsage.lastUpdated {
                HStack {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
    }

}

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
        // NOTE: These constants (48pt collapsed, 228pt expanded) are shared with
        // computePopoverHeight() in ClaudeUsageApp.swift. Update both together (RF5).
        .frame(maxHeight: computedScrollHeight)
        .onAppear {
            // D1: Auto-expand the live account when the popover opens.
            // On popover close+reopen, SwiftUI recreates AccountList and this fires again.
            expandedEmail = accounts.first(where: { $0.isCurrentAccount })?.account.email
        }
    }

    /// Estimated scroll area height assuming 1 expanded row + (N-1) collapsed rows.
    /// expandedRowHeight ≈ 228pt (48pt header + ~180pt detail)
    /// collapsedRowHeight = 48pt
    /// NOTE: Shared constants with computePopoverHeight() in ClaudeUsageApp.swift (RF5).
    private var computedScrollHeight: CGFloat {
        let n = CGFloat(accounts.count)
        let expanded: CGFloat = 228   // matches expandedRowHeight in computePopoverHeight()
        let collapsed: CGFloat = 48   // matches collapsedRowHeight in computePopoverHeight()
        let content = expanded + (n - 1) * collapsed
        return min(content, 380) // 380pt = 480pt cap minus 44pt app header minus 56pt footer area
    }
}

#Preview {
    UsageView(manager: UsageManager())
}
