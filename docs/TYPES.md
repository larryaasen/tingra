# Tingra Types

Every public type in the Tingra monorepo, package by package, each on one line
of at most 80 characters, name included, saying what it is. It is an index, not
an API reference: the authoritative documentation for a type is its `///` doc
comment in the source, and the design behind each piece is in
[ARCHITECTURE.md](ARCHITECTURE.md).

[README.md](../README.md) says what each package and app *is*; this file says
what is *in* it. The order matches the README's, and the two are updated
together — a type added, renamed, or removed lands here in the same change as
the code.

Apps expose no public API beyond their entry point, so their entries list the
internal surface a reader needs to navigate the target instead.

## `packages/TingraEventBus`

- `EventBus` — publishes structured events to the sinks subscribed to it.
- `EventBusEvent` — one event: date, group, domain, name, params, call site.
- `EventGroup` — the closed routing axis: what kind of event it is.
- `EventDomain` — the open attribution axis: which area emitted the event.
- `EventValue` — a scalar event param value, encoded as bare JSON.
- `EventSink` — the protocol every sink subscribing to the bus conforms to.

## `packages/TingraPlugInKit`

- `Input` — the protocol for anything producing video or audio frames.
- `InputID` — the stable identifier for an input.
- `InputKind` — provenance: camera, microphone, display, generator, or media.
- `InputMedia` — the media an input produces: video, audio, both, or neither.
- `InputRegistering` — the registration seam where input plug-ins attach.
- `CapturedFrame` — one GPU-resident video frame with its master-clock time.
- `CapturedAudio` — one captured audio buffer with its host-time PTS.
- `ErrorIdentifier` — the stable, append-only identifiers error events carry.
- `StreamingService` — the output seam: connect, append program media, stop.
- `StreamingServiceProvider` — a factory of services, keyed by URL scheme.
- `DestinationTemplate` — a well-known service a new destination starts from.
- `StreamingServiceEvent` — a connection event reported after a start.
- `StreamingServiceError` — the errors `StreamingService.start(to:)` throws.
- `StreamingStatistics` — a snapshot of a service's delivery counters.
- `StreamConfiguration` — the compression and program settings of a stream.
- `OutputID` — the stable identifier for a registered output.
- `OutputRegistering` — the registration seam where output plug-ins attach.
- `Destination` — a streaming target: URL, optional stream key, parameters.
- `RecordingService` — the recording seam: open a file, append, finalize.
- `RecordingServiceProvider` — a factory of services, keyed by file extension.
- `RecordingServiceEvent` — a recording event reported after a start.
- `RecordingServiceError` — the errors `RecordingService.start(to:)` throws.
- `RecordingFile` — where a recording is written: file URL and container.
- `EffectID` — the stable identifier for a registered audio or video effect.
- `EffectConfiguration` — one effect as persisted: its id and parameters.
- `ParameterDescribing` — declares the `parameters` a registration exposes.
- `Parameter` — one adjustable setting a plug-in declares: number or color.
- `ParameterColor` — a color parameter's value: sRGB components and alpha.
- `EffectParameter` — the deprecated alias of `Parameter`.
- `EffectColor` — the deprecated alias of `ParameterColor`.
- `AudioEffect` — one audio processing step in a channel strip's chain.
- `AudioEffectProvider` — registers an audio effect and makes its instances.
- `VideoEffect` — one video processing step in a layer's chain.
- `VideoEffectProvider` — registers a video effect and makes its instances.
- `EffectRegistering` — the registration seam where effect plug-ins attach.
- `IdentifiedError` — an error that maps to a stable `ErrorIdentifier`.
- `Tool` — the MCP tool seam: a control the engine exposes to agents.
- `ToolError` — a structured tool error keyed by `ErrorIdentifier`.
- `Resource` — the MCP resource seam: an observable `tingra://` document.
- `ToolRegistering` — the registration seam where tool plug-ins attach.
- `JSONValue` — an arbitrary JSON value, the tool seam's currency; `@frozen`.
- `EngineClock` — the master clock seam: current time and the tick stream.
- `LateTickPolicy` — what a late tick stream delivers: `skip` or `catchUp`.
- `PlugIn` — the protocol every plug-in conforms to: identity and activation.
- `BundledPlugIn` — a `PlugIn` shipped as a bundle's principal class.
- `PlugInKitVersion` — the kit's SemVer, checked before a bundle's code loads.
- `PlugInID` — a plug-in's stable reverse-DNS identifier and event domain.
- `MediaProviderID` — the stable identifier for a media input provider.
- `MediaInputProvider` — a plug-in's factory of inputs that play media files.
- `MediaRegistering` — the registration seam where media plug-ins attach.
- `MediaRegisteringError` — thrown when a host has no media registry.
- `UnavailableMediaRegistry` — the default media seam; throws on register.
- `PlugInContext` — what a plug-in gets at activation: bus, clock, seams.

## `packages/TingraHost`

