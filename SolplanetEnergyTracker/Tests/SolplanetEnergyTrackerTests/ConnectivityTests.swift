import XCTest
@testable import SolplanetEnergyTrackerLib

final class ConnectivityTests: XCTestCase {
    private let settings = ConnectionSettings(host: "192.168.4.30", serialNumber: "AL010K5SQ2620429")

    private func stub(_ scenario: String, failing: Set<Int> = []) throws -> StubHTTPClient {
        StubHTTPClient(payloads: try Fixtures.devicePayloads(scenario), failingDevices: failing)
    }

    // MARK: URL building

    func testDeviceDataURLIncludesDeviceAndSerial() {
        let url = settings.deviceDataURL(device: 4)
        XCTAssertEqual(url?.absoluteString,
                       "https://192.168.4.30/getdevdata.cgi?device=4&sn=AL010K5SQ2620429")
    }

    func testMetadataURLUsesGetdev() {
        XCTAssertEqual(settings.metadataURL()?.absoluteString,
                       "https://192.168.4.30/getdev.cgi?device=0")
    }

    func testHTTPSchemeWithCustomPort() {
        let s = ConnectionSettings(host: "10.0.0.5", serialNumber: "SN1", scheme: .http, port: 8484)
        XCTAssertEqual(s.deviceDataURL(device: 2)?.absoluteString,
                       "http://10.0.0.5:8484/getdevdata.cgi?device=2&sn=SN1")
    }

    // MARK: self-signed TLS host pinning

    func testTrustsServerTrustOnlyForConfiguredHost() {
        let trusted: Set<String> = ["192.168.4.30"]
        XCTAssertEqual(
            SelfSignedTrust.evaluate(host: "192.168.4.30",
                                     authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                     trustedHosts: trusted),
            .useServerTrust
        )
        XCTAssertEqual(
            SelfSignedTrust.evaluate(host: "evil.example.com",
                                     authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                     trustedHosts: trusted),
            .performDefault
        )
        // Right host, wrong challenge type (e.g. client cert) → no special trust.
        XCTAssertEqual(
            SelfSignedTrust.evaluate(host: "192.168.4.30",
                                     authenticationMethod: NSURLAuthenticationMethodClientCertificate,
                                     trustedHosts: trusted),
            .performDefault
        )
    }

    // MARK: connector

    func testFetchReadingAssemblesFromAllDevices() async throws {
        let connector = SolplanetConnector(httpClient: try stub("morning-charging"), requestSpacing: .zero)
        let now = ISODate("2026-05-30T07:26:00Z").date ?? Date()
        let reading = try await connector.fetchReading(settings, now: now, staleThreshold: 60)
        XCTAssertEqual(reading.pv.value, 486)
        XCTAssertEqual(reading.battery.soc.value, 24)
        XCTAssertTrue(reading.health.online)
        XCTAssertFalse(reading.health.meterEnabled)
    }

    func testMeterFailureToleratedAsDisabled() async throws {
        // device=3 unreachable must NOT fail the whole reading.
        let connector = SolplanetConnector(httpClient: try stub("morning-charging", failing: [3]),
                                           requestSpacing: .zero)
        let reading = try await connector.fetchReading(settings)
        XCTAssertFalse(reading.grid.available)
        XCTAssertEqual(reading.pv.value, 486)
    }

    func testBatteryDeviceFailurePropagates() async throws {
        let connector = SolplanetConnector(httpClient: try stub("morning-charging", failing: [4]),
                                           requestSpacing: .zero)
        do {
            _ = try await connector.fetchReading(settings)
            XCTFail("expected ConnectorError")
        } catch let error as ConnectorError {
            guard case .transport(let device, _) = error else {
                return XCTFail("expected transport error, got \(error)")
            }
            XCTAssertEqual(device, 4)
        }
    }
}
