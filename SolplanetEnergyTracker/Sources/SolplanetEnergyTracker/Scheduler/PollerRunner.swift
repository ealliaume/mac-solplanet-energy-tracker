import Foundation

/// Owns the polling timing loop: repeatedly calls `InverterPoller.tick`, spacing
/// ticks by `BackoffPolicy` (steady interval on success, exponential backoff on
/// failure). The interval and settings are read through closures each iteration so
/// preference edits take effect on the next tick without a restart.
public actor PollerRunner {
    private let poller: InverterPoller
    private let settingsProvider: @Sendable () -> ConnectionSettings?
    private let intervalProvider: @Sendable () -> TimeInterval
    private let onOutcome: @Sendable (PollOutcome) -> Void
    private var loop: Task<Void, Never>?

    /// How long to wait before re-checking when no inverter is configured yet.
    private static let idleInterval: TimeInterval = 5

    public init(poller: InverterPoller,
                settingsProvider: @escaping @Sendable () -> ConnectionSettings?,
                intervalProvider: @escaping @Sendable () -> TimeInterval,
                onOutcome: @escaping @Sendable (PollOutcome) -> Void) {
        self.poller = poller
        self.settingsProvider = settingsProvider
        self.intervalProvider = intervalProvider
        self.onOutcome = onOutcome
    }

    /// Idempotent: a second call while running is a no-op.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Runs a single tick immediately, outside the scheduled cadence (the menu-bar
    /// "Refresh now" action). The poller is an actor, so this serializes with the
    /// loop's tick — no parallel requests to the fragile dongle.
    public func refreshNow() async {
        guard let settings = settingsProvider() else { return }
        if let outcome = await tickIgnoringCancellation(settings) {
            onOutcome(outcome)
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let delay: TimeInterval
            if let settings = settingsProvider() {
                let outcome = await tickIgnoringCancellation(settings)
                if let outcome { onOutcome(outcome) }
                let failures = await poller.consecutiveFailures
                let backoff = BackoffPolicy(baseInterval: intervalProvider())
                delay = backoff.delay(consecutiveFailures: failures)
            } else {
                delay = Self.idleInterval
            }

            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // cancelled
            }
        }
    }

    private func tickIgnoringCancellation(_ settings: ConnectionSettings) async -> PollOutcome? {
        do {
            return try await poller.tick(settings)
        } catch is CancellationError {
            return nil
        } catch {
            // Disk I/O failure inside tick — surface as offline so the UI flags it
            // rather than the loop dying silently.
            return .offline(reason: String(describing: error), lastGood: nil)
        }
    }
}
