import Foundation
import Observation

/// Observable, main-actor view model the UI reads. Fed by the poll loop (and, in a
/// later milestone, by a file watcher so an external script reading `readings.json`
/// stays in sync). SwiftUI views and the status item observe `readings`.
@MainActor
@Observable
public final class ReadingsStore {
    public private(set) var readings: [InverterReading] = []

    public init(readings: [InverterReading] = []) {
        self.readings = readings
    }

    /// The single inverter shown by the v1 UI.
    public var primary: InverterReading? { readings.first }

    /// Menu-bar label text for the current primary reading.
    public var menuBarText: String { MenuBarSummary.text(for: primary) }

    /// Insert or replace by `host:serialNumber`, preserving order.
    public func update(_ reading: InverterReading) {
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
