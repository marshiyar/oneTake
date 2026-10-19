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
// Keyframe commands. The invalid-interpolation case needs the engine's
// validator and lives in MpvfxSharedEngineTests (EngineKeyframeCommandsTests).
import XCTest
@testable import MpvfxShared

func rotationCommandTrack(_ engine: KeyframeEngine) -> NativeParameterTrack {
    try! createNativeParameterTrack(.init(id: "track:rotation", parameterId: "transform.rotation", valueType: .number,
        frameRate: .init(numerator: 30_000, denominator: 1_001), keyframes: [
            .init(id: "a", frame: 0, value: .number(0), outgoing: .linear),
            .init(id: "b", frame: 30, value: .number(-90), outgoing: .linear),
            .init(id: "c", frame: 60, value: .number(-180), outgoing: .hold)]), engine: engine)
}

final class NativeKeyframeCommandsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func apply(_ t: NativeParameterTrack, _ c: NativeKeyframeCommand) -> NativeKeyframeCommandResult { try! applyNativeKeyframeCommand(t, c, engine: engine) }
    func reversible(_ original: NativeParameterTrack, _ c: NativeKeyframeCommand, file: StaticString = #filePath, line: UInt = #line) -> NativeParameterTrack {
        let applied = apply(original, c)
        guard case .success(let next, let inverse) = applied else { XCTFail("\(applied)", file: file, line: line); return original }
        let reverted = apply(next, inverse)
        XCTAssertTrue(reverted.ok, file: file, line: line)
        XCTAssertEqual(jsJSONStringify(try! .from(reverted.track)), jsJSONStringify(try! .from(original)), file: file, line: line)
        return next
    }
    func frames(_ t: NativeParameterTrack) -> [String] { t.keyframes.map { "\($0.id)@\(jsNumberString($0.frame))" } }
    func assertRejected(_ r: NativeKeyframeCommandResult, _ original: NativeParameterTrack, _ code: NativeKeyframeCommandFailureCode,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.ok, file: file, line: line); XCTAssertEqual(r.track, original, file: file, line: line)
        XCTAssertEqual(r.failure?.code, code, file: file, line: line)
    }

    func testInsertsAtExactFrameWithInverse() {
        let original = rotationCommandTrack(engine)
        let next = reversible(original, .insert(.init(id: "inserted", frame: 45, value: .number(-135), outgoing: .linear)))
        XCTAssertEqual(frames(next), ["a@0", "b@30", "inserted@45", "c@60"])
        XCTAssertEqual(original.keyframes.count, 3)
    }
    func testUpsertAtOccupiedFramePreservesId() {
        let cb = NativeInterpolation.cubicBezier(.init(x1: 0.42, y1: 0, x2: 1, y2: 1))
        let next = reversible(rotationCommandTrack(engine), .upsert(.init(id: "proposed-new-id", frame: 30, value: .number(-45), outgoing: cb)))
        XCTAssertEqual(next.keyframes[1], .init(id: "b", frame: 30, value: .number(-45), outgoing: cb))
    }
    func testUpsertAtEmptyFrameInserts() {
        let next = reversible(rotationCommandTrack(engine), .upsert(.init(id: "new", frame: 15, value: .number(-30), outgoing: .linear)))
        XCTAssertEqual(next.keyframes.first { $0.frame == 15 }?.id, "new")
    }
    func testUpdatesValueOnly() {
        let next = reversible(rotationCommandTrack(engine), .updateValue(keyframeId: "b", value: .number(-120)))
        XCTAssertEqual(next.keyframes[1], .init(id: "b", frame: 30, value: .number(-120), outgoing: .linear))
    }
    func testMovesOneImmutably() {
        let original = rotationCommandTrack(engine)
        let next = reversible(original, .move(keyframeId: "b", toFrame: 45))
        XCTAssertEqual(next.keyframes.first { $0.id == "b" }?.frame, 45)
        XCTAssertEqual(original.keyframes.first { $0.id == "b" }?.frame, 30)
    }
    func testMovesGroupAtomically() {
        let next = reversible(rotationCommandTrack(engine), .moveGroup(keyframeIds: ["c", "b"], deltaFrames: 15))
        XCTAssertEqual(frames(next), ["a@0", "b@45", "c@75"])
    }
    func testDeletesOneOrGroup() {
        XCTAssertEqual(reversible(rotationCommandTrack(engine), .delete(keyframeId: "b")).keyframes.map(\.id), ["a", "c"])
        XCTAssertEqual(reversible(rotationCommandTrack(engine), .deleteGroup(keyframeIds: ["c", "a"])).keyframes.map(\.id), ["b"])
    }
    func testSetsOutgoing() {
        let cb = NativeInterpolation.cubicBezier(.init(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1))
        XCTAssertEqual(reversible(rotationCommandTrack(engine), .setOutgoing(keyframeId: "a", outgoing: cb)).keyframes[0].outgoing, cb)
    }
    func testRejectsInvalidFrameTimes() {
        for c: NativeKeyframeCommand in [.insert(.init(id: "fraction", frame: 1.5, value: .number(1), outgoing: .linear)),
                                         .move(keyframeId: "b", toFrame: -1), .moveGroup(keyframeIds: ["b", "c"], deltaFrames: 0.5)] {
            let o = rotationCommandTrack(engine); assertRejected(apply(o, c), o, .invalidFrame)
        }
    }
    func testRejectsDuplicateIdsAndFrames() {
        let o = rotationCommandTrack(engine)
        assertRejected(apply(o, .insert(.init(id: "b", frame: 15, value: .number(-10), outgoing: .linear))), o, .duplicateKeyframeId)
        assertRejected(apply(o, .move(keyframeId: "a", toFrame: 30)), o, .frameCollision)
    }
    func testRejectsMixedValidMissingGroup() {
        let o = rotationCommandTrack(engine)
        assertRejected(apply(o, .moveGroup(keyframeIds: ["b", "missing"], deltaFrames: 10)), o, .missingKeyframe)
        assertRejected(apply(o, .deleteGroup(keyframeIds: ["a", "missing"])), o, .missingKeyframe)
        XCTAssertEqual(o.keyframes.map(\.frame), [0, 30, 60])
    }
    func testRejectsCrossingOntoOccupiedFrames() {
        let o = rotationCommandTrack(engine)
        assertRejected(apply(o, .moveGroup(keyframeIds: ["a", "b"], deltaFrames: 30)), o, .frameCollision)
    }
    func testRejectsDuplicateIdsInGroup() {
        let o = rotationCommandTrack(engine)
        assertRejected(apply(o, .moveGroup(keyframeIds: ["b", "b"], deltaFrames: 5)), o, .invalidGroup)
    }
    func testRejectsMissingKeyframe() {
        // The invalid-interpolation half of this test runs in EngineKeyframeCommandsTests.
        let o = rotationCommandTrack(engine)
        assertRejected(apply(o, .setOutgoing(keyframeId: "missing", outgoing: .linear)), o, .missingKeyframe)
    }
}
