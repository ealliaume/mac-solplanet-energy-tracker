import Foundation

/// What the menu-bar label shows. Persisted in preferences (plan §7). Defaults:
/// PV on, battery watt+percent, load on, grid off, temperature off.
public struct MenuBarDisplayOptions: Sendable, Codable, Equatable {
    public enum BatteryDisplay: String, Sendable, Codable, CaseIterable, Identifiable {
        case watt
        case percent
        case both
        case none

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .watt: return "Watts"
            case .percent: return "Percent"
            case .both: return "Both"
            case .none: return "Hidden"
            }
        }
    }

    public var showPV: Bool
    public var battery: BatteryDisplay
    public var showLoad: Bool
    public var showGrid: Bool
    public var showTemperature: Bool

    public init(showPV: Bool = true,
                battery: BatteryDisplay = .both,
                showLoad: Bool = true,
                showGrid: Bool = false,
                showTemperature: Bool = false) {
        self.showPV = showPV
        self.battery = battery
        self.showLoad = showLoad
        self.showGrid = showGrid
        self.showTemperature = showTemperature
    }

    public static let `default` = MenuBarDisplayOptions()
}
