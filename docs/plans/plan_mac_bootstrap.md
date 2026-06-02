# Bootstrap plan — Solplanet Energy Tracker (macOS menu bar app)

> **Status:** in progress — M0–M3 + M5 + M6 + M9 shipped; M4 (color logic only), M7, M8 outstanding. See §15 for the per-milestone table. Last updated 2026-06-02.
> **Author:** initial capture 2026-06-02.
> **Reference codebase:** `/Users/ealliaume/private/git/mac-ai-trackers` ("AI Usages Tracker").
> **API reference:** [`docs/solplanet-api-documentation.md`](../solplanet-api-documentation.md) (the live inverter local API, reverse-engineered).

This plan describes how to bootstrap a macOS menu bar app that surfaces live
Solplanet/AISWEI inverter data (PV, battery, house load, grid) in the menu bar,
records history, and renders charts — by **reusing the proven architecture,
tooling, and engineering rules** of the AI Usages Tracker, adapted to a solar
energy use case.

---

## 1. Goals & scope

### In scope (v1)
- Menubar-only macOS app (no Dock icon, no main window) showing live inverter data.
- **Configurable connection**: inverter dongle IP, serial number, scheme, timeout.
- **Configurable menu bar content**: which metrics appear (PV / Battery / SOC / Load / Grid), order, units, direction arrows, colors, separator.
- Popover with an energy-flow card (PV → battery / house / grid), gauges, and SOC.
- **History + charts**: PV, battery power, SOC, load, grid over 6 h / 24 h / 7 d / 30 d / all.
- Health/status surface: inverter offline, stale data, inverter error code, grid status, "grid meter disabled" notice.
- Adjustable refresh interval with a **hard 5 s floor** (dongle rate-limit / brick protection).
- Reuse: logging, atomic IO, file-watcher display pipeline, preferences, launch-at-login, self-update, build/dist scripts, CI, Swift quality rules.

### Out of scope (v1, revisit later)
- Writing/controlling the inverter (charge schedules, export limits). **Read-only by design** — mirrors the AI app's "never mutate the source" invariant.
- Cloud API integration (the app uses the **local** dongle API; cloud lags ~2 min).
- Multi-site / fleet dashboards (architecture leaves room; UI is single-Mac).

---

## 2. Why this maps so cleanly

The AI Usages Tracker is, abstractly, a *"poll a source on an interval → normalize to a value model → persist snapshot → render configurable chips in the menu bar + charts in a popover"* engine. Solar telemetry is the same shape with different nouns. The table below is the core of this plan.

| AI Usages Tracker concept | Solplanet Energy Tracker equivalent |
|---|---|
| Vendor (claude/codex/copilot) | **Inverter source** (Solplanet AISWEI dongle). One built-in source type; multiple *instances* by IP. |
| Vendor registry (compile-time seam) | **Inverter registry** + runtime list of user-configured inverters (IP/SN). |
| Account auto-discovery from local files | **Inverter auto-identify**: user enters IP → app calls `getdev.cgi` to read SN/model/firmware. |
| `CredentialLocator` (read tokens) | **`ConnectionSettings`** (host, SN, scheme, timeout). No secrets, no Keychain. |
| `UsageConnector.fetchUsages()` | **`InverterConnector.fetchReading()`** → queries `device=4`,`device=2`,`device=3`. |
| `VendorUsageEntry` (vendor+account, metrics) | **`InverterReading`** (host+SN, PV/battery/load/grid/energy). |
| `UsageMetric` (.timeWindow / .payAsYouGo) | **`PowerMetric`** (instantaneous W, signed/directional) + **`EnergyMetric`** (kWh today/total). |
| Consumption tiers (pace → color) | **Power/SOC tiers** (charge vs discharge, import vs export, SOC level → color). |
| Vendor status / outages banner | **Inverter health banner** (offline, stale, `err` code, grid down, meter disabled). |
| Active-account monitor | **(dropped)** — replaced by stale-reading watchdog. |
| Payload sanitizer (redact tokens) | **Light sanitizer** (mask SN in logs; redact nothing secret but keep the boundary). |
| Menu bar chips/segments | **Energy segments** (PV / SOC / Battery± / Load / Grid±) — exactly the "configurable menu bar content" ask. |
| History JSONL + charts | **Power/SOC history** JSONL + charts (near-identical infra). |
| Refresh interval pref | Refresh interval pref **with 5 s floor**. |

