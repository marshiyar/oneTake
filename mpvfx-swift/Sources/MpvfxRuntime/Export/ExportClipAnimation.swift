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
// Keyframed clip parameters for export: the parameters export accepts, and values sampled through the keyframe
// engine (the same evaluator the editor stage uses) for what the mix evaluates itself (keyframed clip volume).
import Foundation
import MpvfxShared

/// Parameters the exporter renders, static or keyframed, with the value type each one takes.
let EXPORT_VISUAL_PARAMETERS: Set<String> = [
    "transform.position", "transform.position.x", "transform.position.y", "transform.rotation",
    "transform.scale", "transform.scaleX", "transform.scaleY", "transform.opacity",
    "visual.opacity", "visual.autoAlpha", "layout.width", "layout.height", "layout.left", "layout.top",
    NativeTransform3D.zId, NativeTransform3D.rotationXId, NativeTransform3D.rotationYId, NativeTransform3D.perspectiveId,
]
let EXPORT_AUDIO_PARAMETERS: Set<String> = ["audio.volume"]

/// Parameters whose keyframes are rendered. layout.zIndex orders layers and stays static-only.
func exportAnimatableValueTypes(_ id: String) -> Set<NativeValueType>? {
    switch id {
    case "transform.position": return [.vec2]
    case "transform.scale": return [.number, .vec2]
    case _ where EXPORT_VISUAL_PARAMETERS.contains(id) || EXPORT_AUDIO_PARAMETERS.contains(id): return [.number]
    // Keyframed grade values (issue #179): the export frame painter grades each frame at its values, as the preview.
    case _ where NativeGradeParameter.isGradeParameter(id): return [.number]
    default: return nil
    }
}

/// Where and how a clip's box is drawn at one moment: box size and position in canvas px, scale (negative flips),
/// rotation in degrees (clockwise, about the box centre) and opacity 0...1.
struct ExportClipFrame: Equatable {
    var left: Double, top: Double, boxWidth: Double, boxHeight: Double
    var scaleX: Double, scaleY: Double, rotation: Double, opacity: Double
    /// Depth, tilt and lens (NativeTransform3D), the projection the preview draws too.
    var transform3D = NativeTransform3D.identity
}

/// Reads a clip's parameters at clip-local project frames: the keyframed track when it has keyframes, otherwise the
/// static value, otherwise the default. Fractional frames interpolate linearly between the two integer frames the
/// engine evaluates (it only evaluates integer frames, like the stage).
final class ExportClipSampler {
    let clip: NativeProjectClip
    let canvasWidth: Double, canvasHeight: Double
    private let tracks: [String: NativeParameterTrack]
    private let engine: KeyframeEngine?
    private var cache: [String: [Double: NativeParameterValue]] = [:]

    init(_ clip: NativeProjectClip, canvasWidth: Double, canvasHeight: Double, engine: KeyframeEngine?) {
        self.clip = clip; self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight; self.engine = engine
        var t: [String: NativeParameterTrack] = [:]
        for track in clip.parameterTracks where !track.keyframes.isEmpty && t[track.parameterId] == nil { t[track.parameterId] = track }
        tracks = t
    }

    var animatedParameters: Set<String> { Set(tracks.keys) }
    var hasVisualAnimation: Bool { !animatedParameters.isDisjoint(with: EXPORT_VISUAL_PARAMETERS) }
    var hasVolumeAnimation: Bool { tracks["audio.volume"] != nil }
    /// A 3D transform anywhere in the clip (static or keyframed): it draws through the projective warp.
    var has3D: Bool {
        NativeTransform3D.parameterIds.contains { id in
            tracks[id] != nil || { if case .number(let v)? = clip.staticParameters?[id] { return v != 0 }; return false }()
        }
    }

    private func evaluate(_ track: NativeParameterTrack, _ frame: Double) throws -> NativeParameterValue {
        if let v = cache[track.parameterId]?[frame] { return v }
        let v = try evaluateNativeParameterTrack(track, projectFrame: frame, engine: engine)
        cache[track.parameterId, default: [:]][frame] = v
        return v
    }

