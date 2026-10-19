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
// Adapter between the app's keyframe model and the keyframe engine adapter (module OneTakeKeyframes).
// The package's KeyframeRuntime speaks its own value types (KeyframeRuntime.Track, .Value, ...); this file makes it the
// app's KeyframeEngine by converting at the boundary, and maps KeyframeRuntime.EngineError to KeyframeEngineError.
import OneTakeKeyframes

extension KeyframeRuntime: KeyframeEngine {
    public func validate(_ track: VkfTrack) throws {
        try bridged { try self.validate(Self.engineTrack(track)) }
    }

    public func evaluate(_ track: VkfTrack, frame: Double) throws -> NativeParameterValue {
        try bridged { Self.nativeValue(try self.evaluate(Self.engineTrack(track), frame: frame)) }
    }

    public func sample(_ track: VkfTrack, firstFrame: Double, count: Int) throws -> [Double] {
        try bridged { try self.sample(Self.engineTrack(track), firstFrame: firstFrame, count: count) }
    }

    public func tangentAngle(_ track: VkfTrack, frame: Double) throws -> Double {
        try bridged { try self.tangentAngle(Self.engineTrack(track), frame: frame) }
    }

    /// Not part of KeyframeEngine: the tangent angle at each of `count` frames.
    public func sampleTangentAngle(_ track: VkfTrack, firstFrame: Double, count: Int) throws -> [Double] {
        try bridged { try self.sampleTangentAngle(Self.engineTrack(track), firstFrame: firstFrame, count: count) }
    }

    public func slice(_ track: VkfTrack, fromFrame: Double, untilFrameExclusive: Double) throws -> [VkfSlicedKey] {
        try bridged {
            try self.slice(Self.engineTrack(track), fromFrame: fromFrame, untilFrameExclusive: untilFrameExclusive).map {
                VkfSlicedKey(frame: $0.frame, value: Self.nativeValue($0.value), outgoing: Self.nativeInterpolation($0.outgoing),
                             outgoingPath: $0.outgoingPath.map(Self.nativePath), sourceFrame: $0.sourceFrame, generated: $0.generated)
            }
        }
    }

    // MARK: - Conversion

    private func bridged<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as KeyframeRuntime.EngineError {
            throw KeyframeEngineError(code: e.code, message: e.message)
        }
    }

    static func engineTrack(_ t: VkfTrack) -> KeyframeRuntime.Track {
        KeyframeRuntime.Track(valueType: engineValueType(t.valueType), keyframes: t.keyframes.map {
            KeyframeRuntime.Key(frame: $0.frame, value: engineValue($0.value), outgoing: engineInterpolation($0.outgoing),
                          outgoingPath: $0.outgoingPath.map(enginePath))
        })
    }

    static func engineValueType(_ t: NativeValueType) -> KeyframeRuntime.ValueType {
        switch t { case .number: return .number; case .vec2: return .vec2; case .rgba: return .rgba }
    }

    /// The value as given; a value whose shape differs from the track's type is rejected by the engine (invalid-value).
    static func engineValue(_ v: NativeParameterValue) -> KeyframeRuntime.Value {
        switch v {
        case .number(let n): return .number(n)
        case .vec2(let p): return .vec2(x: p.x, y: p.y)
        case .rgba(let c): return .rgba(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
    }

    static func engineInterpolation(_ i: NativeInterpolation) -> KeyframeRuntime.Interpolation {
        switch i {
        case .hold: return .hold
        case .linear: return .linear
        case .cubicBezier(let p): return .cubicBezier(x1: p.x1, y1: p.y1, x2: p.x2, y2: p.y2)
        }
    }

    static func enginePath(_ p: NativeMotionPath) -> KeyframeRuntime.Path {
        switch p {
        case .curve(let v): return .curve(curviness: v)
        case .bezier(let a, let b): return .bezier(cp1: KeyframeRuntime.Point(x: a.x, y: a.y), cp2: KeyframeRuntime.Point(x: b.x, y: b.y))
        }
    }

    static func nativeValue(_ v: KeyframeRuntime.Value) -> NativeParameterValue {
        switch v {
        case .number(let n): return .number(n)
        case .vec2(let x, let y): return .vec2(Vec2Value(x: x, y: y))
        case .rgba(let r, let g, let b, let a): return .rgba(RgbaValue(red: r, green: g, blue: b, alpha: a))
        }
    }

    static func nativeInterpolation(_ i: KeyframeRuntime.Interpolation) -> NativeInterpolation {
        switch i {
        case .hold: return .hold
        case .linear: return .linear
        case .cubicBezier(let x1, let y1, let x2, let y2): return .cubicBezier(CubicBezierControlPoints(x1: x1, y1: y1, x2: x2, y2: y2))
        }
    }

    static func nativePath(_ p: KeyframeRuntime.Path) -> NativeMotionPath {
        switch p {
        case .curve(let v): return .curve(curviness: v)
        case .bezier(let a, let b): return .bezier(cp1: Vec2Value(x: a.x, y: a.y), cp2: Vec2Value(x: b.x, y: b.y))
        }
    }
}

/// Installs the package's KeyframeRuntime into the process-wide slot (installKeyframeEngine). Every desktop shell
/// (Linux, Windows, macOS) calls this from the shared `main.swift` before building its window.
/// Idempotent: an already-installed engine is kept. Returns nil on success, or the load error.
@discardableResult
public func installDefaultKeyframeEngineAtStartup() -> Error? {
    if keyframeEngineInstalled() { return nil }
    do { installKeyframeEngine(try KeyframeRuntime()); return nil } catch let e as KeyframeRuntime.EngineError {
        return KeyframeEngineError(code: e.code, message: e.message)
    } catch { return error }
}
