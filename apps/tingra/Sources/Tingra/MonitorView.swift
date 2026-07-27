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

/// An on-screen monitor over one of the compositor's buses: an `MTKView`
/// that samples the latest frame from the given relay and draws it,
/// aspect-fit and centered, at the display's rate. One instance monitors
/// **program**, another monitors **preview** — the view is the bus-agnostic
/// half, and the relay it is handed decides which bus it shows.
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
    /// The shared relay holding the latest frame of the bus this monitor
    /// shows.
    let relay: ProgramFrameRelay

    /// Builds the drawing coordinator.
    func makeCoordinator() -> Coordinator {
        Coordinator(relay: relay)
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
    /// frame from the relay each draw.
    func updateNSView(_ nsView: MTKView, context: Context) {}

    /// Draws the bus's latest frame into the `MTKView`'s drawable with
    /// Core Image, GPU-resident. `@MainActor`: `MTKView` calls the delegate
    /// on the main run loop.
    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        /// The Metal device backing the view and the Core Image context, or
        /// nil if the platform has no GPU (not expected on Apple Silicon).
        let device: MTLDevice?

        /// The shared relay the draw loop samples.
        private let relay: ProgramFrameRelay

        /// The command queue for the drawing command buffers.
        private let commandQueue: MTLCommandQueue?

        /// The Core Image context that renders a frame into the drawable.
        private let ciContext: CIContext

        /// The output color space the preview renders into (sRGB, matching
        /// the pipeline's SDR BT.709 delivery convention).
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        /// Creates a coordinator sampling the given bus relay.
        init(relay: ProgramFrameRelay) {
            self.relay = relay
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            self.ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
        }

        /// No per-size state to update; drawing recomputes the fit each frame.
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Renders the bus's current frame, aspect-fit and centered, into
        /// the drawable. Draws nothing (leaving the black clear color) until
        /// the first frame arrives — which for preview means until a shot is
        /// staged.
        func draw(in view: MTKView) {
            guard
                let commandQueue,
                let pixelBuffer = relay.latest,
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

            ciContext.render(
                fitted,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: target),
                colorSpace: colorSpace
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
