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
import OneTakeKeyframes

/// Records drawing calls; images are identified by their first pixel's red channel.
final class PreviewRecordingCanvas: CanvasContext {
    enum Op: Equatable {
        case save, restore, translate(Double, Double), scale(Double, Double), rotate(Double), clip(CanvasPath)
        case fill(CanvasRect?), image(tag: UInt8, rect: CanvasRect, opacity: Double)
    }
    var ops: [Op] = []
    func save() { ops.append(.save) }
    func restore() { ops.append(.restore) }
    func translate(_ dx: Double, _ dy: Double) { ops.append(.translate(dx, dy)) }
    func scale(_ sx: Double, _ sy: Double) { ops.append(.scale(sx, sy)) }
    func rotate(_ radians: Double) { ops.append(.rotate(radians)) }
    func clip(_ path: CanvasPath) { ops.append(.clip(path)) }
    func fill(_ path: CanvasPath, _ color: CanvasColor) { ops.append(.fill(nil)) }
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * 6, font.size) }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect) { drawImage(image, in: rect, opacity: 1) }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect, opacity: Double) {
        ops.append(.image(tag: image.rgba[0], rect: rect, opacity: opacity))
    }
    var images: [(tag: UInt8, rect: CanvasRect, opacity: Double)] {
        ops.compactMap { if case let .image(t, r, o) = $0 { return (t, r, o) }; return nil }
    }
}

