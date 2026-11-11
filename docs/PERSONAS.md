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
persona from 2 to 18 needs the app, so for them every ✅ below means "built in
the app, waiting on its release" (TODO.md, "Release Tingra.app").

**Key:** ✅ has it · 🟡 has part of it, or a workaround · ❌ missing.
"Planned" means TODO.md or a design record already tracks it.

## At a glance

| # | Persona | Typical setup | Fit today |
|---|---|---|---|
| 1 | Set-and-forget camera | One camera, always on, no one watching | Good for someone at home in a terminal; poor for anyone else |
| 2 | Recorder | One camera or one screen, recorded, never live | Strong in the app; the CLI cannot record without streaming |
| 3 | Solo talker | One webcam, one mic, one service | Strong |
| 4 | Fitness or yoga instructor | One wide camera, a wireless mic, music, a class following along | Weak: no flip, no music files, no ducking, no timer |
| 5 | Audio show | Mics, music, a still picture; sound is the show | Weak: no audio files, no playlist, no limiter |
| 6 | Screen streamer | A screen or one window and a voice: live coding, drawing, a walkthrough | Strong, until the Mac's own sound is needed |
| 7 | Live seller | A face camera, a product camera, prices on screen, a chat full of orders | Weak to fair: the cameras work, the graphics do not exist yet |
| 8 | Reaction or watch-along streamer | A face cam over a video or a web page | Weak: no sound from the Mac or a browser |
| 9 | Musician | An instrument and a voice through an audio interface, a camera or two | Fair: the interface works; level control and sync do not exist yet |
| 10 | Teacher or presenter | Screen, face in a corner, slides, a recording | Good, with two big holes: Mac and app sound, and sending the program to a video call |
| 11 | Avatar streamer | An animated character from a face-tracking app, over a game or a backdrop | Unknown until window transparency is checked |
| 12 | Video podcaster | Two to four hosts, a mic and camera each, sometimes a remote guest | Fair: the mixer is good, voice processing and per-track recording are missing |
| 13 | Game streamer | Game capture, face cam, overlays, alerts, chat, several services | Weak: no game sound, no green screen, no web widgets, no global hotkeys |
| 14 | Company webinar or all-hands producer | Slides, speakers in other cities, the company's look, a private server | Fair: the switching is there; remote speakers and captions are not |
| 15 | Worship or community volunteer team | Several cameras, lyrics and titles, a weekly show run by rotating volunteers | Fair: switching and safety are good, titles, macros, and schedules are missing |
| 16 | Public meetings | Many open mics, fixed cameras, sessions of four hours or more, a legal duty to caption | Fair to weak: no automixer, no captions, no chapter marks |
| 17 | Live event producer | Many cameras, multiview, contribution over SRT, replays, graphics | Fair on switching, weak on what a crew expects: ISO recording, replay, NDI, tally |
| 18 | Two-person team: talent and remote producer | One person on camera, another switching from another room or device | Weak, and blocked by a design rule until it is decided |
| 19 | Automation and agent operator | No screen; scripts, a daemon, or an AI agent run the stream | Strong, and where Tingra stands apart |
| 20 | Plug-in developer | Builds inputs, effects, outputs, or app panes for others | Strong design, waiting on the SDK's first publish and 1.0 |

## Which personas Tingra serves best

Of the simple setups, Tingra serves three well today: the **solo talker** (3),
the **recorder** (2), and the **screen streamer** (6). They share a shape: one
or two video inputs, a voice from a microphone, no sound from the Mac itself,
and no web graphics. Inside that shape nearly every need is ✅.

The other simple personas each fall on one or two missing pieces. The **audio
show** (5) has no way to play music files or a playlist. The **musician** (9)
has no limiter and no sync offset. The **fitness instructor** (4) cannot flip
the picture or duck the music. The **live seller** (7) has no price titles,
countdown, or chat. The **set-and-forget camera** (1) works, but only for
someone who can write a terminal command and keep it running; nothing starts
it at login. And the shape breaks for anyone who needs the Mac's own sound,
which is why personas 5, 6, 8, 10, 12, and 13 all list that gap.

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

