# Plan — Homebrew delivery + in-app auto-update

> **Status:** code-complete — created 2026-06-02; implemented 2026-06-02.
> **What is now in place:** the release pipeline (`.github/workflows/release.yml`,
> `scripts/publish-release.sh`, `docs/how-to/how-to-release.md` — Track A); the
> cask source (`homebrew/Casks/solplanet-energy-tracker.rb` — Track B); and the
> full in-app updater (Track C): rich `UpdateChecker` with `.zip`/`.sha256`
> assets, `InstallationDetector`, `BrewUpgradeRunner`, `UpdateDownloader`,
> `UpdateInstaller`, `UpdateState` phase machine, `UpdateScheduler`, the
> `UpdateAvailableBanner` + `ReleaseNotesSheet` + `UpdatesSettingsView` UI, the
> AppDelegate install/restart/skip/later wiring, a defensive launch-time
> quarantine strip, and tests (`UpdatesTests.swift`). `swift build` + `swift test`
> green (91 tests).
> **What remains (human / runtime-only steps, not code):** create the public
> `ealliaume/homebrew-tap` repo and add the cask file there; add the
> `HOMEBREW_TAP_TOKEN` Actions secret (§8); push the first `v0.1.0` tag; and run
> the manual end-to-end gates H3 + H7 against a real brew install. Done items are
> marked **✅ Done** (or **🟡 Partial**) inline below.
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
| **A. Release pipeline** | Tag → build → GitHub Release with zip + sha256 | this repo: `.github/workflows/release.yml` | ✅ Done (`release.yml` + `publish-release.sh` + how-to) |
| **B. Homebrew tap** | A cask that points at the latest release asset | new repo: `ealliaume/homebrew-tap` | 🟡 Cask source written (`homebrew/Casks/...rb`); tap repo + secret are human steps (§8) |
| **C. In-app updater** | Check / detect-install / brew-upgrade / download+swap / banner UI | this repo: `Sources/.../Updates/` + App views | ✅ Done (all actors + UI + wiring + tests) |

---

## 3. Track A — Release pipeline (`.github/workflows/release.yml`)

**Status: ✅ Done.** `.github/workflows/release.yml` exists with both the
`release` (build → `ditto` zip + sha256 → GitHub Release, version/sha256 job
outputs) and `update-tap` jobs, reusing the Xcode-select + SwiftLint-strip steps
from `ci.yml`. Original notes below.

The rest of this section is the original design (now implemented). No `release.yml` existed — only `ci.yml`. But
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

### 3.1. Release-publishing script (`scripts/publish-release.sh`)

**Status: ✅ Done.** `scripts/publish-release.sh` exists: it gates (on `main`,
clean tree, `origin` reachable, `gh` authed), validates SemVer + refuses an
existing/non-monotonic tag, runs an optional local build + `swift test`
(`--skip-build`), confirms before the push (`--yes`), then tags + pushes to
trigger `release.yml`. Accepts an explicit version or a `patch|minor|major`
bump. The workflow above fires on a pushed `vX.Y.Z` tag.
The whole point of a script is to make cutting a release one safe command
instead of a hand-typed `git tag && git push`, where a typo'd or duplicate tag
quietly ships the wrong version. Add `scripts/publish-release.sh` (naming follows
the existing `03_github.sh` / `build-app-bundle.sh` convention).

**Usage:** `./scripts/publish-release.sh <version>` (e.g. `0.2.0`, or accept a
bump keyword `patch|minor|major` and compute the next version from the latest
tag).

**Responsibilities (fail-fast, `set -euo pipefail`):**
1. **Preconditions:** on `main`, working tree clean, `origin` reachable, `gh`
   authenticated (reuse the checks already in `03_github.sh`).
2. **Validate version:** must be SemVer; the `v$VERSION` tag must not already
   exist locally or on the remote (`git ls-remote --tags`). Refuse to overwrite.
3. **Monotonic check:** new version must be strictly greater than the latest
   existing tag (parse with the same rules as `SemanticVersion`) — guards
   against accidental downgrades the in-app checker would then ignore.
4. **Local sanity build (optional, `--skip-build` to bypass):** run
   `BUNDLE_VERSION=$VERSION ./scripts/build-app-bundle.sh` and `swift test` so a
   broken build is caught before the tag is public, not in CI after.
