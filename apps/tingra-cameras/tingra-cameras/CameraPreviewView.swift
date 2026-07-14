//
//  CameraPreviewView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import SwiftUI
import TingraPlugInKit

/// The live video view: it hosts an `AVSampleBufferDisplayLayer` and draws
/// the frames the engine delivers for the selected camera.
///
/// This is the integration seam for the Tingra engine. The view registers a
/// frame sink with the ``HardwareModel`` on appear; the engine pulls frames
/// from the selected camera's `Input` and hands each `CapturedFrame`
/// (`IOSurface`-backed 32BGRA) here, where it is enqueued onto the display
/// layer for the GPU to present — no capture framework or session is
/// touched by the view layer.
struct CameraPreviewView: NSViewRepresentable {
    /// The shared model, used to register and remove the frame sink.
    @Environment(HardwareModel.self) private var model

    /// Creates the display-layer host view and wires it as the model's frame
    /// sink so live frames flow straight to the layer.
    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        model.attachPreview(
            renderFrame: { [weak view] frame in view?.enqueue(frame) },
            flush: { [weak view] in view?.flush() }
        )
        return view
    }

    /// No per-update work: frames arrive through the registered sink, not
    /// through SwiftUI state.
    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {}

    /// Removes the frame sink when the preview is torn down so the engine
    /// stops drawing into a dead view.
    static func dismantleNSView(_ nsView: SampleBufferHostView, coordinator: Coordinator) {
        coordinator.model.detachPreview()
    }

    /// Creates the coordinator that retains the model for teardown.
    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    /// Holds the model so ``dismantleNSView(_:coordinator:)`` can detach the
    /// preview sink; the representable value itself is not kept around.
    final class Coordinator {
        /// The model whose preview sink this view registered.
        let model: HardwareModel

        /// Creates a coordinator retaining the given model.
        init(model: HardwareModel) {
            self.model = model
        }
    }
}

/// A layer-hosting `NSView` whose backing layer is an
/// `AVSampleBufferDisplayLayer`, the surface the engine's frames are
/// presented on.
///
/// It is the AppKit bridge SwiftUI lacks natively for displaying a stream of
/// `CVPixelBuffer`s; each frame is wrapped in a `CMSampleBuffer` marked for
/// immediate display and enqueued on the layer's renderer.
final class SampleBufferHostView: NSView {
    /// The backing layer, typed for enqueuing sample buffers.
    private var displayLayer: AVSampleBufferDisplayLayer {
        // The backing layer is created by `makeBackingLayer`; fall back to a
        // fresh layer rather than force-unwrapping so a misconfigured view
        // can never trap the host (CLAUDE.md, never-crash rule).
        layer as? AVSampleBufferDisplayLayer ?? AVSampleBufferDisplayLayer()
    }

    /// Enables layer backing at construction time; the backing layer itself
    /// is created (and configured) by `makeBackingLayer`.
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    /// Not available from a nib/storyboard; this view is created in code.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SampleBufferHostView is created in code, not from a coder.")
    }

    /// Adopts a sample-buffer display layer as the view's backing layer,
    /// filling the frame while preserving the camera's aspect ratio.
    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    /// Requests a layer-backed view so `makeBackingLayer` is used.
    override var wantsUpdateLayer: Bool { true }

    /// Presents one captured frame by enqueuing it on the display renderer.
    ///
    /// - Parameter frame: The engine frame to draw. Ownership transfers at
    ///   this call per the frame ownership rule; the frame is not retained
    ///   after it is enqueued.
    func enqueue(_ frame: CapturedFrame) {
        let renderer = displayLayer.sampleBufferRenderer
        // A renderer that has entered the failed state (e.g. a transient
        // decode/enqueue error) must be flushed before it will accept
        // frames again; otherwise the feed would silently stall.
        if renderer.status == .failed {
            renderer.flush()
        }
        guard let sampleBuffer = Self.makeSampleBuffer(from: frame) else { return }
        renderer.enqueue(sampleBuffer)
    }

    /// Drops any displayed frame, used when switching cameras so the previous
    /// camera's last frame does not linger under the new one.
    ///
    /// Plain `flush()` only discards pending, not-yet-displayed sample
    /// buffers — the frame already on screen stays there until a new one
    /// arrives. `flush(removingDisplayedImage:)` also clears that frame, so
    /// the canvas actually goes blank when there is no new camera to show it.
    func flush() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Wraps a captured pixel buffer in a `CMSampleBuffer` marked for
    /// immediate display.
    ///
    /// The renderer has no control timebase, so each buffer is flagged
    /// "display immediately" and shown as it arrives — the right model for a
    /// live preview, where the newest frame always wins.
    ///
    /// - Parameter frame: The frame whose pixel buffer to wrap.
    /// - Returns: A ready sample buffer, or `nil` if one could not be built.
    private static func makeSampleBuffer(from frame: CapturedFrame) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            as? [NSMutableDictionary]
        {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
        }
        return sampleBuffer
    }
}
