import Foundation

/// Physical-quantity value objects. Each wraps a `Double` in a fixed unit so a
/// `Watts` can never be passed where `Volts` is expected, and so the unit lives
/// in the type rather than a comment. See `docs/SWIFT-VALUE-OBJECTS.md`.
///
/// All quantities encode as a bare JSON number (single-value container) so the
/// persisted snapshot stays flat and cheap to read for charts.

/// Instantaneous power in watts. **Signed** at the source layer (a raw `pb`/`pac`),
/// but domain readings carry direction in an enum and keep magnitudes here.
public struct Watts: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Double
    public init(_ value: Double) { self.value = value }

    public var kilowatts: Double { value / 1000 }
    public static func < (lhs: Watts, rhs: Watts) -> Bool { lhs.value < rhs.value }
    public var description: String { "\(value) W" }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A percentage, conventionally 0...100. Not auto-clamped (a BMS can briefly
/// report slightly outside the range); use `clamped` where a UI gauge needs it.
public struct Percent: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Double
    public init(_ value: Double) { self.value = value }

    public var clamped: Percent { Percent(min(100, max(0, value))) }
    public static func < (lhs: Percent, rhs: Percent) -> Bool { lhs.value < rhs.value }
    public var description: String { "\(value)%" }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Voltage in volts.
public struct Volts: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public static func < (lhs: Volts, rhs: Volts) -> Bool { lhs.value < rhs.value }
    public var description: String { "\(value) V" }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Temperature in degrees Celsius.
public struct Celsius: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public static func < (lhs: Celsius, rhs: Celsius) -> Bool { lhs.value < rhs.value }
    public var description: String { "\(value)°C" }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Energy in kilowatt-hours (cumulative day/total counters).
public struct KilowattHours: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: Double
    public init(_ value: Double) { self.value = value }
    public static func < (lhs: KilowattHours, rhs: KilowattHours) -> Bool { lhs.value < rhs.value }
    public var description: String { "\(value) kWh" }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension Watts: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }
}
extension Percent: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }
}
extension Volts: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }
}
extension Celsius: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }
}
extension KilowattHours: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }
}
