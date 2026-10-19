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
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

/// The composition size (document.canvas width × height) is one undoable edit: untouched media clips refit to the
/// new frame, placed clips and text keep their size and their offset from the frame's centre, and the new size is
/// saved in project.json like any other edit.
final class CompositionSizeTests: XCTestCase {
    /// 1920×1080 project: an untouched square video (natural 1080×1080 cached on the asset), a placed image, a text
    /// layer with its own box, an old project's full-canvas size on a 16:9-wrong video, a cropped clip with no size,
    /// a clip with keyframed layout.left/top and a video whose natural size is unknown.
    static let json = #"""
    {"schemaVersion":1,"id":"project:comp","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#000000"},
     "assets":[{"id":"sq","kind":"video","name":"square.mp4","source":"square.mp4","durationFrames":300,"width":1080,"height":1080},
               {"id":"img","kind":"image","name":"logo.png","source":"logo.png","durationFrames":300,"width":400,"height":200},
               {"id":"txt","kind":"element","name":"Title","durationFrames":300},
               {"id":"old","kind":"video","name":"old.mp4","source":"old.mp4","durationFrames":300,"width":1000,"height":1000},
               {"id":"unk","kind":"video","name":"unknown.mp4","source":"unknown.mp4","durationFrames":300}],
     "sequence":{"id":"seq","name":"Sequence","tracks":[{"id":"v1","kind":"video","clips":[
      {"id":"natural","assetId":"sq","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
      {"id":"placed","assetId":"img","startFrame":30,"durationFrames":30,"sourceInFrame":0,"muted":false,
       "staticParameters":{"layout.left":100,"layout.top":50,"layout.width":400,"layout.height":200},"effects":[],"parameterTracks":[]},
      {"id":"legacy","assetId":"old","startFrame":60,"durationFrames":30,"sourceInFrame":0,"muted":false,
       "staticParameters":{"layout.width":1920,"layout.height":1080},"effects":[],"parameterTracks":[]},
      {"id":"cropped","assetId":"unk","startFrame":90,"durationFrames":30,"sourceInFrame":0,"muted":false,
       "crop":{"top":10,"right":20,"bottom":30,"left":40},"effects":[],"parameterTracks":[]},
      {"id":"full","assetId":"unk","startFrame":120,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
      {"id":"moving","assetId":"img","startFrame":150,"durationFrames":30,"sourceInFrame":0,"muted":false,
       "staticParameters":{"layout.width":400,"layout.height":200},"effects":[],"parameterTracks":[
        {"schemaVersion":1,"id":"native-parameter:6:moving|11:layout.left","parameterId":"layout.left","valueType":"number",
         "frameRate":{"numerator":30,"denominator":1},"keyframes":[
          {"id":"k0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"k1","frame":20,"value":1520,"outgoing":{"type":"linear"}}]}]}]},
      {"id":"t1","kind":"video","clips":[
      {"id":"title","assetId":"txt","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,
       "staticParameters":{"layout.left":192,"layout.top":490,"layout.width":1536,"layout.height":100},
       "text":{"content":"Hello"},"effects":[],"parameterTracks":[]}]}]}}
    """#

    func editor() throws -> TimelineEditor { try TimelineEditor(json: Self.json, engine: KeyframeRuntime()) }

    func box(_ e: TimelineEditor, _ id: String, time: Double = 0) -> NativeClipLayoutBox {
        let o = e.layoutOrigin(clipId: id, time: time), t = e.transform(clipId: id, time: time)
        return NativeClipLayoutBox(left: o.x, top: o.y, width: t.width ?? e.document.canvas.width, height: t.height ?? e.document.canvas.height)
    }

    /// The box's centre measured from the frame's centre.
    func centreOffset(_ e: TimelineEditor, _ id: String, time: Double = 0) -> (Double, Double) {
        let b = box(e, id, time: time)
        return (b.left + b.width / 2 - e.document.canvas.width / 2, b.top + b.height / 2 - e.document.canvas.height / 2)
    }

    func testSetCanvasSizeIsOneUndoableEditThatRedoes() throws {
        let e = try editor()
        let before = e.document
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1920))
        XCTAssertEqual(e.document.canvas.width, 1080); XCTAssertEqual(e.document.canvas.height, 1920)
        XCTAssertEqual(e.document.canvas.background, "#000000", "the background is kept")
        XCTAssertEqual(e.undoLabel, "Set composition size")
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, before, "undo restores the size and every clip")
        XCTAssertTrue(e.redo())
        XCTAssertEqual(e.document.canvas.width, 1080); XCTAssertEqual(e.document.canvas.height, 1920)
        XCTAssertEqual(box(e, "placed"), NativeClipLayoutBox(left: -320, top: 470, width: 400, height: 200))
    }

    func testTheSameSizeIsNoEditAndInvalidSizesAreRefused() throws {
        let e = try editor()
        XCTAssertTrue(e.setCanvasSize(width: 1920, height: 1080))
        XCTAssertTrue(e.undoStack.isEmpty, "nothing changed, nothing to undo")
        let before = e.document
        let refused = [(0.0, 1080.0), (-2, 1080), (1920.5, 1080), (1920, .nan), (.infinity, 1080), (16385, 1080)]
            .filter { !e.setCanvasSize(width: $0.0, height: $0.1) && e.lastFailure != nil }
        XCTAssertEqual(refused.count, 6, "zero, negative, fractional, NaN, infinite and over-16384 sides are refused")
        XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.undoStack.isEmpty)
        XCTAssertTrue(e.setCanvasSize(width: 16384, height: 9), "the engine's largest picture side is accepted")
    }

    func testSizeIsSavedAndLoadsBack() throws {
        let e = try editor()
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1350))
        let saved = try serializeNativeProjectDocument(e.document, engine: e.engine)
        let compact = saved.filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains(##""canvas":{"background":"#000000","height":1350,"width":1080}"##), saved)
        let reopened = try TimelineEditor(json: saved, engine: e.engine)
        XCTAssertEqual(reopened.document, e.document, "save and load round trip")
        XCTAssertEqual(box(reopened, "placed"), box(e, "placed"))
        XCTAssertEqual(box(reopened, "natural"), NativeClipLayoutBox(left: 0, top: 135, width: 1080, height: 1080))
    }

    func testUntouchedClipsRefitToTheNewFrame() throws {
        let e = try editor()
        XCTAssertEqual(box(e, "natural"), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080))
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1920))
        XCTAssertEqual(box(e, "natural"), NativeClipLayoutBox(left: 0, top: 420, width: 1080, height: 1080), "fit and centred in the tall frame")
        XCTAssertNil(e.clip("natural")?.clip.staticParameters?["layout.width"], "still untouched: nothing written on the clip")
        // An old project's untouched full-canvas size refits too, and stays untouched.
        XCTAssertEqual(box(e, "legacy"), NativeClipLayoutBox(left: 40, top: 460, width: 1000, height: 1000))
        XCTAssertNil(e.clip("legacy")?.clip.staticParameters?["layout.width"])
        // Unknown natural size and no box of its own: the full frame, whatever its size.
        XCTAssertEqual(box(e, "full"), NativeClipLayoutBox(left: 0, top: 0, width: 1080, height: 1920))
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1080))
        XCTAssertEqual(box(e, "natural"), NativeClipLayoutBox(left: 0, top: 0, width: 1080, height: 1080))
    }

    func testPlacedClipsAndTextKeepTheirSizeAndOffsetFromTheCentre() throws {
        let e = try editor()
        let placed = centreOffset(e, "placed"), title = centreOffset(e, "title")
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1920))
        XCTAssertEqual(box(e, "placed").width, 400); XCTAssertEqual(box(e, "placed").height, 200)
        XCTAssertEqual(centreOffset(e, "placed").0, placed.0); XCTAssertEqual(centreOffset(e, "placed").1, placed.1)
        XCTAssertEqual(box(e, "title"), NativeClipLayoutBox(left: -228, top: 910, width: 1536, height: 100), "text box size kept")
        XCTAssertEqual(centreOffset(e, "title").0, title.0); XCTAssertEqual(centreOffset(e, "title").1, title.1)
        // Back to the first size: every placed box is exactly where it started.
        XCTAssertTrue(e.setCanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(box(e, "placed"), NativeClipLayoutBox(left: 100, top: 50, width: 400, height: 200))
        XCTAssertEqual(box(e, "title"), NativeClipLayoutBox(left: 192, top: 490, width: 1536, height: 100))
    }

    func testKeyframedPositionsAndCroppedClipsKeepTheirPlace() throws {
        let e = try editor()
        let start = centreOffset(e, "moving", time: 150.0 / 30), end = centreOffset(e, "moving", time: 170.0 / 30)
        let cropped = centreOffset(e, "cropped")
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1920))
        // Every layout.left keyframe moves with the centre; the unset top is written out at its old value first.
        XCTAssertEqual(centreOffset(e, "moving", time: 150.0 / 30).0, start.0)
        XCTAssertEqual(centreOffset(e, "moving", time: 150.0 / 30).1, start.1)
        XCTAssertEqual(centreOffset(e, "moving", time: 170.0 / 30).0, end.0)
        XCTAssertEqual(box(e, "moving").height, 200)
        // A crop is measured against the box it was made on: that box (the old full frame) is kept.
        XCTAssertEqual(box(e, "cropped"), NativeClipLayoutBox(left: -420, top: 420, width: 1920, height: 1080))
        XCTAssertEqual(centreOffset(e, "cropped").0, cropped.0); XCTAssertEqual(centreOffset(e, "cropped").1, cropped.1)
        XCTAssertEqual(e.clip("cropped")?.clip.crop, NativeClipCrop(top: 10, right: 20, bottom: 30, left: 40))
    }

    func testTheSharedRuleMatchesTheEditor() throws {
        let e = try editor()
        let resized = try nativeDocumentResizingCanvas(e.document, width: 1080, height: 1920, natural: { $0.naturalSize }, engine: e.engine)
        XCTAssertTrue(e.setCanvasSize(width: 1080, height: 1920))
        XCTAssertEqual(e.document, resized)
        XCTAssertThrowsError(try nativeDocumentResizingCanvas(e.document, width: 0, height: 10, natural: { $0.naturalSize }, engine: e.engine)) {
            XCTAssertEqual(($0 as? NativeCanvasSizeError)?.message, "The composition width must be a whole number of pixels from 1 to 16384.")
        }
    }
}