## 4. Fitness or yoga instructor

Leads a class from a studio or a living room: one wide camera, a wireless
mic, music, and students who follow along live, often on a private server or
inside a video call. Moves the whole time, so cannot reach the keyboard.

| Need | Status | Notes |
|---|---|---|
| A wide camera and a wireless mic | ✅ | Any camera and any audio input |
| Flip the picture left to right, so "raise your right arm" matches | ❌ | No flip effect; Crop, Frame, Blur, and Color Adjust only |
| Music under the voice | 🟡 | A video file with sound plays, looping; no audio files or playlist |
| Music that dips when the instructor speaks (ducking) | ❌ | Not on record |
| An interval or session timer on screen | ❌ | Not on record |
| Teach inside a video call | ❌ | No virtual camera output |
| Stream to a private server | ✅ | A custom RTMP(S) or SRT destination |
| Switch shots without touching the Mac | 🟡 | No global hotkeys, pedal, or control surface; an agent over MCP could switch on spoken orders |
| Record the class for members who missed it | ✅ | Local recording |

## 5. Audio show

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

## 6. Screen streamer

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

## 7. Live seller

Sells live: shows each product to the camera, reads out the price, counts down
a timed deal, and answers questions as orders come in. Often a phone as the
face camera and a second camera looking down at the table.

| Need | Status | Notes |
|---|---|---|
| Two cameras: the seller and the product table | ✅ | Any two cameras, an iPhone included, as shots |
| Product photos | ✅ | Image files as layers |
| Price and deal titles, changed on air | 🟡 | Text files as layers; no title templates and no quick way to change a price live |
| A countdown for a timed deal | ❌ | Not on record |
| Orders and questions on screen | ❌ | No web page input |
| Portrait for phone viewers and landscape for others, at once | ❌ | One program format per show |
| Jump to the product shot quickly | 🟡 | ⌘1–⌘9, while Tingra is in front |
| Several services at once | ✅ | Multiple destinations |

## 8. Reaction or watch-along streamer

Watches a trailer, a match, a video, or a web page with viewers and talks over
it, face in a corner. The clip's sound is half the show.

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

## 9. Musician

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

## 10. Teacher or presenter

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
| Mark chapters in the recording | ❌ | Not on record |
| Captions | ❌ | Not on record |
| Draw or point on the screen | ❌ | Not on record |

## 11. Avatar streamer

Streams as an animated character. A face-tracking app reads their face from
the camera and draws the character; the streamer puts the character over a
game, a backdrop, or a chat shot. Otherwise needs what the game streamer (13)
needs.

| Need | Status | Notes |
|---|---|---|
| Capture the avatar app's window | ✅ | Window capture |
| Keep the window's transparency, so only the character shows | 🟡 | Not on record; needs checking in the code |
| Green screen, for avatar apps that draw on a flat color | ❌ | No keying effect |
| A voice changer that appears as a mic | 🟡 | Likely works, since a virtual audio device macOS lists as an input appears as one; not checked |
| Game and app sound | ❌ | No system or app audio input |
| Alerts, chat, and global hotkeys | ❌ | As for the game streamer |

## 12. Video podcaster

Two to four hosts around a table, each with a mic and often a camera, sometimes
a guest who calls in. Cares most about sound, and edits the recording after.

