import Foundation

/// Pure functions encoding the hard-won API truths from
/// `docs/solplanet-api-documentation.md`. Kept free of I/O and side effects so
/// they can be locked by fixtures (plan §14 — including the high-PV regression
/// that disproved `-(pb + pac)`).
public enum PowerDerivations {
    /// PV generation = inverter AC output = `-pac`, clamped at 0.
    ///
    /// The battery is **AC-coupled**: PV is inverted to the AC bus and the battery
    /// charges *from* that bus, so `-pac` already includes the charging power. Do
    /// **not** use `-(pb + pac)` — it double-counts the charge (~1.7× too high).
    public static func pv(inverterPac pac: Int) -> Watts {
        Watts(Double(max(0, -pac)))
    }

    /// Direction from the sign of `pb` (device=4): `<0` charging, `>0` discharging.
    public static func batteryDirection(pb: Int) -> BatteryDirection {
        if pb < 0 { return .charging }
        if pb > 0 { return .discharging }
        return .idle
    }

    /// Grid direction from the meter's signed `pac` (assumed `>0` export, `<0`
    /// import — see API doc, unverified pending a live CT meter).
    public static func gridDirection(meterPac: Int) -> GridDirection {
        if meterPac > 0 { return .exporting }
        if meterPac < 0 { return .importing }
        return .idle
    }

    /// House load.
    ///
    /// With a CT meter the AC-bus balance gives an exact figure:
    /// `house_load = PV + pb − grid_export` (battery_charge ≈ `-pb`). Without a
    /// meter the same expression `PV + pb` is a noisy difference of two large,
    /// asynchronously-sampled values, so it is returned as `derivedRough` and never
    /// presented as exact. `pacSign`: grid `pac` is `>0` export, `<0` import.
    public static func load(pvWatts: Watts, pb: Int, meterPac: Int?) -> LoadState {
        if let grid = meterPac {
            let load = pvWatts.value + Double(pb) - Double(grid)
            return LoadState(value: Watts(load), quality: .exact)
        }
        let rough = max(0, pvWatts.value + Double(pb))
        return LoadState(value: Watts(rough), quality: .derivedRough)
    }
}
