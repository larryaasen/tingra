# Tingra — Architecture & Technical Plan

Tingra is a native macOS live streaming and production application, written entirely in Swift and built on Apple's modern media stack. This document describes the technical architecture and the role each component plays, including where the HaishinKit library fits in.

## Design principles

1. **Mac-first, not cross-platform.** Every choice favors deep integration with macOS over portability. No Qt, no OpenGL, no ported abstractions.
2. **GPU-resident pipeline.** Frames stay on the GPU as `IOSurface`-backed buffers from capture through compositing to encode, avoiding expensive CPU round-trips.
3. **Modern Apple frameworks over reinvention.** ScreenCaptureKit, AVFoundation, Metal, VideoToolbox, and AVAudioEngine do the heavy lifting.
4. **Build the distinctive parts; adopt the thankless parts.** Capture and compositing are what make Tingra native and distinctive, so we own them. RTMP/SRT networking and muxing are hard, standardized, and undifferentiated, so we adopt a proven library (HaishinKit) rather than rebuild them.

## Pipeline overview

```
┌─────────────────────┐     ┌─────────────────────┐
│  ScreenCaptureKit   │     │    AVFoundation     │
│  (display/window/   │     │  (camera capture)   │
│   app capture)      │     │                     │
└──────────┬──────────┘     └──────────┬──────────┘
           │  IOSurface-backed          │  IOSurface-backed
           │  CVPixelBuffers            │  CVPixelBuffers
           └────────────┬───────────────┘
                        ▼
             ┌─────────────────────┐
             │   Metal compositor  │  ◄── Core Image filters,
             │  (scenes, layers,   │      transitions, effects
             │   transforms)       │
             └──────────┬──────────┘
                        │  composited frame
                        │  (IOSurface/CVPixelBuffer, GPU-resident)
                        ▼
             ┌─────────────────────┐
             │     VideoToolbox    │  ◄── hardware H.264 / HEVC
             │      encoder        │
             └──────────┬──────────┘
                        │  encoded H.264/HEVC
                        ▼
             ┌─────────────────────┐     ┌─────────────────────┐
             │      HaishinKit      │     │   Local recording   │
             │  (RTMP / SRT egress) │     │  (AVAssetWriter →   │
             │                      │     │   .mov / .mp4)      │
             └──────────┬──────────┘     └─────────────────────┘
                        ▼
               YouTube / Twitch / custom
               RTMP or SRT destinations

  Audio runs in parallel:
  AVFoundation / Core Audio inputs → AVAudioEngine mixing →
  encoded audio → muxed alongside video (recording + HaishinKit egress)
```

## Layers in detail

### Capture layer — *we own this*
- **ScreenCaptureKit (macOS 12.3+)** for display, window, and per-application capture. It delivers frames as `CMSampleBuffer` wrapping `IOSurface`-backed `CVPixelBuffer`s, which stay on the GPU.
- **AVFoundation** (`AVCaptureSession`) for camera and microphone input.
- The capture layer normalizes every source into a common GPU-resident frame type that the compositor consumes.

### Compositing layer — *we own this*
- **Metal** performs scene composition: positioning, scaling, cropping, and layering sources, plus transitions between scenes.
- **Core Image** (Metal-backed) supplies filters and effects without hand-writing every shader; drop to raw Metal shaders where custom work or performance demands it.
- Output is a single composited `CVPixelBuffer` per frame, still GPU-resident, handed to the encoder. This buffer is the **clean seam** described below.

### Encoding layer
- **VideoToolbox** for hardware-accelerated H.264 and HEVC. It accepts GPU-backed pixel buffers directly, so the Metal-composited frame feeds in without a CPU copy.
- Encoder settings (bitrate, keyframe interval, profile) are driven by the selected streaming target.

### Audio layer — *we own this*
- **AVAudioEngine / Core Audio** for capturing, mixing, and processing multiple audio sources (mics, application audio, media). Produces a mixed, encoded audio stream fed to both recording and egress.

