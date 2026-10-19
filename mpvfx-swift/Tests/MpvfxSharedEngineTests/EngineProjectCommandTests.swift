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
// Engine-dependent keyframe and position path command cases, against KeyframeRuntime.
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

func EJ(_ text: String) -> NativeJSONValue { try! NativeJSONValue.parse(text) }
let engineAddress = NativeProjectParameterAddress(sequenceId: "sequence:main", trackId: "track:video", clipId: "clip:first", parameterId: "transform.rotation")
func engineAt(_ p: String) -> NativeProjectParameterAddress { var a = engineAddress; a.parameterId = p; return a }

/// The keyframe command fixture (clip:first, 120 frames, 30 fps).
func engineDocument(_ e: KeyframeEngine, parameterTracks: String = "[]") throws -> NativeProjectDocument {
    try parseNativeProjectDocument(EJ("""
    {"schemaVersion":1,"id":"project:demo","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#101010"},
     "assets":[{"id":"asset:video","kind":"video","name":"video.mov","durationFrames":360}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video","kind":"video","clips":[
      {"id":"clip:first","assetId":"asset:video","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],
       "parameterTracks":\(parameterTracks)}]}]}}
    """), engine: e)
}
func upsert(_ a: NativeProjectParameterAddress, _ f: Double, _ v: Double, outgoing: NativeInterpolation? = nil) -> NativeProjectKeyframeCommand {
    .atomic(.upsert(address: a, valueType: .number, frame: f, value: .number(v), baselineValue: .number(0), outgoing: outgoing))
}
func ok(_ r: NativeProjectKeyframeCommandResult, file: StaticString = #filePath, line: UInt = #line) -> NativeProjectDocument {
    if let f = r.failure { XCTFail("\(f.code.rawValue): \(f.message)", file: file, line: line) }
    return r.document
}
func trackOf(_ d: NativeProjectDocument, _ p: String) -> NativeParameterTrack? { d.sequence.tracks[0].clips[0].parameterTracks.first { $0.parameterId == p } }
func num(_ v: NativeParameterValue) -> Double { if case .number(let n) = v { return n }; return .nan }
func vec(_ v: NativeParameterValue) -> Vec2Value { if case .vec2(let p) = v { return p }; return .init(x: .nan, y: .nan) }

final class EngineProjectKeyframeCommandsTests: XCTestCase {
    func testCreatedRotationEvaluatesHeldBeforeKey() throws {
        let e = try KeyframeRuntime()
        let next = ok(try applyNativeProjectKeyframeCommand(try engineDocument(e), upsert(engineAddress, 90, -180), engine: e))
        XCTAssertEqual(num(try evaluateNativeParameterTrack(trackOf(next, "transform.rotation")!, projectFrame: 45, engine: e)), -180)
    }
    func testAdjacentAuthoredKeysInterpolate() throws {
        let e = try KeyframeRuntime()
        var d = try engineDocument(e)
        for (f, v) in [(30.0, 0.0), (60, 90), (90, 180)] { d = ok(try applyNativeProjectKeyframeCommand(d, upsert(engineAddress, f, v), engine: e)) }
        let r = trackOf(d, "transform.rotation")!
        XCTAssertEqual(num(try evaluateNativeParameterTrack(r, projectFrame: 45, engine: e)), 45)
        XCTAssertEqual(num(try evaluateNativeParameterTrack(r, projectFrame: 75, engine: e)), 135)
    }
    func testInvalidInterpolationReportedDistinctly() throws {
        let e = try KeyframeRuntime()
        let original = try engineDocument(e)
        let r = try applyNativeProjectKeyframeCommand(original, upsert(engineAddress, 90, -180, outgoing: .cubicBezier(.init(x1: -1, y1: 0, x2: 1, y2: 1))), engine: e)
        XCTAssertFalse(r.ok); XCTAssertEqual(r.document, original); XCTAssertEqual(r.failure?.code, .invalidInterpolation)
    }
}

// Position path commands
private let ease = NativeInterpolation.cubicBezier(.init(x1: 0.42, y1: 0, x2: 0.58, y2: 1))
private func scalar(_ p: String, _ v: [Double], easing: Bool = true) -> String {
    let o = easing ? #"{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":0.58,"y2":1}}"# : #"{"type":"linear"}"#
    return #"{"schemaVersion":1,"id":"parameter:\#(p)","parameterId":"\#(p)","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"\#(p):0","frame":0,"value":\#(jsNumberString(v[0])),"outgoing":\#(o)},{"id":"\#(p):40","frame":40,"value":\#(jsNumberString(v[1])),"outgoing":{"type":"linear"}},{"id":"\#(p):90","frame":90,"value":\#(jsNumberString(v[2])),"outgoing":{"type":"linear"}}]}"#
}

