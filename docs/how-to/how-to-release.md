# How to cut a release

Operator runbook for shipping a new version of **Solplanet Battery Energy
Tracker**. Two paths reach the same outcome — a GitHub Release carrying
`Solplanet-Energy-Tracker.zip` + `Solplanet-Energy-Tracker.zip.sha256`, and a
bumped Homebrew cask in `ealliaume/homebrew-tap`. Underlying machinery:
[plan §3 / §3.1 / §4](../plans/plan_homebrew.md).

The **git tag is the single source of truth**: `vX.Y.Z` → `BUNDLE_VERSION` →
`Info.plist` (`CFBundleShortVersionString`). Nothing is hand-edited to set a
version.

## Prerequisites

- `gh` authenticated (`gh auth status`) with push rights on this repo.
- A recent Xcode (Swift 6 toolchain; the package is `swift-tools-version:6.0`,
  `platforms: [.macOS(.v14)]`). CI pins Xcode 26.
- **Automatic path:** the `HOMEBREW_TAP_TOKEN` Actions secret (a fine-grained
  PAT with `contents:write` on `ealliaume/homebrew-tap`) — see plan §8.
- **Manual path:** local push rights on `ealliaume/homebrew-tap`.

## Path A — Automatic (CI, the normal path)

1. Pick the next SemVer. Nothing to edit by hand.
2. Run the gate + tag + push:
   ```sh
   ./scripts/publish-release.sh <version>     # e.g. 0.2.0
   # or bump from the latest tag:
   ./scripts/publish-release.sh patch|minor|major
   ```
   It refuses unless you are on a clean `main`, the tag is new, and the version
   is strictly greater than the latest tag. It runs a local sanity build +
   `swift test` (skip with `--skip-build`), then prompts before the push
   (`--yes` to skip the prompt).
3. The pushed `vX.Y.Z` tag triggers `.github/workflows/release.yml`: build →
   `ditto -c -k --keepParent` zip + `shasum` → GitHub Release
   (`generate_release_notes`) → the `update-tap` job rewrites `version` +
   `sha256` in `Casks/solplanet-energy-tracker.rb`.
4. Verify:
   ```sh
   gh release view vX.Y.Z          # both assets attached?
   # confirm the tap commit landed in ealliaume/homebrew-tap, then:
   brew update && brew upgrade --cask solplanet-energy-tracker
   ```

## Path B — Manual (local fallback, when CI is unavailable)

The exact commands CI runs, by hand on a Mac:

1. Clean tree on `main`; choose `VERSION` (e.g. `0.2.0`).
2. Build the bundle:
   ```sh
   BUNDLE_VERSION=$VERSION ./scripts/build-app-bundle.sh    # → dist/...app
   ```
3. Zip + checksum (note: `ditto`, **not** `zip` — it preserves the bundle
   structure and the ad-hoc signature):
   ```sh
   cd dist
   ditto -c -k --keepParent "Solplanet Battery Energy Tracker.app" "Solplanet-Energy-Tracker.zip"
   shasum -a 256 "Solplanet-Energy-Tracker.zip" > "Solplanet-Energy-Tracker.zip.sha256"
   cd ..
   ```
4. Tag + push:
   ```sh
   git tag -a v$VERSION -m "Release v$VERSION" && git push origin v$VERSION
   ```
5. Create the release with both assets:
   ```sh
   gh release create v$VERSION --generate-notes \
     dist/Solplanet-Energy-Tracker.zip dist/Solplanet-Energy-Tracker.zip.sha256
   ```
6. Bump the cask by hand in `ealliaume/homebrew-tap` —
   `Casks/solplanet-energy-tracker.rb`: set `version` and the new `sha256`
   (from step 3's `.sha256` file), commit, push.
7. Verify as in Path A step 4.

## Signing / first-launch caveat

Builds are **ad-hoc signed, not notarized** (`codesign --sign -`). First launch
is made safe two ways (plan §1):

- Install with `brew install --cask --no-quarantine solplanet-energy-tracker`.
- The app also strips its own `com.apple.quarantine` xattr at launch as a
  defensive fallback, so first launch works regardless of how it was installed.

If a Developer ID + notarization is added later, the only changes are dropping
the `--no-quarantine` guidance and adding a notarize/staple step to
`release.yml`. The auto-update architecture is unaffected.

## Rollback

Tags and releases are effectively immutable to consumers. **To undo a bad
release, ship a higher patch version** — do not delete or re-push a tag users
may have already pulled (the in-app checker would ignore a re-used tag, and brew
caches the asset by URL).
