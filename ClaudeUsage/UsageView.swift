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

            // Footer: compressed (gear menu) for multi-account, full for single-account (D3)
            if manager.accounts.count > 1 {
                compressedFooterView()
            } else {
                footerView()
            }
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
    
    // D3: 48pt compressed footer for multi-account mode.
    // CRITICAL (R6/RF1): Must include the .onChange(of: launchAtLogin) handler for SMAppService.
    // The ADR-002 D3 code sample omits it — this implementation adds it verbatim from footerView().
    @ViewBuilder
    func compressedFooterView() -> some View {
        HStack(spacing: 8) {
            if let lastUpdated = manager.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Gear menu: Check for Updates + Launch at Login
            Menu {
                Button(action: {
                    Task { await manager.checkForUpdates() }
                }) {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }

                Divider()

                // RF3: Toggle inside SwiftUI.Menu — .onChange may not fire on all macOS versions.
                // If it stops firing, replace with a Button that calls
                // SMAppService.mainApp.register() / .unregister() directly.
                Toggle("Launch at Login", isOn: $launchAtLogin)
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
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 48)
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

#Preview {
    UsageView(manager: UsageManager())
}
