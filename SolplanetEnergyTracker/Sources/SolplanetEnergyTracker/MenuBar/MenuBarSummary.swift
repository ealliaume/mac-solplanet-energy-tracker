import Foundation

/// Builds the compact menu-bar label text from a reading and the user's display
/// options. Pure → unit tested. (Per-segment colour rasterization is M4.)
public enum MenuBarSummary {
    public static func text(for reading: InverterReading?,
                            options: MenuBarDisplayOptions = .default) -> String {
        guard let reading else { return AppInfo.unconfiguredLabel }

        var segments: [String] = []

        if options.showPV {
            segments.append("☀ \(PowerFormatting.short(reading.pv))")
        }
        if let battery = batterySegment(reading.battery, display: options.battery) {
            segments.append(battery)
        }
        if options.showLoad {
            let approx = reading.load.quality == .exact ? "" : "≈"
            segments.append("🏠\(approx) \(PowerFormatting.short(reading.load.value))")
        }
        if options.showGrid {
            segments.append(gridSegment(reading.grid))
        }
        if options.showTemperature, let temp = reading.temperature {
            segments.append("🌡 \(Int(temp.value.rounded()))°C")
        }

        // Everything turned off but an inverter is configured — keep a minimal mark.
        if segments.isEmpty { segments.append("☀") }

        let prefix = reading.health.online ? "" : "⚠ "
        return prefix + segments.joined(separator: "  ")
    }

    private static func batterySegment(_ battery: BatteryState,
                                       display: MenuBarDisplayOptions.BatteryDisplay) -> String? {
        let arrow: String
        switch battery.direction {
        case .charging: arrow = "↑"
        case .discharging: arrow = "↓"
        case .idle: arrow = ""
        }
        let watt = PowerFormatting.short(battery.power)
        let percent = "\(Int(battery.soc.value.rounded()))%"

        switch display {
        case .none: return nil
        case .percent: return "🔋 \(percent)"
        case .watt: return "🔋\(arrow) \(watt)"
        case .both: return "🔋\(arrow) \(watt) \(percent)"
        }
    }

    private static func gridSegment(_ grid: GridState) -> String {
        guard grid.available else { return "⚡ n/a" }
        let arrow: String
        switch grid.direction {
        case .exporting: arrow = "↑"
        case .importing: arrow = "↓"
        case .idle: arrow = ""
        }
        return "⚡\(arrow) \(PowerFormatting.short(grid.power))"
    }
}
