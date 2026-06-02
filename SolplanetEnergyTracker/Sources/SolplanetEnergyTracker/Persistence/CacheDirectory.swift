import Foundation

/// Resolves the on-disk locations the app uses. Injectable root so tests run in a
/// temp directory instead of `~/.cache`. Layout (plan §6):
///
///     <root>/readings.json            latest reading per inverter (atomic + flock)
///     <root>/readings.json.lock       advisory lock file
///     <root>/history/YYYY/MM/YYYY-MM-DD.jsonl   append-only snapshots
///     <root>/<name>.log               logs
public struct CacheDirectory: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Default production location: `~/.cache/solplanet-energy-tracker`.
    public static func makeDefault(fileManager: FileManager = .default) -> CacheDirectory {
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent(AppInfo.cacheDirectoryName, isDirectory: true)
        return CacheDirectory(root: base)
    }

    public var readingsURL: URL { root.appendingPathComponent("readings.json") }
    public var readingsLockURL: URL { root.appendingPathComponent("readings.json.lock") }
    public var historyDirectory: URL { root.appendingPathComponent("history", isDirectory: true) }

    /// Logs live directly under the root (`app.log`, `solplanet-connector.log`).
    public var appLogURL: URL { root.appendingPathComponent("app.log") }
    public var connectorLogURL: URL { root.appendingPathComponent("solplanet-connector.log") }

    /// `history/YYYY/MM/YYYY-MM-DD.jsonl` for the given day (UTC components).
    public func historyFileURL(for date: Date, calendar: Calendar = .current) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        return historyDirectory
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent("\(year)-\(month)-\(day).jsonl")
    }
}
