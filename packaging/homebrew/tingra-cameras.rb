# typed: false
# frozen_string_literal: true

# Homebrew cask for Tingra Cameras — the source of truth lives here; releases
# render it into the tap repo `larryaasen/homebrew-tingra` as
# `Casks/tingra-cameras.rb` (see ../../docs/RELEASE.md, "Releasing Tingra
# Cameras", Decision C9, and packaging/README.md).
#
# The cask downloads the Developer ID signed, notarized, stapled disk image from
# the app's own GitHub release, tagged `cameras-v<version>` (Decision C2), and
# copies the app into /Applications. It never builds from source.
#
# Each release: scripts/release-cameras.sh renders this file into the tap with
# the new `version` and `sha256`. By hand, run
# `scripts/release-app-package.sh --app cameras` and copy both from its output.
#
# `zap` names files, never a folder: ~/Library/Application Support/Tingra is
# shared with Tingra.app and holds its destinations, projects, and plug-in
# settings, so removing this cask must leave the folder and everything else in
# it alone. `camera-presets.json.unreadable` is the copy the app sets aside when
# the presets file cannot be read.
cask "tingra-cameras" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256_FROM_release-app-package.sh"

  url "https://github.com/larryaasen/tingra/releases/download/cameras-v#{version}/Tingra-Cameras-#{version}-arm64.dmg"
  name "Tingra Cameras"
  desc "Camera picker with a live preview and USB webcam controls"
  homepage "https://github.com/larryaasen/tingra"

  # Apple Silicon only, and macOS 26 or later for the Liquid Glass design
  # system (Decision C6). A bare symbol is a minimum; Homebrew deprecated the
  # `">= :tahoe"` string form.
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Tingra Cameras.app"

  zap trash: [
    "~/Library/Application Support/Tingra/camera-presets.json",
    "~/Library/Application Support/Tingra/camera-presets.json.unreadable",
    "~/Library/Preferences/com.moonwink.tingra.cameras.plist",
    "~/Library/Saved Application State/com.moonwink.tingra.cameras.savedState",
  ]
end
