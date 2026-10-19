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
// Engine-dependent project cases, run against the real the keyframe engine-backed KeyframeRuntime.
// Moved here from MpvfxSharedTests (which stays pure Swift).
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

private func engine() throws -> KeyframeRuntime { try KeyframeRuntime() }
private func key(_ id: String, _ f: Double, _ v: NativeParameterValue, _ o: NativeInterpolation = .linear) -> NativeKeyframe {
    NativeKeyframe(id: id, frame: f, value: v, outgoing: o)
}
private func track(_ e: KeyframeEngine, _ id: String, _ pid: String, _ t: NativeValueType, _ rate: RationalFrameRate, _ keys: [NativeKeyframe]) throws -> NativeParameterTrack {
    try createNativeParameterTrack(.init(id: id, parameterId: pid, valueType: t, frameRate: rate, keyframes: keys), engine: e)
}
private func message(_ block: () throws -> Void) -> String {
    do { try block(); return "<no error>" } catch { return "\(error)".lowercased() }
}
private let r30 = RationalFrameRate(numerator: 30, denominator: 1)

// Keyframe types
final class EngineKeyframeTypesTests: XCTestCase {
    func testRejectsDuplicateKeyframeTimes() throws {
        let e = try engine()
        XCTAssertTrue(message { _ = try track(e, "track:position", "transform.position", .vec2, .init(numerator: 60, denominator: 1),
            [key("left", 15, .vec2(.init(x: 0, y: 0))), key("right", 15, .vec2(.init(x: 10, y: 10)))]) }.contains("duplicate keyframe frame 15"))
    }
    func testRejectsNonIntegerFrameTimes() throws {
        let e = try engine()
        XCTAssertTrue(message { _ = try track(e, "track:rotation", "transform.rotation", .number, r30, [key("fractional", 1.5, .number(90))]) }.contains("integer project frame"))
    }
    func testValidatesValuesAgainstDeclaredType() throws {
        let e = try engine()
        XCTAssertTrue(message { _ = try track(e, "track:bad-color", "grade.tint", .rgba, r30, [key("bad", 0, .rgba(.init(red: 1, green: 0.5, blue: 0.25, alpha: 2)))]) }.contains("alpha"))
        XCTAssertTrue(message { _ = try track(e, "track:bad-vector", "transform.position", .vec2, r30, [key("bad", 0, .vec2(.init(x: .nan, y: 0)))]) }.contains("finite"))
    }
    func testValidatesCubicBezierControlPoints() throws {
        let e = try engine()
        XCTAssertTrue(message { _ = try track(e, "track:eased", "transform.scale", .number, r30,
            [key("start", 0, .number(1), .cubicBezier(.init(x1: -0.1, y1: 0, x2: 1, y2: 1)))]) }.contains("x1"))
    }
}