5. **Tag + push:** `git tag -a "v$VERSION" -m "Release v$VERSION"` then
   `git push origin "v$VERSION"`. This push is what triggers Track A's
   `release.yml`.
6. **Confirm before push** (the tag push is the irreversible, outward-facing
   step): print the version, the target tag, and the commit it points at, and
   require explicit confirmation unless `--yes` is passed.
7. **Follow-up:** print the Actions run URL (`gh run watch` / `gh release view`)
   so the user can watch the build → release → tap-bump chain.

**Notes:**
- The script does **not** build/upload artifacts itself — that is CI's job
  (keeps signing + release creation in one reproducible place). The script only
  gates and triggers.
- Keep version as the single source of truth: the tag drives `BUNDLE_VERSION`
  drives `Info.plist`. The script must not write a version into any committed
  file, to avoid drift.
- Document it in `README.md` and reference it from §8.

### 3.2. Release how-to doc (`docs/how-to/how-to-release.md`)

**Status: ✅ Done.** `docs/how-to/how-to-release.md` documents both Path A
(automatic via `publish-release.sh` → CI) and Path B (manual local commands),
plus the signing/`--no-quarantine` caveat, prerequisites, and the rollback rule.
A short operator runbook so cutting a release does
not depend on tribal memory. Create `docs/how-to/how-to-release.md` (new
`docs/how-to/` directory). It documents **two paths to the same outcome** — both
must produce a GitHub Release carrying `Solplanet-Energy-Tracker.zip` +
`.sha256` and bump the tap cask:

**Path A — Automatic (CI, the normal path).**
1. Bump considerations: pick the next SemVer; nothing to edit by hand (version
   comes from the tag).
2. Run `./scripts/publish-release.sh <version>` (§3.1) — gates, tags, pushes.
3. The pushed `vX.Y.Z` tag triggers `.github/workflows/release.yml` (§3): build →
   `ditto` zip + sha256 → GitHub Release → `update-tap` bumps the cask.
4. Verify: `gh release view vX.Y.Z`, confirm both assets attached, confirm the
   tap commit landed, then `brew update && brew upgrade --cask solplanet-energy-tracker`.

**Path B — Manual (local fallback, when CI is unavailable / broken).** The exact
commands the CI runs, done by hand on a Mac:
1. Clean tree on `main`; choose `VERSION`.
2. `BUNDLE_VERSION=$VERSION ./scripts/build-app-bundle.sh` → `dist/...app`.
3. `cd dist && ditto -c -k --keepParent "Solplanet Battery Energy Tracker.app" "Solplanet-Energy-Tracker.zip"`
   then `shasum -a 256 ... > Solplanet-Energy-Tracker.zip.sha256`.
4. `git tag -a v$VERSION -m "Release v$VERSION" && git push origin v$VERSION`.
5. `gh release create v$VERSION --generate-notes dist/Solplanet-Energy-Tracker.zip dist/Solplanet-Energy-Tracker.zip.sha256`.
6. **Tap bump by hand:** edit `Casks/solplanet-energy-tracker.rb` in
   `ealliaume/homebrew-tap` — set `version` + the new `sha256` — commit, push.
7. Same verification as Path A step 4.

**Doc must also cover:**
- The ad-hoc-signing / `no_quarantine` caveat and why first launch is safe.
- Prerequisites: `gh` authenticated, push rights, the recent Xcode toolchain,
  the `HOMEBREW_TAP_TOKEN` secret (CI) vs. tap push rights (manual).
- Rollback: tags/releases are effectively immutable to consumers — to undo, ship
  a higher patch version; do not delete/re-push a tag that users may have pulled.
- A pointer back to this plan (§3, §3.1, §4) for the underlying machinery.

---

## 4. Track B — Homebrew tap (`ealliaume/homebrew-tap`)

