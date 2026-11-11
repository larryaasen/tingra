# Tingra: Who Streams, and What They Need

**Status: first draft, 2026-11-11.** A working list for checking the feature
set against the people who would use it. Each persona below says who they are,
what they set up, and what they need, with Tingra's answer today. The personas
run from the simplest setup to the most complex. The status of each need comes
from the docs as they stand (README.md, ARCHITECTURE.md, TODO.md, DONE.md,
CLI.md, MCP.md, DESTINATIONS.md, UVC.md, PLUGINS.md); a need with no record in
them counts as missing.

**One gap sits above all the others.** `Tingra.app` has not shipped. Today a
user can install `tingra-cli` and Tingra Cameras with Homebrew, and the CLI
streams one camera and one microphone, with no shots and no compositing. Every
persona from 1 to 6 needs the app, so for them every ✅ below means "built in
the app, waiting on its release" (TODO.md, "Release Tingra.app").

**Key:** ✅ has it · 🟡 has part of it, or a workaround · ❌ missing.
"Planned" means TODO.md or a design record already tracks it.

## At a glance

| # | Persona | Typical setup | Fit today |
|---|---|---|---|
| 1 | Solo talker | One webcam, one mic, one service | Strong |
| 2 | Teacher or presenter | Screen, face in a corner, slides, a recording | Good, with two big holes: Mac and app sound, and sending the program to a video call |
| 3 | Video podcaster | Two to four hosts, a mic and camera each, sometimes a remote guest | Fair: the mixer is good, voice processing and per-track recording are missing |
| 4 | Game streamer | Game capture, face cam, overlays, alerts, chat, several services | Weak: no game sound, no green screen, no web widgets, no global hotkeys |
| 5 | Worship or community volunteer team | Several cameras, lyrics and titles, a weekly show run by rotating volunteers | Fair: switching and safety are good, titles, macros, and schedules are missing |
| 6 | Live event producer | Many cameras, multiview, contribution over SRT, replays, graphics | Fair on switching, weak on what a crew expects: ISO recording, replay, NDI, tally |
| 7 | Automation and agent operator | No screen; scripts, a daemon, or an AI agent run the stream | Strong, and where Tingra stands apart |
| 8 | Plug-in developer | Builds inputs, effects, outputs, or app panes for others | Strong design, waiting on the SDK's first publish and 1.0 |

## 1. Solo talker

Talks to camera: a weekly update, a coach's Q&A, a chat stream. One camera, one
microphone, one service. Wants to press one button and be live, and to trust
that nothing will go wrong.

| Need | Status | Notes |
|---|---|---|
| Pick a camera and a microphone | ✅ | Sidebar and mixer; the CLI's `--camera` and `--mic` |
| Go live without knowing server URLs | ✅ | Destination templates: Twitch, YouTube, Facebook Live |
| Keep the stream key safe | ✅ | Keychain storage; keys never reach a log |
| One clear Go Live control and on-air state | ✅ | Start Streaming (⌘G), the status bar |
| Keep a copy of the show | ✅ | Local recording, separate from streaming |
| Fix the webcam's picture (exposure, white balance, focus) | 🟡 | In Tingra Cameras; not yet in the main app (TODO.md, UVC) |
| Blur or replace the background without a green screen | 🟡 | Only macOS's own camera effects; nothing in Tingra |
| Come back after a crash | ✅ | Resume Stream offer after a crash while live |
| A simple first run | 🟡 | The app opens as a full switcher; no simple mode or setup guide on record |

## 2. Teacher or presenter

Teaches a class, runs a webinar, or makes software tutorials. Shows a screen or
one window with their face in a corner, flips between slides, a demo, and a
full-face shot, and often records for later rather than going live.

| Need | Status | Notes |
|---|---|---|
| Capture a display or one window | ✅ | ScreenCaptureKit display and window inputs |
| Face in a corner, rounded, cropped | ✅ | Layers, the Frame and Crop effects |
| Flip between slides, demo, and face | ✅ | Shots, ⌘1–⌘9, Take on Return |
| Slides, images, and text as inputs | ✅ | Media plug-in: images, video files, text, Markdown |
| Play a video file with its sound | ✅ | Video file input with its own channel strip |
| Hear the Mac's or an app's sound (a demo clip, a web page) | ❌ | No system or app audio input; a loopback audio device seen as a mic is the only way |
| Send the program into a video call as a camera | ❌ | No virtual camera output |
| Speaker notes beside the program | 🟡 | The Notes plug-in pane; no prompter |
| Record for upload later | ✅ | `.mov`/`.mp4`, the Library's Recordings tab |
| Captions | ❌ | Not on record |
| Draw or point on the screen | ❌ | Not on record |

