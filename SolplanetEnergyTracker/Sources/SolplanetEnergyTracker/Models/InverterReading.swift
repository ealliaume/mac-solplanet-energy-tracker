import Foundation

/// Battery sub-state of a reading.
public struct BatteryState: Sendable, Hashable, Codable {
    public let power: Watts          // magnitude (always ≥ 0); direction carries the sign
    public let direction: BatteryDirection
    public let soc: Percent
    public let soh: Percent?
    public let voltage: Volts?

    public init(power: Watts, direction: BatteryDirection, soc: Percent,
                soh: Percent? = nil, voltage: Volts? = nil) {
        self.power = power
        self.direction = direction
        self.soc = soc
        self.soh = soh
        self.voltage = voltage
    }
}

/// House-load sub-state. `quality` says whether `value` can be trusted.
public struct LoadState: Sendable, Hashable, Codable {
    public let value: Watts
    public let quality: ReadingQuality

    public init(value: Watts, quality: ReadingQuality) {
        self.value = value
        self.quality = quality
    }
}

/// Grid sub-state. `available == false` ⇒ no CT meter; `power`/`direction` are
/// meaningless and should render as "n/a".
public struct GridState: Sendable, Hashable, Codable {
    public let power: Watts          // magnitude (≥ 0)
    public let direction: GridDirection
    public let available: Bool

    public init(power: Watts, direction: GridDirection, available: Bool) {
        self.power = power
        self.direction = direction
        self.available = available
    }

    public static let unavailable = GridState(power: 0, direction: .idle, available: false)
}

/// Derived health flags (replaces the reference app's vendor-outage fetch).
public struct InverterHealth: Sendable, Hashable, Codable {
    public let online: Bool
    public let stale: Bool
    public let errorCode: Int?
    public let meterEnabled: Bool

    public init(online: Bool, stale: Bool, errorCode: Int?, meterEnabled: Bool) {
        self.online = online
        self.stale = stale
        self.errorCode = errorCode
        self.meterEnabled = meterEnabled
    }
}

/// A fully-derived reading for one inverter, keyed by `host:serialNumber`. This is
/// the normalized model the rest of the app renders and persists — all the API
/// quirks (PV=-pac, sign conventions, scalings) are resolved before this point.
public struct InverterReading: Sendable, Hashable, Codable, Identifiable {
    public let host: Hostname
    public let serialNumber: SerialNumber
    public let model: String?
    public let firmware: String?
    public let takenAt: ISODate
    public let pv: Watts
    public let inverterAC: Watts
    public let battery: BatteryState
    public let load: LoadState
    public let grid: GridState
    public let temperature: Celsius?
    public let energyToday: KilowattHours?
    public let energyTotal: KilowattHours?
    public let health: InverterHealth

    public var id: String { "\(host.rawValue):\(serialNumber.rawValue)" }

    /// A copy of this last-good reading marked unreachable, so the UI can keep
    /// showing dimmed values when a poll fails instead of going blank (plan §9).
    public func markedOffline() -> InverterReading {
        InverterReading(
            host: host, serialNumber: serialNumber, model: model, firmware: firmware,
            takenAt: takenAt, pv: pv, inverterAC: inverterAC, battery: battery,
            load: load, grid: grid, temperature: temperature,
            energyToday: energyToday, energyTotal: energyTotal,
            health: InverterHealth(online: false, stale: true,
                                   errorCode: health.errorCode, meterEnabled: health.meterEnabled)
        )
    }

    public init(host: Hostname, serialNumber: SerialNumber, model: String?, firmware: String?,
                takenAt: ISODate, pv: Watts, inverterAC: Watts, battery: BatteryState,
                load: LoadState, grid: GridState, temperature: Celsius?,
                energyToday: KilowattHours?, energyTotal: KilowattHours?, health: InverterHealth) {
        self.host = host
        self.serialNumber = serialNumber
        self.model = model
        self.firmware = firmware
        self.takenAt = takenAt
        self.pv = pv
        self.inverterAC = inverterAC
        self.battery = battery
        self.load = load
        self.grid = grid
        self.temperature = temperature
        self.energyToday = energyToday
        self.energyTotal = energyTotal
        self.health = health
    }
}
