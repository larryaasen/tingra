# Clock and Timing

How Tingra keeps video and audio in sync from capture to destination. This document defines the master clock, the program tick that paces the compositor, and the timestamp rules every input, sink, and plug-in follows. Vocabulary follows GLOSSARY.md; the timing terms defined there (**master clock**, **timebase**, **program tick**, **sync offset**) originate here.

Timing is **host infrastructure**, not a feature service or a plug-in. Apply the host test from ARCHITECTURE.md: remove the clock and every plug-in breaks — capture cannot timestamp, composition cannot pace, audio cannot align, and no sink can mux. The clock therefore lives in the host beside the event bus and logging, as part of frame transport ("the GPU resident pipeline and its clock").

## Design principles

1. **One master clock.** Every timestamp in the system — captured frame PTS, program frame PTS, audio buffer PTS — is expressed against a single reference: the host time clock (`CMClockGetHostTimeClock()`, backed by `mach_absolute_time`). No component ever compares timestamps from two different clock domains.
2. **Output pacing is independent of any display or input.** A dedicated scheduler drives the program at the configured frame rate. The stream never stalls because a display slept or an input stopped producing.
3. **Timestamp accurately; never resample to force alignment.** Audio is continuous and unforgiving; video is forgiving. Both are stamped with their true position on the master clock, and the sinks interleave by PTS. Tingra does not stretch audio or repeat-drop video to fake sync.
4. **The clock is injected, never global.** Components receive the clock through a protocol so tests can substitute a synthetic clock and drive the pipeline deterministically, with no hardware and no wall clock waiting.

## Why the host time clock

ScreenCaptureKit and `AVCaptureVideoDataOutput` already stamp their `CMSampleBuffer`s against host time, and `AVAudioEngine` reports capture time as `AVAudioTime.hostTime`. The host time clock is therefore the reference the frames already arrive in. Choosing it means zero clock domain translation at the capture boundary — and clock domain translation is where drift bugs are born.

The audio hardware clock genuinely drifts relative to the host clock (crystal oscillators disagree by parts per million, which becomes audible A/V skew over a multi hour stream). Tingra absorbs this by rule 3 above: audio buffers are stamped with their **actual host time of capture** taken from `AVAudioTime`, not with a synthetic `sample count ÷ nominal sample rate` position. The drift then shows up honestly in the timestamps, and the sinks interleave correctly.

## The program tick

The compositor does not render when inputs deliver frames; it renders when the **program tick** fires.

- A host owned **pacing scheduler** fires at the program frame rate (30 fps → every 33.3 ms).
- Each tick's deadline is computed as an **absolute position on the master clock** — `T0 + n × frameDuration` — never `previous tick + interval`, so scheduling error cannot accumulate.
- On each tick, the compositor **pulls the most recent frame each input has produced** (double buffered, latest wins), renders the layer tree of the current shot, and stamps the resulting program frame with the tick's host clock PTS.
- The program frame then fans out to the sinks (streaming output, recording), all sharing that PTS.

### Why pull, not push

- **A stalled input does not stall the program.** If a camera hiccups or a window stops updating, the tick re-composites its last delivered frame and the stream keeps flowing — correct behavior for live.
- **Multiple inputs with different native cadences** (a 30 fps camera, a 60 Hz display, a 10 fps title generator) compose cleanly: each contributes whatever frame is current at tick time.
- **Compression rate control gets what it wants:** a clean, monotonic, constant rate PTS sequence.

### What does not drive the tick

- **Not `CVDisplayLink` / `CADisplayLink`.** Display links throttle or stop when the display sleeps or the app is occluded. A broadcaster must keep sending frames regardless. Display links are fine for pacing *preview drawing* — preview may sample the program at display rate — but preview never drives output.
- **Not a capture input's cadence.** With multiple inputs and shot switching, the "driving" input would keep changing, and its stalls would become program stalls.

### The tick before composition exists (CLI era)

Until the Metal compositor arrives (roadmap step 6), v1 streams one video input and one audio input with no composition stage. The program tick still applies (decided 2026-07-04) — the pipeline is **tick-paced latest-wins**, not capture-cadence pass-through:

- **Video:** the host's pacer consumes the input's frame stream into a latest-wins slot; on each program tick it takes the most recent frame and restamps it with the tick's clock time — a one-layer composition with no rendering. If no new frame arrived since the last tick, the previous frame is re-sent with the new tick's time (a stalled camera must not stall the stream); ticks before the first frame arrives send nothing.
- **Audio:** passes through at capture cadence with its true host-time PTS, untouched. Audio is continuous and unforgiving (rule 3); the tick paces video only.

