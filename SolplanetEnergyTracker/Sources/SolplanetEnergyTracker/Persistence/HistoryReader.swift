import Foundation

/// Reads `PowerSnapshot` history back for charts. Walks only the day files that
/// intersect the requested window, decoding line-by-line and skipping malformed
/// lines rather than failing the whole read (a single bad append must not blind
/// the chart). See plan §6 / §8.
public struct HistoryReader: Sendable {
    private let directory: CacheDirectory
    private let calendar: Calendar
    private var fileManager: FileManager { .default }

    public init(directory: CacheDirectory, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    /// All snapshots with a parseable timestamp in `from...to`, in file order.
    public func snapshots(from: Date, to: Date) -> [PowerSnapshot] {
        guard from <= to else { return [] }
        let decoder = JSONDecoder()
        var result: [PowerSnapshot] = []

        for dayURL in dayFileURLs(from: from, to: to) {
            guard let contents = try? String(contentsOf: dayURL, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let snapshot = try? decoder.decode(PowerSnapshot.self, from: data) else { continue }
                if let stamp = ISODate(String(snapshot.t)).date, stamp >= from, stamp <= to {
                    result.append(snapshot)
                }
            }
        }
        return result
    }

    private func dayFileURLs(from: Date, to: Date) -> [URL] {
        var urls: [URL] = []
        var cursor = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        while cursor <= last {
            let url = directory.historyFileURL(for: cursor, calendar: calendar)
            if fileManager.fileExists(atPath: url.path) { urls.append(url) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return urls
    }
}
