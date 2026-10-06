# Clock and Timing

How Tingra keeps video and audio in sync from capture to destination. This document defines the master clock, the program tick that paces the compositor, and the timestamp rules every input, sink, and plug-in follows. Vocabulary follows GLOSSARY.md; the timing terms defined there (**master clock**, **timebase**, **program tick**, **sync offset**) originate here.

Timing is **host infrastructure**, not a feature service or a plug-in. Apply the host test from ARCHITECTURE.md: remove the clock and every plug-in breaks — capture cannot timestamp, composition cannot pace, audio cannot align, and no sink can mux. The production clock (`HostClock`) therefore lives in the host beside the event bus and logging, as part of frame transport ("the GPU resident pipeline and its clock"). The seam it implements (`EngineClock`) lives in the plug-in protocol package, `TingraPlugInKit`, because every plug-in receives the clock through it.

## Design principles

1. **One master clock.** Every timestamp in the system — captured frame PTS, program frame PTS, audio buffer PTS — is expressed against a single reference: the host time clock (`CMClockGetHostTimeClock()`, backed by `mach_absolute_time`). No component ever compares timestamps from two different clock domains. The clocks that are not the master clock, and how each is kept from leaking into a timestamp, are listed in "Clocks that are not the master clock".
2. **Output pacing is independent of any display or input.** A dedicated scheduler drives the program at the configured frame rate. The stream never stalls because a display slept or an input stopped producing. A sleep of the whole Mac is a different matter: see "System sleep and App Nap".
3. **Timestamp accurately; never resample to force alignment.** Audio is continuous and unforgiving; video is forgiving. Captured media is stamped with its true position on the master clock, program media with the tick that produced it, and the sinks interleave by PTS. Tingra does not stretch audio or repeat-drop video to fake sync; where two clocks disagree, the difference is absorbed as a bounded drop or a bounded silence, never as a resample.
4. **The clock is injected, never global.** Components receive the clock through a protocol so tests can substitute a synthetic clock and drive the pipeline deterministically, with no hardware and no wall clock waiting.

## Why the host time clock

ScreenCaptureKit and `AVCaptureVideoDataOutput` already stamp their `CMSampleBuffer`s against host time, and `AVAudioEngine` reports capture time as `AVAudioTime.hostTime`. The host time clock is therefore the reference the frames already arrive in. Choosing it means zero clock domain translation at the capture boundary — and clock domain translation is where drift bugs are born.

The audio hardware clock genuinely drifts relative to the host clock (crystal oscillators disagree by parts per million, which becomes audible A/V skew over a multi hour stream). Rule 3 above answers it at the capture seam: audio buffers are stamped with their **actual host time of capture** taken from `AVAudioTime`, not with a synthetic `sample count ÷ nominal sample rate` position, so the drift shows up honestly in the timestamps. What happens to it next depends on the path:

