import XCTest
@testable import SolplanetEnergyTrackerLib

final class BackoffPolicyTests: XCTestCase {
    func testSteadyStateUsesClampedBaseInterval() {
        // Requested below the 5 s floor → clamped up.
        let policy = BackoffPolicy(baseInterval: 1)
        XCTAssertEqual(policy.baseInterval, 5)
        XCTAssertEqual(policy.delay(consecutiveFailures: 0), 5)
    }

    func testBacksOffExponentiallyAndCaps() {
        let policy = BackoffPolicy(baseInterval: 10, maxInterval: 60)
        XCTAssertEqual(policy.delay(consecutiveFailures: 1), 10)   // 10 · 2^0
        XCTAssertEqual(policy.delay(consecutiveFailures: 2), 20)   // 10 · 2^1
        XCTAssertEqual(policy.delay(consecutiveFailures: 3), 40)   // 10 · 2^2
        XCTAssertEqual(policy.delay(consecutiveFailures: 4), 60)   // capped (would be 80)
        XCTAssertEqual(policy.delay(consecutiveFailures: 10), 60)  // stays capped
    }
}

final class PollerTests: XCTestCase {
    private let settings = ConnectionSettings(host: "192.168.4.30", serialNumber: "AL010K5SQ2620429")
    private var tempRoot: URL!
    private var directory: CacheDirectory!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sbet-poller-\(UUID().uuidString)", isDirectory: true)
        directory = CacheDirectory(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makePoller(_ client: HTTPClient) -> InverterPoller {
        InverterPoller(
            connector: SolplanetConnector(httpClient: client, requestSpacing: .zero),
            fileManager: ReadingsFileManager(directory: directory),
            recorder: SnapshotRecorder(directory: directory)
        )
    }

    func testSuccessfulTickPersistsAndRecords() async throws {
        let client = StubHTTPClient(payloads: try Fixtures.devicePayloads("morning-charging"))
        let poller = makePoller(client)
        let now = ISODate("2026-05-30T07:26:00Z").date!

        let outcome = try await poller.tick(settings, now: now)
        guard case .success(let reading) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(reading.pv.value, 486)

        let persisted = try ReadingsFileManager(directory: directory).read()
        XCTAssertEqual(persisted.first?.battery.soc.value, 24)
        XCTAssertTrue(persisted.first?.health.online ?? false)

        let failures = await poller.consecutiveFailures
        XCTAssertEqual(failures, 0)
    }

    func testOfflineTickServesLastGoodDimmed() async throws {
        let client = ControllableHTTPClient(payloads: try Fixtures.devicePayloads("morning-charging"))
        let poller = makePoller(client)
        let now = ISODate("2026-05-30T07:26:00Z").date!

        _ = try await poller.tick(settings, now: now)   // seed last-good
        client.setFailing([4])                          // dongle goes unreachable
        let outcome = try await poller.tick(settings, now: now)

        guard case .offline(_, let lastGood) = outcome else {
            return XCTFail("expected offline, got \(outcome)")
        }
        XCTAssertEqual(lastGood?.pv.value, 486)

        let persisted = try ReadingsFileManager(directory: directory).read()
        XCTAssertFalse(persisted.first?.health.online ?? true)  // dimmed copy on disk
        let failures = await poller.consecutiveFailures
        XCTAssertEqual(failures, 1)
    }

    func testOfflineWithNoPriorReadingHasNoLastGood() async throws {
        let client = StubHTTPClient(payloads: try Fixtures.devicePayloads("morning-charging"),
                                    failingDevices: [4])
        let poller = makePoller(client)

        let outcome = try await poller.tick(settings)
        guard case .offline(_, let lastGood) = outcome else {
            return XCTFail("expected offline, got \(outcome)")
        }
        XCTAssertNil(lastGood)
        XCTAssertEqual(try ReadingsFileManager(directory: directory).read(), [])
    }

    func testRecoveryResetsFailureCount() async throws {
        let client = ControllableHTTPClient(payloads: try Fixtures.devicePayloads("morning-charging"),
                                            failing: [4])
        let poller = makePoller(client)

        _ = try await poller.tick(settings)             // offline → failures 1
        var failures = await poller.consecutiveFailures
        XCTAssertEqual(failures, 1)

        client.setFailing([])                            // dongle recovers
        _ = try await poller.tick(settings)
        failures = await poller.consecutiveFailures
        XCTAssertEqual(failures, 0)
    }
}
