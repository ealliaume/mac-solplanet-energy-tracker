import Foundation

/// Severity of a log line. Ordered so callers can filter `>= minLevel`.
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug
    case info
    case warning
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    /// Case-insensitive parse (`"warn"`/`"warning"` both map to `.warning`).
    public static func parse(_ raw: String?) -> LogLevel? {
        switch raw?.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warning
        case "error": return .error
        default: return nil
        }
    }
}
