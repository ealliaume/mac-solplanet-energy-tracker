import XCTest
@testable import SolplanetEnergyTrackerLib

final class ConnectionTesterTests: XCTestCase {
    private let settings = ConnectionSettings(host: "192.168.4.30", serialNumber: "AL010K5SQ2620429")

    func testSuccessReturnsReading() async throws {
        let payloads = try Fixtures.devicePayloads("morning-charging")
        let result = await ConnectionTester.test(settings) { _ in StubHTTPClient(payloads: payloads) }
        guard case .success(let reading) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(reading.battery.soc.value, 24)
        XCTAssertTrue(result.isSuccess)
    }

    func testFailureReturnsActionableMessage() async throws {
        let payloads = try Fixtures.devicePayloads("morning-charging")
        let result = await ConnectionTester.test(settings) { _ in
            StubHTTPClient(payloads: payloads, failingDevices: [4])
        }
        guard case .failure(let message) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(message.lowercased().contains("reach"))
    }

    func testTrustedHostPassedToClientFactory() async throws {
        let payloads = try Fixtures.devicePayloads("morning-charging")
        let captured = HostCapture()
        _ = await ConnectionTester.test(settings) { hosts in
            captured.set(hosts)
            return StubHTTPClient(payloads: payloads)
        }
        XCTAssertEqual(captured.value, ["192.168.4.30"])
    }
}

/// Thread-safe one-shot capture of the trusted-hosts set handed to the factory.
private final class HostCapture: @unchecked Sendable {
    // @unchecked Sendable: guarded by lock.
    private let lock = NSLock()
    private var hosts: Set<String> = []
    func set(_ value: Set<String>) { lock.lock(); hosts = value; lock.unlock() }
    var value: Set<String> { lock.lock(); defer { lock.unlock() }; return hosts }
}
