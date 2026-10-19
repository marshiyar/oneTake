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
// Engine-dependent clip command cases (trim/split slice parameter tracks via KeyframeRuntime).
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

private let rotationJSON = #"{"schemaVersion":1,"id":"parameter:first:rotation","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"rotation:0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"rotation:90","frame":90,"value":-180,"outgoing":{"type":"linear"}}]}"#
private let positionJSON = #"{"schemaVersion":1,"id":"parameter:position","parameterId":"transform.position","valueType":"vec2","frameRate":{"numerator":30,"denominator":1},"autoRotate":true,"keyframes":[{"id":"a","frame":0,"value":{"x":0,"y":0},"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":0.58,"y2":1}},"outgoingPath":{"type":"bezier","cp1":{"x":0,"y":300},"cp2":{"x":400,"y":300}}},{"id":"b","frame":50,"value":{"x":400,"y":0},"outgoing":{"type":"linear"},"outgoingPath":{"type":"curve","curviness":1}},{"id":"c","frame":110,"value":{"x":700,"y":250},"outgoing":{"type":"linear"}}]}"#
private let rotationEaseJSON = rotationJSON.replacingOccurrences(of: #""frame":0,"value":0,"outgoing":{"type":"linear"}"#,
    with: #""frame":0,"value":0,"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":0.58,"y2":1}}"#)

private func fixture(_ e: KeyframeEngine, firstTracks: String = "[\(rotationJSON)]") throws -> NativeProjectDocument {
    try parseNativeProjectDocument(EJ("""
    {"schemaVersion":1,"id":"project:move","revision":4,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:video","kind":"video","name":"video.mov","durationFrames":900},{"id":"asset:audio","kind":"audio","name":"audio.wav","durationFrames":900}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":7,"displayTrack":1},"clips":[
       {"id":"clip:first","assetId":"asset:video","startFrame":0,"durationFrames":120,"sourceInFrame":12,"muted":false,"staticParameters":{"transform.rotation":12},
        "effects":[{"id":"effect:grade","effectId":"grade","enabled":true,"parameters":{"lift":0.1}}],"parameterTracks":\(firstTracks)},
       {"id":"clip:second","assetId":"asset:video","startFrame":120,"durationFrames":120,"sourceInFrame":132,"muted":true,"effects":[],"parameterTracks":[]}]},
      {"id":"track:v2","kind":"video","lane":{"authoredTrack":19,"displayTrack":3},"clips":[]},
      {"id":"track:a1","kind":"audio","lane":{"authoredTrack":4,"displayTrack":5},"clips":[
       {"id":"clip:audio","assetId":"asset:audio","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """), engine: e)
}
private let first = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:first")
private func clip(_ d: NativeProjectDocument, _ id: String) -> NativeProjectClip? { d.sequence.tracks.flatMap(\.clips).first { $0.id == id } }
private func edit(_ d: inout NativeProjectDocument, _ id: String, _ f: (inout NativeProjectClip) -> Void) {
    for t in d.sequence.tracks.indices { for c in d.sequence.tracks[t].clips.indices where d.sequence.tracks[t].clips[c].id == id { f(&d.sequence.tracks[t].clips[c]) } }
}
private let rightId = nativeSplitClipId("clip:first", splitFrame: 60)

final class EngineProjectClipCommandsTests: XCTestCase {
    var e: KeyframeRuntime!
    override func setUpWithError() throws { e = try KeyframeRuntime() }
    func run(_ d: NativeProjectDocument, _ c: NativeProjectClipCommand) throws -> NativeProjectClipCommandResult { try applyNativeProjectClipCommand(d, c, engine: e) }
    func expectOk(_ d: NativeProjectDocument, _ c: NativeProjectClipCommand, file: StaticString = #filePath, line: UInt = #line) throws -> NativeProjectDocument {
        let r = try run(d, c); XCTAssertTrue(r.ok, "\(String(describing: r.failure))", file: file, line: line); return r.document
    }
    func frames(_ c: NativeProjectClip, _ i: Int = 0) -> [[Double]] { c.parameterTracks[i].keyframes.map { [$0.frame, num($0.value)] } }
    func eval(_ t: NativeParameterTrack, _ f: Double) throws -> NativeParameterValue { try evaluateNativeParameterTrack(t, projectFrame: f, engine: e) }

    func testRebasesCropPivotOnTrimAndSplitAndRestoresOnUndo() throws {
        var original = try fixture(e)
        let offset = Vec2Value(x: 0.05, y: -0.1)
        edit(&original, "clip:first") { $0.cropPivotSegments = [.init(startRotationKeyId: "rotation:0", endRotationKeyId: "rotation:90", offsetFraction: offset, reference: nil)] }
        func assertBound(_ c: NativeProjectClip, line: UInt = #line) {
            guard let s = c.cropPivotSegments?.first else { return XCTFail("no segment", line: line) }
            let r = c.parameterTracks.first { $0.parameterId == "transform.rotation" }!
            XCTAssertTrue(r.keyframes.contains { $0.id == s.startRotationKeyId }, line: line)
            XCTAssertTrue(r.keyframes.contains { $0.id == s.endRotationKeyId }, line: line)
            XCTAssertEqual(s.offsetFraction, offset, line: line)
        }
        let split = try run(original, .split(address: first, splitFrame: 60)); XCTAssertTrue(split.ok)
        assertBound(clip(split.document, "clip:first")!); assertBound(clip(split.document, rightId)!)
        let undone = try run(split.document, split.inverse!); XCTAssertTrue(undone.ok)
        XCTAssertEqual(try serializeNativeProjectDocument(undone.document, engine: e), try serializeNativeProjectDocument(original, engine: e))
        assertBound(clip(try expectOk(original, .trimIn(address: first, startFrame: 30)), "clip:first")!)
        assertBound(clip(try expectOk(original, .trimOut(address: first, endFrameExclusive: 60)), "clip:first")!)
    }

    func testTrimInAdvancesSourceAndRebasesKeys() throws {
        let original = try fixture(e); let before = clip(original, "clip:first")!
        let t = clip(try expectOk(original, .trimIn(address: first, startFrame: 30)), "clip:first")!
        XCTAssertEqual([t.startFrame, t.sourceInFrame, t.durationFrames], [30, 42, 90])
        XCTAssertEqual(t.effects, before.effects); XCTAssertEqual(t.staticParameters, before.staticParameters)
        XCTAssertEqual(frames(t), [[0, -60], [60, -180]])
    }

    func testTrimOutKeepsPlayableRange() throws {
        let t = clip(try expectOk(try fixture(e), .trimOut(address: first, endFrameExclusive: 60)), "clip:first")!
        XCTAssertEqual([t.startFrame, t.sourceInFrame, t.durationFrames], [0, 12, 60])
        XCTAssertEqual(t.parameterTracks[0].keyframes.map(\.frame), [0, 59])
    }

    func testSplitsDeterministically() throws {
        let d = try expectOk(try fixture(e), .split(address: first, splitFrame: 60))
        let l = clip(d, "clip:first")!, r = clip(d, rightId)!
        XCTAssertEqual([l.startFrame, l.sourceInFrame, l.durationFrames], [0, 12, 60])
        XCTAssertEqual([r.startFrame, r.sourceInFrame, r.durationFrames], [60, 72, 60])
        XCTAssertEqual(r.effects, l.effects); XCTAssertEqual(r.staticParameters, l.staticParameters)
        XCTAssertEqual(frames(l), [[0, 0], [59, -118]]); XCTAssertEqual(frames(r), [[0, -120], [30, -180]])
        XCTAssertNotEqual(r.parameterTracks[0].id, l.parameterTracks[0].id)
    }

    func testSplitsCurvedEasedAutoRotatingPathsExactly() throws {
        let original = try fixture(e, firstTracks: "[\(rotationJSON),\(positionJSON)]")
        let position = clip(original, "clip:first")!.parameterTracks[1]
        let d = try expectOk(original, .split(address: first, splitFrame: 60))
        let left = clip(d, "clip:first")!.parameterTracks.first { $0.parameterId == "transform.position" }!
        let right = clip(d, rightId)!.parameterTracks.first { $0.parameterId == "transform.position" }!
        for frame in 0..<60 { for (half, offset) in [(left, 0), (right, 60)] {
            let x = vec(try eval(position, Double(offset + frame))), a = vec(try eval(half, Double(frame)))
            XCTAssertEqual(a.x, x.x, accuracy: 5e-7, "x at \(offset + frame)"); XCTAssertEqual(a.y, x.y, accuracy: 5e-7, "y at \(offset + frame)")
        } }
        XCTAssertEqual(left.autoRotate, true); XCTAssertEqual(right.autoRotate, true)
        XCTAssertEqual(left.keyframes.first { $0.frame == 50 }?.id, "b"); XCTAssertEqual(right.keyframes.first { $0.frame == 50 }?.id, "c")
        for t in [left, right] { if case .bezier = t.keyframes.first(where: { $0.frame == 0 })?.outgoingPath {} else { XCTFail("not bezier") } }
        XCTAssertNoThrow(try parseNativeProjectDocument(EJ(try serializeNativeProjectDocument(d, engine: e)), engine: e))
    }

    func testAdvancesSourceByRationalRate() throws {
        var fast = try fixture(e); edit(&fast, "clip:first") { $0.playbackRate = .init(numerator: 2, denominator: 1) }
        let t = clip(try expectOk(fast, .trimIn(address: first, startFrame: 30)), "clip:first")!
        XCTAssertEqual(t.sourceInFrame, 72); XCTAssertEqual(t.playbackRate, .init(numerator: 2, denominator: 1))
        var slow = try fixture(e); edit(&slow, "clip:first") { $0.playbackRate = .init(numerator: 1, denominator: 2) }
        let r = clip(try expectOk(slow, .split(address: first, splitFrame: 60)), rightId)!
        XCTAssertEqual(r.sourceInFrame, 42); XCTAssertEqual(r.playbackRate, .init(numerator: 1, denominator: 2))
    }

    func testPreservesFractionalSourcePositions() throws {
        var original = try fixture(e); edit(&original, "clip:first") { $0.playbackRate = .init(numerator: 1, denominator: 2) }
        let trim = try expectOk(original, .trimIn(address: first, startFrame: 1))
        let t = clip(trim, "clip:first")!
        XCTAssertEqual([t.startFrame, t.durationFrames, t.sourceInFrame], [1, 119, 12]); XCTAssertEqual(t.sourceInFraction, .init(numerator: 1, denominator: 2))
        let s = clip(try expectOk(original, .split(address: first, splitFrame: 1)), nativeSplitClipId("clip:first", splitFrame: 1))!
        XCTAssertEqual([s.startFrame, s.sourceInFrame], [1, 12]); XCTAssertEqual(s.sourceInFraction, .init(numerator: 1, denominator: 2))
        let restored = try parseNativeProjectDocument(EJ(try serializeNativeProjectDocument(trim, engine: e)), engine: e)
        XCTAssertEqual(clip(restored, "clip:first")?.sourceInFraction, .init(numerator: 1, denominator: 2))
        let next = clip(try expectOk(restored, .trimIn(address: first, startFrame: 2)), "clip:first")!
        XCTAssertEqual(next.sourceInFrame, 13); XCTAssertNil(next.sourceInFraction)
        XCTAssertEqual(clip(original, "clip:first")?.sourceInFrame, 12); XCTAssertEqual(clip(original, "clip:first")?.durationFrames, 120)
    }

    func testAssignsOnlyExplicitRightBinding() throws {
        var original = try fixture(e); let left = NativeClipDomBinding(sourceFile: "index.html", domId: "clip-first-left")
        edit(&original, "clip:first") { $0.binding = left }
        let d = try expectOk(original, .split(address: first, splitFrame: 60, rightBinding: .init(sourceFile: "index.html", domId: "clip-first-right")))
        XCTAssertEqual(clip(d, "clip:first")?.binding, left)
        XCTAssertEqual(clip(d, rightId)?.binding, .init(sourceFile: "index.html", domId: "clip-first-right"))
    }

    func testRejectsBadRightBindingsAtomically() throws {
        let cases: [(NativeClipDomBinding, NativeProjectClipFailureCode)] = [
            (.init(sourceFile: "index.html", domId: "clip-first-left"), .duplicateSplitBinding),
            (.init(sourceFile: "index.html", domId: "clip-second"), .duplicateSplitBinding),
            (.init(sourceFile: "index.html"), .invalidSplitBinding)]
        for (b, code) in cases {
            var original = try fixture(e)
            edit(&original, "clip:first") { $0.binding = .init(sourceFile: "index.html", domId: "clip-first-left") }
            edit(&original, "clip:second") { $0.binding = .init(sourceFile: "index.html", domId: "clip-second") }
            let r = try run(original, .split(address: first, splitFrame: 60, rightBinding: b))
            XCTAssertFalse(r.ok); XCTAssertEqual(r.document, original); XCTAssertEqual(r.failure?.code, code)
        }
    }

    func testExtendsTrimInUsingSourceHandles() throws {
        var original = try fixture(e); edit(&original, "clip:first") { $0.startFrame = 30 }
        let c = clip(try expectOk(original, .trimIn(address: first, startFrame: 24)), "clip:first")!
        XCTAssertEqual([c.startFrame, c.sourceInFrame, c.durationFrames], [24, 6, 126])
        XCTAssertEqual(c.parameterTracks[0].keyframes.first { $0.id == "rotation:90" }!.frame, 96)
    }

    func testPreservesLinearMotionWhenTrimmingBeforeNextKey() throws {
        let original = try fixture(e)
        let before = clip(original, "clip:first")!.parameterTracks[0]
        let after = clip(try expectOk(original, .trimOut(address: first, endFrameExclusive: 60)), "clip:first")!.parameterTracks[0]
        for f in 0..<60 { XCTAssertEqual(num(try eval(after, Double(f))), num(try eval(before, Double(f))), accuracy: 5e-7) }
    }

    func testPreservesEasedFramesAfterTrims() throws {
        for trimIn in [true, false] {
            let original = try fixture(e, firstTracks: "[\(rotationEaseJSON)]")
            let track = clip(original, "clip:first")!.parameterTracks[0]
            let c = clip(try expectOk(original, trimIn ? .trimIn(address: first, startFrame: 30) : .trimOut(address: first, endFrameExclusive: 60)), "clip:first")!
            for f in 0..<Int(c.durationFrames) {
                XCTAssertEqual(num(try eval(c.parameterTracks[0], Double(f))), num(try eval(track, Double(f + (trimIn ? 30 : 0)))), accuracy: 5e-6, "\(trimIn) \(f)")
            }
        }
    }
}