final class EnginePositionPathCommandsTests: XCTestCase {
    var e: KeyframeRuntime!
    override func setUpWithError() throws { e = try KeyframeRuntime() }
    func original(easingY: Bool = true) throws -> NativeProjectDocument {
        try engineDocument(e, parameterTracks: "[\(scalar("transform.position.x", [0, 400, 700])),\(scalar("transform.position.y", [0, 0, 250], easing: easingY))]")
    }
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectKeyframeCommand) throws -> NativeProjectKeyframeCommandResult {
        try applyNativeProjectKeyframeCommand(d, c, engine: e)
    }
    func position(_ d: NativeProjectDocument) -> NativeParameterTrack { trackOf(d, "transform.position")! }
    func curvePath(_ f: Double = 0) -> NativeProjectKeyframeCommand { .atomic(.setMotionPath(address: engineAt("transform.position"), frame: f, path: .curve(curviness: 1))) }
    func curved() throws -> NativeProjectDocument { ok(try apply(try original(), curvePath())) }
    func eval(_ t: NativeParameterTrack, _ f: Double) throws -> NativeParameterValue { try evaluateNativeParameterTrack(t, projectFrame: f, engine: e) }

    func testMergesAlignedXYWithoutChangingAnyFrame() throws {
        let before = try original()
        let after = ok(try apply(before, .atomic(.setAutoRotate(address: engineAt("transform.position"), autoRotate: true))))
        XCTAssertEqual(after.sequence.tracks[0].clips[0].parameterTracks.map(\.parameterId), ["transform.position"])
        XCTAssertEqual(position(after).autoRotate, true)
        let x = trackOf(before, "transform.position.x")!, y = trackOf(before, "transform.position.y")!
        for f in 0..<120 {
            let m = vec(try eval(position(after), Double(f)))
            XCTAssertEqual(m.x, num(try eval(x, Double(f))), accuracy: 5e-10); XCTAssertEqual(m.y, num(try eval(y, Double(f))), accuracy: 5e-10)
        }
    }
    func testCurvesASegment() throws {
        let c = try curved(); let t = position(c)
        XCTAssertEqual(t.keyframes[0].outgoingPath, .curve(curviness: 1))
        XCTAssertEqual(try eval(t, 40), .vec2(.init(x: 400, y: 0)))
        XCTAssertGreaterThan(abs(vec(try eval(t, 20)).y), 1)
        let straight = ok(try apply(c, .atomic(.setMotionPath(address: engineAt("transform.position"), frame: 0, path: nil))))
        XCTAssertNil(position(straight).keyframes[0].outgoingPath)
    }
    func testRefusesMisalignedXY() throws {
        let m = try original(easingY: false)
        let r = try apply(m, curvePath())
        XCTAssertFalse(r.ok); XCTAssertEqual(r.failure?.code, .positionComponentsMisaligned); XCTAssertEqual(r.document, m)
    }
    func testRejectsPathOnLastKey() throws { XCTAssertFalse(try apply(try original(), curvePath(90)).ok) }
    func testChangesOneComponentKeepingEasingAndPath() throws {
        let edited = ok(try apply(try curved(), upsert(engineAt("transform.position.x"), 0, 50)))
        let k = position(edited).keyframes[0]
        XCTAssertEqual(k.value, .vec2(.init(x: 50, y: 0))); XCTAssertEqual(k.outgoing, ease); XCTAssertEqual(k.outgoingPath, .curve(curviness: 1))
        XCTAssertEqual(edited.sequence.tracks[0].clips[0].parameterTracks.map(\.parameterId), ["transform.position"])
    }
    func testAddsKeyWithOtherComponentFromCurve() throws {
        let d = try curved(); let onCurve = vec(try eval(position(d), 20))
        let edited = ok(try apply(d, upsert(engineAt("transform.position.x"), 20, 123)))
        XCTAssertEqual(position(edited).keyframes.first { $0.frame == 20 }!.value, .vec2(.init(x: 123, y: onCurve.y)))
    }
    func testPairedStructuralEditsApplyOnce() throws {
        let moved = ok(try apply(try curved(), .batch([.move(address: engineAt("transform.position.x"), fromFrame: 40, toFrame: 50),
                                                       .move(address: engineAt("transform.position.y"), fromFrame: 40, toFrame: 50)])))
        XCTAssertEqual(position(moved).keyframes.map(\.frame), [0, 50, 90])
        let deleted = ok(try apply(moved, .batch([.delete(address: engineAt("transform.position.x"), frame: 50),
                                                  .delete(address: engineAt("transform.position.y"), frame: 50)])))
        XCTAssertEqual(position(deleted).keyframes.map(\.frame), [0, 90])
    }
    func testUndoesPathEditExactly() throws {
        let d = try curved()
        let r = try apply(d, .atomic(.setAutoRotate(address: engineAt("transform.position"), autoRotate: true)))
        let restored = ok(try apply(r.document, r.inverse!))
        XCTAssertNil(position(restored).autoRotate)
        XCTAssertEqual(position(restored).keyframes, position(d).keyframes)
    }
}

