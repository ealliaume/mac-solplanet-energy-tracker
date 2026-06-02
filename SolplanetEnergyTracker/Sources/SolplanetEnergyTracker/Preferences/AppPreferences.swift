import Foundation

/// App preferences seam. Injectable so logic can be tested without touching the
/// real `UserDefaults` (`docs/SWIFT-TESTABILITY.md`). Keys are namespaced
/// `solplanet-tracker.` (plan §10).
public protocol AppPreferences: AnyObject, Sendable {
    /// The single configured inverter (v1 exposes one; storage is an array so the
    /// multi-inverter seam stays open — plan §17.2).
    var inverters: [ConnectionSettings] { get set }
    /// Poll cadence; always read back clamped to the 5 s floor.
    var refreshIntervalSeconds: TimeInterval { get set }
    /// Which metrics the menu-bar label shows.
    var menuBarDisplayOptions: MenuBarDisplayOptions { get set }
    /// Whether to check GitHub for a newer release in the background.
    var updatesAutoCheckEnabled: Bool { get set }
    /// Versions the user explicitly chose to skip; the update banner stays
    /// dismissed for these across launches.
    var updatesDismissedVersions: [String] { get set }
}

public extension Notification.Name {
    /// Posted after `menuBarDisplayOptions` changes so the menu bar re-renders
    /// immediately rather than waiting for the next poll.
    static let menuBarDisplayOptionsChanged = Notification.Name("solplanet-tracker.menuBarDisplayOptionsChanged")
}

public extension AppPreferences {
    /// Convenience for the v1 single-inverter UI.
    var primaryInverter: ConnectionSettings? {
        get { inverters.first }
        set {
            if let newValue { inverters = [newValue] } else { inverters = [] }
        }
    }
}

/// `UserDefaults`-backed implementation.
public final class UserDefaultsAppPreferences: AppPreferences, @unchecked Sendable {
    // @unchecked Sendable: UserDefaults is thread-safe; this type only forwards to it.
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        static let inverters = "solplanet-tracker.connection.inverters"
        static let refreshInterval = "solplanet-tracker.refreshIntervalSeconds"
        static let menuBarDisplayOptions = "solplanet-tracker.menuBarDisplayOptions"
        static let updatesAutoCheckEnabled = "solplanet-tracker.updatesAutoCheckEnabled"
        static let updatesDismissedVersions = "solplanet-tracker.updatesDismissedVersions"
    }

    /// Process-wide instance shared by the poll pipeline (AppDelegate) and the
    /// SwiftUI Settings scene so edits take effect on the next tick.
    public static let shared = UserDefaultsAppPreferences()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var inverters: [ConnectionSettings] {
        get {
            guard let data = defaults.data(forKey: Key.inverters),
                  let decoded = try? decoder.decode([ConnectionSettings].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.inverters)
        }
    }

    public var refreshIntervalSeconds: TimeInterval {
        get {
            let stored = defaults.object(forKey: Key.refreshInterval) as? Double
            return PollingLimits.clamp(stored ?? PollingLimits.defaultRefreshInterval)
        }
        // Clamp on the way in too — never trust a caller to honour the floor.
        set { defaults.set(PollingLimits.clamp(newValue), forKey: Key.refreshInterval) }
    }

    public var menuBarDisplayOptions: MenuBarDisplayOptions {
        get {
            guard let data = defaults.data(forKey: Key.menuBarDisplayOptions),
                  let decoded = try? decoder.decode(MenuBarDisplayOptions.self, from: data) else {
                return .default
            }
            return decoded
        }
        set {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Key.menuBarDisplayOptions)
        }
    }

    public var updatesAutoCheckEnabled: Bool {
        // Defaults to on when never set.
        get { defaults.object(forKey: Key.updatesAutoCheckEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.updatesAutoCheckEnabled) }
    }

    public var updatesDismissedVersions: [String] {
        get { defaults.stringArray(forKey: Key.updatesDismissedVersions) ?? [] }
        set { defaults.set(newValue, forKey: Key.updatesDismissedVersions) }
    }
}
