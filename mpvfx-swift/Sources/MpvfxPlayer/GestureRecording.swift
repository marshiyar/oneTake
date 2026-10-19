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
import MpvfxCanvas
import MpvfxShared

/// One recorded pointer state at a frame-quantized recording time (GestureSample).
/// `properties` keeps insertion order, which the keyframe planner sees.
public struct GestureSample: Equatable {
    public var time: Double
    public var properties: NativeOrderedMap<Double>
    public init(time: Double, properties: NativeOrderedMap<Double>) { self.time = time; self.properties = properties }
    public static func == (a: GestureSample, b: GestureSample) -> Bool {
        a.time == b.time && a.properties.keys == b.properties.keys && a.properties.values == b.properties.values
    }
}

/// Live gesture recording: pointer movement since the first move becomes position;
/// ⌘/Ctrl turns vertical movement into opacity (wheel: scale), ⌥ turns horizontal movement into rotation,
/// ⇧ into 3D rotation, and the wheel alone into depth (z). Samples are kept one per output frame.
public struct GestureRecorder {
    public struct Base: Equatable {
        public var x = 0.0, y = 0.0, opacity = 1.0, scale = 1.0
        public init(x: Double = 0, y: Double = 0, opacity: Double = 1, scale: Double = 1) { self.x = x; self.y = y; self.opacity = opacity; self.scale = scale }
    }
    public let clipId: String
    /// Playhead seconds when recording started (the 0 % keyframe's time).
    public let startTime: Double
    public let fps: Double
    public let base: Base
    /// View px per composition px when recording started (pointer deltas are divided by it).
    public let viewScale: Double

    public private(set) var samples: [GestureSample] = []
    /// Pointer positions (view px) per sample, for the trail overlay.
    public private(set) var trail: [CanvasPoint] = []
    public private(set) var hasMoved = false
    public private(set) var duration = 0.0
    var pointer: CanvasPoint
    var startPointer: CanvasPoint
    var scrollDelta = 0.0
    var modifiers: PointerModifiers = []
    var opacity: Double, scale: Double, z = 0.0
    /// The live values of the latest tick (the stage previews them).
    public private(set) var live = NativeOrderedMap<Double>()

    public init(clipId: String, startTime: Double, fps: Double, base: Base, viewScale: Double, pointer: CanvasPoint) {
        self.clipId = clipId; self.startTime = startTime; self.fps = fps > 0 ? fps : 30; self.base = base
        self.viewScale = viewScale > 0 ? viewScale : 1
        self.pointer = pointer; startPointer = pointer
        opacity = base.opacity; scale = base.scale
    }

    /// Pointer moved (view px). The first move anchors the deltas at the grab point.
    public mutating func pointerMoved(_ p: CanvasPoint, modifiers m: PointerModifiers) {
        if !hasMoved { startPointer = p; hasMoved = true }
        pointer = p; modifiers = m
    }
    public mutating func modifiersChanged(_ m: PointerModifiers) { modifiers = m }
    /// Wheel during recording (web deltaY px, positive = down).
    public mutating func wheel(_ dy: Double, modifiers m: PointerModifiers) {
        if !hasMoved { startPointer = pointer; hasMoved = true }
        scrollDelta += dy; modifiers = m
    }

    /// resolveGestureProperties: which properties the current pointer state drives.
    static func properties(dx: Double, dy: Double, scroll: Double, modifiers m: PointerModifiers,
                           opacity: Double, scale: Double, z: Double) -> (NativeOrderedMap<Double>, opacity: Double, scale: Double, z: Double) {
        var p = NativeOrderedMap<Double>()
        var o = opacity, s = scale, zz = z
        if m.command {
            o = max(0, min(1, 1 - dy * 0.005))
            p["opacity"] = o
            if scroll != 0 { s = max(0.01, scale + scroll * 0.01); p["scale"] = s }
        } else if m.contains(.shift) {
            p["rotationX"] = dy * 0.5
            p["rotationY"] = dx * 0.5
        } else if m.contains(.alt) {
            p["rotation"] = dx * 0.5
        } else {
            p["x"] = dx
            p["y"] = dy
        }
        if !m.command && scroll != 0 { zz = z + scroll; p["z"] = zz }
        return (p, o, s, zz)
    }

