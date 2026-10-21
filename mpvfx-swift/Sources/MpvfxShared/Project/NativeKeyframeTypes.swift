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
// Keyframe and parameter track types, and frame-rate validation.
import Foundation

public let NATIVE_KEYFRAME_SCHEMA_VERSION = 1

/// Copied with its unknown keys for the document frame rate (`{ ...document.frameRate }`).
public struct RationalFrameRate: Codable, Equatable, Hashable, Sendable {
    public var numerator: Double
    public var denominator: Double
    public var spread = NativeSpreadKeys()
    static let known = ["numerator", "denominator"]
    public init(numerator: Double, denominator: Double, spread: NativeSpreadKeys = .init()) {
        self.numerator = numerator; self.denominator = denominator; self.spread = spread
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        numerator = try c.req(Double.self, "numerator"); denominator = try c.req(Double.self, "denominator")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in try c.put(k == "numerator" ? numerator : denominator, k) }
    }
}

/// Copied with its unknown keys for crop-pivot offsetFraction (`{ ...segment.offsetFraction }`).
/// Static-parameter vec2 values are rebuilt as {x, y} (cloneStaticParameterValue) and never carry them.
public struct Vec2Value: Codable, Equatable, Sendable { public var x: Double; public var y: Double
    public var spread = NativeSpreadKeys()
    static let known = ["x", "y"]
    public init(x: Double, y: Double, spread: NativeSpreadKeys = .init()) { self.x = x; self.y = y; self.spread = spread }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        x = try c.req(Double.self, "x"); y = try c.req(Double.self, "y")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in try c.put(k == "x" ? x : y, k) }
    }
}

/// Keyframe rgba values keep unknown keys (`{ ...value }`); static values never do.
public struct RgbaValue: Codable, Equatable, Sendable { public var red, green, blue, alpha: Double
    public var spread = NativeSpreadKeys()
    static let known = ["red", "green", "blue", "alpha"]
    public init(red: Double, green: Double, blue: Double, alpha: Double, spread: NativeSpreadKeys = .init()) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.spread = spread }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        red = try c.req(Double.self, "red"); green = try c.req(Double.self, "green")
        blue = try c.req(Double.self, "blue"); alpha = try c.req(Double.self, "alpha")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            try c.put(k == "red" ? red : k == "green" ? green : k == "blue" ? blue : alpha, k) }
    }
}

public enum NativeValueType: String, Codable, Sendable { case number, vec2, rgba }

/// number | Vec2Value | RgbaValue. Same checks as cloneStaticParameterValue and the engine's
/// packing): JSON number first; then an object with numeric "x" and "y" is vec2 (even if it also
/// has rgba keys); otherwise an object with numeric red/green/blue/alpha is rgba. Unknown keys are kept in
/// the value's `spread` (keyframe values keep them); parse strips them from static values
/// (cloneStaticParameterValue). Strings, booleans, null and arrays are rejected (`typeof === "number"`).
public enum NativeParameterValue: Codable, Equatable, Sendable {
    case number(Double), vec2(Vec2Value), rgba(RgbaValue)
    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), !c.decodeNil(), (try? c.decode(Bool.self)) == nil,
           let n = try? c.decode(Double.self) { self = .number(n); return }
        let o: KeyedDecodingContainer<AnyKey>
        do { o = try decoder.container(keyedBy: AnyKey.self) } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Parameter value must be a number, vec2 or rgba"))
        }
        func num(_ k: String) -> Double? { (try? o.decode(Bool.self, forKey: AnyKey(k))) != nil ? nil : try? o.decode(Double.self, forKey: AnyKey(k)) }
        if num("x") != nil, num("y") != nil { self = .vec2(try Vec2Value(from: decoder)); return }
        if num("red") != nil, num("green") != nil, num("blue") != nil, num("alpha") != nil {
            self = .rgba(try RgbaValue(from: decoder)); return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Parameter value must be a number, vec2 or rgba"))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .number(let n): try c.encode(n); case .vec2(let v): try c.encode(v); case .rgba(let v): try c.encode(v) }
    }
}

