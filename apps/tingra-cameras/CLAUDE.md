# Agent Rules for the Tingra Cameras App

You have full access to every file in this folder — no need to ask about reading, writing, or deleting files here.

Tingra Cameras is a small macOS app that lives in the Tingra monorepo and drives its **engine packages** to show live camera video. It presents a two-column hardware picker: a sidebar listing the available cameras and microphones beside a large live-camera preview; selecting a camera shows its feed. These rules are specific to this app; for anything not covered here, defer to the monorepo root `../../CLAUDE.md`.

The app depends on the local SPM engine packages `TingraHost`, `TingraPlugInKit`, `TingraCapturePlugIns`, and `TingraEventBus` (all under `../../packages/`). It talks to the engine only through the host and the `Input` seam — never by importing a capture framework directly. Discovery and capture go through `AVFoundationCapturePlugIn`, and the selected camera's `CapturedFrame` stream is presented on an `AVSampleBufferDisplayLayer`.

Like the rest of Tingra, this app is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`) and uses the hardened runtime instead. Built-in and external cameras are delivered as out-of-process **CMIOExtension** DAL plug-ins loaded into this app's process, which needs two things beyond the sandbox: the App Sandbox blocks the mach lookups those extensions need to start their capture graph, and the hardened runtime's library validation blocks loading a DAL plug-in signed by a different team than this app. `tingra-cameras/tingra-cameras.entitlements` grants `com.apple.security.device.camera` / `com.apple.security.device.audio-input` (resource access) and `com.apple.security.cs.disable-library-validation` (lets the DAL plug-in load) — the same combination `apps/tingra-cli/tingra-cli.entitlements` already uses for the same reason. Without `disable-library-validation`, `CMIOGraphStart` fails (`err=-536870163`) and the camera never streams even though discovery and authorization both succeed. Camera/microphone access is still gated by TCC via the `NSCameraUsageDescription` usage string.

## Role
You are a Senior macOS Engineer specializing in SwiftUI and Apple's media frameworks (AVFoundation). Your code must always adhere to Apple's Human Interface Guidelines.

## Project Structure

This is a **native Xcode project** (`tingra-cameras.xcodeproj`), not a Swift package. It has a single macOS app target and uses Xcode's synchronized-folder format, so files added to the target folder are picked up automatically.

```
tingra-cameras.xcodeproj/          # The Xcode project (single app target + shared scheme)
tingra-cameras/                    # App source folder (synchronized root group)
  *.swift                          # App source files (flat by default)
  Localizable.xcstrings            # String Catalog (en → de, es)
  Assets.xcassets/                 # App icon + accent color
