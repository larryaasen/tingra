//
//  CameraPreviewView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import AppKit
import SwiftUI
import TingraPlugInKit

/// The live video view: it hosts an `AVSampleBufferDisplayLayer` and draws
/// the frames the engine delivers for the selected camera.
///
/// This is the integration seam for the Tingra engine. The view registers a
/// frame sink with the window's ``CameraSession`` on appear; the engine pulls frames
/// from the selected camera's `Input` and hands each `CapturedFrame`
/// (`IOSurface`-backed 32BGRA) here, where it is enqueued onto the display
/// layer for the GPU to present — no capture framework or session is
/// touched by the view layer.
///
/// The preview is also the Maps-style framing surface (docs/UVC.md, "The
/// Tingra Cameras controls panel"): dragging the picture pans and tilts the
/// camera, and a trackpad pinch or an Option-scroll zooms it. The gestures
/// are handled by the AppKit view itself, which receives every mouse,
/// magnify, and scroll event over the video, and forwarded to the model.
///
/// Its context menu holds **Copy** (the camera's current frame to the
/// pasteboard) and **Cross Bars** (lines through the centre of the
/// preview), the same two commands the Edit and View menus carry
/// (``PreviewCommands``).
struct CameraPreviewView: NSViewRepresentable {
    /// The shared model, for the cross bars every window's preview shows.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session, used to register and remove the frame
    /// sink and to move the framing of the window's camera.
    @Environment(CameraSession.self) private var session

