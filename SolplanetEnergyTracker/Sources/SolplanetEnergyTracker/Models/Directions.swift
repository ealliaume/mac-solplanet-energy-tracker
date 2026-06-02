import Foundation

/// Battery flow direction. Derived from the sign of `pb` (device=4): `pb < 0`
/// charging, `pb > 0` discharging. The sign convention never leaks into the UI —
/// views read this enum, not a signed number. See API doc "Battery sign convention".
public enum BatteryDirection: String, Sendable, Codable, CaseIterable {
    case charging
    case discharging
    case idle
}

/// Grid flow direction (only meaningful when the CT meter is enabled).
public enum GridDirection: String, Sendable, Codable, CaseIterable {
    case importing
    case exporting
    case idle
}

/// How trustworthy a derived figure is. House load and grid are exact only with
/// the CT meter; without it, load is a noisy difference of large async-sampled
/// values and grid is unavailable. See API doc "Why house load & grid can't be
/// derived (without the meter)".
public enum ReadingQuality: String, Sendable, Codable, CaseIterable {
    /// Measured by the CT meter — trustworthy.
    case exact
    /// Derived from `PV + pb` without a meter — directionally useful, not precise.
    case derivedRough
    /// Cannot be determined locally (no meter).
    case unavailable
}