    /// One display frame at recording time `time` (seconds since start). Returns false while nothing moved yet.
    @discardableResult
    public mutating func tick(time: Double) -> Bool {
        let dx = (pointer.x - startPointer.x) / viewScale, dy = (pointer.y - startPointer.y) / viewScale
        if !hasMoved && dx == 0 && dy == 0 && scrollDelta == 0 { return false }
        hasMoved = true
        var (props, o, s, zz) = Self.properties(dx: dx, dy: dy, scroll: scrollDelta, modifiers: modifiers, opacity: opacity, scale: scale, z: z)
        if let x = props["x"] { props["x"] = (base.x + x).rounded(.toNearestOrAwayFromZero) }
        if let y = props["y"] { props["y"] = (base.y + y).rounded(.toNearestOrAwayFromZero) }
        opacity = o; scale = s; z = zz; scrollDelta = 0
        live = props
        // recordSample: keep the latest pointer state for each output frame.
        let frame = time > 0 ? (time * fps).rounded(.toNearestOrAwayFromZero) : 0
        let sample = GestureSample(time: frame > 0 ? frame / fps : 0, properties: props)
        if let last = samples.last, last.time == sample.time { samples[samples.count - 1] = sample } else { samples.append(sample) }
        trail.append(pointer)
        duration = time
        return true
    }
}

/// Turning frozen samples into keyframes (gesture commit: RDP simplification, smoothing and the
/// velocity ease fitter), then into a document through applyNativeGestureRecording.
public enum GestureKeyframes {
    public struct Failure: Error, Equatable, CustomStringConvertible { public let message: String; public var description: String { message } }

    /// Per-property tolerance: opacity and scale are small-range, positions are px.
    static func epsilon(_ key: String) -> Double {
        key == "opacity" || key == "scale" || key == "scaleX" || key == "scaleY" ? 0.01 : 5
    }

    /// Ramer-Douglas-Peucker on one time series.
    static func simplify(_ pts: [(time: Double, value: Double)], _ eps: Double) -> [(time: Double, value: Double)] {
        if pts.count <= 2 || eps <= 0 { return pts }
        let first = pts[0], last = pts[pts.count - 1]
        var maxDist = 0.0, maxIndex = 0
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            let d = last.time == first.time ? abs(p.value - first.value)
                : abs(p.value - (first.value + (last.value - first.value) * (p.time - first.time) / (last.time - first.time)))
            if d > maxDist { maxDist = d; maxIndex = i }
        }
        if maxDist > eps {
            let left = simplify(Array(pts[0...maxIndex]), eps), right = simplify(Array(pts[maxIndex...]), eps)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }

    static func interpolate(_ samples: [GestureSample], _ key: String, _ t: Double) -> Double {
        var before: (Double, Double)?, after: (Double, Double)?
        for s in samples {
            guard let v = s.properties[key] else { continue }
            if s.time <= t { before = (s.time, v) }
            if s.time >= t && after == nil { after = (s.time, v) }
        }
        if let b = before, b.0 == t { return b.1 }
        if let a = after, a.0 == t { return a.1 }
        guard let b = before else { return after!.1 }
        guard let a = after else { return b.1 }
        return b.1 + (a.1 - b.1) * (t - b.0) / (a.0 - b.0)
    }

    /// simplifyGestureSamples: percentage (1 decimal) -> every property interpolated at each surviving time.
    public static func simplifySamples(_ samples: [GestureSample], duration: Double) -> [(percentage: Double, properties: NativeOrderedMap<Double>)] {
        guard !samples.isEmpty, duration > 0 else { return [] }
        var keys: [String] = []
        for s in samples { for k in s.properties.keys where !keys.contains(k) { keys.append(k) } }
        var surviving = Set<Double>()
        for k in keys {
            let series = samples.compactMap { s in s.properties[k].map { (time: s.time, value: $0) } }
            for p in simplify(series, epsilon(k)) { surviving.insert(p.time) }
        }
        var out: [(Double, NativeOrderedMap<Double>)] = []
        for t in surviving.sorted() {
            let pct = (t / duration * 1000).rounded(.toNearestOrAwayFromZero) / 10
            var props = NativeOrderedMap<Double>()
            for k in keys { props[k] = interpolate(samples, k, t) }
            if let i = out.firstIndex(where: { $0.0 == pct }) { out[i].1 = props } else { out.append((pct, props)) }
        }
        return out.map { (percentage: $0.0, properties: $0.1) }
    }

