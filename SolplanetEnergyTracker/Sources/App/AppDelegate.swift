import AppKit
import SwiftUI
import SolplanetEnergyTrackerLib
import AppIconKit

/// Owns the status item, the polling pipeline, and the app lifecycle. Menubar-only
/// (no Dock icon). Shows "Configure inverter" until a dongle is configured, then
/// live `☀ PV  🔋 SOC` text refreshed by the poll loop.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    private let preferences = UserDefaultsAppPreferences.shared
    private let cacheDirectory = CacheDirectory.makeDefault()
    private lazy var store = ReadingsStore(readings: (try? ReadingsFileManager(directory: cacheDirectory).read()) ?? [])
    private var runner: PollerRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only: no Dock icon, no app-switcher entry. Pairs with
        // LSUIElement=true in the bundled Info.plist (set by the dist script).
        NSApp.setActivationPolicy(.accessory)

        if let icon = AppIconRenderer.makeImage() {
            NSApp.applicationIconImage = icon
        }

        seedInverterFromEnvironmentIfNeeded()
        installStatusItem()
        startPolling()

        // Re-render the label immediately when the user edits the display options.
        NotificationCenter.default.addObserver(
            forName: .menuBarDisplayOptionsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let runner = runner
        Task { await runner?.stop() }
    }

    // MARK: status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = menuBarTitle()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                historyReader: HistoryReader(directory: cacheDirectory),
                onRefresh: { [weak self] in
                    guard let runner = self?.runner else { return }
                    Task { await runner.refreshNow() }
                },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        self.popover = popover
    }

    private func refreshTitle() {
        statusItem?.button?.title = menuBarTitle()
    }

    private func menuBarTitle() -> String {
        MenuBarSummary.text(for: store.primary, options: preferences.menuBarDisplayOptions)
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func openSettings() {
        // Close the transient popover first so the Settings window takes focus.
        popover?.performClose(nil)

        // An app-owned window, rather than the SwiftUI `Settings` scene: the scene's
        // open action (`showSettingsWindow:`) is unreliable to invoke from an
        // `.accessory` app with no app menu, so we present the same view ourselves.
        if settingsWindow == nil {
            // NSHostingController drives the window to its view's fitting size,
            // which collapses a Form/TabView to ~zero height. Use an explicit
            // content rect + NSHostingView so the window keeps a usable size.
            let contentRect = NSRect(x: 0, y: 0, width: 460, height: 560)
            let window = NSWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = AppInfo.displayName
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: UserDefaultsAppPreferences.shared))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: polling pipeline

    private func startPolling() {
        let trustedHosts = Set(preferences.inverters.map(\.host.rawValue))
        let session = SolplanetSession.make(trustedHosts: trustedHosts)
        let poller = InverterPoller(
            connector: SolplanetConnector(httpClient: session),
            fileManager: ReadingsFileManager(directory: cacheDirectory),
            recorder: SnapshotRecorder(directory: cacheDirectory)
        )

        let preferences = self.preferences
        let runner = PollerRunner(
            poller: poller,
            settingsProvider: { preferences.primaryInverter },
            intervalProvider: { preferences.refreshIntervalSeconds },
            onOutcome: { [weak self] outcome in
                Task { @MainActor in self?.apply(outcome) }
            }
        )
        self.runner = runner
        Task { await runner.start() }
    }

    private func apply(_ outcome: PollOutcome) {
        switch outcome {
        case .success(let reading):
            store.update(reading)
        case .offline(_, let lastGood):
            if let lastGood { store.update(lastGood.markedOffline()) }
        }
        refreshTitle()
    }

    /// Lets the app run against a real dongle before the Connection settings UI
    /// exists: `SOLPLANET_TRACKER_HOST` + `SOLPLANET_TRACKER_SN` seed the single
    /// inverter on first launch if none is configured.
    private func seedInverterFromEnvironmentIfNeeded() {
        guard preferences.inverters.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SOLPLANET_TRACKER_HOST"], !host.isEmpty,
              let serial = env["SOLPLANET_TRACKER_SN"], !serial.isEmpty else { return }
        preferences.primaryInverter = ConnectionSettings(host: Hostname(host), serialNumber: SerialNumber(serial))
    }
}