/// Unknown keys are kept: cloneInterpolation copies controlPoints with `{ ...controlPoints }`.
public struct CubicBezierControlPoints: Codable, Equatable, Sendable {
    public var x1, y1, x2, y2: Double
    public var spread = NativeSpreadKeys()
    static let known = ["x1", "y1", "x2", "y2"]
    public init(x1: Double, y1: Double, x2: Double, y2: Double, spread: NativeSpreadKeys = .init()) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2; self.spread = spread }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        x1 = try c.req(Double.self, "x1"); y1 = try c.req(Double.self, "y1"); x2 = try c.req(Double.self, "x2"); y2 = try c.req(Double.self, "y2")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in try c.put(k == "x1" ? x1 : k == "y1" ? y1 : k == "x2" ? x2 : y2, k) }
    }
}

public enum NativeInterpolation: Codable, Equatable, Sendable {
    case hold, linear, cubicBezier(CubicBezierControlPoints)
    private enum K: String, CodingKey { case type, controlPoints }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hold": self = .hold
        case "linear": self = .linear
        case "cubic-bezier": self = .cubicBezier(try c.decode(CubicBezierControlPoints.self, forKey: .controlPoints))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown interpolation \(t)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .hold: try c.encode("hold", forKey: .type)
        case .linear: try c.encode("linear", forKey: .type)
        case .cubicBezier(let p): try c.encode("cubic-bezier", forKey: .type); try c.encode(p, forKey: .controlPoints)
        }
    }
}

public enum NativeMotionPath: Codable, Equatable, Sendable {
    case curve(curviness: Double), bezier(cp1: Vec2Value, cp2: Vec2Value)
    private enum K: String, CodingKey { case type, curviness, cp1, cp2 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "curve": self = .curve(curviness: try c.decode(Double.self, forKey: .curviness))
        case "bezier": self = .bezier(cp1: try c.decode(Vec2Value.self, forKey: .cp1), cp2: try c.decode(Vec2Value.self, forKey: .cp2))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown path \(t)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .curve(let v): try c.encode("curve", forKey: .type); try c.encode(v, forKey: .curviness)
        case .bezier(let a, let b): try c.encode("bezier", forKey: .type); try c.encode(a, forKey: .cp1); try c.encode(b, forKey: .cp2)
        }
    }
}

/// Unknown keys at each level are kept as follows:
/// - `spread`: keys on the keyframe object. Kept by `{ ...keyframe }` edits; dropped by createNativeParameterTrack,
///   which rebuilds each keyframe as { id, frame, value, outgoing, outgoingPath? }.
/// - `outgoingSpread` / `outgoingPathSpread`: keys on the outgoing / outgoingPath objects. createNativeParameterTrack
///   keeps those objects as they are; assigning a new interpolation or path (cloneInterpolation /
///   cloneMotionPath / a new object) drops them, so the setters clear them.
/// Nested controlPoints, cp1/cp2 and vec2/rgba values carry their own `spread`.
public struct NativeKeyframe: Codable, Equatable, Sendable {
    public var id: String
    public var frame: Double
    public var value: NativeParameterValue
    public var outgoing: NativeInterpolation { didSet { outgoingSpread = .init() } }
    public var outgoingPath: NativeMotionPath? { didSet { outgoingPathSpread = .init() } }   // absent key when nil
    public var spread = NativeSpreadKeys()
    public var outgoingSpread = NativeSpreadKeys()
    public var outgoingPathSpread = NativeSpreadKeys()
    static let known = ["id", "frame", "value", "outgoing", "outgoingPath"]
    public init(id: String, frame: Double, value: NativeParameterValue, outgoing: NativeInterpolation, outgoingPath: NativeMotionPath? = nil) {
        self.id = id; self.frame = frame; self.value = value; self.outgoing = outgoing; self.outgoingPath = outgoingPath
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); frame = try c.req(Double.self, "frame")
        value = try c.req(NativeParameterValue.self, "value")
        outgoing = try c.req(NativeInterpolation.self, "outgoing")
        outgoingPath = try c.opt(NativeMotionPath.self, "outgoingPath")
        spread = try decodeSpread(decoder, known: Self.known)
        outgoingSpread = spreadOfJSON(try c.opt(NativeJSONValue.self, "outgoing"), known: ["type", "controlPoints"])
        outgoingPathSpread = spreadOfJSON(try c.opt(NativeJSONValue.self, "outgoingPath"), known: ["type", "curviness", "cp1", "cp2"])
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k {
            case "id": try c.put(id, k); case "frame": try c.put(frame, k); case "value": try c.put(value, k)
            case "outgoing": try c.put(overlaySpread(try NativeJSONValueEncoder.encode(outgoing), outgoingSpread), k)
            default: if let p = outgoingPath { try c.put(overlaySpread(try NativeJSONValueEncoder.encode(p), outgoingPathSpread), k) }
            }
        }
    }
    /// cloneKeyframe: a new keyframe object with cloned interpolation and path (their own unknown keys dropped);
    /// the value (`{ ...value }`) and controlPoints / cp1 / cp2 (`{ ...point }`) keep theirs.
    public func jsClone() -> NativeKeyframe {
        NativeKeyframe(id: id, frame: frame, value: value, outgoing: outgoing, outgoingPath: outgoingPath)
    }
}

