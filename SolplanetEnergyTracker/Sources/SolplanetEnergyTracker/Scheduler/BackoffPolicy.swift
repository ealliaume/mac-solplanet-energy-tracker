import Foundation

/// Computes the delay before the next poll. On success the poller runs at the
/// user's interval; on repeated failures it backs off exponentially (capped) so a
/// down dongle is not hammered — which the API doc warns can brick it (`CLAUDE.md`).
public struct BackoffPolicy: Sendable, Equatable {
    /// Steady-state interval, already clamped to the 5 s floor.
    public let baseInterval: TimeInterval
    /// Upper bound on the backed-off delay.
    public let maxInterval: TimeInterval

    public static let defaultMaxInterval: TimeInterval = 300

    public init(baseInterval: TimeInterval, maxInterval: TimeInterval = BackoffPolicy.defaultMaxInterval) {
        self.baseInterval = PollingLimits.clamp(baseInterval)
        self.maxInterval = max(self.baseInterval, maxInterval)
    }

    /// Delay after `consecutiveFailures` failed ticks (`0` ⇒ last tick succeeded).
    public func delay(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return baseInterval }
        // base · 2^(n-1), capped. n is small; pow on Double is fine.
        let factor = pow(2.0, Double(consecutiveFailures - 1))
        return min(maxInterval, baseInterval * factor)
    }
}
