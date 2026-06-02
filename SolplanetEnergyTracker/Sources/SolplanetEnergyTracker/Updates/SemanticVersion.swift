import Foundation

/// Minimal SemVer for comparing the running build against a release tag. Accepts
/// an optional leading `v` and a missing patch (`v1.2` ⇒ `1.2.0`); ignores any
/// pre-release/build suffix after the patch.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Spelled-out alias of `init(_:)` for call sites that read better as
    /// `SemanticVersion(string: tag)` (mirrors the reference `AppVersion(string:)`).
    public init?(string raw: String) { self.init(raw) }

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Drop anything past the numeric core (e.g. "-beta.1", "+build").
        let core = text.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Canonical `major.minor.patch` string. Used as the persistence key for the
    /// "skip this version" list and in UI labels, so it must stay stable.
    public var rawValue: String { description }
}