| Need | Status | Notes |
|---|---|---|
| A strip per mic: fader, mute, pan, meter | ✅ | The console mixer, in dB |
| Headphone mix for the operator | ✅ | The monitor path to a chosen output device |
| Clean up voices: compressor, limiter, gate, EQ, noise removal | 🟡 | Only gain, high-pass, and low-pass today |
| Turn down the mics nobody is speaking into (automixer) | ❌ | Not on record |
| Listen to one mic alone (solo) | ❌ | Planned: solo as pre-fade listen |
| Line up sound with slow cameras (sync offset) | ❌ | Planned: designed in CLOCK.md, not built |
| Sound that follows the shot | ✅ | Audio follows video |
| Cut to whoever is talking, on its own | ❌ | Not on record |
| A remote guest calling in | ❌ | No call-in path; WHIP/WHEP waits on `RTCHaishinKit` |
| A track per mic in the recording | ❌ | The recording holds the stereo program mix only |
| A file per camera (ISO recording) | ❌ | Not on record |
| Name titles (lower thirds) | 🟡 | A text file as a layer; no title templates |
| Stream to several services at once | ✅ | One program, many destinations |

## 13. Game streamer

Plays a game on the same Mac, with a face cam, a logo, alerts for new
followers, the chat on screen, and switches between "playing", "be right back",
and "just talking". Often streams to more than one service, and makes short
portrait clips. Tabletop and board game streams belong here too, with an
overhead camera and players who may join from afar.

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
| A button deck or other control surface | 🟡 | Nothing direct; MCP tools (`shot_take`, `preview_set`) could drive one |
| Video transitions (stingers) | ❌ | Cut, dissolve, wipe, and shader transitions only |
| Several services at once | ✅ | Multiple destinations, each with its own reconnect |
| Landscape and portrait at the same time | ❌ | Portrait sizes exist, but one program format per show |
| Save the last 30 seconds (replay buffer) | ❌ | Not on record |
| Low cost while the game runs | ✅ | GPU-resident frames, hardware compression |

## 14. Company webinar or all-hands producer

Runs a product launch, an all-hands, or a customer webinar. Slides come from a
presenter's Mac, speakers join from other cities, every shot carries the
company's look, the stream often goes to a private server, and IT installs
the software.

| Need | Status | Notes |
|---|---|---|
| Slides from the presenter's computer | 🟡 | Through a capture card, which appears as a camera; NDI is planned |
| Remote speakers | ❌ | No call-in path; WHIP/WHEP waits on `RTCHaishinKit` |
| The company's look on every shot | 🟡 | Layers in each shot; no overlay above all shots, no title templates |
| Captions | ❌ | Not on record |
| Stream to a private server | ✅ | A custom RTMP(S) or SRT destination |
| A countdown before the start | ❌ | Not on record |
| Audience questions on screen | ❌ | No web page input |
| Installed and set up by IT on managed Macs | 🟡 | A signed, notarized `.pkg` for the CLI; managed settings for the app not on record |
| Stream keys kept out of logs and files | ✅ | Keychain storage, redaction at every boundary |
| A recording for those who missed it | ✅ | Local recording |

## 15. Worship or community volunteer team

A church, a temple, a school assembly. Two to five cameras, often through
capture cards; a computer showing lyrics or slides; a house mixing desk
feeding sound in. The same show every week, run by whichever volunteer turned
up. (Council and board meetings, with their legal duties, are persona 16.)

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
| A countdown before the start | ❌ | Not on record |
| Start at a set time | ❌ | Not on record |
| One button for "record, go live, show welcome" | ❌ | GLOSSARY.md defines macros; not built |
| Simple for a new volunteer each week | 🟡 | Shortcuts follow common switcher keys; macros and a simple mode would help most |
| Line up sound with the cameras | ❌ | Planned: sync offset, not built |
| Survive a crash mid-service | ✅ | Resume Stream offer, autosave |
| The app in Spanish or German | ✅ | English, German, Spanish |
| Captions for those who cannot hear | ❌ | Not on record |

## 16. Public meetings

A city council, a school board, a court, a zoning hearing. Many mics open
around a table, two or three fixed cameras, sessions that run four hours or
more, and a legal duty to stream, caption, and keep the record. Clerks run it,
not video staff.

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

## 17. Live event producer

Sports, conferences, weddings, concerts, tournaments: a small crew, many
cameras, sometimes a feed sent to a far site over SRT. Expects the tools of a
broadcast switcher.

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

