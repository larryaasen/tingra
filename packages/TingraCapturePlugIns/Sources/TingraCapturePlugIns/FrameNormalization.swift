//
//  FrameNormalization.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo

/// The color-tagging half of input normalization: every `CVPixelBuffer` in
/// the pipeline carries color attachments — an untagged buffer is a defect
/// (ARCHITECTURE.md, "Color and pixel format conventions"). Conversion
/// happens once, at the input seam; downstream stages trust these tags and
/// never re-convert.
enum FrameNormalization {
    /// Tags the buffer BT.709 where the capture framework left attachments
    /// unset, preserving any tags already present (the framework knows the
    /// true colorimetry better than a default does).
    static func tagBT709IfUntagged(_ buffer: CVPixelBuffer) {
        if CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) == nil {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate
            )
        }
        if CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) == nil {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate
            )
        }
        if CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil {
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
        }
    }
}
