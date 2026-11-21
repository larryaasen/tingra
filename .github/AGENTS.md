# Agent Rules for CI (`.github/`)

These rules add to the monorepo root [AGENTS.md](../AGENTS.md), which still applies in full. `CLAUDE.md` in this folder only imports this file (`@AGENTS.md`) and should not be edited separately.

## Workflows
- **CI runs on GitHub Actions**, every workflow on the `xcode-27` arm64 image with `DEVELOPER_DIR` pinned explicitly to Xcode 27.2 (the image's default is older). The workflows:
  - **`format-test.yml`** — every push and PR, skipped when a change touches only files no job reads (its `paths-ignore`): formatting check, `swift test` per package and the app (no camera, microphone, or TCC needed), code coverage to Codecov (informational, never a merge gate; `.github/codecov.yml`), and warning-clean builds of every package and app. Also `workflow_call`-able, which is how the release workflows gate on it.
  - **`integration.yml`** — integration tests against the ingest simulator, on streaming/output changes.
  - **`release-cli.yml`**, **`release-sdk.yml`**, **`release-cameras.yml`** — manual-dispatch releases, each a thin wrapper over the matching `scripts/release-*.sh --yes` so the local and CI paths cannot drift. Recipes: [CLI.md](../docs/CLI.md) "Distribution", [PLUGINS.md](../docs/PLUGINS.md) Decision 37, and [RELEASE.md](../docs/RELEASE.md). The SDK is built at the toolchain floor, read from its workflow's `DEVELOPER_DIR`, because a `.swiftinterface` from a newer compiler may not build under an older Xcode.
- **Every CI job carries `timeout-minutes` of 30 or less**, set just below its `runs-on`, sized to a few times the job's normal run. A job that only `uses:` a reusable workflow cannot take one; the called workflow's jobs carry their own.
