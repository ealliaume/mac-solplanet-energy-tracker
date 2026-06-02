import Foundation

/// Errors the connector raises for a failed reading. Carries enough context to
/// diagnose without logs (`docs/SWIFT-ERROR-HANDLING.md`). The meter device is
/// *not* represented here — its absence is expected and handled as "disabled".
public enum ConnectorError: Error, Equatable, CustomStringConvertible {
    case invalidURL(device: Int, host: String)
    case transport(device: Int, reason: String)
    case httpStatus(device: Int, code: Int, url: String)
    case decoding(device: Int, reason: String)

    public var description: String {
        switch self {
        case let .invalidURL(device, host):
            return "could not build URL for device=\(device) on \(host)"
        case let .transport(device, reason):
            return "transport error querying device=\(device): \(reason)"
        case let .httpStatus(device, code, url):
            return "HTTP \(code) querying device=\(device) (\(url))"
        case let .decoding(device, reason):
            return "failed to decode device=\(device): \(reason)"
        }
    }
}

/// Queries the dongle's `getdevdata.cgi` for the battery (4), inverter (2), and
/// meter (3) sub-devices and assembles a normalized `InverterReading`.
///
/// The two/three device reads are **serialized** with a small spacing — the ESP32
/// dongle is fragile under concurrent/tight requests (see `CLAUDE.md`). Throwing
/// is the boundary here; the M3 poller catches and decides whether to keep the
/// last good reading (offline) rather than the connector inventing one.
public actor SolplanetConnector {
    private let httpClient: HTTPClient
    private let requestSpacing: Duration
    private let decoder = JSONDecoder()

    private static let okStatusRange = 200..<300
    /// Default gap inserted between the serialized device reads within one tick.
    public static let defaultRequestSpacing: Duration = .milliseconds(250)

    public init(httpClient: HTTPClient,
                requestSpacing: Duration = SolplanetConnector.defaultRequestSpacing) {
        self.httpClient = httpClient
        self.requestSpacing = requestSpacing
    }

    public func fetchReading(_ settings: ConnectionSettings,
                             now: Date = Date(),
                             staleThreshold: TimeInterval = 60) async throws -> InverterReading {
        let battery: BatteryDeviceRaw = try await fetchDevice(4, settings: settings)
        try await space()
        let inverter: InverterDeviceRaw = try await fetchDevice(2, settings: settings)
        try await space()
        let meter = await fetchMeterTolerant(settings: settings)

        return SolplanetReadingMapper.makeReading(
            host: settings.host,
            serialNumber: settings.serialNumber,
            battery: battery,
            inverter: inverter,
            meter: meter,
            online: true,
            now: now,
            staleThreshold: staleThreshold
        )
    }

    private func space() async throws {
        guard requestSpacing > .zero else { return }
        try await Task.sleep(for: requestSpacing)
    }

    private func fetchDevice<T: Decodable>(_ device: Int,
                                           settings: ConnectionSettings) async throws -> T {
        guard let url = settings.deviceDataURL(device: device) else {
            throw ConnectorError.invalidURL(device: device, host: settings.host.rawValue)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(settings.timeoutSeconds)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw ConnectorError.transport(device: device, reason: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !Self.okStatusRange.contains(http.statusCode) {
            throw ConnectorError.httpStatus(device: device, code: http.statusCode, url: url.absoluteString)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ConnectorError.decoding(device: device, reason: String(describing: error))
        }
    }

    /// The CT meter (device=3) is frequently absent. A failure to read it is
    /// expected, not an error: treat it as disabled so the rest of the reading
    /// still derives. This is the one place a fetch failure is intentionally
    /// downgraded rather than propagated.
    private func fetchMeterTolerant(settings: ConnectionSettings) async -> MeterDeviceRaw {
        let disabled = MeterDeviceRaw(flg: 0)
        do {
            return try await fetchDevice(3, settings: settings)
        } catch {
            return disabled
        }
    }
}
