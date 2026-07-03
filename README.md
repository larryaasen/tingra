# Tingra — Native Live Streaming for macOS

Tingra is a free, open-source live streaming and production application built exclusively for macOS. It bets on being Mac-first and Swift-native end to end — a real SwiftUI/AppKit app built directly on Apple's media stack, not a cross-platform tool ported to the Mac.

Under the hood, Tingra is written entirely in Swift. It captures displays, windows, and applications through ScreenCaptureKit, and cameras and microphones through AVFoundation. Shot compositing, transitions, and visual effects run on Metal, Apple's modern GPU framework, with Core Image for filters. Compression is handled by VideoToolbox for hardware-accelerated H.264 and HEVC, and audio mixing runs through AVAudioEngine. Captured frames stay GPU-resident from capture through compositing to compression, avoiding costly CPU round-trips. Tingra's real differentiation is combining a genuinely native Swift/SwiftUI codebase with being fully open source, a combination nothing else currently offers.

Tingra offers the essentials creators expect: presets and shots, layered inputs, audio mixing, real-time preview, recording, and streaming to any RTMP or SRT destination, including YouTube, Twitch, and custom servers. The interface is built in SwiftUI and AppKit, so it looks and behaves like a real Mac app rather than a transplanted one.

The project targets a narrow but real gap. Native-feeling streaming apps for the Mac exist (e.g. Ecamm Live), but they are commercial and closed-source. Full-featured open-source tools exist, but none are Swift-native, Metal-based, or built with a native Mac UI framework. Tingra aims to be the missing piece: an open-source, transparent, genuinely Mac-native broadcaster — not necessarily a faster one.

Tingra is for streamers, educators, podcasters, and developers who want a fast, focused, native tool — and who believe the best Mac software is built with the platform, not around it.

## License

Tingra is released under the [MIT License](LICENSE).