public struct NativeParameterTrack: Codable, Equatable, Sendable {
    public var schemaVersion: Int = NATIVE_KEYFRAME_SCHEMA_VERSION
    public var id: String
    public var parameterId: String
    public var valueType: NativeValueType
    public var frameRate: RationalFrameRate
    public var keyframes: [NativeKeyframe]
    /// `autoRotate?: true` — encoded only when true.
    public var autoRotate: Bool? = nil
    /// Unknown track-level keys. Parse passes tracks through untouched and `{ ...track }` edits keep them;
    /// createNativeParameterTrack builds a new object and drops them.
    public var spread = NativeSpreadKeys()
}

extension NativeParameterTrack {
    static let known = ["schemaVersion", "id", "parameterId", "valueType", "frameRate", "keyframes", "autoRotate"]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        schemaVersion = try c.opt(Int.self, "schemaVersion") ?? NATIVE_KEYFRAME_SCHEMA_VERSION
        id = try c.req(String.self, "id"); parameterId = try c.req(String.self, "parameterId")
        valueType = try c.req(NativeValueType.self, "valueType"); frameRate = try c.req(RationalFrameRate.self, "frameRate")
        keyframes = try c.req([NativeKeyframe].self, "keyframes"); autoRotate = try c.opt(Bool.self, "autoRotate")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k {
            case "schemaVersion": try c.put(schemaVersion, k); case "id": try c.put(id, k); case "parameterId": try c.put(parameterId, k)
            case "valueType": try c.put(valueType, k); case "frameRate": try c.put(frameRate, k); case "keyframes": try c.put(keyframes, k)
            default: try c.put(autoRotate, k)
            }
        }
    }
}

public struct NativeParameterTrackInput {
    public var id: String, parameterId: String, valueType: NativeValueType
    public var frameRate: RationalFrameRate, keyframes: [NativeKeyframe], autoRotate: Bool?
    public init(id: String, parameterId: String, valueType: NativeValueType, frameRate: RationalFrameRate, keyframes: [NativeKeyframe], autoRotate: Bool? = nil) {
        self.id = id; self.parameterId = parameterId; self.valueType = valueType; self.frameRate = frameRate; self.keyframes = keyframes; self.autoRotate = autoRotate
    }
}

public enum NativeKeyframeValidationCode: String, Sendable {
    case invalidFrameRate = "invalid-frame-rate", invalidTrackId = "invalid-track-id", invalidParameterId = "invalid-parameter-id"
    case emptyTrack = "empty-track", invalidKeyframeId = "invalid-keyframe-id", duplicateKeyframeId = "duplicate-keyframe-id"
    case duplicateKeyframeFrame = "duplicate-keyframe-frame", invalidKeyframeFrame = "invalid-keyframe-frame"
    case invalidValue = "invalid-value", invalidInterpolation = "invalid-interpolation", invalidPath = "invalid-path"
}