- `HostClock` — the production `EngineClock` over the host time clock.
- `KeepAwake` — the seam a session holds the Mac and the process awake by.
- `KeepAwakeHold` — one hold taken through `KeepAwake`, released once.
- `ProcessActivityKeepAwake` — the `ProcessInfo`-backed `KeepAwake`.
- `InputRegistry` — the actor that holds registered inputs and resolves them.
- `InputRegistryError` — registry errors, such as a duplicate input id.
- `InputSelectorError` — selector resolution errors: `notFound`, `ambiguous`.
- `PlugInLoader` — activates compiled-in and bundled plug-ins, reporting each.
- `PlugInActivation` — what a launch activated, with the bundle scan.
- `PlugInLoadReport` — each host-tier plug-in a launch met, with its state.
- `PlugInLoadReport.Entry` — one plug-in in the report: id, state, reason.
- `PlugInBundleLoader` — scans, admits, and loads `*.tingraplugin` bundles.
- `PlugInBundle` — a loaded bundle: its plug-in instance and directory.
- `PlugInBundleScan` — one scan's result: found, loaded, problems, skipped.
- `FoundPlugInBundle` — one bundle a scan met, with its declared info.
- `PlugInBundleSkip` — an admitted bundle that was not loaded, and why.
- `PlugInSafeModeTrigger` — why a launch is in safe mode.
- `PlugInEnablement` — which bundles are off: the `plug-ins.json` document.
- `CrashedPlugInBundle` — one recorded crash of a bundle while it loaded.
- `PlugInEnablementStore` — reads and writes `plug-ins.json` atomically.
- `PlugInEnablementStoreError` — the file is `unreadable` or `unwritable`.
- `PlugInLoadGuard` — the per-process markers that catch a load crash.
- `PlugInLoadMarker` — names the bundle a process is loading right now.
- `ProcessIdentity` — a process id paired with the kernel's start time.
- `PlugInBundleProblem` — a bundle refusal or defect, with a stable reason.
- `PlugInBundleInfo` — what a bundle's Info.plist declares about itself.
- `PlugInBundleOpening` — the seam that reads and loads a bundle on disk.
- `FoundationPlugInBundleOpener` — the production opener, over `Bundle`.
- `CodeSignatureChecking` — the seam that admits a bundle's signature.
- `CodeSignatureVerdict` — `valid`, `unsigned`, or `notNotarized`.
- `StaticCodeSignatureChecker` — the production checker, over Security.
- `AuthorizationPermission` — a camera, microphone, or screen recording grant.
- `AuthorizationStatus` — `notDetermined`, `granted`, `denied`, `restricted`.
- `AuthorizationChecking` — the seam that reads, requests, and resets grants.
- `AuthorizationError` — a recoverable error from resetting a grant.
- `SystemAuthorization` — the production checker over AVFoundation and TCC.
- `OSLogSink` — the sink routing every event to OSLog, params private.
- `LogLineFormatter` — the one human log line format every text sink shares.
- `LogSession` — the four-digit cold-start id stamped into every log line.
- `FileSink` — the sink appending human log lines to a file.
- `LogFile` — locates the app's log file; sizes, snapshots, clears, reads.
- `LogFileError` — a snapshot asked of an empty or missing log.
- `LogFileChunk` — one read of log lines and the offset they begin at.
- `LogLevel` — the word a log line begins with: `INFO`, `DEBUG`, `ERROR`.
- `LogEntry` — one log line read back, with its parsed parts.
- `OutputRegistry` — the actor holding streaming and recording providers.
- `OutputRegistryError` — registry errors, such as a scheme already served.
- `MediaRegistry` — the actor resolving a media file to a provider's input.
- `MediaRegistryError` — registry errors, such as a file no provider opens.
- `EffectRegistry` — the actor holding audio and video effect providers.
- `EffectRegistryError` — an effect id that is already registered.
- `ProgramPacer` — tick-paced latest-wins video pacing for a single input.
- `StreamSession` — one live stream fanned out to N destination legs.
- `StreamSession.VideoSource` — the session's video: an input or the program.
- `StreamSession.AudioSource` — the session's audio: an input or the mix.
- `StreamSession.LegStatistics` — one leg's counters at one reading.
- `StreamSession.DestinationLeg` — one leg: its id, destination, and service.
- `SecureStorage` — the host's secret store seam, where stream keys live.
- `KeychainSecureStorage` — the data-protection Keychain `SecureStorage`.
- `SecureStorageError` — a recoverable, secret-free secure storage error.
- `DestinationStore` — the operator's saved destinations and their keys.
- `DestinationID` — a saved destination's stable identity.
- `StoredDestination` — a saved destination's key-free record.
- `DestinationStoreError` — a recoverable, secret-free store error.
- `ToolRegistry` — the actor holding the MCP tools plug-ins register.
- `ToolRegistryError` — a tool name that is already registered.
- `ResourceRegistry` — the actor holding the engine's MCP resources.
- `ResourceRegistryError` — a resource URI that is already registered.
- `StatusSink` — retains the latest status events and re-broadcasts them.

## `packages/TingraCapturePlugIns`

