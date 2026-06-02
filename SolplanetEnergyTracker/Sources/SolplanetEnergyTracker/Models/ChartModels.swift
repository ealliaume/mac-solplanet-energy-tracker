import Foundation

/// Time spans offered by the charts (plan §6/§8).
public enum ChartWindow: String, Sendable, CaseIterable, Identifiable {
    case sixHours
    case day
    case week
    case month
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sixHours: return "6h"
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    /// Span in seconds, or `nil` for "all history".
    public var seconds: TimeInterval? {
        let hour: TimeInterval = 3600
        switch self {
        case .sixHours: return 6 * hour
        case .day: return 24 * hour
        case .week: return 7 * 24 * hour
        case .month: return 30 * 24 * hour
        case .all: return nil
        }
    }
}

/// A plottable metric drawn from `PowerSnapshot`.
public enum ChartMetric: String, Sendable, CaseIterable, Identifiable {
    case pv
    case battery
    case soc
    case load
    case grid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pv: return "PV"
        case .battery: return "Battery"
        case .soc: return "SOC"
        case .load: return "Load"
        case .grid: return "Grid"
        }
    }

    /// Extracts this metric from a snapshot. `nil` ⇒ unavailable at that sample, so
    /// the chart breaks the line instead of bridging the gap.
    public func value(from snapshot: PowerSnapshot) -> Double? {
        switch self {
        case .pv: return snapshot.pv
        case .battery: return snapshot.battPower
        case .soc: return snapshot.soc
        case .load: return snapshot.load
        case .grid: return snapshot.gridAvailable ? snapshot.grid : nil
        }
    }
}

/// One plotted sample. `value == nil` is a deliberate gap marker.
public struct ChartPoint: Sendable, Identifiable, Equatable {
    public let id: Int
    public let date: Date
    public let value: Double?

    public init(id: Int, date: Date, value: Double?) {
        self.id = id
        self.date = date
        self.value = value
    }
}
