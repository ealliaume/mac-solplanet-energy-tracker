import Foundation

/// Compile-time identity and hard operational limits for the app. Kept in the
/// library target so both the executable and the test target read the same
/// source of truth (no string drift between the menu bar, the bundle, and CI).
public enum AppInfo {
    /// User-facing product name (window titles, About box, bundle display name).
    public static let displayName = "Solplanet Battery Energy Tracker"

    /// Executable / bundle base name.
    public static let binaryName = "SolplanetBatteryEnergyTracker"

    /// Reverse-DNS bundle identifier. Homebrew distribution deferred (plan §17).
    public static let bundleIdentifier = "io.github.ealliaume.solplanet-energy-tracker"

    /// Directory name under `~/.cache` for the latest reading, history, and logs.
    public static let cacheDirectoryName = "solplanet-energy-tracker"

    /// Text shown in the menu bar before any inverter is configured. Tapping the
    /// item opens Settings so the user can enter the dongle IP / serial number.
    public static let unconfiguredLabel = "Configure inverter"
}

/// Hard limits on how the poller may talk to the dongle.
///
/// The AISWEI ESP32 dongle is fragile under tight polling — community reports
/// describe it becoming unreachable for an extended window after being hammered.
/// The refresh interval is therefore floored here and clamped in the preference
/// setter; the UI is never trusted to enforce it. See `CLAUDE.md` and plan §4/§16.
public enum PollingLimits {
    /// Smallest permitted gap between two polls of the same dongle.
    public static let minimumRefreshInterval: TimeInterval = 5

    /// Default gap used on first launch.
    public static let defaultRefreshInterval: TimeInterval = 60

    /// Clamps a requested interval up to the safe floor. Callers must route every
    /// user-supplied interval through here before scheduling a poll.
    public static func clamp(_ requested: TimeInterval) -> TimeInterval {
        max(requested, minimumRefreshInterval)
    }
}