- `AVFoundationCapturePlugIn` — contributes cameras and microphones as inputs.
- `ScreenCaptureKitCapturePlugIn` — contributes the Mac's displays as inputs.
- `DisplayChange` — one display connecting or disconnecting.
- `DisplayEventReporter` — turns display reconfigurations into device events.
- `DisplayInput` — one display behind the `Input` seam.
- `DisplayCapture` — one running display capture, injected for tests.
- `DisplayCaptureEnd` — why a display capture ended on its own.
- `DisplayCaptureStarter` — the function that starts a display capture.
- `DisplayPower` — observes display sleep and wake from `NSWorkspace`.
- `DisplayPowerEvent` — a display sleep or wake.
- `SystemDefaultInputs` — the system default camera and microphone ids.
- `PrivateAggregateDevice` — keeps macOS's private aggregates out of inputs.

## `packages/TingraGeneratorPlugIns`

- `GeneratorPlugIn` — contributes the built-in generators as inputs.
- `BarsGenerator` — SMPTE color bars with a burned-in time-of-day timecode.
- `AlignmentGenerator` — a crosshatch alignment pattern.
- `PlugeGenerator` — a PLUGE black-level calibration pattern.
- `PlugeStrictGenerator` — a stricter broadcast-style PLUGE pattern.
- `BlackGenerator` — full-frame opaque black as a selectable input.
- `ToneGenerator` — a test tone with frequency and level parameters.

## `packages/TingraComposition`

- `Compositor` — the tick-paced engine rendering the program and preview.
- `MediaID` — a media item's stable identifier, and its input's `InputID`.
- `ProjectMedia` — one file added to a project as media: id, path, name.
- `ProjectID` — the stable identifier of a project document.
- `Project` — the saved, versioned `Codable` document for a whole show.
- `DestinationReference` — a project's use of one saved destination.
- `ProjectDestination` — superseded by `DestinationReference`; decode only.
- `ProjectDestinationID` — a destination's stable identity within a project.
- `Preset` — a named, persisted collection of shots and audio channels.
- `AudioChannel` — one channel strip as a preset persists it.
- `PresetID` — the stable identifier for a preset.
- `Shot` — a persisted composition: a layer tree over a background.
- `ShotOrigin` — whether a shot is `authored` or `automatic`.
- `ShotID` — the stable identifier for a shot.
- `Layer` — one input placed in a frame, with opacity and an effect chain.
- `BackgroundColor` — the straight RGBA color the layers composite over.
- `ProgramFormat` — the program's width, height, and frame rate.
- `Transition` — the move between shots: cut, dissolve, wipe, or shader.
- `WipeEdge` — the frame edge a wipe reveals the incoming shot from.
- `TransitionShader` — the built-in shader transitions: iris, diagonal, blinds.
- `ShotRenderer` — the seam between the compositor's ticks and the pixel work.
- `ShotRenderFailure` — why a renderer produced no frame for a tick.
- `VideoEffectFactory` — resolves a layer's persisted chain to live effects.
- `CoreImageShotRenderer` — the default, GPU-resident Core Image renderer.
- `VideoEffectChain` — one layer's live effect chain, applied in order.

## `packages/TingraAudio`

- `AudioMixer` — the clock-paced mixer producing the stereo program mix.
- `ChannelStrip` — one input's slot in the mixer: level, pan, and mute.
- `MeterReading` — one strip's pre-fader peak and RMS over one mix block.
- `StereoMeterReading` — the master's post-fader reading, per channel.
- `MeterBlock` — one mix tick's readings: every strip and the master.
- `MixFormat` — the program mix's sample rate and block size.
- `AudioMonitor` — the monitor seam: the program mix played to a device.
- `AudioMonitorDevice` — one audio output device, by its Core Audio UID.
- `AudioMonitorError` — a monitor device that was not found or did not start.
- `AVAudioEngineMonitor` — the first-party `AudioMonitor`, over AVAudioEngine.

## `packages/TingraEffectPlugIns`

- `EffectPlugIn` — contributes the built-in audio and video effects.
- `GainEffectProvider` — registers the gain effect.
- `GainEffect` — a clean decibel trim on a channel strip.
- `HighPassEffectProvider` — registers the high-pass effect.
- `HighPassEffect` — a second-order Butterworth high-pass rumble filter.
- `LowPassEffectProvider` — registers the low-pass effect.
- `LowPassEffect` — a second-order Butterworth low-pass filter.
- `ColorAdjustEffectProvider` — registers the color adjust effect.
- `ColorAdjustEffect` — a layer's brightness, contrast, and saturation trim.
- `BlurEffectProvider` — registers the blur effect.
- `BlurEffect` — a layer's Gaussian blur.
- `FrameEffectProvider` — registers the Frame effect.
- `FrameEffect` — a layer's rounded corners and inside border.
- `CropEffectProvider` — registers the Crop effect.
- `CropEffect` — insets that show only part of a layer's input picture.

## `packages/TingraOutputPlugIns`

- `HaishinKitOutputPlugIn` — contributes the RTMP/RTMPS and SRT providers.
- `RTMPStreamingServiceProvider` — the provider for `rtmp://` and `rtmps://`.
- `HaishinKitStreamingService` — the RTMP/RTMPS service, over HaishinKit.
- `SRTStreamingServiceProvider` — the provider for `srt://` destinations.
- `SRTHaishinKitStreamingService` — the SRT service, over HaishinKit.
- `HaishinKitMediaConversion` — the conversions both services share.

## `packages/TingraRecordingPlugIns`

