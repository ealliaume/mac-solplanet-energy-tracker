import XCTest
@testable import SolplanetEnergyTrackerLib

/// Locks the brick-protection invariant: no caller can schedule a poll faster
/// than the floor, no matter what the UI hands in. See CLAUDE.md / plan §4.
final class PollingLimitsTests: XCTestCase {
    func testClampRaisesBelowFloorToMinimum() {
        XCTAssertEqual(PollingLimits.clamp(1), PollingLimits.minimumRefreshInterval)
        XCTAssertEqual(PollingLimits.clamp(0), PollingLimits.minimumRefreshInterval)
        XCTAssertEqual(PollingLimits.clamp(-10), PollingLimits.minimumRefreshInterval)
    }

    func testClampLeavesValuesAtOrAboveFloorUnchanged() {
        XCTAssertEqual(PollingLimits.clamp(PollingLimits.minimumRefreshInterval),
                       PollingLimits.minimumRefreshInterval)
        XCTAssertEqual(PollingLimits.clamp(30), 30)
    }

    func testFloorIsAtLeastFiveSeconds() {
        XCTAssertGreaterThanOrEqual(PollingLimits.minimumRefreshInterval, 5)
    }

    func testDefaultIntervalRespectsFloor() {
        XCTAssertGreaterThanOrEqual(PollingLimits.defaultRefreshInterval,
                                    PollingLimits.minimumRefreshInterval)
    }
}
