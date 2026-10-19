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
// The data-moving half of the keyframe engine that is not in Project/KeyframeEngine.swift: the frame budget
// helper, bakeTrackSamples and createBakedEngine (answers from pre-baked samples).
// No evaluation rules live here; every value comes from a KeyframeEngine.
import Foundation

/// assertFrameBudget: refuses more than VKF_MAX_MATERIALIZED_FRAMES samples, as KeyframeEngineError("limit-exceeded").
public func assertKeyframeFrameBudget(_ count: Double) throws {
    if count > VKF_MAX_MATERIALIZED_FRAMES {
        throw KeyframeEngineError(code: KeyframeEngineError.limitExceeded,
            message: "Engine sample count exceeds the \(jsNumberString(VKF_MAX_MATERIALIZED_FRAMES))-frame limit")
    }
}

/// Values per sample for each value type (COMPONENTS).
public func keyframeComponentCount(_ type: NativeValueType) -> Int {
    switch type { case .number: return 1; case .vec2: return 2; case .rgba: return 4 }
}

/// A baked track. `angles` entries are nil where the angle is undefined (JSON null).
public struct BakedKeyframeTrack: Equatable {
    public var valueType: NativeValueType
    public var samples: [Double]
    public var angles: [Double?]?
    public init(valueType: NativeValueType, samples: [Double], angles: [Double?]? = nil) {
        self.valueType = valueType; self.samples = samples; self.angles = angles
    }

    /// The track as JSON (key order valueType, samples, angles; angles omitted when absent).
    public var jsonValue: NativeJSONValue {
        var o = NativeJSONObject()
        o["valueType"] = .string(valueType.rawValue)
        o["samples"] = .array(samples.map { .number($0) })
        if let angles { o["angles"] = .array(angles.map { $0.map(NativeJSONValue.number) ?? .null }) }
        return .object(o)
    }

    public init?(json: NativeJSONValue) {
        guard let t = json["valueType"]?.stringValue.flatMap(NativeValueType.init(rawValue:)),
              let s = json["samples"]?.arrayValue else { return nil }
        let samples = s.compactMap(\.numberValue)
        guard samples.count == s.count else { return nil }
        var angles: [Double?]? = nil
        if let a = json["angles"] {
            guard let list = a.arrayValue else { return nil }
            angles = try? list.map { v -> Double? in
                if case .null = v { return nil }
                guard let n = v.numberValue else { throw KeyframeEngineError(code: "", message: "") }
                return n
            }
            if angles == nil { return nil }
        }
        self.init(valueType: t, samples: samples, angles: angles)
    }
}

/// bakeTrackSamples: engine samples for frames [0, count) where
/// count = max(1, floor(frameCount), lastKey + 1), plus per-frame tangent angles for vec2 tracks.
public func bakeTrackSamples(_ engine: KeyframeEngine, _ track: KeyframeTrack, frameCount: Double) throws -> BakedKeyframeTrack {
    let lastKey = track.keyframes.reduce(0.0) { jsMathMax($0, $1.frame) }
    let count = jsMathMax(jsMathMax(1, Foundation.floor(frameCount)), lastKey + 1)
    try assertKeyframeFrameBudget(count)
    guard jsIsInteger(count) else {
        // A non-integer (NaN or fractional) count goes to engine.sample, which compiles the track first
        // (rejecting it with its track error) and otherwise rejects the count. KeyframeEngine.sample takes Int,
        // so reproduce that order here with the engine's own message (cvkf.cpp:195, vkf_node.cpp:293).
        try engine.validate(track)
        throw KeyframeEngineError(code: "invalid-argument", message: "sampleTrack(track, firstFrame, count) needs a finite frame and count")
    }
    let n = Int(count)
    let samples = try engine.sample(track, firstFrame: 0, count: n)
    guard track.valueType == .vec2 else { return BakedKeyframeTrack(valueType: track.valueType, samples: samples) }
    var angles: [Double?] = []
    angles.reserveCapacity(n)
    for frame in 0..<n {
        let angle = try engine.tangentAngle(track, frame: Double(frame))
        angles.append(angle.isNaN ? nil : angle)
    }
    return BakedKeyframeTrack(valueType: track.valueType, samples: samples, angles: angles)
}

/// Errors createBakedEngine raises itself, with their messages (`Error` or `TypeError` kinds).
public struct BakedKeyframeEngineError: Error, Equatable, CustomStringConvertible {
    public enum Kind: String { case error = "Error", typeError = "TypeError" }
    public let kind: Kind
    public let message: String
    public var description: String { message }
    public static let noSamples = BakedKeyframeEngineError(kind: .error, message: "No engine samples were prepared for this track")
    public static let integerFramesOnly = BakedKeyframeEngineError(kind: .typeError, message: "Pre-computed engine values exist only for integer frames")
    public static let noEditing = BakedKeyframeEngineError(kind: .error, message: "Editing keyframes is not available on export pages")
}