- `RecordingPlugIn` — contributes the `.mov`/`.mp4` recording provider.
- `AVAssetWriterRecordingServiceProvider` — the `.mov`/`.mp4` provider.
- `AVAssetWriterRecordingService` — the recording service, over a writer.
- `RecordingCapacity` — how much recording time a volume still holds.
- `RecordingCapacityProbe` — how a service measures a volume, injected.

## `packages/TingraMediaPlugIns`

- `MediaPlugIn` — contributes the image, movie, and text media providers.
- `MediaInputError` — the errors a media input throws from `start()`.
- `ImageMediaProvider` — the provider for every image type ImageIO reads.
- `ImageInput` — a still image as an input, decoded once and held.
- `MovieMediaProvider` — the provider for movie types AVFoundation reads.
- `MovieInput` — a looping video file as an input, paced by the clock.
- `TextMediaProvider` — the provider for plain text and Markdown.
- `TextInput` — a text or Markdown document rendered once as an input.

## `packages/TingraJSONRPC`

- `JSONRPCID` — a request/response identifier: a string or an integer.
- `JSONRPCErrorCode` — the standard error codes plus `resourceNotFound`.
- `JSONRPCError` — the error object a response carries; a Swift `Error`.
- `JSONRPCIncoming` — a received request, notification, or response.
- `JSONRPCResponse` — an outgoing response: one of `result` or `error`.
- `JSONRPCNotification` — an outgoing method call with no id.
- `MessageCoder` — the one encoder/decoder configuration every peer shares.
- `MessageTransport` — the duplex, message-level channel under a session.
- `SurfaceMessage` — one message with the `IOSurface` attached to it.
- `SurfaceMessageTransport` — a transport that can carry an `IOSurface`.
- `InMemoryMessageTransport` — the test transport: no socket, no process.
- `LinkedMessageTransports` — two in-memory transports joined as a pair.
- `AsyncQueue` — a single-consumer async FIFO for blocking producers.
- `XPCMessageChannel` — the `@objc` protocol an `NSXPCConnection` carries.
- `XPCMessageTransport` — the `MessageTransport` over an `NSXPCConnection`.
- `XPCMessageTransportError` — the connection offered no channel proxy.

## `packages/TingraMCP`

Re-exports `TingraJSONRPC` (`@_exported import`), so `import TingraMCP` also
sees the types listed under that package.

- `Daemon` — the engine daemon serving MCP sessions on a Unix socket.
- `MCPSession` — one connection's MCP session: tools, resources, status.
- `SessionMethodHandler` — the seam for an endpoint's methods beyond MCP.
- `SessionNotifier` — how a method handler sends its peer a notification.
- `SessionRequestError` — errors from a request the session sent its peer.
- `StreamCoordinator` — owns the one active stream for the stream tools.
- `StreamDefaults` — the system default input identifiers, injected.
- `ControlToolsPlugIn` — registers the first-party control tools.
- `DaemonInfo` — the daemon's name and version, reported at `initialize`.
- `StdioSocketProxy` — the byte pipe behind `tingra-cli mcp`.
- `SocketLocation` — the per-user socket path and its directory setup.
- `LaunchAgent` — renders, installs, and removes the daemon's LaunchAgent.
- `LaunchAgentError` — an error installing or removing the LaunchAgent.
- `LaunchdSocket` — adopts the launchd-owned listening socket.
- `MCPProtocol` — the MCP method and notification names and version.

## `packages/TingraAppPlugInKit`

- `PaneID` — a pane's identifier: the plug-in id and a name.
- `CommandID` — a command's identifier, unique within its plug-in.
- `StatusItemID` — a status item's identifier, unique within its plug-in.
- `SidebarPosition` — the sidebar a pane prefers: leading, trailing, bottom.
- `PaneDescriptor` — a pane a plug-in contributes to a sidebar.
- `ShortcutDescriptor` — a keyboard shortcut as a manifest declares it.
- `CommandPlacement` — where a command appears; today the plug-in's menu.
- `CommandDescriptor` — a command a plug-in contributes to the menus.
- `SettingsPaneDescriptor` — a pane a plug-in adds to the Settings window.
- `WindowDescriptor` — a window a plug-in contributes, opened by a command.
- `StatusItemDescriptor` — a status item a plug-in adds to the status bar.
- `MeterLevel` — one meter's linear peak and RMS over a window of the mix.
- `MeterLevels` — one `tingra/meters` notification: strips and master.
- `FrameBus` — a video bus a plug-in can follow: `program` or `preview`.
- `BusFrame` — one bus frame as a plug-in gets it: surface, bus, time.
- `BusMonitorView` — the ready-made bus monitor view for a plug-in's pane.
- `ActivationCondition` — a bus event that wakes the plug-in.
- `ActivationCondition.Qualifier` — the param key and value it requires.
- `ActivationConditionError` — a malformed activation condition.
- `PlugInManifest` — what a plug-in declares in its extension's Info.plist.
- `PlugInManifestError` — what is wrong with a manifest, naming the fix.
- `AppTierMethod` — the JSON-RPC method names the app tier adds to MCP.
- `StorageScope` — where a stored value lives: `project` or `application`.
- `PlugInConnection` — the extension's MCP client connection to the app.
- `PlugInConnectionError` — what a connection call can get wrong.
- `DebouncedWriter` — coalesces a stream of values into one write per pause.
- `PlugInRuntime` — the extension's observable view of its connections.
- `TingraAppExtension` — what a plug-in's `@main` type adopts.
- `PlugInCommandHandler` — the configuration accepting the app's connections.

