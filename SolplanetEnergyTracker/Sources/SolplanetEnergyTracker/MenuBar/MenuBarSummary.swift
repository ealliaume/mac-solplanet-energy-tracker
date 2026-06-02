import Foundation

/// Builds the compact menu-bar label text from a reading. The full per-segment,
/// per-colour rasterized renderer is M4; this is the M3-wiring text the status
/// item shows so live data is visible end to end. Pure → unit tested.
public enum MenuBarSummary {
    /// `nil` reading ⇒ the first-launch CTA; otherwise `☀ <pv>  🔋 <soc>%`, with a
    /// warning glyph when the inverter is unreachable.
    public static func text(for reading: InverterReading?) -> String {
        guard let reading else { return AppInfo.unconfiguredLabel }
        let pv = PowerFormatting.short(reading.pv)
        let soc = "\(Int(reading.battery.soc.value.rounded()))%"
        let prefix = reading.health.online ? "" : "⚠ "
        return "\(prefix)☀ \(pv)  🔋 \(soc)"
    }
}
