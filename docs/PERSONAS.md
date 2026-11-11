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
persona from 2 to 11 needs the app, so for them every ✅ below means "built in
the app, waiting on its release" (TODO.md, "Release Tingra.app").

**Key:** ✅ has it · 🟡 has part of it, or a workaround · ❌ missing.
"Planned" means TODO.md or a design record already tracks it.

## At a glance

| # | Persona | Typical setup | Fit today |
|---|---|---|---|
| 1 | Set-and-forget camera | One camera, always on, no one watching | Good for someone at home in a terminal; poor for anyone else |
| 2 | Recorder | One camera or one screen, recorded, never live | Strong in the app; the CLI cannot record without streaming |
| 3 | Solo talker | One webcam, one mic, one service | Strong |
| 4 | Audio show | Mics, music, a still picture; sound is the show | Weak: no audio files, no playlist, no limiter |
| 5 | Screen streamer | A screen or one window and a voice: live coding, drawing, a walkthrough | Strong, until the Mac's own sound is needed |
| 6 | Musician | An instrument and a voice through an audio interface, a camera or two | Fair: the interface works; level control and sync do not exist yet |
| 7 | Teacher or presenter | Screen, face in a corner, slides, a recording | Good, with two big holes: Mac and app sound, and sending the program to a video call |
| 8 | Video podcaster | Two to four hosts, a mic and camera each, sometimes a remote guest | Fair: the mixer is good, voice processing and per-track recording are missing |
| 9 | Game streamer | Game capture, face cam, overlays, alerts, chat, several services | Weak: no game sound, no green screen, no web widgets, no global hotkeys |
| 10 | Worship or community volunteer team | Several cameras, lyrics and titles, a weekly show run by rotating volunteers | Fair: switching and safety are good, titles, macros, and schedules are missing |
| 11 | Live event producer | Many cameras, multiview, contribution over SRT, replays, graphics | Fair on switching, weak on what a crew expects: ISO recording, replay, NDI, tally |
| 12 | Automation and agent operator | No screen; scripts, a daemon, or an AI agent run the stream | Strong, and where Tingra stands apart |
| 13 | Plug-in developer | Builds inputs, effects, outputs, or app panes for others | Strong design, waiting on the SDK's first publish and 1.0 |

## Which personas Tingra serves best

Of the simple setups, Tingra serves three well today: the **solo talker** (3),
the **recorder** (2), and the **screen streamer** (5). They share a shape: one
or two video inputs, a voice from a microphone, no sound from the Mac itself,
and no web graphics. Inside that shape nearly every need is ✅.

The other low-end personas each fall on one missing piece. The **audio show**
(4) has no way to play music files or a playlist. The **musician** (6) has no
limiter and no sync offset. The **set-and-forget camera** (1) works, but only
for someone who can write a terminal command and keep it running; nothing
starts it at login. And the shape breaks for anyone who needs the Mac's own
sound, which is why personas 4, 5, 7, 8, and 9 all list that gap.

## 1. Set-and-forget camera

A bird feeder, a fish tank, a building site, a parking lot, a barn at
lambing time. One camera, sometimes a microphone, streaming day and night
to one service. No one watches the Mac; the owner checks in once a day, if at
all.

| Need | Status | Notes |
|---|---|---|
| Stream one camera, with or without sound | ✅ | `tingra-cli stream`, `--no-audio` |
| Keep the Mac awake while streaming | ✅ | A running `stream` holds off idle and display sleep |
| Reconnect after a network drop | 🟡 | `--reconnect <n>` per destination; a count, not "forever", and SRT drops go unseen |
| Start on its own at login or after a power cut | ❌ | Nothing starts `stream` at login; the owner would write their own launchd job |
| Set it up without a terminal | ❌ | The app streams, but has no unattended mode or start at launch |
| Recover when the camera is unplugged and plugged back in | 🟡 | Device events are reported; recovery of a running CLI stream is not on record |
| Check health from afar | 🟡 | `--json` stats and `--log-file`; nothing pushes a notice when it stops |
| A date and time stamp on the picture | ❌ | Only the bars generator carries a timecode |
| Low power, cool Mac | ✅ | Hardware compression, GPU-resident frames |

## 2. Recorder

Never goes live. Makes a talking-head update, a screen walkthrough for a
teammate, a lesson to upload later. Wants to press Record, press Stop, and
find the file.

| Need | Status | Notes |
|---|---|---|
| Record without streaming | 🟡 | Yes in the app; `tingra-cli` cannot, since `stream` needs a `--url` |
| Camera, screen, or both in one picture | ✅ | Shots and layers in the app |
| Choose `.mov` or `.mp4` | ✅ | |
| Find the take afterwards | ✅ | The Library's Recordings tab: Quick Look, Reveal in Finder |
| Warn before the disk fills | ✅ | A free-space check before recording starts |
| Keep the file if Tingra quits | 🟡 | The file is written in fragments, so a take survives a force quit; a few dropped frames are still under study (TODO.md) |
| Pause and resume a take | ❌ | Not on record |
| Smaller files (HEVC) | 🟡 | `--video-codec hevc` in the CLI; the app records H.264 only |
| Trim the ends | ❌ | Not on record |
| Name titles, a logo | 🟡 | Text and image files as layers |

## 3. Solo talker

Talks to camera: a weekly update, a coach's Q&A, a chat stream. One camera, one
microphone, one service. Wants to press one button and be live, and to trust
that nothing will go wrong.

