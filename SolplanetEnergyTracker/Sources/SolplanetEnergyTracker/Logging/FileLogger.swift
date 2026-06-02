import Foundation

/// Appends timestamped lines to a log file, rotating the file aside once it grows
/// past a size cap (rotated archives are reaped by `LogCleaner`). An actor so it's
/// safe to log from the poller, connector, and main actor concurrently; the
/// formatter is actor-isolated so it isn't shared across threads
/// (`docs/guidelines/swift-concurrency.md`).
public actor FileLogger {
    private let fileURL: URL
    private let maxBytes: Int
    private let fileManager: FileManager
    private let timestampFormatter: ISO8601DateFormatter
    private var minLevel: LogLevel

    /// 5 MB cap before the active file is rotated aside.
    public static let defaultMaxBytes = 5 * 1024 * 1024

    public init(fileURL: URL,
                minLevel: LogLevel = .info,
                maxBytes: Int = FileLogger.defaultMaxBytes,
                fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.minLevel = minLevel
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        self.timestampFormatter = ISO8601DateFormatter()
    }

    public func setMinLevel(_ level: LogLevel) { minLevel = level }

    public func log(_ level: LogLevel, _ message: String, now: Date = Date()) {
        guard level >= minLevel else { return }
        let line = "\(timestampFormatter.string(from: now)) \(level.label) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try rotateIfNeeded(incoming: data.count, now: now)
            if fileManager.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Logging must never crash the app or recurse — drop the line.
        }
    }

    /// Rotates `app.log` → `app.<timestamp>.log` once the next write would push it
    /// past the cap, so the active file never exceeds `maxBytes` by much.
    private func rotateIfNeeded(incoming: Int, now: Date) throws {
        guard let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int else {
            return
        }
        guard size + incoming > maxBytes else { return }

        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let stamp = Int(now.timeIntervalSince1970)
        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(stamp).\(ext)")
        try? fileManager.removeItem(at: rotated)
        try fileManager.moveItem(at: fileURL, to: rotated)
    }
}
