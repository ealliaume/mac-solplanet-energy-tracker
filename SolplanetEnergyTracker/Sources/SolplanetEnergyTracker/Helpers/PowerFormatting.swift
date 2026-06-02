import Foundation

/// Formats power magnitudes for display, auto-scaling to kW at/above 1 kW
/// (plan §7 "value unit: W vs kW"). Pure and locale-stable for testability.
public enum PowerFormatting {
    private static let kilowattThreshold = 1000.0

    /// e.g. `486` → "486 W", `1432` → "1.4 kW". Uses the magnitude only.
    public static func short(_ watts: Watts) -> String {
        let magnitude = abs(watts.value)
        if magnitude >= kilowattThreshold {
            return String(format: "%.1f kW", magnitude / 1000)
        }
        return "\(Int(magnitude.rounded())) W"
    }
}
