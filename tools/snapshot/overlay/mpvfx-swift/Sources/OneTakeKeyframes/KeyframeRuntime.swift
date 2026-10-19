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
// The app's Swift face of the keyframe engine: a thin adapter over the C interface in cvkf.h (module
// CKeyframeEngine). The engine is a proprietary dynamic library fetched by version and SHA-256 (binaries.lock).
import CKeyframeEngine
import Foundation

/// Evaluates keyframe tracks with the keyframe engine. Safe to share between threads.
public final class KeyframeRuntime: @unchecked Sendable {
    /// Interface version the loaded library reports.
    public let apiVersion: Int
    /// Version string the loaded library reports.
    public let version: String

    /// Engine handles of recently used tracks, least recently used first (tracks are values, compared by equality).
    private var compiled: [(track: Track, handle: TrackHandle)] = []
    private let compiledLimit = 64
    private let lock = NSLock()

    /// Throws when the loaded library speaks another interface version than this adapter.
    public init() throws {
        apiVersion = Int(cvkf_api_version())
        guard apiVersion == Self.expectedAPIVersion else {
            throw EngineError(code: EngineError.engineInternal,
                              message: "keyframe engine interface \(apiVersion) is incompatible (expected \(Self.expectedAPIVersion))")
        }
        version = String(cString: cvkf_version())
    }

    /// Throws `EngineError` when the engine rejects the track.
    public func validate(_ track: Track) throws {
        _ = try handle(for: track)
    }

    public func evaluate(_ track: Track, frame: Double) throws -> Value {
        let h = try handle(for: track)
        var out: [Double] = [0, 0, 0, 0]
        try Self.run { cvkf_track_evaluate(h.pointer, frame, &out, $0) }
        return Self.value(track.valueType, out)
    }

    /// Values of `count` consecutive frames from `firstFrame`, flattened (`count * componentCount` doubles).
    public func sample(_ track: Track, firstFrame: Double, count: Int) throws -> [Double] {
        try Self.checkBudget(count)
        let h = try handle(for: track)
        var out = [Double](repeating: 0, count: max(0, count) * track.valueType.componentCount)
        try out.withUnsafeMutableBufferPointer { buffer in
            try Self.run { cvkf_track_sample(h.pointer, firstFrame, Double(count), buffer.baseAddress, $0) }
        }
        return out
    }

    /// Direction of travel, in radians, of a vec2 track at `frame` (NaN while the value stands still).
    public func tangentAngle(_ track: Track, frame: Double) throws -> Double {
        let h = try handle(for: track)
        var angle = 0.0
        try Self.run { cvkf_track_tangent_angle(h.pointer, frame, &angle, $0) }
        return angle
    }

    /// `tangentAngle` for `count` consecutive frames from `firstFrame`.
    public func sampleTangentAngle(_ track: Track, firstFrame: Double, count: Int) throws -> [Double] {
        let h = try handle(for: track)
        var out = [Double](repeating: 0, count: max(0, count))
        try out.withUnsafeMutableBufferPointer { buffer in
            try Self.run { cvkf_track_sample_tangent_angle(h.pointer, firstFrame, Double(count), buffer.baseAddress, $0) }
        }
        return out
    }

    /// Keys that reproduce `track` over [fromFrame, untilFrameExclusive), rebased to start at frame 0.
    public func slice(_ track: Track, fromFrame: Double, untilFrameExclusive: Double) throws -> [SlicedKey] {
        let h = try handle(for: track)
        var result: OpaquePointer?
        try Self.run { cvkf_track_slice(h.pointer, fromFrame, untilFrameExclusive, &result, $0) }
        guard let result else { return [] }
        defer { cvkf_slice_destroy(result) }
        let count = cvkf_slice_count(result)
        guard count > 0, let first = cvkf_slice_keys(result) else { return [] }
        return UnsafeBufferPointer(start: first, count: count).map { sliced in
            let k = sliced.key
            return SlicedKey(frame: k.frame, value: Self.value(track.valueType, k.value),
                             outgoing: Self.interpolation(of: k), outgoingPath: Self.path(of: k),
                             sourceFrame: sliced.source_frame, generated: sliced.generated != 0)
        }
    }

    // MARK: - Engine tracks

    /// Owns one engine track handle.
    final class TrackHandle {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { cvkf_track_destroy(pointer) }
    }

