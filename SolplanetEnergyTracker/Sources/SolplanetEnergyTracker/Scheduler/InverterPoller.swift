import Foundation

/// Result of one poll tick. A network/connector failure is an expected,
/// non-throwing outcome (`.offline`) that keeps the last good reading; only disk
/// I/O failures throw out of `tick`.
public enum PollOutcome: Sendable, Equatable {
    case success(InverterReading)
    case offline(reason: String, lastGood: InverterReading?)
}

/// Drives one fetch → persist → record cycle. The timing/backoff loop lives in
/// the caller (using `BackoffPolicy` + `consecutiveFailures`); this actor owns the
/// side effects and the last-good cache so a failed tick can serve dimmed data.
public actor InverterPoller {
    private let connector: SolplanetConnector
    private let fileManager: ReadingsFileManager
    private let recorder: SnapshotRecorder
    private let staleThreshold: TimeInterval

    private var lastGoodByID: [String: InverterReading] = [:]
    public private(set) var consecutiveFailures = 0

    public static let defaultStaleThreshold: TimeInterval = 60

    public init(connector: SolplanetConnector,
                fileManager: ReadingsFileManager,
                recorder: SnapshotRecorder,
                staleThreshold: TimeInterval = InverterPoller.defaultStaleThreshold) {
        self.connector = connector
        self.fileManager = fileManager
        self.recorder = recorder
        self.staleThreshold = staleThreshold
    }

    @discardableResult
    public func tick(_ settings: ConnectionSettings, now: Date = Date()) async throws -> PollOutcome {
        do {
            let reading = try await connector.fetchReading(
                settings, now: now, staleThreshold: staleThreshold
            )
            lastGoodByID[reading.id] = reading
            consecutiveFailures = 0
            try persistCurrentView()
            try await recorder.appendIfChanged(reading, now: now)
            return .success(reading)
        } catch let error as ConnectorError {
            return try handleOffline(settings: settings, reason: error.description)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Transport errors surfaced as anything other than ConnectorError still
            // mean "couldn't reach the dongle" — treat as offline, not a crash.
            return try handleOffline(settings: settings, reason: String(describing: error))
        }
    }

    private func handleOffline(settings: ConnectionSettings, reason: String) throws -> PollOutcome {
        consecutiveFailures += 1
        let lastGood = lastGoodByID[settings.id]
        if lastGood != nil {
            try persistCurrentView(offlineID: settings.id)
        }
        return .offline(reason: reason, lastGood: lastGood)
    }

    /// Writes the latest view of every known inverter. When `offlineID` is set,
    /// that inverter's entry is written as a dimmed, offline copy.
    private func persistCurrentView(offlineID: String? = nil) throws {
        let readings = lastGoodByID.keys.sorted().compactMap { id -> InverterReading? in
            guard let good = lastGoodByID[id] else { return nil }
            return id == offlineID ? good.markedOffline() : good
        }
        try fileManager.write(readings)
    }
}
