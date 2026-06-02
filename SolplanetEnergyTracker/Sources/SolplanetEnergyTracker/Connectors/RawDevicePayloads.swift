import Foundation

/// Verbatim decodes of the dongle's `getdevdata.cgi` JSON, one struct per
/// sub-device. These mirror the wire format exactly (raw field names, raw integer
/// scalings) — all unit conversion and derivation happens in `PowerDerivations` /
/// `SolplanetReadingMapper`, never here. Fields are optional so a firmware that
/// omits one decodes instead of throwing (plan §16 "firmware variance").

/// `device=4` — Battery / ESS.
public struct BatteryDeviceRaw: Sendable, Codable, Equatable {
    public var flg: Int?
    public var tim: String?
    public var ppv: Int?       // PV power — dead on this firmware (always 0)
    public var soc: Int?       // %
    public var soh: Int?       // %
    public var pb: Int?        // battery power, W (<0 charging, >0 discharging)
    public var vb: Int?        // battery voltage, V ×100
    public var cb: Int?        // battery current, A ×10
    public var tb: Int?        // battery temperature, °C ×10
    public var bst: Int?       // battery status enum (not directional)
}

/// `device=2` — Inverter (AC side).
public struct InverterDeviceRaw: Sendable, Codable, Equatable {
    public var flg: Int?
    public var tim: String?
    public var pac: Int?       // inverter AC power, W (<0 export to bus, >0 draw)
    public var sac: Int?       // apparent power, VA
    public var qac: Int?       // reactive power, var
    public var pf: Int?        // power factor ×100
    public var fac: Int?       // grid frequency, Hz ×100
    public var tmp: Int?       // inverter temperature, °C ×10
    public var eto: Int?       // energy total ×10
    public var etd: Int?       // energy today ×10
    public var err: Int?       // error code (0 = none)
    public var grid_sts: Int?  // grid status enum
    public var vac: [Int]?     // AC voltage per phase, V ×10
    public var iac: [Int]?     // AC current per phase, A ×10
}

/// `device=3` — Smart meter (grid CT). `flg == 0` ⇒ no CT wired (disabled here).
public struct MeterDeviceRaw: Sendable, Codable, Equatable {
    public var flg: Int?
    public var tim: String?
    public var pac: Int?       // signed grid power: >0 export, <0 import (assumed)
    public var enb: Int?

    public var isEnabled: Bool { (flg ?? 0) == 1 }
}
