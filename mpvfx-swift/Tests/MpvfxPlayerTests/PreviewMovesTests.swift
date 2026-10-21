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
// Issue #273 A3: moves on the preview's layers go over the user's keyframes; the stage outline follows the moved box.
import XCTest
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes

final class PreviewMovesTests: XCTestCase {
    /// A 1920×1080 image clip of 60 frames at 30 fps whose position is keyframed (0,0) at frame 0 → (300,120) at 30.
    static func document(moves: String, engine: KeyframeEngine) throws -> NativeProjectDocument {
        let track = #"{"schemaVersion":1,"id":"p","parameterId":"transform.position","valueType":"vec2","frameRate":{"numerator":30,"denominator":1},"#
            + #""keyframes":[{"id":"p0","frame":0,"value":{"x":0,"y":0},"outgoing":{"type":"linear"}},{"id":"p1","frame":30,"value":{"x":300,"y":120},"outgoing":{"type":"linear"}}]}"#
        return try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"id":"project:moves","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"i","kind":"image","name":"i.png","source":"i.png","durationFrames":1}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[
           {"id":"A","assetId":"i","startFrame":0,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[\(track)],"moves":\(moves)}]}]}}
        """), engine: engine)
    }

    func layer(_ d: NativeProjectDocument, frame: Int, engine: KeyframeEngine) throws -> PreviewLayer {
        let comp = PreviewComposition(document: d, projectDir: URL(fileURLWithPath: "/project"), engine: engine, fileExists: { _ in true })
        return try XCTUnwrap(comp.layers(at: Double(frame) / 30).first)
    }

    func testA3ASlideInFromTheLeftStartsAFrameWidthLeftOfTheKeyedPositionAndLandsOnItAtFrame15() throws {
        let engine = try KeyframeRuntime()
        let moved = try Self.document(moves: #"{"v":1,"in":{"kind":"slide","frames":15,"direction":"left"}}"#, engine: engine)
        let still = try Self.document(moves: #"{"v":1}"#, engine: engine)
        let start = try layer(moved, frame: 0, engine: engine), keyedStart = try layer(still, frame: 0, engine: engine)
        XCTAssertEqual(start.box.x, keyedStart.box.x - 1920, accuracy: 1e-9, "a full frame width left of the keyed position")
        XCTAssertEqual(start.box.y, keyedStart.box.y, accuracy: 1e-9)
        let landed = try layer(moved, frame: 15, engine: engine), keyed = try layer(still, frame: 15, engine: engine)
        XCTAssertEqual(keyed.box.x, 150, accuracy: 1e-9, "the keyframes still move the layer")
        XCTAssertEqual(landed, keyed, "exactly on the keyed position at frame 15")
        let between = try layer(moved, frame: 7, engine: engine), keyedBetween = try layer(still, frame: 7, engine: engine)
        XCTAssertLessThan(between.box.x, keyedBetween.box.x); XCTAssertGreaterThan(between.box.x, keyedBetween.box.x - 1920)
        XCTAssertEqual(between.box.y, keyedBetween.box.y, accuracy: 1e-9, "the keyed y keeps animating under the slide")
    }

    func testMovesScaleRotateAndFadeOverTheLayersOwnValues() throws {
        let engine = try KeyframeRuntime()
        let d = try Self.document(moves: #"{"v":1,"out":{"kind":"spin","frames":10,"amount":90,"ease":{"type":"linear"}}}"#, engine: engine)
        let l = try layer(d, frame: 59, engine: engine)
        XCTAssertEqual(l.rotation, 90, accuracy: 1e-9); XCTAssertEqual(l.opacity, 0, accuracy: 1e-9)
        XCTAssertFalse(l.isVisible, "fully faded on the last frame")
        let midway = try layer(d, frame: 54, engine: engine)
        XCTAssertEqual(midway.rotation, 45, accuracy: 1e-9); XCTAssertEqual(midway.opacity, 0.5, accuracy: 1e-9)
    }

    func testTheStageOutlineFollowsTheMovedBoxAndADragWritesTheClipsOwnPosition() throws {
        let engine = try KeyframeRuntime()
        let d = try Self.document(moves: #"{"v":1,"in":{"kind":"grow","frames":10,"amount":50,"ease":{"type":"linear"}},"loop":{"kind":"sway","periodFrames":4,"amount":6,"ease":{"type":"linear"}}}"#, engine: engine)
        let editor = TimelineEditor(document: d, engine: engine)
        let o = editor.moveOffsets(clipId: "A", time: 5.0 / 30)
        let drawn = try layer(d, frame: 5, engine: engine), own = try layer(Self.document(moves: #"{"v":1}"#, engine: engine), frame: 5, engine: engine)
        XCTAssertEqual(drawn, own.moved(by: o), "the stage reads the same offsets the preview draws")
        let element = StageElement(id: "A", name: "A", rect: own.box, kind: .image, rotation: own.rotation)
        let outline = StageGeometry.moved(element, by: o)
        XCTAssertEqual(outline.rect, drawn.box); XCTAssertEqual(outline.rotation, drawn.rotation, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(outline.scale), drawn.scaleX, accuracy: 1e-9)
        var dragged = outline; dragged.rect.x += 40
        let back = StageGeometry.unmoved(dragged, by: o)
        XCTAssertEqual(back.rect.x, own.box.x + 40, accuracy: 1e-9); XCTAssertEqual(back.rotation, own.rotation, accuracy: 1e-9)
        XCTAssertNil(back.scale)
    }
}
