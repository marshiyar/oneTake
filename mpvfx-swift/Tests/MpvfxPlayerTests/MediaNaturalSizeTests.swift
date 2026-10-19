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
import MpvfxTimeline
import MpvfxCanvas
import MpvfxShared

/// A media clip's default box is fitTimelineAssetGeometry of its natural size, and the
/// stage's selection box, the preview's picture and export all use that one box.
final class MediaNaturalSizeTests: XCTestCase {
    static let square = NativeMediaNaturalSize(width: 1080, height: 1080)
    static let portrait = NativeMediaNaturalSize(width: 1080, height: 1920)
    static let wide = NativeMediaNaturalSize(width: 3840, height: 1080)

    /// 1920×1080 project with three media files on disk and one empty video track. `clips` are raw clip JSON.
    static func json(canvas: (Int, Int) = (1920, 1080), assetExtra: String = "", clips: String = "") -> String {
        #"""
        {"schemaVersion":1,"id":"project:fit","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":\#(canvas.0),"height":\#(canvas.1),"background":"#000000"},
         "assets":[{"id":"sq","kind":"video","name":"square.mp4","source":"square.mp4","durationFrames":300\#(assetExtra)},
                   {"id":"po","kind":"image","name":"portrait.png","source":"portrait.png","durationFrames":150},
                   {"id":"wi","kind":"video","name":"wide.mp4","source":"wide.mp4","durationFrames":300}],
         "sequence":{"id":"seq","name":"Sequence","tracks":[{"id":"v1","kind":"video","clips":[\#(clips)]}]}}
        """#
    }

    func box(_ e: TimelineEditor, _ id: String) -> NativeClipLayoutBox {
        let o = e.layoutOrigin(clipId: id, time: 0), t = e.transform(clipId: id, time: 0)
        // Unset width/height draw at the canvas size (PreviewComposition / ExportClipSampler fallback).
        return NativeClipLayoutBox(left: o.x + (t.x ?? 0), top: o.y + (t.y ?? 0),
                                   width: t.width ?? e.document.canvas.width, height: t.height ?? e.document.canvas.height)
    }

    // MARK: The fit rule (fitTimelineAssetGeometry)

    func testFitMatchesTheReferenceCases() {
        XCTAssertEqual(fitTimelineAssetGeometry(.init(width: 640, height: 360), compWidth: 1920, compHeight: 1080),
                       NativeClipLayoutBox(left: 640, top: 360, width: 640, height: 360))
        XCTAssertEqual(fitTimelineAssetGeometry(.init(width: 4000, height: 1000), compWidth: 1920, compHeight: 1080),
                       NativeClipLayoutBox(left: 0, top: 300, width: 1920, height: 480))
        XCTAssertEqual(fitTimelineAssetGeometry(nil, compWidth: 1920, compHeight: 1080),
                       NativeClipLayoutBox(left: 0, top: 0, width: 1920, height: 1080))
        // JS Math.round on a .5: 1080 × 0.5625 = 607.5 → 608, left (1920 − 608) / 2 = 656.
        XCTAssertEqual(fitTimelineAssetGeometry(Self.portrait, compWidth: 1920, compHeight: 1080),
                       NativeClipLayoutBox(left: 656, top: 0, width: 608, height: 1080))
    }

    func testDisplaySizeAppliesSampleAspectAndRotation() {
        XCTAssertEqual(NativeMediaNaturalSize.display(width: 1920, height: 1080, rotation: -90), .init(width: 1080, height: 1920))
        XCTAssertEqual(NativeMediaNaturalSize.display(width: 720, height: 576, sampleAspect: 16.0 / 15.0), .init(width: 768, height: 576))
        XCTAssertEqual(NativeMediaNaturalSize.display(width: 100, height: 50, sampleAspect: 0), .init(width: 100, height: 50))
        XCTAssertNil(NativeMediaNaturalSize.display(width: 0, height: 50))
    }

    // MARK: insert

    func testSquarePortraitAndWideInsertIntoA16x9ProjectAtTheirFittedRects() throws {
        let e = try TimelineEditor(json: Self.json())
        var ids: [String: String] = [:]
        for (name, kind, natural) in [("a.mp4", NativeProjectAssetKind.video, Self.square), ("b.png", .image, Self.portrait), ("c.mp4", .video, Self.wide)] {
            let asset = try XCTUnwrap(e.addAsset(kind: kind, name: name, source: name, durationFrames: 90, naturalSize: natural))
            XCTAssertEqual(e.document.assets.first { $0.id == asset }?.naturalSize, natural, "natural size cached on the asset")
            ids[name] = try XCTUnwrap(e.insertClip(assetId: asset, at: 0))
        }
        XCTAssertEqual(box(e, ids["a.mp4"]!), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080))
        XCTAssertEqual(box(e, ids["b.png"]!), NativeClipLayoutBox(left: 656, top: 0, width: 608, height: 1080))
        XCTAssertEqual(box(e, ids["c.mp4"]!), NativeClipLayoutBox(left: 0, top: 270, width: 1920, height: 540))
        // Smaller than the project: natural size, centred.
        let small = try XCTUnwrap(e.addAsset(kind: .image, name: "s.png", source: "s.png", durationFrames: 90, naturalSize: .init(width: 300, height: 200)))
        let s = try XCTUnwrap(e.insertClip(assetId: small, at: 10))
        XCTAssertEqual(box(e, s), NativeClipLayoutBox(left: 810, top: 440, width: 300, height: 200))
        // Nothing is written on the clip: an untouched size means "natural", as clips are inserted with {}.
        XCTAssertNil(e.clip(ids["a.mp4"]!)?.clip.staticParameters?["layout.width"])
        // Undo the insert: the clip goes; redo: it comes back with the same box.
        XCTAssertTrue(e.undo()); XCTAssertNil(e.clip(s))
        XCTAssertTrue(e.redo()); XCTAssertEqual(box(e, s), NativeClipLayoutBox(left: 810, top: 440, width: 300, height: 200))
    }

    func testAPreviouslyAddedAssetInsertsAtItsNaturalSizeOnEveryPath() throws {
        // insertClip is the one path the bin, drags, the stage drop and "add at playhead" share.
        let e = try TimelineEditor(json: Self.json(assetExtra: #","width":1080,"height":1080"#))
        let id = try XCTUnwrap(e.insertClip(assetId: "sq", at: 0))
        XCTAssertEqual(box(e, id), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080))
        // Unknown natural size (not probed yet): full frame.
        let w = try XCTUnwrap(e.insertClip(assetId: "wi", at: 0))
        XCTAssertEqual(box(e, w), NativeClipLayoutBox(left: 0, top: 0, width: 1920, height: 1080))
        // The host's probe arrives: the same clip now shows its natural box without any document change.
        let before = e.document
        e.naturalSize = { $0.naturalSize ?? ($0.id == "wi" ? Self.wide : nil) }
        XCTAssertEqual(box(e, w), NativeClipLayoutBox(left: 0, top: 270, width: 1920, height: 540))
        XCTAssertEqual(e.document, before)
    }

    // MARK: old projects

    func testOldProjectsWithTheUntouchedFullCanvasSizeShowTheMediaBox() throws {
        let clip = #"{"id":"c1","assetId":"sq","startFrame":0,"durationFrames":90,"sourceInFrame":0,"muted":false,"staticParameters":%@,"effects":[],"parameterTracks":[]}"#
        func editor(_ sp: String) throws -> TimelineEditor {
            let e = try TimelineEditor(json: Self.json(clips: clip.replacingOccurrences(of: "%@", with: sp)))
            e.naturalSize = { $0.id == "sq" ? Self.square : nil }   // sizes probed by the session for an old asset
            return e
        }
        // Size never set, and size written out as the composition size with another aspect: both are the default.
        for sp in ["{}", #"{"layout.width":1920,"layout.height":1080}"#] {
            let e = try editor(sp)
            XCTAssertEqual(box(e, "c1"), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080), sp)
            XCTAssertNotNil(e.naturalLayout(clipId: "c1"), sp)
        }
        // A size the user chose stays theirs.
        for sp in [#"{"layout.width":1000,"layout.height":1080}"#, #"{"layout.width":1920,"layout.height":1080,"layout.left":10}"#] {
            let e = try editor(sp)
            XCTAssertNil(e.naturalLayout(clipId: "c1"), sp)
            XCTAssertEqual(e.transform(clipId: "c1", time: 0).width, sp.contains("1000") ? 1000 : 1920, sp)
        }
        // Same aspect as the composition: the written size is kept (it may be deliberate and looks the same).
        let e2 = try TimelineEditor(json: Self.json(clips: clip.replacingOccurrences(of: "%@", with: #"{"layout.width":1920,"layout.height":1080}"#)))
        e2.naturalSize = { _ in .init(width: 3840, height: 2160) }
        XCTAssertNil(e2.naturalLayout(clipId: "c1"))
        // A clip with a crop and no size keeps the full-canvas box its insets were measured on.
        let cropped = clip.replacingOccurrences(of: #""staticParameters":%@,"#, with: #""staticParameters":{},"crop":{"top":0,"right":0,"bottom":0,"left":100},"#)
        let e3 = try TimelineEditor(json: Self.json(clips: cropped))
        e3.naturalSize = { _ in Self.square }
        XCTAssertNil(e3.naturalLayout(clipId: "c1"))
        XCTAssertEqual(box(e3, "c1"), NativeClipLayoutBox(left: 0, top: 0, width: 1920, height: 1080))
    }

    // MARK: edits and undo

    func testResizingAnUntouchedClipStartsFromItsBoxAndUndoes() throws {
        let e = try TimelineEditor(json: Self.json(assetExtra: #","width":1080,"height":1080"#))
        let id = try XCTUnwrap(e.insertClip(assetId: "sq", at: 0))
        let natural = e.document
        // A stage resize keeping the centre (540×540 at 690,270): position offsets the natural box origin.
        let base = StageGeometry.baseRect(editor: e, clipId: id, kind: .video, time: 0)
        XCTAssertEqual(base.x, 420); XCTAssertEqual(base.y, 0)
        let start = StageElement(id: id, name: "sq", rect: StageGeometry.rect(editor: e, clipId: id, kind: .video, time: 0), kind: .video)
        var end = start; end.rect = CanvasRect(x: 690, y: 270, width: 540, height: 540)
        XCTAssertTrue(e.applyTransform(clipId: id, time: 0, StageGeometry.transform(base: base, start: start, end: end)))
        XCTAssertEqual(StageGeometry.rect(editor: e, clipId: id, kind: .video, time: 0), end.rect)
        XCTAssertEqual(e.clip(id)?.clip.staticParameters?["layout.left"], .number(420), "the natural origin was written out with the size")
        XCTAssertNil(e.naturalLayout(clipId: id))
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document, natural, "one undo step back to the untouched clip")
        XCTAssertEqual(box(e, id), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080))
        // Size ↺ returns an edited clip to its natural box.
        XCTAssertTrue(e.applyTransform(clipId: id, time: 0, ClipTransform(width: 500)))
        XCTAssertEqual(box(e, id).width, 500)
        XCTAssertTrue(e.resetSize(clipId: id))
        XCTAssertEqual(box(e, id), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080))
        XCTAssertTrue(e.undo()); XCTAssertEqual(box(e, id).width, 500)
        // A move alone leaves the size natural.
        XCTAssertTrue(e.resetSize(clipId: id))
        XCTAssertTrue(e.applyTransform(clipId: id, time: 0, ClipTransform(x: 10, y: 5)))
        XCTAssertNotNil(e.naturalLayout(clipId: id))
        XCTAssertEqual(box(e, id), NativeClipLayoutBox(left: 430, top: 5, width: 1080, height: 1080))
    }

    func testCroppingAnUntouchedClipKeepsItsBox() throws {
        let e = try TimelineEditor(json: Self.json(assetExtra: #","width":1080,"height":1080"#))
        let id = try XCTUnwrap(e.insertClip(assetId: "sq", at: 0))
        XCTAssertTrue(e.setCrop(clipId: id, NativeClipCrop(top: 0, right: 0, bottom: 0, left: 100)))
        XCTAssertEqual(box(e, id), NativeClipLayoutBox(left: 420, top: 0, width: 1080, height: 1080))
        XCTAssertTrue(e.undo()); XCTAssertNotNil(e.naturalLayout(clipId: id))
    }

    func testMediaCornersScaleProportionallyWithoutShift() {
        let pv = PlayerView(playback: PlaybackState(duration: 10))
        pv.canvasSize = CanvasSize(1920, 1080)
        let pc = PlayerController(view: pv)
        pc.size = CanvasSize(1920, 1080)
        pv.elements = [StageElement(id: "m", name: "m", rect: CanvasRect(x: 420, y: 0, width: 1080, height: 1080), kind: .video)]
        pv.selectedIds = ["m"]
        let ve = pv.viewElement(pv.elements[0], in: pc.size).rect
        pc.pointerDown(x: ve.maxX, y: ve.maxY)
        pc.pointerMove(x: ve.maxX - 200, y: ve.maxY - 50)
        let r = pv.elements[0].rect
        XCTAssertEqual(r.width / r.height, 1, accuracy: 1e-9, "aspect kept")
        XCTAssertLessThan(r.width, 1080)
    }

    // MARK: selection box == rendered picture

    /// The stage selection rect and the rect the preview paints the picture into are the same media rect.
    func testSelectionBoxEqualsThePaintedPictureAt1xAnd2x() throws {
        let e = try TimelineEditor(json: Self.json())
        e.naturalSize = { a in ["sq": Self.square, "po": Self.portrait, "wi": Self.wide][a.id] }
        var ids: [String] = []
        for a in ["sq", "po", "wi"] { ids.append(try XCTUnwrap(e.insertClip(assetId: a, at: 0))) }
        let comp = PreviewComposition(document: e.document, projectDir: URL(fileURLWithPath: "/p"), engine: nil,
                                      naturalSize: e.naturalSize, fileExists: { _ in true })
        // Decoded pictures come at screen size, not natural size: same aspect, other pixels (and odd rounding).
        let decoded: [String: (Int, Int)] = ["sq": (540, 540), "po": (303, 540), "wi": (960, 270)]
        for scale in [1.0, 2.0] {
            let frame = CanvasRect(x: 17.25, y: 9.5, width: 1920 * scale, height: 1080 * scale)
            for layer in comp.layers(at: 0) {
                let assetId = e.clip(layer.clipId)!.clip.assetId
                let stage = StageGeometry.rect(editor: e, clipId: layer.clipId, kind: assetId == "po" ? .image : .video, time: 0)
                XCTAssertEqual(stage, layer.box, "stage rect is the preview box (\(assetId))")
                let (w, h) = decoded[assetId]!
                let c = PreviewRecordingCanvas()
                PreviewPainter.draw(layer, image: PreviewCompositorTests.solid(255, 255, 255, w: w, h: h), on: c, frame: frame, scale: scale)
                let painted = try XCTUnwrap(c.images.first).rect
                let selection = PreviewPainter.toView(stage, frame: frame, scale: scale)
                for (a, b, edge) in [(painted.x, selection.x, "left"), (painted.y, selection.y, "top"),
                                     (painted.maxX, selection.maxX, "right"), (painted.maxY, selection.maxY, "bottom")] {
                    XCTAssertEqual(a, b, accuracy: 0.5, "\(assetId) \(edge) at \(scale)x")
                }
            }
        }
    }

    #if os(Linux)
    /// Real pixels: the white picture's painted edges (from pixel coverage) sit on the selection box's edges.
    func testSelectionBoxEdgesMatchRenderedPixelsAt1xAnd2x() throws {
        // 384×216 project (16:9); media 432² (fit 216² at 84,0), 216×384 (fit 122×216 at 131,0; 121.5 rounds up),
        // 768×216 (fit 384×108 at 0,54).
        let e = try TimelineEditor(json: Self.json(canvas: (384, 216)))
        let naturals = ["sq": NativeMediaNaturalSize(width: 432, height: 432), "po": .init(width: 216, height: 384), "wi": .init(width: 768, height: 216)]
        e.naturalSize = { naturals[$0.id] }
        let decoded: [String: (Int, Int)] = ["sq": (216, 216), "po": (121, 216), "wi": (384, 108)]
        for asset in ["sq", "po", "wi"] {
            let id = try XCTUnwrap(e.insertClip(assetId: asset, at: 100))
            let comp = PreviewComposition(document: e.document, projectDir: URL(fileURLWithPath: "/p"), engine: nil,
                                          naturalSize: e.naturalSize, fileExists: { _ in true })
            let layer = try XCTUnwrap(comp.layers(at: 100.01).first { $0.clipId == id })
            let stage = StageGeometry.rect(editor: e, clipId: id, kind: asset == "po" ? .image : .video, time: 100.01)
            for scale in [1.0, 2.0] {
                let frame = CanvasRect(x: 3.25, y: 2.75, width: 384 * scale, height: 216 * scale)
                let t = CairoImageTarget(width: Int(390 * scale) + 8, height: Int(222 * scale) + 8)
                t.canvas.fill(.rect(CanvasRect(x: 0, y: 0, width: Double(t.width), height: Double(t.height))), CanvasColor(r: 0, g: 0, b: 0))
                let (w, h) = decoded[asset]!
                PreviewPainter.draw(layer, image: PreviewCompositorTests.solid(255, 255, 255, w: w, h: h), on: t.canvas, frame: frame, scale: scale)
                let sel = PreviewPainter.toView(stage, frame: frame, scale: scale)
                func cov(_ x: Int, _ y: Int) -> Double { Double(t.pixel(x, y).r) / 255 }
                // Edges from coverage along the middle row and column.
                let row = Int(sel.y + sel.height / 2), col = Int(sel.x + sel.width / 2)
                let xs = (0..<t.width).filter { cov($0, row) > 0.004 }, ys = (0..<t.height).filter { cov(col, $0) > 0.004 }
                let left = Double(xs.first!) + 1 - cov(xs.first!, row), right = Double(xs.last!) + cov(xs.last!, row)
                let top = Double(ys.first!) + 1 - cov(col, ys.first!), bottom = Double(ys.last!) + cov(col, ys.last!)
                XCTAssertEqual(left, sel.x, accuracy: 0.5, "\(asset) left at \(scale)x")
                XCTAssertEqual(right, sel.maxX, accuracy: 0.5, "\(asset) right at \(scale)x")
                XCTAssertEqual(top, sel.y, accuracy: 0.5, "\(asset) top at \(scale)x")
                XCTAssertEqual(bottom, sel.maxY, accuracy: 0.5, "\(asset) bottom at \(scale)x")
            }
        }
    }
    #endif
}