// Property commands — collapse evaluates the track.
final class EngineProjectPropertyCommandsTests: XCTestCase {
    let rotation = #"{"schemaVersion":1,"id":"parameter:rotation","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"key:0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:60","frame":60,"value":-180,"outgoing":{"type":"hold"}}]}"#
    let opacity = #"{"schemaVersion":1,"id":"parameter:opacity","parameterId":"visual.opacity","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"opacity:0","frame":0,"value":1,"outgoing":{"type":"linear"}}]}"#
    func testCollapsesToEvaluatedValue() throws {
        let e = try KeyframeRuntime()
        let before = try engineDocument(e, parameterTracks: "[\(rotation)]")
        let r = try applyNativeProjectPropertyCommand(before, .atomic(.collapseTrack(address: engineAddress, frame: 30)), engine: e)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.document.sequence.tracks[0].clips[0].staticParameters, ["transform.rotation": .number(-90)])
        XCTAssertEqual(r.document.sequence.tracks[0].clips[0].parameterTracks, [])
        XCTAssertEqual(before.sequence.tracks[0].clips[0].parameterTracks.count, 1)
    }
    func testRemovesExactlyTheCollapsedTrack() throws {
        let e = try KeyframeRuntime()
        var d = try engineDocument(e, parameterTracks: "[\(rotation),\(opacity)]")
        d.sequence.tracks[0].clips[0].staticParameters = ["layout.width": .number(640)]
        let r = try applyNativeProjectPropertyCommand(d, .atomic(.collapseTrack(address: engineAddress, frame: 60)), engine: e)
        XCTAssertTrue(r.ok)
        let clip = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.staticParameters, ["layout.width": .number(640), "transform.rotation": .number(-180)])
        XCTAssertEqual(clip.parameterTracks.map { [$0.id, $0.parameterId] }, [["parameter:opacity", "visual.opacity"]])
    }
}

// Position path commands — property commands on a 2D position.
final class EnginePositionPropertyCommandsTests: XCTestCase {
    var e: KeyframeRuntime!
    override func setUpWithError() throws { e = try KeyframeRuntime() }
    func bezierDocument() throws -> NativeProjectDocument {
        func scalar(_ p: String, _ v: [Int]) -> String {
            #"{"schemaVersion":1,"id":"parameter:\#(p)","parameterId":"\#(p)","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"\#(p):0","frame":0,"value":\#(v[0]),"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":0.58,"y2":1}}},{"id":"\#(p):40","frame":40,"value":\#(v[1]),"outgoing":{"type":"linear"}},{"id":"\#(p):90","frame":90,"value":\#(v[2]),"outgoing":{"type":"linear"}}]}"#
        }
        let d = try engineDocument(e, parameterTracks: "[\(scalar("transform.position.x", [0, 400, 700])),\(scalar("transform.position.y", [0, 0, 250]))]")
        return ok(try applyNativeProjectKeyframeCommand(d, .atomic(.setMotionPath(address: engineAt("transform.position"), frame: 0,
            path: .bezier(cp1: .init(x: 0, y: 300), cp2: .init(x: 400, y: 300)))), engine: e))
    }
    func position(_ d: NativeProjectDocument) -> NativeParameterTrack { trackOf(d, "transform.position")! }
    func prop(_ d: NativeProjectDocument, _ c: NativeProjectPropertyCommand) throws -> NativeProjectPropertyCommandResult {
        try applyNativeProjectPropertyCommand(d, c, engine: e)
    }
    func eval(_ t: NativeParameterTrack, _ f: Double) throws -> Vec2Value { vec(try evaluateNativeParameterTrack(t, projectFrame: f, engine: e)) }

