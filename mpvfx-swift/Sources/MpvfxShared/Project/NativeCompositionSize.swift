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
// The composition size: document.canvas width × height, which preview, stage, export, layout, text and 3D all
// read. Changing it rewrites only what must change for the picture to stay put: untouched media clips refit on
// their own (their box is computed from the canvas, nativeClipNaturalLayout), and every clip with a box of its own
// keeps that box's size and its offset from the frame's centre.
import Foundation

/// The named composition sizes the Design tab offers.
public enum NativeCompositionPreset: String, CaseIterable, Sendable {
    case landscape, portrait, square, vertical45 = "vertical-4-5", landscape4k = "landscape-4k"

    public var label: String {
        switch self {
        case .landscape: "Landscape 16:9"; case .portrait: "Portrait 9:16"; case .square: "Square 1:1"
        case .vertical45: "Vertical 4:5"; case .landscape4k: "4K 16:9"
        }
    }
    public var width: Double {
        switch self { case .landscape: 1920; case .portrait, .square, .vertical45: 1080; case .landscape4k: 3840 }
    }
    public var height: Double {
        switch self { case .landscape: 1080; case .portrait: 1920; case .square: 1080; case .vertical45: 1350; case .landscape4k: 2160 }
    }

    /// The preset of exactly this size, nil for any other (a custom size).
    public static func matching(width: Double, height: Double) -> NativeCompositionPreset? {
        allCases.first { $0.width == width && $0.height == height }
    }
}

/// Largest composition side: the media engine's picture bound (16384 × 16384, mpvfx-media AGENTS.md).
public let NATIVE_CANVAS_MAX_SIDE: Double = 16384

/// A composition size the document cannot take (not a whole number of pixels from 1 to NATIVE_CANVAS_MAX_SIDE).
public struct NativeCanvasSizeError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// `document` with its canvas set to `width` × `height` and every clip's box rewritten so the picture stays put:
/// a media clip with no box of its own (nativeClipNaturalLayout) refits to the new frame; a clip with a box of its
/// own (static or keyframed layout, or a crop, which is measured against its box) keeps the box's size and its
/// offset from the frame's centre. A clip with no layout at all keeps filling the frame. The result is validated
/// like every edit (parseNativeProjectDocument).
public func nativeDocumentResizingCanvas(_ document: NativeProjectDocument, width: Double, height: Double,
                                         natural: (NativeProjectAsset) -> NativeMediaNaturalSize?,
                                         engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    for (name, v) in [("width", width), ("height", height)] where !(jsIsInteger(v) && v >= 1 && v <= NATIVE_CANVAS_MAX_SIDE) {
        throw NativeCanvasSizeError(message: "The composition \(name) must be a whole number of pixels from 1 to \(Int(NATIVE_CANVAS_MAX_SIDE)).")
    }
    let old = document.canvas
    let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var d = document
    d.canvas.width = width; d.canvas.height = height
    let shift = (x: (width - old.width) / 2, y: (height - old.height) / 2)
    for t in d.sequence.tracks.indices {
        for i in d.sequence.tracks[t].clips.indices {
            let clip = d.sequence.tracks[t].clips[i]
            guard let asset = assets[clip.assetId], asset.kind != .audio else { continue }
            let media = asset.kind == .video || asset.kind == .image
            if media, nativeClipNaturalLayout(clip, natural: natural(asset), canvasWidth: old.width, canvasHeight: old.height) != nil {
                d.sequence.tracks[t].clips[i] = clipDroppingFullCanvasSize(clip)
            } else if clipHasOwnBox(clip) {
                d.sequence.tracks[t].clips[i] = clipKeepingCentreOffset(clip, oldCanvas: old, shift: shift)
            }
        }
    }
    return try parseNativeProjectDocument(d, engine: engine)
}

/// An untouched clip may carry an old project's full-canvas size (nativeClipNaturalLayout reads it as untouched);
/// on another canvas that size would read as a placed box, so it is removed and the clip stays untouched.
private func clipDroppingFullCanvasSize(_ clip: NativeProjectClip) -> NativeProjectClip {
    guard var sp = clip.staticParameters, sp["layout.width"] != nil || sp["layout.height"] != nil else { return clip }
    sp["layout.width"] = nil; sp["layout.height"] = nil
    var c = clip
    c.staticParameters = sp.isEmpty ? nil : sp
    return c
}

private func hasLayoutTrack(_ clip: NativeProjectClip, _ id: String) -> Bool {
    clip.parameterTracks.contains { $0.parameterId == id && !$0.keyframes.isEmpty }
}

/// Any static or keyframed layout value, or a crop: the clip's box is its own, not the frame.
private func clipHasOwnBox(_ clip: NativeProjectClip) -> Bool {
    if let crop = clip.crop, !crop.isZero { return true }
    return NATIVE_CLIP_LAYOUT_PARAMETERS.contains { clip.staticParameters?[$0] != nil || hasLayoutTrack(clip, $0) }
}

/// Writes out the box values the old canvas supplied by default (left/top 0, the old width/height), then moves
/// layout.left/top, static and every keyframe, by half the size change: same size, same offset from the centre.
private func clipKeepingCentreOffset(_ clip: NativeProjectClip, oldCanvas: NativeCanvas,
                                     shift: (x: Double, y: Double)) -> NativeProjectClip {
    var c = clip
    var sp = c.staticParameters ?? [:]
    let defaults = [("layout.left", 0.0), ("layout.top", 0.0), ("layout.width", oldCanvas.width), ("layout.height", oldCanvas.height)]
    for (id, value) in defaults where sp[id] == nil && !hasLayoutTrack(clip, id) { sp[id] = .number(value) }
    for (id, delta) in [("layout.left", shift.x), ("layout.top", shift.y)] {
        if case .number(let v)? = sp[id] { sp[id] = .number(v + delta) }
        for k in c.parameterTracks.indices where c.parameterTracks[k].parameterId == id {
            c.parameterTracks[k].keyframes = c.parameterTracks[k].keyframes.map { key in
                var n = key
                if case .number(let v) = key.value { n.value = .number(v + delta) }
                return n
            }
        }
    }
    c.staticParameters = sp
    return c
}
