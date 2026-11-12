# Tingra: Who Streams, and What They Need

**Status: first draft, 2026-11-11.** A working list for checking the feature
set against the people who would use it. Each persona below says who they are,
what they set up, and what they need, with Tingra's answer today. The status
of each need comes from the docs as they stand (README.md, ARCHITECTURE.md,
TODO.md, DONE.md, CLI.md, MCP.md, DESTINATIONS.md, UVC.md, PLUGINS.md); a need
with no record in them counts as missing.

**The order is how easy each persona is to make successful.** The persona
Tingra already serves comes first, then those the app's release alone would
serve, then the rest by the size of the work still between them and success.
Each persona's section opens with a **To succeed** line naming that work. The
sizes are estimates read from the architecture, not measured:

- **S** — a plug-in or a setting on a seam that already exists, such as one
  more effect or media provider.
- **M** — new engine or app work on existing seams, such as a new input kind
  or a change to the mixer or compositor.
- **L** — a new subsystem or a new kind of output, such as titles, captions,
  or a virtual camera.
- **XL** — waits on something outside Tingra's control, or on a design
  decision not yet made.

**One step comes before all of this.** `Tingra.app` has not shipped. Today a
user can install `tingra-cli` and Tingra Cameras with Homebrew, and the CLI
streams one camera and one microphone, with no shots and no compositing. Every
persona except 1 and 6 needs the app, and so do plug-in developers building for
the app tier (5); for them every ✅ below means
"built in the app, waiting on its release" (TODO.md, "Release Tingra.app").
The sizes leave the release out, since every one of them shares it.

**Key:** ✅ has it · 🟡 has part of it, or a workaround · ❌ missing.
"Planned" means TODO.md or a design record already tracks it.

## At a glance

| # | Persona | Fit today | To succeed | Size |
|---|---|---|---|---|
| 1 | Automation and agent operator | Strong without the app, and where Tingra stands apart | Nothing, without the app; driving the app needs an agent connection to it | — / XL |
| 2 | Solo talker | Strong | Ship the app | — |
| 3 | Recorder | Strong in the app | Ship the app; a CLI `record` command | S |
| 4 | Screen streamer | Strong, until the Mac's own sound is needed | Ship the app; system and app audio for some | — / M |
| 5 | Plug-in developer | Strong design | Publish the SDK; app-tier plug-ins also need the app | — |
| 6 | Set-and-forget camera | Good for someone at home in a terminal | Reconnect without a limit, start at login | S, M |
| 7 | Audio show | Weak | Audio files, ducking; a limiter on the whole mix | S, M, M |
| 8 | Fitness or yoga instructor | Weak | Flip, audio files, ducking | S, S, M |
| 9 | Musician | Fair | An audio bit rate setting, channel choice, sync offset | S, M, M |
| 10 | Avatar streamer | Unknown | Check window transparency, or a chroma key | S or M |
| 11 | Reaction or watch-along streamer | Weak | System and app audio, ducking, clips that pause | M, M, M |
| 12 | Video podcaster | Fair | EQ and noise removal, automixer, a track per mic, sync offset | M to L |
| 13 | Teacher or presenter | Good, with two big holes | System and app audio, virtual camera, captions | M, L, L |
| 14 | Live seller | Weak to fair | Live titles, a web page input | L, L |
| 15 | Worship or community volunteer team | Fair | Lyric titles, macros, a scheduled start | L, L, M |
| 16 | Game streamer | Weak | Mac sound, chroma key, hotkeys, overlays, a web page input | M to L, many |
| 17 | Public meetings | Fair to weak | Automixer, captions, chapter marks | M, L, M |
| 18 | Company webinar or all-hands producer | Fair | Remote speakers, captions, branding | XL, L, M |
| 19 | Live event producer | Fair on switching, weak for a crew | ISO recording, replay, NDI, tally | Several L |
| 20 | Two-person team: talent and remote producer | Weak | A design decision, then remote control | XL |

## What the order shows

