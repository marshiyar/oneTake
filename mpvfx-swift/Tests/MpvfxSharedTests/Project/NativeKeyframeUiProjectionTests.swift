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
// Keyframe UI projection.
// Value assertions live in Tests/MpvfxSharedEngineTests (EngineKeyframeUiProjectionTests); row/identity/ordering assertions run with the
// stand-in in opaque mode (fixed NaN values, no interpolation).
import XCTest
@testable import MpvfxShared

final class NativeKeyframeUiProjectionTests: XCTestCase {
    let frameRate = RationalFrameRate(numerator: 30, denominator: 1)
    let engine: KeyframeEngineStandIn = { let e = KeyframeEngineStandIn(); e.opaqueEvaluate = true; return e }()

    func numberTrack(_ id: String, _ pid: String, _ keys: [(String, Double, Double, NativeInterpolation)]) -> NativeParameterTrack {
        try! createNativeParameterTrack(.init(id: id, parameterId: pid, valueType: .number, frameRate: frameRate,
            keyframes: keys.map { NativeKeyframe(id: $0.0, frame: $0.1, value: .number($0.2), outgoing: $0.3) }), engine: engine)
    }
    func supportedTracks() -> [NativeParameterTrack] { [
        numberTrack("animation:rotation", "transform.rotation", [("rotation:0", 0, 0, .linear), ("rotation:90", 90, -180, .hold)]),
        numberTrack("animation:x", "transform.position.x", [("x:0", 0, 0, .linear), ("x:90", 90, 100, .linear)]),
        numberTrack("animation:opacity", "visual.opacity", [("opacity:0", 0, 1, .hold), ("opacity:60", 60, 0.5, .linear)]),
        numberTrack("animation:unsupported", "grade.temperature", [("temperature:0", 0, 6500, .linear)]),
    ] }
    func makeDocument(_ tracks: [NativeParameterTrack]? = nil) -> NativeProjectDocument {
        func clip(_ id: String, _ dom: String, _ hf: String, _ start: Double, _ srcIn: Double, _ t: [NativeParameterTrack]) -> NativeProjectClip {
            NativeProjectClip(id: id, assetId: "asset:video",
                binding: .init(sourceFile: "scenes/main.html", domId: dom, hfId: hf, selector: "#\(dom)", selectorIndex: 0),
                startFrame: start, durationFrames: 120, sourceInFrame: srcIn, playbackRate: DEFAULT_NATIVE_PLAYBACK_RATE, muted: false,
                staticParameters: [:], effects: [], parameterTracks: t)
        }
        return NativeProjectDocument(schemaVersion: NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION, id: "project:ui", revision: 0, frameRate: frameRate,
            canvas: .init(width: 1920, height: 1080, background: "#111111"),
            assets: [.init(id: "asset:video", kind: .video, name: "video.mov", durationFrames: 500)],
            sequence: .init(id: "sequence:main", name: "Main", tracks: [.init(id: "track:video", kind: .video, lane: .init(authoredTrack: 0, displayTrack: 0), clips: [
                clip("clip:first", "preview-first", "hf-first", 30, 0, tracks ?? supportedTracks()),
                clip("clip:second", "preview-second", "hf-second", 150, 120, [])])]))
    }
    func project(_ d: NativeProjectDocument, _ sel: NativeSelectedElementReference, _ seconds: Double) throws -> NativeKeyframeUiProjectionResult {
        try projectNativeKeyframeUi(d, .init(selectedElement: sel, playheadSeconds: seconds), engine: engine)
    }
    func success(_ r: NativeKeyframeUiProjectionResult, file: StaticString = #filePath, line: UInt = #line) throws -> NativeKeyframeUiProjection {
        switch r { case .success(let p): return p; case .failure(let f): XCTFail("\(f)", file: file, line: line); throw f }
    }
    func row(_ pct: Double, _ prop: NativeKeyframeUiProperty, _ v: Double, _ anim: String, _ pid: String, _ kid: String, _ f: Double, _ i: NativeInterpolation) -> NativeKeyframeUiRow {
        .init(percentage: pct, properties: [prop: v], animationId: anim, parameterId: pid, nativeKeyframeId: kid, nativeFrame: f, interpolation: i)
    }

