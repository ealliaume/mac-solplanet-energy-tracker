import XCTest
@testable import SolplanetEnergyTrackerLib

final class PersistenceTests: XCTestCase {
    private var tempRoot: URL!
    private var directory: CacheDirectory!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbet-tests-\(UUID().uuidString)", isDirectory: true)
        directory = CacheDirectory(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: factory

    private func makeReading(
        soc: Double = 50,
        batteryPower: Double = 358,
        direction: BatteryDirection = .charging,
        pv: Double = 486,
        gridAvailable: Bool = false,
        takenAt: Date = ISODate("2026-05-30T07:25:39Z").date!
    ) -> InverterReading {
        InverterReading(
            host: "192.168.4.30", serialNumber: "AL010K5SQ2620429",
            model: nil, firmware: nil,
            takenAt: ISODate(date: takenAt),
            pv: Watts(pv), inverterAC: Watts(-pv),
            battery: BatteryState(power: Watts(batteryPower), direction: direction, soc: Percent(soc)),
            load: LoadState(value: Watts(128), quality: .derivedRough),
            grid: gridAvailable ? GridState(power: 50, direction: .exporting, available: true) : .unavailable,
            temperature: Celsius(41.4), energyToday: KilowattHours(2.6), energyTotal: KilowattHours(6.1),
            health: InverterHealth(online: true, stale: false, errorCode: nil, meterEnabled: gridAvailable)
        )
    }

    // MARK: ReadingsFileManager

    func testReadingsRoundTrip() throws {
        let manager = ReadingsFileManager(directory: directory)
        let readings = [makeReading(soc: 24), makeReading(soc: 80, takenAt: Date())]
        try manager.write(readings)
        let restored = try manager.read()
        XCTAssertEqual(restored, readings)
    }

    func testReadReturnsEmptyWhenNoFile() throws {
        XCTAssertEqual(try ReadingsFileManager(directory: directory).read(), [])
    }

    func testWriteIsAtomicAndOverwrites() throws {
        let manager = ReadingsFileManager(directory: directory)
        try manager.write([makeReading(soc: 24)])
        try manager.write([makeReading(soc: 99)])
        let restored = try manager.read()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.battery.soc.value, 99)
    }

    // MARK: SnapshotRecorder

    func testAppendIfChangedSkipsUnchangedValues() async throws {
        let recorder = SnapshotRecorder(directory: directory)
        let first = makeReading(soc: 50)
        // Same values, later timestamp → must NOT append a second line.
        let same = makeReading(soc: 50, takenAt: ISODate("2026-05-30T07:25:44Z").date!)
        let changed = makeReading(soc: 51, takenAt: ISODate("2026-05-30T07:25:49Z").date!)

        let appendedFirst = try await recorder.appendIfChanged(first)
        let appendedSame = try await recorder.appendIfChanged(same)
        let appendedChanged = try await recorder.appendIfChanged(changed)
        XCTAssertTrue(appendedFirst)
        XCTAssertFalse(appendedSame)
        XCTAssertTrue(appendedChanged)

        let fileURL = directory.historyFileURL(for: ISODate("2026-05-30T07:25:39Z").date!)
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
    }

    func testSnapshotNullsGridWhenUnavailable() throws {
        let snapshot = PowerSnapshot(reading: makeReading(gridAvailable: false))
        XCTAssertNil(snapshot.grid)
        XCTAssertFalse(snapshot.gridAvailable)
    }

    func testSnapshotSignsBatteryByDirection() throws {
        let charging = PowerSnapshot(reading: makeReading(batteryPower: 358, direction: .charging))
        let discharging = PowerSnapshot(reading: makeReading(batteryPower: 358, direction: .discharging))
        XCTAssertEqual(charging.battPower, -358)   // charging is negative on the chart axis
        XCTAssertEqual(discharging.battPower, 358)
    }

    // MARK: HistoryReader

    func testHistoryReaderReturnsSamplesInWindow() async throws {
        let recorder = SnapshotRecorder(directory: directory)
        let day = ISODate("2026-05-30T07:25:39Z").date!
        try await recorder.appendIfChanged(makeReading(soc: 50, takenAt: day))
        try await recorder.appendIfChanged(makeReading(soc: 55, takenAt: day.addingTimeInterval(300)))

        let reader = HistoryReader(directory: directory)
        let window = reader.snapshots(from: day.addingTimeInterval(-3600),
                                      to: day.addingTimeInterval(3600))
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.map(\.soc), [50, 55])
    }

    func testHistoryReaderEmptyForRangeWithoutData() throws {
        let reader = HistoryReader(directory: directory)
        XCTAssertEqual(reader.snapshots(from: Date(), to: Date().addingTimeInterval(60)), [])
    }
}
