import XCTest
@testable import SolplanetEnergyTrackerLib

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sbet-life-\(UUID().uuidString)", isDirectory: true)
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class FileLoggerTests: XCTestCase {
    func testRespectsMinimumLevel() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.log")
        let logger = FileLogger(fileURL: url, minLevel: .info)

        await logger.log(.debug, "hidden")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        await logger.log(.warning, "shown")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("WARN shown"))
        XCTAssertFalse(text.contains("hidden"))
    }

    func testRotatesPastSizeCap() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.log")
        let logger = FileLogger(fileURL: url, minLevel: .debug, maxBytes: 50)

        await logger.log(.info, String(repeating: "x", count: 60))
        await logger.log(.info, String(repeating: "y", count: 60))

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let logs = entries.filter { $0.hasSuffix(".log") }
        XCTAssertTrue(entries.contains("app.log"))      // active file recreated
        XCTAssertEqual(logs.count, 2)                   // active + one rotated archive
    }
}

final class LogCleanerTests: XCTestCase {
    func testPurgesOnlyFilesOlderThanRetention() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let old = dir.appendingPathComponent("app.123.log")
        let fresh = dir.appendingPathComponent("app.log")
        try Data("old".utf8).write(to: old)
        try Data("fresh".utf8).write(to: fresh)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)

        let deleted = LogCleaner(directory: dir, retention: 60).purge(now: Date())
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
    }
}

final class PidGuardTests: XCTestCase {
    func testAcquiresWhenNoOwner() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.pid")
        let guardA = PidGuard(pidFileURL: url, currentPID: 111, isAlive: { _ in false })
        XCTAssertEqual(try guardA.acquire(), .acquired)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "111")
    }

    func testDetectsLiveOtherInstance() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.pid")
        _ = try PidGuard(pidFileURL: url, currentPID: 111, isAlive: { _ in false }).acquire()
        let guardB = PidGuard(pidFileURL: url, currentPID: 222, isAlive: { _ in true })
        XCTAssertEqual(try guardB.acquire(), .alreadyRunning(pid: 111))
    }

    func testReclaimsStalePid() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.pid")
        _ = try PidGuard(pidFileURL: url, currentPID: 111, isAlive: { _ in false }).acquire()
        let guardB = PidGuard(pidFileURL: url, currentPID: 222, isAlive: { _ in false })
        XCTAssertEqual(try guardB.acquire(), .acquired)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "222")
    }

    func testReleaseOnlyRemovesOwnPidFile() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.pid")
        _ = try PidGuard(pidFileURL: url, currentPID: 111, isAlive: { _ in false }).acquire()
        PidGuard(pidFileURL: url, currentPID: 999, isAlive: { _ in false }).release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) // not ours → kept
        PidGuard(pidFileURL: url, currentPID: 111, isAlive: { _ in false }).release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class SemanticVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("1.4"), SemanticVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(SemanticVersion("2.0.0-beta.1"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertNil(SemanticVersion("nope"))
    }

    func testOrdering() {
        XCTAssertTrue(SemanticVersion("1.2.0")! < SemanticVersion("1.10.0")!)
        XCTAssertTrue(SemanticVersion("2.0.0")! > SemanticVersion("1.9.9")!)
        XCTAssertEqual(SemanticVersion("1.0.0"), SemanticVersion("v1.0.0"))
    }
}

/// HTTP client that returns one canned response (or fails) for any request.
private struct FixedHTTPClient: HTTPClient {
    var body: Data = Data()
    var status: Int = 200
    var fails = false
    struct Boom: Error {}
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if fails { throw Boom() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

final class UpdateCheckerTests: XCTestCase {
    private func checker(_ client: FixedHTTPClient) -> UpdateChecker {
        UpdateChecker(httpClient: client, owner: "ealliaume", repo: "mac-solplanet-energy-tracker")
    }

    func testReportsUpdateAvailable() async throws {
        let json = #"{"tag_name":"v9.9.9","html_url":"https://example.com/r/v9.9.9"}"#
        let status = try await checker(FixedHTTPClient(body: Data(json.utf8))).check(currentVersion: "0.1.0")
        XCTAssertEqual(status, .updateAvailable(version: SemanticVersion("9.9.9")!,
                                                releaseURL: "https://example.com/r/v9.9.9"))
    }

    func testReportsUpToDate() async throws {
        let json = #"{"tag_name":"v0.0.1","html_url":"https://example.com/r/v0.0.1"}"#
        let status = try await checker(FixedHTTPClient(body: Data(json.utf8))).check(currentVersion: "0.1.0")
        XCTAssertEqual(status, .upToDate(current: SemanticVersion("0.1.0")!))
    }

    func testTransportFailureThrows() async {
        do {
            _ = try await checker(FixedHTTPClient(fails: true)).check(currentVersion: "0.1.0")
            XCTFail("expected error")
        } catch let error as UpdateCheckError {
            guard case .transport = error else { return XCTFail("expected transport, got \(error)") }
        } catch { XCTFail("unexpected \(error)") }
    }

    func testBadCurrentVersionThrows() async {
        do {
            _ = try await checker(FixedHTTPClient()).check(currentVersion: "not-a-version")
            XCTFail("expected error")
        } catch let error as UpdateCheckError {
            guard case .badCurrentVersion = error else { return XCTFail("expected badCurrentVersion") }
        } catch { XCTFail("unexpected \(error)") }
    }
}
