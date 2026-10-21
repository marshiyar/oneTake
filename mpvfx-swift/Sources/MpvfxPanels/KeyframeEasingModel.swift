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
import Foundation
import MpvfxShared
import MpvfxTimeline

/// What the Keyframe Easing panel edits: one clip, one property, and the keys of it the panel's edits apply to.
public struct KeyframeEasingTarget: Equatable {
    public var clipId: String
    public var parameterId: String
    /// The clip's animated properties that have easing, in the inspector's order.
    public var properties: [String]
    /// The keys edited, in time order: the timeline's selected keys of this property, else the playhead's key.
    public var refs: [TimelineKeyframeRef]
    public var fromSelection: Bool
    public var focused: TimelineKeyframeRef? { refs.first }

    /// Properties the panel eases: the Transform group's and keyed volume (TimelineEditor.keyframeEasingGroup).
    public static let easedParameterIds = TimelineEditor.transformEasedParameterIds + [TimelineEditor.opacityId, TimelineEditor.volumeId]

    /// Property: `chosen` when selected keys include it, else the earliest selected key's on this clip, else
    /// `chosen` when it is animated, else the first animated one. Nil without a clip or an animated easable property.
    public static func resolve(_ editor: TimelineEditor, clipId: String?, selected: Set<TimelineKeyframeRef>, time: Double,
                               chosen: String?) -> KeyframeEasingTarget? {
        guard let clipId, editor.clip(clipId) != nil else { return nil }
        let properties = easedParameterIds.filter { editor.isAnimated(clipId: clipId, $0) }
        let picked = selected.filter { $0.clipId == clipId && properties.contains($0.parameterId) && editor.outgoing($0) != nil }
            .sorted(by: Self.inTimeOrder)
        let pid = picked.first(where: { $0.parameterId == chosen })?.parameterId ?? picked.first?.parameterId
            ?? chosen.flatMap { properties.contains($0) ? $0 : nil } ?? properties.first
        guard let pid else { return nil }
        let refs = picked.filter { $0.parameterId == pid }
        if !refs.isEmpty { return .init(clipId: clipId, parameterId: pid, properties: properties, refs: refs, fromSelection: true) }
        let atPlayhead = editor.keyframesAtOrBefore(clipId: clipId, parameterIds: [pid], time: time)
        return .init(clipId: clipId, parameterId: pid, properties: properties, refs: atPlayhead, fromSelection: false)
    }

    /// Earlier frame first; on the same frame, by parameter id.
    public static func inTimeOrder(_ a: TimelineKeyframeRef, _ b: TimelineKeyframeRef) -> Bool {
        a.frame != b.frame ? a.frame < b.frame : a.parameterId < b.parameterId
    }
}

/// The panel's state that outlives one draw: the property the user picked, the ease clipboard, the graph view.
public final class KeyframeEasingState {
    public enum Graph: String, CaseIterable, Sendable { case value, speed }
    public var chosenProperty: String?
    /// The timeline selection when the user picked `chosenProperty` in the panel: while the host keeps syncing that
    /// same selection, the pick holds even though the selected keys belong to another property.
    public var pinnedSelection: Set<TimelineKeyframeRef>?
    public private(set) var clipboard: NativeInterpolation?
    public var graph: Graph = .speed
    /// Time zoom (1 = the whole keyed range) and pan (the shown range's start, as a fraction of the keyed range).
    public var zoom = 1.0 { didSet { zoom = min(64, max(1, zoom.isFinite ? zoom : 1)); pan = clampPan(pan) } }
    public var pan = 0.0 { didSet { pan = clampPan(pan) } }
    public init() {}

    func clampPan(_ p: Double) -> Double { min(1 - 1 / zoom, max(0, p.isFinite ? p : 0)) }

    /// Copies the focused key's curve; false without one.
    @discardableResult
    public func copy(_ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Bool {
        guard let f = t.focused, let v = editor.outgoing(f) else { return false }
        clipboard = v; return true
    }

    /// Applies the copied curve to every target key (one undo step); false with nothing copied or nothing changed.
    @discardableResult
    public func paste(_ editor: TimelineEditor, _ t: KeyframeEasingTarget) -> Bool {
        guard let v = clipboard else { return false }
        return KeyframeEasing.apply(editor, t, v, label: "Paste keyframe easing")
    }
}

/// The panel's edits; each is one undo step over every target key.
public enum KeyframeEasing {
    public typealias Side = KeyframeEase.End
    /// A key's two handles as the numbers show them: influence 0…1, velocity in property units per second.
    public struct Sides: Equatable {
        public var outInfluence, outVelocity, inInfluence, inVelocity: Double
    }

    @discardableResult
    public static func apply(_ editor: TimelineEditor, _ t: KeyframeEasingTarget, _ v: NativeInterpolation,
                             label: String = "Edit keyframe easing") -> Bool {
        editor.withHistory(label) { editor.setOutgoing(t.refs, v) }
    }

    /// The segment leaving `ref`: how far its value moves (the straight distance for 2D and colour values) and in
    /// how many seconds. Nil for the last key.
    public static func segment(_ editor: TimelineEditor, _ ref: TimelineKeyframeRef) -> (valueChange: Double, seconds: Double)? {
        guard let next = editor.nextKeyframe(ref), let track = editor.parameterTrack(ref),
              let a = track.keyframes.first(where: { $0.frame == ref.frame }), let b = track.keyframes.first(where: { $0.frame == next.frame })
        else { return nil }
        let rate = track.frameRate.numerator / max(track.frameRate.denominator, 1)
        return (distance(a.value, b.value), (next.frame - ref.frame) / max(rate, 1e-9))
    }