This is the CLOCK.md model applied to a single input rather than a departure from it: the design-principle-2 guarantees (output pacing independent of any input; constant-rate monotonic PTS into compression; `--fps` meaning what it says regardless of a camera's native cadence) hold from v1 on, and when the compositor lands it replaces the pacer's "take the latest frame" with "render the layer tree" — the tick, the slot semantics, and the timestamps do not change.

### Scheduler implementation

GCD is banned project wide, so the scheduler is one of:

- a dedicated high priority thread sleeping until each absolute host clock deadline, or
- a `ContinuousClock` based `Task.sleep(until:)` deadline loop.

Start with whichever measures acceptably; **validate jitter by measurement** (tick timing error should be small relative to a frame duration, and dropped-tick behavior must be defined: skip, never burst). A known alternative is driving the tick from the audio render callback — the most reliable real time heartbeat on the platform. Tingra starts with the independent scheduler for simplicity and revisits only if measured sync is not tight enough. This choice is an implementation detail behind the host's frame transport; nothing outside the host may depend on it.

## Timestamp rules

| Media | PTS rule |
| :---- | :------- |
| Captured video frame | Host time stamped by the capture framework, normalized by the input onto the master clock. |
| Program video frame | The program tick's host clock time. |
| Audio buffer | Actual host time of capture from `AVAudioTime.hostTime` — never a synthetic sample count position. |
| Into the sinks | `PTS = hostTime − T0`, where `T0` is the session start on the master clock, shared by every sink. |

- **Recording:** `AVAssetWriter` starts with `startSession(atSourceTime:)` at the shared `T0`; video and audio tracks interleave by the PTS rules above.
- **Streaming:** buffers appended to HaishinKit carry the same shared timeline, so the muxed RTMP/SRT stream lip syncs at the destination.
- PTS as seen by any sink is **monotonic**; the host clock guarantees this for video ticks, and audio is monotonic per its own capture stream.

## Sync offset

Real capture chains have unequal latency (a USB camera and an audio interface do not delay signals equally). Tingra exposes a **sync offset**: a signed millisecond adjustment applied to timestamps — global A/V offset first, per input offsets when the mixer and multi input composition arrive. This is a first class, persisted setting (every serious broadcast tool has one), not a debug knob. Offsets are applied at the timestamp normalization point in the input path, so everything downstream — composition, sinks — sees already corrected times.

## The clock as a seam

The clock is exposed to the engine as a small host protocol (sketch, not final API):

```swift
protocol EngineClock: Sendable {
    var now: CMTime { get }                       // current master clock time
    func tick(every duration: CMTime) -> AsyncStream<CMTime>  // absolute-deadline tick stream
}
```

- The production implementation wraps the host time clock and the pacing scheduler.
- Tests inject a **synthetic clock** advanced manually, making tick pacing, stall handling, drift absorption, and A/V alignment deterministically testable with generators — no camera, no waiting, in line with the project's "testable without hardware" commitment (SIMULATOR.md covers the other half of that story).
- Components receive the clock by initializer injection like every other dependency. There is no global "current clock."

## What each part of the engine does with time

| Component | Role |
| :-------- | :--- |
| **Host / frame transport** | Owns the master clock and the pacing scheduler. The only code that decides what time it is or when a tick fires. |
| **Capture (inputs)** | Normalize framework timestamps onto the master clock; apply per input sync offset. Never generate synthetic timestamps for real capture. |
| **Generators** | Stamp synthesized frames with master clock time at generation (or synthetic clock time under test). |
| **Composition** | Pure function of the tick: "render the current shot's layer tree for time T." Holds no timing state beyond the latest frame per input. |
| **Audio** | Derives buffer PTS from `AVAudioTime` against the same clock; applies audio sync offset. |
| **Compression / Output / Recording** | Consume PTS; never modify it. Share `T0`. |

## Open questions

- Measured jitter of the `Task.sleep(until:)` loop vs. a dedicated thread on Apple Silicon under load — decide by benchmark during roadmap step 2–3.
- Whether preview sampling (display rate) needs its own decoupled path from day one or arrives with the app UI in phase 2–3.
- Frame rate conversion policy for inputs faster than the program rate (currently: latest wins, extras dropped silently — revisit if judder is observed).
