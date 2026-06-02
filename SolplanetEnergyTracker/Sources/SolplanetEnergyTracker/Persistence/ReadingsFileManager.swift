import Foundation

public enum PersistenceError: Error, CustomStringConvertible {
    case cannotOpenLock(path: String)
    case lockTimeout(path: String)

    public var description: String {
        switch self {
        case let .cannotOpenLock(path): return "cannot open lock file \(path)"
        case let .lockTimeout(path): return "timed out acquiring lock \(path)"
        }
    }
}

/// Reads/writes the latest-reading file with an atomic write under an advisory
/// `flock`. One JSON array entry per configured inverter. Synchronous and cold —
/// callers invoke it off the main actor (the poller). See `docs/SWIFT-IO-ROBUSTNESS.md`.
public struct ReadingsFileManager: Sendable {
    private let directory: CacheDirectory

    /// `FileManager.default` is thread-safe for the operations used here; a stored
    /// instance would make this struct non-Sendable under Swift 6.
    private var fileManager: FileManager { .default }

    /// Advisory-lock acquisition budget. A hung holder must not block forever.
    private static let lockTimeoutSeconds: TimeInterval = 5
    private static let lockRetryMicroseconds: useconds_t = 50_000

    public init(directory: CacheDirectory) {
        self.directory = directory
    }

    public func write(_ readings: [InverterReading]) throws {
        try fileManager.createDirectory(at: directory.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(readings)

        try withLock {
            try data.write(to: directory.readingsURL, options: .atomic)
        }
    }

    public func read() throws -> [InverterReading] {
        guard fileManager.fileExists(atPath: directory.readingsURL.path) else { return [] }
        let data = try Data(contentsOf: directory.readingsURL)
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([InverterReading].self, from: data)
    }

    /// Acquires the advisory lock (non-blocking with a timeout loop — never a bare
    /// blocking `LOCK_EX`), runs `body`, then unlocks. `defer` guarantees release.
    private func withLock(_ body: () throws -> Void) throws {
        try fileManager.createDirectory(at: directory.root, withIntermediateDirectories: true)
        let lockPath = directory.readingsLockURL.path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw PersistenceError.cannotOpenLock(path: lockPath) }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(Self.lockTimeoutSeconds)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw PersistenceError.lockTimeout(path: lockPath) }
            usleep(Self.lockRetryMicroseconds)
        }
        defer { flock(fd, LOCK_UN) }

        try body()
    }
}
