import XCTest
@testable import SolplanetEnergyTrackerLib

private func snapshot(at iso: String, soc: Double = 50, pv: Double = 100,
                      grid: Double? = nil, gridAvailable: Bool = false) -> PowerSnapshot {
    PowerSnapshot(t: iso, pv: pv, battPower: -200, soc: soc, load: 50,
                  loadQuality: "derivedRough", grid: grid, gridAvailable: gridAvailable,
                  inverterAC: -pv, energyToday: 1.0)
}

final class ChartSeriesResolverTests: XCTestCase {
    private let now = ISODate("2026-05-30T12:00:00Z").date!

    func testFiltersToWindow() {
        let snapshots = [
            snapshot(at: "2026-05-29T06:00:00Z"),   // 30h ago — outside 24h
            snapshot(at: "2026-05-30T11:00:00Z"),   // 1h ago — inside
            snapshot(at: "2026-05-30T11:30:00Z"),   // inside
        ]
        let points = ChartSeriesResolver.series(from: snapshots, metric: .pv, window: .day, now: now)
        XCTAssertEqual(points.compactMap(\.value).count, 2)
    }

    func testWeekWindowKeepsOlderSamples() {
        let snapshots = [
            snapshot(at: "2026-05-25T12:00:00Z"),   // 5d ago — inside 7d, outside 24h
            snapshot(at: "2026-05-30T11:00:00Z"),   // 1h ago — inside
        ]
        let points = ChartSeriesResolver.series(from: snapshots, metric: .pv, window: .week, now: now)
        XCTAssertEqual(points.compactMap(\.value).count, 2)
    }

    func testInsertsBreakAcrossLargeTimeGap() {
        // Two samples 2h apart (> 15 min maxGap) → a nil break point between them.
        let snapshots = [snapshot(at: "2026-05-30T09:00:00Z"), snapshot(at: "2026-05-30T11:00:00Z")]
        let points = ChartSeriesResolver.series(from: snapshots, metric: .pv, window: .day, now: now)
        XCTAssertEqual(points.count, 3)
        XCTAssertNil(points[1].value)               // the gap break
        XCTAssertNotNil(points[0].value)
        XCTAssertNotNil(points[2].value)
    }

    func testGridMetricNilWhenUnavailable() {
        let snapshots = [snapshot(at: "2026-05-30T11:50:00Z", gridAvailable: false)]
        let points = ChartSeriesResolver.series(from: snapshots, metric: .grid, window: .day, now: now)
        XCTAssertEqual(points.count, 1)
        XCTAssertNil(points[0].value)
    }

    func testSortsOutOfOrderInput() {
        let snapshots = [snapshot(at: "2026-05-30T11:30:00Z", soc: 60),
                         snapshot(at: "2026-05-30T11:00:00Z", soc: 50)]
        let points = ChartSeriesResolver.series(from: snapshots, metric: .soc, window: .day, now: now)
        XCTAssertEqual(points.compactMap(\.value), [50, 60])
    }
}

final class PowerTierTests: XCTestCase {
    func testSOCTiers() {
        XCTAssertEqual(PowerTiers.soc(Percent(10)), .critical)
        XCTAssertEqual(PowerTiers.soc(Percent(30)), .warning)
        XCTAssertEqual(PowerTiers.soc(Percent(60)), .info)
        XCTAssertEqual(PowerTiers.soc(Percent(90)), .good)
        XCTAssertEqual(PowerTiers.soc(Percent(15)), .warning)   // boundary
        XCTAssertEqual(PowerTiers.soc(Percent(80)), .good)      // boundary
    }

    func testBatteryTiers() {
        XCTAssertEqual(PowerTiers.battery(.charging), .good)
        XCTAssertEqual(PowerTiers.battery(.discharging), .warning)
        XCTAssertEqual(PowerTiers.battery(.idle), .neutral)
    }

    func testGridTiers() {
        XCTAssertEqual(PowerTiers.grid(GridState(power: 100, direction: .exporting, available: true)), .good)
        XCTAssertEqual(PowerTiers.grid(GridState(power: 100, direction: .importing, available: true)), .critical)
        XCTAssertEqual(PowerTiers.grid(.unavailable), .neutral)
    }
}
