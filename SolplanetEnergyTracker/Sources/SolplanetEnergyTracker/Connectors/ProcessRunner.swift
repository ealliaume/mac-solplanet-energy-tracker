import Foundation

/// Result of running an external process to completion (or timing out).
public struct ProcessExecutionResult: Sendable, Equatable {
    public let stdout: Data
    public let terminationStatus: Int32
    public let timedOut: Bool

    public init(stdout: Data, terminationStatus: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
    }
}

/// Injectable process-execution seam so the update machinery (brew detection,
/// `ditto` unzip) can be unit-tested without spawning real processes
/// (`docs/guidelines/swift-testability.md`).
public protocol ProcessRunning: Sendable {
    func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            // Never block the cooperative pool: Process.waitUntilExit() runs on a
            // dedicated global-queue thread (docs/guidelines/swift-concurrency.md).
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()
                let state = ProcessState()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { _ in state.markCompleted() }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                timer.setEventHandler {
                    guard state.markTimedOutIfNotCompleted() else { return }
                    process.terminate()
                }

                do {
                    try process.run()
                } catch {
                    timer.cancel()
                    continuation.resume(throwing: error)
                    return
                }

                timer.resume()
                // Read before wait to avoid a full-pipe-buffer deadlock.
                let raw = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()

                continuation.resume(returning: ProcessExecutionResult(
                    stdout: raw,
                    terminationStatus: process.terminationStatus,
                    timedOut: state.didTimeOut
                ))
            }
        }
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    func markTimedOutIfNotCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        timedOut = true
        return true
    }
}
