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

    // MARK: update machinery
    private var updateScheduler: UpdateScheduler?
    private var updateInstaller: UpdateInstaller?
    private var installationDetector: InstallationDetector?
    private var updateDownloader: UpdateDownloader?
    private var brewUpgradeRunner: BrewUpgradeRunner?
    /// Holds the in-flight install Task so a second "Install" click doesn't kick
    /// off a parallel pipeline.
    private var activeInstallTask: Task<Void, Never>?
    /// Captured at install start so the finalize step knows whether we ran the
    /// Homebrew or manual path.
    private var activeInstallKind: InstallationKind?
    private var activeInstallBundlePath: String?

    /// Observable update state shared by the popover banner and the Settings tab.
    static let sharedUpdateState = UpdateState()
    /// Pointer to the running scheduler so Settings can trigger a manual check.
    static var sharedUpdateScheduler: UpdateScheduler?
    /// Exposed to Settings so the user can start an install without the popover.
    static var sharedTriggerUpdateInstall: (() -> Void)?
    /// Called when the user clicks "Restart now" once the update is staged
    /// (manual) or installed by Homebrew.
    static var sharedTriggerRestart: (() -> Void)?

    /// Display name used to synthesize the install target when running from a
    /// non-`.app` location (e.g. `swift run`). Mirrors `build-app-bundle.sh`.
    private static let appBundleDisplayName = AppInfo.displayName

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
        stripOwnQuarantineIfNeeded()
        purgeOldLogs()
        seedInverterFromEnvironmentIfNeeded()
        installStatusItem()
        startPolling()
        setupUpdateScheduler()

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

    /// Defensive first-launch fix for the ad-hoc-signed build: strip our own
    /// `com.apple.quarantine` xattr so Gatekeeper doesn't block launch regardless
    /// of whether the user passed `--no-quarantine` at `brew install` (plan §1,
    /// §4, §9). Best-effort and only meaningful from a real `.app` bundle.
    private func stripOwnQuarantineIfNeeded() {
        let bundlePath = Bundle.main.bundleURL.path
        guard bundlePath.hasSuffix(".app") else { return }
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func purgeOldLogs() {
        let directory = cacheDirectory.root
        Task.detached { LogCleaner(directory: directory).purge() }
    }

    // MARK: updates

    /// Running build's marketing version, or nil when launched as a bare binary
    /// (no Info.plist) — used to decide whether update checks make sense.
    static func currentAppVersion(bundle: Bundle = .main) -> SemanticVersion? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return SemanticVersion(string: raw)
    }

    /// Update checks are pointless when there is no real bundle version to
    /// compare against the GitHub release tag (e.g. `swift run`).
    static func areUpdateChecksUnavailable(bundle: Bundle = .main) -> Bool {
        currentAppVersion(bundle: bundle) == nil
    }

    static func currentAppVersionLabel() -> String {
        currentAppVersion()?.rawValue ?? "development build"
    }

    private func setupUpdateScheduler() {
        guard !Self.areUpdateChecksUnavailable(),
              let effectiveVersion = Self.currentAppVersion() else {
            log(.info, "update checks unavailable (no bundle version); skipping scheduler")
            return
        }
        Self.sharedUpdateState.dismissedVersions = Set(preferences.updatesDismissedVersions)

        let bundlePath = Bundle.main.bundleURL.path
        let detector = InstallationDetector(bundlePath: bundlePath)
        self.installationDetector = detector
        self.updateInstaller = UpdateInstaller()
        self.updateDownloader = UpdateDownloader()
        self.brewUpgradeRunner = BrewUpgradeRunner()

        let scheduler = UpdateScheduler(
            checker: UpdateChecker(httpClient: URLSession.shared, owner: AppInfo.repoOwner, repo: AppInfo.repoName),
            detector: detector,
            currentVersion: effectiveVersion,
            preferencesAccessor: { UserDefaultsAppPreferences.shared },
            stateAccessor: { Self.sharedUpdateState },
            onUpdateAvailable: { [weak self] update, kind in
                self?.presentUpdateAlert(update: update, kind: kind)
            }
        )
        self.updateScheduler = scheduler
        Self.sharedUpdateScheduler = scheduler
        Self.sharedTriggerUpdateInstall = { [weak self] in self?.triggerUpdateInstall() }
        Self.sharedTriggerRestart = { [weak self] in self?.triggerRestart() }
        Task { await scheduler.start() }
    }

    private func presentUpdateAlert(update: AvailableUpdate, kind: InstallationKind) {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "Update available"
        alert.informativeText = "Version \(update.version.rawValue) of \(AppInfo.displayName) is available. Install it now?"
        alert.alertStyle = .informational
        let installLabel = kind == .homebrewCask ? "Update via Homebrew" : "Install"
        alert.addButton(withTitle: installLabel)
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip this version")
        // .accessory apps don't get focus by default; activate so the modal
        // surfaces above other windows when the user is mid-task.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        switch alert.runModal() {
        case .alertFirstButtonReturn: triggerUpdateInstall()
        case .alertThirdButtonReturn: skipCurrentUpdate()
        default: break
        }
    }

    /// Kicks off the in-app preparation pipeline (download/extract for manual,
    /// `brew upgrade --cask` streaming for Homebrew). The app stays alive; when
    /// the pipeline reaches `readyToRestart`, the banner exposes "Restart now".
    private func triggerUpdateInstall() {
        if activeInstallTask != nil { return } // re-entrancy guard
        guard let detector = installationDetector,
              let downloader = updateDownloader,
              let brewRunner = brewUpgradeRunner,
              let update = Self.sharedUpdateState.availableUpdate else {
            return
        }
        let detectedKind = Self.sharedUpdateState.installationKind ?? .manual
        let runningPath = Bundle.main.bundleURL.path
        let bundlePath: String
        if detectedKind == .manual && !runningPath.hasSuffix(".app") {
            guard let chosen = Self.promptForInstallDirectory(startingAt: runningPath) else { return }
            bundlePath = (chosen as NSString).appendingPathComponent("\(Self.appBundleDisplayName).app")
        } else {
            bundlePath = runningPath
        }

        Self.sharedUpdateState.setPreparing()
        activeInstallBundlePath = bundlePath

        activeInstallTask = Task { [weak self] in
            do {
                // Resolve brew at install time too — the user may have installed
                // Homebrew since the periodic check.
                let brewPath = await detector.brewExecutablePath()
                let effectiveKind: InstallationKind = (detectedKind == .homebrewCask && brewPath != nil) ? .homebrewCask : .manual
                await MainActor.run { self?.activeInstallKind = effectiveKind }

                switch effectiveKind {
                case .homebrewCask:
                    guard let brew = brewPath else {
                        await MainActor.run { Self.sharedUpdateState.setFailed("Homebrew binary disappeared after detection.") }
                        return
                    }
                    try await brewRunner.runUpgrade(
                        brewExecutablePath: brew,
                        caskName: InstallationDetector.homebrewCaskName,
                        onEvent: { event in
                            Task { @MainActor in
                                if case .outputLine(let line) = event {
                                    Self.sharedUpdateState.setRunningHomebrew(lastLine: line)
                                }
                            }
                        }
                    )
                    await MainActor.run { Self.sharedUpdateState.setReadyToRestart(stagedAppPath: nil) }

                case .manual:
                    let stagedURL = try await downloader.downloadAndStage(
                        update: update,
                        onEvent: { event in
                            Task { @MainActor in Self.applyDownloadEvent(event) }
                        }
                    )
                    await MainActor.run { Self.sharedUpdateState.setReadyToRestart(stagedAppPath: stagedURL.path) }
                }
            } catch is CancellationError {
                await MainActor.run { Self.sharedUpdateState.setFailed("Install cancelled.") }
            } catch {
                let message = String(describing: error)
                await MainActor.run { Self.sharedUpdateState.setFailed(message) }
            }
            await MainActor.run { self?.activeInstallTask = nil }
        }
    }

    @MainActor
    private static func applyDownloadEvent(_ event: UpdateDownloadEvent) {
        switch event {
        case .progress(let received, let total):
            Self.sharedUpdateState.setDownloading(received: received, total: total)
        case .verifying:
            Self.sharedUpdateState.setVerifying()
        case .extracting:
            Self.sharedUpdateState.setExtracting()
        }
    }

    /// User clicked "Restart now": build a finalize script (swap-and-relaunch for
    /// manual, relaunch-only for brew), launch it detached, then quit.
    private func triggerRestart() {
        guard let installer = updateInstaller,
              let update = Self.sharedUpdateState.availableUpdate,
              let bundlePath = activeInstallBundlePath,
              let kind = activeInstallKind else {
            return
        }
        let stagedAppPath = Self.sharedUpdateState.stagedAppPath
        Self.sharedUpdateState.setRestarting()
        let pid = ProcessInfo.processInfo.processIdentifier

        Task { [weak self] in
            do {
                let plan: UpdateFinalizationPlan
                switch kind {
                case .manual:
                    guard let staged = stagedAppPath else {
                        throw UpdateInstallerError.missingStagedApp(path: "(none)")
                    }
                    plan = try await installer.buildManualFinalizationPlan(
                        stagedAppPath: staged, bundlePath: bundlePath, currentPID: pid, update: update
                    )
                case .homebrewCask:
                    plan = try await installer.buildHomebrewFinalizationPlan(
                        bundlePath: bundlePath, currentPID: pid, update: update
                    )
                }

                if plan.requiresAdminPrivileges {
                    let confirmed = await MainActor.run { Self.confirmAdminElevation(version: update.version.rawValue) }
                    guard confirmed else {
                        await MainActor.run { Self.sharedUpdateState.setReadyToRestart(stagedAppPath: stagedAppPath) }
                        return
                    }
                    try await Self.launchWithAdminPrivileges(scriptPath: plan.scriptPath)
                } else {
                    try Self.launchDetached(scriptPath: plan.scriptPath)
                }
                await self?.gracefulShutdownAndTerminate()
            } catch {
                let message = String(describing: error)
                await MainActor.run { Self.sharedUpdateState.setFailed(message) }
            }
        }
    }

    private func skipCurrentUpdate() {
        guard let version = Self.sharedUpdateState.availableUpdate?.version.rawValue else { return }
        Self.sharedUpdateState.dismissCurrent()
        var stored = preferences.updatesDismissedVersions
        if !stored.contains(version) {
            stored.append(version)
            preferences.updatesDismissedVersions = stored
        }
    }

    private func laterUpdate() {
        // Clears the in-popover banner for this session without skipping.
        Self.sharedUpdateState.dismissCurrent()
    }

    @MainActor
    private static func promptForInstallDirectory(startingAt currentPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select installation directory"
        panel.message = "Choose where \(AppInfo.displayName) should be installed."
        panel.prompt = "Install here"
        let parent = (currentPath as NSString).deletingLastPathComponent
        if parent.contains("/.build/") || parent.hasSuffix("/.build") {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        } else {
            panel.directoryURL = URL(fileURLWithPath: parent)
        }
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    @MainActor
    private static func confirmAdminElevation(version: String) -> Bool {
        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.messageText = "Administrator permission required"
        alert.informativeText = "\(AppInfo.displayName) is installed in a location that requires administrator privileges to update. macOS will prompt you for your password to install version \(version)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Launch the install script as root via AppleScript. The bash script is
    /// spawned in the background (`&`) so osascript exits as soon as the user
    /// approves the prompt — the script waits for the parent to terminate before
    /// the actual swap.
    private static func launchWithAdminPrivileges(scriptPath: String) async throws {
        let escaped = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "/bin/bash \\"\(escaped)\\" >/dev/null 2>&1 &" with administrator privileges
        """
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: NSError(
                        domain: "SolplanetEnergyTracker.UpdateInstaller",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Authorization was cancelled or denied (status \(process.terminationStatus))."]
                    ))
                    return
                }
                continuation.resume()
            }
        }
    }

    private static func launchDetached(scriptPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        // Detach: redirect IO to /dev/null so the child outlives the app.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    @MainActor
    private func gracefulShutdownAndTerminate() async {
        pidGuard.release()
        let runner = runner
        let scheduler = updateScheduler
        await runner?.stop()
        await scheduler?.stop()
        NSApp.terminate(nil)
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
                updateState: Self.sharedUpdateState,
                onRefresh: { [weak self] in
                    guard let runner = self?.runner else { return }
                    Task { await runner.refreshNow() }
                },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) },
                onInstallUpdate: { [weak self] in self?.triggerUpdateInstall() },
                onRestartUpdate: { [weak self] in self?.triggerRestart() },
                onSkipUpdate: { [weak self] in self?.skipCurrentUpdate() },
                onLaterUpdate: { [weak self] in self?.laterUpdate() }
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
            window.contentView = NSHostingView(rootView: SettingsView(
                preferences: UserDefaultsAppPreferences.shared,
                updateState: Self.sharedUpdateState
            ))
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
