//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
import CMediaEngine
import Foundation

/// Still-image decoding and JPEG encoding through the media engine.
public enum ImageCodec {
    /// Decodes PNG, JPEG, BMP, GIF, WebP or ICO data into straight-alpha RGBA8 pixels.
    public static func decode(_ data: Data) throws -> (rgba: [UInt8], width: Int, height: Int) {
        var buffer = MpvfxBuffer(data: nil, len: 0)
        var width: UInt32 = 0
        var height: UInt32 = 0
        let status = data.withUnsafeBytes { bytes in
            mpvfx_image_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &buffer, &width, &height)
        }
        try MediaError.check(status)
        let pixels = takeBuffer(&buffer) { Array($0) }
        return (pixels, Int(width), Int(height))
    }

    /// Baseline JPEG of straight RGBA8 pixels (alpha ignored); `quality` is clamped to 1 ... 100.
    public static func encodeJPEG(rgba: [UInt8], width: Int, height: Int, quality: Int = 85) throws -> Data {
        var buffer = MpvfxBuffer(data: nil, len: 0)
        let q = UInt32(min(100, max(1, quality)))
        let status = rgba.withUnsafeBufferPointer { pixels in
            mpvfx_jpeg_encode(pixels.baseAddress, pixels.count, u32(max(0, width)), u32(max(0, height)), q, &buffer)
        }
        try MediaError.check(status)
        return takeBuffer(&buffer) { Data(buffer: $0) }
    }
}
