# typed: false
# frozen_string_literal: true

# Homebrew cask for Tingra.app — the source of truth lives here; releases
# render it into the tap repo `larryaasen/homebrew-tingra` as `Casks/tingra.rb`
# (see ../../docs/RELEASE.md, Decision 5, and packaging/README.md).
#
# The cask downloads the Developer ID signed, notarized, stapled disk image from
# the product's GitHub release, tagged `v<version>`, the same release that
# carries tingra-cli (Decision 6), and copies the app into /Applications. It
# never builds from source. Until the CLI moves inside the app (slice 2), the
# `tingra-cli` formula installs the CLI and the daemon on its own.
#
# Each release: scripts/release-publish.sh renders this file into the tap with
# the new `version` and `sha256`. By hand, run
# `scripts/release-app-package.sh --app tingra` and copy both from its output.
#
# `zap` names what only Tingra.app writes, never the shared folder, the rule
# the tingra-cameras cask follows (amending Decision 5).
# ~/Library/Application Support/Tingra is shared: tingra-cli reads the
# destinations, the plug-in enablement file and load markers, and the user
# plug-ins folder there, its daemon keeps its socket there, and Tingra Cameras
# keeps its presets file there, so removing this cask leaves all of those and
# the folder. Once the CLI moves inside the app (slice 2), its files can join
# this list. `zap` never touches the Keychain, which holds the stream keys, and
# the caveats say so. Recordings and snapshots are the operator's work, in
# folders the operator chose, and are never zapped.
cask "tingra" do
  version "0.2.0"
  sha256 "REPLACE_WITH_DMG_SHA256_FROM_release-app-package.sh"

  url "https://github.com/larryaasen/tingra/releases/download/v#{version}/Tingra-#{version}-arm64.dmg"
  name "Tingra"
  desc "Live video production and streaming"
  homepage "https://github.com/larryaasen/tingra"

  # Apple Silicon only, and macOS 15 or later (Decision 10). A bare symbol is a
  # minimum; Homebrew deprecated the `">= :sequoia"` string form.
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Tingra.app"

  zap trash: [
    "~/Library/Application Support/Tingra/*.tingraproject",
    "~/Library/Application Support/Tingra/*.tingraproject.unreadable",
    "~/Library/Application Support/Tingra/live-stream.json",
    "~/Library/Application Support/Tingra/loaded-plug-ins.json",
    "~/Library/Application Support/Tingra/log-session-id",
    "~/Library/Application Support/Tingra/Plug-in Data",
    "~/Library/Application Support/Tingra/stream-history.json",
    "~/Library/Application Support/Tingra/stream-history.json.unreadable",
    "~/Library/Containers/com.moonwink.tingra.app.notes",
    "~/Library/Logs/Tingra",
    "~/Library/Preferences/com.moonwink.tingra.app.plist",
    "~/Library/Saved Application State/com.moonwink.tingra.app.savedState",
  ]

  caveats <<~EOS
    Tingra keeps stream keys and plug-in secrets in the Keychain, and
    `brew uninstall --zap` leaves them there. To remove them, choose
    Remove All Data in Tingra's Data settings before uninstalling.

    To use tingra-cli and its daemon as well, install the formula:
      brew install larryaasen/tingra/tingra-cli
  EOS
end