    /// The parameter at clip-local frame `frame` (clamped into the clip, as the stage clamps its playhead).
    func value(_ id: String, at frame: Double) throws -> NativeParameterValue? {
        guard let track = tracks[id] else { return clip.staticParameters?[id] }
        let f = Swift.max(0, Swift.min(Swift.max(0, clip.durationFrames - 1), frame))
        let lo = f.rounded(.down), hi = f.rounded(.up)
        let a = try evaluate(track, lo)
        if hi == lo { return a }
        let b = try evaluate(track, hi), w = f - lo
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x + (y - x) * w)
        case (.vec2(let x), .vec2(let y)): return .vec2(Vec2Value(x: x.x + (y.x - x.x) * w, y: x.y + (y.y - x.y) * w))
        default: return a
        }
    }

    func number(_ id: String, at frame: Double) throws -> Double? {
        if case .number(let v)? = try value(id, at: frame) { return v }
        return nil
    }
    func vector(_ id: String, at frame: Double) throws -> Vec2Value? {
        if case .vec2(let v)? = try value(id, at: frame) { return v }
        return nil
    }

    private var tangentCache: [Double: Double] = [:]

    /// Orient-along-path rotation in degrees: the tangent of an auto-rotating position track (Arc motion's
    /// "Orient to path"), as the preview adds it (PreviewComposition.layer). 0 when the track does not auto-rotate.
    func motionRotation(at frame: Double) -> Double {
        guard let track = tracks["transform.position"], track.autoRotate == true,
              let eng = engine ?? (try? keyframeEngine()) else { return 0 }
        func angle(_ f: Double) -> Double {
            if let a = tangentCache[f] { return a }
            let a = (try? eng.tangentAngle(KeyframeTrack(track), frame: f)).flatMap { $0.isFinite ? $0 * 180 / .pi : nil } ?? 0
            tangentCache[f] = a
            return a
        }
        let f = Swift.max(0, Swift.min(Swift.max(0, clip.durationFrames - 1), frame))
        let lo = f.rounded(.down), hi = f.rounded(.up)
        let a = angle(lo)
        if hi == lo { return a }
        var d = angle(hi) - a   // the shorter way round, so a turn through ±180° does not spin backwards
        d -= 360 * (d / 360).rounded()
        return a + d * (f - lo)
    }

    /// Same fallbacks the static renderer has always used (position.x over position, scaleX over scale, opacity chain).
    func frame(at f: Double) throws -> ExportClipFrame {
        let position = try vector("transform.position", at: f)
        let scaleValue = try value("transform.scale", at: f)
        var uniform: Double? = nil, scaleVector: Vec2Value? = nil
        if case .number(let s)? = scaleValue { uniform = s }
        if case .vec2(let s)? = scaleValue { scaleVector = s }
        let scaleX = try number("transform.scaleX", at: f) ?? uniform ?? scaleVector?.x ?? 1
        let scaleY = try number("transform.scaleY", at: f) ?? uniform ?? scaleVector?.y ?? 1
        let x = (try number("layout.left", at: f) ?? 0) + (try number("transform.position.x", at: f) ?? position?.x ?? 0)
        let y = (try number("layout.top", at: f) ?? 0) + (try number("transform.position.y", at: f) ?? position?.y ?? 0)
        let opacity = try number("transform.opacity", at: f) ?? number("visual.opacity", at: f) ?? number("visual.autoAlpha", at: f) ?? 1
        var out = ExportClipFrame(left: x, top: y, boxWidth: try number("layout.width", at: f) ?? canvasWidth,
                                  boxHeight: try number("layout.height", at: f) ?? canvasHeight, scaleX: scaleX, scaleY: scaleY,
                                  rotation: (try number("transform.rotation", at: f) ?? 0) + motionRotation(at: f), opacity: Swift.min(1, Swift.max(0, opacity)))
        out.transform3D = NativeTransform3D(rotationX: try number(NativeTransform3D.rotationXId, at: f) ?? 0,
                                            rotationY: try number(NativeTransform3D.rotationYId, at: f) ?? 0,
                                            z: try number(NativeTransform3D.zId, at: f) ?? 0,
                                            perspective: try number(NativeTransform3D.perspectiveId, at: f) ?? 0)
        return out
    }
}
