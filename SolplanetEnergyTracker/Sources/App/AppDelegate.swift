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
    }

    func applicationWillTerminate(_ notification: Notification) {
        let runner = runner
        Task { await runner?.stop() }
    }

    // MARK: status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = store.menuBarText
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                store: store,
                historyReader: HistoryReader(directory: cacheDirectory),
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        self.popover = popover
    }

    private func refreshTitle() {
        statusItem?.button?.title = store.menuBarText
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
        NSApp.activate(ignoringOtherApps: true)
        let modern = Selector(("showSettingsWindow:"))
        let legacy = Selector(("showPreferencesWindow:"))
        if NSApp.responds(to: modern) {
            NSApp.perform(modern, with: nil)
        } else if NSApp.responds(to: legacy) {
            NSApp.perform(legacy, with: nil)
        }
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
