import Foundation
import Observation

/// Observable, main-actor view model the UI reads. Fed by the poll loop (and, in a
/// later milestone, by a file watcher so an external script reading `readings.json`
/// stays in sync). SwiftUI views and the status item observe `readings`.
@MainActor
@Observable
public final class ReadingsStore {
    public private(set) var readings: [InverterReading] = []
    /// Wall-clock time a fresh reading was last received (not the dongle's `tim`).
    /// Drives the "Updated X ago" footer so it resets the moment data arrives.
    public private(set) var lastUpdatedAt: Date?

    public init(readings: [InverterReading] = []) {
        self.readings = readings
    }

    /// The single inverter shown by the v1 UI.
    public var primary: InverterReading? { readings.first }

    /// Menu-bar label text for the current primary reading.
    public var menuBarText: String { MenuBarSummary.text(for: primary) }

    /// A fresh reading arrived: insert/replace by `host:serialNumber` and stamp
    /// the receive time.
    public func update(_ reading: InverterReading, receivedAt: Date = Date()) {
        store(reading)
        lastUpdatedAt = receivedAt
    }

    /// Replace a reading with its dimmed/offline copy without touching
    /// `lastUpdatedAt` — a failed poll is not fresh data.
    public func markOffline(_ reading: InverterReading) {
        store(reading)
    }

    private func store(_ reading: InverterReading) {
        if let index = readings.firstIndex(where: { $0.id == reading.id }) {
            readings[index] = reading
        } else {
            readings.append(reading)
        }
    }

    public func replaceAll(_ readings: [InverterReading]) {
        self.readings = readings
    }
}
