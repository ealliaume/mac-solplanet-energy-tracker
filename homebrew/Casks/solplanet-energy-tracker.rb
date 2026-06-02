# Canonical source for the Homebrew cask. Copy this file into the
# `ealliaume/homebrew-tap` repo at `Casks/solplanet-energy-tracker.rb` (plan §4,
# §8). The release workflow's `update-tap` job rewrites `version` + `sha256`
# there on every `vX.Y.Z` tag — keep the field formatting it `sed`s for intact:
#   sed 's/version "..."/.../'  and  sed 's/sha256 "..."/.../'
cask "solplanet-energy-tracker" do
  version "1.0.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ealliaume/mac-solplanet-energy-tracker/releases/download/v#{version}/Solplanet-Energy-Tracker.zip"
  name "Solplanet Battery Energy Tracker"
  desc "Menu bar app for live Solplanet/AISWEI inverter telemetry"
  homepage "https://github.com/ealliaume/mac-solplanet-energy-tracker"

  # Ad-hoc signed, not notarized. There is no real `no_quarantine` stanza; for a
  # custom tap, first launch is made safe two ways (plan §1, §4): users are told
  # to `brew install --cask --no-quarantine`, AND the app strips its own
  # quarantine xattr at launch as a defensive fallback. Users opt into this
  # trust by tapping this third-party repo.
  auto_updates false
  depends_on macos: ">= :sonoma" # LSMinimumSystemVersion 14.0

  app "Solplanet Battery Energy Tracker.app"

  zap trash: [
    "~/.cache/solplanet-energy-tracker",
    "~/Library/Preferences/io.github.ealliaume.solplanet-energy-tracker.plist",
  ]
end
