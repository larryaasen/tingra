# Tingra — Native Live Streaming for macOS

Tingra is a free, open-source live streaming and production application built exclusively for macOS. Where today's dominant tools are cross-platform and built on aging, deprecated graphics APIs, Tingra takes the opposite bet: be Mac-first, be native, and use Apple's modern media stack end to end.

Under the hood, Tingra is written entirely in Swift. It captures displays, windows, and applications through ScreenCaptureKit, and cameras and microphones through AVFoundation. Scene compositing, transitions, and visual effects run on Metal, Apple's modern GPU framework, with Core Image for filters. Encoding is handled by VideoToolbox for hardware-accelerated H.264 and HEVC, and audio mixing runs through AVAudioEngine. Captured frames stay GPU-resident from capture through compositing to encode, avoiding the costly CPU round-trips that burden cross-platform tools. The result is a streamer that is lighter, cooler, and more power-efficient on Apple Silicon than anything ported from another platform.

Tingra offers the essentials creators expect: multiple scenes, layered sources, audio mixing, real-time previews, recording, and streaming to any RTMP or SRT destination, including YouTube, Twitch, and custom servers. The interface is built in SwiftUI and AppKit, so it looks and behaves like a real Mac app rather than a transplanted one.

The project fills a genuine gap. Excellent native streaming apps for the Mac exist, but they are commercial and closed-source. Powerful open-source tools exist, but none are Swift-native or Metal-based. Tingra aims to be the missing piece: a community-owned, transparent, genuinely Mac-native broadcaster.

Tingra is for streamers, educators, podcasters, and developers who want a fast, focused, native tool — and who believe the best Mac software is built with the platform, not around it. Contributions welcome.

## License

Tingra is released under the [MIT License](LICENSE).
