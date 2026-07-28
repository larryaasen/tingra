//
//  MonitorView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreVideo
@preconcurrency import MetalKit
import SwiftUI

/// Where a monitor reads the frame it is about to draw: the bus-agnostic
/// (and now input-agnostic) half of ``MonitorView``.
///
/// Two things conform. ``ProgramFrameRelay`` holds the latest frame of a
/// **bus**, written by the model's program or preview drain. An
/// `InputFrameSource` reads one **input**'s latest frame straight from the
/// compositor's latest-wins slot for a multiview tile (ARCHITECTURE.md,
/// "Multiview"). Both are sampled the same way — a plain read on each draw,
/// at display cadence (CLOCK.md) — which is what lets program, preview, and
/// every tile share one draw path instead of three that could drift.
@MainActor
protocol MonitorFrameSource {
    /// The frame to draw now, or nil before the first one arrives (which
    /// for preview means until a shot is staged, and for an input tile
    /// means until that input delivers).
    var latest: CVPixelBuffer? { get }
}

/// The Metal device, command queue, and Core Image context every monitor
/// draws through.
///
/// Shared rather than per-view: with multiview open the app draws program,
/// preview, and one tile per running input at display rate, and a `CIContext`
/// per view would mean that many shader caches and texture pools for one
/// identical job.
@MainActor
final class MonitorRenderContext {
    /// The context every ``MonitorView`` in the app draws through.
    static let shared = MonitorRenderContext()

    /// The Metal device backing the views and the Core Image context, or
    /// nil if the platform has no GPU (not expected on Apple Silicon).
    let device: MTLDevice?

    /// The command queue for the drawing command buffers.
    let commandQueue: MTLCommandQueue?

    /// The Core Image context that renders a frame into a drawable.
    let ciContext: CIContext

    /// The output color space monitors render into (sRGB, matching the
    /// pipeline's SDR BT.709 delivery convention).
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Creates the context from the system default Metal device.
    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }
}

/// An on-screen monitor over one of the compositor's buses — or, in
/// multiview, over one input: an `MTKView` that samples the latest frame
/// from the given source and draws it, aspect-fit and centered, at the
/// display's rate. One instance monitors **program**, another monitors
/// **preview**, and multiview adds one per running input — the view is the
/// source-agnostic half, and the ``MonitorFrameSource`` it is handed decides
/// what it shows.
///
/// Named for what it is rather than for program alone (it was
/// `ProgramPreviewView` while program was the only bus): with the preview bus
/// landed, "preview" names the staging bus in this codebase (GLOSSARY.md,
/// "Preview"), so a type called `…PreviewView` that renders *program* would
/// read as exactly the wrong thing.
///
/// This is the ARCHITECTURE.md "UI layer" plan realized — Metal preview
/// content hosted in an `MTKView` — and CLOCK.md's preview-sampling rule:
/// the monitor draws whatever frame is current at display rate and never
/// drives the program tick itself (the compositor does). Core Image
/// composites the frame into the drawable, so the path stays GPU-resident.
struct MonitorView: NSViewRepresentable {
    /// Where this monitor reads the frame it draws — a bus's relay, or one
    /// input's slot in multiview.
    let source: any MonitorFrameSource

    /// Builds the drawing coordinator.
    func makeCoordinator() -> Coordinator {
        Coordinator(source: source)
    }

    /// Creates the `MTKView`, configured for Core Image drawing at display
    /// rate.
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        // Core Image renders into the drawable's texture, so the framebuffer
        // must be readable/writable, not framebuffer-only.
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Draw continuously at display rate, sampling the latest frame —
        // the program tick, not the view, paces the compositor.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    /// Nothing to push on SwiftUI updates — the coordinator pulls the latest
    /// frame from the source each draw.
    func updateNSView(_ nsView: MTKView, context: Context) {}

    /// Draws the source's latest frame into the `MTKView`'s drawable with
    /// Core Image, GPU-resident. `@MainActor`: `MTKView` calls the delegate
    /// on the main run loop.
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        /// The Metal device backing the view, from the shared render
        /// context.
        var device: MTLDevice? { renderContext.device }

        /// Where the draw loop samples its frame.
        private let source: any MonitorFrameSource

        /// The device, queue, and Core Image context shared by every
        /// monitor in the app.
        private let renderContext = MonitorRenderContext.shared

        /// Creates a coordinator sampling the given source.
        init(source: any MonitorFrameSource) {
            self.source = source
        }

        /// No per-size state to update; drawing recomputes the fit each frame.
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Renders the source's current frame, aspect-fit and centered, into
        /// the drawable. Draws nothing (leaving the black clear color) until
        /// the first frame arrives — which for preview means until a shot is
        /// staged, and for a multiview tile means until that input delivers.
        ///
        /// The frame is read, drawn, and dropped within this call: a monitor
        /// never accumulates frames, which would starve a capture
        /// framework's buffer pool (ARCHITECTURE.md, "Frame ownership across
        /// the `Input` seam", clause 4).
        func draw(in view: MTKView) {
            guard
                let commandQueue = renderContext.commandQueue,
                let pixelBuffer = source.latest,
                let drawable = view.currentDrawable,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let source = image.extent
            let target = view.drawableSize
            guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return }

            let scale = min(target.width / source.width, target.height / source.height)
            let scaledWidth = source.width * scale
            let scaledHeight = source.height * scale
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(
                    CGAffineTransform(
                        translationX: (target.width - scaledWidth) / 2,
                        y: (target.height - scaledHeight) / 2
                    )
                )
            let fitted = image.transformed(by: transform)

            renderContext.ciContext.render(
                fitted,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: target),
                colorSpace: renderContext.colorSpace
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// One framed monitor: the `MTKView` over a frame source, letterboxed on
/// black, rounded, and badged with what it is showing.
///
/// Shared by the main window's program and preview monitors and by every
/// multiview tile, so the two surfaces cannot drift in how a monitor reads —
/// the lesson `MeterCapsule` learned on the audio side.
struct MonitorTile: View {
    /// Where the monitor reads its frames.
    let source: any MonitorFrameSource

    /// What this monitor is showing: a bus name, or an input's name.
    let label: Text

    /// The badge's tint.
    let badgeTint: Color

    /// The **tally** border's tint, or nil for no border (GLOSSARY.md,
    /// "Tally"). The main window's two monitors pass nil: their position
    /// and their labels already say which bus is which, so a border would
    /// carry no information there. Multiview tiles are interchangeable, so
    /// the border is what makes an on-air input findable at a glance.
    var borderTint: Color?

    /// The monitor: video, tally border, then badge.
    var body: some View {
        MonitorView(source: source)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                if let borderTint {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(borderTint, lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                label
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(badgeTint.opacity(0.85), in: .capsule)
                    .foregroundStyle(.white)
                    .padding(8)
            }
    }
}