Five personas need no new feature: the **automation operator** (1) succeeds
today, the **solo talker** (2), **recorder** (3), and **screen streamer** (4)
succeed the day the app ships, and the **plug-in developer** (5) succeeds
the day the SDK is published for host-tier plug-ins, and the day the app
ships for app-tier ones. The first four share a shape: one or two video
inputs, a voice from a microphone, no sound from the Mac itself, and no web
graphics.

The next five (6 to 10) are each a few small pieces away, and most of those
pieces are plug-ins on seams that already exist: a flip effect and audio
files as a media provider (the dynamics effects and the time generators
were the first built). The larger pieces among
them, each M, are ducking, sync offset, and starting at login. That makes them
the cheapest personas to win next.

From 11 down, every persona needs at least one M or L feature, and the same
few recur: system and app audio, titles and overlays, captions, and a web page
input. Building those in that order would move most of the list at once.

## 1. Automation and agent operator

No one sits at the switcher. A script runs a stream around the clock, a lab
streams a camera, a developer tests a streaming server, or an AI agent runs the
show on spoken orders: "go live to my Twitch". Today the agent reaches the
daemon, which streams one camera; it cannot reach the app's shots.

**To succeed:** nothing, for streams run without the app; it works today. Driving the app (taking shots, starting the program's stream) needs an agent connection to the app, which does not exist and needs a design decision. **Size:** none, then XL. The other extras (an agent seeing the program, event-driven steps) are wanted, not blocking.

| Need | Status | Notes |
|---|---|---|
| Stream from the command line | ✅ | `tingra-cli stream`, one camera and one mic |
| Stable machine-readable output | ✅ | `--json` events and exit codes as a contract |
| Reconnect on its own | 🟡 | RTMP yes; SRT drops go unseen |
| Run as a background service | ✅ | `serve`, started by launchd on demand |
| Let an AI agent drive it | ✅ | MCP server: stream, record, destinations, devices |
| Find a destination by name | ✅ | `destinations_list`, operator-wide store |
| Drive the app's shots from an agent | ❌ | The app's `shot_take`, `preview_set`, and `program_*` tools answer only app-tier plug-ins over XPC (PLUGINS.md, Decision 14); an agent through `tingra-cli mcp` reaches the daemon, which has no shots |
| Shots and compositing without the app | ❌ | The CLI has no compositor; display, window, and shots are app-only |
| Let the agent see the program | ❌ | Planned: a `program.snapshot` tool |
| Run steps when an event fires | ❌ | Macros not built |
| Test without hardware | ✅ | Bars, tone, black, PLUGE generators |

## 2. Solo talker

Talks to camera: a weekly update, a coach's Q&A, a chat stream. One camera, one
microphone, one service. Wants to press one button and be live, and to trust
that nothing will go wrong.

**To succeed:** ship the app. **Size:** none beyond the release.

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

## 3. Recorder

Never goes live. Makes a talking-head update, a screen walkthrough for a
teammate, a lesson to upload later. Wants to press Record, press Stop, and
find the file.

**To succeed:** ship the app; for CLI users, a `record` command that needs no `--url`. **Size:** S.

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

## 4. Screen streamer

Codes live, draws, edits a photo, plays chess online, walks through a
spreadsheet. The screen or one app's window is the picture; a voice explains
it; a small face cam is optional.

**To succeed:** ship the app, for anyone who needs no sound from the Mac. Those who do wait on system and app audio. **Size:** none, then M.

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

## 5. Plug-in developer

Builds what Tingra does not: an NDI input, a new streaming protocol, an effect,
a rundown pane, a chat panel. Needs a stable API and a way to reach users.

**To succeed:** publish the SDK, a step for Larry with no code to write; that serves host-tier plug-ins (inputs, effects, outputs, tools). App-tier plug-ins (panes, windows, status items, the app's meters and video) also need the app to ship. **Size:** none.

| Need | Status | Notes |
|---|---|---|
| A stable, versioned API | 🟡 | SemVer and Library Evolution; 0.x until NDI, then 1.0 |
| A binary SDK to build against | 🟡 | Built; the first public publish waits on Larry (TODO.md) |
| Add inputs, effects, outputs, and MCP tools | ✅ | Host-tier `*.tingraplugin` bundles |
| Add panes, windows, commands, and status items | ✅ | App-tier ExtensionKit plug-ins |
| Read the app's meters and video | ✅ | `tingra/meters`, `tingra/frame` |
| Store secrets and data | ✅ | Plug-in secrets in the Keychain, project and app storage |
| Settings drawn for you | ✅ | Declared `Parameter`s become a native settings pane |
| Safe when a plug-in crashes | 🟡 | App-tier plug-ins run out of process, so a crash spares the app. Host-tier bundles run in process, so a crash takes Tingra and a live stream down; the load-crash guard and safe mode only help the next launch |
| A worked example | ✅ | The Notes plug-in, the fixture plug-in |
| A place to list and share plug-ins | ❌ | Planned: the plug-in gallery, proposed |

## 6. Set-and-forget camera

A bird feeder, a fish tank, a building site, a parking lot, a barn at
lambing time. One camera, sometimes a microphone, streaming day and night
to one service. No one watches the Mac; the owner checks in once a day, if at
all.

**To succeed:** reconnect without a limit, and start on its own at login. **Size:** S, then M.

| Need | Status | Notes |
|---|---|---|
| Stream one camera, with or without sound | ✅ | `tingra-cli stream`, `--no-audio` |
| Keep the Mac awake while streaming | ✅ | A running `stream` holds off idle and display sleep |
| Reconnect after a network drop | 🟡 | `--reconnect <n>` per destination; a count, not "forever", and SRT drops go unseen |
| Start on its own at login or after a power cut | ❌ | Nothing starts `stream` at login; the owner would write their own launchd job |
| Set it up without a terminal | ❌ | The app streams, but has no unattended mode or start at launch |
| Recover when the camera is unplugged and plugged back in | 🟡 | Device events are reported; recovery of a running CLI stream is not on record |
| Check health from afar | 🟡 | `--json` stats and `--log-file`; nothing pushes a notice when it stops |
| A date and time stamp on the picture | 🟡 | In the app, the time stamp generator is a layer over the camera; `tingra-cli stream` does no compositing, so there `--video-generator time-stamp` replaces the camera |
| Low power, cool Mac | ✅ | Hardware compression, GPU-resident frames |

## 7. Audio show

A radio-style show, a DJ set, a sermon or reading streamed as sound, a talk
show with no cameras. Mics and music carry it; the picture is a still image,
a logo, or black.

**To succeed:** audio files as inputs, ducking, and a limiter on the whole mix (each strip has one). **Size:** S, M, M.

| Need | Status | Notes |
|---|---|---|
| Stream sound with a still picture | ✅ | An image file as a layer, or the black generator |
| Sound only | 🟡 | `tingra-cli stream --no-video`; some services refuse a stream with no video |
| Several mics on faders | ✅ | The console mixer |
| Play music files (MP3, AAC, WAV) | ❌ | Video files with sound play; audio-only files are not an input |
| A playlist, or play a clip on a button press | ❌ | A staged video loops from the moment it is staged; once-only play is a planned slice |
| Music from a music app on the Mac | ❌ | No system or app audio input |
| A limiter so the stream never clips | 🟡 | A limiter effect on each strip, before its fader. Nothing limits the program mix, so several loud strips can still add up past full scale; that needs an effect chain on the master, which is not built |
| Talk over the music (ducking) | ❌ | Not on record |
| A higher audio bit rate | 🟡 | `--audio-bitrate` in the CLI; no app setting on record |

## 8. Fitness or yoga instructor

Leads a class from a studio or a living room: one wide camera, a wireless
mic, music, and students who follow along live, often on a private server or
inside a video call. Moves the whole time, so cannot reach the keyboard.

**To succeed:** a flip effect, audio files, and ducking. Classes held inside a video call also need virtual camera output (L). **Size:** S, S, M.

| Need | Status | Notes |
|---|---|---|
| A wide camera and a wireless mic | ✅ | Any camera and any audio input |
| Flip the picture left to right, so "raise your right arm" matches | ❌ | No flip effect; Crop, Frame, Blur, and Color Adjust only |
| Music under the voice | 🟡 | A video file with sound plays, looping; no audio files or playlist |
| Music that dips when the instructor speaks (ducking) | ❌ | Not on record |
| An interval or session timer on screen | ✅ | The timer and countdown generators as layers over the camera; an interval is one length that repeats, with no separate work and rest lengths, and starting or resetting is a click in Input Settings |
| Teach inside a video call | ❌ | No virtual camera output |
| Stream to a private server | ✅ | A custom RTMP(S) or SRT destination |
| Switch shots without touching the Mac | ❌ | No global hotkeys, pedal, or control surface; an app-tier plug-in could call the shot tools, but no agent can reach the app yet |
| Record the class for members who missed it | ✅ | Local recording |

## 9. Musician

Plays guitar, keys, or a drum kit, and sings. Sound comes in through an audio
interface; one camera shows the player, another the hands. Sound quality
matters more than anything else.

**To succeed:** an audio bit rate setting in the app, channel choice on the interface, and sync offset. **Size:** S, M, M.

| Need | Status | Notes |
|---|---|---|
| An audio interface as an input | ✅ | It appears as an input with its own strip |
| Choose which interface channels feed a strip | ❌ | Not on record |
| Headphone mix of the program | ✅ | The monitor path; most players will monitor from the interface |
| A limiter so a loud chord never clips | ✅ | The limiter effect on the interface's strip holds it under a ceiling. It works before the fader, so keep the fader at or under 0 dB; not yet judged by ear |
| Picture and sound in step | ❌ | Planned: sync offset, not built |
| Two cameras: the player and the hands | ✅ | Shots, multiview |
| A higher audio bit rate | 🟡 | `--audio-bitrate` in the CLI; no app setting on record |
| A separate track per instrument in the recording | ❌ | The recording holds the stereo program mix only |
| Several services at once | ✅ | Multiple destinations |

## 10. Avatar streamer

Streams as an animated character. A face-tracking app reads their face from
the camera and draws the character; the streamer puts the character over a
game, a backdrop, or a chat shot. Otherwise needs what the game streamer (16)
needs.

**To succeed:** check whether window capture keeps transparency; if not, a chroma key. Avatars over a game also need system and app audio. **Size:** S, or M.

| Need | Status | Notes |
|---|---|---|
| Capture the avatar app's window | ✅ | Window capture |
| Keep the window's transparency, so only the character shows | 🟡 | Not on record; needs checking in the code |
| Green screen, for avatar apps that draw on a flat color | ❌ | No keying effect |
| A voice changer that appears as a mic | 🟡 | Likely works, since a virtual audio device macOS lists as an input appears as one; not checked |
| Game and app sound | ❌ | No system or app audio input |
| Alerts, chat, and global hotkeys | ❌ | As for the game streamer |

## 11. Reaction or watch-along streamer

Watches a trailer, a match, a video, or a web page with viewers and talks over
it, face in a corner. The clip's sound is half the show.

**To succeed:** system and app audio, ducking, and clips that pause. **Size:** M, M, M.

| Need | Status | Notes |
|---|---|---|
| Capture the browser or player window | ✅ | Window capture |
| The clip's sound | ❌ | No system or app audio input: without it there is no show |
| Play a downloaded video with its sound | ✅ | Video file input with its own strip |
| The clip's sound dips when the streamer talks | ❌ | No ducking |
| Pause or restart the clip on air | ❌ | Not on record; play once, hold, and restart on take are planned slices |
| Face cam over the clip | ✅ | Layers, Crop, Frame |
| A web page as an input, not a captured window | ❌ | No web page input |
| Viewers' chat on screen | ❌ | No web page input |

## 12. Video podcaster

Two to four hosts around a table, each with a mic and often a camera, sometimes
a guest who calls in. Cares most about sound, and edits the recording after.

**To succeed:** EQ and noise removal (the gate, compressor, and limiter are built), an automixer, a track per mic in the recording, and sync offset. Shows with remote guests wait on a call-in path (XL). **Size:** M to L.

| Need | Status | Notes |
|---|---|---|
| A strip per mic: fader, mute, pan, meter | ✅ | The console mixer, in dB |
| Headphone mix for the operator | ✅ | The monitor path to a chosen output device |
| Clean up voices: compressor, limiter, gate, EQ, noise removal | 🟡 | Gate, compressor, and limiter effects on each strip, beside gain, high-pass, and low-pass; not yet judged by ear. No EQ and no noise removal |
| Turn down the mics nobody is speaking into (automixer) | ❌ | Not on record |
| Listen to one mic alone (solo) | ❌ | Planned: solo as pre-fade listen |
| Line up sound with slow cameras (sync offset) | ❌ | Planned: designed in CLOCK.md, not built |
| Sound that follows the shot | 🟡 | Audio follows video works for a video file's sound; it keys on the strip's own input, so turned on for a mic it silences it. Tying a mic to its host's camera is a planned slice |
| Cut to whoever is talking, on its own | ❌ | Not on record |
| A remote guest calling in | ❌ | No call-in path; WHIP/WHEP waits on `RTCHaishinKit` |
| A track per mic in the recording | ❌ | The recording holds the stereo program mix only |
| A file per camera (ISO recording) | ❌ | Not on record |
| Name titles (lower thirds) | 🟡 | A text file as a layer; no title templates |
| Stream to several services at once | ✅ | One program, many destinations |

## 13. Teacher or presenter

Teaches a class, runs a webinar, or makes software tutorials. Shows a screen or
one window with their face in a corner, flips between slides, a demo, and a
full-face shot, and often records for later rather than going live.

**To succeed:** system and app audio, then virtual camera output and captions. **Size:** M, L, L.

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
| Mark chapters in the recording | ❌ | Not on record |
| Captions | ❌ | Not on record |
| Draw or point on the screen | ❌ | Not on record |

## 14. Live seller

Sells live: shows each product to the camera, reads out the price, counts down
a timed deal, and answers questions as orders come in. Often a phone as the
face camera and a second camera looking down at the table.

**To succeed:** titles that change on air, and orders on screen through a web page input. **Size:** L, L.

| Need | Status | Notes |
|---|---|---|
| Two cameras: the seller and the product table | ✅ | Any two cameras, an iPhone included, as shots |
| Product photos | ✅ | Image files as layers |
| Price and deal titles, changed on air | 🟡 | Text files as layers; no title templates and no quick way to change a price live |
| A countdown for a timed deal | ✅ | The countdown generator as a layer: a duration, started, paused, and reset in Input Settings |
| Orders and questions on screen | ❌ | No web page input |
| Portrait for phone viewers and landscape for others, at once | ❌ | One program format per show |
| Jump to the product shot quickly | 🟡 | ⌘1–⌘9, while Tingra is in front |
| Several services at once | ✅ | Multiple destinations |

## 15. Worship or community volunteer team

A church, a temple, a school assembly. Two to five cameras, often through
capture cards; a computer showing lyrics or slides; a house mixing desk
feeding sound in. The same show every week, run by whichever volunteer turned
up. (Council and board meetings, with their legal duties, are persona 17.)

**To succeed:** lyric and scripture titles, macros, and a scheduled start. **Size:** L, L, M.

| Need | Status | Notes |
|---|---|---|
| Several cameras, capture cards included | ✅ | Capture cards appear as cameras |
| Pan, tilt, and zoom a camera | 🟡 | USB cameras in Tingra Cameras; not in the main app; no network camera control |
| The same setup every week | ✅ | Projects, presets, shots, autosave |
| Preview, then take; fade to black | ✅ | Preview and program, Take on Return, ⇧⌘B |
| Sound from the house desk | ✅ | An audio interface appears as an input |
| Lyrics and scripture on screen | 🟡 | Text and Markdown files; no lyric or slide feed, no title templates |
| A feed from the slides computer over the network | ❌ | Planned: NDI as an external plug-in |
| Walk-in music before the start | 🟡 | A video file with sound; no audio files or playlist |
| A countdown before the start | ✅ | The countdown generator as a layer, counting to a time of day or through a duration |
| Start at a set time | ❌ | Not on record |
| One button for "record, go live, show welcome" | ❌ | GLOSSARY.md defines macros; not built |
| Simple for a new volunteer each week | 🟡 | Shortcuts follow common switcher keys; macros and a simple mode would help most |
| Line up sound with the cameras | ❌ | Planned: sync offset, not built |
| Survive a crash mid-service | ✅ | Resume Stream offer, autosave |
| The app in Spanish or German | ✅ | English, German, Spanish |
| Captions for those who cannot hear | ❌ | Not on record |

## 16. Game streamer

Plays a game on the same Mac, with a face cam, a logo, alerts for new
followers, the chat on screen, and switches between "playing", "be right back",
and "just talking". Often streams to more than one service, and makes short
portrait clips. Tabletop and board game streams belong here too, with an
overhead camera and players who may join from afar.

**To succeed:** system and app audio, chroma key, global hotkeys, overlays above every shot, and a web page input. Each is M or L; the size is in the number of pieces. **Size:** M to L, many.

| Need | Status | Notes |
|---|---|---|
| Capture the game's window or display | ✅ | Window and display inputs |
| Game sound and voice-chat sound | ❌ | No system or app audio input: the biggest gap for this persona |
| Face cam, cropped, framed | ✅ | Crop and Frame effects |
| An overhead camera on a table or board | ✅ | Any camera, as its own shot |
| Players joining from afar | ❌ | No call-in path |
| Green screen (chroma key) | ❌ | GLOSSARY.md names keying; no effect yet |
| Background removal without a green screen | ❌ | Not on record |
| A logo or frame above every shot | 🟡 | A layer in each shot; no overlay that sits above all shots |
| Alerts, chat, goal bars (web widgets) | ❌ | No web page input |
| Switch shots while the game has focus | ❌ | ⌘1–⌘9 work only while Tingra is in front; no global hotkeys |
| A button deck or other control surface | 🟡 | Nothing direct; an app-tier plug-in could drive one through the app's `shot_take` and `preview_set` tools |
| Video transitions (stingers) | ❌ | Cut, dissolve, wipe, and shader transitions only |
| Several services at once | ✅ | Multiple destinations, each with its own reconnect |
| Landscape and portrait at the same time | ❌ | Portrait sizes exist, but one program format per show |
| Save the last 30 seconds (replay buffer) | ❌ | Not on record |
| Low cost while the game runs | ✅ | GPU-resident frames, hardware compression |

## 17. Public meetings

A city council, a school board, a court, a zoning hearing. Many mics open
around a table, two or three fixed cameras, sessions that run four hours or
more, and a legal duty to stream, caption, and keep the record. Clerks run it,
not video staff.

**To succeed:** an automixer, captions, and chapter marks. Hybrid meetings also need call-in (XL). **Size:** M, L, M.

| Need | Status | Notes |
|---|---|---|
| Many open mics, turned down when no one speaks into them (automixer) | ❌ | Not on record; each strip is a manual fader |
| Choose channels on the room's audio interface | ❌ | Not on record |
| Several fixed cameras | ✅ | Shots |
| A "recess" or "starting soon" shot | ✅ | Shots with image or text layers |
| Captions, often required by law | ❌ | Not on record |
| Long sessions recorded without a gap | 🟡 | Fragmented recording survives a crash; dropped frames under study; splitting by hour or size not on record |
| Mark each agenda item in the recording (chapters) | ❌ | Not on record |
| The agenda item on screen | 🟡 | Text files as layers; no title templates |
| Remote members and public comment by call-in | ❌ | No call-in path |
| Start at a set time | ❌ | Not on record |
| Easy for a clerk | 🟡 | As for volunteers: macros and a simple mode would help most |

## 18. Company webinar or all-hands producer

Runs a product launch, an all-hands, or a customer webinar. Slides come from a
presenter's Mac, speakers join from other cities, every shot carries the
company's look, the stream often goes to a private server, and IT installs
the software.

**To succeed:** remote speakers, captions, and branding above every shot. **Size:** XL, L, M.

| Need | Status | Notes |
|---|---|---|
| Slides from the presenter's computer | 🟡 | Through a capture card, which appears as a camera; NDI is planned |
| Remote speakers | ❌ | No call-in path; WHIP/WHEP waits on `RTCHaishinKit` |
| The company's look on every shot | 🟡 | Layers in each shot; no overlay above all shots, no title templates |
| Captions | ❌ | Not on record |
| Stream to a private server | ✅ | A custom RTMP(S) or SRT destination |
| A countdown before the start | ✅ | The countdown generator as a layer, counting to a time of day or through a duration |
| Audience questions on screen | ❌ | No web page input |
| Installed and set up by IT on managed Macs | 🟡 | A signed, notarized `.pkg` for the CLI; managed settings for the app not on record |
| Stream keys kept out of logs and files | ✅ | Keychain storage, redaction at every boundary |
| A recording for those who missed it | ✅ | Local recording |

## 19. Live event producer

Sports, conferences, weddings, concerts, tournaments: a small crew, many
cameras, sometimes a feed sent to a far site over SRT. Expects the tools of a
broadcast switcher.

**To succeed:** ISO recording, replay, NDI, and tally, among others. **Size:** several L.

| Need | Status | Notes |
|---|---|---|
| See every input at once (multiview) | ✅ | Multiview window with tally |
| Preview and program, many transitions | ✅ | Cut, dissolve, wipe, shaders |
| Up to 4K, up to 60 frames a second | ✅ | Program format menu |
| A camera per player at a tournament | ✅ | Capture cards and cameras as inputs, multiview |
| Send over SRT | 🟡 | SRT output works; a dropped SRT link is never reported, so it never reconnects (TODO.md) |
| Send to several services, each reconnecting | ✅ | Multiple destinations |
| A file per camera (ISO recording) | ❌ | Not on record |
| Instant replay | ❌ | Not on record |
| Scoreboards and data-driven graphics | ❌ | No title engine or web page input |
| NDI in and out | ❌ | Planned: an external plug-in |
| Tally lights on the cameras | ❌ | Not on record |
| Delay a slow input's sound | ❌ | Planned: sync offset, not built |
| Solo, sends, and extra buses for crew feeds | ❌ | Planned as later mixer slices |
| One audio track per language, for interpreters | ❌ | The stream and the recording carry one stereo mix |
| A log to review after the show | ✅ | Log window, log file, stream history |
| A hardware control surface | ❌ | Not on record |

## 20. Two-person team: talent and remote producer

One person is on camera; another runs the show from another room, another
Mac, or a tablet. Common for a creator with an editor or a partner, and for
small companies.

**To succeed:** a decision on how anything outside the Mac may control Tingra, then remote control built on it. **Size:** XL, after a design decision.

| Need | Status | Notes |
|---|---|---|
| Switch shots from another device | ❌ | MCP is local by design: a per-user Unix socket, and MCP.md forbids a TCP listener. Remote control needs a design decision first |
| The producer sees the program | ❌ | Nothing leaves the Mac but the stream; a `program.snapshot` tool is planned for agents |
| Cues from the producer to the talent | ❌ | Not on record; an app-tier plug-in could add one |
| Both work on one project | ❌ | One project, open on one Mac |
| Control from a phone or tablet | ❌ | Not on record; Tingra is Mac-only |
| An AI agent as the producer | ❌ | An agent reaches the daemon, not the app's shots (persona 1) |

## Out of scope: streaming on the move

Streamers who walk and talk, with a phone and a cellular link, are not
Tingra's. Tingra is a Mac app for a desk, by design (ARCHITECTURE.md, design
principles). They are listed here so the question stays answered.

## The gaps, easiest first

Sized as above. Within a size, the gaps that block more personas come first.
"Blocks" lists the personas whose tables name the gap.

| Gap | Size | Blocks | Tracked? |
|---|---|---|---|
| Publish the plug-in SDK | — | 5 | Yes, TODO.md; no code, a step for Larry |
| Audio files as inputs | S | 7, 8, 15 | No |
| HEVC and audio bit rate settings in the app | S | 3, 7, 9 | No |
| Reconnect without a limit | S | 6 | No |
| A `record` command in the CLI | S | 3 | No |
| Flip the picture left to right | S | 8 | No |
| Check whether window capture keeps transparency | S | 10 | Not on record |
| System and app audio capture | M | 4, 7, 10, 11, 13, 16 | No |
| Global hotkeys | M | 4, 8, 14, 16 | No |
| Sync offset | M | 9, 12, 15, 19 | Yes, CLOCK.md |
| Playlists, and clips that play once or pause | M | 7, 8, 11, 15 | Play-once is a planned slice |
| Ducking: music or a clip dips under a voice | M | 7, 8, 11 | No |
| Starting on its own: at login, or at a set time | M | 6, 15, 17 | No |
| A time stamp over the camera in a CLI stream | M | 6 | No; the generator is built (ARCHITECTURE.md, "The time generators"), the CLI does no compositing |
| Chroma key and background removal | M | 2, 10, 16 | Keying defined in GLOSSARY.md only |
| Overlays above every shot | M | 16, 18 | Defined in GLOSSARY.md only |
| Choosing channels on a multichannel audio interface | M | 9, 17 | Not on record |
| Pausing and splitting a recording | M | 3, 17 | No |
| Automixer for many open mics | M | 12, 17 | No |
| Chapter marks in a recording | M | 13, 17 | No |
| Camera controls in the main app | M | 2, 15 | Yes, TODO.md |
| EQ as an audio effect | M | 12 | No |
| An effect chain on the master, so a limiter can hold the whole mix | M | 7 | No; DONE.md names it as what re-opens the master section |
| Settings IT can manage on many Macs | M | 18 | No |
| Title templates, changed on air (lower thirds, lyrics, prices, scores) | L | 3, 12, 14, 15, 17, 18, 19 | Titles defined in GLOSSARY.md only |
| Web page input (alerts, chat, orders, scoreboards) | L | 4, 11, 14, 16, 18, 19 | No |
| Macros and control surfaces | L | 1, 15, 16, 17, 19 | Macros defined in GLOSSARY.md only |
| Captions | L | 13, 15, 17, 18 | No |
| ISO and per-track recording, one track per language included | L | 9, 12, 19 | No |
| NDI | L | 15, 18, 19 | Yes, TODO.md |
| Virtual camera output | L | 8, 13 | No |
| Landscape and portrait at the same time | L | 14, 16 | No |
| Replay | L | 16, 19 | No |
| Noise removal | L | 12 | No |
| Remote guests and call-in | XL | 12, 16, 17, 18 | WHIP/WHEP waits on `RTCHaishinKit` |
| SRT reconnect after a dropped link | XL | 1, 6, 19 | Yes, TODO.md; waits on HaishinKit |
| An agent connection to the app | XL | 1, 8, 20 | No; agents reach only the daemon, and the app's tools answer only its extensions; needs a decision |
| Remote control from another device | XL | 20 | No, and MCP.md forbids a TCP listener; needs a decision |

Where Tingra already leads: a native Mac app with a GPU-resident path, several
services at once with per-destination reconnect, recovery after a crash, and,
above all, control by scripts and AI agents through the CLI and MCP, where
Tingra stands apart. The plug-in design gives persona 5 a path to fill the
gaps above without waiting on the core.