**Status: 🟡 Cask source written; tap repo + secret remain (human steps §8).**
The cask is committed at `homebrew/Casks/solplanet-energy-tracker.rb` (the
canonical source to copy into the tap). `zap` paths were confirmed against the
codebase: only `~/.cache/solplanet-energy-tracker` and the prefs plist
`io.github.ealliaume.solplanet-energy-tracker` are used (no Application Support).
Defensive launch-time quarantine strip is implemented in `AppDelegate`
(`stripOwnQuarantineIfNeeded`). Remaining: create the public repo + add
`HOMEBREW_TAP_TOKEN`.

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
| `SemanticVersion.swift` (reference `AppVersion.swift`) | semantic version parse/compare | ✅ **Done** — `v`-prefix + pre-release handling; added `rawValue` + `init(string:)`; covered by `SemanticVersionTests` |
| `UpdateChecker.swift` | GET GitHub `releases/latest`, compare tag | ✅ **Done** — keeps the notify-only `check()` and adds `checkForUpdate(currentVersion:)` returning a rich `AvailableUpdate` (`.zip` + `.sha256` asset URLs, `publishedAt`, release notes) via the injected `HTTPClient`. Covered by `UpdateCheckerRichTests` |
| `InstallationDetector.swift` | brew-cask vs manual; resolve `brew` path | ✅ **Done** — `homebrewCaskName` → `solplanet-energy-tracker`; bundle paths → `Solplanet Battery Energy Tracker.app` (global + `~/Applications`); login-shell brew discovery. Covered by `InstallationDetectorTests` |
| `BrewUpgradeRunner.swift` | stream `brew update` + `brew upgrade --cask` | ✅ **Done** — line-buffered streaming, non-zero → throws. Covered by `BrewUpgradeRunnerTests` |
| `UpdateDownloader.swift` | manual path: download zip, verify sha256, `ditto -x` unzip to staging | ✅ **Done** — progress callbacks, SHA256 verify, `ditto` extract to staging |
| `UpdateInstaller.swift` | build finalize scripts (manual swap / brew relaunch); waits for parent PID, strips quarantine, relaunches as console user | ✅ **Done** — cache dir `~/.cache/solplanet-energy-tracker/updates`, `0o755`, quarantine-strip line, admin-when-not-writable. Covered by `UpdateInstallerTests` |
| `UpdateScheduler.swift` | poll on launch then on an interval; de-dupe notifications | ✅ **Done** — dedicated actor, initial check + every **6 h**, gated on the auto-check pref, de-dupes the proactive notification |
| `UpdateState.swift` | `@MainActor @Observable` phase machine for the UI | ✅ **Done** — idle/checking/preparing/downloading/verifying/extracting/runningHomebrew/readyToRestart/restarting/failed + skip list |

**UI (under `Sources/App/Views/`):** ✅ **Done.** `UpdateAvailableBanner`
(Install/Restart + streamed progress + skip/later), `ReleaseNotesSheet` +
`ReleaseNotesMarkdownView`, and `UpdatesSettingsView` (current version + install
type, auto-check toggle, "Check now" + last-checked, inline install/restart,
skip-version list) all exist. `PopoverView` now renders `UpdateAvailableBanner`
driven by `UpdateState.pendingUpdate`; `SettingsView` gained an Updates tab.

**AppDelegate wiring:** ✅ **Done.** `setupUpdateScheduler()` instantiates the
`InstallationDetector`, `UpdateInstaller`, `UpdateDownloader`, `BrewUpgradeRunner`,
and `UpdateScheduler`, seeds `UpdateState.dismissedVersions` from prefs, exposes
the `shared*` accessors Settings reads, and routes `onUpdateAvailable` into an
NSAlert. `triggerUpdateInstall` / `triggerRestart` / `skipCurrentUpdate` /
`laterUpdate` are implemented (with admin-elevation + install-directory prompts),
and `updatesDismissedVersions` was added to `AppPreferences`.

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
| H0 | Decide cask name, asset name, tap repo name; confirm app's support/cache/prefs paths | naming contract fixed | — | ✅ Done — names fixed; asset `Solplanet-Energy-Tracker.zip`; on-disk paths confirmed (`~/.cache/solplanet-energy-tracker` + prefs plist only) |
| H1 | Track A release workflow + first `v0.1.0` tag | GitHub Release with zip+sha256 exists | H0 | 🟡 Workflow done; first tag push is a human step |
| H1b | `scripts/publish-release.sh` — gate + tag + push to trigger H1 (§3.1) | one-command, typo-safe releases | H1 | ✅ Done |
| H1c | `docs/how-to/how-to-release.md` — automatic (CI) + manual (local) runbook (§3.2) | release process documented, repeatable | H1, H2 | ✅ Done |
| H2 | Track B tap repo + cask; `HOMEBREW_TAP_TOKEN` secret; wire `update-tap` job | `brew install --cask` works end to end | H1 | 🟡 Cask source + `update-tap` job done; tap repo + secret are human steps (§8) |
| H3 | Manual `brew upgrade --cask` verified to swap a running app | upgrade path proven by hand | H2 | ❌ Not started — manual runtime gate (needs H2) |
| H4 | Port `Updates/` core (checker, detector, version) + tests | app *detects* updates, logs them | H1 | ✅ Done — version + rich checker + detector + tests |
| H5 | Port brew-upgrade + finalize + downloader/installer | app *performs* updates (both flows) | H4, H3 | ✅ Done (code); H3 runtime gate still pending |
| H6 | Port banner + settings UI; wire AppDelegate + scheduler | full auto-update UX in the menu bar | H5 | ✅ Done |
| H7 | End-to-end: install v0.1.0 via brew, tag v0.2.0, watch the app self-update | **goal met** | H6 | ❌ Not started — end-to-end runtime gate (needs H2) |

