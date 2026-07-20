//
//  CoreImageShotRenderer.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import CoreMedia
import CoreVideo
import Metal
import TingraPlugInKit

/// The default ``ShotRenderer``: composites a shot's layer tree with Core
/// Image, GPU-resident through a Metal-backed `CIContext`
/// (ARCHITECTURE.md, "Composition" — Core Image supplies compositing
/// without hand-writing every shader; raw Metal shaders arrive only where
/// custom work or performance demands them, at a later effects step).
///
/// The pipeline stays on the GPU: each layer's `IOSurface`-backed
/// `CVPixelBuffer` becomes a `CIImage`, is scaled and placed into its
/// destination rect, and is composited over the background; the result
/// renders into an `IOSurface`-backed 32BGRA program buffer, tagged BT.709
/// (the delivery convention every buffer in the pipeline carries). A
/// **dissolve** (``renderDissolve(from:to:progress:frames:format:time:)``)
/// renders both shots' layer trees this same way and alpha-blends them —
/// no separate shader, just the layer-opacity math applied to the whole
/// incoming image. A **wipe**
/// (``renderWipe(from:to:edge:progress:frames:format:time:)``) renders both
/// trees the same way and blends them behind a soft-edged linear-gradient
/// mask swept across the frame — built-in Core Image filters, still no
/// custom shader. A **custom-shader transition**
/// (``renderShader(from:to:shader:progress:frames:format:time:)``) is where
/// hand-written Metal finally arrives: both trees blend through one of the
/// first-party stitchable Metal kernels (``TransitionShader``), compiled
/// once at first use from compiled-in source.
///
/// Not `Sendable` by design (see ``ShotRenderer``): an instance and its
/// `CIContext` and buffer pool live entirely inside the compositor's tick
/// task, so nothing here crosses an isolation boundary.
public final class CoreImageShotRenderer: ShotRenderer {
    /// The Core Image context that runs the compositing graph. Metal-backed
    /// in production; tests inject a software context for deterministic,
    /// GPU-free pixel checks.
    private let context: CIContext

    /// The output color space Core Image renders into: sRGB, tagged BT.709
    /// on the buffer afterward — the same SDR convention the generators use
    /// (their working space is device RGB with BT.709 tags).
    private let outputColorSpace: CGColorSpace

    /// The output buffer pool, `IOSurface`-backed 32BGRA. Created lazily for
    /// the program size and rebuilt if the size changes.
    private var pool: CVPixelBufferPool?

    /// The size the current ``pool`` produces, so a format change rebuilds it.
    private var poolSize: (width: Int, height: Int)?

