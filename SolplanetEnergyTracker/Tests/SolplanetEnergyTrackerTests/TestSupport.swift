import Foundation
import XCTest
@testable import SolplanetEnergyTrackerLib

/// Loads a captured device payload from the test bundle.
enum Fixtures {
    static func data(_ scenario: String, _ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(scenario)"),
            "missing fixture Fixtures/\(scenario)/\(name).json"
        )
        return try Data(contentsOf: url)
    }

    static func devicePayloads(_ scenario: String) throws -> [Int: Data] {
        [
            4: try data(scenario, "device4"),
            2: try data(scenario, "device2"),
            3: try data(scenario, "device3"),
        ]
    }
}

/// Immutable in-memory `HTTPClient` answering `device=N` from canned payloads.
struct StubHTTPClient: HTTPClient {
    var payloads: [Int: Data]
    var failingDevices: Set<Int> = []

    struct StubError: Error {}

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let device = deviceID(from: request.url) else { throw StubError() }
        if failingDevices.contains(device) { throw StubError() }
        guard let body = payloads[device], let url = request.url else { throw StubError() }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// `HTTPClient` whose failing-device set can be flipped between ticks, to simulate
/// a dongle going offline and recovering.
// @unchecked Sendable: all mutable state is guarded by `lock`, so concurrent
// access from the connector actor is serialized.
final class ControllableHTTPClient: HTTPClient, @unchecked Sendable {
    private let payloads: [Int: Data]
    private let lock = NSLock()
    private var failing: Set<Int>

    init(payloads: [Int: Data], failing: Set<Int> = []) {
        self.payloads = payloads
        self.failing = failing
    }

    func setFailing(_ devices: Set<Int>) {
        lock.lock(); defer { lock.unlock() }
        failing = devices
    }

    struct StubError: Error {}

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let device = deviceID(from: request.url) else { throw StubError() }
        let isFailing: Bool = {
            lock.lock(); defer { lock.unlock() }
            return failing.contains(device)
        }()
        if isFailing { throw StubError() }
        guard let body = payloads[device], let url = request.url else { throw StubError() }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private func deviceID(from url: URL?) -> Int? {
    guard let url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let raw = items.first(where: { $0.name == "device" })?.value else { return nil }
    return Int(raw)
}
