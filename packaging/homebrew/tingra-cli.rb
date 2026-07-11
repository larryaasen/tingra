# typed: false
# frozen_string_literal: true

# Homebrew formula for tingra-cli — the source of truth lives here; releases
# copy it into the tap repo `larryaasen/homebrew-tingra` (see
# ../../docs/CLI.md, "Distribution" and packaging/README.md).
#
# The tap never builds from source: it downloads the prebuilt, Developer ID
# signed, notarized arm64 zip from the GitHub release. Building on the user's
# machine would produce an unsigned binary with no stable identity — no
# notarization, and TCC grants keyed to nothing.
#
# Each release: run scripts/package-cli.sh, then update `version` and `sha256`
# below from its output and commit the formula to the tap.
class TingraCli < Formula
  desc "Native macOS live-streaming engine with an MCP server (headless CLI front end)"
  homepage "https://github.com/larryaasen/tingra"
  version "0.1.0"
  url "https://github.com/larryaasen/tingra/releases/download/v#{version}/tingra-cli-#{version}-arm64.zip"
  sha256 "REPLACE_WITH_ZIP_SHA256_FROM_package-cli.sh"
  license "MIT"

  # Apple Silicon (arm64), macOS 15+ only (see Platform Support in CLAUDE.md).
  depends_on macos: :sequoia
  on_intel do
    odie "tingra-cli ships for Apple Silicon (arm64) only."
  end

  def install
    bin.install "tingra-cli"
  end

  def caveats
    <<~EOS
      Tingra's MCP server runs as a launchd LaunchAgent so its camera and
      microphone prompts are attributed to Tingra (not the agent app that
      connects). Register it once with:

        tingra-cli serve --install

      Then point your agent at:  tingra-cli mcp
      Remove it with:            tingra-cli serve --uninstall

      Re-run `tingra-cli serve --install` after `brew upgrade` to point the
      LaunchAgent at the new version. See the README for full setup.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/tingra-cli version")
  end
end
