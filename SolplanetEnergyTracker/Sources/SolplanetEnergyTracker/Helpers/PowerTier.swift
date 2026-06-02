import Foundation

/// Semantic colour buckets for menu-bar segments and popover accents (plan §7).
/// Kept UI-framework-free in the library; the app maps each case to a system
/// `Color`/`NSColor` so it adapts to light/dark automatically.
public enum PowerTier: String, Sendable, Equatable, CaseIterable {
    case neutral
    case good
    case info
    case warning
    case critical
}

public enum PowerTiers {
    /// SOC: <15% critical, 15–40% warning, 40–80% info, >80% good (plan §7).
    public static func soc(_ percent: Percent) -> PowerTier {
        switch percent.value {
        case ..<15: return .critical
        case ..<40: return .warning
        case ..<80: return .info
        default: return .good
        }
    }

    /// Battery flow: charging is good (storing energy), discharging is a warning
    /// (draining), idle neutral.
    public static func battery(_ direction: BatteryDirection) -> PowerTier {
        switch direction {
        case .charging: return .good
        case .discharging: return .warning
        case .idle: return .neutral
        }
    }

    /// Grid flow: export good (selling), import critical (buying), idle neutral.
    public static func grid(_ state: GridState) -> PowerTier {
        guard state.available else { return .neutral }
        switch state.direction {
        case .exporting: return .good
        case .importing: return .critical
        case .idle: return .neutral
        }
    }
}
