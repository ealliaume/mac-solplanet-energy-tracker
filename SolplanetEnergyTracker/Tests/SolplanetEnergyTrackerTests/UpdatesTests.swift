import XCTest
@testable import SolplanetEnergyTrackerLib

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sbet-upd-\(UUID().uuidString)", isDirectory: true)
    // swiftlint:disable:next force_try
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// HTTP client returning one canned response (mirrors the one in LifecycleTests).
private struct CannedHTTPClient: HTTPClient {
    var body: Data = Data()
    var status: Int = 200
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private func releaseJSON(tag: String, assets: [(String, String)], body: String? = nil) -> Data {
    let assetsJSON = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }
        .joined(separator: ",")
    let bodyField = body.map { #","body":"\#($0)""# } ?? ""
    let json = #"""
    {"tag_name":"\#(tag)","html_url":"https://example.com/r/\#(tag)","published_at":"2026-06-01T10:00:00Z","assets":[\#(assetsJSON)]\#(bodyField)}
    """#
    return Data(json.utf8)
}

final class UpdateCheckerRichTests: XCTestCase {
    private let zipName = UpdateChecker.defaultDownloadAssetName

    private func checker(_ client: CannedHTTPClient) -> UpdateChecker {
        UpdateChecker(httpClient: client, owner: "ealliaume", repo: "mac-solplanet-energy-tracker")
    }

    func testReturnsRichUpdateWithAssets() async throws {
        let data = releaseJSON(tag: "v9.9.9", assets: [
            (zipName, "https://example.com/dl/\(zipName)"),
            ("\(zipName).sha256", "https://example.com/dl/\(zipName).sha256"),
        ], body: "## What\\n- thing")
        let result = try await checker(CannedHTTPClient(body: data)).checkForUpdate(currentVersion: SemanticVersion("0.1.0")!)
        let update = try XCTUnwrap(result.update)
        XCTAssertEqual(update.version, SemanticVersion("9.9.9"))
        XCTAssertEqual(update.downloadURL.absoluteString, "https://example.com/dl/\(zipName)")
        XCTAssertEqual(update.sha256URL?.absoluteString, "https://example.com/dl/\(zipName).sha256")
        XCTAssertNotNil(update.releaseNotes)
        XCTAssertNotNil(update.publishedAt)
    }

    func testNoUpdateWhenUpToDate() async throws {
        let data = releaseJSON(tag: "v0.0.1", assets: [(zipName, "https://example.com/dl/\(zipName)")])
        let result = try await checker(CannedHTTPClient(body: data)).checkForUpdate(currentVersion: SemanticVersion("0.1.0")!)
        XCTAssertNil(result.update)
        XCTAssertEqual(result.latestVersion, SemanticVersion("0.0.1"))
    }

    func testMissingZipAssetThrows() async {
        let data = releaseJSON(tag: "v9.9.9", assets: [("Something-Else.zip", "https://example.com/dl/other.zip")])
        do {
            _ = try await checker(CannedHTTPClient(body: data)).checkForUpdate(currentVersion: SemanticVersion("0.1.0")!)
            XCTFail("expected missingDownloadAsset")
        } catch let error as UpdateCheckError {
            guard case .missingDownloadAsset = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("unexpected \(error)") }
    }

    func testHTTPErrorThrows() async {
        do {
            _ = try await checker(CannedHTTPClient(body: Data(), status: 404)).checkForUpdate(currentVersion: SemanticVersion("0.1.0")!)
            XCTFail("expected httpStatus")
        } catch let error as UpdateCheckError {
            guard case .httpStatus(404) = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("unexpected \(error)") }
    }
}

/// Fake process runner returning canned results keyed by the first argument.
private struct FakeProcessRunner: ProcessRunning {
    var resultsByFirstArg: [String: ProcessExecutionResult] = [:]
    var defaultResult = ProcessExecutionResult(stdout: Data(), terminationStatus: 1, timedOut: false)
    func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
        resultsByFirstArg[arguments.first ?? ""] ?? defaultResult
    }
}

final class InstallationDetectorTests: XCTestCase {
    func testManualWhenBrewNotFound() async {
        let detector = InstallationDetector(
            bundlePath: "/Applications/\(AppInfo.displayName).app",
            process: FakeProcessRunner(),
            homebrewBinaryPaths: [],
            pathEnvironment: "",
            loginShellPath: nil
        )
        let info = await detector.detect()
        XCTAssertEqual(info.kind, .manual)
    }

    func testBrewExecutablePathResolvesExistingBinary() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("brew")
        FileManager.default.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8))
        let detector = InstallationDetector(
            bundlePath: "/Applications/\(AppInfo.displayName).app",
            process: FakeProcessRunner(),
            homebrewBinaryPaths: [brew.path],
            pathEnvironment: "",
            loginShellPath: nil
        )
        let resolved = await detector.brewExecutablePath()
        XCTAssertEqual(resolved, brew.path)
    }

    func testManualWhenCaskroomEmptyEvenIfBrewFound() async {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("brew")
        FileManager.default.createFile(atPath: brew.path, contents: Data("#!/bin/sh\n".utf8))
        let runner = FakeProcessRunner(resultsByFirstArg: [
            "--caskroom": ProcessExecutionResult(stdout: Data(), terminationStatus: 0, timedOut: false),
        ])
        let detector = InstallationDetector(
            bundlePath: "/Applications/\(AppInfo.displayName).app",
            process: runner,
            homebrewBinaryPaths: [brew.path],
            pathEnvironment: "",
            loginShellPath: nil
        )
        let info = await detector.detect()
        XCTAssertEqual(info.kind, .manual)
    }
}

final class UpdateInstallerTests: XCTestCase {
    private func makeUpdate() -> AvailableUpdate {
        AvailableUpdate(
            version: SemanticVersion("1.2.3")!,
            releaseURL: URL(string: "https://example.com/r/v1.2.3")!,
            downloadURL: URL(string: "https://example.com/dl/app.zip")!,
            sha256URL: nil,
            publishedAt: nil
        )
    }

    func testManualPlanScriptContents() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("staged.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let bundle = dir.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let installer = UpdateInstaller(scriptDirectory: dir.appendingPathComponent("scripts"))
        let plan = try await installer.buildManualFinalizationPlan(
            stagedAppPath: staged.path, bundlePath: bundle.path, currentPID: 4242, update: makeUpdate()
        )

        let script = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine"), "must strip quarantine")
        XCTAssertTrue(script.contains(staged.path))
        XCTAssertTrue(script.contains(bundle.path))
        XCTAssertTrue(script.contains("4242"))
        // 0o755 on the script.
        let perms = try FileManager.default.attributesOfItem(atPath: plan.scriptPath)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o755)
        // Writable temp dir → no admin needed.
        XCTAssertFalse(plan.requiresAdminPrivileges)
    }

    func testHomebrewPlanIsRelaunchOnly() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let installer = UpdateInstaller(scriptDirectory: dir.appendingPathComponent("scripts"))
        let plan = try await installer.buildHomebrewFinalizationPlan(
            bundlePath: "/Applications/\(AppInfo.displayName).app", currentPID: 7, update: makeUpdate()
        )
        let script = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        XCTAssertFalse(script.contains("/bin/mv"), "brew already swapped — relaunch only")
        XCTAssertTrue(script.contains("/usr/bin/open"))
        XCTAssertFalse(plan.requiresAdminPrivileges)
    }

    func testCanReplaceBundleReflectsWritability() {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let writableBundle = dir.appendingPathComponent("Foo.app").path
        XCTAssertTrue(UpdateInstaller.canReplaceBundle(at: writableBundle, fileManager: .default))
        // /usr/bin is not user-writable on a normal system.
        XCTAssertFalse(UpdateInstaller.canReplaceBundle(at: "/usr/bin/Foo.app", fileManager: .default))
    }
}

final class BrewUpgradeRunnerTests: XCTestCase {
    /// Writes a tiny executable that echoes two lines then exits with `exitCode`.
    private func makeFakeBrew(dir: URL, exitCode: Int) throws -> String {
        let path = dir.appendingPathComponent("fakebrew").path
        let script = """
        #!/bin/bash
        echo "line one"
        echo "last line here"
        exit \(exitCode)
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testCollectsLinesAndSucceeds() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let brew = try makeFakeBrew(dir: dir, exitCode: 0)
        let lines = LinesBox()
        try await BrewUpgradeRunner().runUpgrade(brewExecutablePath: brew, caskName: "x") { event in
            if case .outputLine(let line) = event { lines.append(line) }
        }
        XCTAssertTrue(lines.all.contains("last line here"))
    }

    func testNonZeroExitThrows() async throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let brew = try makeFakeBrew(dir: dir, exitCode: 3)
        do {
            try await BrewUpgradeRunner().runUpgrade(brewExecutablePath: brew, caskName: "x") { _ in }
            XCTFail("expected nonZeroExit")
        } catch let error as BrewUpgradeRunnerError {
            guard case .nonZeroExit(let status, let lastLine) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(status, 3)
            XCTAssertEqual(lastLine, "last line here")
        }
    }
}

/// Thread-safe line accumulator for the streaming callback (invoked off-actor).
private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