## 18. Two-person team: talent and remote producer

One person is on camera; another runs the show from another room, another
Mac, or a tablet. Common for a creator with an editor or a partner, and for
small companies.

| Need | Status | Notes |
|---|---|---|
| Switch shots from another device | ❌ | MCP is local by design: a per-user Unix socket, and MCP.md forbids a TCP listener. Remote control needs a design decision first |
| The producer sees the program | ❌ | Nothing leaves the Mac but the stream; a `program.snapshot` tool is planned for agents |
| Cues from the producer to the talent | ❌ | Not on record; an app-tier plug-in could add one |
| Both work on one project | ❌ | One project, open on one Mac |
| Control from a phone or tablet | ❌ | Not on record; Tingra is Mac-only |
| An AI agent as the producer | ✅ | On the same Mac, through MCP (persona 19) |

## 19. Automation and agent operator

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

## 20. Plug-in developer

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

## Out of scope: streaming on the move

Streamers who walk and talk, with a phone and a cellular link, are not
Tingra's. Tingra is a Mac app for a desk, by design (ARCHITECTURE.md, design
principles). They are listed here so the question stays answered.

## The gaps, ranked by how many personas they block

| Gap | Blocks | Tracked? |
|---|---|---|
| Release `Tingra.app` | 2–18 | Yes, TODO.md |
| Voice processing: compressor, limiter, gate, EQ, noise removal | 4, 5, 9, 12, 13, 14, 15, 16, 17 | No |
| Global hotkeys, macros, and control surfaces | 4, 6, 7, 13, 15, 16, 17, 19 | Macros defined in GLOSSARY.md only |
| Overlays above every shot, and title templates | 7, 12, 13, 14, 15, 16, 17 | Defined in GLOSSARY.md only |
| System and app audio capture | 5, 6, 8, 10, 11, 12, 13 | No |
| Timers, and starting on its own: at login, at a set time, with a countdown | 1, 4, 7, 14, 15, 16 | No |
| Web page input (alerts, chat, orders, scoreboards) | 6, 7, 8, 13, 14, 17 | No |
| Remote guests and call-in | 10, 12, 13, 14, 16, 17 | WHIP/WHEP waits on `RTCHaishinKit` |
| Captions | 10, 14, 15, 16, 17 | No |
| ISO and per-track recording, one track per language included | 9, 10, 12, 17 | No |
| Sync offset | 9, 12, 15, 17 | Yes, CLOCK.md |
| Virtual camera output | 4, 10, 12, 14 | No |
| Recording and compression settings in the app: pause, HEVC, audio bit rate, splitting | 2, 5, 9, 16 | No |
| Audio files, playlists, and play-once or pausable clips | 4, 5, 8, 15 | Play-once is a planned slice |
| Chroma key and background removal | 3, 11, 13 | Keying defined in GLOSSARY.md only |
| Ducking: music or a clip dips under a voice | 4, 5, 8 | No |
| Choosing channels on a multichannel audio interface | 9, 15, 16 | Not on record |
| NDI | 14, 15, 17 | Yes, TODO.md |
| Automixer for many open mics | 12, 16 | No |
| Chapter marks in a recording | 10, 16 | No |
| Landscape and portrait at the same time | 7, 13 | No |
| Replay | 13, 17 | No |
| Flip the picture left to right | 4 | No |
| Window capture that keeps transparency | 11 | Not on record; check the code |
| Settings IT can manage on many Macs | 14 | No |
| Remote control from another device | 18 | No, and MCP.md forbids a TCP listener; needs a decision |

Where Tingra already leads: a native Mac app with a GPU-resident path, several
services at once with per-destination reconnect, recovery after a crash, and,
above all, control by scripts and AI agents through the CLI and MCP, where
Tingra stands apart. The plug-in design gives persona 20 a path to fill the
gaps above without waiting on the core.
