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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes

final class MoveBakeTests: XCTestCase {
    func composition(_ d: NativeProjectDocument, _ engine: KeyframeEngine) -> PreviewComposition {
        PreviewComposition(document: d, projectDir: URL(fileURLWithPath: "/project"), engine: engine, fileExists: { _ in true })
    }

    func testA1EveryKindMatchesThePreviewPainterAtEveryFrame() throws {
        let engine = try KeyframeRuntime()
        var moves = NativeEdgeMoveKind.allCases.flatMap { kind in
            [NativeClipMoves(in: NativeEdgeMove(kind: kind, frames: 15)),
             NativeClipMoves(out: NativeEdgeMove(kind: kind, frames: 15))]
        }
        moves += NativeLoopMoveKind.allCases.map { NativeClipMoves(loop: NativeLoopMove(kind: $0, periodFrames: 20)) }
        moves.append(NativeClipMoves(in: NativeEdgeMove(kind: .grow, frames: 15),
                                    out: NativeEdgeMove(kind: .spin, frames: 15),
                                    loop: NativeLoopMove(kind: .drift, periodFrames: 20)))
        for move in moves {
            var before = try PreviewMovesTests.document(moves: #"{"v":1}"#, engine: engine)
            before.canvas = NativeCanvas(width: 96, height: 48, background: "#000000")
            before.sequence.tracks[0].clips[0].moves = move
            var after = before
            after.sequence.tracks[0].clips[0] = try bakeNativeClipMoves(before.sequence.tracks[0].clips[0],
                canvas: before.canvas, frameRate: before.frameRate, engine: engine)
            let a = composition(before, engine), b = composition(after, engine)
            let image = CanvasImage(width: 4, height: 2, rgba: [UInt8](repeating: 255, count: 32))
            for frame in 0..<60 {
                let time = Double(frame) / 30
                let left = try XCTUnwrap(a.layers(at: time).first), right = try XCTUnwrap(b.layers(at: time).first)
                XCTAssertEqual(left.box.x, right.box.x, accuracy: 1e-8)
                XCTAssertEqual(left.box.y, right.box.y, accuracy: 1e-8)
                XCTAssertEqual(left.scaleX, right.scaleX, accuracy: 1e-8)
                XCTAssertEqual(left.scaleY, right.scaleY, accuracy: 1e-8)
                XCTAssertEqual(left.rotation, right.rotation, accuracy: 1e-8)
                XCTAssertEqual(left.opacity, right.opacity, accuracy: 1e-8)
                let c = try RasterCanvas(width: 96, height: 48), d = try RasterCanvas(width: 96, height: 48)
                c.clear(.opaqueBlack); d.clear(.opaqueBlack)
                let rect = CanvasRect(x: 0, y: 0, width: 96, height: 48)
                PreviewPainter.draw(left, image: image, on: c, frame: rect, scale: 1)
                PreviewPainter.draw(right, image: image, on: d, frame: rect, scale: 1)
                let diff = zip(c.image().rgba, d.image().rgba).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(diff, 1, "frame \(frame), \(move)")
            }
        }
    }

    func testA2OneUndoRestoresMovesAndKeysAndRedoRestoresTheBake() throws {
        let engine = try KeyframeRuntime()
        let before = try PreviewMovesTests.document(moves: #"{"v":1,"in":{"kind":"spin","frames":15}}"#, engine: engine)
        let editor = TimelineEditor(document: before, engine: engine)
        XCTAssertTrue(editor.convertMovesToKeyframes(clipId: "A"))
        let baked = editor.document
        XCTAssertNil(baked.sequence.tracks[0].clips[0].moves)
        XCTAssertEqual(editor.undoLabel, "Convert moves to keyframes")
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.document, before)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.redo()); XCTAssertEqual(editor.document, baked)
        let text = try serializeNativeProjectDocument(baked, engine: engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: engine), baked)
    }

    func testA3ExistingTracksAndKeyIdentitiesSurvive() throws {
        let engine = try KeyframeRuntime()
        var d = try PreviewMovesTests.document(moves: #"{"v":1,"in":{"kind":"slide","frames":15}}"#, engine: engine)
        let original = d.sequence.tracks[0].clips[0]
        let baked = try bakeNativeClipMoves(original, canvas: d.canvas, frameRate: d.frameRate, engine: engine)
        XCTAssertEqual(baked.parameterTracks.first, original.parameterTracks.first)
        let x = try XCTUnwrap(baked.parameterTracks.first { $0.parameterId == "transform.position.x" })
        XCTAssertTrue(x.keyframes.contains { $0.frame == 30 })
        // Bake again with an existing scalar track: its key identities must survive, with combined values.
        d.sequence.tracks[0].clips[0] = baked
        d.sequence.tracks[0].clips[0].moves = original.moves
        let twice = try bakeNativeClipMoves(d.sequence.tracks[0].clips[0], canvas: d.canvas, frameRate: d.frameRate, engine: engine)
        let nextX = try XCTUnwrap(twice.parameterTracks.first { $0.parameterId == x.parameterId })
        for key in x.keyframes { XCTAssertTrue(nextX.keyframes.contains { $0.id == key.id && $0.frame == key.frame }) }
    }

    func testSimpleMovesKeepSparseKeysAndTheirEase() throws {
        let engine = try KeyframeRuntime()
        var d = try PreviewMovesTests.document(moves: #"{"v":1,"in":{"kind":"slide","frames":15}}"#, engine: engine)
        d.sequence.tracks[0].clips[0].parameterTracks = []
        let baked = try bakeNativeClipMoves(d.sequence.tracks[0].clips[0], canvas: d.canvas, frameRate: d.frameRate, engine: engine)
        let x = try XCTUnwrap(baked.parameterTracks.first { $0.parameterId == "transform.position.x" })
        XCTAssertEqual(x.keyframes.map(\.frame), [0, 15, 59])
        XCTAssertEqual(x.keyframes[0].outgoing, NativeMoveEase.easeOut)
    }

    func testAnimatedScaleAndOpacityMultiplyWithMovesAtEveryFrame() throws {
        let engine = try KeyframeRuntime()
        var d = try PreviewMovesTests.document(moves: #"{"v":1,"in":{"kind":"grow","frames":15},"loop":{"kind":"pulse","periodFrames":20}}"#, engine: engine)
        var scale = d.sequence.tracks[0].clips[0].parameterTracks[0]
        scale.id = "scale"; scale.parameterId = "transform.scale"
        scale.keyframes[0].id = "s0"; scale.keyframes[1].id = "s1"
        scale.keyframes[0].value = .vec2(Vec2Value(x: 0.5, y: 1.2))
        scale.keyframes[1].value = .vec2(Vec2Value(x: 1.5, y: 0.8))
        var opacity = scale
        opacity.id = "alpha"; opacity.parameterId = "visual.opacity"; opacity.valueType = .number
        opacity.keyframes[0].id = "a0"; opacity.keyframes[0].value = .number(0.25)
        opacity.keyframes[1].id = "a1"; opacity.keyframes[1].value = .number(0.8)
        d.sequence.tracks[0].clips[0].parameterTracks += [scale, opacity]
        let editor = TimelineEditor(document: d, engine: engine)
        XCTAssertTrue(editor.convertMovesToKeyframes(clipId: "A"))
        let a = composition(d, engine), b = composition(editor.document, engine)
        for frame in 0..<60 {
            let time = Double(frame) / 30
            let x = try XCTUnwrap(a.layers(at: time).first), y = try XCTUnwrap(b.layers(at: time).first)
            XCTAssertEqual(x.scaleX, y.scaleX, accuracy: 1e-9)
            XCTAssertEqual(x.scaleY, y.scaleY, accuracy: 1e-9)
            XCTAssertEqual(x.opacity, y.opacity, accuracy: 1e-9)
        }
    }

    func testLockedTrackAndUnknownMovesRefuseWithoutChangingTheDocument() throws {
        let engine = try KeyframeRuntime()
        for locked in [true, false] {
            var d = try PreviewMovesTests.document(moves: #"{"v":1,"in":{"kind":"slide","frames":15}}"#, engine: engine)
            if locked { d.sequence.tracks[0].locked = true }
            else { d.sequence.tracks[0].clips[0].moves = NativeClipMoves(stored: ["v": .number(2)]) }
            let editor = TimelineEditor(document: d, engine: engine)
            XCTAssertFalse(editor.convertMovesToKeyframes(clipId: "A"))
            XCTAssertEqual(editor.document, d); XCTAssertFalse(editor.canUndo)
        }
    }
}