"End of the day" minimum to claim auto-update: **H1–H2 + H4–H6**, validated by
H7. H3 is a manual sanity gate that de-risks H5.

---

## 7. Testing

Mirror the reference test suite
(`mac-ai-trackers/.../Tests/.../UpdatesTests.swift`):

- ✅ **Done** — `SemanticVersion` parse/compare edge cases (leading `v`,
  pre-release, equal) in `SemanticVersionTests` (`LifecycleTests.swift`).
- ✅ **Done** — `UpdateChecker`: notify-only `check()` in `UpdateCheckerTests`,
  plus the rich `checkForUpdate()` in `UpdateCheckerRichTests` (newer → rich
  update with `.zip`/`.sha256`/notes; equal → no update; missing asset → error;
  HTTP non-200 → error).
- ✅ **Done** — `InstallationDetector` with a fake `ProcessRunning`
  (`InstallationDetectorTests`): brew not found → manual; brew binary resolution;
  empty caskroom → manual.
- ✅ **Done** — `UpdateInstaller` script generation (`UpdateInstallerTests`):
  correct paths, quarantine-strip line present, `0o755`, brew plan is
  relaunch-only, `canReplaceBundle` reflects writability (admin-when-not).
- ✅ **Done** — `BrewUpgradeRunner` line collection + non-zero exit → throw with
  last line (`BrewUpgradeRunnerTests`, via a temp fake-brew executable).

Manual gates: H3 (running-app swap), H7 (true end-to-end self-update). Both
honor the dongle 5 s floor invariant — irrelevant here but don't let the
updater's network polling touch the inverter code paths.

---

## 8. Secrets & one-time setup (human steps — still TODO)

1. ⬜ Create public repo `ealliaume/homebrew-tap` and copy
   `homebrew/Casks/solplanet-energy-tracker.rb` (from this repo) to
   `Casks/solplanet-energy-tracker.rb` there.
2. ⬜ Create a PAT (fine-grained, `contents:write` on the tap repo) and add it to
   **this** repo's Actions secrets as `HOMEBREW_TAP_TOKEN`.
3. ⬜ First release is bootstrapped by hand-filling the cask `sha256` once (or let
   the `update-tap` job do it on the first tag).
4. ✅ `README.md` updated with the install + auto-update instructions and the
   ad-hoc-signing / `--no-quarantine` note.

---

## 9. Open questions — resolved during H0

- ✅ On-disk paths: only `~/.cache/solplanet-energy-tracker` (cache + updater
  staging under `.../updates`) and the prefs plist
  `io.github.ealliaume.solplanet-energy-tracker` are used — no Application
  Support. Cask `zap` filled accordingly.
- ✅ Default-strip quarantine in-app at launch **and** document `--no-quarantine`
  — both implemented (`AppDelegate.stripOwnQuarantineIfNeeded` + README).
- ✅ `depends_on macos: ">= :sonoma"` matches `Info.plist` `LSMinimumSystemVersion 14.0`.
- ✅ "Skip this version" persisted list shipped from day one
  (`AppPreferences.updatesDismissedVersions` + `UpdateState.dismissedVersions`).