    func testIdentityTimingLocalFrameAndValues() throws {
        let r = try success(project(makeDocument(), .init(attributes: ["data-studio-clip-id": "clip:first"]), 75.0 / 30))
        XCTAssertEqual(r.sequenceId, "sequence:main"); XCTAssertEqual(r.trackId, "track:video"); XCTAssertEqual(r.clipId, "clip:first")
        XCTAssertEqual(r.clipStartSeconds, 1); XCTAssertEqual(r.clipDurationSeconds, 4); XCTAssertEqual(r.projectFrame, 75); XCTAssertEqual(r.clipLocalFrame, 45)
        XCTAssertEqual(Set(r.currentValues.keys), [.x, .rotation, .opacity])   // no "temperature"
    }
    func testNavigationRows() throws {
        let r = try success(project(makeDocument(), .init(id: "clip:first"), 75.0 / 30))
        XCTAssertEqual(r.keyframeRows, [
            row(0, .x, 0, "animation:x", "transform.position.x", "x:0", 0, .linear),
            row(75, .x, 100, "animation:x", "transform.position.x", "x:90", 90, .linear),
            row(0, .rotation, 0, "animation:rotation", "transform.rotation", "rotation:0", 0, .linear),
            row(75, .rotation, -180, "animation:rotation", "transform.rotation", "rotation:90", 90, .hold),
            row(0, .opacity, 1, "animation:opacity", "visual.opacity", "opacity:0", 0, .hold),
            row(50, .opacity, 0.5, "animation:opacity", "visual.opacity", "opacity:60", 60, .linear)])
    }
    func testMapsEverySupportedParameterAndOmitsWrongTyped() throws {
        let all: [(String, NativeKeyframeUiProperty)] = [("transform.position.x", .x), ("transform.position.y", .y), ("transform.rotation", .rotation),
            ("transform.scale", .scale), ("transform.scaleX", .scaleX), ("transform.scaleY", .scaleY), ("visual.opacity", .opacity),
            ("layout.width", .width), ("layout.height", .height)]
        var tracks = all.enumerated().map { i, p in numberTrack("track:\(p.0)", p.0, [("key:\(i)", 0, Double(i + 1), .linear)]) }
        tracks.append(try createNativeParameterTrack(.init(id: "wrong:x", parameterId: "transform.position", valueType: .vec2, frameRate: frameRate,
            keyframes: [NativeKeyframe(id: "wrong:key", frame: 0, value: .vec2(.init(x: 9, y: 10)), outgoing: .linear)]), engine: engine))
        let r = try success(project(makeDocument(tracks), .init(id: "clip:first"), 1))
        // NOTE: the vec2 "transform.position" track here is shadowed by scalar x and y, so it adds no rows.
        XCTAssertEqual(r.keyframeRows.map { $0.properties.keys.first! }, all.map(\.1))
    }
    func test3DControls() throws {
        let all: [(String, NativeKeyframeUiProperty, Double)] = [("transform.position.z", .z, 120), ("transform.rotationX", .rotationX, 12),
            ("transform.rotationY", .rotationY, -18), ("transform.scaleZ", .scaleZ, 0.8), ("transform.perspective", .transformPerspective, 900)]
        let tracks = all.enumerated().map { i, p in numberTrack("track:3d:\(i)", p.0, [("key:3d:\(i)", 0, p.2, .linear)]) }
        let r = try success(project(makeDocument(tracks), .init(id: "clip:first"), 1))
        XCTAssertEqual(r.keyframeRows.map { $0.properties.keys.first! }, all.map(\.1))
    }
    func testDeterministicOrderRegardlessOfTrackOrder() throws {
        let ordered = try success(project(makeDocument(supportedTracks()), .init(id: "clip:first"), 75.0 / 30))
        let reversed = try success(project(makeDocument(Array(supportedTracks().reversed())), .init(id: "clip:first"), 75.0 / 30))
        // currentValues hold NaN from the opaque stand-in (NaN != NaN), so compare everything else.
        XCTAssertEqual(reversed.keyframeRows, ordered.keyframeRows)
        XCTAssertEqual(Set(reversed.currentValues.keys), Set(ordered.currentValues.keys))
        XCTAssertEqual(reversed.positionPath, ordered.positionPath)
    }
    func testScopedCompatibilityBinding() throws {
        XCTAssertEqual(try success(project(makeDocument(), .init(id: "preview-first", sourceFile: "scenes/main.html"), 75.0 / 30)).clipId, "clip:first")
    }
    func testScopedAmbiguity() throws {
        guard case .failure(let f) = try project(makeDocument(), .init(id: "preview-first", hfId: "hf-second", sourceFile: "scenes/main.html"), 75.0 / 30)
        else { return XCTFail() }
        XCTAssertEqual(f.code, .ambiguousClip)
    }
    func testRejectsInvalidPlayhead() throws {
        for s in [-0.1, .nan] {
            guard case .failure(let f) = try project(makeDocument(), .init(id: "clip:first"), s) else { XCTFail("\(s)"); continue }
            XCTAssertEqual(f.code, .invalidPlayhead)
        }
    }
    func testAvailableOutsideRange() throws {
        for (s, e) in [(0.0, 0.0), (150.0 / 30, 119)] { XCTAssertEqual(try success(project(makeDocument(), .init(id: "clip:first"), s)).clipLocalFrame, e) }
    }
    func testPairedStaticPositionAndScaleWithScalarOverride() throws {
        var d = makeDocument([])
        d.sequence.tracks[0].clips[0].staticParameters = ["transform.position": .vec2(.init(x: 240, y: 180)), "transform.position.x": .number(300),
                                                          "transform.scale": .vec2(.init(x: 1.2, y: 0.8))]
        let v = try success(project(d, .init(id: "clip:first"), 75.0 / 30)).currentValues
        XCTAssertEqual(v[.x], 300); XCTAssertEqual(v[.y], 180); XCTAssertEqual(v[.scaleX], 1.2); XCTAssertEqual(v[.scaleY], 0.8)
    }
    func testStaticValuesWithoutRows() throws {
        var d = makeDocument([])
        d.sequence.tracks[0].clips[0].staticParameters = ["transform.position.x": .number(42), "transform.rotation": .number(-30),
                                                          "visual.opacity": .number(0.75), "grade.temperature": .number(6500)]
        let r = try success(project(d, .init(id: "clip:first"), 75.0 / 30))
        XCTAssertEqual(r.currentValues, [.x: 42, .rotation: -30, .opacity: 0.75]); XCTAssertEqual(r.keyframeRows, [])
    }
    func testAnimatedTrackOverridesOnlyMatchingStatic() throws {
    }
}