    /// smoothGestureKeyframes: Gaussian-weighted moving average by index; first and last pinned.
    public static func smooth(_ kfs: [(percentage: Double, properties: NativeOrderedMap<Double>)], radius: Int = 3) -> [(percentage: Double, properties: NativeOrderedMap<Double>)] {
        guard kfs.count > 2, radius > 0 else { return kfs }
        let sigma = Double(radius) / 2
        var keys: [String] = []
        for k in kfs { for key in k.properties.keys where !keys.contains(key) { keys.append(key) } }
        return kfs.enumerated().map { i, kf in
            if i == 0 || i == kfs.count - 1 { return kf }
            var out = kf.properties
            for key in keys {
                var ws = 0.0, vs = 0.0
                for j in max(0, i - radius)...min(kfs.count - 1, i + radius) {
                    guard let v = kfs[j].properties[key] else { continue }
                    let d = Double(j - i), w = exp(-(d * d) / (2 * sigma * sigma))
                    ws += w; vs += v * w
                }
                if ws > 0 { out[key] = (vs / ws * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }
            }
            return (kf.percentage, out)
        }
    }

    static let easyEase = "custom(M0,0 C0.333,0 0.667,1 1,1)"
    static let easyEaseIn = "custom(M0,0 C0.333,0.333 0.667,1 1,1)"
    static let easyEaseOut = "custom(M0,0 C0.333,0 0.667,0.667 1,1)"

    static func meanSpeed(_ s: [(time: Double, value: Double)]) -> Double {
        guard s.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<s.count { let dt = s[i].time - s[i - 1].time; if dt > 0 { total += abs(s[i].value - s[i - 1].value) / dt } }
        return total / Double(s.count - 1)
    }

    /// fitEasesFromVelocity: a segment that starts and/or ends slow (edge speed under 30 % of its mean) gets the
    /// After Effects easy-ease shape on its arriving keyframe; constant speed stays linear.
    public static func fitEases(_ kfs: [(percentage: Double, properties: NativeOrderedMap<Double>)], samples: [GestureSample], duration: Double) -> [NativeRecordedKeyframe] {
        var out = kfs.map { kf in
            NativeRecordedKeyframe(percentage: kf.percentage, properties: NativeOrderedMap(kf.properties.keys.map { ($0, NativeRecordedKeyframe.Property.number(kf.properties[$0]!)) }))
        }
        guard kfs.count >= 2, samples.count >= 3 else { return out }
        for i in 1..<kfs.count {
            let segStart = kfs[i - 1].percentage / 100 * duration, segEnd = kfs[i].percentage / 100 * duration
            let segDur = segEnd - segStart
            guard segDur > 0 else { continue }
            let props = kfs[i].properties.keys
            var best = props.first ?? "x", bestRange = 0.0
            for p in props {
                let r = abs((kfs[i].properties[p] ?? 0) - (kfs[i - 1].properties[p] ?? 0))
                if r > bestRange { bestRange = r; best = p }
            }
            let seg = samples.filter { $0.time >= segStart && $0.time <= segEnd }.map { (time: $0.time, value: $0.properties[best] ?? 0) }
            guard seg.count >= 3 else { continue }
            let window = segDur * 0.25
            let avg = meanSpeed(seg)
            guard avg >= 1e-6 else { continue }
            let startSpd = meanSpeed(seg.filter { $0.time >= segStart && $0.time <= segStart + window })
            let endSpd = meanSpeed(seg.filter { $0.time >= segEnd - window && $0.time <= segEnd })
            let slowStart = startSpd / avg < 0.3, slowEnd = endSpd / avg < 0.3
            if slowStart && slowEnd { out[i].ease = easyEase } else if slowEnd { out[i].ease = easyEaseIn } else if slowStart { out[i].ease = easyEaseOut }
        }
        return out
    }

    /// The keyframes a recording commits (stopAndCommitRecording): simplify, ensure a 0 % key, smooth, fit eases.
    public static func keyframes(_ samples: [GestureSample], duration: Double) throws -> [NativeRecordedKeyframe] {
        if samples.count <= 2 { throw Failure(message: "No gesture detected — move the pointer while recording") }
        if duration <= 0 { throw Failure(message: "Recording too short — try again") }
        var simplified = simplifySamples(samples, duration: duration)
        if !simplified.contains(where: { $0.percentage == 0 }) { simplified.insert((0, samples[0].properties), at: 0) }
        return fitEases(smooth(simplified, radius: 3), samples: samples, duration: duration)
    }

    /// The edited document: the recorded interval replaced on the clip's keyframe tracks (one undo step for the host).
    public static func apply(_ document: NativeProjectDocument, clipId: String, startTime: Double, duration: Double,
                             samples: [GestureSample], bounds: NativeSelectionBounds?, engine: KeyframeEngine? = nil) throws -> (document: NativeProjectDocument, count: Int) {
        let keys = try keyframes(samples, duration: duration)
        let request = NativeGestureRecordingRequest(selectedElement: NativeSelectedElementReference(datasetStudioClipId: clipId),
                                                    playheadSeconds: startTime, selectionBounds: bounds)
        return (try applyNativeGestureRecording(document, request, duration: duration, keys: keys, engine: engine), keys.count)
    }

    /// Values the recording starts from (projectNativeKeyframeUi currentValues), or nil when the clip can't be keyframed.
    public static func base(_ document: NativeProjectDocument, clipId: String, time: Double, engine: KeyframeEngine? = nil) -> GestureRecorder.Base? {
        let req = NativeKeyframeUiProjectionRequest(selectedElement: NativeSelectedElementReference(datasetStudioClipId: clipId), playheadSeconds: time)
        guard case .success(let p)? = try? projectNativeKeyframeUi(document, req, engine: engine) else { return nil }
        let v = p.currentValues
        return GestureRecorder.Base(x: v[.x] ?? 0, y: v[.y] ?? 0, opacity: v[.opacity] ?? 1, scale: v[.scale] ?? 1)
    }
}