## `apps/tingra-cli`

An executable, so it exposes no public types; its surface is its subcommands —
`devices`, `stream`, `probe`, `serve`, `mcp`, `plug-ins`, and `version` (see
[CLI.md](CLI.md) for each one's options, output, and exit codes).

- `PlugInOptions` — the options every plug-in-loading command shares.
- `PlugIns` — the `plug-ins` command: list, enable, and disable.
- `PlugInSwitch` — turns one bundle on or off in `plug-ins.json`.
- `DaemonEngine` — `serve`'s engine, assembled in one place.

## `apps/ingest-simulator`

No Swift target and no types: a pinned MediaMTX binary wrapped in `sim.sh`
(`start | stop | status | verify`) with key-validating paths (see
[SIMULATOR.md](SIMULATOR.md)).

## `apps/tingra-app`

An app, so it exposes no public API beyond its `@main` entry; its internal
surface is:

- `EngineModel` — the observable model that boots and drives the engine.
- `LeadingSidebar` — the main window's leading sidebar and its ten sections.
- `SidebarRow` — the pure row derivation behind the leading sidebar.
- `SidebarSection` — the closed list of the sidebar's ten sections.
- `SidebarPreferences` — which sidebar sections are open, per Mac.
- `ContentView` — the main window's detail column: monitors over controls.
- `TransitionPanel` — the Cut, Take, transition, and duration controls.
- `FadeToBlackButton` — the latching Fade to Black toolbar control.
- `SettingsButton` — the toolbar gear that opens the settings window.
- `DestinationListView` — the Streaming pane's destination list.
- `DestinationEdit` — the pure destination state behind those rows.
- `DestinationTemplateMatching` (file) — which template a typed URL matches.
- `DestinationTemplateURLKey` — a URL reduced for template comparison.
- `MixerView` — the console mixer panel: strip columns and a master column.
- `FaderScale` — the pure mapping between fader travel and linear gain.
- `EffectChainView` — one strip's audio effect chain editor, in a popover.
- `InputParametersView` — one input's declared settings, in a popover.
- `ParameterScale` — the pure mapping between a value and slider travel.
- `CommittingNumberField` — a number field committing on Return or focus loss.
- `EffectChainHeading` — the Effects heading both chain editors share.
- `EffectSlotOrdinal` — the "1." ordinal before each chain slot's name.
- `EffectParameterField` — the value field beside a parameter's slider.
- `EffectParameterFormat` — the pure unit and percent conversions for it.
- `UnsupportedParameterRow` — the row for a parameter kind this build lacks.
- `EffectColorWell` — the color well drawn for a color parameter.
- `ColorWellRepresentable` — the `NSColorWell` wrapper beneath it.
- `MixerStrip` — the pure strip state merging authored channels and devices.
- `MuteLabel` — the fixed-size speaker label every mute toggle shares.
- `StripMeter` — one strip's pre-fader meter capsule beside its fader.
- `PeakReadout` — a meter's peak-hold readout; a click resets the hold.
- `PeakSubject` — whose peak a readout shows: a strip or the master.
- `PeakFigure` — the observable text and over state of one peak readout.
- `MasterMeter` — the master's post-fader stereo meter, two capsules.
- `MeterCapsule` — the one meter capsule every meter draws.
- `MeterCapsuleView` — the capsule's layer-backed `NSView`.
- `MeterSubject` — what one capsule shows: a strip or a master channel.
- `MeterDisplayLink` — the one display link every meter on screen shares.
- `MeterRelay` — the lock-guarded holder of latest readings and peak holds.
- `ProgramFrameRelay` — the lock-guarded holder of a bus's latest frame.
- `ProgramTee` — the tee feeding program media to stream and recording.
- `VerticalSlider` — a vertical `NSSlider` mirroring SwiftUI's `Slider`.
- `FaderSlider` — the `NSSlider` subclass catching a fader's double-click.
- `MeterBallistics` — draw-time ballistics: instant attack, 20 dB/s decay.
- `SessionPreferences` — where the operator's position persists per project.
- `SessionPosition` — validates the recorded position against the project.
- `MonitorPreferences` — where the monitor device, level, and mute persist.
- `RecordingSettingsView` — the Recording settings pane.
- `RecordButton` — the Record / Stop Recording toolbar control, ⌘R.
- `StreamButton` — the Start / Stop Streaming toolbar control, ⌘G.
- `RecordingPreferences` — where the recordings folder and container persist.
- `RecordingFilename` — the pure date-stamped, never-overwriting naming rule.
- **Snapshots** (`Snapshots/`) — a still of a monitor's frame, saved as PNG:
  - `SnapshotSubject` — which monitor: program, preview, input, or layer.
  - `SnapshotFeedback` — what the last request came to, worn as a badge.
  - `SnapshotWriter` — the actor that renders, names, and writes the PNG.
  - `SnapshotPNG` — an encoded snapshot.
  - `SnapshotError` — why a snapshot was not saved.
  - `SnapshotFilename` — the snapshot naming rule; never overwrites.
  - `SnapshotPreferences` — where the snapshots folder persists.
  - `SnapshotMonitorMenu` — the Save Snapshot menu every monitor wears.
  - `SnapshotBadge` — the feedback badge a monitor shows.
- `StatusBarView` — the status bar: recording, on-air, and format readings.
- `StatusBarCommands` — the View-menu Show/Hide Status Bar item, ⌘/.
- `SidebarVisibilityCommands` — the View-menu Show/Hide Sidebar item, ⌃⌘S.
- `StatusBarItem` — the pure lamp and symbol reading behind the status bar.
- `KeepAwakePreferences` — whether a stream or recording keeps the Mac awake.
- `KeepAwakeSwitch` — owns the app's one hold on the Mac while on air.
- `LiveStreamRecord` — `live-stream.json`: the stream this run has on air.
- `StreamResumeOffer` — whether a launch offers to resume a stream.
- `StreamResumeAlert` — the alert asking whether to resume the stream.
- `StatusBarPreferences` — whether the status bar is shown, per Mac.
- `StatusBarModel` — the observable both windows read for the bar's state.
- `TingraAppDelegate` — the AppKit hooks: open, quit, and safe mode.
- `PresetContextMenu` — one preset's context menu.
- `PresetMenuSurface` — which surface a preset menu is on, for `tap` names.
- `PresetRenameDialog` — the preset rename alert as a modifier.
- `ShotContextMenu` — one shot's context menu, shared by bank and sidebar.
- `ShotMenuSurface` — which surface a shot menu is on, for `tap` names.
- `ShotRenameDialog` — the shot rename alert as a modifier.
- `LaunchDiagnostics` — the build and system params of `app.launched`.
- `LaunchEnvironment` — whether this is the test host or a console run.
- `ConsoleEventSink` — the dev-run sink printing log-file lines to stdout.
- `TerminationReason` — why the app is quitting, as far as AppKit can say.
- `QuitCommands` — the app-menu Quit item, recording its `tap` first.
- `Binding.reportingTap` — reports a control's `tap` from its binding.
- `LayerTreeEditorView` — the layer-tree editor for the edited shot.
- `EditedShot` — the pure rule for which shot the layer editor follows.
- `LayerTreeEdit` — the pure layer edit operations over a `Shot`.
- `LayerHandlesOverlay` — direct manipulation of the selected layer.
- `LayerHandle` — one of the eight resize handles and the edges it moves.
- `LayerFrameGesture` — the pure move, resize, and nudge geometry.
- `LayerSnap` — the pure smart guides a dragged layer snaps onto.
- `LayerCommands` — the menu bar's Layer menu.
- `LayerMenuItems` — the items the Layer menu and row context menu share.
- `LayerArrangeCommand` — the closed table of layer arrange commands.
- `LayerMenuSurface` — which surface a layer menu item was chosen from.
- `LayerUndoAction` — what a layer edit did, naming Undo and Redo.
- `TrailingSidebar` — the trailing sidebar: inspector, Library, plug-ins.
- `LibrarySplitter` — the draggable hairline that resizes the Library.
- `LayerInspectorColumn` — the trailing sidebar's upper pane.
- `LibraryView` — the Library pane: Media, Snapshots, and Recordings tabs.
- `LibraryTab` — the Library's tabs: Media, Snapshots, and Recordings.
- `LibraryList` — the one file list every Library tab draws.
- `LibraryFacts` — the rows' cached thumbnails and movie durations.
- `FolderListing` — the files in a folder of one content type, newest first.
- `LibraryItem` — one Library row as a value, with its detail line.
- `LibraryPreferences` — the Library's height and tab, per Mac.
- **Plug-ins** (`PlugIns/`) — the app as the host of the app tier:
  - `EngineResources` — the session, program, and inputs resources.
  - `ModelResource` — a `Resource` over a snapshot of the model.
  - `ObservedChange` — observation tracking as an awaitable change.
  - `ProgramToolsPlugIn` — registers the app's program tools.
  - `ProgramControlling` — the seam the program tools act through.
  - `ShotSelector` — the `shot` argument: an id or a unique name.
  - `ShotTakeTool` — `shot_take`: takes a shot to program.
  - `PreviewSetTool` — `preview_set`: stages a shot on preview.
  - `FadeToBlackTool` — `fade_to_black`: fades picture and sound.
  - `ProgramOutputControlling` — the seam the stream and record tools use.
  - `ProgramOutputTool` — the schema and results the four tools share.
  - `ProgramStreamStartTool` — `program_stream_start`.
  - `ProgramStreamStopTool` — `program_stream_stop`.
  - `ProgramRecordStartTool` — `program_record_start`.
  - `ProgramRecordStopTool` — `program_record_stop`.
  - `AppPlugInHost` — discovers app-tier plug-ins and starts them on demand.
  - `AvailabilityCounts` — the enabled, disabled, and unapproved counts.
  - `DiscoveredPlugIn` — an extension identity with its manifest.
  - `AppPlugInServices` — what every plug-in link needs from the app.
  - `AppPlugInStorage` — the storage behind the method handler.
  - `AppPlugInLink` — one plug-in's process and its connections.
  - `PlugInHostError` — an identity whose bundle is not embedded.
  - `ActivationTable` — activation conditions indexed by event name.
  - `PaneRegistry` — every pane, settings pane, and window plug-ins declare.
  - `RegisteredPane` — a pane descriptor with its plug-in.
  - `RegisteredSettingsPane` — a settings pane descriptor with its plug-in.
  - `RegisteredWindow` — a window descriptor with its plug-in.
  - `StatusItemRegistry` — declared status items and their current texts.
  - `RegisteredStatusItem` — a status item descriptor with its plug-in.
  - `PlugInStatusReporting` — the seam a status item's text is set through.
  - `MeterFeed` — the mix's meter blocks as plug-ins follow them.
  - `MeterWindow` — the fold of meter blocks one follower is sent.
  - `PlugInMeterFeeding` — the seam the handler subscribes to meters by.
  - `RelayFrameFeed` — the program and preview frames as plug-ins follow them.
  - `PlugInFrameUpdate` — a bus's next frame surface, or an empty bus.
  - `PlugInFrameFeeding` — the seam the handler demands frames through.
  - `PlugInWindowView` — the content of a plug-in's window.
  - `CommandRegistry` — plug-in commands, grouped for the Plug-ins menu.
  - `RegisteredCommand` — a command descriptor with its plug-in and `tap`.
  - `PlugInRegistryError` — a registration refused because its id is taken.
  - `PlugInMethodHandler` — serves `tingra/*` on one plug-in's connection.
  - `PlugInStoring` — the storage-and-secrets seam behind the handler.
  - `SafeModeLaunch` — how this launch treats plug-in bundles.
  - `UncleanExitAlert` — the alert offering safe mode after an unclean exit.
  - `PlugInLaunchRecord` — `loaded-plug-ins.json`: bundles this run loaded.
  - `PlugInApplicationStore` — app-scoped plug-in storage, a file per id.
  - `PlugInSecretStore` — plug-in secrets in Keychain-backed secure storage.
  - `PanePreferences` — which plug-in panes are open, per Mac.
  - `PlugInShortcut` — turns a `ShortcutDescriptor` into a `KeyboardShortcut`.
  - `PlugInPaneHost` — one pane's hosted extension scene.
  - `PlugInPaneSection` — one plug-in pane's chrome in the trailing sidebar.
  - `PlugInCommands` — the Plug-ins menu, one submenu per plug-in.
  - `PlugInCommandItem` — one menu item; emits its `tap`, then performs.
- **Notes** (`tingra-notes`) — the first-party app-tier plug-in:
  - `NotesExtension` — the `@main` `TingraAppExtension`.
  - `NotesModel` — the notes text and font size, saved debounced.
  - `NotesPaneView` — the pane: a text editor and a Clear button.
  - `NotesSettingsView` — the settings pane: the editor's font size.
- **Fixture plug-in** (`tingra-fixture-plugin`) — a test-only bundle:
  - `FixturePlugIn` — the principal class; registers one input.
  - `FixtureInput` — a generator that delivers nothing.
- `InspectorCommands` — the View-menu Show/Hide Inspector item, ⌥⌘I.
- `InspectorButton` — the toolbar's inspector toggle.
- `LayerInspectorView` — the selected layer's inspector.
- `LayerInspectorUnit` — the pure pixels/percent conversion for its fields.
- `LayerPlacement` — the pure placement presets: anchors, sizes, and fits.
- `ShotEdit` — the pure shot-management operations.
- `PresetEdit` — the pure preset-management operations.
- `ProjectStore` — loads and saves one `.tingraproject` document.
- `WindowCloseCommands` — File ▸ Close, ⌘W, for the secondary windows.
- `ProjectCommands` — the File menu's project items.
- `ProjectFilePanel` — the open and save panels for project documents.
- `NewProjectName` — the pure numbered name New Project… suggests.
- `NewProjectNameSuggester` — renumbers that name per folder in the panel.
- `ProjectSwitch` — the pure rule refusing a project switch while on air.
- `MonitorView` — the `MTKView` drawing one `MonitorFrameSource`.
- `MonitorFrameSource` — the seam a monitor reads its frames through.
- `MonitorFrameStamp` — one frame's identity: its buffer and time.
- `LayerMonitorSource` — the layer monitor's frames, through the chain.
- `MonitorTile` — the framed monitor: fitted video, tally border, badges.
- `MonitorRenderContext` — the one Metal device and `CIContext` monitors share.
- `InputGridView` — the multiview window's grid of running inputs.
- `ShotBankView` — the shot bank: one tile per shot of the active preset.
- `ShotBankTile` — the pure tile derivation behind the shot bank.
- `ShotThumbnailSource` — a bank tile's frames: the whole shot composed.
- `AddShotMenu` — the Add Shot menu beside the Shots heading.
- `AddShotMenuItems` — the Add Shot items every surface shares.
- `AddShotMenuSurface` — which surface the items are on, for `tap` names.
- `DraggedInput` — the `Transferable` payload of a dragged sidebar input.
- `MultiviewView` — the multiview window: program, preview, and inputs.
- `InputFrameSource` — one input's latest frame, for a multiview tile.
- `MultiviewTile` — the pure tile derivation and its tally rule.
- `Tally` — the red and green tint pair every tally draws from.
- `MultiviewCommands` — the View-menu command opening multiview, ⌥⌘M.
- `ProgramCommands` — the Program menu: size, frame rate, and snapshots.
- `ProgramSize` — the named program sizes, from SD to 4K.
- `ProgramFormatChoice` — the offered sizes, frame rates, and labels.
- `ProgramFormatProblem` — why a typed program format is refused.
- `ProgramFormatSheet` — the Custom Size… sheet.
- `ShotCommands` — the Shots menu: Add Shot, then each shot, ⌘1–⌘9.
- `PresetCommands` — the Presets menu: Add Preset, then each preset.
- `ProgramLayout` — the pure arrangement that seeds a fresh project's shots.
- `ProductionShortcut` — the closed list of production keyboard shortcuts.
- `SettingsView` — the settings window: a pane list beside the open pane.
- `SettingsPane` — the closed list of built-in settings panes.
- `SettingsSelection` — what the list selects: a built-in or plug-in pane.
- `SettingsCommands` — the app-menu Settings… item, ⌘,.
- `GeneralSettingsView` — the General pane: appearance, status bar, snapshots.
- `StreamingSettingsView` — the Streaming pane: destinations and status.
- `AppearancePicker` — the three-thumbnail appearance control.
- `AppearanceSwatch` — one appearance thumbnail.
- `AppearanceMiniDesktop` — the miniature desktop a thumbnail draws.
- `ShortcutsSettingsView` — the read-only Shortcuts pane.
- `ShortcutRow` — one shortcut's row in that pane.
- `PermissionsSettingsView` — the Permissions pane, one row per grant.
- `PermissionRow` — one permission's row: use, status, and actions.
- `StatusLabel` — a permission's status as a colored symbol and a word.
- `PermissionsModel` — the observable record of what TCC allows.
- `DataSettingsView` — the Data pane: everything Tingra saved on this Mac.
- `AppDataRow` — one kind of saved data: its name, amount, and place.
- `AppDataModel` — the observable inventory and removal behind the pane.
- `AppDataStore` — finds and removes everything the app saves.
- `AppDataKind` — the closed list of kinds of saved data.
- `AppDataItem` — one kind's inventory: its count and size.
- `AppDataRemovalFailure` — a kind that was not removed, and why.
- `LoggingSettingsView` — the Logging pane: reveal, share, and clear.
- `LogSnapshot` — a `Transferable` dated copy of the log file.
- `LogFileModel` — the observable log size, snapshot, and clear.
- `PlugInsSettingsView` — the Plug-ins pane, one row per plug-in.
- `PlugInRow` — one plug-in's row: name, version, toggle or refusal.
- `SafeModeBanner` — the banner topping the Plug-ins pane in safe mode.
- `ManagePlugInsSheet` — the sheet hosting the system's extension switches.
- `AppExtensionBrowser` — the `EXAppExtensionBrowserViewController` wrapper.
- `PlugInListing` — the pane's rows as a value, both tiers joined by id.
- `BundleStanding` — what a bundle's row offers: a toggle or a refusal.
- `PlugInEnablementModel` — the observable model behind the toggles.
- `LogFileCommands` — the Help menu's Share Log File… item.
- **Log window** (`LogWindow/`) — the live, filterable view of the log:
  - `LogWindowModel` — the observable lines: loaded, live, and paused.
  - `LogWindowFilter` — what shows: levels, taps, domain, launch, search.
  - `LogLaunchScope` — all launches, or this one.
  - `LogWindowLine` — a loaded line with a unique identity.
  - `LogLaunchGroup` — a run of consecutive lines from one launch.
  - `LogWindowPreferences` — the level, tap, and launch choices, per Mac.
  - `LogWindowSink` — the `EventSink` attached while the window is open.
  - `LogWindowView` — the window: line table, detail, and toolbar filters.
  - `LogLineTable` — the lines, as an AppKit `NSTableView`.
  - `LogLineTableRow` — a table row with a stable identity.
  - `LogLineTableChange` — the change between two sets of rows.
  - `LogLineTableView` — the `NSTableView` subclass answering Copy.
  - `LogWindowCommands` — the Window ▸ Log menu item.
- `AboutSettingsView` — the About pane: icon, name, version, and uptime.
- `AppearanceMode` — System, Light, or Dark.
- `AppearancePreferences` — where the appearance choice persists.
- `AppearanceModel` — installs the matching `NSAppearance` on the app.
- `AppearanceTarget` — the one-property seam it installs through.
- `AppVersion` — the pure version text the About pane prints.
- `AppUptime` — the pure uptime wording the About pane prints.

## `apps/tingra-cameras`

An app, so it exposes no public API beyond its `@main` entry; its internal
surface is:

- `TingraCamerasApp` — the `@main` entry owning the shared model.
- `ContentView` — the `NavigationSplitView` two-column layout.
- `SidebarView` — the Cameras and Microphones sidebar list.
- `PreviewCanvasView` — the panel centering the 16:9 preview frame.
- `CameraPreviewView` — the video view: a placeholder or a live feed.
- `HardwareModel` — the observable device selection state.
- `Device` — one camera or microphone the picker lists.
- `DeviceKind` — whether a device is a camera or a microphone.