// Keyframe evaluator
final class EngineKeyframeEvaluatorTests: XCTestCase {
    func eval(_ e: KeyframeEngine, _ t: NativeParameterTrack, _ f: Double) throws -> NativeParameterValue { try evaluateNativeParameterTrack(t, projectFrame: f, engine: e) }
    func testUnwrappedRotation() throws {
        let e = try engine()
        let t = try track(e, "track:rotation", "transform.rotation", .number, r30, [key("start", 0, .number(0)), key("end", 90, .number(-180))])
        XCTAssertEqual(try eval(e, t, 45), .number(-90))
    }
    func testEndpointsAndClamping() throws {
        let e = try engine()
        let t = try track(e, "track:opacity", "transform.opacity", .number, .init(numerator: 24, denominator: 1), [key("start", 10, .number(0.25)), key("end", 20, .number(0.75))])
        XCTAssertEqual(try eval(e, t, 0), .number(0.25)); XCTAssertEqual(try eval(e, t, 10), .number(0.25))
        XCTAssertEqual(try eval(e, t, 20), .number(0.75)); XCTAssertEqual(try eval(e, t, 200), .number(0.75))
    }
    func testHoldInterpolation() throws {
        let e = try engine()
        let t = try track(e, "track:position", "transform.position", .vec2, .init(numerator: 25, denominator: 1),
                          [key("start", 0, .vec2(.init(x: 10, y: 20)), .hold), key("end", 25, .vec2(.init(x: 100, y: 200)))])
        XCTAssertEqual(try eval(e, t, 24), .vec2(.init(x: 10, y: 20))); XCTAssertEqual(try eval(e, t, 25), .vec2(.init(x: 100, y: 200)))
    }
    func testComponentwiseVec2AndRgba() throws {
        let e = try engine()
        let p = try track(e, "track:position", "transform.position", .vec2, r30, [key("start", 0, .vec2(.init(x: 0, y: 20))), key("end", 10, .vec2(.init(x: 10, y: 40)))])
        let c = try track(e, "track:color", "grade.color", .rgba, r30, [key("start", 0, .rgba(.init(red: 0, green: 0.2, blue: 0.4, alpha: 0.5))),
                                                                       key("end", 10, .rgba(.init(red: 1, green: 0.4, blue: 0.8, alpha: 1)))])
        XCTAssertEqual(try eval(e, p, 5), .vec2(.init(x: 5, y: 30)))
        XCTAssertEqual(try eval(e, c, 5), .rgba(.init(red: 0.5, green: 0.30000000000000004, blue: 0.6000000000000001, alpha: 0.75)))
    }
    func testCubicBezierTiming() throws {
        let e = try engine()
        let t = try track(e, "track:eased", "transform.scale", .number, r30,
                          [key("start", 0, .number(0), .cubicBezier(.init(x1: 0.42, y1: 0, x2: 1, y2: 1))), key("end", 100, .number(100))])
        guard case .number(let v) = try eval(e, t, 50) else { return XCTFail() }
        XCTAssertEqual(v, 31.5357, accuracy: 0.0005)   // toBeCloseTo(31.5357, 3)
    }
    func testDeterministic() throws {
        let e = try engine()
        let t = try track(e, "track:deterministic", "transform.rotation", .number, .init(numerator: 30_000, denominator: 1_001),
                          [key("start", 0, .number(10), .cubicBezier(.init(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1))), key("end", 120, .number(-350))])
        let first = try eval(e, t, 73)
        XCTAssertNotEqual(try eval(e, t, 5), first)
        XCTAssertEqual(try eval(e, t, 73), first); XCTAssertEqual(try eval(e, t, 73), first)
    }
}