    /// Creates the production renderer, Metal-backed where a GPU is present.
    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device)
        } else {
            self.context = CIContext()
        }
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Creates a renderer over an injected Core Image context (the test
    /// seam): a software `CIContext` makes compositing deterministic and
    /// GPU-free for unit tests.
    ///
    /// - Parameter context: The Core Image context to render with.
    init(context: CIContext) {
        self.context = context
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Composites the shot's layer tree into one program frame.
    public func render(
        shot: Shot,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        let image = layerTreeImage(shot: shot, frames: frames, format: format)
        return renderToBuffer(image, format: format, time: time)
    }

    /// Composites a dissolve: both shots' layer trees are rendered
    /// independently, then the incoming image is faded in over the outgoing
    /// one by `progress` — `0` shows `outgoing` alone, `1` shows `incoming`
    /// alone, and values between blend the two (a plain alpha crossfade,
    /// the same "fade toward the background" math ``placedImage(for:layer:format:)``
    /// already uses for layer opacity).
    public func renderDissolve(
        from outgoing: Shot,
        to incoming: Shot,
        progress: Double,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        let clampedProgress = min(max(progress, 0), 1)
        let outgoingImage = layerTreeImage(shot: outgoing, frames: frames, format: format)
        let incomingImage = layerTreeImage(shot: incoming, frames: frames, format: format)
        let fadedIncoming = incomingImage.applyingFilter(
            "CIColorMatrix",
            parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clampedProgress)]
        )
        let blended = fadedIncoming.composited(over: outgoingImage)
        return renderToBuffer(blended, format: format, time: time)
    }

    /// Composites a wipe: both shots' layer trees are rendered
    /// independently, then the incoming image is revealed from `edge` behind
    /// a moving, soft-edged boundary — a `CILinearGradient` mask swept
    /// across the frame drives `CIBlendWithMask` (white shows `incoming`,
    /// black keeps `outgoing`). The mask's blend band sits fully off-frame
    /// at progress `0` and fully past the far edge at progress `1`, so the
    /// endpoints render the outgoing and incoming shot exactly.
    public func renderWipe(
        from outgoing: Shot,
        to incoming: Shot,
        edge: WipeEdge,
        progress: Double,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        let clampedProgress = min(max(progress, 0), 1)
        let outgoingImage = layerTreeImage(shot: outgoing, frames: frames, format: format)
        let incomingImage = layerTreeImage(shot: incoming, frames: frames, format: format)
        let mask = wipeMask(edge: edge, progress: clampedProgress, format: format)
        let blended = incomingImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                "inputBackgroundImage": outgoingImage,
                "inputMaskImage": mask,
            ]
        )
        return renderToBuffer(blended, format: format, time: time)
    }

    /// Composites a custom-shader transition: both shots' layer trees are
    /// rendered independently, then blended per pixel by the built-in
    /// stitchable Metal kernel named by `shader`, its reveal ramping with
    /// `progress` — the endpoints render the outgoing and incoming shot
    /// exactly (each kernel's swept band, feathered like the wipe's, sits
    /// fully off its span at progress `0` and fully past it at `1`).
    ///
    /// If the kernel could not be compiled or refuses to apply — an
    /// environment defect, never expected for first-party source — the
    /// transition **degrades to the incoming shot** (visually a cut):
    /// returning `nil` would make the compositor skip every tick of the
    /// transition and freeze the program for its duration, where a visible
    /// early cut keeps the program live (ARCHITECTURE.md, "Custom-shader
    /// transitions").
    public func renderShader(
        from outgoing: Shot,
        to incoming: Shot,
        shader: TransitionShader,
        progress: Double,
        frames: [InputID: CapturedFrame],
        format: ProgramFormat,
        time: CMTime
    ) -> CapturedFrame? {
        let clampedProgress = min(max(progress, 0), 1)
        let outgoingImage = layerTreeImage(shot: outgoing, frames: frames, format: format)
        let incomingImage = layerTreeImage(shot: incoming, frames: frames, format: format)
        let programRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        guard
            let kernel = shaderKernels[shader],
            let blended = kernel.apply(
                extent: programRect,
                arguments: [
                    outgoingImage,
                    incomingImage,
                    Float(clampedProgress),
                    Float(format.width),
                    Float(format.height),
                ]
            )
        else {
            return renderToBuffer(incomingImage, format: format, time: time)
        }
        return renderToBuffer(blended, format: format, time: time)
    }

    /// The compiled transition kernels, keyed by shader — built once on
    /// first use (`lazy`, so a session that never takes a shader transition
    /// never compiles), inside the tick task like everything else in this
    /// renderer. A shader whose kernel did not compile is simply absent;
    /// ``renderShader(from:to:shader:progress:frames:format:time:)``
    /// degrades it to the incoming shot.
    private lazy var shaderKernels: [TransitionShader: CIColorKernel] = Self.compileShaderKernels()

    /// Compiles the first-party transition kernels from their compiled-in
    /// Metal source and maps them by ``TransitionShader`` — each kernel's
    /// Metal function name is the shader's raw value. Runtime compilation
    /// (`CIKernel.kernels(withMetalString:)`) keeps the build free of
    /// Metal-library plumbing and takes only these fixed constants as
    /// input — never a document, a file, or user input (the first-party-only
    /// security posture; ARCHITECTURE.md, "Custom-shader transitions"). A
    /// compile failure yields an incomplete map, never a crash.
    private static func compileShaderKernels() -> [TransitionShader: CIColorKernel] {
        guard let kernels = try? CIKernel.kernels(withMetalString: transitionShaderSource) else { return [:] }
        var compiled: [TransitionShader: CIColorKernel] = [:]
        for kernel in kernels {
            guard let shader = TransitionShader(rawValue: kernel.name), let colorKernel = kernel as? CIColorKernel
            else { continue }
            compiled[shader] = colorKernel
        }
        return compiled
    }

    /// The first-party transition shaders — the repo's first hand-written
    /// Metal, arriving exactly where ARCHITECTURE.md sequenced it ("raw
    /// Metal shaders arrive only where custom work demands them"). Each
    /// `[[stitchable]]` kernel shares one signature — the two shots'
    /// samples, the progress, the program size, and the destination — and
    /// one sweep rule, the wipe's: a feathered band (5% of the swept span)
    /// runs from fully off its span at progress 0 to fully past it at 1,
    /// so the endpoints are exact. Coordinates are flipped from Core
    /// Image's bottom-left origin into the operator's top-left screen
    /// terms (the `placedImage(for:layer:format:)` flip), so the diagonal
    /// opens from the screen's top-left and blinds reveal downward.
    private static let transitionShaderSource = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        /// The shared sweep: 1 where the boundary has revealed the incoming
        /// shot, 0 where the outgoing shot still shows, ramping across a
        /// feather band that trails the boundary.
        static float reveal(float distance, float span, float progress) {
            float feather = span * 0.05;
            float swept = -feather + progress * (span + feather);
            return 1.0 - smoothstep(swept, swept + feather, distance);
        }

        [[ stitchable ]] float4 iris(
            coreimage::sample_t outgoing, coreimage::sample_t incoming,
            float progress, float width, float height, coreimage::destination dest
        ) {
            float2 center = float2(width, height) * 0.5;
            float span = length(center);
            float d = distance(dest.coord(), center);
            return mix(outgoing, incoming, reveal(d, span, progress));
        }

        [[ stitchable ]] float4 diagonal(
            coreimage::sample_t outgoing, coreimage::sample_t incoming,
            float progress, float width, float height, coreimage::destination dest
        ) {
            float d = dest.coord().x + (height - dest.coord().y);
            return mix(outgoing, incoming, reveal(d, width + height, progress));
        }

        [[ stitchable ]] float4 blinds(
            coreimage::sample_t outgoing, coreimage::sample_t incoming,
            float progress, float width, float height, coreimage::destination dest
        ) {
            float band = height / 8.0;
            float d = fmod(height - dest.coord().y, band);
            return mix(outgoing, incoming, reveal(d, band, progress));
        }
        """

    /// The width of a wipe's soft edge as a fraction of the sweep span — a
    /// fixed, narrow feather so the moving boundary blends instead of
    /// crawling as a hard aliased line. An adjustable softness is a
    /// plausible later parameter of the wipe itself; this iteration keeps
    /// the transition contract to edge and duration.
    private static let wipeFeatherFraction = 0.05

    /// The wipe's grayscale mask: white where the incoming shot has been
    /// revealed, black where the outgoing shot still shows, ramping across a
    /// feather band that trails the boundary into the outgoing side.
    ///
    /// The revealed distance runs from `-feather` at progress `0` (the band
    /// entirely off-frame — pure outgoing) to the full sweep span at
    /// progress `1` (the band past the far edge — pure incoming). Edges are
    /// named in the operator's top-left-origin screen terms; Core Image's
    /// bottom-left origin flips the vertical cases here, the same flip
    /// ``placedImage(for:layer:format:)`` applies to layer frames.
    private func wipeMask(edge: WipeEdge, progress: Double, format: ProgramFormat) -> CIImage {
        let width = Double(format.width)
        let height = Double(format.height)
        let span =
            switch edge {
            case .left, .right: width
            case .top, .bottom: height
            }
        let feather = span * Self.wipeFeatherFraction
        let distance = -feather + progress * (span + feather)

        // The gradient's white point sits at the boundary (revealed side);
        // the black point sits one feather past it, into the outgoing side.
        let revealed: CGPoint
        let concealed: CGPoint
        switch edge {
        case .left:
            revealed = CGPoint(x: distance, y: 0)
            concealed = CGPoint(x: distance + feather, y: 0)
        case .right:
            revealed = CGPoint(x: width - distance, y: 0)
            concealed = CGPoint(x: width - distance - feather, y: 0)
        case .top:
            revealed = CGPoint(x: 0, y: height - distance)
            concealed = CGPoint(x: 0, y: height - distance - feather)
        case .bottom:
            revealed = CGPoint(x: 0, y: distance)
            concealed = CGPoint(x: 0, y: distance + feather)
        }

        let programRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard
            let gradient = CIFilter(
                name: "CILinearGradient",
                parameters: [
                    "inputPoint0": CIVector(cgPoint: revealed),
                    "inputColor0": white,
                    "inputPoint1": CIVector(cgPoint: concealed),
                    "inputColor1": black,
                ]
            )?.outputImage
        else {
            // The built-in gradient should always exist; if it ever does
            // not, keep the outgoing shot on program (an all-black mask)
            // rather than glitch — a renderer problem must never take down
            // the pipeline.
            return CIImage(color: black).cropped(to: programRect)
        }
        return gradient.cropped(to: programRect)
    }

    /// Composites one shot's layer tree, bottom to top, over its background —
    /// the shared pixel work behind ``render(shot:frames:format:time:)``,
    /// ``renderDissolve(from:to:progress:frames:format:time:)``, and
    /// ``renderWipe(from:to:edge:progress:frames:format:time:)``.
    private func layerTreeImage(shot: Shot, frames: [InputID: CapturedFrame], format: ProgramFormat) -> CIImage {
        let programRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        var image = backgroundImage(shot.background, in: programRect)
        for layer in shot.layers {
            guard let frame = frames[layer.input] else { continue }
            if let placed = placedImage(for: frame, layer: layer, format: format) {
                image = placed.composited(over: image)
            }
        }
        return image
    }

    /// Renders a composited image into a fresh output buffer, tags it
    /// BT.709, and stamps it with the tick time — the shared tail of both
    /// render paths.
    private func renderToBuffer(_ image: CIImage, format: ProgramFormat, time: CMTime) -> CapturedFrame? {
        guard let buffer = makeOutputBuffer(width: format.width, height: format.height) else { return nil }
        let programRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        context.render(image, to: buffer, bounds: programRect, colorSpace: outputColorSpace)
        tagBT709(buffer)
        return CapturedFrame(pixelBuffer: buffer, presentationTime: time)
    }

    /// The background as an infinite color image cropped to the program.
    private func backgroundImage(_ color: BackgroundColor, in rect: CGRect) -> CIImage {
        let ciColor = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        return CIImage(color: ciColor).cropped(to: rect)
    }

    /// One layer's frame, scaled into its destination rect (converting the
    /// layer's top-left-origin normalized frame into Core Image's
    /// bottom-left pixel space) and faded to its opacity. Returns nil when
    /// the destination is empty (a zero-size layer draws nothing).
    private func placedImage(for frame: CapturedFrame, layer: Layer, format: ProgramFormat) -> CIImage? {
        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let sourceExtent = source.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

        let width = Double(format.width)
        let height = Double(format.height)
        let destWidth = layer.frame.width * width
        let destHeight = layer.frame.height * height
        guard destWidth > 0, destHeight > 0 else { return nil }
        let destX = layer.frame.minX * width
        // Flip the top-left-origin normalized frame into bottom-left pixels.
        let destY = height * (1 - layer.frame.minY - layer.frame.height)

        var transform = CGAffineTransform(scaleX: destWidth / sourceExtent.width, y: destHeight / sourceExtent.height)
        transform = transform.concatenating(CGAffineTransform(translationX: destX, y: destY))
        var placed = source.transformed(by: transform)

        let opacity = min(max(layer.opacity, 0), 1)
        if opacity < 1 {
            placed = placed.applyingFilter(
                "CIColorMatrix",
                parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)]
            )
        }
        return placed
    }

    /// Fetches (or lazily builds) the output buffer pool for the program
    /// size and vends one `IOSurface`-backed 32BGRA buffer, or nil if the
    /// pool or a buffer cannot be created.
    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolSize?.width != width || poolSize?.height != height {
            pool = Self.makePool(width: width, height: height)
            poolSize = pool == nil ? nil : (width, height)
        }
        guard let pool else { return nil }
        var bufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut) == kCVReturnSuccess else {
            return nil
        }
        return bufferOut
    }

    /// Builds an `IOSurface`-backed 32BGRA pixel buffer pool for the given
    /// size (the GPU-resident program buffer type).
    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// Tags the buffer BT.709 — every `CVPixelBuffer` in the pipeline
    /// carries color attachments; an untagged buffer is a defect
    /// (ARCHITECTURE.md, "Color and pixel format conventions").
    private func tagBT709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }
}
