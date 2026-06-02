import XCTest
@testable import SolplanetEnergyTrackerLib

/// Locks the derivation formulas that took real effort to get right
/// (see docs/solplanet-api-documentation.md). Inline values keep the sign /
/// quality logic readable; fixture-driven end-to-end mapping lives in
/// `ReadingMapperTests`.
final class PowerDerivationsTests: XCTestCase {

    // MARK: PV = -pac, clamped

    func testPVIsNegatedPac() {
        XCTAssertEqual(PowerDerivations.pv(inverterPac: -486).value, 486)
        XCTAssertEqual(PowerDerivations.pv(inverterPac: -4274).value, 4274)
    }

    func testPVClampsToZeroWhenInverterImporting() {
        // pac > 0 means the inverter is drawing from the bus — no PV.
        XCTAssertEqual(PowerDerivations.pv(inverterPac: 300).value, 0)
    }

    /// The decisive regression: the wrong formula `-(pb + pac)` double-counts the
    /// AC-coupled battery charge. At the high-PV event it gave ~8303 W vs the
    /// correct 4274 W. PV must equal `-pac`, independent of `pb`.
    func testPVDoesNotDoubleCountBatteryCharge() {
        let pac = -4274
        let pb = -4029
        let correct = PowerDerivations.pv(inverterPac: pac).value
        let wrong = Double(-(pb + pac))
        XCTAssertEqual(correct, 4274)
        XCTAssertEqual(wrong, 8303)
        XCTAssertNotEqual(correct, wrong)
    }

    // MARK: Battery direction by sign of pb

    func testBatteryDirectionFromPbSign() {
        XCTAssertEqual(PowerDerivations.batteryDirection(pb: -358), .charging)
        XCTAssertEqual(PowerDerivations.batteryDirection(pb: 420), .discharging)
        XCTAssertEqual(PowerDerivations.batteryDirection(pb: 0), .idle)
    }

    func testGridDirectionFromMeterPacSign() {
        XCTAssertEqual(PowerDerivations.gridDirection(meterPac: 100), .exporting)
        XCTAssertEqual(PowerDerivations.gridDirection(meterPac: -100), .importing)
        XCTAssertEqual(PowerDerivations.gridDirection(meterPac: 0), .idle)
    }

    // MARK: Load quality flag transitions

    func testLoadIsRoughWithoutMeterAndClampsToZero() {
        // PV 486, pb -358 (charging) → rough load 128 W.
        let state = PowerDerivations.load(pvWatts: Watts(486), pb: -358, meterPac: nil)
        XCTAssertEqual(state.quality, .derivedRough)
        XCTAssertEqual(state.value.value, 128)
    }

    func testRoughLoadNeverGoesNegative() {
        // PV 100, pb -4029 (charging hard) → PV + pb < 0; clamp to 0.
        let state = PowerDerivations.load(pvWatts: Watts(100), pb: -4029, meterPac: nil)
        XCTAssertEqual(state.value.value, 0)
        XCTAssertEqual(state.quality, .derivedRough)
    }

    func testLoadIsExactWithMeter() {
        // PV 4801, pb -4380 (charge), grid export 21 → load = 4801 - 4380 - 21 = 400.
        let state = PowerDerivations.load(pvWatts: Watts(4801), pb: -4380, meterPac: 21)
        XCTAssertEqual(state.quality, .exact)
        XCTAssertEqual(state.value.value, 400)
    }
}