Everything below the registry seam (logging, IO, file watcher, store, charts, settings shell, updates, build) is reused largely **as-is**.

---

## 3. Architecture (inherited, with deltas)

Keep the reference's invariants verbatim:

- **Menubar-only**: `NSApplication.setActivationPolicy(.accessory)`, `LSUIElement=true`.
- **`NSStatusItem`, not `MenuBarExtra`** — required for per-segment colors and multi-segment labels. Follow [`SWIFT-MENUBAR.md`](../../../mac-ai-trackers/docs/SWIFT-MENUBAR.md) (copy into this repo's docs): rasterize a **non-template** `NSImage`, pick text color from `button.effectiveAppearance`, re-arm `withObservationTracking`.
- **Library + executable split**: all domain logic in a lib target; the executable is a thin SwiftUI/AppKit entry point.
- **`@Observable` store on `@MainActor`** fed by a **file watcher** over the snapshot JSON; the poller and UI are decoupled through the file (so an external script/widget can read the same file under `flock`).
- **Atomic writes + advisory `flock`** for the data file; append-only JSONL for history.

### Data flow

```
InverterPoller (actor, every N≥5 s)
   └─ InverterConnector.fetchReading()           // device=4 + device=2 (+device=3 if enabled)
        └─ derive PV = -pac, battery = pb, load/grid (meter-aware)
   └─ ReadingsFileManager.write(atomic, flock)    // ~/.cache/solplanet-energy-tracker/readings.json
        └─ SnapshotRecorder.appendIfChanged()      // history/YYYY/MM/YYYY-MM-DD.jsonl

ReadingsFileWatcher (DispatchSource + poll backstop, debounced)
   └─ ReadingsStore (@MainActor @Observable)
        ├─ menu bar segments  → MenuBarLabelRenderer → NSStatusItem image
        └─ popover (SwiftUI)  → energy card, gauges, charts, health banner
```

### Swift package targets (mirror the reference)

```
SolplanetEnergyTracker/                      # Swift package root
  Package.swift                              # swift-tools 6.0, macOS 14, SwiftLint plugin
  Sources/
    SolplanetEnergyTracker/   (lib target "SolplanetEnergyTrackerLib")
      Connectors/    InverterConnector, SolplanetConnector, ConnectionSettings,
                     InverterIdentifier (getdev.cgi), HTTPClient (self-signed TLS),
                     InverterHealth
      Models/        InverterReading, PowerMetric, EnergyMetric, BatteryState,
                     GridState, ValueObjects (Watts, Percent, Volts, ISODate, Host, SerialNumber),
                     PowerSnapshot, ChartConfiguration, MenuBarSegmentConfig
      Persistence/   ReadingsFileManager, SnapshotRecorder, HistoryReader, StartupMigrationRunner
      FileWatcher/   ReadingsFileWatcher
      Scheduler/     InverterPoller, SnapshotScheduler
      Store/         ReadingsStore, RefreshState
      Helpers/       PowerDerivations (PV=-pac etc.), MenuBarSegmentResolver, ChartSeriesResolver
      Logging/       Logger, LoggingProxy, PayloadSanitizing (SN mask), LogCleaner
      Preferences/   AppPreferences (+UserDefaults impl), keys, seeders, LaunchAtLogin
      Plugins/       InverterRegistry, InverterBundle (keeps the "registry is the only seam")
      Updates/       (reused as-is) UpdateChecker/Downloader/Installer/Scheduler
    App/   (executable "SolplanetEnergyTracker")
      SolplanetEnergyTrackerApp.swift, AppDelegate.swift, AppPidGuard.swift,
      MenuBarLabelRenderer.swift, LaunchAtLoginService.swift,
      Views/  EnergyFlowCard, GaugeBar, PowerMetricRow, BatteryGauge,
              EnergyHistoryChartView, InverterHealthBanner,
              Settings/ (Connection, MenuBar, Charts, General, Updates, Health)
      Resources/  (app icon, optional brand mark)
    AppIconKit/        AppIconView (sun/battery glyph)
    IconExporter/      iconset → .icns
  Tests/SolplanetEnergyTrackerTests/   (+ Fixtures/ with real captured JSON)
```

---

## 4. Connection & configuration (the IP/SN ask)

The user explicitly wants the dongle IP configurable. Model it as a value type and a settings tab.

### `ConnectionSettings` (value object, Codable, stored in prefs)
```
host: Host                 // e.g. 192.168.4.30  (validated IPv4/hostname)
serialNumber: SerialNumber // e.g. AL010K5SQ2620429
scheme: "https" | "http"   // default https (dongle uses self-signed TLS)
port: Int?                 // default nil (443); some firmware uses 8484/http
timeoutSeconds: Int        // default 10
```

### Connection settings tab
- Text fields for **IP** and **Serial number**, scheme/port advanced disclosure.
- **"Detect" button**: calls `GET /getdev.cgi` → fills SN, model, firmware (auto-identify, mirrors the AI app's auto-discovery philosophy). Shows dongle model/firmware read back.
- **"Test connection" button**: one `fetchReading()` round-trip, reports OK / timeout / TLS / 404 with an actionable message.
- Multi-inverter ready: store `inverters: [ConnectionSettings]` (v1 UI can expose one; the list and `InverterRegistry` keep the seam open for more).

### Self-signed TLS (must-do, security-noted)
The dongle serves HTTPS with a self-signed cert. Implement a `URLSessionDelegate`
that trusts the cert **only for the configured host(s)** (pinned by host, not a
global `NSAllowsArbitraryLoads`). Document this in a `SWIFT-IO-ROBUSTNESS`-style
note. Provide an `http` fallback for firmwares that expose port 8484.

### Rate-limit / brick protection (must-do)
Community sources warn the ESP32 dongle can be **bricked ~10 min by tight polling**.
- Enforce a **hard minimum refresh interval of 5 s** in the preferences setter (clamp, don't trust UI).
- Serialize the two device queries within a tick (no parallel hammering); add small spacing.
- On repeated timeouts, **back off** (exponential, capped) instead of retrying tightly.

---

## 5. Domain model & derivations

Encode the hard-won API truth (see [`solplanet-api-documentation.md`](../solplanet-api-documentation.md)) **inside the connector**, with the documented formulas:

- **PV** = `-pac` (device=2 inverter AC output; battery is AC-coupled). **Not** `-(pb+pac)`. Clamp ≥ 0.
- **Battery**: `pb` (device=4) — `<0` charging, `>0` discharging; `soc`, `soh`, `vb÷100`.
- **Grid**: from `device=3` meter when `flg==1`; otherwise **unavailable**.
- **House load**: exact only with meter (`PV + pb − grid_export`); otherwise marked **derived/rough** (small noisy difference of large async-sampled values — document the caveat).
- **Energy totals**: `etd`/`eto` (daily/total) and battery in/out counters for kWh-today panels (verify scaling against the app before trusting).
- **Timestamp skew**: device=2 (`tim`) can lag device=4 by 60 s+. Capture both `tim`s; expose a `readingConsistency` flag; recompute load only when reasonably aligned.

### Value objects (per `SWIFT-VALUE-OBJECTS.md`)
`Watts`, `Percent`, `Volts`, `Amps`, `Celsius`, `KilowattHours`, `Host`, `SerialNumber`, `ISODate` — no bare `Int`/`Double`/`String` for domain fields. Direction is an enum (`.charging/.discharging/.idle`, `.import/.export/.idle`), never a sign convention leaked into the UI.

### `InverterReading` (persisted, keyed by `host:sn`)
```
host, serialNumber, model?, firmware?
takenAt: ISODate
pv: Watts
battery: { power: Watts, direction, soc: Percent, soh: Percent, voltage: Volts }
load: { value: Watts, quality: .exact | .derivedRough | .unavailable }
grid: { power: Watts, direction, available: Bool }
inverterAC: Watts
temperature: Celsius?
energyToday: KilowattHours?  energyTotal: KilowattHours?
health: { online: Bool, stale: Bool, errorCode: Int?, gridStatus, meterEnabled: Bool }
```

---

## 6. Persistence (reused infra)

- **Latest reading**: `~/.cache/solplanet-energy-tracker/readings.json` (atomic write + `readings.json.lock` advisory `flock`). One entry per configured inverter.
- **History**: `~/.cache/solplanet-energy-tracker/history/YYYY/MM/YYYY-MM-DD.jsonl`, append-only, one `PowerSnapshot` line **only when values change**. Null out a metric when unavailable (e.g. grid when meter disabled) so charts break the line instead of bridging.
- **Logs**: `app.log`, `solplanet-connector.log`; size rotation 5 MB + 7-day retention purge (reused `LogCleaner`).

`PowerSnapshot` fields: `t, pv, battPower, soc, load, loadQuality, grid, gridAvailable, inverterAC, energyToday`. Keep it flat and numeric for cheap chart reads.

---

## 7. Menu bar configurability (the "info in the menu bar" ask)

Reuse the **chip → segments** model. A chip is a pill; segments live inside it.

### Segment kinds (solar)
Each segment targets one metric and declares visible elements:
- **PV**: ☀ icon + value (`1.4 kW`).
- **SOC**: 🔋 icon + `54%` + optional charge/discharge arrow (`↑/↓`).
- **Battery power**: signed value + direction arrow + tier color.
- **Load**: 🏠 + value (badge "≈" when derived/rough).
- **Grid**: ⚡ + value + import/export arrow (color: export green, import red).

### Per-segment display options
- value unit: `W` vs `kW` (auto-scale ≥ 1 kW), decimals.
- show/hide icon, arrow, label, color dot.
- SOC: show voltage in tooltip.
- separator between segments (reuse `menuBarSeparator`).

### Colors / tiers (`PowerTier`, replaces `ConsumptionTier`)
- **Battery flow**: charging → green scale; discharging → amber→red as load rises.
- **Grid**: import → red, export → green, idle → neutral.
- **SOC**: `<15%` red, `15–40%` orange, `40–80%` blue, `>80%` green.
Expose both `color: Color` (popover) and `nsColor: NSColor` (rasterized label), using system colors for appearance adaptation.

### Seeding (first launch)
Mirror the AI app's "Configure" CTA: on a fresh install with no inverter configured, the label shows **"Configure inverter"**; once a connection tests OK, seed a default segment set: `☀ PV | 🔋 SOC↑↓ | 🏠 Load`.

---

## 8. Popover UI

- **Energy-flow card** (hero): PV → (battery / house / grid) with live arrows and magnitudes; battery ring gauge for SOC; small badges for direction. (A compact textual Sankey; no heavy dependency.)
- **Metric rows**: PV, Battery (power + SOC + V), Load (with quality badge), Grid (with availability), Inverter temp, Energy today.
- **Health banner** at top when offline/stale/error/meter-disabled.
- **Charts tab**: reuse `UsageHistoryChartView`. Default panel "All power" (PV/Battery/Load/Grid on W axis) + a dedicated **SOC %** panel (0–100 axis) + optional **Energy today kWh**. Hover tooltips, window switch (6 h/24 h/7 d/30 d/all), gap-aware line breaks.
- **Footer**: app name, last-updated relative time, Quit, Settings (`Cmd+,`).

---

## 9. Health & status (replaces vendor outages)

Derive an `InverterHealth` instead of fetching a status page:
- **Offline**: last N fetches failed/timed out → banner "Inverter unreachable" + keep last good reading dimmed.
- **Stale**: `takenAt`/`tim` older than `max(3×interval, 60 s)` → "Data stale".
- **Error**: `err != 0` (device=2) or `grid_sts` abnormal → surface code + plain-language hint.
- **Meter disabled**: `device=3 flg==0` → persistent info chip "Grid/Load require the CT meter" (links to enabling it).
These feed the same banner component pattern as the AI app's `VendorStatusBanner`.

---

## 10. Preferences (keys)

`UserDefaults.standard`, prefix `solplanet-tracker.`:
- `connection.inverters` (JSON array of `ConnectionSettings`)
- `refreshIntervalSeconds` (clamped ≥ 5)
- `launchAtLogin`, `logLevel`
- `menuBarSegments`, `menuBarSegmentsInitialized`, `menuBarSeparator`, `menuBarChipBackground`
- `chartConfigurations`, `chartConfigurationsInitialized`
- `notifications.*` (see §11)
- `tariff.*` (see §11)
- `updatesAutoCheckEnabled`, `updatesDismissedVersions`
Env override for logs: `SOLPLANET_TRACKER_LOG_LEVEL`.

---

## 11. Features worth adding (beyond a 1:1 port)

Proposed, ranked by value/effort:

1. **Energy-today / self-sufficiency panel** *(high value, low effort)* — kWh produced/consumed/charged today from `etd`/counters; autoconsumption % = (PV used on-site) / PV. Surfaces the "am I using my solar?" answer.
2. **Notifications** *(high value, med effort)* — local `UserNotifications`:
   - Battery full (SOC ≥ threshold) / low (SOC ≤ threshold).
   - "Exporting to grid" / "Importing while battery available" (efficiency nudge).
   - Inverter offline / error.
   All opt-in with thresholds in a Notifications tab; debounced to avoid spam.
3. **Tariff & savings estimate** *(med value, med effort)* — configurable import/export prices; compute today's € saved/earned from energy counters. Pure display, no control.
4. **Auto-identify inverter via `getdev.cgi`** *(med value, low effort)* — fill SN/model/firmware from IP (already in §4).
5. **Meter-aware adaptive UI** *(med value, low effort)* — automatically switch Load/Grid from "rough/unavailable" to exact when `device=3` becomes enabled; show a one-time tip on how to enable the CT meter.
6. **Daily summary at sunset** *(nice, low effort)* — a notification/log line: peak PV, kWh, % self-sufficient.
7. **CLI parity** *(nice, low effort)* — keep `scripts/battery_status.sh` working and add a `--json` mode reading the same `readings.json` (so the menubar app and the shell tool agree).
8. **Multi-inverter** *(future)* — registry already supports it; UI tabs per inverter + an aggregate chip.
9. **Reduce-motion / accessibility** for the energy-flow animation; **Reduce transparency** handled in rasterizer (inherited).

Mark 1–5 as v1 candidates; 6–9 as backlog.

---

## 12. Engineering rules (copy & obey)

Copy these docs into this repo's `docs/` and treat them as mandatory (same as the reference's `CLAUDE.md` gate):
- `SWIFT-CONCURRENCY.md` — actors for poller/connector/file managers, `NSFormatter` thread-safety, `Process`/`URLSession` timeouts.
- `SWIFT-ERROR-HANDLING.md` — rich error enums; **no silent `try?`**; connector never throws past the boundary (returns reading with `health.errorCode`/offline instead, so last good values persist).
- `SWIFT-IO-ROBUSTNESS.md` — atomic writes, `flock` with timeout, O(n+m) history merges; **add a self-signed-TLS pinning note**.
- `SWIFT-TESTABILITY.md` — constructor injection (`URLSession`/`HTTPClient`, `FileManager`, `Clock`), no force-unwrap, no magic numbers.
- `SWIFT-VALUE-OBJECTS.md` — value objects for every domain field (§5).
- `SWIFT-MENUBAR.md` — the `NSStatusItem` rules (§3).
Add a repo `CLAUDE.md` pointing at these (lazy-loaded), plus a "must not poll faster than 5 s" rule analogous to the AI app's "must not trigger Keychain prompts" rule.

---

## 13. Build, distribution, CI

- Adapt `scripts/build-app-bundle.sh`:
  - `APP_DISPLAY_NAME="Solplanet Energy Tracker"`, `APP_BINARY_NAME="SolplanetEnergyTracker"`.
  - `BUNDLE_ID="io.github.ealliaume.solplanet-energy-tracker"` *(confirm handle — see Open decisions)*.
  - `LSUIElement=true`, `LSMinimumSystemVersion=14.0`, icon from `IconExporter`.
  - Drop the AI-specific `NSAppleEventsUsageDescription`/tester-debug trio unless reused.
  - Add a **local-network usage** note if macOS prompts (LAN access to the dongle).
- `IconExporter` + `AppIconKit`: new sun/battery glyph.
- CI: port `.github/workflows/ci.yml` (build + `swift test` + SwiftLint). Defer release/notarization until distribution is decided.

---

## 14. Testing strategy

- **Fixtures from real captures** (already have them) — drop the actual `device=2/3/4` JSON we recorded into `Tests/.../Fixtures/` (low SOC, high-PV charging, night discharge, meter-disabled, error case). Use them to lock derivations.
- **Derivation tests**: assert `PV=-pac`, clamping, battery direction by `pb` sign, load quality flag transitions, meter-enabled vs disabled paths. Include the **high-PV regression** (the case that disproved `-(pb+pac)`).
- **Conformance test** (port `VendorRegistryConformanceTests`): every reading's metrics are well-typed; `takenAt` parses ISO 8601; branding asset exists; docs pointer resolves.
- **IO/store/watcher tests** reused near-verbatim (atomic write, flock contention, debounce, snapshot-on-change, history gap nulls).
- **Rate-limit guard test**: preferences clamp interval to ≥ 5 s; backoff on repeated timeout.
- **TLS test**: connector trusts only configured host (injected trust evaluator).

---

## 15. Phased roadmap

Legend: ✅ shipped · 🟡 partial · ⬜ not started.

| Milestone | Status | Deliverable | Done when |
|---|---|---|---|
| **M0 — Skeleton** | ✅ | SwiftPM package (lib+app+iconkit+tests), `.accessory` app, empty `NSStatusItem` showing "Configure inverter", SwiftLint + CI green. | App launches in menu bar, no Dock icon. |
| **M1 — Connectivity** | ✅ | `HTTPClient` (self-signed TLS, injectable), `SolplanetConnector` querying device 4/2/3, `ConnectionSettings`, Connection settings tab with Test. *(Detect/`getdev.cgi` auto-identify still TODO.)* | "Test connection" returns a live reading for a configured IP/SN. |
| **M2 — Derivations + model** | ✅ | `InverterReading`, value objects, `PowerDerivations` (PV=-pac etc.), fixtures + derivation tests (incl. high-PV regression). | All derivation tests pass against captured fixtures. |
| **M3 — Persistence + poller** | ✅ | `InverterPoller` (≥5 s floor, backoff), `ReadingsFileManager` (atomic+flock), `SnapshotRecorder`, `ReadingsStore`. *(Poller pushes to the store directly; the JSON file watcher for external readers is deferred.)* | `readings.json` + history JSONL update on a live system; store observes changes. |
| **M4 — Menu bar** | 🟡 | `PowerTier` color logic shipped. Menu bar currently renders plain text `☀ PV  🔋 SOC`; rasterized per-segment colored `NSImage` (`MenuBarLabelRenderer`, `MenuBarSegmentResolver`, seeding) still TODO. | Configurable colored segments render live (PV/SOC/Battery/Load/Grid). |
| **M5 — Popover** | ✅ | Metric rows, health banner, footer. *(Energy-flow hero card + gauges still TODO.)* | Popover shows live data + health states. |
| **M6 — Charts** | ✅ | `HistoryReader`, `ChartSeriesResolver` (gap-aware), `EnergyHistoryChartView` (Swift Charts), metric + window pickers. | Charts render across all time windows with gap-aware lines. |
| **M7 — Settings + lifecycle** | 🟡 | Connection + General settings tabs shipped, preferences take effect live. Launch-at-login, logging+rotation+retention, PID guard, self-update still TODO. | Feature-complete v1; preferences take effect live. |
| **M8 — Added features** | ⬜ | Energy-today/self-sufficiency (in scope); notifications + tariff deferred per §17. | Opt-in features shipping behind settings. |
| **M9 — Build/dist** | 🟡 | `scripts/build-app-bundle.sh` → ad-hoc-signed `dist/Solplanet Battery Energy Tracker.app` with `.icns`, LSUIElement, NSLocalNetworkUsageDescription. README/screenshots + distribution decision still TODO. | `dist/Solplanet Battery Energy Tracker.app` launches; docs updated. |

---

## 16. Risks & mitigations

| Risk | Mitigation |
|---|---|
| **Dongle bricks under fast polling** | Hard 5 s floor (clamped in setter), serialized tick, exponential backoff on errors, documented in CLAUDE.md rule. |
| **Self-signed TLS** | Host-pinned trust override (not global ATS off); `http`/8484 fallback; covered by test. |
| **Derived load/grid inaccuracy** | Mark quality (`exact`/`derivedRough`/`unavailable`); prefer the CT meter when present; never present rough numbers as exact. |
| **device=2 vs device=4 timestamp skew** | Capture both `tim`s; consistency flag; recompute load only when aligned. |
| **Firmware variance across dongles** | API doc is a *dated snapshot*; connector tolerates missing fields; auto-identify records model/firmware. |
| **API drift** | Re-verification discipline (bump "Last verified", changelog) inherited from the vendor-doc workflow. |

---

## 17. Open decisions (need a yes/no before/while building)

1. **GitHub handle / bundle id / distribution** — `io.github.ealliaume.…`? Homebrew cask like the reference, or local build only?
=> defer Homebrew to later on

4. **Multi-inverter in v1 UI**, or single inverter with the list plumbing hidden until later?
=> single inverter for now

3. **Notifications + tariff in v1**, or backlog after the core port?
=> no notification for now

4. **Keep `scripts/battery_status.sh`** as a supported CLI companion (with `--json` reading `readings.json`)?
=> keep the script, but can create any other alternative if easier (I ll use this script for debugging, app can use whatever)

5. **App name** confirmation: "Solplanet Battery Energy Tracker" (display) / `SolplanetBatteryEnergyTracker` (binary).
=> Solplanet Battery Energy Tracker

---

## 18. Immediate next steps

1. ~~Confirm the Open-decisions in §17~~ — done (name, bundle id, single-inverter, no notifications, keep the script).
2. ~~Copy the six Swift quality docs + `SWIFT-MENUBAR.md` into `docs/`, add `CLAUDE.md`~~ — done (incl. self-signed-TLS note + 5 s-floor rule).
3. ~~Scaffold M0~~ — done.
4. ~~Drop the captured device JSON into fixtures and TDD the M2 derivations~~ — done (incl. high-PV regression).

**Next up (remaining work):**
5. M4 — rasterized colored `NSStatusItem` segments per `SWIFT-MENUBAR.md` (replace the plain-text label; add `MenuBarSegmentResolver` + seeding + per-segment options).
6. M7 — launch-at-login, logging (`Logger`/`LoggingProxy`/rotation+retention), PID guard, optional self-update.
7. M8 — energy-today / self-sufficiency panel from `etd` + battery counters.
8. M1 polish — Detect button (`getdev.cgi` auto-identify of SN/model/firmware).
9. M3 polish — `ReadingsFileWatcher` so an external script/widget reads the same `readings.json` under `flock`.
10. M5 polish — energy-flow hero card + SOC ring gauge.
11. M9 — README + screenshots; decide distribution (Homebrew deferred per §17).
