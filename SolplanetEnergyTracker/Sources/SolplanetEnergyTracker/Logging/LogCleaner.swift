import Foundation

/// Purges old `.log` files from the log directory. Active files are written
/// frequently so their modification date stays recent and they survive; only
/// rotated archives age out. Default retention is one week.
public struct LogCleaner: Sendable {
    private let directory: URL
    private let retention: TimeInterval

    /// Seven days, expressed in seconds.
    public static let defaultRetention: TimeInterval = 7 * 24 * 60 * 60

    public init(directory: URL, retention: TimeInterval = LogCleaner.defaultRetention) {
        self.directory = directory
        self.retention = retention
    }

    /// Removes `.log` files last modified before `now - retention`. Returns the
    /// number of files deleted. Best-effort — unreadable entries are skipped.
    @discardableResult
    public func purge(now: Date = Date(), fileManager: FileManager = .default) -> Int {
        let cutoff = now.addingTimeInterval(-retention)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var deleted = 0
        for url in entries where url.pathExtension == "log" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if modified < cutoff, (try? fileManager.removeItem(at: url)) != nil {
                deleted += 1
            }
        }
        return deleted
    }
}