    /// The handles of `ref`'s outgoing curve (a linear segment reads as slope 1 on both sides); nil for a hold or
    /// the last key.
    public static func sides(_ editor: TimelineEditor, _ ref: TimelineKeyframeRef) -> Sides? {
        guard let seg = segment(editor, ref), let h = editor.outgoing(ref).flatMap(handles) else { return nil }
        func v(_ s: Double) -> Double { KeyframeEase.velocity(slope: s, valueChange: seg.valueChange, seconds: seg.seconds) }
        return Sides(outInfluence: h.outInfluence, outVelocity: v(h.outSlope), inInfluence: h.inInfluence, inVelocity: v(h.inSlope))
    }

    /// Sets one side of every target key's outgoing curve: the influence as given, the velocity converted per key
    /// (each segment has its own distance and length). Nil keeps that number. The other side's control point, and
    /// any unknown keys the curve carried, stay exactly as they were. Holds and last keys are skipped.
    @discardableResult
    public static func setSide(_ editor: TimelineEditor, _ t: KeyframeEasingTarget, _ side: Side, influence: Double?, velocity: Double?) -> Bool {
        let changes: [(TimelineKeyframeRef, NativeInterpolation)] = t.refs.compactMap { r in
            guard let seg = segment(editor, r), let p = editor.outgoing(r).flatMap(points), let h = KeyframeEase.handles(p) else { return nil }
            let slope = velocity.map { KeyframeEase.slope(velocity: $0, valueChange: seg.valueChange, seconds: seg.seconds) }
            let now = side == .out ? (h.outInfluence, h.outSlope) : (h.inInfluence, h.inSlope)
            return (r, .cubicBezier(KeyframeEase.setting(side, of: p, influence: influence ?? now.0, slope: slope ?? now.1)))
        }
        return editor.withHistory("Edit keyframe easing") { editor.setOutgoing(changes) }
    }

    /// The control points a curve edit starts from: a linear segment as the cubic that moves at its linear speed;
    /// nil for a hold (no handles).
    static func points(_ v: NativeInterpolation) -> CubicBezierControlPoints? {
        switch v {
        case .hold: return nil
        case .linear: return CubicBezierControlPoints(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        case .cubicBezier(let p): return p
        }
    }

    static func handles(_ v: NativeInterpolation) -> KeyframeEase.Handles? {
        points(v).flatMap(KeyframeEase.handles)
    }

    static func distance(_ a: NativeParameterValue, _ b: NativeParameterValue) -> Double {
        magnitude(zip(components(a), components(b)).map { $1 - $0 })
    }

    /// 1D: the absolute change; 2D: the straight distance; colour: the largest channel change.
    static func magnitude(_ d: [Double]) -> Double {
        d.count == 2 ? hypot(d[0], d[1]) : d.reduce(0) { max($0, abs($1)) }
    }

    static func components(_ v: NativeParameterValue) -> [Double] { v.components }
}

/// The value and speed graphs' data: the property's engine-evaluated value across its keyed range, so the line drawn
/// is the motion the preview and export render.
public enum KeyframeEasingGraph {
    public struct Samples: Equatable {
        /// Clip-local frame of each sample: evenly spaced, the last one exactly the last key (the final gap may be
        /// shorter).
        public var frames: [Double]
        /// One array of components per sample.
        public var values: [[Double]]
        /// Speed at each sample in property units per second (2D: along the path; colour: the fastest channel).
        public var speeds: [Double]
        public var keyFrames: [Double]
    }

    public static func samples(_ editor: TimelineEditor, _ t: KeyframeEasingTarget, maxSamples: Int = 1200) -> Samples? {
        guard let track = editor.parameterTrack(t.focused ?? TimelineKeyframeRef(clipId: t.clipId, parameterId: t.parameterId, frame: 0)),
              let first = track.keyframes.first?.frame, let last = track.keyframes.last?.frame else { return nil }
        let span = max(1, last - first), step = max(1, (span / Double(max(1, maxSamples))).rounded(.up))
        let count = Int((span / step).rounded(.up)) + 1
        let frames = (0..<count).map { min(last, first + Double($0) * step) }
        let dims = track.valueType == .number ? 1 : (track.valueType == .vec2 ? 2 : 4)
        let engine: KeyframeEngine
        do { engine = try editor.engine ?? keyframeEngine() } catch { return nil }
        var values: [[Double]] = []
        let keyed = KeyframeTrack(track)
        do {
            for frame in frames {
                let flat = try engine.sample(keyed, firstFrame: frame, count: 1)
                guard flat.count == dims else { return nil }
                values.append(flat)
            }
        } catch {
            return nil   // the engine refused the track: the panel shows no graph rather than a wrong one
        }
        let rate = track.frameRate.numerator / max(track.frameRate.denominator, 1)
        return Samples(frames: frames, values: values, speeds: speeds(values, frames: frames, rate: rate),
                       keyFrames: track.keyframes.map(\.frame))
    }

    /// Central differences (one-sided at the ends) over the samples' real frame gaps, in units per second.
    static func speeds(_ values: [[Double]], frames: [Double], rate: Double) -> [Double] {
        guard values.count > 1, frames.count == values.count else { return values.map { _ in 0 } }
        return values.indices.map { i in
            let a = max(0, i - 1), b = min(values.count - 1, i + 1)
            let dist = KeyframeEasing.magnitude(zip(values[a], values[b]).map { $1 - $0 })
            return dist / max(1e-9, frames[b] - frames[a]) * rate
        }
    }
}

extension TimelineEditor {
    /// The parameter track `ref` names (its clip and parameter; the frame is not used).
    func parameterTrack(_ ref: TimelineKeyframeRef) -> NativeParameterTrack? {
        clip(ref.clipId)?.clip.parameterTracks.first { $0.parameterId == ref.parameterId && !$0.keyframes.isEmpty }
    }
}