final class PreviewCompositorTests: XCTestCase {
    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255, w: Int = 4, h: Int = 4) -> CanvasImage {
        CanvasImage(width: w, height: h, rgba: Array((0..<(w * h)).map { _ in [r, g, b, a] }.joined()))
    }

    /// Two video tracks (authored lanes 1 and 2) plus an image on lane 3; canvas 200×100 at 10 fps.
    static func document(extra: String = "", clipB: String = "", bTracks: String = "", engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
        let json = """
        {"schemaVersion":1,"id":"project:t","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":200,"height":100,"background":"#102030"},
         "assets":[{"id":"a","kind":"video","name":"a.mp4","source":"a.mp4","durationFrames":100},
                   {"id":"b","kind":"video","name":"b.mp4","source":"b.mp4","durationFrames":100},
                   {"id":"i","kind":"image","name":"i.jpg","source":"i.jpg","durationFrames":100},
                   {"id":"gone","kind":"video","name":"gone.mp4","source":"gone.mp4","durationFrames":100},
                   {"id":"m","kind":"audio","name":"m.wav","source":"m.wav","durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"t3","kind":"video","lane":{"authoredTrack":3,"displayTrack":0},"clips":[
           {"id":"img","assetId":"i","startFrame":5,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
          {"id":"t2","kind":"video","lane":{"authoredTrack":2,"displayTrack":1},"clips":[
           {"id":"B","assetId":"b","startFrame":0,"durationFrames":20,"sourceInFrame":4,"muted":false,"effects":[],"parameterTracks":[\(bTracks)]\(clipB)}]},
          {"id":"t1","kind":"video","lane":{"authoredTrack":1,"displayTrack":2},"clips":[
           {"id":"A","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"G","assetId":"gone","startFrame":30,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}\(extra)]},
          {"id":"ta","kind":"audio","lane":{"authoredTrack":4,"displayTrack":3},"clips":[
           {"id":"M","assetId":"m","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json), engine: engine)
    }

    static func composition(_ doc: NativeProjectDocument, engine: KeyframeEngine? = nil) -> PreviewComposition {
        PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: engine,
                           fileExists: { !$0.hasSuffix("gone.mp4") })
    }

    // MARK: Composition

    func testLayersAreActiveVisualClipsInTrackOrder() throws {
        let comp = Self.composition(try Self.document())
        XCTAssertEqual(comp.entries.map(\.clip.id), ["A", "G", "B", "img"], "audio is not a layer; lane 1 at the bottom")
        XCTAssertEqual(comp.entries.map(\.kind), [.video, .offline, .video, .image], "missing media is an offline layer (#102)")
        XCTAssertEqual(comp.layers(at: 0).map(\.clipId), ["A", "B"])
        XCTAssertEqual(comp.layers(at: 0.5).map(\.clipId), ["A", "B", "img"])
        XCTAssertEqual(comp.layers(at: 1.45).map(\.clipId), ["A", "B", "img"], "frame 14 is the image's last frame")
        XCTAssertEqual(comp.layers(at: 1.5).map(\.clipId), ["A", "B"])
        XCTAssertEqual(comp.layers(at: 2.0).map(\.clipId), ["A"])
        XCTAssertEqual(comp.layers(at: 3.2).map(\.clipId), ["G"], "missing media is drawn as an offline slate (#102)")
        let b = try XCTUnwrap(comp.layers(at: 0).last)
        XCTAssertEqual(b.source, "/proj/b.mp4"); XCTAssertEqual(b.sourceIn, 0.4, accuracy: 1e-9)
        XCTAssertEqual(b.box, CanvasRect(x: 0, y: 0, width: 200, height: 100), "default box is the whole canvas")
        XCTAssertEqual(comp.upcoming(after: 0.2, within: 0.5).map(\.clipId), ["img"])
    }

    func testHiddenTracksAreLeftOut() throws {
        var doc = try Self.document()
        doc.sequence.tracks[1].hidden = true   // t2 (clip B)
        XCTAssertEqual(Self.composition(doc).layers(at: 0.5).map(\.clipId), ["A", "img"])
    }

    func testHiddenClipsAreLeftOut() throws {
        var doc = try Self.document()
        doc.sequence.tracks[2].clips[0].hidden = true   // t1 clip A
        XCTAssertEqual(Self.composition(doc).layers(at: 0.5).map(\.clipId), ["B", "img"])
        XCTAssertEqual(Self.composition(doc).entries.map(\.clip.id), ["G", "B", "img"], "G (gone.mp4) stays as an offline entry")
    }

    func testZIndexOverridesTrackOrder() throws {
        let doc = try Self.document(clipB: #","staticParameters":{"layout.zIndex":0}"#)
        XCTAssertEqual(Self.composition(doc).layers(at: 0).map(\.clipId), ["B", "A"])
    }

    func testStaticTransformOpacityAndCrop() throws {
        let doc = try Self.document(clipB: #","staticParameters":{"transform.position":{"x":10,"y":-5},"layout.width":80,"layout.height":40,"transform.scale":0.5,"transform.rotation":30,"visual.opacity":0.25},"crop":{"top":2,"right":4,"bottom":6,"left":8}"#)
        let b = try XCTUnwrap(Self.composition(doc).layers(at: 0).last)
        XCTAssertEqual(b.box, CanvasRect(x: 10, y: -5, width: 80, height: 40))
        XCTAssertEqual(b.scaleX, 0.5); XCTAssertEqual(b.scaleY, 0.5)
        XCTAssertEqual(b.rotation, 30); XCTAssertEqual(b.opacity, 0.25)
        XCTAssertEqual(b.crop, CropInsets(top: 2, right: 4, bottom: 6, left: 8))
        XCTAssertEqual(b.visibleBox, CanvasRect(x: 18, y: -3, width: 68, height: 32))
    }

    func testKeyframedOpacityAndPositionUseTheEngine() throws {
        let track = { (id: String, param: String, type: String, a: String, b: String) in
            #"{"schemaVersion":1,"id":"\#(id)","parameterId":"\#(param)","valueType":"\#(type)","frameRate":{"numerator":10,"denominator":1},"keyframes":[{"id":"\#(id)0","frame":0,"value":\#(a),"outgoing":{"type":"linear"}},{"id":"\#(id)1","frame":10,"value":\#(b),"outgoing":{"type":"linear"}}]}"#
        }
        let tracks = [track("o", "transform.opacity", "number", "0", "1"),
                      track("p", "transform.position", "vec2", #"{"x":0,"y":0}"#, #"{"x":100,"y":50}"#)].joined(separator: ",")
        let engine = try KeyframeRuntime()
        let withTracks = try Self.document(clipB: #","staticParameters":{"transform.opacity":0.9}"#, bTracks: tracks, engine: engine)
        let comp = Self.composition(withTracks, engine: engine)
        let at5 = try XCTUnwrap(comp.layers(at: 0.5).first { $0.clipId == "B" })
        XCTAssertEqual(at5.opacity, 0.5, accuracy: 1e-6, "track wins over the static value")
        XCTAssertEqual(at5.box.x, 50, accuracy: 1e-6); XCTAssertEqual(at5.box.y, 25, accuracy: 1e-6)
        let at0 = try XCTUnwrap(comp.layers(at: 0).first { $0.clipId == "B" })
        XCTAssertEqual(at0.opacity, 0, accuracy: 1e-9)
        XCTAssertFalse(at0.isVisible, "fully transparent layers are skipped")
        let late = try XCTUnwrap(comp.layers(at: 1.9).first { $0.clipId == "B" })
        XCTAssertEqual(late.opacity, 1, accuracy: 1e-9, "holds the last key past the end")
    }

    // MARK: Painter

    func testContainFit() {
        XCTAssertEqual(PreviewPainter.containRect(imageWidth: 160, imageHeight: 90, in: CanvasRect(x: 0, y: 0, width: 100, height: 100)),
                       CanvasRect(x: 0, y: 21.875, width: 100, height: 56.25))
        XCTAssertEqual(PreviewPainter.containRect(imageWidth: 10, imageHeight: 10, in: CanvasRect(x: 10, y: 0, width: 40, height: 20)),
                       CanvasRect(x: 20, y: 0, width: 20, height: 20))
    }

    func testPainterScalesThenRotatesAboutTheBoxCentreAndClipsTheCrop() {
        let layer = PreviewLayer(clipId: "x", source: "/x", kind: .video, start: 0, end: 1, sourceIn: 0,
                                 box: CanvasRect(x: 20, y: 10, width: 100, height: 50), scaleX: 2, scaleY: -1, rotation: 90,
                                 opacity: 0.5, crop: CropInsets(top: 0, right: 0, bottom: 0, left: 10))
        let c = PreviewRecordingCanvas()
        // View frame at (5, 5), half scale.
        PreviewPainter.draw(layer, image: Self.solid(7, 0, 0, w: 2, h: 1), on: c, frame: CanvasRect(x: 5, y: 5, width: 100, height: 50), scale: 0.5)
        XCTAssertEqual(c.ops, [.save, .translate(40, 22.5), .rotate(90 * .pi / 180), .scale(2, -1), .translate(-40, -22.5),
                               .clip(.rect(CanvasRect(x: 20, y: 10, width: 45, height: 25))),
                               .image(tag: 7, rect: CanvasRect(x: 15, y: 10, width: 50, height: 25), opacity: 0.5), .restore])
    }

    func testCompositorDrawsBottomFirstAndHoldsTheLastFrameWhileDecoding() throws {
        let comp = Self.composition(try Self.document())
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = comp
        let layers = comp.layers(at: 0.5)
        let a = layers[0], b = layers[1], img = layers[2]
        cx.cache.store(Self.solid(1, 0, 0, w: 8, h: 4), lane: a.laneKey, frame: 5)
        cx.cache.store(Self.solid(2, 0, 0), lane: b.laneKey, frame: 3)        // only an older frame of B
        cx.cache.store(Self.solid(3, 0, 0), lane: img.laneKey, frame: PreviewDecodeLane.stillFrame)
        let c = PreviewRecordingCanvas()
        cx.draw(c, in: CanvasRect(x: 0, y: 0, width: 400, height: 200), time: 0.5, elements: [], context: FrameDrawContext())
        XCTAssertEqual(c.images.map(\.tag), [1, 2, 3], "bottom lane first, image on top")
        XCTAssertEqual(cx.lastShown, [.init(clipId: "A", frame: 5, exact: true), .init(clipId: "B", frame: 3, exact: false),
                                      .init(clipId: "img", frame: 0, exact: true)])
        XCTAssertEqual(c.images[0].rect, CanvasRect(x: 0, y: 0, width: 400, height: 200), "fills the 2× view")
        XCTAssertTrue(cx.lanes.isEmpty, "no decoders when media decoding is off")
    }

    func testCompareWipesCachedRawLeftAndGradedRightWithoutDecoder() {
        let cx = PreviewCompositor(decodesMedia: false)
        let layer = PreviewLayer(clipId: "selected", source: "/x", kind: .video, start: 0, end: 1, sourceIn: 0,
                                 box: CanvasRect(x: 0, y: 0, width: 100, height: 100))
        let c = PreviewRecordingCanvas()
        cx.draw(layer, raw: Self.solid(1, 0, 0), shown: Self.solid(2, 0, 0), on: c,
                frame: CanvasRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
                context: FrameDrawContext(compareClipId: "selected", comparePosition: 0.25))
        XCTAssertEqual(c.images.map(\.tag), [1, 2])
        XCTAssertTrue(c.ops.contains(.clip(.rect(CanvasRect(x: 0, y: 0, width: 25, height: 100)))))
        XCTAssertTrue(c.ops.contains(.clip(.rect(CanvasRect(x: 25, y: 0, width: 75, height: 100)))))
        XCTAssertTrue(cx.lanes.isEmpty, "compare reuses pictures and never starts a decoder")
    }

    func testCompareDoesNotPairCurrentRawWithAStaleGradedFrame() {
        let cx = PreviewCompositor(decodesMedia: false)
        let layer = PreviewLayer(clipId: "selected", source: "/x", kind: .video, start: 0, end: 1, sourceIn: 0,
                                 box: CanvasRect(x: 0, y: 0, width: 100, height: 100))
        let c = PreviewRecordingCanvas()
        cx.draw(layer, raw: Self.solid(7, 0, 0), shown: Self.solid(6, 0, 0), shownIsCurrent: false, on: c,
                frame: CanvasRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
                context: FrameDrawContext(compareClipId: "selected"))
        XCTAssertEqual(c.images.map(\.tag), [7, 7], "both sides use the same source frame while its grade is pending")
    }
    func testLiveStageEditOverridesBoxRotationAndCrop() throws {
        let comp = Self.composition(try Self.document())
        let frame = CanvasRect(x: 10, y: 10, width: 100, height: 50)   // scale 0.5
        let el = StageElement(id: "B", name: "B", rect: CanvasRect(x: 20, y: 15, width: 50, height: 25), kind: .video,
                              rotation: 15, crop: CropInsets(top: 1, right: 0, bottom: 0, left: 2))
        let out = PreviewCompositor.applyStage([el], to: comp.layers(at: 0), frame: frame, scale: 0.5)
        XCTAssertEqual(out[0], comp.layers(at: 0)[0], "other layers untouched")
        XCTAssertEqual(out[1].box, CanvasRect(x: 20, y: 10, width: 100, height: 50))
        XCTAssertEqual(out[1].rotation, 15); XCTAssertEqual(out[1].crop, CropInsets(top: 2, right: 0, bottom: 0, left: 4))
    }

    func testOnlyLiveStageElementsOverrideTheDocument() throws {
        // A stale stage element (e.g. before the stage re-syncs after an inspector edit) must not mask the document.
        var doc = try Self.document(clipB: #","staticParameters":{"transform.rotation":30,"visual.opacity":0.5}"#)
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = Self.composition(doc)
        cx.cache.store(Self.solid(9, 0, 0), lane: try XCTUnwrap(cx.composition?.layers(at: 0).last).laneKey, frame: 0)
        let stale = StageElement(id: "B", name: "B", rect: CanvasRect(x: 0, y: 0, width: 400, height: 200), kind: .video, rotation: 0)
        let c = PreviewRecordingCanvas()
        cx.draw(c, in: CanvasRect(x: 0, y: 0, width: 400, height: 200), time: 0, elements: [stale], context: FrameDrawContext(liveElementIds: []))
        XCTAssertTrue(c.ops.contains(.rotate(30 * .pi / 180)), "document rotation drawn, the stale stage rotation ignored")
        XCTAssertEqual(c.images.first { $0.tag == 9 }?.opacity, 0.5)
        // The inspector writes a new opacity: the next draw reads it (no frame cache keyed by time alone).
        doc.sequence.tracks[1].clips[0].staticParameters?["visual.opacity"] = .number(0.2)
        cx.composition = Self.composition(doc)
        let c2 = PreviewRecordingCanvas()
        cx.draw(c2, in: CanvasRect(x: 0, y: 0, width: 400, height: 200), time: 0, elements: [stale], context: FrameDrawContext(liveElementIds: []))
        XCTAssertEqual(c2.images.first { $0.tag == 9 }?.opacity, 0.2)
        // While B is being dragged, its live element wins.
        let c3 = PreviewRecordingCanvas()
        cx.draw(c3, in: CanvasRect(x: 0, y: 0, width: 400, height: 200), time: 0, elements: [stale], context: FrameDrawContext(liveElementIds: ["B"]))
        XCTAssertFalse(c3.ops.contains(.rotate(30 * .pi / 180)))
    }

    #if os(Linux)
    func testCairoReportsDeviceScale() {
        let t = CairoImageTarget(width: 4, height: 4)
        XCTAssertEqual(t.canvas.deviceScale, 1)
        t.canvas.scale(2, 2); XCTAssertEqual(t.canvas.deviceScale, 2, accuracy: 1e-9)
    }
    #endif

    func testOpacityDefaultBakesAlpha() {
        let img = Self.solid(10, 20, 30, 200, w: 1, h: 1).withOpacity(0.5)
        XCTAssertEqual(img.rgba, [10, 20, 30, 100])
    }

    // MARK: Cache and sizing

    func testFrameCacheEvictsLeastRecentlyUsedWithinBudget() {
        let cache = PreviewFrameCache(budgetBytes: 3 * 64)   // three 4×4 frames
        for f in 0..<3 { cache.store(Self.solid(UInt8(f), 0, 0), lane: "L", frame: f) }
        _ = cache.frame(lane: "L", frame: 0)                 // touch 0: frame 1 is now the oldest
        cache.store(Self.solid(9, 0, 0), lane: "L", frame: 3)
        XCTAssertEqual(cache.cachedFrames(lane: "L", from: 0, to: 9), [0, 2, 3])
        XCTAssertEqual(cache.bytes, 3 * 64)
        XCTAssertEqual(cache.nearest(lane: "L", to: 1)?.frame, 0, "latest frame at or before")
        XCTAssertEqual(cache.nearest(lane: "L", to: -5)?.frame, 0, "else the earliest after")
        XCTAssertNil(cache.nearest(lane: "other", to: 1))
        cache.trim(lane: "L", keeping: 2, 3)
        XCTAssertEqual(cache.cachedFrames(lane: "L", from: 0, to: 9), [2, 3]); XCTAssertEqual(cache.bytes, 2 * 64)
        cache.store(Self.solid(1, 1, 1, w: 2, h: 2), lane: "L", frame: 2)   // replacing keeps the byte count honest
        XCTAssertEqual(cache.bytes, 64 + 16)
    }

    /// Settings > Preview cache: lowering the budget evicts the least recently used frames at once.
    func testLoweringTheBudgetEvictsAtOnce() {
        let cache = PreviewFrameCache(budgetBytes: 4 * 64, pressure: nil)   // four 4×4 frames
        cache.store(Self.solid(0, 0, 0), lane: "L", frame: 0)
        cache.store(Self.solid(1, 0, 0), lane: "L", frame: 1)
        cache.store(Self.solid(2, 0, 0), lane: "L", frame: 2)
        cache.store(Self.solid(3, 0, 0), lane: "L", frame: 3)
        _ = cache.frame(lane: "L", frame: 0)   // touch 0: frames 1 and 2 are now the oldest
        cache.budgetBytes = 2 * 64
        XCTAssertEqual(cache.budgetBytes, 2 * 64)
        XCTAssertEqual(cache.cachedFrames(lane: "L", from: 0, to: 9), [0, 3])
        XCTAssertEqual(cache.bytes, 2 * 64)
        cache.budgetBytes = 0
        XCTAssertEqual(cache.budgetBytes, 1, "a budget never drops below one byte")
    }

    func testDecodeSizeFollowsScreenPixelsAndBackingScale() {
        let layer = PreviewLayer(clipId: "x", source: "/x", kind: .video, start: 0, end: 1, sourceIn: 0,
                                 box: CanvasRect(x: 0, y: 0, width: 1920, height: 1080), scaleX: 0.5, scaleY: 0.5)
        let px = PreviewPainter.screenPixels(layer, viewScale: 0.5, backingScale: 2)
        XCTAssertEqual(PreviewDecodeSize.fitting(px), PreviewDecodeSize(width: 960, height: 540))
        XCTAssertEqual(PreviewDecodeSize.fitting((7001, 3001), maxSide: 3840).width, 3840)
        XCTAssertEqual(PreviewDecodeSize.fitting((33.2, 17)), PreviewDecodeSize(width: 34, height: 18), "even sizes")
        let s = PreviewDecodeSize(width: 960, height: 540)
        XCTAssertTrue(s.serves(PreviewDecodeSize(width: 1000, height: 562)))
        XCTAssertFalse(s.serves(PreviewDecodeSize(width: 1920, height: 1080)), "much larger needs a sharper decode")
        XCTAssertFalse(s.serves(PreviewDecodeSize(width: 400, height: 226)), "much smaller wastes decode time")
        XCTAssertFalse(s.serves(PreviewDecodeSize(width: 960, height: 700)), "aspect change")
        XCTAssertEqual(PreviewDecodeSize(width: 400, height: 400).containing(aspect: 16.0 / 9), PreviewDecodeSize(width: 400, height: 224))
        XCTAssertEqual(PreviewDecodeSize(width: 400, height: 100).containing(aspect: 2), PreviewDecodeSize(width: 200, height: 100))
    }

    #if os(Linux)
    // MARK: Pixels (Cairo)

    func render(_ layers: [(PreviewLayer, CanvasImage)], w: Int = 100, h: Int = 50) -> CairoImageTarget {
        let t = CairoImageTarget(width: w, height: h)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)), CanvasColor(r: 0, g: 0, b: 0))
        for (l, img) in layers { PreviewPainter.draw(l, image: img, on: t.canvas, frame: CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)), scale: 0.5) }
        return t
    }
    func full(_ crop: CropInsets = .zero, scale: Double = 1, rotation: Double = 0, opacity: Double = 1, box: CanvasRect = CanvasRect(x: 0, y: 0, width: 200, height: 100)) -> PreviewLayer {
        PreviewLayer(clipId: "x", source: "/x", kind: .video, start: 0, end: 1, sourceIn: 0, box: box,
                     scaleX: scale, scaleY: scale, rotation: rotation, opacity: opacity, crop: crop)
    }
    func rgb(_ t: CairoImageTarget, _ x: Int, _ y: Int) -> [UInt8] { let p = t.pixel(x, y); return [p.r, p.g, p.b] }

    func testPixelsCropScaleRotateOpacityAndOrder() {
        let red = Self.solid(255, 0, 0, w: 20, h: 10), blue = Self.solid(0, 0, 255, w: 20, h: 10)
        var t = render([(full(CropInsets(left: 100)), red)])
        XCTAssertEqual(rgb(t, 10, 25), [0, 0, 0], "cropped half shows what is below"); XCTAssertEqual(rgb(t, 90, 25), [255, 0, 0])
        t = render([(full(scale: 0.5), red)])
        XCTAssertEqual(rgb(t, 50, 25), [255, 0, 0]); XCTAssertEqual(rgb(t, 5, 5), [0, 0, 0], "scaled about the centre")
        XCTAssertEqual(rgb(t, 30, 25), [255, 0, 0]); XCTAssertEqual(rgb(t, 20, 25), [0, 0, 0])
        // A 40×100 box rotated 90° lies across the middle: 100 wide, 40 tall (in canvas px), i.e. 50×20 view px.
        t = render([(full(rotation: 90, box: CanvasRect(x: 80, y: 0, width: 40, height: 100)), Self.solid(255, 0, 0, w: 4, h: 10))])
        XCTAssertEqual(rgb(t, 30, 25), [255, 0, 0]); XCTAssertEqual(rgb(t, 50, 5), [0, 0, 0])
        t = render([(full(opacity: 0.5), red)])
        XCTAssertEqual(Int(rgb(t, 50, 25)[0]), 128, accuracy: 2)
        t = render([(full(), red), (full(CropInsets(right: 100)), blue)])
        XCTAssertEqual(rgb(t, 10, 25), [0, 0, 255], "upper layer on top"); XCTAssertEqual(rgb(t, 90, 25), [255, 0, 0])
    }
    #endif
}
