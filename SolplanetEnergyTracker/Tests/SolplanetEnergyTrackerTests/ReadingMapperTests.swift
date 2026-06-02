import XCTest
@testable import SolplanetEnergyTrackerLib

/// End-to-end mapping from the three raw device payloads to an `InverterReading`,
/// driven by JSON captured from the real inverter. Locks scalings, derivations,
/// and health flags against ground truth.
final class ReadingMapperTests: XCTestCase {
    private let host: Hostname = "192.168.4.30"
    private let serial: SerialNumber = "AL010K5SQ2620429"

    private func loadDevices(_ scenario: String) throws -> (BatteryDeviceRaw, InverterDeviceRaw, MeterDeviceRaw) {
        let decoder = JSONDecoder()
        let battery = try decoder.decode(BatteryDeviceRaw.self, from: fixtureData(scenario, "device4"))
        let inverter = try decoder.decode(InverterDeviceRaw.self, from: fixtureData(scenario, "device2"))
        let meter = try decoder.decode(MeterDeviceRaw.self, from: fixtureData(scenario, "device3"))
        return (battery, inverter, meter)
    }

    private func fixtureData(_ scenario: String, _ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures/\(scenario)"),
            "missing fixture Fixtures/\(scenario)/\(name).json"
        )
        return try Data(contentsOf: url)
    }

    private func makeReading(_ scenario: String, online: Bool = true) throws -> InverterReading {
        let (battery, inverter, meter) = try loadDevices(scenario)
        // A timestamp aligned with the fixtures' `tim` so staleness is deterministic.
        let now = ISODate("2026-05-30T07:26:00Z").date ?? Date()
        return SolplanetReadingMapper.makeReading(
            host: host, serialNumber: serial,
            battery: battery, inverter: inverter, meter: meter,
            online: online, now: now, staleThreshold: 60
        )
    }

    // MARK: morning-charging (real capture: soc 24%, meter disabled)

    func testMorningChargingDerivations() throws {
        let reading = try makeReading("morning-charging")
        XCTAssertEqual(reading.pv.value, 486)                 // -pac
        XCTAssertEqual(reading.battery.power.value, 358)      // |pb|
        XCTAssertEqual(reading.battery.direction, .charging)  // pb < 0
        XCTAssertEqual(reading.battery.soc.value, 24)
        XCTAssertEqual(reading.battery.voltage?.value ?? 0, 51.90, accuracy: 0.001)  // vb ÷100
        XCTAssertEqual(reading.load.quality, .derivedRough)   // no meter
        XCTAssertEqual(reading.load.value.value, 128)         // max(0, 486 - 358)
        XCTAssertFalse(reading.grid.available)                // device=3 flg 0
        XCTAssertEqual(reading.energyToday?.value ?? 0, 2.6, accuracy: 0.001)        // etd ÷10
        XCTAssertEqual(reading.temperature?.value ?? 0, 41.4, accuracy: 0.001)       // tmp ÷10
        XCTAssertNil(reading.health.errorCode)                // err 0
        XCTAssertFalse(reading.health.meterEnabled)
    }

    // MARK: high-pv-charging (the regression that disproved -(pb+pac))

    func testHighPVChargingUsesNegatedPacNotDoubleCount() throws {
        let reading = try makeReading("high-pv-charging")
        XCTAssertEqual(reading.pv.value, 4274)                // -pac, NOT 8303
        XCTAssertEqual(reading.battery.power.value, 4029)
        XCTAssertEqual(reading.battery.direction, .charging)
        XCTAssertEqual(reading.battery.soc.value, 55)
        // Worked example (API doc): rough house load = PV + pb = 4274 - 4029 = 245 W.
        XCTAssertEqual(reading.load.value.value, 245)
        XCTAssertEqual(reading.load.quality, .derivedRough)
    }

    // MARK: health flags

    func testStaleWhenReadingOlderThanThreshold() throws {
        let (battery, inverter, meter) = try loadDevices("morning-charging")
        // Far ahead of the fixture timestamp → must flag stale.
        let now = ISODate("2026-05-30T09:00:00Z").date ?? Date()
        let reading = SolplanetReadingMapper.makeReading(
            host: host, serialNumber: serial,
            battery: battery, inverter: inverter, meter: meter,
            online: true, now: now, staleThreshold: 60
        )
        XCTAssertTrue(reading.health.stale)
    }

    func testReadingIsCodableRoundTrip() throws {
        let reading = try makeReading("morning-charging")
        let data = try JSONEncoder().encode(reading)
        let restored = try JSONDecoder().decode(InverterReading.self, from: data)
        XCTAssertEqual(restored, reading)
    }

    func testIdentityKeyedByHostAndSerial() throws {
        let reading = try makeReading("morning-charging")
        XCTAssertEqual(reading.id, "192.168.4.30:AL010K5SQ2620429")
    }
}
