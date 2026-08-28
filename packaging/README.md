# Packaging

How `tingra-cli` is built, signed, notarized, and distributed. The full
rationale lives in [docs/CLI.md](../docs/CLI.md) "Distribution"; this directory
holds the concrete recipe.

## Artifacts

`scripts/release-cli-package.sh [version]` produces, in `dist/`:

- **`tingra-cli-<version>-arm64.zip`** — the artifact the Homebrew tap
  downloads. A bare Mach-O cannot be stapled, so Gatekeeper fetches the
  notarization ticket online on first run.
- **`tingra-cli-<version>.pkg`** — a stapled installer for offline-capable
  direct download.

Both come from one signed binary: Developer ID Application signature, hardened
runtime, the stable identifier `com.moonwink.tingra.cli`, and the entitlements
in [`apps/tingra-cli/tingra-cli.entitlements`](../apps/tingra-cli/tingra-cli.entitlements)
— which may hold **unrestricted entitlements only**, since a bare executable
carries no provisioning profile to authorize a restricted one (see docs/CLI.md,
"Hardened runtime and entitlements"). After signing, the script runs the
packaged binary and stops the release unless it reports the expected version:
signature verification, entitlement inspection, and notarization all pass on a
binary the kernel refuses to launch, as v0.1.1 proved.
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
| `TINGRA_NOTARY_KEYCHAIN` | path to the keychain holding that profile — optional, and only CI sets it (`notarytool` reads the login keychain otherwise, which a runner's release credentials are not in) |

In CI these come from GitHub Actions secrets, never the repo.

## Release secrets

The CI release reads nine repository secrets. They are set once and then only
touched when something expires or rotates, which is exactly when nobody
remembers how they were made — so here is the whole recipe.

| Secret | Where it comes from |
|--------|---------------------|
| `TINGRA_RELEASE_TOKEN` | a fine-grained PAT, **Contents: Read and write**, scoped to **both** `larryaasen/tingra` and `larryaasen/homebrew-tingra` |
| `TINGRA_CERT_P12` | `base64 -i` of a `.p12` exported from Keychain Access |
| `TINGRA_CERT_PASSWORD` | that export's password |
| `TINGRA_SIGN_ID` | `Developer ID Application: … (TEAMID)` |
| `TINGRA_INSTALLER_SIGN_ID` | `Developer ID Installer: … (TEAMID)` |
| `TINGRA_NOTARY_KEY_P8` | `base64 -i` of an App Store Connect API key |
| `TINGRA_NOTARY_KEY_ID` | that key's Key ID — always the `.p8` filename, `AuthKey_<KEYID>.p8` |
| `TINGRA_NOTARY_ISSUER_ID` | the Issuer ID **for a Team key only** (see below) |
| `TINGRA_INSTALLER_CERT_P12` / `_PASSWORD` | not needed when one `.p12` carries both identities |

**The certificates.** In Keychain Access → login → My Certificates, select *both*
Developer ID identities and export them as one `.p12`. A `.p12` may hold several
identities and the workflow imports whatever it finds, so the separate installer
secrets stay unset. Note `security find-identity -v -p codesigning` hides the
Installer certificate; drop `-p codesigning` to see both.

**The API key.** App Store Connect → Users and Access → Integrations →
App Store Connect API, role **Developer** or higher. Two things about this key
cause almost every notarization failure:

- **Team vs Individual.** A **Team** key requires `--issuer`; an **Individual**
  key has none and `notarytool` rejects the argument. The page shows a team
  Issuer ID whether or not your key needs it, so it is easy to set the secret for
  an Individual key and get `Credential validation failed` with nothing naming
  the cause. Tingra's key is a Team key.
- **It downloads once.** Store the `.p8` in a password manager immediately. A key
  that cannot be re-downloaded has to be replaced.

**Always validate a new key locally first.** This answers in seconds; CI takes a
whole run to tell you the same thing:

```sh
xcrun notarytool store-credentials scratch-profile \
    --key ~/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>
```

**Setting them.** `gh secret set <NAME>` with no `--body` prompts for the value,
so nothing lands in shell history. Do not reach for `$(pbpaste)` in a command you
also have to copy — copying the command replaces the clipboard, and the secret
becomes the command text.

```sh
base64 -i ~/tingra-signing.p12 | gh secret set TINGRA_CERT_P12 --repo larryaasen/tingra
gh secret set TINGRA_CERT_PASSWORD --repo larryaasen/tingra          # prompts
```

**Expiry.** A fine-grained PAT lasts at most 366 days. When
`TINGRA_RELEASE_TOKEN` expires the release fails at `actions/checkout` with a git
authentication error that does not mention the token — regenerate it with the
same two repositories and the same single permission.

## Verifying a published release

Read the artifacts, not the workflow log — the log says what the pipeline
believes, and these commands say what a user will actually get.

```sh
gh release view v<version> --repo larryaasen/tingra          # assets present, not a draft
gh release download v<version> --repo larryaasen/tingra --pattern '*.zip'
shasum -a 256 tingra-cli-<version>-arm64.zip                 # must equal the tap formula's sha256
xcrun stapler validate tingra-cli-<version>.pkg              # proves Apple issued a ticket
pkgutil --check-signature tingra-cli-<version>.pkg           # "trusted by the Apple notary service"
codesign -dv --verbose=4 dist/tingra-cli                     # identifier, chain, flags=0x10000(runtime)
codesign -d --entitlements - --xml dist/tingra-cli | plutil -p -
```

Two results that look like problems and are not:

- **`spctl --assess --type exec` reports "does not seem to be an app."** That
  assessment only applies to bundles. For a bare executable the meaningful
  evidence is the `origin=Developer ID Application: …` line it prints, plus the
  stapled `.pkg` above — the zip itself carries no ticket to staple by design.
- **The zip extracts to `dist/tingra-cli`, not a bare `tingra-cli`.** `ditto
  --keepParent` embeds the enclosing folder. Homebrew descends into a single
  top-level directory when staging, so the formula's `bin.install "tingra-cli"`
  resolves correctly — verified on every release through 0.1.3. Anyone changing
  the `ditto` invocation or the formula's `install` block must keep those two
  agreeing.

## Cutting a release

**Normally, in CI:** Actions → **Release tingra-cli** → *Run workflow*
(`.github/workflows/release-cli.yml`). That runs every step below — gate on
Format & Test, bump, build, sign, notarize, tag, publish the GitHub release, and
push the formula to the tap — so no developer Mac, keychain, or `gh` login is in
the loop. The workflow's header lists the repository secrets it needs.

**Locally,** `scripts/release-cli.sh` is the one command to run, and is exactly
what the workflow runs. It prompts for the next version (defaulting to the next
increment), bumps `TingraCLIVersion.current` and `Info.plist` together, commits
and pushes that bump, then hands off to `release-cli-publish.sh` — so a release
is:

```sh
# Export the signing env (see the table above), then:
scripts/release-cli.sh      # prompts for the version; --dry-run to rehearse
```

`--yes` makes it unattended: every confirmation is answered yes and the default
version is taken. That is the only difference between the two paths. Missing
signing credentials abort under `--yes` instead of prompting, so an unsigned
artifact can never be published unattended.

Step-by-step instructions, flags, and the resume behavior are in
[docs/CLI.md](../docs/CLI.md) "Cutting a release".

`scripts/release-cli-publish.sh [version]` is the non-interactive half underneath — build,
sign, notarize, tag, publish the GitHub release, and update the tap. Call it
directly when the version bump is already committed (which is what CI does); it
does **not** bump the version itself, so a bare `release-cli-publish.sh` on a tree whose
constant still names a shipped version stops at the tag-collision check.

It requires a **clean working tree** (the tag must name a committed state) and the
GitHub CLI (`gh`) authenticated with push access to both repos. Under the hood it
runs `scripts/release-cli-package.sh`, pushes tag `v<version>`, creates the release with
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

### The pieces `release-cli-publish.sh` orchestrates

The formula source of truth is [`homebrew/tingra-cli.rb`](homebrew/tingra-cli.rb).
The **tap itself is a separate repo**, `larryaasen/homebrew-tingra`, that lives
outside this monorepo and must exist (empty is fine) before the first release.
To run any step by hand instead of `release-cli-publish.sh`:

1. `scripts/release-cli-package.sh` → `dist/*.zip`, `dist/*.pkg`, and the zip's sha256.
2. `gh release create v<version> dist/* --repo larryaasen/tingra`.
3. Copy `homebrew/tingra-cli.rb` into the tap, setting `version` and `sha256`,
   then commit and push the tap.

`.github/workflows/release-cli.yml` automates all three in CI, including the tap
push — it holds a PAT with write access to both repositories, which is what
`GITHUB_TOKEN` alone could not give it.
