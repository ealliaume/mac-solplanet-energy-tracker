import SwiftUI
import SolplanetEnergyTrackerLib

/// Menubar-only entry point. The real surface is an `NSStatusItem` managed by
/// `AppDelegate`; this `App` exists only to host the Settings scene (so `Cmd+,`
/// and the menu's "Settings…" item resolve to a window) and to install the
/// delegate. There is intentionally no `WindowGroup` — see `AppDelegate` for the
/// `.accessory` activation policy that keeps the app out of the Dock.
@main
struct SolplanetBatteryEnergyTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                preferences: UserDefaultsAppPreferences.shared,
                updateState: AppDelegate.sharedUpdateState
            )
        }
    }
}
