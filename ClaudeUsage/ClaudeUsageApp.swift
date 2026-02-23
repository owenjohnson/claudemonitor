import SwiftUI
import Combine

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var usageManager = UsageManager()
    var timer: Timer?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - menubar only
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupWakeNotification()
        setupUsageObserver()
        startFetching()
    }

    func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func setupUsageObserver() {
        // Auto-update status item when accounts array changes (A8).
        // $accounts replaces the former $usage and $error sinks.
        usageManager.$accounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    @objc func handleWake() {
        // Delay refresh after wake to allow keychain to unlock
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            await usageManager.refresh()
        }
    }

    func startFetching() {
        // Initial fetch and update check
        Task {
            // If system recently booted (within 60 seconds), wait before accessing keychain
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime < 60 {
                let delaySeconds = max(30 - uptime, 5)
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }

            await usageManager.refresh()
            await usageManager.checkForUpdates()
        }

        // Refresh every 2 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
            }
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "⏳"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 320)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: UsageView(manager: usageManager))
    }

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        guard let liveAccount = usageManager.accounts.first(where: { $0.isCurrentAccount }) else {
            // No live account yet — loading or not logged in
            if usageManager.accounts.contains(where: { $0.error != nil }) {
                button.title = "❌"
            } else {
                button.title = "⏳"
            }
            return
        }

        if let usage = liveAccount.usage {
            // Worst-case across session and weekly for the live account (OQ-3: stale excluded)
            let worstCasePct = max(usage.sessionPercentage, usage.weeklyPercentage)
            let emoji = usageManager.statusEmoji
            button.title = "\(emoji) \(worstCasePct)%"
        } else if liveAccount.error != nil {
            button.title = "❌"
        } else {
            button.title = "⏳"
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Bring to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
