# Agent Rules for `apps/`

These rules add to the monorepo root [AGENTS.md](../AGENTS.md), which still applies in full. `CLAUDE.md` in this folder only imports this file (`@AGENTS.md`) and should not be edited separately.

Engine architecture, the package dependency graph, and the data flow rules are in [packages/AGENTS.md](../packages/AGENTS.md). Read it before changing how an app talks to the engine.

## The Apps

```
apps/
  tingra-cli/                   # Headless front end over the engine (see CLI.md)
  ingest-simulator/             # Local RTMP/SRT test server: pinned MediaMTX + sim.sh; test-only,
                                #   never linked into the product (see SIMULATOR.md)
  tingra-app/                   # The SwiftUI/AppKit app: an Xcode project (scheme tingra-app,
                                #   product Tingra.app, module TingraApp), so the bundle and a stable
                                #   signature are build settings and one TCC grant survives a rebuild
  tingra-cameras/               # Standalone "Tingra Cameras" app: camera/microphone picker beside a
                                #   live preview; an Xcode project, no engine packages; own AGENTS.md
```

## The App Target
- **UI lives in `apps/tingra-app` only.** Engine packages stay UI-free, so the CLI and the daemon can import them. The app is an **Xcode project**: build it with `xcodebuild`, never `swift build`. It compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a type that must run off the main actor says `nonisolated` explicitly; and with `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, using a member means importing the module that defines it, even when another import re-exports it. `Bundle.module` does not exist in an app target — `String(localized:)` reads the app's own catalog from `Bundle.main` by default.

## SwiftUI & AppKit
- Use SwiftUI for UI; use AppKit where SwiftUI doesn't cover a need (e.g., hosting Metal preview content in an `MTKView`).
- Use design tokens for consistent styling once a shared design-tokens file exists for the UI layer.

## State Management
- Use `@State` for view-local state and for owning an `@Observable` model (see Swift Language & Idioms).
- Prefer simple boolean flags over complex wrapper types when possible.
- Clean up state properly in async operations using `defer`.

## Localization
- Localize all user-facing strings in the app via its String Catalog (`Localizable.xcstrings`). The source language is English (`en`).
- Supported translation languages are **German (`de`) and Spanish (`es`)**. When you add or change a user-facing string, add it to the catalog with translations for both languages so coverage stays complete.
- Xcode auto-extracts new English strings on build, but auto-extracted entries are left untranslated. Provide the `de`/`es` values explicitly (state `translated`) rather than relying on extraction.
- When a string is removed from code, leave its catalog entry in place unless doing a deliberate cleanup — Xcode marks unused entries `stale` automatically.
- Vocabulary in every language must still follow [GLOSSARY.md](../docs/GLOSSARY.md) — translate the concept, not a borrowed term.
- **Localization applies to the app only.** `tingra-cli` output stays English and locale-independent: `--json` events, field names, error identifiers, and any machine-readable output are a scripting contract, and exit codes (not message wording) carry the meaning callers key off. Foundation picks the language from `AppleLanguages` (per run: `-AppleLanguages '(es)'`), not `LANG`/`LC_*`.

### Signing: nothing personal in a tracked file
This repository is public, so **no app secret and nothing personal to one developer may be committed** — not stream keys, not certificates, and not an Apple Developer Team ID. Both Xcode projects (`apps/tingra-app`, `apps/tingra-cameras`) therefore carry `DEVELOPMENT_TEAM = $(TINGRA_DEVELOPMENT_TEAM)` in a committed `Tingra.xcconfig`, which optionally includes a **git-ignored `Local.xcconfig`** holding that one value. Copy `Local.xcconfig.example` and fill in your team.

- `#include?` is an *optional* include, so a checkout without `Local.xcconfig` still builds — that is exactly what CI does, passing `CODE_SIGNING_ALLOWED=NO` and needing no team at all.
- **Never write a Team ID, certificate name, or keychain identity into a tracked file** — not the `.pbxproj`, not a script, not a workflow. Xcode will silently re-add `DEVELOPMENT_TEAM` to the `.pbxproj` if you pick a team in the target editor's Signing & Capabilities tab; if a diff shows that line coming back, move it to `Local.xcconfig` instead of committing it.
- Release signing and notarization credentials stay in GitHub Actions secrets and the `TINGRA_SIGN_ID`/`TINGRA_INSTALLER_SIGN_ID`/`TINGRA_NOTARY_PROFILE`/`TINGRA_APP_PROFILE`/`TINGRA_SIGN_IDENTITY` environment variables, never in the repo (see [CLI.md](../docs/CLI.md) "Distribution").
