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
    private lazy var pidGuard = PidGuard(pidFileURL: cacheDirectory.root.appendingPathComponent("app.pid"))
    private lazy var logger = FileLogger(
        fileURL: cacheDirectory.appLogURL,
        minLevel: LogLevel.parse(ProcessInfo.processInfo.environment[AppInfo.logLevelEnvKey]) ?? .info
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: if another live copy already owns the pid file, bow out.
        if case .alreadyRunning(let pid) = (try? pidGuard.acquire()) {
            log(.warning, "another instance is running (pid \(pid)); exiting")
            NSApp.terminate(nil)
            return
        }

        // Menubar-only: no Dock icon, no app-switcher entry. Pairs with
        // LSUIElement=true in the bundled Info.plist (set by the dist script).
        NSApp.setActivationPolicy(.accessory)

        if let icon = AppIconRenderer.makeImage() {
            NSApp.applicationIconImage = icon
        }

        log(.info, "launched \(AppInfo.displayName) \(AppInfo.currentVersion)")
        purgeOldLogs()
        seedInverterFromEnvironmentIfNeeded()
        installStatusItem()
        startPolling()
        startUpdateChecks()

        // Re-render the label immediately when the user edits the display options.
        NotificationCenter.default.addObserver(
            forName: .menuBarDisplayOptionsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pidGuard.release()
        let runner = runner
        Task { await runner?.stop() }
    }

    // MARK: logging

    private func log(_ level: LogLevel, _ message: String) {
        let logger = logger
        Task { await logger.log(level, message) }
    }

    private func purgeOldLogs() {
        let directory = cacheDirectory.root
        Task.detached { LogCleaner(directory: directory).purge() }
    }

    // MARK: updates

    private func startUpdateChecks() {
        guard preferences.updatesAutoCheckEnabled else { return }
        let checker = UpdateChecker(
            httpClient: URLSession.shared,
            owner: AppInfo.repoOwner,
            repo: AppInfo.repoName
        )
        Task { [weak self] in
            // Check now, then once a day while the app runs.
            let oneDay: UInt64 = 24 * 60 * 60 * 1_000_000_000
            while !Task.isCancelled {
                await self?.runUpdateCheck(checker)
                try? await Task.sleep(nanoseconds: oneDay)
            }
        }
    }

    private func runUpdateCheck(_ checker: UpdateChecker) async {
        do {
            let status = try await checker.check(currentVersion: AppInfo.currentVersion)
            if case .updateAvailable(let version, let url) = status {
                store.availableUpdate = AvailableUpdate(version: version.description, url: url)
                log(.info, "update available: \(version)")
            }
        } catch {
            log(.info, "update check skipped: \(error)")
        }
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
        case .offline(let reason, let lastGood):
            log(.warning, "poll offline: \(reason)")
            if let lastGood { store.markOffline(lastGood.markedOffline()) }
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
