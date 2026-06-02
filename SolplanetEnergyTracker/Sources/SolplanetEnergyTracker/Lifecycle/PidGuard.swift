import Foundation

/// Single-instance guard backed by a pid file. On launch the app calls `acquire`:
/// if another *live* instance owns the pid file, this launch should bow out;
/// otherwise it writes its own pid and runs. Liveness and the current pid are
/// injected so the logic is testable without spawning processes
/// (`docs/guidelines/swift-testability.md`).
public struct PidGuard: Sendable {
    public enum Acquisition: Sendable, Equatable {
        case acquired
        case alreadyRunning(pid: Int32)
    }

    private let pidFileURL: URL
    private let currentPID: Int32
    private let isAlive: @Sendable (Int32) -> Bool

    /// `FileManager.default` is thread-safe for these operations; storing one
    /// would make this struct non-Sendable under Swift 6.
    private var fileManager: FileManager { .default }

    public init(pidFileURL: URL,
                currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                isAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }) {
        self.pidFileURL = pidFileURL
        self.currentPID = currentPID
        self.isAlive = isAlive
    }

    public func acquire() throws -> Acquisition {
        if let existing = readPID(), existing != currentPID, isAlive(existing) {
            return .alreadyRunning(pid: existing)
        }
        // Stale, missing, or ours → claim it.
        try fileManager.createDirectory(at: pidFileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("\(currentPID)".utf8).write(to: pidFileURL, options: .atomic)
        return .acquired
    }

    /// Removes the pid file if we still own it (avoids deleting a successor's).
    public func release() {
        guard readPID() == currentPID else { return }
        try? fileManager.removeItem(at: pidFileURL)
    }

    private func readPID() -> Int32? {
        guard let data = try? Data(contentsOf: pidFileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
