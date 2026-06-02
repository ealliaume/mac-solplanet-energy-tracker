import Foundation
import ServiceManagement

/// Registers/unregisters the app as a macOS login item via `SMAppService`
/// (no helper bundle, no deprecated `SMLoginItemSetEnabled`). The system stores
/// the state, so there is no preference to persist and the default is "off"
/// (`.notRegistered`). Only meaningful when running from an installed `.app`.
struct LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