### Output layer — *HaishinKit*
- **HaishinKit** (BSD 3-Clause) handles RTMP and SRT egress — the connection handling, retry logic, and muxing that Apple provides no framework for. WHIP/WHEP support is emerging in HaishinKit as well, giving a path to WebRTC output later.
- **Local recording** uses `AVAssetWriter` to write `.mov`/`.mp4` directly, independent of the streaming egress.

## How HaishinKit is incorporated (minimal-adoption approach)

HaishinKit is capable of doing capture, video mixing, and output on its own. Tingra deliberately uses **only its output layer**, for three reasons: it preserves Tingra's distinctive native capture/compositing story, it avoids inheriting HaishinKit's architecture across the whole app, and it isolates the dependency to a single, well-defined boundary.

**The clean seam:** Tingra's Metal compositor produces the composited frame; from that point, HaishinKit's session/stream objects are responsible for encoding-and-egress to RTMP/SRT. In practice this means feeding Tingra's composited video frames and mixed audio into HaishinKit's stream ingest interface, rather than letting HaishinKit attach directly to the camera or screen.

Concretely:
- Tingra owns `AVCaptureSession` / `SCStream` and the Metal compositor.
- HaishinKit is configured in **ingest mode** and receives the composited output.
- All RTMP/SRT connection setup, reconnection, and muxing is delegated to HaishinKit.
- A thin `StreamingService` protocol wraps HaishinKit so the rest of Tingra never imports it directly — this keeps the dependency swappable and the seam explicit.

```swift
// Sketch of the boundary — not final API.
protocol StreamingService {
    func start(to endpoint: StreamEndpoint) async throws
    func send(video frame: CVPixelBuffer, at time: CMTime)
    func send(audio buffer: CMSampleBuffer)
    func stop() async
}

// HaishinKit-backed implementation lives behind this protocol,
// so no other module in Tingra depends on HaishinKit directly.
struct HaishinKitStreamingService: StreamingService { /* ... */ }
```

### Dependency notes / caveats
- **License:** HaishinKit is BSD 3-Clause — permissive and compatible with Tingra's MIT license, including any future closed-source Pro tier.
- **Binary targets:** Recent HaishinKit ships some **binary-only targets**. Before committing, audit exactly which pieces are source-available versus prebuilt, since a fully-open build matters for an MIT open-source project. If any required target is binary-only and that's unacceptable, the `StreamingService` seam lets us swap in a librtmp/libsrt-based implementation later without touching the rest of the app.
- **Modules:** HaishinKit is split into modules (e.g. RTMP and SRT are separate). Pull in only what Tingra ships.
- **Integration:** Add via Swift Package Manager.

## UI layer
- **SwiftUI + AppKit**, with Metal preview content hosted in an `MTKView` (or a `CAMetalLayer` bridged into the view hierarchy).
- The interface exposes scenes, sources, the audio mixer, real-time preview, recording controls, and streaming destination configuration.

## Roadmap sequencing (suggested)

1. **Capture → Metal composite → local preview.** Get a single camera + a screen source compositing to an on-screen `MTKView`.
2. **Add VideoToolbox encode → local recording** via `AVAssetWriter`.
3. **Add HaishinKit output** behind the `StreamingService` seam; stream a single composited scene to an RTMP test endpoint.
4. **Scenes, layers, transitions, audio mixer** — flesh out the production feature set.
5. **SRT, multi-destination, and later WHIP/WHEP** as HaishinKit's support matures.

## Summary

Tingra owns the parts that make it native and distinctive — capture on ScreenCaptureKit/AVFoundation, compositing on Metal, audio on AVAudioEngine — and delegates the standardized, undifferentiated egress work to HaishinKit behind a thin `StreamingService` protocol. The entire media path stays GPU-resident from capture to encode, and the HaishinKit dependency is isolated to a single swappable seam, keeping the project MIT-clean and future-proof.
