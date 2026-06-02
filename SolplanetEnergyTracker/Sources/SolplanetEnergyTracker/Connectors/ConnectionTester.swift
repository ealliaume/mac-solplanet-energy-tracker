import Foundation

/// Outcome of the Settings "Test connection" action — an actionable message, not
/// a raw error (plan §4).
public enum ConnectionTestResult: Sendable, Equatable {
    case success(InverterReading)
    case failure(message: String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Runs a single `fetchReading` round-trip for the Settings tab. The HTTP client
/// is injectable so the button logic is testable without a live dongle; the
/// production default builds a session that trusts only the host under test.
public enum ConnectionTester {
    public static func test(
        _ settings: ConnectionSettings,
        makeClient: @Sendable (Set<String>) -> HTTPClient = { SolplanetSession.make(trustedHosts: $0) }
    ) async -> ConnectionTestResult {
        let client = makeClient([settings.host.rawValue])
        let connector = SolplanetConnector(httpClient: client, requestSpacing: .zero)
        do {
            let reading = try await connector.fetchReading(settings)
            return .success(reading)
        } catch let error as ConnectorError {
            return .failure(message: humanReadable(error))
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    private static func humanReadable(_ error: ConnectorError) -> String {
        switch error {
        case .invalidURL:
            return "The host or serial number is not a valid address."
        case .transport:
            return "Couldn't reach the inverter. Check the IP, that you're on the same network, and the scheme (https/http)."
        case let .httpStatus(_, code, _):
            return "The inverter answered with HTTP \(code). Check the serial number."
        case .decoding:
            return "Connected, but the response wasn't in the expected format — the firmware may differ."
        }
    }
}
