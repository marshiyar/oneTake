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
import MpvfxShared

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

/// What a look or effect tile shows: the rendered frame; a "Rendering" caption while it renders; or, when the clip
/// has no picture (`unavailable`) or the render failed (`failed`), a placeholder that says why. Never an empty frame.
public enum PresetPreviewState {
    case ready(CanvasImage)
    case rendering
    case unavailable
    case failed(PreviewFailure)
}

/// Why a tile has no picture; `reason` is the text its placeholder shows.
public enum PreviewFailure: Error, Equatable, Sendable {
    /// The host gave the panel no preview renderer.
    case noRenderer
    /// The clip has no picture to grade (no media, or nothing decoded).
    case noPicture
    /// The tile asked for a size the renderer refuses (below 2 or above its maximum side).
    case invalidSize(width: Int, height: Int)
    /// The renderer ran and produced no usable picture.
    case renderFailed(String)

    public var reason: String {
        switch self {
        case .noRenderer: "No preview renderer"
        case .noPicture: "No picture to preview"
        case .invalidSize(let w, let h): "Tile size \(w)×\(h) is out of range"
        case .renderFailed(let why): "Render failed: \(why)"
        }
    }
}

/// One Effects catalog or look tile's demo: `grade` (the clip grade JSON, as `ColorGrading.json` writes it) drawn on
/// the frame of `clipId` at the playhead when that clip has a picture, else on the built-in sample picture, at most
/// `pixelWidth` x `pixelHeight` device pixels. `key` names the tile ("fx:blur", "look:vhs-playback"): a newer request
/// for the same key replaces an older one still queued; caches key on the grade itself.
public struct EffectPreviewRequest: Sendable {
    public var key: String
    public var grade: NativeJSONObject
    public var clipId: String?
    public var pixelWidth: Int, pixelHeight: Int
    public init(key: String, grade: NativeJSONObject, clipId: String? = nil, pixelWidth: Int, pixelHeight: Int) {
        self.key = key; self.grade = grade; self.clipId = clipId; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}
