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

## Cutting a release

`scripts/release.sh [version]` does the whole thing in one command — build, sign,
notarize, tag, publish the GitHub release, and update the tap — so a release is:

```sh
# 1. Bump TingraCLIVersion.current in Version.swift + Info.plist, then commit.
# 2. Export the signing env (see the table above), then:
scripts/release.sh          # version defaults to Version.swift's constant
```

It requires a **clean working tree** (the tag must name a committed state) and the
GitHub CLI (`gh`) authenticated with push access to both repos. Under the hood it
runs `scripts/package-cli.sh`, pushes tag `v<version>`, creates the release with
`dist/*.zip` (and `*.pkg` if produced), and renders
[`homebrew/tingra-cli.rb`](homebrew/tingra-cli.rb) into the tap with the release's
`version` + `sha256`. Configurable via `TINGRA_REPO`, `TINGRA_TAP_REPO`,
`TINGRA_TAP_FORMULA`. Idempotent — safe to re-run if a step fails.

Testers then install with:

```sh
brew install larryaasen/tingra/tingra-cli
tingra-cli serve --install
```

The tap never builds from source — it downloads the prebuilt, notarized zip.

### The pieces `release.sh` orchestrates

The formula source of truth is [`homebrew/tingra-cli.rb`](homebrew/tingra-cli.rb).
The **tap itself is a separate repo**, `larryaasen/homebrew-tingra`, that lives
outside this monorepo and must exist (empty is fine) before the first release.
To run any step by hand instead of `release.sh`:

1. `scripts/package-cli.sh` → `dist/*.zip`, `dist/*.pkg`, and the zip's sha256.
2. `gh release create v<version> dist/* --repo larryaasen/tingra`.
3. Copy `homebrew/tingra-cli.rb` into the tap, setting `version` and `sha256`,
   then commit and push the tap.

The tag-triggered `.github/workflows/packaging.yml` automates steps 1–2 in CI
when the signing secrets are configured; the tap update (step 3) stays with
`release.sh` (or is done by hand) since it pushes to a second repo.
