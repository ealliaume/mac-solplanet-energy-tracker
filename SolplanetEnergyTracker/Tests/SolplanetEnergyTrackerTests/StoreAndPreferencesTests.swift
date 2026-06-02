import XCTest
@testable import SolplanetEnergyTrackerLib

private func sampleReading(soc: Double = 24, pv: Double = 486, online: Bool = true) -> InverterReading {
    InverterReading(
        host: "192.168.4.30", serialNumber: "AL010K5SQ2620429", model: nil, firmware: nil,
        takenAt: ISODate("2026-05-30T07:25:39Z"),
        pv: Watts(pv), inverterAC: Watts(-pv),
        battery: BatteryState(power: Watts(358), direction: .charging, soc: Percent(soc)),
        load: LoadState(value: Watts(128), quality: .derivedRough),
        grid: .unavailable, temperature: nil, energyToday: nil, energyTotal: nil,
        health: InverterHealth(online: online, stale: !online, errorCode: nil, meterEnabled: false)
    )
}

final class FormattingTests: XCTestCase {
    func testPowerFormattingScalesToKilowatts() {
        XCTAssertEqual(PowerFormatting.short(Watts(486)), "486 W")
        XCTAssertEqual(PowerFormatting.short(Watts(1432)), "1.4 kW")
        XCTAssertEqual(PowerFormatting.short(Watts(-4274)), "4.3 kW")  // magnitude only
        XCTAssertEqual(PowerFormatting.short(Watts(1000)), "1.0 kW")   // threshold inclusive
    }

    func testMenuBarSummaryUnconfigured() {
        XCTAssertEqual(MenuBarSummary.text(for: nil), AppInfo.unconfiguredLabel)
    }

    func testMenuBarSummaryLiveReading() {
        XCTAssertEqual(MenuBarSummary.text(for: sampleReading()), "☀ 486 W  🔋 24%")
    }

    func testMenuBarSummaryFlagsOffline() {
        let text = MenuBarSummary.text(for: sampleReading(online: false))
        XCTAssertTrue(text.hasPrefix("⚠"))
    }
}

@MainActor
final class ReadingsStoreTests: XCTestCase {
    func testUpdateInsertsThenReplacesByID() {
        let store = ReadingsStore()
        store.update(sampleReading(soc: 24))
        store.update(sampleReading(soc: 80))  // same host:sn → replace, not append
        XCTAssertEqual(store.readings.count, 1)
        XCTAssertEqual(store.primary?.battery.soc.value, 80)
    }

    func testMenuBarTextReflectsPrimary() {
        let store = ReadingsStore()
        XCTAssertEqual(store.menuBarText, AppInfo.unconfiguredLabel)
        store.update(sampleReading())
        XCTAssertEqual(store.menuBarText, "☀ 486 W  🔋 24%")
    }
}

final class PreferencesTests: XCTestCase {
    private func freshPreferences() throws -> UserDefaultsAppPreferences {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "sbet-prefs-\(UUID().uuidString)"))
        return UserDefaultsAppPreferences(defaults: suite)
    }

    func testRefreshIntervalClampsToFloorOnReadAndWrite() throws {
        let prefs = try freshPreferences()
        prefs.refreshIntervalSeconds = 1            // below the 5 s floor
        XCTAssertEqual(prefs.refreshIntervalSeconds, 5)
        prefs.refreshIntervalSeconds = 30
        XCTAssertEqual(prefs.refreshIntervalSeconds, 30)
    }

    func testDefaultIntervalWhenUnset() throws {
        let prefs = try freshPreferences()
        XCTAssertGreaterThanOrEqual(prefs.refreshIntervalSeconds, 5)
    }

    func testPrimaryInverterRoundTrips() throws {
        let prefs = try freshPreferences()
        XCTAssertNil(prefs.primaryInverter)
        prefs.primaryInverter = ConnectionSettings(host: "10.0.0.9", serialNumber: "SN9",
                                                   scheme: .http, port: 8484)
        XCTAssertEqual(prefs.primaryInverter?.host, "10.0.0.9")
        XCTAssertEqual(prefs.primaryInverter?.port, 8484)
        XCTAssertEqual(prefs.inverters.count, 1)
    }
}
