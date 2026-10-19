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
import MpvfxCanvas

/// One Grade preset tile's look frame: the selected clip's frame graded with `presetId` plus the clip's LUT, at most
/// `pixelWidth` x `pixelHeight` device pixels.
public struct PresetPreviewRequest: Hashable, Sendable {
    public var clipId: String
    public var presetId: String
    public var lutSrc: String?
    public var lutIntensity: Double
    public var pixelWidth: Int, pixelHeight: Int
    public init(clipId: String, presetId: String, lutSrc: String?, lutIntensity: Double, pixelWidth: Int, pixelHeight: Int) {
        self.clipId = clipId; self.presetId = presetId; self.lutSrc = lutSrc; self.lutIntensity = lutIntensity
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// What a preset tile shows: the rendered frame, or the empty `bg-black/20` frame while it renders or when the clip
/// has no picture to preview.
public enum PresetPreviewState {
    case ready(CanvasImage)
    case rendering
    case unavailable
}
