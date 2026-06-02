import SwiftUI
import SolplanetEnergyTrackerLib

/// The Settings window (`Cmd+,`). Connection tab covers the v1 single-inverter
/// configuration ask (plan §4); General covers the refresh interval with its 5 s
/// floor (plan §10).
struct SettingsView: View {
    let preferences: any AppPreferences

    var body: some View {
        TabView {
            ConnectionSettingsView(preferences: preferences)
                .tabItem { Label("Connection", systemImage: "network") }
            GeneralSettingsView(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        // Explicit height: hosted in a plain NSWindow (not the Settings scene), a
        // Form/TabView reports no intrinsic height and the content collapses.
        .frame(width: 460, height: 360)
    }
}

private struct ConnectionSettingsView: View {
    let preferences: any AppPreferences

    @State private var host: String = ""
    @State private var serial: String = ""
    @State private var scheme: ConnectionSettings.Scheme = .https
    @State private var portText: String = ""
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded = false

    var body: some View {
        Form {
            Section("Inverter dongle") {
                TextField("IP address", text: $host, prompt: Text("192.168.4.30"))
                TextField("Serial number", text: $serial, prompt: Text("AL010K5SQ2620429"))
                Picker("Scheme", selection: $scheme) {
                    Text("https").tag(ConnectionSettings.Scheme.https)
                    Text("http").tag(ConnectionSettings.Scheme.http)
                }
                TextField("Port (optional)", text: $portText, prompt: Text("default"))
            }

            Section {
                HStack {
                    Button("Test connection") { runTest() }
                        .disabled(testing || host.isEmpty || serial.isEmpty)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(host.isEmpty || serial.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let testMessage {
                    Label(testMessage, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(testSucceeded ? Color.green : Color.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing = preferences.primaryInverter else { return }
        host = existing.host.rawValue
        serial = existing.serialNumber.rawValue
        scheme = existing.scheme
        portText = existing.port.map(String.init) ?? ""
    }

    private func currentSettings() -> ConnectionSettings {
        ConnectionSettings(host: Hostname(host.trimmingCharacters(in: .whitespaces)),
                           serialNumber: SerialNumber(serial.trimmingCharacters(in: .whitespaces)),
                           scheme: scheme,
                           port: Int(portText))
    }

    private func save() {
        preferences.primaryInverter = currentSettings()
        testMessage = "Saved. Polling will use these settings."
        testSucceeded = true
    }

    private func runTest() {
        testing = true
        testMessage = nil
        let settings = currentSettings()
        Task {
            let result = await ConnectionTester.test(settings)
            await MainActor.run {
                testing = false
                switch result {
                case .success(let reading):
                    testSucceeded = true
                    testMessage = "Connected — battery \(Int(reading.battery.soc.value.rounded()))%, "
                        + "PV \(PowerFormatting.short(reading.pv))."
                case .failure(let message):
                    testSucceeded = false
                    testMessage = message
                }
            }
        }
    }
}

private struct GeneralSettingsView: View {
    let preferences: any AppPreferences

    @State private var interval: Double = PollingLimits.defaultRefreshInterval

    var body: some View {
        Form {
            Section("Refresh") {
                VStack(alignment: .leading) {
                    Text("Poll every \(Int(interval)) s")
                    Slider(value: $interval,
                           in: PollingLimits.minimumRefreshInterval...120,
                           step: 1) { _ in
                        preferences.refreshIntervalSeconds = interval
                    }
                    Text("Minimum \(Int(PollingLimits.minimumRefreshInterval)) s — the dongle can stop responding if polled faster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { interval = preferences.refreshIntervalSeconds }
    }
}
