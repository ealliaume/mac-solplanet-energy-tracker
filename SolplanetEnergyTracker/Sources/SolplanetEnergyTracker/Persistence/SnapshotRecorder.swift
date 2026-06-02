import Foundation

/// Appends a `PowerSnapshot` to the day's JSONL history file, but **only when the
/// values changed** since the last recorded sample for that inverter (plan §6).
/// Holds the last sample per inverter id in memory; the poller keeps one recorder
/// alive for the process lifetime.
public actor SnapshotRecorder {
    private let directory: CacheDirectory
    private let fileManager: FileManager
    private let calendar: Calendar
    private var lastByID: [String: PowerSnapshot] = [:]
    private let encoder: JSONEncoder

    public init(directory: CacheDirectory, fileManager: FileManager = .default,
                calendar: Calendar = .current) {
        self.directory = directory
        self.fileManager = fileManager
        self.calendar = calendar
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// Returns `true` if a line was appended, `false` if the sample was a no-op.
    @discardableResult
    public func appendIfChanged(_ reading: InverterReading, now: Date = Date()) throws -> Bool {
        let snapshot = PowerSnapshot(reading: reading)
        if let previous = lastByID[reading.id], previous.hasSameValues(as: snapshot) {
            return false
        }

        let date = reading.takenAt.date ?? now
        let fileURL = directory.historyFileURL(for: date, calendar: calendar)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        var line = try encoder.encode(snapshot)
        line.append(0x0A) // newline

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }

        lastByID[reading.id] = snapshot
        return true
    }
}