    /// Creates the display-layer host view and wires it as the session's
    /// frame sink so live frames flow straight to the layer.
    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        session.attachPreview(
            id: ObjectIdentifier(view),
            renderFrame: { [weak view] frame in view?.enqueue(frame) },
            flush: { [weak view] in view?.flush() }
        )
        let model = model
        let session = session
        view.onFramingDrag = { [weak session] translation, size in
            session?.dragFraming(by: translation, in: size)
        }
        view.onFramingZoom = { [weak session] fraction in
            session?.zoomFraming(byFraction: fraction)
        }
        view.onFramingGestureEnded = { [weak session] gesture in
            session?.endFramingGesture(gesture.tapName)
        }
        view.onCopy = { [weak session] in
            session?.copyFrame(from: "contextMenu")
        }
        view.onToggleCrossBars = { [weak model] in
            model?.toggleCrossBars(from: "contextMenu")
        }
        view.showsCrossBars = model.showsCrossBars
        return view
    }

    /// Shows or hides the cross bars. Frames arrive through the registered
    /// sink, not through SwiftUI state, so this is the only per-update work.
    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        nsView.showsCrossBars = model.showsCrossBars
    }

    /// Removes this preview's frame sink when it is torn down so the engine
    /// stops drawing into a dead view.
    static func dismantleNSView(_ nsView: SampleBufferHostView, coordinator: Coordinator) {
        coordinator.session.detachPreview(id: ObjectIdentifier(nsView))
    }

    /// Creates the coordinator that retains the session for teardown.
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    /// Holds the session so ``dismantleNSView(_:coordinator:)`` can detach
    /// the preview sink; the representable value itself is not kept around.
    final class Coordinator {
        /// The session whose preview sink this view registered.
        let session: CameraSession

        /// Creates a coordinator retaining the given session.
        init(session: CameraSession) {
            self.session = session
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
    /// filling the frame while preserving the camera's aspect ratio, with
    /// the cross bars drawn over it.
    override func makeBackingLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        crossBarsLayer.fillColor = nil
        crossBarsLayer.lineWidth = 1
        crossBarsLayer.isHidden = !showsCrossBars
        layer.addSublayer(crossBarsLayer)
        return layer
    }

    /// The cross bars: one line across and one down through the centre of
    /// the preview, drawn on a layer over the video so they are never part
    /// of the frame — a copied frame has none.
    private let crossBarsLayer = CAShapeLayer()

    /// Whether the cross bars show over the video.
    var showsCrossBars = false {
        didSet {
            guard showsCrossBars != oldValue else { return }
            updateCrossBars()
        }
    }

    /// Called when the context menu's Copy is chosen.
    var onCopy: (() -> Void)?

    /// Called when the context menu's Cross Bars is chosen.
    var onToggleCrossBars: (() -> Void)?

    /// Keeps the cross bars through the centre as the preview resizes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCrossBars()
    }

    /// Redraws the cross bars in the new accent color when the appearance
    /// changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCrossBars()
    }

    /// Keeps the cross bars sharp on a display with a different scale.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        crossBarsLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Lays the cross bars over the current bounds in the system accent
    /// color, without the implicit animation a layer change would bring.
    private func updateCrossBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        crossBarsLayer.isHidden = !showsCrossBars
        guard showsCrossBars else { return }
        crossBarsLayer.frame = bounds
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        crossBarsLayer.path = path
        effectiveAppearance.performAsCurrentDrawingAppearance {
            crossBarsLayer.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    /// The preview's context menu: Copy, then Cross Bars, checked while
    /// they show.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(
            title: String(localized: "Copy"),
            action: #selector(copyFromContextMenu(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)
        let crossBars = NSMenuItem(
            title: String(localized: "Cross Bars"),
            action: #selector(toggleCrossBarsFromContextMenu(_:)),
            keyEquivalent: ""
        )
        crossBars.target = self
        crossBars.state = showsCrossBars ? .on : .off
        menu.addItem(crossBars)
        return menu
    }

    /// The context menu's Copy.
    @objc private func copyFromContextMenu(_ sender: NSMenuItem) {
        onCopy?()
    }

    /// The context menu's Cross Bars.
    @objc private func toggleCrossBarsFromContextMenu(_ sender: NSMenuItem) {
        onToggleCrossBars?()
    }

    /// Requests a layer-backed view so `makeBackingLayer` is used.
    override var wantsUpdateLayer: Bool { true }

    /// A framing gesture over the preview, reported when it ends.
    enum FramingGesture {
        /// A drag across the picture: pan and tilt.
        case drag
        /// A trackpad pinch: zoom.
        case pinch
        /// An Option-scroll: zoom.
        case scroll

        /// The gesture's `tap` name (EVENTS.md, "The `tap` convention").
        var tapName: String {
            switch self {
            case .drag: "cameraFraming.drag"
            case .pinch: "cameraFraming.pinch"
            case .scroll: "cameraFraming.scroll"
            }
        }
    }

    /// Called as the pointer drags across the picture, with its movement in
    /// points (y growing downward) and the view's size.
    var onFramingDrag: ((_ translation: CGSize, _ viewSize: CGSize) -> Void)?

    /// Called as a pinch or Option-scroll zooms, with the amount as a
    /// fraction of the zoom range (positive zooms in).
    var onFramingZoom: ((_ fraction: Double) -> Void)?

    /// Called once when a framing gesture ends.
    var onFramingGestureEnded: ((FramingGesture) -> Void)?

    /// Whether the current click has become a drag, so a plain click ends
    /// no gesture.
    private var isDragging = false

    /// How far a precise (trackpad) Option-scroll must travel, in points,
    /// to zoom across the whole range.
    private static let preciseScrollSpan = 400.0

    /// How many wheel lines an Option-scroll on a mouse takes to zoom
    /// across the whole range.
    private static let lineScrollSpan = 20.0

    /// Takes the first click even while the window is inactive, so a drag
    /// on the preview frames the camera straight away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Starts tracking a possible drag; a click alone does nothing. A
    /// Control-click opens the context menu, as a right-click does.
    override func mouseDown(with event: NSEvent) {
        isDragging = false
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    /// Reports the pointer's movement as a framing drag.
    override func mouseDragged(with event: NSEvent) {
        isDragging = true
        onFramingDrag?(CGSize(width: event.deltaX, height: event.deltaY), bounds.size)
    }

    /// Ends a framing drag.
    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onFramingGestureEnded?(.drag)
    }

    /// Reports a trackpad pinch as a zoom; spreading the fingers zooms in.
    override func magnify(with event: NSEvent) {
        onFramingZoom?(Double(event.magnification))
        if event.phase == .ended || event.phase == .cancelled {
            onFramingGestureEnded?(.pinch)
        }
    }

    /// Reports an Option-scroll as a zoom — scrolling up zooms in — and
    /// passes any other scroll on, so the panel below still scrolls.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let onFramingZoom else {
            super.scrollWheel(with: event)
            return
        }
        let span = event.hasPreciseScrollingDeltas ? Self.preciseScrollSpan : Self.lineScrollSpan
        onFramingZoom(Double(event.scrollingDeltaY) / span)
        // A mouse wheel's notches carry no phase: each is a gesture.
        let isNotch = event.phase.isEmpty && event.momentumPhase.isEmpty
        if isNotch || event.phase == .ended {
            onFramingGestureEnded?(.scroll)
        }
    }

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