## 3. Video podcaster

Two to four hosts around a table, each with a mic and often a camera, sometimes
a guest who calls in. Cares most about sound, and edits the recording after.

| Need | Status | Notes |
|---|---|---|
| A strip per mic: fader, mute, pan, meter | ✅ | The console mixer, in dB |
| Headphone mix for the operator | ✅ | The monitor path to a chosen output device |
| Clean up voices: compressor, limiter, gate, EQ, noise removal | 🟡 | Only gain, high-pass, and low-pass today |
| Listen to one mic alone (solo) | ❌ | Planned: solo as pre-fade listen |
| Line up sound with slow cameras (sync offset) | ❌ | Planned: designed in CLOCK.md, not built |
| Sound that follows the shot | ✅ | Audio follows video |
| Cut to whoever is talking, on its own | ❌ | Not on record |
| A remote guest calling in | ❌ | No call-in path; WHIP/WHEP waits on `RTCHaishinKit` |
| A track per mic in the recording | ❌ | The recording holds the stereo program mix only |
| A file per camera (ISO recording) | ❌ | Not on record |
| Name titles (lower thirds) | 🟡 | A text file as a layer; no title templates |
| Stream to several services at once | ✅ | One program, many destinations |

## 4. Game streamer

Plays a game on the same Mac, with a face cam, a logo, alerts for new
followers, the chat on screen, and switches between "playing", "be right back",
and "just talking". Often streams to more than one service, and makes short
portrait clips.

| Need | Status | Notes |
|---|---|---|
| Capture the game's window or display | ✅ | Window and display inputs |
| Game sound and voice-chat sound | ❌ | No system or app audio input: the biggest gap for this persona |
| Face cam, cropped, framed | ✅ | Crop and Frame effects |
| Green screen (chroma key) | ❌ | GLOSSARY.md names keying; no effect yet |
| Background removal without a green screen | ❌ | Not on record |
| A logo or frame above every shot | 🟡 | A layer in each shot; no overlay that sits above all shots |
| Alerts, chat, goal bars (web widgets) | ❌ | No web page input |
| Switch shots while the game has focus | ❌ | ⌘1–⌘9 work only while Tingra is in front; no global hotkeys |
| A button deck or other control surface | 🟡 | Nothing direct; MCP tools (`shot_take`, `preview_set`) could drive one |
| Video transitions (stingers) | ❌ | Cut, dissolve, wipe, and shader transitions only |
| Several services at once | ✅ | Multiple destinations, each with its own reconnect |
| Landscape and portrait at the same time | ❌ | Portrait sizes exist, but one program format per show |
| Save the last 30 seconds (replay buffer) | ❌ | Not on record |
| Low cost while the game runs | ✅ | GPU-resident frames, hardware compression |

## 5. Worship or community volunteer team

A church, a school, a town council. Two to five cameras, often through capture
cards; a computer showing lyrics or slides; a house mixing desk feeding sound
in. The same show every week, run by whichever volunteer turned up.

| Need | Status | Notes |
|---|---|---|
| Several cameras, capture cards included | ✅ | Capture cards appear as cameras |
| Pan, tilt, and zoom a camera | 🟡 | USB cameras in Tingra Cameras; not in the main app; no network camera control |
| The same setup every week | ✅ | Projects, presets, shots, autosave |
| Preview, then take; fade to black | ✅ | Preview and program, Take on Return, ⇧⌘B |
| Sound from the house desk | ✅ | An audio interface appears as an input |
| Lyrics and scripture on screen | 🟡 | Text and Markdown files; no lyric or slide feed, no title templates |
| A feed from the slides computer over the network | ❌ | Planned: NDI as an external plug-in |
| A countdown before the start | ❌ | Not on record |
| Start at a set time | ❌ | Not on record |
| One button for "record, go live, show welcome" | ❌ | GLOSSARY.md defines macros; not built |
| Simple for a new volunteer each week | 🟡 | Shortcuts follow common switcher keys; macros and a simple mode would help most |
| Line up sound with the cameras | ❌ | Planned: sync offset, not built |
| Survive a crash mid-service | ✅ | Resume Stream offer, autosave |
| The app in Spanish or German | ✅ | English, German, Spanish |
| Captions for those who cannot hear | ❌ | Not on record |

## 6. Live event producer

Sports, conferences, weddings, concerts: a small crew, many cameras, sometimes
a feed sent to a far site over SRT. Expects the tools of a broadcast
switcher.

