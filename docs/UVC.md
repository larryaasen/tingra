# UVC: camera controls through the USB Video Class

**Status: approved 2026-10-27, built the same day.** This document owns the `TingraUVC` package, the three `TingraPlugInKit` additions it led to, the camera input's parameters, and the Tingra Cameras controls panel. The public types are listed in [TYPES.md](TYPES.md); the package is described in [README.md](../README.md).

## The problem

Operators adjust a webcam's picture — brightness, contrast, white balance, exposure, focus, zoom — and macOS gives an app almost no way to do it. AVFoundation on the Mac exposes only a lock/continuous-auto switch for exposure and focus, and only on some cameras; it has no brightness, contrast, saturation, sharpness, gain, or white balance temperature at all. Measured 2026-10-26 on the dev Mac: the Razer Kiyo Pro supports locked/continuous exposure and focus and nothing else through AVFoundation; the FaceTime HD Camera and a Continuity Camera support nothing.

Utilities that do offer these controls (the screenshot that prompted this work shows one) talk to the camera directly over USB. Almost every external webcam is a **USB Video Class (UVC)** device, and the UVC specification defines a standard set of controls that any app can read and set with class-specific control requests on the camera's VideoControl interface — no driver, no vendor SDK. Larry's Dart package [`uvc`](https://pub.dev/packages/uvc) does exactly this through libusb for Flutter apps on macOS and Windows.

## What the probe measured

A throwaway probe on 2026-10-26 against the Razer Kiyo Pro (vendor `0x1532`, product `0x0E05`) settled the mechanism before any design:

- **`IOUSBHost` opens the camera's device object without seizing it**, while the camera is streaming in another process, and with no TCC prompt — USB control transfers are not camera capture. No entitlement is needed for a non-sandboxed, hardened-runtime app.
- **The configuration descriptor names the controls.** The camera terminal advertises `bmControls` `2e 0a 02` (auto exposure mode and priority, exposure time, focus, zoom, pan/tilt, focus auto); the processing unit advertises `5b 17` (brightness, contrast, saturation, sharpness, white balance temperature, backlight compensation, gain, power line frequency, white balance temperature auto). Requests for an unadvertised control (hue, gamma) stall, as the specification says they should.
- **Ranges come from the camera.** Brightness, contrast, saturation, sharpness, and gain read `0…255` (default 128, gain 0); white balance temperature `2000…7500` K (default 5000); exposure time `3…2047` (100 µs units); focus `0…600`; zoom `100…400`. The current values matched the other utility's sliders exactly.
- **`SET_CUR` works**: writing brightness's current value back succeeded and read back unchanged.
- **The `AVCaptureDevice.uniqueID` of a UVC camera encodes its USB address**: `0x211100015320e05` is the location ID `0x02111000` printed as `%x`, then the vendor and product IDs as four hex digits each. That is the bridge from a discovered camera to its USB device.

The built-in FaceTime HD Camera and Continuity Cameras are not UVC devices. They get no controls; there is nothing on macOS to drive.

## The decision: `TingraUVC`, a standalone package

**`packages/TingraUVC` (module `TingraUVC`) is a general-purpose UVC control library for the Mac** — the Swift counterpart of the Dart `uvc` package — living in the monorepo beside the engine.

- **Apple's `IOUSBHost`, not libusb.** The Dart package needed libusb through FFI to reach the bus; on the Mac `IOUSBHost` (macOS 10.15+) is the first-party way to send control requests, so the package takes no third-party dependency (CLAUDE.md: prefer native frameworks).
- **Standalone.** It depends on no Tingra package — not the plug-in kit, not the event bus — so any Mac app can import it to control a UVC camera, exactly as a Flutter app imports `uvc`. It is an ordinary static library, not a Library Evolution kit, so the plug-in API stability rules do not bind it. Inside it, UVC's own vocabulary (camera terminal, processing unit, control, selector) is used, because it is an explicit external protocol boundary (GLOSSARY.md permits this).
- **One seam: `UVCTransport`.** Every byte that crosses USB goes through a transport — a connection that reads the configuration descriptor and sends class-specific control requests. The production transport is `IOUSBHost`; tests drive the package through a scripted transport, so descriptor parsing, value encoding, and every error path are unit tested with no camera attached (CLAUDE.md, Testing).
- **The device is opened per exchange, never held.** A transport opens the device for one exchange — describing a camera, reading a value, writing a batch — and closes it at the end. Tingra therefore never holds a camera that another app (a vendor utility, the other Tingra app) wants to adjust, and a camera that disconnects mid-session leaves no open handle behind.
- **Synchronous, throwing calls.** A UVC control request is a short blocking control transfer bounded by a timeout, so the API is synchronous like the Dart package's property accessors; the types are `Sendable` values. Callers run it off the main actor. Every failure throws a `UVCError` whose description names the cause and the fix — never a crash.

### The API

| Type | What it is |
|---|---|
| `UVCDevice` | A connected UVC camera found in the I/O Registry: name, vendor ID, product ID, USB location ID. `UVCDevice.all()` lists them; `UVCDevice.matching(captureDeviceUniqueID:)` finds the one behind an `AVCaptureDevice`. |
| `UVCCamera` | A described camera: the controls its descriptors advertise, each with its range read once. `UVCCamera(device:)` opens, describes, and closes. `camera.brightness`, `camera.zoom`, … return the control, or `nil` when the camera does not have it. |
| `UVCControl` | One control: its kind, `minimum`, `maximum`, `resolution`, `defaultValue`, and capabilities, plus `value()` and `setValue(_:)` for the current setting and `isDisabledByAutomaticMode()`. |
| `UVCControlKind` | The catalog of standard controls the package knows: where each lives (camera terminal or processing unit), its selector, its advertising bit, and its wire layout. |
| `UVCControlCapabilities` | The `GET_INFO` bits: supports get, supports set, disabled by an automatic mode, autoupdate, asynchronous. |
| `UVCAutoExposureMode` | The auto exposure mode bitmap: manual, auto, shutter priority, aperture priority. |
| `UVCTransport` / `UVCConnection` | The seam: a connection that reads the configuration descriptor and sends one control request. |
| `UVCRequest` / `UVCRequestCode` | One class-specific control request and its request code (`SET_CUR`, `GET_CUR`, `GET_MIN`, …). |
| `UVCError` | Every failure, with a developer-facing description. |

The naming departs from the Dart package in one place: there `UVCControl` is the open camera and its properties are the controls; here the camera is `UVCCamera` and each control is a `UVCControl`, which reads more naturally in Swift.

The catalog covers the standard processing unit and camera terminal controls a webcam advertises: brightness, contrast, hue, saturation, sharpness, gamma, gain, white balance temperature and its auto switch, backlight compensation, power line frequency, auto exposure mode and priority, exposure time, focus and its auto switch, zoom, pan, and tilt (pan and tilt share one 8-byte control on the wire; the package reads and writes each half without disturbing the other). A control the camera advertises but cannot describe (its range requests stall) is left out rather than reported with a made-up range. **Vendor extension units** (the Razer has two) are out of scope: their controls are vendor-specific and undocumented.

## The kit additions

Three additive changes to `TingraPlugInKit`, each with a default so every existing conformer and host is unchanged (ARCHITECTURE.md, "Plug-in API stability and versioning"):

1. **`Parameter.Kind.toggle`** — an on/off parameter, carried in the payload as a JSON boolean, created with `Parameter(key:name:defaultIsOn:)` and read with `isOn(in:)`. A host draws a switch. The camera's three Auto switches (exposure, white balance, focus) are the first.
2. **`Parameter.automaticToggleKey`**, set with `controlledAutomatically(whenOn:)` — the key of a toggle that, while on, hands this parameter to the device's automatic control. A host disables the parameter's control while the toggle is on. White balance temperature is governed by Auto White Balance, exposure time by Auto Exposure, focus by Auto Focus.
3. **`Input.currentParameters()`** — the values an input holds right now, for a host with nothing stored. Default: an empty payload. **This is what keeps a host from resetting a camera.** Until now a host with no stored values handed an input an empty payload, which restores the declared defaults — right for a generator, whose settings live only in the host, but wrong for a camera, which keeps its own settings in firmware across apps. A camera reports its live values here, and a host with no stored payload applies those (changing nothing) instead of an empty one.

Alongside them, **`Parameter.step`** (set with `stepped(by:)`, read through `snapped(_:)`) declares the increment a number moves in, so a host's slider lands only on values the device takes — added after the first build showed a pan slider resting at -0.003° and reading "-0°", because the camera's pan moves in whole degrees. `ParameterScale` snaps every slider's value to it, and the camera input snaps what it writes. **`Parameter.section`** (set with `inSection(_:)`) names the heading a parameter belongs under, so a host groups a camera's Exposure, Image, White Balance, and Framing parameters without knowing what a camera is. And **`ParameterScale`** — the pure mapping between a parameter's value and a slider's travel that honors a logarithmic scale — moves from the app into the kit, because a second host (Tingra Cameras) now needs it; it was app code only because only one app drew sliders.

## The camera input's parameters

`TingraCapturePlugIns` depends on `TingraUVC`. When the AVFoundation capture plug-in discovers a camera, it looks for the UVC device behind its unique ID and, if there is one, describes it — a handful of control transfers, done once per discovery or connection, off the main actor. `CameraInput` then declares one `Parameter` per control it maps, in this order:

| Section | Key | Name | Control | Notes |
|---|---|---|---|---|
| Exposure | `exposureAuto` | Auto Exposure | auto exposure mode | toggle; on = the camera's own auto mode, off = manual |
| Exposure | `exposureTime` | Exposure Time | exposure time | ms (100 µs units ÷ 10), logarithmic; governed by `exposureAuto` |
| Exposure | `gain` | Gain | gain | governed by `exposureAuto` |
| Exposure | `backlightCompensation` | Backlight Compensation | backlight compensation | a toggle when its range is `0`…`1` |
| Exposure | `powerLineFrequency` | Power Line Frequency | power line frequency | choice: Disabled (`0`), 50 Hz (`1`), 60 Hz (`2`), and Auto (`3`) on a camera whose `GET_MAX` reaches it |
| Image | `brightness` | Brightness | brightness | |
| Image | `contrast` | Contrast | contrast | |
| Image | `saturation` | Saturation | saturation | |
| Image | `sharpness` | Sharpness | sharpness | |
| Image | `hue` | Hue | hue | degrees (hundredths ÷ 100) |
| Image | `gamma` | Gamma | gamma | |
| Image | `focusAuto` | Auto Focus | focus auto | toggle |
| Image | `focus` | Focus | focus | governed by `focusAuto` |
| White Balance | `whiteBalanceAuto` | Auto White Balance | white balance temperature auto | toggle |
| White Balance | `whiteBalanceTemperature` | Temperature | white balance temperature | K; governed by `whiteBalanceAuto` |
| Framing | `zoom` | Zoom | zoom | |
| Framing | `pan` | Pan | pan | degrees (arc-seconds ÷ 3600) |
| Framing | `tilt` | Tilt | tilt | degrees (arc-seconds ÷ 3600) |

Only the controls the camera advertises are declared, so a camera without hue shows no hue. Each parameter's range, default, and step are the camera's own (the step is `GET_RES` in display units: 1 for brightness, 10 K for white balance, 0.1 ms for exposure time, 1° for pan and tilt). A number control whose range is just `0`…`1` is declared as a toggle, since a two-position slider is a switch — the Razer's backlight compensation is one. Gain is governed by Auto Exposure because the camera reports it disabled while auto exposure runs. The keys are the stable payload names on the project contract. Auto exposure priority is not mapped yet.

**Power line frequency's reported range understates it.** The Razer answers `GET_MIN` 1 and `GET_MAX` 2, yet measured on 2026-10-30 it takes `SET_CUR` 0 (Disabled) and reads it back, and stalls on 3 (Auto). So `TingraUVC` treats the control as an option list starting at `0` (`UVCControlKind.Style.option`), with `GET_MAX` deciding how far up it goes, and the Razer offers Disabled, 50 Hz, and 60 Hz. Probing each value at discovery would disturb the camera, so a camera that rejects Disabled shows it anyway: the write is reported as an `input.parameterSet` error and the re-read after it puts the menu back.

- **`currentParameters()`** reads every mapped control's current value.
- **`setParameters(_:)`** writes only what changed since the last write or read, toggles first (so an Auto switch turned off releases its value before a manual value is written), and never writes a value while its Auto toggle is on — the camera owns it then. A rejected write is reported as an `input.parameterSet` error event naming the control and the camera's reason; the camera keeps running, and the value is tried again on the next apply.
- **`currentParameters()`** of a camera that cannot be reached reports an `input.parameterRead` error event and returns the values it was last known to hold, never an empty payload — an empty one would tell a host to restore the defaults.
- **Discovery** describes each camera once, when it is discovered or connects (about 25 ms for the Razer), and reports an `input.controls` trace with the parameter count — or an `input.controls` error when a UVC camera cannot be described, in which case the camera is still registered, just without controls.
- Values are snapped to the control's resolution and clamped to its range before they are written.

The camera's live automatic adjustments (an exposure time moving under Auto Exposure) are **not** followed: UVC offers no change notification a webcam reliably sends, and the project forbids polling. A host refreshes the values when the operator changes a toggle, which is when they matter.

## The Tingra Cameras controls panel

In the trailing sidebar, beside the preview (in the compact window, under it), the window shows the selected camera's parameters as a grouped `Form`: one `Section` per parameter section, a `Slider` with its value and unit under its name for each number, a switch for each toggle, a pop-up menu for each choice, and a governed slider disabled while its Auto switch is on. A slider rests only on the camera's steps and shows its value to the step's precision, and a **double-click returns it to the camera's default** — the reset convention the main app's pan slider and faders already use. The sliders are `NSSlider`s (`CameraSlider`) rather than SwiftUI `Slider`s, for the reason the main app's faders are: the slider tracks each click inside `mouseDown`, so a SwiftUI tap gesture beside it never saw the double-click, and Pan would not return to 0; the subclass catches the second click (`clickCount == 2`) itself. Every control writes straight to the camera through the input (the camera keeps the value until it is unplugged); the app stores nothing. **Reset All Controls**, at the end of the form, returns every control to the camera's defaults with an empty payload (an omitted key means its default), then reads the camera's values back; a dialog confirms it first, because it overwrites every value at once, and saved presets are unchanged, which is how to keep values worth returning to. A camera with no controls (the FaceTime HD Camera, a Continuity Camera) shows a short note instead. Each slider reports a `tap` when a drag ends or a double-click resets it, and each switch when it flips (EVENTS.md, "The `tap` convention").

**An Auto switch that owns one number shares that number's row.** White Balance's Temperature and Image's Focus each carry an **Auto** checkbox at the end of their slider row instead of a switch on a row of their own; the slider is disabled while it is checked. The rule is generic — a toggle that is the `automaticToggleKey` of exactly one number in its own section — so Auto Exposure, which owns both Exposure Time and Gain, keeps its own row.

The Framing row has no heading, because it names each of its sliders; in a window too narrow to fit them side by side, it stacks them. The parameters still declare the Framing section.

**Framing: Maps-style on the preview, numbers in the form (decided 2026-10-27).** Pan, tilt, and zoom are PTZ, so the app recognises the three by their stable keys (`pan`, `tilt`, `zoom`) and draws them two ways, both driving the same values:

- **Maps-style, on the preview.** Drag the picture to pan and tilt — it follows the pointer the way Maps' map does, so dragging right pans the camera left, and the preview's full width or height covers the whole range. Pinch on a trackpad, or Option-scroll, to zoom. A Liquid Glass capsule in the preview's corner holds zoom in, zoom out (a tenth of the range each), and reset framing, like Maps' zoom control; those buttons are also how VoiceOver and keyboard users reach it. The gestures are handled by the preview's own `NSView` (a SwiftUI overlay would take the scroll and pinch events from it). A gesture accumulates its movement unsnapped and sends snapped values, so small mouse movements still add up to whole steps.
- **One Framing row in the form.** Three compact sliders side by side, each with its name before it and its value after it, so the numbers stay visible while the preview is dragged; each double-clicks back to its default like every other slider.

A puck pad (a 16:9 pad whose puck is the pan and tilt, after the surround panners in Final Cut Pro and Logic Pro) was tried beside the Maps-style design the same day and dropped: the preview already is the pad. The preview's gestures and buttons report `cameraFraming.drag`, `.pinch`, `.scroll`, `.zoomIn`, `.zoomOut`, and `.reset` taps with the pan, tilt, and zoom they left; the sliders report `cameraParameter.slider` and `.reset` like the others. On the Razer, pan and tilt are digital: they only move the picture once it is zoomed in past 100.

Parameter and section names are supplied by the plug-in in English, like effect parameter names; the app's own strings are localized.

## Camera presets

**Built 2026-10-28.** Tingra Cameras saves the selected camera's control values as a named **camera preset** (GLOSSARY.md) and recalls them later — the main app's preset idiom, applied to camera settings, and the "Save / Update / Delete Profile" of the other utility under Tingra's vocabulary.

- **The data and its rules are in `TingraHost`**, so any front end that opens a camera can read them: `CameraPreset` (a name, the camera's id and name, and the parameter payload), `CameraPresets` (the list and its default, as a value holding the rules), and `CameraPresetStore` (`camera-presets.json` in Tingra's Application Support folder, beside `destinations.json`; an unreadable file is moved to `.unreadable`, as the stream history's is). The app keeps only the observable state on `HardwareModel` and the views in `Presets/`.
- **The default.** There is none until the first preset is saved, which becomes it. Any preset can be made the default; deleting the default hands the role to the first preset left, so while there are presets one is always the default.
- **At launch** the camera the operator last chose opens — remembered in the app's defaults by its identifier and name, matched the same way as a preset's — else the default preset's camera, else the first camera. The default preset's values are written to the camera that opens when it is the preset's own, before its controls are read, so the panel shows them from the start; a launch back onto another camera shows that camera as it is. A default preset whose camera is not connected reports a `cameraPreset.cameraAbsent` event (an unplugged camera is normal, not an error). Only the operator's choices are remembered — clicking a camera or recalling a preset — never the fallback to the first camera when the chosen one disconnects, so the chosen camera returns at the next launch it is connected for.
- **Finding the camera.** A preset finds its camera by id, else by name: a USB camera's `uniqueID` includes the port's location (the Razer's `0x211100015320e05`), so the same camera on another port keeps its presets. A preset whose camera is away is dimmed and cannot be recalled.
- **Recalling** a preset for the camera already showing writes the values without reopening it (no blink), then reads the camera back; for another camera it switches to that camera with the values written first. Either way the whole payload is written, and `setParameters` writes the Auto switches first and skips a value its Auto switch owns, so a payload read from a camera is safe to write back whole.
- **The UI.** A Presets section above the cameras in the sidebar (both sections collapse, as the main app's do) — name, camera, and a Default label; a click recalls — with Save Preset… on the section header's context menu and each row's context menu holding Recall, Set as Default, Update with Current Settings (only for the camera showing), Rename…, and Delete Preset… (confirmed; it cannot be undone). A Presets menu holds Save Preset…, one item per preset, and a Default Preset submenu. Every click reports its `tap` (`cameraPreset.row`, `cameraPresetSave.menu`, `cameraPresetDefault.menuItem`, …), and each change a `cameraPreset.saved`, `.applied` (`reason` `launch` or `recall`), `.defaultChanged`, `.renamed`, `.updated`, or `.deleted` event; a file that cannot be read or written is a `cameraPreset.read` or `cameraPreset.write` error event.

## The main app

The main app's load path applies `currentParameters()` to an input with no stored values instead of an empty payload — so opening a project no longer resets a camera's picture — and keeps those device-held values (`EngineModel.deviceInputParameters`, never written to the document) as what a settings editor shows and starts its first edit from. The Input Settings popover gains the toggle kind, the disabled state for a governed value, and section headings; both effect chain editors draw a toggle parameter as a switch (`EffectParameterToggle`, shared) and disable a governed number. A choice parameter is drawn the same way in all three, as a pop-up menu of its options (`EffectParameterPicker`, shared; 2026-11-07) — until then the editors fell through to the row meant for a kind newer than the app.

**The main app has no place to open a camera's controls yet.** Its Input Settings popover hangs off a mixer channel strip, and a camera has no strip. The natural home is the camera layer's inspector — a later slice.

## What the build measured

Checked on 2026-10-27 against the Razer Kiyo Pro on the dev Mac, beyond the unit tests (TingraUVC 46, TingraCapturePlugIns 134, TingraPlugInKit 84):

- `TingraUVC` alone described all 17 advertised controls in 25 ms; one write took under a millisecond.
- The engine path the apps use — `AVFoundationCapturePlugIn` → `CameraInput` — declared 15 parameters with the camera's ranges, read its live values, wrote brightness 95, read it back, and restored 87.
- Tingra Cameras, signed with the hardened runtime and no new entitlement, described the Razer at discovery (`input.controls … parameters=15`).
- The camera's own `GET_INFO` "disabled by automatic mode" bit is not trustworthy: the Razer reports its white balance temperature disabled while auto white balance is off. Tingra relies on the Auto toggles instead, never that bit.

## Not in this slice

- **Profiles** (the other utility's Save / Update / Delete Profile) arrived 2026-10-28 as camera presets (above). The main app does not use them yet: its project already persists input parameters.
- **Auto exposure priority** is not mapped, though the kit now has a choice kind.
- **Vendor extension units** and **relative controls** (`*_RELATIVE` selectors).
- **`tingra-cli`** does not expose camera parameters yet.
- **The main app's camera controls** (above): a camera layer's inspector.
