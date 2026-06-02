import Foundation

/// How to reach a dongle. A plain value type stored in preferences — no secrets,
/// no Keychain (the local API is unauthenticated). See plan §4.
public struct ConnectionSettings: Sendable, Codable, Hashable, Identifiable {
    public enum Scheme: String, Sendable, Codable, CaseIterable {
        case https
        case http
    }

    public var host: Hostname
    public var serialNumber: SerialNumber
    /// The dongle on this install uses HTTPS with a self-signed cert; some
    /// firmwares expose plain HTTP on port 8484 instead.
    public var scheme: Scheme
    /// `nil` ⇒ the scheme's default port (443/80).
    public var port: Int?
    public var timeoutSeconds: Int

    public static let defaultTimeoutSeconds = 10

    public var id: String { "\(host.rawValue):\(serialNumber.rawValue)" }

    public init(host: Hostname, serialNumber: SerialNumber, scheme: Scheme = .https,
                port: Int? = nil, timeoutSeconds: Int = ConnectionSettings.defaultTimeoutSeconds) {
        self.host = host
        self.serialNumber = serialNumber
        self.scheme = scheme
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }

    private var baseComponents: URLComponents {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host.rawValue
        components.port = port
        return components
    }

    /// `…/getdevdata.cgi?device=N&sn=<serial>` for a live sub-device read.
    public func deviceDataURL(device: Int) -> URL? {
        var components = baseComponents
        components.path = "/getdevdata.cgi"
        components.queryItems = [
            URLQueryItem(name: "device", value: String(device)),
            URLQueryItem(name: "sn", value: serialNumber.rawValue),
        ]
        return components.url
    }

    /// `…/getdev.cgi?device=0` for dongle metadata (Detect / auto-identify).
    public func metadataURL() -> URL? {
        var components = baseComponents
        components.path = "/getdev.cgi"
        components.queryItems = [URLQueryItem(name: "device", value: "0")]
        return components.url
    }
}