| Need | Status | Notes |
|---|---|---|
| Pick a camera and a microphone | ✅ | Sidebar and mixer; the CLI's `--camera` and `--mic` |
| Use an iPhone as the camera | ✅ | Continuity Camera appears as a camera; it has no picture controls (UVC.md) |
| Go live without knowing server URLs | ✅ | Destination templates: Twitch, YouTube, Facebook Live |
| Keep the stream key safe | ✅ | Keychain storage; keys never reach a log |
| One clear Go Live control and on-air state | ✅ | Start Streaming (⌘G), the status bar |
| Keep a copy of the show | ✅ | Local recording, separate from streaming |
| Fix the webcam's picture (exposure, white balance, focus) | 🟡 | In Tingra Cameras; not yet in the main app (TODO.md, UVC) |
| Blur or replace the background without a green screen | 🟡 | Only macOS's own camera effects; nothing in Tingra |
| Come back after a crash | ✅ | Resume Stream offer after a crash while live |
| A simple first run | 🟡 | The app opens as a full switcher; no simple mode or setup guide on record |

## 4. Audio show

A radio-style show, a DJ set, a sermon or reading streamed as sound, a talk
show with no cameras. Mics and music carry it; the picture is a still image,
a logo, or black.

| Need | Status | Notes |
|---|---|---|
| Stream sound with a still picture | ✅ | An image file as a layer, or the black generator |
| Sound only | 🟡 | `tingra-cli stream --no-video`; some services refuse a stream with no video |
| Several mics on faders | ✅ | The console mixer |
| Play music files (MP3, AAC, WAV) | ❌ | Video files with sound play; audio-only files are not an input |
| A playlist, or play a clip on a button press | ❌ | A staged video loops from the moment it is staged; once-only play is a planned slice |
| Music from a music app on the Mac | ❌ | No system or app audio input |
| A limiter so the stream never clips | ❌ | Gain, high-pass, and low-pass only |
| Talk over the music (ducking) | ❌ | Not on record |
| A higher audio bit rate | 🟡 | `--audio-bitrate` in the CLI; no app setting on record |

## 5. Screen streamer

Codes live, draws, edits a photo, plays chess online, walks through a
spreadsheet. The screen or one app's window is the picture; a voice explains
it; a small face cam is optional.

| Need | Status | Notes |
|---|---|---|
| Capture a display or one window | ✅ | One window keeps the rest of the desktop private |
| A voice from a mic | ✅ | |
| A small face cam in a corner | ✅ | Layers, Crop, Frame |
| Text sharp enough to read | ✅ | Program format up to 4K; the bit rate rises with the size |
| The Mac's or an app's sound (a build's alert, a video, a game) | ❌ | No system or app audio input |
| Hide alerts and private windows from the picture | 🟡 | Window capture hides them; a whole-display capture shows them |
| Viewers' chat on screen | ❌ | No web page input |
| A "be right back" shot | ✅ | Shots, with an image or text layer |
| Switch shots while another app has focus | ❌ | No global hotkeys |

## 6. Musician

Plays guitar, keys, or a drum kit, and sings. Sound comes in through an audio
interface; one camera shows the player, another the hands. Sound quality
matters more than anything else.

| Need | Status | Notes |
|---|---|---|
| An audio interface as an input | ✅ | It appears as an input with its own strip |
| Choose which interface channels feed a strip | ❌ | Not on record |
| Headphone mix of the program | ✅ | The monitor path; most players will monitor from the interface |
| A limiter so a loud chord never clips | ❌ | Gain, high-pass, and low-pass only |
| Picture and sound in step | ❌ | Planned: sync offset, not built |
| Two cameras: the player and the hands | ✅ | Shots, multiview |
| A higher audio bit rate | 🟡 | `--audio-bitrate` in the CLI; no app setting on record |
| A separate track per instrument in the recording | ❌ | The recording holds the stereo program mix only |
| Several services at once | ✅ | Multiple destinations |

## 7. Teacher or presenter

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

## 8. Video podcaster

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

## 9. Game streamer

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

## 10. Worship or community volunteer team

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

## 11. Live event producer

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

## 12. Automation and agent operator

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

## 13. Plug-in developer

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
| Release `Tingra.app` | 2–11 | Yes, TODO.md |
| Voice processing: compressor, limiter, gate, EQ, noise removal | 4, 6, 8, 9, 10, 11 | No |
| System and app audio capture | 4, 5, 7, 8, 9 | No |
| Global hotkeys, macros, and control surfaces | 5, 9, 10, 11, 12 | Macros defined in GLOSSARY.md only |
| Overlays above every shot, and title templates | 8, 9, 10, 11 | Defined in GLOSSARY.md only |
| ISO and per-track recording | 6, 7, 8, 11 | No |
| Sync offset | 6, 8, 10, 11 | Yes, CLOCK.md |
| Web page input (alerts, chat, scoreboards) | 5, 9, 11 | No |
| Remote guests | 7, 8, 11 | WHIP/WHEP waits on `RTCHaishinKit` |
| Captions | 7, 10, 11 | No |
| Chroma key and background removal | 3, 7, 9 | Keying defined in GLOSSARY.md only |
| Recording and compression settings in the app: pause, HEVC, audio bit rate | 2, 4, 6 | No |
| Audio files, playlists, and play-once clips | 4, 10 | Play-once is a planned slice |
| Starting on its own: at login, or at a set time, with a countdown | 1, 10 | No |
| Virtual camera output | 7, 8 | No |
| Choosing channels on a multichannel audio interface | 6, 10 | Not on record |
| NDI | 10, 11 | Yes, TODO.md |
| Replay | 9, 11 | No |

Where Tingra already leads: a native Mac app with a GPU-resident path, several
services at once with per-destination reconnect, recovery after a crash, and,
above all, control by scripts and AI agents through the CLI and MCP, where
Tingra stands apart. The plug-in design gives persona 13 a path to fill the
gaps above without waiting on the core.
