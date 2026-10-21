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
import XCTest
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

/// Issue #449: geometry is evaluated at the playhead; one batch writes the ordinary position parameters.
final class AlignmentTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"id":"alignment","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1000,"height":600,"background":"#000000"},
     "assets":[{"id":"image","kind":"image","name":"image.png","source":"image.png","durationFrames":300},
               {"id":"audio","kind":"audio","name":"audio.wav","source":"audio.wav","durationFrames":300}],
     "sequence":{"id":"sequence","name":"Sequence","tracks":[
      {"id":"v1","kind":"video","clips":[{"id":"a","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"staticParameters":{"layout.left":30,"layout.top":50,"layout.width":100,"layout.height":80}}]},
      {"id":"v2","kind":"video","clips":[{"id":"b","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"staticParameters":{"layout.left":350,"layout.top":170,"layout.width":200,"layout.height":100}}]},
      {"id":"v3","kind":"video","clips":[{"id":"c","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"staticParameters":{"layout.left":800,"layout.top":400,"layout.width":150,"layout.height":120}}]},
      {"id":"sound","kind":"audio","clips":[{"id":"sound","assetId":"audio","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#

    func editor() throws -> TimelineEditor { try TimelineEditor(json: Self.json, engine: KeyframeRuntime()) }
    func bounds(_ e: TimelineEditor, _ id: String, time: Double = 1) throws -> CanvasRect {
        try XCTUnwrap(e.alignmentBounds(clipId: id, time: time))
    }

    func startAnimation(_ e: TimelineEditor, parameter: String, value: NativeParameterValue, type: NativeValueType) -> Bool {
        e.applyProperty(.atomic(.keyframe(.upsert(address: .init(sequenceId: e.sequenceId, trackId: "v1", clipId: "a", parameterId: parameter),
            valueType: type, frame: 0, value: value, baselineValue: value))))
    }

    func testAllSixFrameAlignmentsForASingleClip() throws {
        for action in TimelineAlignment.allCases {
            let e = try editor()
            XCTAssertTrue(e.alignClips(["a"], to: action, time: 1))
            let b = try bounds(e, "a")
            switch action {
            case .left: XCTAssertEqual(b.x, 0)
            case .centre: XCTAssertEqual(b.x + b.width / 2, 500)
            case .right: XCTAssertEqual(b.maxX, 1000)
            case .top: XCTAssertEqual(b.y, 0)
            case .middle: XCTAssertEqual(b.y + b.height / 2, 300)
            case .bottom: XCTAssertEqual(b.maxY, 600)
            }
        }
    }

    func testSelectionReferenceAndMultipleClipsAreOneUndoStep() throws {
        let e = try editor(), before = e.document
        XCTAssertTrue(e.alignClips(["a", "b", "c"], to: .right, relativeTo: .selection, time: 1))
        for id in ["a", "b", "c"] { XCTAssertEqual(try bounds(e, id).maxX, 950) }
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertEqual(e.undoLabel, "Align clips")
        let after = e.document
        XCTAssertFalse(e.alignClips(["a", "b", "c"], to: .right, relativeTo: .selection, time: 1), "no-op adds no history")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.document, after)
    }

    func testHorizontalAndVerticalDistributionHaveEqualGapsAndKeepEndpoints() throws {
        let e = try editor()
        let beforeA = try bounds(e, "a"), beforeC = try bounds(e, "c")
        XCTAssertTrue(e.distributeClips(["a", "b", "c"], along: .horizontal, time: 1))
        let a = try bounds(e, "a"), b = try bounds(e, "b"), c = try bounds(e, "c")
        XCTAssertEqual(a.x, beforeA.x); XCTAssertEqual(c.maxX, beforeC.maxX)
        XCTAssertEqual(b.x - a.maxX, 235); XCTAssertEqual(c.x - b.maxX, 235)
        XCTAssertTrue(e.distributeClips(["a", "b", "c"], along: .vertical, time: 1))
        let aa = try bounds(e, "a"), bb = try bounds(e, "b"), cc = try bounds(e, "c")
        XCTAssertEqual(aa.y, beforeA.y); XCTAssertEqual(cc.maxY, beforeC.maxY)
        XCTAssertEqual(bb.y - aa.maxY, 85); XCTAssertEqual(cc.y - bb.maxY, 85)
        XCTAssertEqual(e.undoStack.count, 2)
    }

    func testCroppedScaledAndRotatedClipAlignsItsTransformedBox() throws {
        let e = try editor()
        var d = e.document
        d.sequence.tracks[0].clips[0].staticParameters?["transform.scale"] = .vec2(.init(x: 2, y: 0.5))
        d.sequence.tracks[0].clips[0].staticParameters?[TimelineEditor.rotationId] = .number(90)
        d.sequence.tracks[0].clips[0].crop = .init(top: 0, right: 20, bottom: 0, left: 10)
        e.loadDocument(try parseNativeProjectDocument(d, engine: e.engine))
        XCTAssertEqual(try bounds(e, "a").width, 40, accuracy: 1e-9)
        XCTAssertEqual(try bounds(e, "a").height, 140, accuracy: 1e-9)
        XCTAssertTrue(e.alignClips(["a"], to: .left, time: 1))
        XCTAssertTrue(e.alignClips(["a"], to: .top, time: 1))
        XCTAssertEqual(try bounds(e, "a").x, 0, accuracy: 1e-9)
        XCTAssertEqual(try bounds(e, "a").y, 0, accuracy: 1e-9)
    }

    func testAnimatedPositionWritesAtPlayheadAndLeavesOtherKeysIntact() throws {
        let e = try editor()
        XCTAssertTrue(startAnimation(e, parameter: TimelineEditor.positionId, value: .vec2(.init(x: 0, y: 0)), type: .vec2))
        XCTAssertTrue(e.alignClips(["a"], to: .right, time: 1))
        XCTAssertEqual(e.parameterValue(clipId: "a", parameterId: TimelineEditor.positionId, time: 0), .vec2(.init(x: 0, y: 0)))
        XCTAssertEqual(e.parameterValue(clipId: "a", parameterId: TimelineEditor.positionId, time: 1), .vec2(.init(x: 870, y: 0)))
        XCTAssertEqual(e.clip("a")?.clip.parameterTracks.first?.keyframes.map(\.frame), [0, 30])
        XCTAssertNil(e.clip("a")?.clip.staticParameters?[TimelineEditor.positionId])
    }

    func testLegacyScalarPositionTrackIsUpdatedInsteadOfBeingOverridden() throws {
        let e = try editor()
        XCTAssertTrue(startAnimation(e, parameter: POSITION_X_PARAMETER_ID, value: .number(0), type: .number))
        XCTAssertTrue(e.alignClips(["a"], to: .right, time: 1))
        XCTAssertEqual(e.parameterValue(clipId: "a", parameterId: POSITION_X_PARAMETER_ID, time: 0), .number(0))
        XCTAssertEqual(e.parameterValue(clipId: "a", parameterId: POSITION_X_PARAMETER_ID, time: 1), .number(870))
        XCTAssertEqual(try bounds(e, "a").maxX, 1000)
    }

    func testUntouchedNaturalMediaKeepsItsFittedSizeWhenAligned() throws {
        let e = try editor()
        var d = e.document
        d.assets[0].naturalSize = .init(width: 100, height: 80)
        d.sequence.tracks[0].clips[0].staticParameters = nil
        e.loadDocument(try parseNativeProjectDocument(d, engine: e.engine))
        XCTAssertEqual(try bounds(e, "a"), CanvasRect(x: 450, y: 260, width: 100, height: 80))
        XCTAssertTrue(e.alignClips(["a"], to: .left, time: 1))
        XCTAssertEqual(try bounds(e, "a"), CanvasRect(x: 0, y: 260, width: 100, height: 80))
        XCTAssertNil(e.clip("a")?.clip.staticParameters?[TimelineEditor.widthId], "position does not resize the media")
    }

    func testPositionsRoundTripWithoutANewRenderingRepresentation() throws {
        let e = try editor()
        XCTAssertTrue(e.alignClips(["a", "b"], to: .middle, time: 1))
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(try bounds(reopened, "a"), try bounds(e, "a"))
        XCTAssertEqual(try bounds(reopened, "b"), try bounds(e, "b"))
    }

    func testLockedAudioMissingAndTooSmallSelectionsCannotPartiallyEdit() throws {
        let e = try editor()
        XCTAssertFalse(e.distributeClips(["a", "b"], along: .horizontal, time: 1))
        XCTAssertFalse(e.alignClips(["a", "sound"], to: .left, time: 1))
        XCTAssertFalse(e.alignClips(["a", "missing"], to: .left, time: 1))
        XCTAssertFalse(e.alignClips([], to: .left, time: 1))
        XCTAssertFalse(e.alignClips(["a"], to: .left, time: .nan))
        var d = e.document; d.sequence.tracks[1].locked = true
        e.loadDocument(try parseNativeProjectDocument(d, engine: e.engine))
        let before = e.document
        XCTAssertFalse(e.alignClips(["a", "b"], to: .left, time: 1))
        XCTAssertEqual(e.document, before); XCTAssertTrue(e.undoStack.isEmpty)
    }
}
