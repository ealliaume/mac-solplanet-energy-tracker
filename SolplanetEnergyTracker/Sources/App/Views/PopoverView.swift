import SwiftUI
import SolplanetEnergyTrackerLib

/// Popover shown when the menu-bar item is clicked. Live metric rows + a health
/// banner (plan §8/§9). Charts (M6) and the energy-flow hero card are follow-ups.
struct PopoverView: View {
    let store: ReadingsStore
    let historyReader: HistoryReader
    var onRefresh: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case now = "Now"
        case charts = "Charts"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let update = store.availableUpdate {
                updateBanner(update)
            }
            if store.primary != nil {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let reading = store.primary {
                switch mode {
                case .now:
                    healthBanner(for: reading)
                    Divider()
                    metrics(for: reading)
                case .charts:
                    EnergyHistoryChartView(reader: historyReader)
                }
            } else {
                Text("No inverter configured. Open Settings to enter the dongle IP and serial number.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
            supportLink
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text(AppInfo.displayName).font(.headline)
            Spacer()
            if let reading = store.primary {
                Circle()
                    .fill(reading.health.online ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(reading.health.online ? "Online" : "Offline")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func healthBanner(for reading: InverterReading) -> some View {
        if !reading.health.online {
            banner("Inverter unreachable — showing last known values.", color: .red, icon: "wifi.slash")
        } else if reading.health.stale {
            banner("Data is stale.", color: .orange, icon: "clock.badge.exclamationmark")
        } else if let code = reading.health.errorCode {
            banner("Inverter error code \(code).", color: .orange, icon: "exclamationmark.triangle")
        } else if !reading.health.meterEnabled {
            banner("Grid & exact load need the CT meter (enable it in the Solplanet mobile app).",
                   color: .secondary, icon: "bolt.badge.questionmark")
        }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metrics(for reading: InverterReading) -> some View {
        VStack(spacing: 8) {
            MetricRow(icon: "sun.max.fill", label: "PV", value: PowerFormatting.short(reading.pv))
            MetricRow(icon: "battery.100", label: batteryLabel(reading),
                      value: "\(PowerFormatting.short(reading.battery.power))  ·  \(Int(reading.battery.soc.value.rounded()))%")
            MetricRow(icon: "house.fill",
                      label: reading.load.quality == .exact ? "Load" : "Load ≈",
                      value: PowerFormatting.short(reading.load.value))
            MetricRow(icon: "bolt.fill", label: "Grid",
                      value: reading.grid.available ? PowerFormatting.short(reading.grid.power) : "n/a")
            if let temp = reading.temperature {
                MetricRow(icon: "thermometer.medium", label: "Inverter", value: String(format: "%.0f °C", temp.value))
            }
        }
    }

    private func batteryLabel(_ reading: InverterReading) -> String {
        switch reading.battery.direction {
        case .charging: return "Battery ↑"
        case .discharging: return "Battery ↓"
        case .idle: return "Battery"
        }
    }

    private var footer: some View {
        HStack {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            if let updatedAt = store.lastUpdatedAt {
                Text("Updated \(updatedLabel(updatedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings…", action: onOpenSettings)
            Button("Quit", action: onQuit)
        }
    }

    private func updateBanner(_ update: AvailableUpdate) -> some View {
        Link(destination: URL(string: update.url) ?? Self.sponsorURL) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Version \(update.version) is available — view release")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func updatedLabel(_ date: Date) -> String {
        // Within a few seconds the relative formatter says "in 0 seconds"; show a
        // friendlier "just now" instead so a manual refresh reads cleanly.
        if Date().timeIntervalSince(date) < 5 { return "just now" }
        return date.formatted(.relative(presentation: .numeric))
    }

    /// GitHub Sponsors' heart colour (#DB61A2).
    private static let sponsorPink = Color(red: 0.859, green: 0.380, blue: 0.635)
    private static let sponsorURL = URL(string: "https://github.com/sponsors/ealliaume")! // known-valid literal

    private var supportLink: some View {
        Link(destination: Self.sponsorURL) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(Self.sponsorPink)
                Text("Support this project")
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Support this project on GitHub Sponsors")
    }
}

private struct MetricRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
    }
}
