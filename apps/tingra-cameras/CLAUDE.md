# Agent Rules for the Tingra Cameras App

You have full access to every file in this folder — no need to ask about reading, writing, or deleting files here.

Tingra Cameras is a small macOS app that lives in the Tingra monorepo and drives its **engine packages** to show live camera video. It opens a narrow compact window — a camera picker over a live-camera preview over the camera's controls — or, switched to from the Window menu, a standard window with a sidebar listing the available cameras, a large preview, and a trailing sidebar with the controls; selecting a camera shows its feed, and each window shows its own camera. These rules are specific to this app; for anything not covered here, defer to the monorepo root `../../CLAUDE.md`.

The app depends on the local SPM engine packages `TingraHost`, `TingraPlugInKit`, `TingraCapturePlugIns`, and `TingraEventBus` (all under `../../packages/`). `TingraEventBus` and `TingraPlugInKit` are dynamic products, so the target embeds them in an Embed Frameworks phase; a Debug build would run without it by finding them in DerivedData, and an archive would not launch. It talks to the engine only through the host and the `Input` seam — never by importing a capture framework directly. Discovery and capture go through `AVFoundationCapturePlugIn`, and the selected camera's `CapturedFrame` stream is presented on an `AVSampleBufferDisplayLayer`.

Like the rest of Tingra, this app is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`) and uses the hardened runtime instead. Built-in and external cameras are delivered as out-of-process **CMIOExtension** DAL plug-ins loaded into this app's process, which needs two things beyond the sandbox: the App Sandbox blocks the mach lookups those extensions need to start their capture graph, and the hardened runtime's library validation blocks loading a DAL plug-in signed by a different team than this app. `tingra-cameras/tingra-cameras.entitlements` grants `com.apple.security.device.camera` (resource access; the app opens no microphone — it asks the capture plug-in for cameras only, `AVFoundationCapturePlugIn(deviceKinds: [.camera])`, so microphones are never even discovered — so it has no `audio-input` entitlement) and `com.apple.security.cs.disable-library-validation` (lets the DAL plug-in load) — the same combination `apps/tingra-cli/tingra-cli.entitlements` already uses for the same reason. Without `disable-library-validation`, `CMIOGraphStart` fails (`err=-536870163`) and the camera never streams even though discovery and authorization both succeed. Camera access is still gated by TCC via the `NSCameraUsageDescription` usage string.

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
- Never use periodic polling. Camera availability is **event-driven**: observe `AVCaptureDevice` connect/disconnect notifications and `AVCaptureDevice.DiscoverySession`, never a poll loop.
- Don't ever use hacks to solve a problem.
- Use consistent vocabulary in code and UI: **camera**, **preview**. Don't call a camera a "source" or "device feed."

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
| Run tests | None here: the project has no test target. The logic worth testing (presets, parameters, the launch rule) lives in `TingraHost`, so test it there with `cd ../../packages/TingraHost && swift test` (docs/RELEASE.md, Decision C12) |
| Format all Swift files | `../../scripts/format-swift.sh` |
| Package for release | `../../scripts/release-app-package.sh --app cameras` (unsigned without `TINGRA_SIGN_ID`; see docs/RELEASE.md, "Releasing Tingra Cameras") |
| Cut a release | `../../scripts/release-cameras.sh` (`--dry-run` to rehearse), or Actions → Release Tingra Cameras |

Run from `apps/tingra-cameras/`. The app also opens and runs directly from Xcode (⌘R). CI builds it unsigned and warning-clean in `format-test.yml`'s `cameras` job.

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
- All camera capture goes through the engine's `Input` seam, not `AVFoundation` directly. `CaptureEngine` stands up a minimal host (event bus, registries, master clock, plug-in loader), activates `AVFoundationCapturePlugIn` for discovery, and drives the selected camera's `Input`. The live preview is an `AVSampleBufferDisplayLayer` inside an `NSViewRepresentable` that enqueues the camera's `CapturedFrame` stream; a placeholder shows until a camera is selected, and a message shows if the camera can't be opened — in a card as tall as the message, not the 16:9 frame, because the camera's error is longer than a narrow frame holds.
- Camera authorization is requested inside the engine's `CameraInput.start()` (TCC prompt on first use); the app surfaces the denied/unavailable states as a message in the preview canvas. The `NSCameraUsageDescription` string is set in the target's build settings (`INFOPLIST_KEY_NSCameraUsageDescription`), and the hardened-runtime camera entitlement is in `tingra-cameras/tingra-cameras.entitlements` (the app is not sandboxed — see above).
- **Camera controls** (docs/UVC.md): in the trailing sidebar (`TrailingSidebar`, an `.inspector` column of the main app's shape, 280–320–440 points wide, shown and hidden per window by View ▸ Show/Hide Inspector, ⌥⌘I, and the toolbar's trailing button), the selected camera's adjustable controls — a USB webcam's brightness, white balance, exposure, focus, zoom — are drawn from the camera input's `Parameter` descriptors in `CameraControls/`, read with `Input.currentParameters()` when the camera is selected and written live with `Input.setParameters(_:)`. The capture plug-in reaches the camera through `TingraUVC`; the app never imports it. Editing a control stores nothing — the camera keeps its values — unless the operator saves them as a camera preset. Values are re-read when an Auto switch flips, never polled.
- **Camera presets** (`Presets/`, docs/UVC.md "Camera presets"): the selected camera's control values saved under a name, in a Presets sidebar section above the cameras and a Presets menu. Both sidebar sections collapse, the main app's way: `Section(isExpanded:)` over an expansion persisted per section in `UserDefaults` (`SidebarPreferences`, keys `sidebar.presets.expanded`/`sidebar.cameras.expanded`), each disclosure reporting its own `tap`. Clicking one recalls it (selects its camera and writes the values); its context menu sets it as the default, updates it with the current settings, renames, or deletes it. The first preset saved becomes the default. A launch opens the camera the operator last chose (remembered in `UserDefaults` by id and name, `selectedCameraID`/`selectedCameraName`), else the default preset's camera, and writes the default preset's values when the camera opening is its own. An Xcode re-run (⌘R while the app runs) can launch before macOS has released the camera the killed copy was streaming, so a USB camera reopened at launch may report "delivered no frame within 10 seconds"; a normal quit and relaunch does not (seen with the Razer, 2026-10-28). Clicking the selected camera after a preview error restarts it. The data, rules, and file (`camera-presets.json`) live in `TingraHost` (`CameraPreset`, `CameraPresets`, `CameraPresetStore`) and are tested there; `HardwareModel` keeps them observable. Dialogs are per window (`PresetDialogs`, attached by `WindowSession`), and a preset recalls onto the window it is chosen in, opened from the sidebar through the environment and from the menu through a focused scene value.
- **Preview commands** (`PreviewCommands/`): the preview's context menu, the Edit menu, and the View menu carry **Copy** (the camera's newest frame, at full resolution, onto the pasteboard as an image) and **Cross Bars** (lines through the preview's centre, drawn on a layer over the video so a copied frame never includes them; remembered across launches). The engine keeps only the newest frame for Copy.
- **The sidebar follows the window's width** (`ContentView`). The preview column keeps 410 points to itself and the trailing sidebar keeps its own width, so the sidebar needs those plus its own width: narrowing the window past that closes the sidebar, widening back reopens it unless the operator has changed it since, and opening it in a narrower window widens the window to fit (`HostWindow`, because SwiftUI can't resize an open window). The trailing sidebar never closes on its own, because it holds the only way to reach the controls: the window's minimum is 410 points, plus the trailing sidebar's 280 while it is open. The state is per window, in `@SceneStorage`.
- **Names:** the product is `Tingra Cameras.app` (module `TingraCameras`, bundle identifier `com.moonwink.tingra.cameras`), while the project, target, and scheme stay `tingra-cameras`. Its version is `TINGRA_CAMERAS_VERSION` in `Tingra.xcconfig`, separate from the product version (docs/RELEASE.md, "Releasing Tingra Cameras"). `Tingra Cameras --version` prints it and exits before the app exists: `TingraCamerasMain` is the `@main` entry, by `TingraHost`'s `LaunchArguments` rule, and `TingraCamerasApp` is not. A window is titled with the selected camera's name, else the product name. SwiftUI saves window and split-view layouts under keys containing the module name, so renaming the module discards them once.
- **Window styles** (`WindowStyles/`): a window is **compact**, the default (one narrow column, the `WindowGroup` scene `compact`, `CompactWindowView`): a camera pop-up and a Presets pull-down over the preview (`PreviewFrame`, shared with the standard window) over the camera's controls (`CameraControlsView`, the trailing sidebar's form), with the status bar across the bottom; its width is bounded at 340–380–520 points (`.windowResizability(.contentSize)`), its height free. Or it is **standard** (the three columns above, the `WindowGroup` scene `standard`). Any number of either can be open. The Window menu's **Switch to Compact Window** / **Switch to Standard Window** (`WindowStyleCommands`) opens the other style's window on the same camera and closes the key one — the Music app's Switch to MiniPlayer — and remembers the choice (`window.style` in `UserDefaults`, `WindowStylePreferences`, compact when unset), so a launch (`.defaultLaunchBehavior` on both scenes) and File ▸ New Window (⌘N, `NewWindowCommands`, replacing SwiftUI's item, which always opens the first group) open that style. The Presets pull-down lists the Presets menu's items (`PresetMenuItems`, shared) and a Manage Presets submenu with each preset's sidebar context menu (`PresetContextMenu`), so nothing a preset can do needs the standard window. Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing = false` in the app's `init`): a window is a camera of its own, never a tab, so View ▸ Show Tab Bar and the Window menu's tab items are gone. The compact window is a candidate for a menu bar extra that tears off into it, as some menu bar utilities do; not built.
- **Each window shows its own camera** (decided 2026-11-07, replacing "windows share one model"). `HardwareModel` keeps only what is app-wide — the connected cameras, the presets, the permission, the cross bars — and each window owns a `CameraSession` (`WindowSession`, the modifier both styles wear): the window's camera, its preview state, and that camera's controls, reached by the window's views through the environment and by the menu bar's Copy and Presets commands through the key window's focused value. A session reaches the engine through its own `CameraFeed`. A camera input has one frame consumer at a time, so windows showing the same camera share one `RunningCamera` in `CaptureEngine`: started for the first window that subscribes, each frame drawn in every subscribed window, a control change shown in each, and stopped when the last window leaves (a window closing leaves its camera). A start waiting on a silent camera is left at once when the window chooses another. A new window opens on the camera the operator last chose (`selectedCameraID`/`selectedCameraName`), else the default preset's, else the first; the first window since launch also applies the default preset's values when the camera is the preset's own; a window macOS restores reopens on its own camera (`@SceneStorage` `camera.id`/`camera.name`). Device changes and a new camera grant reach every session from `HardwareModel`, never by polling; a window whose camera disconnects falls back to the first camera.
- **Settings** (`Settings/`): a `Window` scene opened by Settings… (⌘,) in the app menu, with the main Tingra app's source-list shape and three panes — **General** (Appearance, System/Light/Dark; Show Status Bar), **Permissions** (the camera permission, with Request/Open System Settings/Reset; re-read on every app activation, never polled, and a new grant restarts a preview that could not open), and **About** (icon, version, uptime). Choices persist in `UserDefaults` under the main app's key names (`appearance.mode`, `statusBar.visible`).
- **Status bar** (`StatusBar/`): across the bottom of the preview column, the preview's state (Live, Starting…, Camera unavailable, No camera selected), the camera's name, and its frame resolution — reported by the engine when the size changes, never per frame. Shown or hidden from General settings or View ▸ Show/Hide Status Bar (⌘/).
- Device connect/disconnect arrives as `device.connected` / `device.disconnected` events on the engine's event bus (domain `capture`); `CaptureEngine` rebuilds the camera list from those events, never by polling. Device connect/disconnect is a normal event, never an error state.
- Keep the capture pipeline off the main actor where the frameworks require it (the engine owns that), and marshal UI updates back with `@MainActor`.