public struct NativeKeyframeValidationError: Error, Equatable, CustomStringConvertible {
    public let code: NativeKeyframeValidationCode
    public let message: String
    public var description: String { message }
}

public func validateRationalFrameRate(_ r: RationalFrameRate) throws -> RationalFrameRate {
    func fail(_ m: String) -> NativeKeyframeValidationError { .init(code: .invalidFrameRate, message: m) }
    if !jsIsInteger(r.numerator) { throw fail("Frame-rate numerator must be an integer") }
    if !jsIsInteger(r.denominator) { throw fail("Frame-rate denominator must be an integer") }
    if r.numerator <= 0 { throw fail("Frame-rate numerator must be greater than zero") }
    if r.denominator <= 0 { throw fail("Frame-rate denominator must be greater than zero") }
    return r
}


// MARK: - createNativeParameterTrack

private func validateStableId(_ id: String, _ kind: String) throws {
    if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let code: NativeKeyframeValidationCode = kind == "track" ? .invalidTrackId : kind == "parameter" ? .invalidParameterId : .invalidKeyframeId
        throw NativeKeyframeValidationError(code: code, message: "\(kind.prefix(1).uppercased())\(kind.dropFirst()) ID must not be empty")
    }
}

public func createNativeParameterTrack(_ input: NativeParameterTrackInput, engine: KeyframeEngine? = nil) throws -> NativeParameterTrack {
    try validateStableId(input.id, "track")
    try validateStableId(input.parameterId, "parameter")
    let frameRate = try validateRationalFrameRate(input.frameRate)
    if input.keyframes.isEmpty {
        throw NativeKeyframeValidationError(code: .emptyTrack, message: "Parameter track \(input.id) must contain at least one keyframe")
    }
    var ids = Set<String>()
    var keyframes: [NativeKeyframe] = []
    for k in input.keyframes {
        try validateStableId(k.id, "keyframe")
        if ids.contains(k.id) {
            throw NativeKeyframeValidationError(code: .duplicateKeyframeId, message: "Parameter track \(input.id) has duplicate keyframe ID \(k.id)")
        }
        ids.insert(k.id)
        // Each keyframe is rebuilt as { id, frame, value, outgoing, outgoingPath? }: keyframe-level unknown keys go,
        // the value / outgoing / outgoingPath objects are kept as they are.
        var rebuilt = k; rebuilt.spread = .init()
        keyframes.append(rebuilt)
    }
    if input.autoRotate == true && input.valueType != .vec2 {
        throw NativeKeyframeValidationError(code: .invalidPath, message: "Parameter track \(input.id): auto-rotate needs a 2D value")
    }
    let e = try engine ?? keyframeEngine()
    do {
        try e.validate(KeyframeTrack(valueType: input.valueType, keyframes: keyframes.map {
            .init(frame: $0.frame, value: $0.value, outgoing: $0.outgoing, outgoingPath: $0.outgoingPath) }))
    } catch let err as KeyframeEngineError {
        guard let code = err.trackErrorCode else { throw err }   // non-track errors propagate
        throw NativeKeyframeValidationError(code: NativeKeyframeValidationCode(rawValue: code.rawValue)!,
                                            message: "Parameter track \(input.id): \(err.message)")
    }
    // Stable sort by frame, then id (JS localeCompare; see jsLocaleCompare).
    keyframes = keyframes.enumerated().sorted { a, b in
        if a.element.frame != b.element.frame { return a.element.frame < b.element.frame }
        let c = jsLocaleCompare(a.element.id, b.element.id)
        return c == 0 ? a.offset < b.offset : c < 0
    }.map(\.element)
    return NativeParameterTrack(schemaVersion: NATIVE_KEYFRAME_SCHEMA_VERSION, id: input.id, parameterId: input.parameterId,
                                valueType: input.valueType, frameRate: frameRate, keyframes: keyframes,
                                autoRotate: input.autoRotate == true ? true : nil)
}
