# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Solplanet Battery Energy Tracker** — a menubar-only macOS app that surfaces live
Solplanet/AISWEI inverter telemetry (PV, battery, house load, grid) read from the
**local dongle API**, records history, and renders charts. Read-only by design.

The bootstrap plan lives at `docs/plans/plan_mac_bootstrap.md`. The reverse-engineered
inverter API is documented in `docs/solplanet-api-documentation.md`. Architecture and
tooling are adapted from the "AI Usages Tracker" reference codebase.

## Lazy-loaded context

Detailed guidelines live under `docs/` so this file stays small. Load the file whose
topic matches your task; do not load them preemptively. Notable docs: the bootstrap
plan (`docs/plans/plan_mac_bootstrap.md`), the inverter API snapshot
(`docs/solplanet-api-documentation.md`).

## Swift code quality (mandatory)

When writing or modifying Swift code, you **must** load and follow all six Swift
guideline docs before writing any code:

- `docs/guidelines/swift-concurrency.md` — cooperative thread pool, NSFormatter thread safety, actors, Process/URLSession timeouts
- `docs/guidelines/switch-error-handling.md` — no silent `try?`, no success-after-catch, rich error types
- `docs/guidelines/swift-io.md` — atomic writes, flock with timeout, O(n+m) merges, **self-signed-TLS host pinning**
- `docs/guidelines/swift-testability.md` — dependency injection, test coverage, force-unwrap, comments, magic numbers
- `docs/guidelines/swift-value-objects.md` — value objects for domain fields (Watts, Percent, Volts, Host, SerialNumber, …)
- `docs/guidelines/swift-menubar.md` — menu bar UI: `NSStatusItem` (not `MenuBarExtra`), non-template `NSImage`, appearance detection

## Must not poll the dongle faster than 5 s

Community reports warn the ESP32 dongle can be **bricked for ~10 minutes** by tight
polling. Treat this as a hard invariant analogous to the reference app's "must not
trigger Keychain prompts" rule:

- The refresh-interval preference setter **clamps to a minimum of 5 s** — never trust
  the UI to enforce it.
- The two/three device queries within a tick are **serialized** (no parallel hammering),
  with small spacing.
- On repeated timeouts, **back off exponentially (capped)** instead of retrying tightly.

See `docs/plans/plan_mac_bootstrap.md` §4, §16 and `docs/SWIFT-IO-ROBUSTNESS.md`.

## Build & test

The Swift package lives under `SolplanetEnergyTracker/`.

```sh
cd SolplanetEnergyTracker
swift build
swift test
```

Build a distributable, ad-hoc-signed `.app` (menubar-only, with `.icns`):

```sh
./scripts/build-app-bundle.sh          # → dist/Solplanet Battery Energy Tracker.app
```

To run against a real dongle before configuring it in Settings, set
`SOLPLANET_TRACKER_HOST` and `SOLPLANET_TRACKER_SN` in the environment; the app
seeds the single inverter from them on first launch.