```

**Key facts:**
- App source files live directly in `tingra-cameras/`. For a feature with **more than one UI file**, create a named subdirectory (e.g. `tingra-cameras/CameraSettings/`). Single-file views go flat in `tingra-cameras/`. Do not create generic folders like `Views/`, `Components/`, or `Helpers/`.
- This app links the local engine packages listed above and imports Apple frameworks (`SwiftUI`, `AVFoundation`, `AppKit`). Keep engine access behind the host and the `Input` seam — views depend on view-facing `Device` values and a frame sink, never on a capture framework or the `Input` protocol directly.

## General Guidelines
- Summary documents after changes are never needed.
- **Always verify compilation after making changes** with the Build command below — the app target must build warning-clean.
- Follow Apple's Human Interface Guidelines for UI/UX decisions.
- Prioritize readability and maintainability over clever code.
- Never use periodic polling. Camera and microphone availability is **event-driven**: observe `AVCaptureDevice` connect/disconnect notifications and `AVCaptureDevice.DiscoverySession`, never a poll loop.
- Don't ever use hacks to solve a problem.
- Use consistent vocabulary in code and UI: **camera**, **microphone**, **preview**. Don't call a camera a "source" or "device feed."

## Code Quality
- Use SwiftLint standards for code style (no force unwrapping, proper optional handling).
- Format Swift code using SwiftFormat (swift-format); run the monorepo's `../../scripts/format-swift.sh`.
- Prefer value types (structs, enums) over reference types (classes) where appropriate — reach for a class only where reference semantics are required (e.g. an `@Observable` model, an `AVCaptureSession` wrapper, an `NSView` subclass).
- Use `guard` statements for early returns instead of nested `if` statements.
- Always use optional chaining or guard statements instead of force unwrapping (`!`); likewise avoid force `try` (`try!`).
- **Never crash the process.** Recoverable problems (no camera present, camera authorization denied, a capture session that won't start) surface as SwiftUI state or thrown Swift errors, never a trap or `fatalError`.
- Write unit tests for logic that isn't pure view code (e.g. selection/model behavior).

## Build & Test Commands

| Action | Command |
|--------|---------|
| Build (Debug, macOS) | `xcodebuild -project tingra-cameras.xcodeproj -scheme tingra-cameras -configuration Debug -destination 'platform=macOS' build` |
| Run tests | `xcodebuild -project tingra-cameras.xcodeproj -scheme tingra-cameras -destination 'platform=macOS' test` |
| Format all Swift files | `../../scripts/format-swift.sh` |

Run from `apps/tingra-cameras/`. The app also opens and runs directly from Xcode (⌘R).

## SwiftUI & UI Design
- Use SwiftUI for all UI. Build the two-column layout with `NavigationSplitView` and standard controls (`List`, `Section`, `Label`).
- **Adopt the standard SwiftUI Liquid Glass look — do not hardcode a bespoke visual style.** On macOS 26 the system controls already render with Liquid Glass; the app's job is to use standard controls so that styling comes through, not to reimplement it.
  - **Never hardcode fonts, sizes, weights, colors, opacities, corner radii, or shadows taken from a mockup or wireframe.** Any wireframe supplied is a rough layout guide only, never a visual spec.
  - Use **semantic system fonts** (`.body`, `.headline`, `Font.TextStyle` via the default `Label`/`Text` styling), **system colors** (`.primary`, `.secondary`, `Color.accentColor`, `.tint`), and **system materials** (`.regularMaterial`, `.bar`, or the material the container already provides). Prefer letting standard controls supply their own styling over applying modifiers.
  - Use **SF Symbols** for iconography (e.g. `Label("FaceTime HD Camera", systemImage: "video")`), not custom-drawn shapes.
  - Show selection with the **native `List` selection** highlight and standard idioms (e.g. a trailing `checkmark`), not a custom-drawn highlight capsule.
- Use `@MainActor` for UI-related async code. Host Metal/AVFoundation preview content in an `NSViewRepresentable` where SwiftUI lacks a native equivalent.
- Do not introduce a design-tokens file or a custom theme; this app follows the system appearance.

## SwiftUI & the engine
- All camera capture goes through the engine's `Input` seam, not `AVFoundation` directly. `CaptureEngine` stands up a minimal host (event bus, registries, master clock, plug-in loader), activates `AVFoundationCapturePlugIn` for discovery, and drives the selected camera's `Input`. The live preview is an `AVSampleBufferDisplayLayer` inside an `NSViewRepresentable` that enqueues the camera's `CapturedFrame` stream; a placeholder shows until a camera is selected, and a message shows if the camera can't be opened.
- Camera authorization is requested inside the engine's `CameraInput.start()` (TCC prompt on first use); the app surfaces the denied/unavailable states as a message in the preview canvas. The `NSCameraUsageDescription` string is set in the target's build settings (`INFOPLIST_KEY_NSCameraUsageDescription`), and the hardened-runtime camera/audio-input entitlements are in `tingra-cameras/tingra-cameras.entitlements` (the app is not sandboxed — see above).
- Device connect/disconnect arrives as `device.connected` / `device.disconnected` events on the engine's event bus (domain `capture`); `CaptureEngine` rebuilds the device lists from those events, never by polling. Device connect/disconnect is a normal event, never an error state.
- Keep the capture pipeline off the main actor where the frameworks require it (the engine owns that), and marshal UI updates back with `@MainActor`.

## Localization
- Localize all user-facing strings via the String Catalog at `tingra-cameras/Localizable.xcstrings`. The source language is English (`en`).
- Supported translation languages are **German (`de`) and Spanish (`es`)**. When you add or change a user-facing string, add it to the catalog with translations for both languages so coverage stays complete.
- Xcode auto-extracts new English strings on build, but auto-extracted entries are left untranslated. Provide the `de`/`es` values explicitly (state `translated`).
- Device names reported by the system (e.g. "FaceTime HD Camera") are proper nouns supplied at runtime and are not localized.
- When a string is removed from code, leave its catalog entry in place unless doing a deliberate cleanup — Xcode marks unused entries `stale` automatically.

## Platform Support
- Target **macOS 26 (Tahoe)+, Apple Silicon** — the floor that makes the standard Liquid Glass design system available.
- Don't use deprecated APIs — keep code current with the latest SDK.
- This is a Mac-only app. Use `AppKit` (`NSViewRepresentable`) directly where needed; don't add cross-platform abstractions speculatively.

## State Management
- Model shared state with **`@Observable` classes** (the Observation framework), owned via `@State` and passed via `@Bindable` / `@Environment`. Do **not** use `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, or `@EnvironmentObject`.
- An `@Observable` class that drives UI must be `@MainActor` (or rely on the target's Main Actor default isolation).
- Use `@State` for view-local state. Prefer simple boolean flags over complex wrapper types.
- Clean up state in async operations with `defer` (e.g. stop the capture session when the view disappears).

## Async/Await
- Always use `async/await` instead of completion handlers.
- Mark UI updates with `@MainActor` or wrap in `MainActor.run`.
- Prefer `AsyncStream`/`AsyncSequence` over Combine for reactive data (e.g. a frame or device-change stream).
- Use `Task` for fire-and-forget work; handle cancellation for long-running tasks.

## Error Handling
- Always provide user-friendly error messages, surfaced in the UI.
- Use proper Swift error types (an `enum` conforming to `Error`).
- Handle async errors with `try`/`catch`.

## Documentation
- Add doc comments (`///`) for every type, property, method, and function — public and private alike.
- Keep inline comments focused on "why" not "what".
- Use clear, descriptive names that reduce the need for comments.
- Keep the "Swift File Header" convention from the monorepo root `../../CLAUDE.md` (copyright + `SPDX-License-Identifier: MIT`).

# Other Rules

1. **Workspace Isolation Constraint**: Never modify, create, or delete files outside this workspace.
2. **Strict Compilation**: After each change, code must compile without errors and introduce no **new** warnings. Verify proactively. Treat pre-existing warnings as out of scope unless deliberately cleaning up.
3. **No Leftover Scripts**: Remove temporary working scripts as soon as they're no longer needed.
4. **Code Preservation**: Never remove existing code, logic, or comments without a clear, compelling reason.
5. **DRY Principles**: Place shared UI components or helpers in a common file rather than duplicating them.
