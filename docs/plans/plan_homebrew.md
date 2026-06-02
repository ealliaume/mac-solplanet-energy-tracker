# Plan — Homebrew delivery + in-app auto-update

> **Status:** partially implemented — created 2026-06-02; impl audited 2026-06-02.
> **What already exists (notify-only update detection):** `SemanticVersion`,
> a check-only `UpdateChecker` (GitHub `releases/latest`), an inline daily poll
> in `AppDelegate` gated on the `updatesAutoCheckEnabled` pref, a "view release"
> banner in `PopoverView`, the Settings auto-check toggle, and tests for the
> version parser + checker. CI (`ci.yml`) already has the Xcode-select +
> SwiftLint-strip steps the release workflow will reuse.
> **What is missing (the actual *auto*-update):** the release pipeline (Track A),
> the Homebrew tap/cask (Track B), and all install machinery — installation
> detection, `brew upgrade` runner, downloader, finalize/swap installer, phase
> machine, and the Install/Restart UX (Track C). Today the app only *links* to
> the GitHub release; it cannot upgrade itself. Done items are marked **✅ Done**
> (or **🟡 Partial**) inline below.
> **Goal:** ship the menu bar app as an updatable binary delivered via Homebrew
> cask, and make the app able to **update itself** (check for new releases, run
> the upgrade, relaunch) without the user touching a terminal.
> **Reference implementation:** the "AI Usages Tracker" codebase at
> `/Users/ealliaume/private/git/mac-ai-trackers` already ships this exact
> system. This plan ports it, renamed for Solplanet. Read those files before
> writing code — they are the source of truth for the actor/error patterns and
> the Swift quality rules in `docs/guidelines/`.

---

## 0. End state (what "done" looks like)

A user installs once:

```sh
brew tap ealliaume/tap
brew install --cask solplanet-energy-tracker
open "/Applications/Solplanet Battery Energy Tracker.app"
```

From then on, **the app updates itself**:

1. ✅ On launch + every 24 h (plan target 6 h), the app polls the GitHub "latest
   release" API. *(Done — inline in `AppDelegate`.)*
2. 🟡 When a newer version exists, the popover shows an "Update available"
   banner. *(Done as a "view release" link — release-notes body + Install
   button still to add.)*
3. ❌ The user clicks **Install**. Because the app detects it was installed via the
   Homebrew cask, it runs `brew upgrade --cask solplanet-energy-tracker`
   in-process, streaming progress into the banner.
4. ❌ The user clicks **Restart**; the app relaunches into the new version.
5. ❌ Manual (non-brew) installs get the same UX via a zip download + staged-swap
   fallback path.

The release side is fully automated: pushing a `vX.Y.Z` git tag builds the
`.app`, publishes a GitHub Release with a zipped bundle + SHA256, and bumps the
cask in the tap repo. No manual artifact handling.

---

## 1. The signing reality (read first — it shapes everything)

The build is **ad-hoc signed only** (`codesign --sign -`), with **no Apple
Developer ID and no notarization** (see `scripts/build-app-bundle.sh`). This is
fine for a self-distributed open-source tool, but it has hard consequences:

