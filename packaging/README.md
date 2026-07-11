# Packaging

How `tingra-cli` is built, signed, notarized, and distributed. The full
rationale lives in [docs/CLI.md](../docs/CLI.md) "Distribution"; this directory
holds the concrete recipe.

## Artifacts

`scripts/package-cli.sh [version]` produces, in `dist/`:

- **`tingra-cli-<version>-arm64.zip`** — the artifact the Homebrew tap
  downloads. A bare Mach-O cannot be stapled, so Gatekeeper fetches the
  notarization ticket online on first run.
- **`tingra-cli-<version>.pkg`** — a stapled installer for offline-capable
  direct download.

Both come from one signed binary: Developer ID Application signature, hardened
runtime, the stable identifier `com.moonwink.tingra.cli`, and the entitlements
in [`apps/tingra-cli/tingra-cli.entitlements`](../apps/tingra-cli/tingra-cli.entitlements).
The Info.plist ([`apps/tingra-cli/Info.plist`](../apps/tingra-cli/Info.plist))
is embedded in the binary's `__TEXT,__info_plist` section by the linker flags
in the CLI's `Package.swift`.

Signing and notarization need credentials, passed as environment variables
(the script skips them with a warning when unset, so a local run still builds
and prints the zip's sha256):

| Variable | What |
|----------|------|
| `TINGRA_SIGN_ID` | `Developer ID Application: … (TEAMID)` |
| `TINGRA_INSTALLER_SIGN_ID` | `Developer ID Installer: … (TEAMID)` — for the `.pkg` |
| `TINGRA_NOTARY_PROFILE` | a `notarytool store-credentials` keychain profile name |

In CI these come from GitHub Actions secrets, never the repo.

## The Homebrew tap

The formula source of truth is [`homebrew/tingra-cli.rb`](homebrew/tingra-cli.rb).
The **tap itself is a separate repo**, `larryaasen/homebrew-tingra`, that lives
outside this monorepo. Per release:

1. Run `scripts/package-cli.sh` and upload `dist/*.zip` and `dist/*.pkg` to the
   GitHub release for the tag (`v<version>`).
2. Copy `homebrew/tingra-cli.rb` into the tap, updating `version` and `sha256`
   from the script's output.
3. Commit the tap. Testers then:

   ```sh
   brew tap larryaasen/tingra
   brew install tingra-cli
   tingra-cli serve --install
   ```

The tap never builds from source — it downloads the prebuilt, notarized zip.
