import SwiftUI
import Combine

@main
struct ClaudeMonitorApp: App {
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
    var hostingController: NSHostingController<UsageView>?
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
        // Auto-update status item and popover size when accounts array changes (A8).
        // $accounts replaces the former $usage and $error sinks.
        usageManager.$accounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
                self?.updatePopoverSize()
            }
            .store(in: &cancellables)

        // Also observe noAccountError so the status bar updates for not-logged-in state (D1).
        usageManager.$noAccountError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
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
        // Seed tokenCache from persisted keychain tokens before first refresh
        usageManager.loadPersistedTokens()

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

        // Refresh every 60 seconds (B3: reduced from 120s to enable faster account-switch detection)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.usageManager.refresh()
            }
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = statusImage(symbolName: "clock.arrow.circlepath", color: .secondaryLabelColor)
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func setupPopover() {
        let hc = NSHostingController(rootView: UsageView(manager: usageManager))
        hostingController = hc
        popover = NSPopover()
        popover?.contentSize = measuredPopoverSize()
        popover?.behavior = .transient
        popover?.contentViewController = hc
    }

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        guard let liveAccount = usageManager.accounts.first(where: { $0.isCurrentAccount }) else {
            // No live account yet — loading or not logged in (D1: also check noAccountError)
            if usageManager.accounts.contains(where: { $0.error != nil }) || usageManager.noAccountError != nil {
                button.image = statusImage(symbolName: "xmark.circle.fill", color: .systemRed)
                button.title = ""
            } else {
                button.image = statusImage(symbolName: "clock.arrow.circlepath", color: .secondaryLabelColor)
                button.title = ""
            }
            button.imagePosition = .imageLeading
            return
        }

        if let usage = liveAccount.usage {
            let pct = usage.bottleneck.percentage
            let color: NSColor
            if pct >= 90 {
                color = .systemRed
            } else if pct >= 70 {
                color = .systemOrange
            } else {
                color = .systemGreen
            }
            button.image = statusImage(symbolName: "circle.fill", color: color)
            button.title = " \(pct)%"
            button.imagePosition = .imageLeading
        } else if liveAccount.error != nil {
            button.image = statusImage(symbolName: "xmark.circle.fill", color: .systemRed)
            button.title = ""
            button.imagePosition = .imageLeading
        } else {
            button.image = statusImage(symbolName: "clock.arrow.circlepath", color: .secondaryLabelColor)
            button.title = ""
            button.imagePosition = .imageLeading
        }
    }

    func updatePopoverSize() {
        popover?.contentSize = measuredPopoverSize()
    }

    /// Ask the hosting controller for the real content height at fixed width.
    private func measuredPopoverSize() -> NSSize {
        let width: CGFloat = 280
        let maxHeight: CGFloat = 600
        guard let hc = hostingController else { return NSSize(width: width, height: 240) }
        let ideal = hc.sizeThatFits(in: NSSize(width: width, height: maxHeight))
        let height = min(max(ideal.height, 120), maxHeight)
        return NSSize(width: width, height: height)
    }

    private func statusImage(symbolName: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = image.copy() as! NSImage
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
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
