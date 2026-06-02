import Foundation

/// Assembles a normalized `InverterReading` from the three raw device payloads.
/// All API scalings (`vb÷100`, `tmp÷10`, `etd÷10`, …) and derivations live here,
/// behind the connector boundary, so the rest of the app never sees a raw integer.
public enum SolplanetReadingMapper {
    /// Dongle `tim` is `yyyyMMddHHmmss` in the dongle's local time.
    private static let dongleTimestampFormat = "yyyyMMddHHmmss"

    private static func parseDongleTimestamp(_ tim: String?) -> Date? {
        guard let tim, !tim.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dongleTimestampFormat
        return formatter.date(from: tim)
    }

    /// Scaling divisors for the raw integer fields (see API doc field reference).
    private enum Scale {
        static let voltage = 100.0      // vb: V ×100
        static let temperature = 10.0   // tmp/tb: °C ×10
        static let energy = 10.0        // eto/etd: ×10
    }

    public static func makeReading(
        host: Hostname,
        serialNumber: SerialNumber,
        battery: BatteryDeviceRaw,
        inverter: InverterDeviceRaw,
        meter: MeterDeviceRaw,
        model: String? = nil,
        firmware: String? = nil,
        online: Bool = true,
        now: Date = Date(),
        staleThreshold: TimeInterval
    ) -> InverterReading {
        let pac = inverter.pac ?? 0
        let pb = battery.pb ?? 0

        let pv = PowerDerivations.pv(inverterPac: pac)
        let direction = PowerDerivations.batteryDirection(pb: pb)

        let meterEnabled = meter.isEnabled
        let load = PowerDerivations.load(
            pvWatts: pv,
            pb: pb,
            meterPac: meterEnabled ? (meter.pac ?? 0) : nil
        )

        let grid: GridState
        if meterEnabled, let gridPac = meter.pac {
            grid = GridState(
                power: Watts(Double(abs(gridPac))),
                direction: PowerDerivations.gridDirection(meterPac: gridPac),
                available: true
            )
        } else {
            grid = .unavailable
        }

        let batteryState = BatteryState(
            power: Watts(Double(abs(pb))),
            direction: direction,
            soc: Percent(Double(battery.soc ?? 0)),
            soh: battery.soh.map { Percent(Double($0)) },
            voltage: battery.vb.map { Volts(Double($0) / Scale.voltage) }
        )

        // device=4 is the freshest source for the reading instant; fall back to
        // device=2, then to `now` if neither timestamp parses.
        let takenAtDate = parseDongleTimestamp(battery.tim)
            ?? parseDongleTimestamp(inverter.tim)
            ?? now
        let stale = now.timeIntervalSince(takenAtDate) > staleThreshold

        let err = inverter.err ?? 0

        return InverterReading(
            host: host,
            serialNumber: serialNumber,
            model: model,
            firmware: firmware,
            takenAt: ISODate(date: takenAtDate),
            pv: pv,
            inverterAC: Watts(Double(pac)),
            battery: batteryState,
            load: load,
            grid: grid,
            temperature: inverter.tmp.map { Celsius(Double($0) / Scale.temperature) },
            energyToday: inverter.etd.map { KilowattHours(Double($0) / Scale.energy) },
            energyTotal: inverter.eto.map { KilowattHours(Double($0) / Scale.energy) },
            health: InverterHealth(
                online: online,
                stale: stale,
                errorCode: err == 0 ? nil : err,
                meterEnabled: meterEnabled
            )
        )
    }
}
