import Foundation

/// Network host (IPv4 or hostname) of a dongle. Wrapping `String` stops a host
/// being swapped with a serial number at a call site.
public struct Hostname: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Inverter serial number (e.g. `AL010K5SQ2620429`). Sensitive enough that logs
/// mask it (see plan §2 "Light sanitizer") but it is not a secret.
public struct SerialNumber: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    /// Log-safe rendering: keeps the last four characters, masks the rest.
    public var masked: String {
        guard rawValue.count > 4 else { return String(repeating: "•", count: rawValue.count) }
        return String(repeating: "•", count: rawValue.count - 4) + rawValue.suffix(4)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An ISO 8601 timestamp stored as text. Parsing is centralised here so callers
/// never reach for a formatter (`ISO8601DateFormatter` is not thread-safe — a new
/// one per call is fine on these cold paths; see `docs/SWIFT-CONCURRENCY.md`).
public struct ISODate: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(date: Date) { rawValue = ISO8601DateFormatter().string(from: date) }
    public var description: String { rawValue }

    /// Nil if the stored string is not a parseable ISO 8601 date.
    public var date: Date? { ISO8601DateFormatter().date(from: rawValue) }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