- **The CLI's single microphone** passes through with those true times untouched, and the sink interleaves by them.
- **The mixer** (the app's path) does not read a captured buffer's PTS at all. Each channel's samples queue in a FIFO at intake, and the mix tick consumes one block's worth per tick and stamps the mixed block with the tick's own time. A device running slow underruns and contributes silence for the shortfall; a device running fast fills its queue to the one second cap and loses its oldest samples. The drift costs a bounded glitch, and the program audio's timeline stays exactly on the master clock (ARCHITECTURE.md, "The audio mixer").

## Clocks that are not the master clock

Principle 1 holds because each of these is kept on its own side of a boundary:

- **An audio capture device's sample clock.** Absorbed at the capture seam and the mixer's intake, as above.
- **The monitor's output device.** The mix tick is paced by the master clock and the output device runs on its own crystal, so the two will diverge. This is the one place the engine feeds a second clock domain, and it never compares the two: the monitor schedules blocks in order, caps its scheduled backlog at a handful of blocks, and drops a block that arrives at the cap. Drift costs a bounded glitch, never a growing delay between what the operator sees and hears, and the monitor never applies back pressure to the mix (ARCHITECTURE.md, "The monitor path").
- **The display's refresh.** Paces monitor sampling and meter drawing only; see "What does not drive the tick".
- **The wall clock.** Never a timestamp. Its one use in the engine is the bars generator's burned in time of day, read through an injected wall clock (`Date.now` in production, fixed in tests) and positioned by the tick's master clock time. The master clock counts the Mac's awake time since boot, so it cannot say what time of day it is.
- **A sink's own bookkeeping clock.** The SRT streaming service measures its frames per second figure against a `ContinuousClock` of its own. It stamps nothing with it, but it is not injected and it counts sleep, so one reading after a wake is wrong. A known deviation from principle 4, tracked in TODO.md.

## The program tick

The compositor does not render when inputs deliver frames; it renders when the **program tick** fires.

- A host owned **pacing scheduler** fires at the program frame rate (30 fps → every 33.3 ms).
- Each tick's deadline is computed as an **absolute position on the master clock** — `start + n × frameDuration`, where `start` is the instant the tick stream began — never `previous tick + interval`, so scheduling error cannot accumulate. (`T0` in this document always means a session's start, "Timestamp rules"; a tick stream's `start` is a different instant.)
- On each tick, the compositor **pulls the most recent frame each input has produced** (double buffered, latest wins), renders the layer tree of the current shot, and stamps the resulting program frame with the tick's host clock PTS.
- The program frame then fans out to the sinks (streaming output, recording), all sharing that PTS.
- **One tick paces both buses.** Since the preview bus landed (ARCHITECTURE.md, "The preview bus"), the same tick also renders the shot staged on **preview** — a second renderer pass over the *same* snapshot of input slots, so preview shows the very frames program is composited from rather than racing it for them, and both carry the tick's PTS. A second bus is not a second timeline and not a second tick stream. The preview pass runs only while a shot is staged and a consumer is attached, so an unwatched preview costs nothing, and preview frames go to a monitor only — never to a sink.
- **A frame rate change re-arms the tick.** When the program format's rate changes live, the tick that is in flight still renders at the old cadence, and the compositor then asks the clock for a new tick stream at the new interval inside the same tick task. The new stream has its own `start`, so the first frame at the new rate lands one new interval after the re-arm; PTS stays monotonic. A transition in flight finishes at the tick count it was given.

### Other tick streams on the same clock

The program tick is one consumer of the clock's tick stream, not the only one. Each of these asks the same injected clock for its own stream, with its own interval and its own `start`:

- **The mix tick.** The mixer produces one program audio block per tick, at the block cadence (1024 frames at 48 kHz, about every 21.3 ms). It is the audio counterpart of the program tick and runs beside it, not under it.
- **Generators** synthesize on a tick at their own rate, and **movie playback** ticks at the file's own frame rate.
- **A session's waits** — the stream statistics cadence and a configured duration — are ticks too, so a synthetic clock drives them in tests.

One clock, several grids. Nothing aligns the grids to each other, and nothing needs to: every tick is stamped with its own position on the master clock, which is what the sinks interleave by.

### Why pull, not push

- **A stalled input does not stall the program.** If a camera hiccups or a window stops updating, the tick re-composites its last delivered frame and the stream keeps flowing — correct behavior for live.
- **Multiple inputs with different native cadences** (a 30 fps camera, a 60 Hz display, a 10 fps title generator) compose cleanly: each contributes whatever frame is current at tick time.
- **Compression rate control gets what it wants:** a clean, monotonic, constant rate PTS sequence.

### What does not drive the tick

- **Not `CVDisplayLink` / `CADisplayLink`.** Display links throttle or stop when the display sleeps or the app is occluded. A broadcaster must keep sending frames regardless. Display links are fine for pacing *monitor drawing*, which never drives output.
- **Not a capture input's cadence.** With multiple inputs and shot switching, the "driving" input would keep changing, and its stalls would become program stalls.

**How the app's monitors sample.** A monitor reads the latest frame from a shared relay the bus's drain writes, decoupled from the program tick (settled at step 6). The display paces the *sampling*, not the rendering: a monitor renders only when what it samples has changed (a new frame, or an edit to what the picture is composed from), so program and preview draw at the program rate and a still image's tile draws once, however fast the display refreshes (refined 2026-09-26). Program, preview, and the layer monitor sample at the display's rate; thumbnail tiles — the shot bank, the layer rows, the input grid — sample at 15 frames a second. Multiview and the input tiles apply the same rule one surface over: they read the compositor's latest-wins slots (`latestFrame(forInput:)`) at their sampling rate and are never a consumer of an input's frame stream. The mixer's meters are drawn off a display link the same way.

### The single-input pacer (the CLI's path)

`tingra-cli` streams one video input and one audio input with no composition stage. The program tick still applies (decided 2026-07-04) — the pipeline is **tick-paced latest-wins**, not capture-cadence pass-through:

- **Video:** the host's `ProgramPacer` consumes the input's frame stream into a latest-wins slot; on each program tick it takes the most recent frame and restamps it with the tick's clock time — a one-layer composition with no rendering. If no new frame arrived since the last tick, the previous frame is re-sent with the new tick's time (a stalled camera must not stall the stream); ticks before the first frame arrives send nothing.
- **Audio:** passes through at capture cadence with its true host-time PTS, untouched. Audio is continuous and unforgiving (rule 3); the tick paces video only.

This is the model applied to a single input rather than a departure from it: the design-principle-2 guarantees (output pacing independent of any input; constant-rate monotonic PTS into compression; `--fps` meaning what it says regardless of a camera's native cadence) hold on this path exactly as they do in the app.

**The compositor is the same rule over a layer tree** (`TingraComposition`, roadmap step 6). It holds a latest-wins slot per input and, on each tick, renders the current shot's layer tree over every slot's latest frame, stamped with the tick time: the pacer's "take the latest frame" replaced by "render the layer tree", with the tick, the slot semantics, and the timestamps unchanged. One refinement, decided 2026-07-06: the pacer sends nothing before the first frame arrives (a one-layer composition has nothing to show), but the compositor **renders from the first tick**, drawing the shot's background before any input delivers — a broadcast program is always a live canvas at the tick rate. The mixer does the same for audio, emitting silence from its first tick.

### Scheduler implementation

GCD is banned project wide, so the scheduler is a `SuspendingClock` based `Task.sleep(until:)` deadline loop, built in `HostClock`.

**Its clock must be `SuspendingClock`**, the one Swift clock on the host time clock's own timebase: both read `mach_absolute_time`, which stops while the Mac sleeps, so a deadline and the tick time stamped for it are the same instant. The loop was first built on `ContinuousClock`, which counts sleep, and that was a defect (found 2026-09-29): every tick-stamped time in the engine ran ahead of the captured inputs' true host times by the Mac's sleep since the stream started. It showed first on the bars' burned in time of day, 9 hours 22 minutes ahead after a working day. The full account is in `HostClock`'s doc comment.

**Benchmarked 2026-10-04, and the loop stays.** A throwaway harness ran the real `HostClock` beside three alternatives on an 11 core M3 Pro (macOS 26.6), every scheduler at once so each saw the same machine, 20 seconds a case, two to four runs. Lateness is the master clock's time when a tick reaches its consumer minus the deadline the tick is stamped with. The figures are the worst run's, in milliseconds; 30 and 60 fps read alike and share a row.

| Case | Scheduler | Mean | 99th percentile | Worst |
| :--- | :-------- | ---: | ---: | ---: |
| Quiet Mac (the app open) | `HostClock` loop, program tick | 1.8 | 4.1 | 6.3 |
| | `HostClock` loop, mix tick | 1.7 | 3.9 | 12.7 |
| | plain thread | 3.3 | 5.0 | 33.9 |
| | real time thread, its own wake | 0.02 | 0.05 | 0.09 |
| | real time thread, delivered to a task | 0.09 | 0.15 | 3.3 |
| Every core busy in other processes | `HostClock` loop, program tick | 2.7 | 8.2 | 9.3 |
| | `HostClock` loop, mix tick | 2.5 | 7.2 | 9.1 |
| | plain thread | 4.0 | 7.7 | 10.9 |
| | real time thread, its own wake | 0.00 | 0.01 | 0.01 |
| | real time thread, delivered to a task | 1.05 | 5.6 | 7.2 |
| Every core busy in this process's own tasks | `HostClock` loop, program tick | 2.0 | 4.0 | 7.2 |
| | `HostClock` loop, mix tick | 1.7 | 3.7 | 8.5 |
| | plain thread | 3.3 | 5.0 | 6.9 |
| | real time thread, its own wake | 0.02 | 0.05 | 0.08 |
| | real time thread, delivered to a task | 0.08 | 0.17 | 5.0 |

The schedulers: the **plain thread** sleeps on `mach_wait_until` at user interactive quality of service; the **real time thread** is the same loop under `THREAD_TIME_CONSTRAINT_POLICY`. "Its own wake" is when that thread wakes. "Delivered to a task" is when a consumer task receives the tick through an `AsyncStream`, which is what `HostClock` would have to do with it and the only figure comparable to the loop's. A fourth variant, the loop with its sleep's tolerance set to zero, read the same as the loop to within 0.05 ms in every case, so tolerance is not where the two milliseconds come from.

What it shows:

- **A real time thread is far tighter, and most of that survives delivery on a quiet Mac**: 0.09 ms mean against the loop's 1.8. A plain thread is no better than the loop, and slightly worse.
- **Under full outside load the advantage mostly goes.** The thread still wakes on time, but the consumer task waits for a core like any other, and the delivered tick's 99th percentile (5.6 ms) is close to the loop's (8.2 ms).
- **One stall, once.** In one quiet run every scheduler but the real time thread stalled for about 34 ms at the same moment. The loop skipped one tick at 30 fps and two at 60, as designed. The consumer task would have stalled with it, so a real time scheduler would not have saved the frame.

Why the loop stays: lateness never reaches a timestamp, because a tick is stamped with its deadline, not its arrival. All it moves is the instant "the latest frame" is sampled and the latency of the frame leaving the compositor, by a small fraction of a frame. A real time thread would buy back about two milliseconds of that latency on a quiet Mac, at the cost of a hand managed thread and thread policy per tick stream, and it would not prevent a skipped tick, which is decided by the consumer.

Two alternatives stay in reserve, to be reached for only if those two milliseconds come to matter (a low latency monitor path would be the reason): the real time thread measured here, and driving the tick from the audio render callback, the most reliable real time heartbeat on the platform. The choice is an implementation detail behind `HostClock`; nothing outside it may depend on which is in use.

### Late ticks

A tick is late in one of two ways: the scheduler itself wakes past later deadlines (the process was suspended, or its thread starved), or the consumer is still busy with the previous tick when the next deadline passes. A system sleep is neither: the scheduler's clock stops with the master clock, so the grid resumes where it paused and the first tick after the wake is on time (see "Scheduler implementation"). What happens then is the **consumer's** choice, made when it asks for the stream (`tick(every:lateTicks:)`, a `LateTickPolicy`), because rule 3 cuts both ways:

- **Skip — the default, and the program tick's rule.** A late consumer receives only the most recent due tick, never the backlog: the scheduler jumps its grid index to the latest deadline already due when it wakes late, and the stream buffers only the newest tick, so a slow consumer finds one current tick waiting rather than a queue. Ticks stay on the absolute `start + n × duration` grid and monotonic; a late stretch is a gap (dropped program frames), never a burst of stale renders. The compositor, the video generators, movie playback, the CLI's pacer, and the stream stats all use it. Movie audio is unaffected by a skipped tick: it is pulled by playback position, so the next tick delivers every block up to that position.
- **Catch up — for audio that must abut.** Every deadline is delivered, in order, however late. The **mix tick** and the **tone generator** use it: a skipped mix tick would be a hole in the program audio, and the samples it would have consumed stay in the channel queues, so every skipped block would add permanent latency to the monitor and the stream (up to the intake cap). Catching up mixes the missed blocks back to back with their own grid times, so the program audio stays contiguous — any lost capture shows up as silence at the right timestamps, not as a timeline that shrinks.

`tick(every:)` is `tick(every:lateTicks: .skip)`. The policy parameter arrived as an addition to the `EngineClock` seam with a default implementation forwarding to `tick(every:)`, so existing conformers — every synthetic test clock, which scripts each tick and is never late — are untouched (the plug-in API stability rules, ARCHITECTURE.md).

### Tick loops drain an autorelease pool per tick

Every loop driven by the tick stream (or draining a buffered frame or audio stream) that calls into Objective-C frameworks wraps each iteration's work in `autoreleasepool { }`. Core Image, AVFoundation, Core Text, and Foundation autorelease their results, and those results retain the frame's `IOSurface`-backed buffers. Swift concurrency drains the thread's pool when the task suspends, but a loop that has fallen behind always finds its next tick already waiting (every missed deadline under catch up, the newest one under skip) and **never suspends**, so without a per-tick pool every frame it renders stays alive: the compositor leaked 16,319 1080p buffers (126 GB) over a day this way before the pool went in (2026-09-26). The compositor, generator, movie, and mixer tick loops and the mixer's per-channel intake each carry one; a loop whose Objective-C work happens behind an `await` to another actor (the stream and recording drains) is already drained at that hop and needs none. A new tick loop that touches a framework adopts the pool in the same change, with a test that its autoreleased objects are freed between back-to-back ticks (the synthetic clock buffers every tick, which is exactly the case).

## System sleep and App Nap

**A system sleep stops the master clock and the scheduler together.** Both read `mach_absolute_time`, so a tick grid pauses with the sleep and resumes where it stopped, on time, with no late ticks and no jump in PTS. A session running when the Mac sleeps therefore produces nothing for the length of the sleep, and its destinations see the connection go quiet; the session's reconnect policy handles what follows the wake. Principle 2 covers a sleeping *display* and a stalled *input*, not a sleeping Mac.

**Nothing prevents the sleep today.** Neither the engine nor the app holds a power assertion or declares an activity while a session is live, and the app does not opt out of App Nap. App Nap, if it throttled the process while its windows were occluded, would show up as late ticks and be handled by the policies above (video skips, audio catches up) — degraded output, not a wrong timeline. Whether a running capture session already keeps the Mac awake in practice has not been checked. Holding the Mac and the process awake for the life of a session is unbuilt, and tracked in TODO.md.

## Timestamp rules

| Media | PTS rule |
| :---- | :------- |
| Captured video frame | Host time stamped by the capture framework, normalized by the input onto the master clock. For AVFoundation and ScreenCaptureKit the normalization is the identity. |
| Generated or file-backed frame | The time of the tick that produced it. A still image or text frame, which has no tick, carries the master clock's time at delivery. |
| Program video frame | The program tick's host clock time. Late ticks are skipped, so a late stretch leaves a gap in the sequence, never a burst of stale frames (see "Late ticks"). |
| Captured audio buffer | Actual host time of capture from `AVAudioTime.hostTime` — never a synthetic sample count position. The CLI's pass-through delivers it to the sinks; the mixer does not read it (see "Why the host time clock"). |
| Program audio block | The mix tick's host clock time (the mixer's blocks; see ARCHITECTURE.md, "The audio mixer"). A mixed block spans multiple inputs, so no single capture time exists for it; tick deadlines are absolute (`start + n × blockDuration`) and the mix tick catches up rather than skipping ("Late ticks"), so consecutive blocks are contiguous and monotonic by construction. |
| Into the sinks | `PTS = hostTime − T0`, where `T0` is the session's start on the master clock, shared by every sink of that session. |

- **`T0` belongs to a session.** A `StreamSession` reads the master clock once, after its destinations have connected, and rebases every frame and block onto that instant before any sink sees it. Every destination leg of the session, and its recording when it has one, share it — which is why several destinations are one session fanned out, never several sessions (ARCHITECTURE.md, "Multiple destinations"). The app runs streaming and recording as **two** sessions, so a recording made while streaming has its own `T0` and its own timeline; nothing compares the two.
- **Media stamped before `T0` is dropped, not clamped.** A buffer stamped before the session started has a negative session PTS and no place on the timeline, so the session drops it before any sink sees it. This matters most in the app, which attaches the program to a session before the session connects: the audio stream arrives holding every block mixed during the connect, up to a second of them. Delivering that backlog once left a whole stream's audio behind its video by the length of the connect (measured and fixed 2026-10-04; DONE.md, "Clock and timing").
- **Recording:** sinks receive already rebased media, so the `AVAssetWriter` session is anchored at zero (`startSession(atSourceTime: .zero)`), which is `T0` on the session timeline; video and audio tracks interleave by the PTS rules above.
- **Streaming:** frames appended to HaishinKit carry their session PTS. For audio, HaishinKit takes the first buffer's time as its anchor and extrapolates every later buffer from the accumulated sample count, so the per-buffer times the seam passes are not used after the first. With the mixer feeding it this loses nothing: mixed blocks are contiguous on the master clock by construction, so sample count and tick time agree. With the CLI's pass-through microphone it flattens the device's drift inside the library. The seam still passes true times, so another implementation behind `StreamingService` can honor them.
- PTS as seen by any sink is **monotonic**: the tick grid guarantees it for program video and program audio, and a passed-through capture stream is monotonic in its own right.

## Sync offset

**Not built.** This section is the design; no offset is applied anywhere today, and nothing is persisted. Tracked in TODO.md.

Real capture chains have unequal latency (a USB camera and an audio interface do not delay signals equally). Tingra will expose a **sync offset**: a signed millisecond adjustment — a global A/V offset first, then per input offsets. It is to be a first class, persisted setting (every serious broadcast tool has one), not a debug knob.

The offset belongs at the input's normalization point, so everything downstream sees already corrected media. What "corrected" means differs by path, because of who reads the timestamp:

- **Video into the compositor** is latest-wins by arrival, and the tick restamps it, so shifting a frame's PTS changes nothing. A video offset has to delay the frame's arrival in its slot.
- **Audio into the mixer** is consumed from a FIFO without reading PTS, so an audio offset has to be a delay in the channel's queue.
- **The CLI's pass-through audio** is the one place a timestamp shift alone does the job.

## The clock as a seam

The clock is exposed to the engine and to plug-ins as a small public protocol in `TingraPlugInKit`, bound by that package's API stability rules:

```swift
public protocol EngineClock: Sendable {
    var now: CMTime { get }                       // current master clock time
    func tick(every duration: CMTime) -> AsyncStream<CMTime>  // absolute-deadline tick stream; late ticks skipped
    func tick(every duration: CMTime, lateTicks: LateTickPolicy) -> AsyncStream<CMTime>  // .skip or .catchUp
}
```

- The production implementation, `HostClock` in `TingraHost`, wraps the host time clock and the pacing scheduler.
- Tests inject a **synthetic clock** advanced manually, making tick pacing, stall handling, drift absorption, and A/V alignment deterministically testable with generators — no camera, no waiting, in line with the project's "testable without hardware" commitment (SIMULATOR.md covers the other half of that story).
- Components receive the clock by initializer injection like every other dependency. There is no global "current clock."

## What each part of the engine does with time

| Component | Role |
| :-------- | :--- |
| **Host / frame transport** | Owns the production master clock and the pacing scheduler: the only code that reads the host time clock or decides when a tick fires. Owns each session's `T0` and the rebase onto it. |
| **Capture (inputs)** | Normalize framework timestamps onto the master clock. Never generate synthetic timestamps for real capture. The per input sync offset joins here when it is built. |
| **Generators** | Synthesize on their own tick and stamp output with the tick's time (synthetic clock time under test). Video generators skip late ticks; the tone generator catches up, so its audio abuts. The bars' time of day is the engine's one wall clock reading. |
| **Media inputs** | A movie plays on a tick at the file's own rate, each frame stamped with its tick and the audio pulled by playback position; latest wins absorbs a rate mismatch with the program. A still or text frame is stamped with the clock's time at delivery. |
| **Composition** | Renders "the current shot's layer tree for time T" on each tick. Beyond the latest frame per input, its only timing state is counted in ticks, not read from a clock: a transition's progress and the fade to black ramp, so both are exact under a synthetic clock. |
| **Audio** | The capture seam derives each buffer's PTS from `AVAudioTime`. The mixer queues samples per channel without reading that PTS, absorbs device drift at the queue, and stamps each mixed program block with its own mix tick's time. The monitor plays the mixed blocks on the output device's clock behind a bounded backlog. |
| **Compression / Output / Recording** | Consume the session PTS they are handed; never restamp it. Share their session's `T0`. |

## Open questions

- Frame rate conversion policy for inputs faster than the program rate (currently: latest wins, extras dropped silently — revisit if judder is observed).

Known defects and unbuilt work in this area are tracked in TODO.md, "Clock and timing": keeping the Mac awake during a session, the SRT service's own rate clock, an SRT audio lead of about 100 ms, and the sync offset.
