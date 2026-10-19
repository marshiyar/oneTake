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
// Project keyframe commands. Engine-evaluated values (evaluateNativeParameterTrack)
// and the invalid-interpolation case run against KeyframeRuntime in MpvfxSharedEngineTests (EngineProjectKeyframeCommandsTests).
import XCTest
@testable import MpvfxShared

let keyframeAddress = NativeProjectParameterAddress(sequenceId: "sequence:main", trackId: "track:video", clipId: "clip:first", parameterId: "transform.rotation")

func makeKeyframeCommandDocument(_ engine: KeyframeEngine) -> NativeProjectDocument {
    try! parseNativeProjectDocument(J("""
    {"schemaVersion":1,"id":"project:demo","revision":7,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#101010"},
     "assets":[{"id":"asset:video","kind":"video","name":"video.mov","durationFrames":360}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video","kind":"video","clips":[
      {"id":"clip:first","assetId":"asset:video","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[
        {"schemaVersion":1,"id":"parameter:first:position","parameterId":"transform.position","valueType":"vec2","frameRate":{"numerator":30,"denominator":1},
         "keyframes":[{"id":"position:0","frame":0,"value":{"x":100,"y":200},"outgoing":{"type":"linear"}}]},
        {"schemaVersion":1,"id":"parameter:first:scale","parameterId":"transform.scale","valueType":"number","frameRate":{"numerator":30,"denominator":1},
         "keyframes":[{"id":"scale:0","frame":0,"value":1,"outgoing":{"type":"linear"}}]},
        {"schemaVersion":1,"id":"parameter:first:opacity","parameterId":"transform.opacity","valueType":"number","frameRate":{"numerator":30,"denominator":1},
         "keyframes":[{"id":"opacity:0","frame":0,"value":1,"outgoing":{"type":"linear"}}]}]},
      {"id":"clip:second","assetId":"asset:video","startFrame":120,"durationFrames":120,"sourceInFrame":120,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """), engine: engine)
}

func clipById(_ d: NativeProjectDocument, _ id: String) -> NativeProjectClip { d.sequence.tracks[0].clips.first { $0.id == id }! }
func rotationOf(_ d: NativeProjectDocument) -> NativeParameterTrack? { clipById(d, "clip:first").parameterTracks.first { $0.parameterId == "transform.rotation" } }
func upsertNumber(_ frame: Double, _ value: Double, baseline: Double = 0, outgoing: NativeInterpolation? = nil) -> NativeProjectAtomicKeyframeCommand {
    upsertNumber(at: keyframeAddress, frame, value, baseline: baseline, outgoing: outgoing)
}
func upsertNumber(at a: NativeProjectParameterAddress, _ frame: Double, _ value: Double, baseline: Double = 0,
                  outgoing: NativeInterpolation? = nil) -> NativeProjectAtomicKeyframeCommand {
    .upsert(address: a, valueType: .number, frame: frame, value: .number(value), baselineValue: .number(baseline), outgoing: outgoing)
}
func withParameter(_ p: String) -> NativeProjectParameterAddress { var a = keyframeAddress; a.parameterId = p; return a }
func jsonText<T: Encodable>(_ v: T) -> String { jsJSONStringify(try! .from(v)) }

final class NativeProjectKeyframeCommandsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectKeyframeCommand) -> NativeProjectKeyframeCommandResult {
        try! applyNativeProjectKeyframeCommand(d, c, engine: engine)
    }
    func apply(_ d: NativeProjectDocument, _ c: NativeProjectAtomicKeyframeCommand) -> NativeProjectKeyframeCommandResult { apply(d, .atomic(c)) }
    func serialize(_ d: NativeProjectDocument) -> String { try! serializeNativeProjectDocument(d, engine: engine) }
    func reversible(_ d: NativeProjectDocument, _ c: NativeProjectKeyframeCommand, file: StaticString = #filePath, line: UInt = #line) -> NativeProjectDocument {
        let r = apply(d, c)
        guard case .success(let next, let inverse) = r else { XCTFail("\(r.failure!)", file: file, line: line); return d }
        XCTAssertEqual(next.revision, d.revision, file: file, line: line)
        let reverted = apply(next, inverse)
        XCTAssertTrue(reverted.ok, file: file, line: line)
        XCTAssertEqual(serialize(reverted.document), serialize(d), file: file, line: line)
        return next
    }
    func reversible(_ d: NativeProjectDocument, _ c: NativeProjectAtomicKeyframeCommand, file: StaticString = #filePath, line: UInt = #line) -> NativeProjectDocument {
        reversible(d, .atomic(c), file: file, line: line)
    }
    func assertRejected(_ r: NativeProjectKeyframeCommandResult, _ original: NativeProjectDocument, _ code: NativeProjectKeyframeFailureCode,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.ok, file: file, line: line); XCTAssertEqual(r.document, original, file: file, line: line)
        XCTAssertEqual(r.failure?.code, code, file: file, line: line)
    }
    func threeKeys() -> NativeProjectDocument {
        var d = reversible(makeKeyframeCommandDocument(engine), upsertNumber(0, 0))
        d = reversible(d, upsertNumber(30, -90)); return reversible(d, upsertNumber(60, -180))
    }

    func testCreatesExactlyOneRotationKey() {
        let original = makeKeyframeCommandDocument(engine)
        let unrelatedBefore = jsonText(clipById(original, "clip:first").parameterTracks)
        let next = reversible(original, upsertNumber(90, -180))
        let rotation = rotationOf(next)!
        XCTAssertEqual(rotation.id, nativeParameterTrackId(clipId: keyframeAddress.clipId, parameterId: keyframeAddress.parameterId))
        XCTAssertEqual(rotation.keyframes.map { [$0.id, jsNumberString($0.frame)] }, [[nativeParameterKeyframeId(parameterTrackId: rotation.id, frame: 90), "90"]])
        XCTAssertEqual(rotation.keyframes[0].value, .number(-180))
        // evaluateNativeParameterTrack(rotation, 45) == -180: EngineProjectKeyframeCommandsTests.
        XCTAssertEqual(jsonText(Array(clipById(next, "clip:first").parameterTracks.prefix(3))), unrelatedBefore)
    }

    func testAddsOneKeyPerAction() {
        var d = makeKeyframeCommandDocument(engine)
        let authored: [(Double, Double)] = [(30, 0), (60, 90), (90, 180)]
        for (i, (f, v)) in authored.enumerated() {
            let r = apply(d, upsertNumber(f, v, baseline: -999))
            XCTAssertTrue(r.ok); d = r.document
            XCTAssertEqual(rotationOf(d)!.keyframes.map(\.frame), authored.prefix(i + 1).map(\.0))
            XCTAssertEqual(rotationOf(d)!.keyframes.map(\.value), authored.prefix(i + 1).map { NativeParameterValue.number($0.1) })
        }
        // Evaluation at 45/75 (45, 135): EngineProjectKeyframeCommandsTests.
    }

    func testCreatesOneKeyAtFrameZero() {
        let next = reversible(makeKeyframeCommandDocument(engine), upsertNumber(0, -30))
        let rotation = clipById(next, "clip:first").parameterTracks.last!
        XCTAssertEqual(rotation.keyframes.count, 1)
        XCTAssertEqual(rotation.keyframes[0].frame, 0); XCTAssertEqual(rotation.keyframes[0].value, .number(-30))
    }

    func testUpsertsExistingFramePreservingId() {
        let withRotation = reversible(makeKeyframeCommandDocument(engine), upsertNumber(90, -180))
        let before = clipById(withRotation, "clip:first")
        let unrelated = jsonText(before.parameterTracks.filter { $0.parameterId != "transform.rotation" })
        let existingId = rotationOf(withRotation)!.keyframes.first { $0.frame == 90 }!.id
        let next = reversible(withRotation, upsertNumber(90, -120, baseline: 999))
        let k = rotationOf(next)!.keyframes.first { $0.frame == 90 }!
        XCTAssertEqual(k.id, existingId); XCTAssertEqual(k.value, .number(-120))
        XCTAssertEqual(jsonText(clipById(next, "clip:first").parameterTracks.filter { $0.parameterId != "transform.rotation" }), unrelated)
    }

    func testEditingSecondClipPreservesFirst() {
        let original = makeKeyframeCommandDocument(engine)
        let firstBefore = jsonText(clipById(original, "clip:first"))
        var a = keyframeAddress; a.clipId = "clip:second"
        let next = reversible(original, upsertNumber(at: a, 60, 0.5, baseline: 1))
        XCTAssertEqual(jsonText(clipById(next, "clip:first")), firstBefore)
    }

    func testUpdatesMovesDeletesAndSetsOutgoing() {
        var d = reversible(makeKeyframeCommandDocument(engine), upsertNumber(0, 0))
        d = reversible(d, upsertNumber(90, -180))
        d = reversible(d, .updateValue(address: keyframeAddress, frame: 90, value: .number(-150)))
        d = reversible(d, .move(address: keyframeAddress, fromFrame: 90, toFrame: 80))
        d = reversible(d, .setOutgoing(address: keyframeAddress, frame: 0, outgoing: .hold))
        d = reversible(d, .delete(address: keyframeAddress, frame: 80))
        let keys = rotationOf(d)!.keyframes
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].frame, 0); XCTAssertEqual(keys[0].value, .number(0)); XCTAssertEqual(keys[0].outgoing, .hold)
    }

    func testCropPivotFollowsMoveAndRetiresOnDeleteWithUndo() {
        var d = reversible(makeKeyframeCommandDocument(engine), upsertNumber(0, 0))
        d = reversible(d, upsertNumber(90, 90))
        let rotation = rotationOf(d)!
        let marker = NativeCropPivotSegment(startRotationKeyId: rotation.keyframes[0].id, endRotationKeyId: rotation.keyframes[1].id,
                                            offsetFraction: .init(x: 0.05, y: -0.1), reference: nil)
        let ci = d.sequence.tracks[0].clips.firstIndex { $0.id == "clip:first" }!
        d.sequence.tracks[0].clips[ci].cropPivotSegments = [marker]
        let moved = reversible(d, .move(address: keyframeAddress, fromFrame: 90, toFrame: 80))
        XCTAssertEqual(clipById(moved, "clip:first").cropPivotSegments, [marker])
        let deleted = apply(moved, .delete(address: keyframeAddress, frame: 80))
        XCTAssertTrue(deleted.ok)
        XCTAssertEqual(clipById(deleted.document, "clip:first").cropPivotSegments, [])
        let undone = apply(deleted.document, deleted.inverse!)
        XCTAssertTrue(undone.ok)
        XCTAssertEqual(clipById(undone.document, "clip:first").cropPivotSegments, [marker])
    }

    func testBatchAcrossParameters() {
        let next = reversible(makeKeyframeCommandDocument(engine), .batch([upsertNumber(90, -180),
            .upsert(address: withParameter("grade.tint"), valueType: .rgba, frame: 90, value: .rgba(.init(red: 1, green: 0, blue: 0, alpha: 1)),
                    baselineValue: .rgba(.init(red: 0, green: 0, blue: 0, alpha: 1)))]))
        XCTAssertEqual(clipById(next, "clip:first").parameterTracks.map(\.parameterId),
                       ["transform.position", "transform.scale", "transform.opacity", "transform.rotation", "grade.tint"])
    }

    func testRejectsMixedBatchWithoutPartialEdit() {
        let original = makeKeyframeCommandDocument(engine)
        var missing = keyframeAddress; missing.clipId = "missing"
        let r = apply(original, .batch([upsertNumber(30, -45), upsertNumber(at: missing, 30, 1)]))
        assertRejected(r, original, .missingClip)
        XCTAssertEqual(serialize(original), serialize(makeKeyframeCommandDocument(engine)))
    }

    func testRejectsFramesOutsideClipRange() {
        for f in [-1.0, 120, 1.5] {
            let o = makeKeyframeCommandDocument(engine); assertRejected(apply(o, upsertNumber(f, 10)), o, .invalidFrame)
        }
    }

    func testRejectsMismatchedValueType() {
        let o = makeKeyframeCommandDocument(engine)
        assertRejected(apply(o, upsertNumber(at: withParameter("transform.position"), 30, 10)), o, .valueTypeMismatch)
    }

    func testRejectsUpdateValueShapeMismatch() {
        let o = makeKeyframeCommandDocument(engine)
        assertRejected(apply(o, .updateValue(address: withParameter("transform.position"), frame: 0, value: .number(10))), o, .valueTypeMismatch)
    }

    func testRejectsFrameRateDrift() {
        var bad = makeKeyframeCommandDocument(engine)
        let ci = bad.sequence.tracks[0].clips.firstIndex { $0.id == "clip:first" }!
        for i in bad.sequence.tracks[0].clips[ci].parameterTracks.indices where bad.sequence.tracks[0].clips[ci].parameterTracks[i].parameterId == "transform.opacity" {
            bad.sequence.tracks[0].clips[ci].parameterTracks[i].frameRate = .init(numerator: 24, denominator: 1)
        }
        assertRejected(apply(bad, .updateValue(address: withParameter("transform.opacity"), frame: 0, value: .number(0.5))), bad, .frameRateMismatch)
    }

    func testSameIdsForSameAddress() {
        let l = apply(makeKeyframeCommandDocument(engine), upsertNumber(90, -180)), r = apply(makeKeyframeCommandDocument(engine), upsertNumber(90, -180))
        XCTAssertTrue(l.ok && r.ok)
        XCTAssertEqual(serialize(l.document), serialize(r.document))
    }

    func testMovesManyAsGroup() {
        let moved = reversible(threeKeys(), .moveMany(address: keyframeAddress, frames: [30, 60], deltaFrames: 5))
        XCTAssertEqual(rotationOf(moved)!.keyframes.map(\.frame), [0, 35, 65])
    }

    func testDeletesManyAsGroup() {
        let deleted = reversible(threeKeys(), .deleteMany(address: keyframeAddress, frames: [60, 30]))
        XCTAssertEqual(rotationOf(deleted)!.keyframes.map(\.frame), [0])
    }

    func testRejectsInvalidOrCollidingMultiMove() {
        let d = threeKeys()
        assertRejected(apply(d, .moveMany(address: keyframeAddress, frames: [0, 30], deltaFrames: 30)), d, .frameCollision)
        assertRejected(apply(d, .moveMany(address: keyframeAddress, frames: [0, 999], deltaFrames: 1)), d, .invalidFrame)
    }

    func testRejectsMixedMultiDelete() {
        var d = reversible(makeKeyframeCommandDocument(engine), upsertNumber(0, 0))
        d = reversible(d, upsertNumber(30, -90))
        assertRejected(apply(d, .deleteMany(address: keyframeAddress, frames: [0, 15])), d, .missingKeyframe)
        XCTAssertEqual(rotationOf(d)!.keyframes.count, 2)
    }
}