## Localization
- Localize all user-facing strings via the String Catalog at `tingra-cameras/Localizable.xcstrings`. The source language is English (`en`).
- Supported translation languages are **German (`de`) and Spanish (`es`)**. When you add or change a user-facing string, add it to the catalog with translations for both languages so coverage stays complete.
- Xcode auto-extracts new English strings on build, but auto-extracted entries are left untranslated. Provide the `de`/`es` values explicitly (state `translated`).
- Device names reported by the system (e.g. "FaceTime HD Camera") are proper nouns supplied at runtime and are not localized. Likewise a camera control's name and section heading ("Brightness", "White Balance") come from the capture plug-in's `Parameter` descriptors at runtime and are drawn with `Text(verbatim:)`, as the main app draws effect parameter names.
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
- Name no other product, company, or brand, in code, comments, docs, or UI text, beyond the exceptions the monorepo root `../../CLAUDE.md` allows (real dependencies, shipped integrations, Apple's own apps as platform conventions, and hardware the code handles).

# Other Rules

1. **Workspace Isolation Constraint**: Never modify, create, or delete files outside this workspace.
2. **Strict Compilation**: After each change, code must compile without errors and introduce no **new** warnings. Verify proactively. Treat pre-existing warnings as out of scope unless deliberately cleaning up.
3. **No Leftover Scripts**: Remove temporary working scripts as soon as they're no longer needed.
4. **Code Preservation**: Never remove existing code, logic, or comments without a clear, compelling reason.
5. **DRY Principles**: Place shared UI components or helpers in a common file rather than duplicating them.
