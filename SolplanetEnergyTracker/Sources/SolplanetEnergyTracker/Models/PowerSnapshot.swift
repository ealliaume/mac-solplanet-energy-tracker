import Foundation

/// One history sample, deliberately flat and numeric so chart reads stay cheap
/// (plan §6). A metric is `nil` when unavailable (e.g. grid with no CT meter) so
/// charts break the line instead of bridging across a gap.
///
/// `battPower` is **signed for charts**: negative = charging, positive =
/// discharging (the magnitude+direction split lives on `InverterReading`; here we
/// re-fold it into one signed axis). `grid` is signed: positive = export.
public struct PowerSnapshot: Sendable, Codable, Equatable {
    public let t: String              // ISO 8601 timestamp (ISODate.rawValue)
    public let pv: Double
    public let battPower: Double
    public let soc: Double
    public let load: Double?
    public let loadQuality: String
    public let grid: Double?
    public let gridAvailable: Bool
    public let inverterAC: Double
    public let energyToday: Double?

    public init(t: String, pv: Double, battPower: Double, soc: Double, load: Double?,
                loadQuality: String, grid: Double?, gridAvailable: Bool,
                inverterAC: Double, energyToday: Double?) {
        self.t = t
        self.pv = pv
        self.battPower = battPower
        self.soc = soc
        self.load = load
        self.loadQuality = loadQuality
        self.grid = grid
        self.gridAvailable = gridAvailable
        self.inverterAC = inverterAC
        self.energyToday = energyToday
    }

    public init(reading: InverterReading) {
        let signedBattery: Double
        switch reading.battery.direction {
        case .charging: signedBattery = -reading.battery.power.value
        case .discharging: signedBattery = reading.battery.power.value
        case .idle: signedBattery = 0
        }

        let signedGrid: Double?
        if reading.grid.available {
            switch reading.grid.direction {
            case .exporting: signedGrid = reading.grid.power.value
            case .importing: signedGrid = -reading.grid.power.value
            case .idle: signedGrid = 0
            }
        } else {
            signedGrid = nil
        }

        self.init(
            t: reading.takenAt.rawValue,
            pv: reading.pv.value,
            battPower: signedBattery,
            soc: reading.battery.soc.value,
            load: reading.load.quality == .unavailable ? nil : reading.load.value.value,
            loadQuality: reading.load.quality.rawValue,
            grid: signedGrid,
            gridAvailable: reading.grid.available,
            inverterAC: reading.inverterAC.value,
            energyToday: reading.energyToday?.value
        )
    }

    /// Value-equality ignoring the timestamp — used to decide whether a new sample
    /// actually changed anything worth recording.
    public func hasSameValues(as other: PowerSnapshot) -> Bool {
        pv == other.pv && battPower == other.battPower && soc == other.soc &&
            load == other.load && loadQuality == other.loadQuality && grid == other.grid &&
            gridAvailable == other.gridAvailable && inverterAC == other.inverterAC &&
            energyToday == other.energyToday
    }
}
