# Solplanet / AISWEI Local Inverter API

Reverse-engineered documentation for the **local HTTP API** exposed by the AISWEI
Wi-Fi/LAN dongle (Ai-Dongle) shipped with Solplanet hybrid inverters.

There is **no official public spec** — this combines hands-on measurements from
this installation with community reverse-engineering (see [Sources](#sources)).

> Verified against: inverter `AL010K5SQ2620429`, dongle model `B51312-30`
> (AISWEI Ai-Dongle LAN/WLAN), firmware `V610-52015-06.004`, protocol `V2.2`.

---

## Connection

| | |
|---|---|
| Transport | HTTP (some firmware uses HTTPS with a self-signed cert) |
| Host | The dongle's IP on your LAN (e.g. `192.168.4.30`) |
| Port | `443` (HTTPS) on this unit; community reports `8484` (HTTP) on others |
| Auth | **None** — endpoints are unauthenticated |
| TLS | Self-signed → use `curl -k` / disable cert verification |

### Rate limits (important)

The dongle is an ESP32 with very little headroom. Community guidance:

- **Max ~1 request every 5 seconds.**
- Polling in a tight loop (especially scanning Modbus registers) can **brick the
  dongle for ~10 minutes** until it reboots.

Keep poll intervals at **≥5 s** and avoid hammering on errors.

---

## Endpoints

### `GET /getdev.cgi`

Returns dongle metadata (not power data). Useful to discover the serial / confirm
connectivity.

```
https://<host>/getdev.cgi?device=0
```

Returns: dongle serial (`psn`), model (`mod`), manufacturer (`muf`), firmware
(`sw`), protocol version, MACs, cloud endpoint, `max_meter_num`, etc.

### `GET /getdevdata.cgi`

The main data endpoint. Returns live JSON for a given sub-device.

```
https://<host>/getdevdata.cgi?device=<N>&sn=<INVERTER_SERIAL>
```

| `device` | Component | Notes |
|----------|-----------|-------|
| `2` | **Inverter** (AC side) | Has `vpv`/`ipv`/`pf`/`tmp` → it is the inverter, **not** the grid meter. |
| `3` | **Smart meter** (grid CT) | `meter_general` block. **May be disabled** (`flg:0`) if no CT is installed. |
| `4` | **Battery / ESS** | SOC, battery power, voltages, currents. |
| `5` | Diesel/genset | All-zero on systems without a generator. |
| others | — | Return `request not found, 404`. |

A response with `"flg":0` means that sub-device is **disabled / not reporting**;
`"flg":1` means data is live.

---

## Field reference

### device=4 — Battery / ESS

| Field | Meaning | Unit / scaling | Notes |
|-------|---------|----------------|-------|
| `ppv` | PV power | W | ⚠️ **Unreliable on this firmware — stuck at `0`** even while PV produces. See [Deriving PV](#deriving-pv-power). |
| `etdpv` | PV energy, today | — | Also `0` on this unit (tied to broken `ppv`). |
| `etopv` | PV energy, total | — | |
| `soc` | State of charge | % | Reliable. |
| `soh` | State of health | % | |
| `pb` | Battery power | W | **`<0` = charging, `>0` = discharging.** See [sign convention](#battery-sign-convention). |
| `vb` | Battery voltage (BMS terminal) | V ×100 | Divide by 100 (e.g. `5240` → 52.40 V). |
| `cb` | Battery current (BMS terminal) | A ×10 | Sign tracks `pb`. |
| `vbinv` | Battery voltage (inverter side) | V ×100 | Reads ~0.3 V above `vb` regardless of direction — **not** a charge indicator. |
| `cbinv` | Battery current (inverter side) | A ×10 | |
| `tb` | Battery temperature | °C ×10 | |
| `bst` | Battery status | enum | `2` ≈ idle/standby, `3` ≈ active (charge or discharge). Not directional. |
| `cst` | (Charge?) status | enum | |
| `*esp` (`vesp`,`pesp`,`vl1esp`…) | Backup / EPS port | | Off-grid backup output; `0` when unused. |

### device=2 — Inverter (AC side)

| Field | Meaning | Unit / scaling | Notes |
|-------|---------|----------------|-------|
| `pac` | Inverter AC power | W | `<0` = exporting to AC bus, `>0` = drawing from AC. This is the **total** PV output (battery is AC-coupled and charges from this bus), so **`PV = -pac`**. |
| `sac` | Apparent power | VA | |
| `qac` | Reactive power | var | |
| `pf` | Power factor | ×100 | e.g. `83` → 0.83 |
| `vac` | AC voltage (per phase) | V ×10 | array, e.g. `[2450]` → 245.0 V |
| `iac` | AC current (per phase) | A ×10 | array |
| `fac` | Grid frequency | Hz ×100 | e.g. `5000` → 50.00 Hz |
| `tmp` | Inverter temperature | °C ×10 | |
| `vpv` / `ipv` | PV string voltage / current | V/A | arrays; **read `0` on this unit** (DC-coupled PV not surfaced here). |
| `eto` / `etd` | Energy total / daily | ×10 | cumulative counters |
| `pac1/2/3`, `qac1/2/3` | Per-phase active/reactive | W/var | `-1` when unavailable |
| `grid_sts` | Grid status | enum | |

### device=3 — Smart meter (grid CT)

Block `meter_general` (`prc`, `sac`, `iac`, `avg_v`, `avg_i`, `fac`, `pf`) plus
per-phase arrays. **`flg:0` on this install** → no CT meter wired, so **true grid
import/export and house load are not available locally.** The mobile app obtains
those from the cloud instead.

---

## Battery sign convention

`pb < 0` = **charging**, `pb > 0` = **discharging**. `cb` (terminal current) shares
the same sign as `pb`.

Confirmed against the Solplanet app during a high-PV event: app showed ~2791 W
generating while `pb = -871` (charging) and `pac = -967` (exporting) — both negative,
i.e. PV pouring into the battery and the grid. Cross-checked with the original full
reading (PV 841, battery 421 **charging** ⇒ `pb = -421`).

> ⚠️ `vbinv` (inverter-side battery voltage) reads ~0.3 V above `vb` (terminal)
> **in all directions**, so it is *not* a charge/discharge indicator. Use the sign
> of `pb`/`cb`.

> Note: the mobile app polls the **cloud** API and lags real time by **~2 minutes**.
> Around a near-zero crossing (PV ≈ load) the app and the local register can briefly
> disagree on charge vs. discharge — that's lag, not a bug.

---

## Deriving PV power

`ppv` (device=4) is **dead on this firmware (always `0`)**, and the PV string
fields `vpv`/`ipv` (device=2) also read `0`. The community confirms *"no standard
method for separating PV-only power is documented."*

**The battery is AC-coupled.** PV is converted to AC by the inverter and put on the
AC bus; the battery charges *from* that bus, alongside the house and grid. So the
inverter's AC output (`-pac`) is the **total** PV delivered — it already includes the
battery-charging power:

```
PV = -pac        (inverter AC output, device=2)
```

The AC bus splits that output into its sinks:

```
PV  =  battery_charge  +  house_load  +  grid_export  -  grid_import     (all AC)
```

Clamp PV at `0` (negative `-pac` = the inverter is importing, no PV).

> ⚠️ **Do NOT use `-(pb + pac)`** — that adds the battery charge a second time
> (it is already inside `-pac`) and roughly *doubles* the result.

**Validation against the Solplanet app:**

| | app PV | `pac` | `-pac` | `-(pb+pac)` (wrong) |
|---|-------:|------:|-------:|--------------------:|
| high-PV event | 4801 W | −4274 | **4274 W** ✓ (app lags ~2 min; PV falling) | 8303 W ✗ (~1.7×) |

The decisive proof: while PV was *falling* (SOC climbing, clouds), `-(pb+pac)`
read *higher* than the lagging app value — impossible for a correct formula, so it
is structurally wrong. `-pac` read *below* the app value, consistent with the drop.

The app's own four numbers are internally exact and lag-free, which pins the model:
`4801 = 4380 (batt) + 400 (load) + 21 (grid export)`.

### Why house load & grid can't be derived (without the meter)

When charging hard, `PV ≈ battery_charge` (the house+grid remainder is small), so
house load is the **tiny difference of two large numbers** — and `pb` (device=4)
and `pac` (device=2) refresh on *different* cadences (device=2 can lag 60 s+). That
makes the difference far too noisy to trust:

```
house_load = PV + pb - grid_export        (battery_charge ≈ -pb; grid = device=3)
```

Enable the grid CT meter (`device=3`, Solplanet app / installer menu) for a usable
grid figure; house load is then `PV + pb - grid_export` (still ±battery charge
efficiency, ~8%).

---

## Worked example (live snapshot, high-PV)

```
device=4: ppv=0  pb=-4029  soc=55  vb=5330  cb=-756
device=2: pac=-4274

PV       = -pac = 4274 W            (app showed 4801, lagging/falling)
Battery  = 4029 W charging (pb<0), 55%, 53.30 V
House    = PV + pb = 245 W  (rough; small noisy diff - needs meter)
Grid     = unavailable (meter disabled)
```

This repo's `scripts/battery_status.sh` implements exactly this logic.

---

## Sources

- Home Assistant community thread — *API integration for Solplanet inverter (AISWEI)*:
  <https://community.home-assistant.io/t/api-integration-for-solplanet-inverter-aiswei/569754>
- `zbigniewmotyka/home-assistant-solplanet` — local-polling HA integration:
  <https://github.com/zbigniewmotyka/home-assistant-solplanet>
- `Fufs/pysolplanet` — standalone Python client for the dongle:
  <https://github.com/Fufs/pysolplanet>
- `PatMan6889/AISWEI-Solplanet-Cloud-API` — the cloud API the mobile app uses:
  <https://github.com/PatMan6889/AISWEI-Solplanet-Cloud-API>
- dev.to — *I Reverse-Engineered My Solar Inverter API* (rate limits, bricking warning):
  <https://dev.to/alexchen31337/i-reverse-engineered-my-solar-inverter-api-to-export-5kw-to-the-grid-47hp>

> Field meanings marked "on this firmware / this unit" are observed behaviour of the
> hardware listed at the top and may differ across dongle models and firmware versions.
