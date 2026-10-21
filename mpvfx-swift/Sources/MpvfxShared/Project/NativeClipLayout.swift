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
// Default media clip geometry (fitTimelineAssetGeometry) from the media's natural size
// (resolveDroppedAssetDimensions: the picture's natural width and height after rotation)
// as the drop and insert paths place a clip.
import Foundation

/// A media file's natural pixel size as a player shows it (sample aspect applied, 90° rotation swapped).
public struct NativeMediaNaturalSize: Equatable, Hashable, Sendable {
    public var width: Double, height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }

    /// Display size from probed stream facts: `width × sar` by `height`, swapped for a ±90° rotation.
    public static func display(width: Double, height: Double, sampleAspect: Double? = nil, rotation: Double = 0) -> NativeMediaNaturalSize? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let sar = sampleAspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        let w = width * sar
        let rotated = rotation.isFinite && abs(rotation.truncatingRemainder(dividingBy: 180)) == 90
        return rotated ? NativeMediaNaturalSize(width: height, height: w) : NativeMediaNaturalSize(width: w, height: height)
    }
}

/// A clip box in composition px: layout.left / layout.top / layout.width / layout.height.
public struct NativeClipLayoutBox: Equatable, Sendable {
    public var left: Double, top: Double, width: Double, height: Double
    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left; self.top = top; self.width = width; self.height = height
    }
}

/// `fitTimelineAssetGeometry`: places a new clip at its natural size when it fits the composition, scaled down to
/// fit when it is larger, and always centred; an unknown natural size fills the frame. Every value is rounded the
/// way JavaScript's Math.round rounds.
public func fitTimelineAssetGeometry(_ natural: NativeMediaNaturalSize?, compWidth: Double, compHeight: Double) -> NativeClipLayoutBox {
    guard let natural, natural.width > 0, natural.height > 0 else {
        return NativeClipLayoutBox(left: 0, top: 0, width: compWidth, height: compHeight)
    }
    let scale = Swift.min(1, compWidth / natural.width, compHeight / natural.height)
    let width = jsMathRound(natural.width * scale)
    let height = jsMathRound(natural.height * scale)
    return NativeClipLayoutBox(left: jsMathRound((compWidth - width) / 2), top: jsMathRound((compHeight - height) / 2),
                               width: width, height: height)
}

public let NATIVE_CLIP_LAYOUT_PARAMETERS = ["layout.left", "layout.top", "layout.width", "layout.height"]

public extension NativeProjectAsset {
    /// The natural size cached on the asset (`width` / `height` keys, carried like any other asset key).
    var naturalSize: NativeMediaNaturalSize? {
        get {
            guard case .number(let w)? = spread.extra["width"], case .number(let h)? = spread.extra["height"] else { return nil }
            let s = NativeMediaNaturalSize(width: w, height: h)
            return s.isValid ? s : nil
        }
        set {
            if let s = newValue, s.isValid { spread.extra["width"] = .number(s.width); spread.extra["height"] = .number(s.height) }
            else { spread.extra["width"] = nil; spread.extra["height"] = nil }
        }
    }
}

/// The box a media clip's untouched size stands for, or nil when the clip carries its own geometry.
///
/// A new clip stores no layout (clips are inserted with `staticParameters: {}`; its size is the inserted
/// element's own geometry), so "no layout.width/height" means the default box: `fitTimelineAssetGeometry` of the
/// media's natural size. Clips saved before natural sizes were honored kept the full-canvas default, sometimes
/// written out as layout.width/height equal to the canvas; when that size has a different aspect than the media
/// and nothing else about the layout was touched, it is read as the natural default too (no migration).
/// A clip with a crop and no size keeps the full-canvas box its crop insets were measured against.
public func nativeClipNaturalLayout(_ clip: NativeProjectClip, natural: NativeMediaNaturalSize?,
                                    canvasWidth: Double, canvasHeight: Double) -> NativeClipLayoutBox? {
    guard let natural, natural.isValid, canvasWidth > 0, canvasHeight > 0 else { return nil }
    if clip.parameterTracks.contains(where: { NATIVE_CLIP_LAYOUT_PARAMETERS.contains($0.parameterId) && !$0.keyframes.isEmpty }) { return nil }
    let sp = clip.staticParameters
    if sp?["layout.left"] != nil || sp?["layout.top"] != nil { return nil }
    if let crop = clip.crop, !crop.isZero { return nil }
    switch (sp?["layout.width"], sp?["layout.height"]) {
    case (nil, nil): break
    case (.number(let w)?, .number(let h)?):
        let sameAspect = abs(natural.width * canvasHeight - natural.height * canvasWidth) <= 1e-9 * natural.width * canvasHeight
        guard w == canvasWidth, h == canvasHeight, !sameAspect else { return nil }
    default: return nil
    }
    return fitTimelineAssetGeometry(natural, compWidth: canvasWidth, compHeight: canvasHeight)
}

/// The clip with its natural default layout written out as static layout.left/top/width/height (unchanged when
/// the clip carries its own geometry or the natural size is unknown). Renderers read this, so preview, stage
/// and export see one box.
public func nativeClipWithNaturalLayout(_ clip: NativeProjectClip, natural: NativeMediaNaturalSize?,
                                        canvasWidth: Double, canvasHeight: Double) -> NativeProjectClip {
    guard let box = nativeClipNaturalLayout(clip, natural: natural, canvasWidth: canvasWidth, canvasHeight: canvasHeight) else { return clip }
    var c = clip
    var sp = c.staticParameters ?? [:]
    sp["layout.left"] = .number(box.left); sp["layout.top"] = .number(box.top)
    sp["layout.width"] = .number(box.width); sp["layout.height"] = .number(box.height)
    c.staticParameters = sp
    return c
}

/// Every visual clip of the document with its natural default layout written out (see nativeClipWithNaturalLayout).
public func nativeDocumentWithNaturalLayouts(_ document: NativeProjectDocument,
                                             natural: (NativeProjectAsset) -> NativeMediaNaturalSize?) -> NativeProjectDocument {
    let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var d = document
    for t in d.sequence.tracks.indices {
        for i in d.sequence.tracks[t].clips.indices {
            let clip = d.sequence.tracks[t].clips[i]
            guard let asset = assets[clip.assetId], asset.kind == .video || asset.kind == .image else { continue }
            d.sequence.tracks[t].clips[i] = nativeClipWithNaturalLayout(clip, natural: natural(asset),
                                                                        canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
        }
    }
    return d
}

/// The rect a media picture of `image` aspect occupies in `box`: contain-fit (object-fit: contain), except that
/// a box already within rounding of the picture's aspect (≤ 1 px of letterbox on a side) is filled, so the picture's
/// edges are the box edges. The fit rounds the box to whole pixels; this keeps that sub-pixel rounding from
/// showing up as a hairline gap between the media and its selection box.
public func nativeMediaRect(imageWidth: Double, imageHeight: Double, box: NativeClipLayoutBox) -> NativeClipLayoutBox {
    guard imageWidth > 0, imageHeight > 0, box.width > 0, box.height > 0 else { return box }
    let s = Swift.min(box.width / imageWidth, box.height / imageHeight)
    let w = imageWidth * s, h = imageHeight * s
    if box.width - w <= 2 && box.height - h <= 2 { return box }
    return NativeClipLayoutBox(left: box.left + (box.width - w) / 2, top: box.top + (box.height - h) / 2, width: w, height: h)
}