/// valueAt. An index outside the samples has no value. For a number track that makes
/// the whole value undefined (`nil` here); for vec2/rgba each missing component is undefined, which Swift
/// carries as NaN (exactly what a Float64Array stores). See docs/IMPLEMENTATION_NOTES.md.
func bakedKeyframeValueAt(_ baked: BakedKeyframeTrack, _ frame: Double) -> NativeParameterValue? {
    let n = Double(keyframeComponentCount(baked.valueType))
    let frames = Double(baked.samples.count) / n
    let index = Swift.min(frames - 1, jsMathMax(0, frame))
    let at = index * n
    func s(_ offset: Double) -> Double? {
        let k = at + offset
        guard k >= 0, k < Double(baked.samples.count), k == k.rounded(.towardZero) else { return nil }
        return baked.samples[Int(k)]
    }
    switch baked.valueType {
    case .number: return s(0).map(NativeParameterValue.number)
    case .vec2: return .vec2(Vec2Value(x: s(0) ?? .nan, y: s(1) ?? .nan))
    case .rgba: return .rgba(RgbaValue(red: s(0) ?? .nan, green: s(1) ?? .nan, blue: s(2) ?? .nan, alpha: s(3) ?? .nan))
    }
}

/// createBakedEngine: answers integer-frame queries from baked samples; tracks the lookup
/// does not know go to `fallback`, and with no fallback they are an error.
public final class BakedKeyframeEngine: KeyframeEngine {
    public let version: String
    private let lookup: (KeyframeTrack) -> BakedKeyframeTrack?
    private let fallback: KeyframeEngine?

    public init(version: String, lookup: @escaping (KeyframeTrack) -> BakedKeyframeTrack?, fallback: KeyframeEngine? = nil) {
        self.version = version; self.lookup = lookup; self.fallback = fallback
    }

    private func delegate(_ track: KeyframeTrack) -> KeyframeEngine? {
        guard let fallback, lookup(track) == nil else { return nil }
        return fallback
    }
    private func baked(_ track: KeyframeTrack) throws -> BakedKeyframeTrack {
        guard let found = lookup(track) else { throw BakedKeyframeEngineError.noSamples }
        return found
    }

    public func validate(_ track: KeyframeTrack) throws {
        if let f = delegate(track) { try f.validate(track) } else { _ = try baked(track) }
    }

    public func evaluate(_ track: KeyframeTrack, frame: Double) throws -> NativeParameterValue {
        if let f = delegate(track) { return try f.evaluate(track, frame: frame) }
        guard jsIsInteger(frame) else { throw BakedKeyframeEngineError.integerFramesOnly }
        // A number track read outside its samples has no value; this returns NaN (gap 2 in docs/IMPLEMENTATION_NOTES.md).
        return bakedKeyframeValueAt(try baked(track), frame) ?? .number(.nan)
    }

    public func tangentAngle(_ track: KeyframeTrack, frame: Double) throws -> Double {
        if let f = delegate(track) { return try f.tangentAngle(track, frame: frame) }
        guard jsIsInteger(frame) else { throw BakedKeyframeEngineError.integerFramesOnly }
        let b = try baked(track)
        guard let angles = b.angles else { return .nan }
        let index = Swift.min(Double(angles.count) - 1, jsMathMax(0, frame))
        guard index >= 0, index < Double(angles.count) else { return .nan }
        return angles[Int(index)] ?? .nan
    }

    public func slice(_ track: KeyframeTrack, fromFrame: Double, untilFrameExclusive: Double) throws -> [KeyframeSlicedKey] {
        if let f = delegate(track) { return try f.slice(track, fromFrame: fromFrame, untilFrameExclusive: untilFrameExclusive) }
        throw BakedKeyframeEngineError.noEditing
    }

    public func sample(_ track: KeyframeTrack, firstFrame: Double, count: Int) throws -> [Double] {
        if let f = delegate(track) { return try f.sample(track, firstFrame: firstFrame, count: count) }
        guard jsIsInteger(firstFrame), count >= 0 else { throw BakedKeyframeEngineError.integerFramesOnly }
        let b = try baked(track)
        let n = keyframeComponentCount(b.valueType)
        var out = [Double](repeating: 0, count: count * n)
        for i in 0..<count {
            switch bakedKeyframeValueAt(b, firstFrame + Double(i)) {
            case nil:
                // No sample at this frame: a type error, as for any read of a missing sample.
                throw BakedKeyframeEngineError(kind: .typeError, message: "Cannot use 'in' operator to search for 'x' in undefined")
            case .number(let v)?: out[i] = v
            case .vec2(let v)?: out[i * n] = v.x; out[i * n + 1] = v.y
            case .rgba(let v)?: out[i * n] = v.red; out[i * n + 1] = v.green; out[i * n + 2] = v.blue; out[i * n + 3] = v.alpha
            }
        }
        return out
    }
}