- **Homebrew quarantine.** `brew install --cask` applies the
  `com.apple.quarantine` xattr by default. A quarantined, non-notarized app is
  blocked by Gatekeeper on first launch ("can't be opened because Apple cannot
  check it"). Two options:
  - **(a) `no_quarantine` stanza in the cask** — cleanest UX, app opens
    directly. This is a deliberate trust trade-off the user accepts by tapping
    our repo. **Chosen default.**
  - (b) keep quarantine and document the right-click → Open dance. Worse UX;
    only fall back to this if a cask reviewer rejects `no_quarantine` (only
    relevant if we ever submit to `homebrew-cask` proper — we are not; we use
    our own tap, where the stanza is fine).
- **In-app swap must strip quarantine.** The manual-install finalize script
  must run `xattr -dr com.apple.quarantine` on the swapped bundle (the
  reference script already does this).
- **No Sparkle / no notarized delta updates.** We deliberately do **not** use
  Sparkle. Auto-update is "re-run the package manager" (brew) or "download +
  swap the whole bundle" (manual) — both already proven in the reference app.
- **Version source of truth = the git tag.** `BUNDLE_VERSION` is injected into
  `Info.plist` at build time from the tag (`CFBundleShortVersionString`). The
  app reads its own version from the bundle and compares against the GitHub
  release tag.

> If a Developer ID + notarization is added later, the only changes are: drop
> `no_quarantine` from the cask and add a notarize/staple step to the release
> workflow. The auto-update architecture is unaffected.

---

## 2. Pieces to build (and where each lives)

Three independent tracks. Track A (release pipeline) and Track B (tap) can land
first and are independently useful — they give `brew install` + manual
`brew upgrade`. Track C (in-app updater) is what makes it *auto*-update.

| Track | What | Repo / location | Status |
|---|---|---|---|
| **A. Release pipeline** | Tag → build → GitHub Release with zip + sha256 | this repo: `.github/workflows/release.yml` | ❌ Not started (CI building blocks reusable) |
| **B. Homebrew tap** | A cask that points at the latest release asset | new repo: `ealliaume/homebrew-tap` | ❌ Not started |
| **C. In-app updater** | Check / detect-install / brew-upgrade / download+swap / banner UI | this repo: `Sources/.../Updates/` + App views | 🟡 Partial — *check + notify* done; *install* missing |

---

## 3. Track A — Release pipeline (`.github/workflows/release.yml`)

**Status: ❌ Not started.** No `release.yml` exists yet — only `ci.yml`. But
`ci.yml` already contains the two non-obvious steps the release job reuses
verbatim: the **Select Xcode 26** step and the **Strip SwiftLint plugin for CI
build** Python patch. Copy those across; the rest below is new.

Port the reference workflow (`mac-ai-trackers/.github/workflows/release.yml`),
adapting names. Trigger on `push` of tags matching `v*.*.*`.

**Job `release` (runs on `macos-15`):**

1. Checkout.
2. Select a recent Xcode (Swift 6 toolchain — the package is
   `swift-tools-version:6.0`, `platforms: [.macOS(.v14)]`). Match whatever the
   local dev toolchain is; pin explicitly so CI is reproducible.
3. Extract version from tag: `VERSION=${TAG#v}`.
4. **Strip the SwiftLint build-tool plugin from `Package.swift` for CI** — the
   reference notes `SwiftLintPlugins` fails on runners with "prebuild command
   cannot use executables built from source". Lint is a PR concern, not a
   release concern. Reuse the reference's Python regex patch.
5. Run `BUNDLE_VERSION=$VERSION ./scripts/build-app-bundle.sh`. The existing
   script already reads `BUNDLE_VERSION` and writes it into both Info.plists.
6. Create the artifact with **`ditto -c -k --keepParent`** (preserves the
   bundle structure + the ad-hoc signature; `zip` does not):
   ```sh
   cd dist
   ditto -c -k --keepParent "Solplanet Battery Energy Tracker.app" "Solplanet-Energy-Tracker.zip"
   shasum -a 256 "Solplanet-Energy-Tracker.zip" > "Solplanet-Energy-Tracker.zip.sha256"
   ```
7. Publish the GitHub Release (`softprops/action-gh-release@v2`,
   `generate_release_notes: true`) attaching the `.zip` and `.zip.sha256`.
8. Expose `version` and `sha256` as job outputs for the tap-bump job.

**Job `update-tap` (runs on `ubuntu-latest`, `needs: release`):**

1. Checkout `ealliaume/homebrew-tap` using a PAT secret `HOMEBREW_TAP_TOKEN`
   (needs `contents:write` on the tap repo).
2. `sed` the `version` and `sha256` fields in `Casks/solplanet-energy-tracker.rb`.
3. Verify the substitutions took, commit, push.

**Decisions / notes:**
- Asset name `Solplanet-Energy-Tracker.zip` is the contract between the release,
  the cask (`url`), and the in-app `UpdateChecker.downloadAssetName`. Keep all
  three in sync.
- The release summary step should print the "ad-hoc signed, no notarization"
  warning so it's visible in logs.
- The version-tag scheme: `v0.1.0`, `v0.2.0`, … . The app's `AppVersion` parser
  must accept the bundle's `CFBundleShortVersionString` and the tag's stripped
  form identically.

---

## 4. Track B — Homebrew tap (`ealliaume/homebrew-tap`)

**Status: ❌ Not started.** No tap repo / cask exists yet.

Create a public repo `ealliaume/homebrew-tap` (Homebrew maps `brew tap
ealliaume/tap` → `github.com/ealliaume/homebrew-tap`). Add
`Casks/solplanet-energy-tracker.rb`:

```ruby
cask "solplanet-energy-tracker" do
  version "0.1.0"
  sha256 "<filled by release workflow>"

  url "https://github.com/ealliaume/mac-solplanet-energy-tracker/releases/download/v#{version}/Solplanet-Energy-Tracker.zip"
  name "Solplanet Battery Energy Tracker"
  desc "Menu bar app for live Solplanet/AISWEI inverter telemetry"
  homepage "https://github.com/ealliaume/mac-solplanet-energy-tracker"

  # Ad-hoc signed, not notarized: skip Gatekeeper quarantine so first launch
  # works without the right-click->Open dance. Users opt into this trust by
  # tapping this third-party repo.
  auto_updates false
  depends_on macos: ">= :sonoma"   # LSMinimumSystemVersion 14.0

  app "Solplanet Battery Energy Tracker.app"

  zap trash: [
    "~/Library/Application Support/SolplanetEnergyTracker",   # confirm actual path
    "~/Library/Preferences/io.github.ealliaume.solplanet-energy-tracker.plist",
    "~/.cache/solplanet-energy-tracker",
  ]
end
```

**To get `no_quarantine` behavior:** add `no_quarantine` — wait, that is not a
real stanza. The correct mechanism for a custom tap is the cask's
`postflight`/`uninstall` is *not* needed; instead Homebrew honors
`HOMEBREW_CASK_OPTS="--no-quarantine"` per-install, **but** to make it the
default for our cask we rely on users installing with `--no-quarantine`, OR we
strip quarantine ourselves. **Decision:** document `brew install --cask
--no-quarantine solplanet-energy-tracker` in the README *and* have the app strip
quarantine on every launch defensively (one `xattr -dr com.apple.quarantine` of
its own bundle at startup, best-effort). This guarantees first-launch works
regardless of how the user installed. Validate this against current Homebrew
behavior during implementation (Homebrew has changed quarantine handling
before).

**Verify before shipping:**
- `brew install --cask --no-quarantine solplanet-energy-tracker` then `open` →
  app launches with no Gatekeeper prompt.
- `brew upgrade --cask solplanet-energy-tracker` swaps a running app cleanly
  (the running mach-o is mmapped; on-disk swap is safe — confirmed by the
  reference `BrewUpgradeRunner` doc comment).
- The cask's `zap` paths match the app's real Application Support / cache /
  prefs locations (grep the codebase to confirm before filling them in).

---

## 5. Track C — In-app updater (the "auto" part)

Port the reference `Updates/` module wholesale. Files (under
`SolplanetEnergyTracker/Sources/SolplanetEnergyTracker/Updates/`):

| File | Role | Status |
|---|---|---|
| `SemanticVersion.swift` (reference `AppVersion.swift`) | semantic version parse/compare | ✅ **Done** — exists with `v`-prefix + pre-release handling; covered by `SemanticVersionTests` |
| `UpdateChecker.swift` | GET GitHub `releases/latest`, compare tag | 🟡 **Partial** — *check-only* done (injected `HTTPClient`, owner/repo from `AppInfo`, returns `.upToDate`/`.updateAvailable`, covered by `UpdateCheckerTests`). **Missing:** building a rich `AvailableUpdate` with the `.zip` + `.sha256` download asset URLs that the manual install path needs |
| `InstallationDetector.swift` | brew-cask vs manual; resolve `brew` path | ❌ **Not started** — `homebrewCaskName` → `solplanet-energy-tracker`; bundle paths → `Solplanet Battery Energy Tracker.app` (global `/Applications` + `~/Applications`) |
| `BrewUpgradeRunner.swift` | stream `brew update` + `brew upgrade --cask` | ❌ **Not started** (cask name passed in) |
| `UpdateDownloader.swift` | manual path: download zip, verify sha256, `ditto -x` unzip to staging | ❌ **Not started** |
| `UpdateInstaller.swift` | build finalize scripts (manual swap / brew relaunch); waits for parent PID, strips quarantine, relaunches as console user | ❌ **Not started** — use cache dir `~/.cache/solplanet-energy-tracker/updates` |
| `UpdateScheduler.swift` | poll on launch then on an interval; de-dupe notifications | 🟡 **Partial** — an *inline* loop lives in `AppDelegate.startUpdateChecks()` (check-now + every **24 h**, gated on the auto-check pref). Not yet extracted to a dedicated actor; interval differs from the reference's 6 h. Extract + de-dupe when porting the rest |
| `UpdateState.swift` | `@MainActor @Observable` phase machine for the UI | ❌ **Not started** — today only a flat `store.availableUpdate` holder exists; no download/verify/extract/brew/restart phases |

**UI (under `Sources/App/Views/`):** 🟡 **Partial.** `PopoverView` already renders
a banner, but it is a "view release" `Link` to the GitHub page — no Install /
Restart buttons, no streamed progress. `SettingsView` already has the auto-check
toggle. **Still to port:** `UpdateAvailableBanner` (Install/Restart + progress),
`ReleaseNotesSheet`, and the richer `Settings/UpdatesSettingsView` ("Check now",
current/latest version, skip-version).

**AppDelegate wiring:** 🟡 **Partial.** It instantiates `UpdateChecker` and runs
the poll loop today. **Still to do:** instantiate `InstallationDetector` +
`UpdateScheduler` (extracted) + `UpdateState`, route an `onUpdateAvailable`
callback into the banner, and add the `dismissedVersions` skip-list to
preferences.

**The two install flows:**

- **Homebrew cask** (`InstallationKind.homebrewCask`): click Install →
  `BrewUpgradeRunner.runUpgrade` streams `brew upgrade --cask` lines into the
  banner → on success `UpdateInstaller.buildHomebrewFinalizationPlan` (relaunch
  only, brew already swapped the bundle) → click Restart → detached script
  waits for quit, relaunches.
- **Manual** (`InstallationKind.manual`): click Install →
  `UpdateDownloader` downloads the release zip, verifies SHA256 against the
  `.sha256` asset, `ditto -x` extracts to staging →
  `UpdateInstaller.buildManualFinalizationPlan` (move staged `.app` over the
  running bundle, strip quarantine, relaunch; elevate via `osascript` only when
  the bundle dir is not user-writable, e.g. `/Applications` owned by root).

**Swift quality (mandatory — per CLAUDE.md):** before writing any of this, load
all six `docs/guidelines/swift-*.md`. The reference code already conforms
(actors for IO/network, `URLSession`/`Process` timeouts, atomic script writes
with `0o755`, no silent `try?`, rich error enums, value object `AppVersion`).
Preserve those properties; do not regress them when renaming.

---

## 6. Sequencing / milestones

| # | Milestone | Outcome | Depends on | Status |
|---|---|---|---|---|
| H0 | Decide cask name, asset name, tap repo name; confirm app's support/cache/prefs paths | naming contract fixed | — | 🟡 Partial — names proposed here; owner/repo wired in `AppInfo`; on-disk paths still to confirm |
| H1 | Track A release workflow + first `v0.1.0` tag | GitHub Release with zip+sha256 exists | H0 | ❌ Not started |
| H2 | Track B tap repo + cask; `HOMEBREW_TAP_TOKEN` secret; wire `update-tap` job | `brew install --cask` works end to end | H1 | ❌ Not started |
| H3 | Manual `brew upgrade --cask` verified to swap a running app | upgrade path proven by hand | H2 | ❌ Not started |
| H4 | Port `Updates/` core (checker, detector, version) + tests | app *detects* updates, logs them | H1 | 🟡 Partial — version + check-only checker + tests + poll loop done; **detector + rich `AvailableUpdate` assets** missing |
| H5 | Port brew-upgrade + finalize + downloader/installer | app *performs* updates (both flows) | H4, H3 | ❌ Not started |
| H6 | Port banner + settings UI; wire AppDelegate + scheduler | full auto-update UX in the menu bar | H5 | 🟡 Partial — notify banner + auto-check toggle done; Install/Restart/progress, release-notes sheet, scheduler extraction, `UpdateState` missing |
| H7 | End-to-end: install v0.1.0 via brew, tag v0.2.0, watch the app self-update | **goal met** | H6 | ❌ Not started |

"End of the day" minimum to claim auto-update: **H1–H2 + H4–H6**, validated by
H7. H3 is a manual sanity gate that de-risks H5.

---

## 7. Testing

Mirror the reference test suite
(`mac-ai-trackers/.../Tests/.../UpdatesTests.swift`):

- ✅ **Done** — `SemanticVersion` parse/compare edge cases (leading `v`,
  pre-release, equal) in `SemanticVersionTests` (`LifecycleTests.swift`).
- 🟡 **Partial** — `UpdateChecker` against a `FixedHTTPClient` (newer →
  `.updateAvailable`; equal → `.upToDate`) in `UpdateCheckerTests`. Extend for
  the rich-asset variant once the download path lands: missing asset → error;
  HTTP non-200 → error (error cases already modeled in `UpdateCheckError`).
- `InstallationDetector` with a fake `ProcessRunning` (brew found/not-found,
  caskroom present/absent, bundle path match/mismatch).
- `UpdateInstaller` script generation: correct paths, shell-quoting,
  quarantine-strip line present, `0o755`, admin-required when dir not writable.
- `BrewUpgradeRunner` line collection (chunk boundaries, trailing partial line,
  non-zero exit → throw).

Manual gates: H3 (running-app swap), H7 (true end-to-end self-update). Both
honor the dongle 5 s floor invariant — irrelevant here but don't let the
updater's network polling touch the inverter code paths.

---

## 8. Secrets & one-time setup (human steps)

1. Create public repo `ealliaume/homebrew-tap` with `Casks/solplanet-energy-tracker.rb`.
2. Create a PAT (fine-grained, `contents:write` on the tap repo) and add it to
   **this** repo's Actions secrets as `HOMEBREW_TAP_TOKEN`.
3. First release is bootstrapped by hand-filling the cask `sha256` once (or let
   the `update-tap` job do it on the first tag).
4. Update `README.md` with the install + auto-update instructions and the
   ad-hoc-signing / `--no-quarantine` note.

---

## 9. Open questions to resolve during H0

- Exact on-disk paths for Application Support / preferences / cache (drives the
  cask `zap` block and the updater cache dir). Grep before filling.
- Whether to default-strip quarantine in-app at launch (defensive) vs. rely on
  `--no-quarantine` at install time. Recommendation: do both.
- Minimum macOS for `depends_on macos:` — `Info.plist` says 14.0 (Sonoma);
  keep consistent.
- Do we want a "skip this version" persisted list from day one? Reference has
  it; cheap to port; recommend yes.