| Need | Status | Notes |
|---|---|---|
| See every input at once (multiview) | ✅ | Multiview window with tally |
| Preview and program, many transitions | ✅ | Cut, dissolve, wipe, shaders |
| Up to 4K, up to 60 frames a second | ✅ | Program format menu |
| Send over SRT | 🟡 | SRT output works; a dropped SRT link is never reported, so it never reconnects (TODO.md) |
| Send to several services, each reconnecting | ✅ | Multiple destinations |
| A file per camera (ISO recording) | ❌ | Not on record |
| Instant replay | ❌ | Not on record |
| Scoreboards and data-driven graphics | ❌ | No title engine or web page input |
| NDI in and out | ❌ | Planned: an external plug-in |
| Tally lights on the cameras | ❌ | Not on record |
| Delay a slow input's sound | ❌ | Planned: sync offset, not built |
| Solo, sends, and extra buses for crew feeds | ❌ | Planned as later mixer slices |
| A log to review after the show | ✅ | Log window, log file, stream history |
| A hardware control surface | ❌ | Not on record |

## 7. Automation and agent operator

No one sits at the switcher. A script runs a stream around the clock, a lab
streams a camera, a developer tests a streaming server, or an AI agent runs the
show on spoken orders: "go live to my Twitch", "take the wide shot".

| Need | Status | Notes |
|---|---|---|
| Stream from the command line | ✅ | `tingra-cli stream`, one camera and one mic |
| Stable machine-readable output | ✅ | `--json` events and exit codes as a contract |
| Reconnect on its own | 🟡 | RTMP yes; SRT drops go unseen |
| Run as a background service | ✅ | `serve`, started by launchd on demand |
| Let an AI agent drive it | ✅ | MCP server: stream, record, destinations, devices |
| Find a destination by name | ✅ | `destinations_list`, operator-wide store |
| Drive the app's shots from an agent | ✅ | `preview_set`, `shot_take`, and the `program_*` tools |
| Shots and compositing without the app | ❌ | The CLI has no compositor; display, window, and shots are app-only |
| Let the agent see the program | ❌ | Planned: a `program.snapshot` tool |
| Run steps when an event fires | ❌ | Macros not built |
| Test without hardware | ✅ | Bars, tone, black, PLUGE generators |

## 8. Plug-in developer

Builds what Tingra does not: an NDI input, a new streaming protocol, an effect,
a rundown pane, a chat panel. Needs a stable API and a way to reach users.

| Need | Status | Notes |
|---|---|---|
| A stable, versioned API | 🟡 | SemVer and Library Evolution; 0.x until NDI, then 1.0 |
| A binary SDK to build against | 🟡 | Built; the first public publish waits on Larry (TODO.md) |
| Add inputs, effects, outputs, and MCP tools | ✅ | Host-tier `*.tingraplugin` bundles |
| Add panes, windows, commands, and status items | ✅ | App-tier ExtensionKit plug-ins |
| Read the app's meters and video | ✅ | `tingra/meters`, `tingra/frame` |
| Store secrets and data | ✅ | Plug-in secrets in the Keychain, project and app storage |
| Settings drawn for you | ✅ | Declared `Parameter`s become a native settings pane |
| Safe when a plug-in crashes | ✅ | Load-crash guard, safe mode, out-of-process app tier |
| A worked example | ✅ | The Notes plug-in, the fixture plug-in |
| A place to list and share plug-ins | ❌ | Planned: the plug-in gallery, proposed |

## The gaps, ranked by how many personas they block

| Gap | Blocks | Tracked? |
|---|---|---|
| Release `Tingra.app` | 1–6 | Yes, TODO.md |
| System and app audio capture | 2, 3, 4 | No |
| Voice processing: compressor, limiter, gate, EQ, noise removal | 3, 4, 5, 6 | No |
| Overlays above every shot, and title templates | 3, 4, 5, 6 | Defined in GLOSSARY.md only |
| Macros, global hotkeys, and control surfaces | 4, 5, 6, 7 | Macros defined in GLOSSARY.md only |
| ISO and per-track recording | 2, 3, 6 | No |
| Remote guests | 2, 3, 6 | WHIP/WHEP waits on `RTCHaishinKit` |
| Sync offset | 3, 5, 6 | Yes, CLOCK.md |
| Captions | 2, 5, 6 | No |
| Chroma key and background removal | 1, 2, 4 | Keying defined in GLOSSARY.md only |
| Virtual camera output | 2, 3 | No |
| Web page input (alerts, chat, scoreboards) | 4, 6 | No |
| NDI | 5, 6 | Yes, TODO.md |
| Replay | 4, 6 | No |
| Scheduled start and countdown | 5 | No |

Where Tingra already leads: a native Mac app with a GPU-resident path, several
services at once with per-destination reconnect, recovery after a crash, and,
above all, control by scripts and AI agents through the CLI and MCP, where
Tingra stands apart. The plug-in design gives persona 8 a path to fill the
gaps above without waiting on the core.