    private func handle(for track: Track) throws -> TrackHandle {
        lock.lock()
        defer { lock.unlock() }
        if let index = compiled.firstIndex(where: { $0.track == track }) {
            let hit = compiled.remove(at: index)
            compiled.append(hit)
            return hit.handle
        }
        let keys = track.keyframes.map { Self.cKey($0, track.valueType) }
        var created: OpaquePointer?
        try keys.withUnsafeBufferPointer { buffer in
            try Self.run { cvkf_track_create(Self.cValueType(track.valueType), buffer.baseAddress, buffer.count, &created, $0) }
        }
        guard let created else {
            throw EngineError(code: EngineError.engineInternal, message: "keyframe engine returned no track")
        }
        let h = TrackHandle(created)
        compiled.append((track, h))
        if compiled.count > compiledLimit { compiled.removeFirst() }
        return h
    }

    private static func checkBudget(_ count: Int) throws {
        guard Double(count) <= maxMaterializedFrames else {
            throw EngineError(code: EngineError.limitExceeded,
                              message: "Engine sample count exceeds the \(Int(maxMaterializedFrames))-frame limit")
        }
    }

    /// Calls the engine with an error out-parameter and turns a non-OK status into `EngineError`.
    private static func run(_ call: (UnsafeMutablePointer<cvkf_error>) -> cvkf_status) throws {
        var error = cvkf_error()
        let status = call(&error)
        if status == CVKF_OK { return }
        let message = withUnsafeBytes(of: error.message) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        throw EngineError(code: String(cString: cvkf_status_code(status)), message: message)
    }

    // MARK: - Conversion to and from cvkf.h

    static func cValueType(_ type: ValueType) -> Int32 {
        switch type {
        case .number: return Int32(CVKF_NUMBER.rawValue)
        case .vec2: return Int32(CVKF_VEC2.rawValue)
        case .rgba: return Int32(CVKF_RGBA.rawValue)
        }
    }

    static func cKey(_ key: Key, _ type: ValueType) -> cvkf_key {
        var c = cvkf_key()
        c.frame = key.frame
        switch key.value {
        case .number(let n): c.value = (n, 0, 0, 0)
        case .vec2(let x, let y): c.value = (x, y, 0, 0)
        case .rgba(let r, let g, let b, let a): c.value = (r, g, b, a)
        }
        // A value of the wrong shape for the track is passed as NaN so the engine reports invalid-value.
        if !matches(key.value, type) { c.value = (.nan, .nan, .nan, .nan) }
        switch key.outgoing {
        case .hold:
            c.outgoing = Int32(CVKF_HOLD.rawValue)
        case .linear:
            c.outgoing = Int32(CVKF_LINEAR.rawValue)
        case let .cubicBezier(x1, y1, x2, y2):
            c.outgoing = Int32(CVKF_CUBIC_BEZIER.rawValue)
            c.x1 = x1; c.y1 = y1; c.x2 = x2; c.y2 = y2
        }
        c.curviness = 1   // the engine's neutral curviness; only a curve path sets another
        switch key.outgoingPath {
        case nil:
            c.path_shape = Int32(CVKF_PATH_LINE.rawValue)
        case .curve(let curviness)?:
            c.path_shape = Int32(CVKF_PATH_CURVE.rawValue)
            c.curviness = curviness
        case let .bezier(cp1, cp2)?:
            c.path_shape = Int32(CVKF_PATH_BEZIER.rawValue)
            c.cp1x = cp1.x; c.cp1y = cp1.y; c.cp2x = cp2.x; c.cp2y = cp2.y
        }
        return c
    }

    private static func matches(_ value: Value, _ type: ValueType) -> Bool {
        switch (value, type) {
        case (.number, .number), (.vec2, .vec2), (.rgba, .rgba): return true
        default: return false
        }
    }

    static func value(_ type: ValueType, _ v: [Double]) -> Value {
        value(type, (v[0], v[1], v[2], v[3]))
    }

    static func value(_ type: ValueType, _ v: (Double, Double, Double, Double)) -> Value {
        switch type {
        case .number: return .number(v.0)
        case .vec2: return .vec2(x: v.0, y: v.1)
        case .rgba: return .rgba(red: v.0, green: v.1, blue: v.2, alpha: v.3)
        }
    }

    static func interpolation(of k: cvkf_key) -> Interpolation {
        switch k.outgoing {
        case Int32(CVKF_HOLD.rawValue): return .hold
        case Int32(CVKF_CUBIC_BEZIER.rawValue): return .cubicBezier(x1: k.x1, y1: k.y1, x2: k.x2, y2: k.y2)
        default: return .linear
        }
    }

    static func path(of k: cvkf_key) -> Path? {
        switch k.path_shape {
        case Int32(CVKF_PATH_CURVE.rawValue): return .curve(curviness: k.curviness)
        case Int32(CVKF_PATH_BEZIER.rawValue): return .bezier(cp1: Point(x: k.cp1x, y: k.cp1y), cp2: Point(x: k.cp2x, y: k.cp2y))
        default: return nil
        }
    }
}