// Keyframe UI projection (value assertions)
final class EngineKeyframeUiProjectionTests: XCTestCase {
    func numberTrack(_ e: KeyframeEngine, _ id: String, _ pid: String, _ keys: [(String, Double, Double, NativeInterpolation)]) throws -> NativeParameterTrack {
        try track(e, id, pid, .number, r30, keys.map { key($0.0, $0.1, .number($0.2), $0.3) })
    }
    func supported(_ e: KeyframeEngine) throws -> [NativeParameterTrack] { [
        try numberTrack(e, "animation:rotation", "transform.rotation", [("rotation:0", 0, 0, .linear), ("rotation:90", 90, -180, .hold)]),
        try numberTrack(e, "animation:x", "transform.position.x", [("x:0", 0, 0, .linear), ("x:90", 90, 100, .linear)]),
        try numberTrack(e, "animation:opacity", "visual.opacity", [("opacity:0", 0, 1, .hold), ("opacity:60", 60, 0.5, .linear)]),
        try numberTrack(e, "animation:unsupported", "grade.temperature", [("temperature:0", 0, 6500, .linear)]),
    ] }
    func document(_ tracks: [NativeParameterTrack]) -> NativeProjectDocument {
        let clip = NativeProjectClip(id: "clip:first", assetId: "asset:video",
            binding: .init(sourceFile: "scenes/main.html", domId: "preview-first", hfId: "hf-first", selector: "#preview-first", selectorIndex: 0),
            startFrame: 30, durationFrames: 120, sourceInFrame: 0, playbackRate: DEFAULT_NATIVE_PLAYBACK_RATE, muted: false, staticParameters: [:], effects: [], parameterTracks: tracks)
        return NativeProjectDocument(schemaVersion: 1, id: "project:ui", revision: 0, frameRate: r30, canvas: .init(width: 1920, height: 1080, background: "#111111"),
            assets: [.init(id: "asset:video", kind: .video, name: "video.mov", durationFrames: 500)],
            sequence: .init(id: "sequence:main", name: "Main", tracks: [.init(id: "track:video", kind: .video, lane: .init(authoredTrack: 0, displayTrack: 0), clips: [clip])]))
    }
    func values(_ e: KeyframeEngine, _ d: NativeProjectDocument, _ seconds: Double) throws -> [NativeKeyframeUiProperty: Double] {
        guard case .success(let p) = try projectNativeKeyframeUi(d, .init(selectedElement: .init(id: "clip:first"), playheadSeconds: seconds), engine: e) else { throw XCTSkip("projection failed") }
        return p.currentValues
    }
    func testEvaluatedCurrentValues() throws {
        let e = try engine()
        XCTAssertEqual(try values(e, document(supported(e)), 75.0 / 30), [.x: 50, .rotation: -90, .opacity: 1])
    }
    func testEverySupportedParameterValue() throws {
        let e = try engine()
        let all: [(String, NativeKeyframeUiProperty)] = [("transform.position.x", .x), ("transform.position.y", .y), ("transform.rotation", .rotation),
            ("transform.scale", .scale), ("transform.scaleX", .scaleX), ("transform.scaleY", .scaleY), ("visual.opacity", .opacity), ("layout.width", .width), ("layout.height", .height)]
        var tracks = try all.enumerated().map { i, p in try numberTrack(e, "track:\(p.0)", p.0, [("key:\(i)", 0, Double(i + 1), .linear)]) }
        tracks.append(try track(e, "wrong:x", "transform.position", .vec2, r30, [key("wrong:key", 0, .vec2(.init(x: 9, y: 10)))]))
        var expected: [NativeKeyframeUiProperty: Double] = [:]
        for (i, p) in all.enumerated() { expected[p.1] = Double(i + 1) }
        XCTAssertEqual(try values(e, document(tracks), 1), expected)
    }
    func test3DValues() throws {
        let e = try engine()
        let all: [(String, NativeKeyframeUiProperty, Double)] = [("transform.position.z", .z, 120), ("transform.rotationX", .rotationX, 12),
            ("transform.rotationY", .rotationY, -18), ("transform.scaleZ", .scaleZ, 0.8), ("transform.perspective", .transformPerspective, 900)]
        let tracks = try all.enumerated().map { i, p in try numberTrack(e, "track:3d:\(i)", p.0, [("key:3d:\(i)", 0, p.2, .linear)]) }
        XCTAssertEqual(try values(e, document(tracks), 1), Dictionary(uniqueKeysWithValues: all.map { ($0.1, $0.2) }))
    }
    func testAnimatedTrackOverridesOnlyMatchingStatic() throws {
        let e = try engine()
        var d = document([try numberTrack(e, "animation:rotation", "transform.rotation", [("rotation:0", 0, 0, .linear), ("rotation:90", 90, -180, .linear)])])
        d.sequence.tracks[0].clips[0].staticParameters = ["transform.position.x": .number(42), "transform.rotation": .number(999)]
        XCTAssertEqual(try values(e, d, 75.0 / 30), [.x: 42, .rotation: -90])
    }
}

// Keyframe commands — invalid interpolation (engine validation)
final class EngineKeyframeCommandsTests: XCTestCase {
    func testRejectsInvalidInterpolationWithTrackUnchanged() throws {
        let e = try engine()
        let original = try track(e, "track:rotation", "transform.rotation", .number, .init(numerator: 30_000, denominator: 1_001),
            [key("a", 0, .number(0)), key("b", 30, .number(-90)), key("c", 60, .number(-180), .hold)])
        let r = try applyNativeKeyframeCommand(original, .setOutgoing(keyframeId: "a", outgoing: .cubicBezier(.init(x1: -1, y1: 0, x2: 1, y2: 1))), engine: e)
        XCTAssertFalse(r.ok); XCTAssertEqual(r.track, original); XCTAssertEqual(r.failure?.code, .invalidInterpolation)
    }
}