    func testAppliesXYMovePairOnce() throws {
        let r = try prop(try bezierDocument(), .batch([.keyframe(.move(address: engineAt("transform.position.x"), fromFrame: 40, toFrame: 55)),
                                                       .keyframe(.move(address: engineAt("transform.position.y"), fromFrame: 40, toFrame: 55))]))
        XCTAssertTrue(r.ok); XCTAssertEqual(position(r.document).keyframes.map(\.frame), [0, 55, 90])
    }
    func testCollapsesWhole2DPosition() throws {
        let d = try bezierDocument()
        let expected = try evaluateNativeParameterTrack(position(d), projectFrame: 20, engine: e)
        let r = try prop(d, .atomic(.collapseTrack(address: engineAt("transform.position.x"), frame: 20)))
        XCTAssertTrue(r.ok)
        let clip = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.parameterTracks, [])
        XCTAssertEqual(clip.staticParameters?["transform.position"], expected)
        XCTAssertNil(clip.staticParameters?["transform.position.x"])
    }
    func testOffsetsBothComponents() throws {
        for delta in [25.0, -25] {
            let d = try bezierDocument()
            let r = try prop(d, .batch([.offsetTrack(address: engineAt("transform.position.x"), delta: delta),
                                        .offsetTrack(address: engineAt("transform.position.y"), delta: delta)]))
            XCTAssertTrue(r.ok)
            let t = position(r.document)
            XCTAssertEqual(t.keyframes[0].outgoingPath, .bezier(cp1: .init(x: delta, y: 300 + delta), cp2: .init(x: 400 + delta, y: 300 + delta)))
            for f in 0...90 {
                let b = try eval(position(d), Double(f)), a = try eval(t, Double(f))
                XCTAssertEqual(a.x, b.x + delta, accuracy: 5e-7); XCTAssertEqual(a.y, b.y + delta, accuracy: 5e-7)
            }
        }
    }
    func testOffsetsOneComponentWithHandles() throws {
        let d = try bezierDocument()
        let r = try prop(d, .atomic(.offsetTrack(address: engineAt("transform.position.x"), delta: 25)))
        XCTAssertTrue(r.ok)
        for f in stride(from: 0.0, through: 90, by: 5) {
            let b = try eval(position(d), f), a = try eval(position(r.document), f)
            XCTAssertEqual(a.x, b.x + 25, accuracy: 5e-7); XCTAssertEqual(a.y, b.y, accuracy: 5e-7)
        }
    }
    func testRefusesStaticXOverAnimated2D() throws {
        let d = try bezierDocument()
        let r = try prop(d, .atomic(.setStatic(address: engineAt("transform.position.x"), value: .number(3))))
        XCTAssertFalse(r.ok); XCTAssertEqual(r.document, d)
    }
}

// Position path commands — displaying a 2D position (UI rows take values from the curve).
final class EnginePositionDisplayTests: XCTestCase {
    func testShowsXYRowsWithValuesFromCurve() throws {
        let e = try KeyframeRuntime()
        func scalar(_ p: String, _ v: [Int]) -> String {
            #"{"schemaVersion":1,"id":"parameter:\#(p)","parameterId":"\#(p)","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"\#(p):0","frame":0,"value":\#(v[0]),"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":0.58,"y2":1}}},{"id":"\#(p):40","frame":40,"value":\#(v[1]),"outgoing":{"type":"linear"}},{"id":"\#(p):90","frame":90,"value":\#(v[2]),"outgoing":{"type":"linear"}}]}"#
        }
        let base = try engineDocument(e, parameterTracks: "[\(scalar("transform.position.x", [0, 400, 700])),\(scalar("transform.position.y", [0, 0, 250]))]")
        let d = ok(try applyNativeProjectKeyframeCommand(base, .atomic(.setMotionPath(address: engineAt("transform.position"), frame: 0, path: .curve(curviness: 1))), engine: e))
        let selected = NativeSelectedElementReference(attributes: ["data-studio-clip-id": "clip:first"], datasetStudioClipId: "clip:first")
        guard case .success(let r) = try projectNativeKeyframeUi(d, .init(selectedElement: selected, playheadSeconds: 20.0 / 30), engine: e) else { return XCTFail() }
        let onCurve = vec(try evaluateNativeParameterTrack(trackOf(d, "transform.position")!, projectFrame: 20, engine: e))
        XCTAssertEqual(r.currentValues[.x]!, onCurve.x, accuracy: 5e-10); XCTAssertEqual(r.currentValues[.y]!, onCurve.y, accuracy: 5e-10)
        XCTAssertEqual(r.keyframeRows.filter { $0.properties[.x] != nil }.map(\.parameterId), Array(repeating: "transform.position.x", count: 3))
        XCTAssertEqual(r.keyframeRows.compactMap { $0.properties[.y] }, [0, 0, 250])
    }
}
