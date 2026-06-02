import XCTest
@testable import SolplanetBatteryEnergyTracker

/// Smoke test: reading the login-item status must not trap, even outside an
/// installed `.app` bundle (the toggle's `.onAppear` calls this). We don't assert
/// the value — it depends on the host — only that the call is safe.
final class LaunchAtLoginTests: XCTestCase {
    func testReadingStatusIsSafe() {
        let enabled = LaunchAtLoginService.shared.isEnabled
        XCTAssertTrue(enabled == true || enabled == false)
    }
}
