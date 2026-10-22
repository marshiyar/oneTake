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

/// Canvas fill: the colour, gradient, image or blurred copy behind a picture that does not cover the frame.
final class CanvasFillTests: XCTestCase {
    /// A 90 x 160 (9:16) project at 10 fps with one clip `A` whose 16:9 picture is contained, leaving bars above and below.
    func document(project: String? = nil, clip: String? = nil, extraAssets: String = "") throws -> NativeProjectDocument {
        let json = """
        {"schemaVersion":1,"id":"project:f","revision":1,"frameRate":{"numerator":10,"denominator":1},
         \(project.map { "\"compositionFill\":\($0)," } ?? "")
         "canvas":{"width":90,"height":160,"background":"#102030"},
         "assets":[{"id":"a","kind":"video","name":"a.mp4","source":"a.mp4","durationFrames":100},
                   {"id":"photo","kind":"image","name":"photo.png","source":"photo.png","durationFrames":1}\(extraAssets)],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]\(clip.map { ",\"fill\":\($0)" } ?? "")}]}]}}
        """
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json), engine: nil)
    }

    func composition(_ doc: NativeProjectDocument, missing: String? = nil) -> PreviewComposition {
        PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil,
                           naturalSize: { $0.id == "a" ? NativeMediaNaturalSize(width: 160, height: 90) : NativeMediaNaturalSize(width: 40, height: 40) },
                           fileExists: { missing.map($0.hasSuffix) != true })
    }

    func picture(_ rgba: (UInt8, UInt8, UInt8), w: Int = 160, h: Int = 90) -> CanvasImage {
        CanvasImage(width: w, height: h, rgba: Array((0..<(w * h)).map { _ in [rgba.0, rgba.1, rgba.2, 255] }.joined()))
    }

    func paint(_ comp: PreviewComposition, time: Double = 0, frames: @escaping (PreviewLayer) -> CanvasImage?) throws -> CanvasImage {
        let p = try ExportFramePainter(composition: comp, width: 90, height: 160, pad: .opaqueBlack)
        return try p.paint(time: time) { layer, _, _, _ in frames(layer) }
    }

    func px(_ i: CanvasImage, _ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(i.rgba[(y * i.width + x) * 4 + $0]) } }

    func close(_ a: [Int], _ b: [Int], _ tol: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(zip(a, b).allSatisfy { abs($0 - $1) <= tol }, "\(a) vs \(b)", file: file, line: line)
    }

    func testAColourFillShowsAboveAndBelowTheClipAndNotUnderIt() throws {
        let doc = try document(project: ##"{"v":1,"kind":"color","color":"#ff0000"}"##)
        let img = try paint(composition(doc)) { _ in self.picture((255, 255, 255)) }
        close(px(img, 45, 5), [255, 0, 0, 255], 0)
        close(px(img, 45, 154), [255, 0, 0, 255], 0)
        close(px(img, 45, 80), [255, 255, 255, 255], 0)
    }

    func testAClipWithoutAFillAndAClipOverrideRenderAsTheyShould() throws {
        let plain = try paint(composition(try document())) { _ in self.picture((255, 255, 255)) }
        close(px(plain, 45, 5), [0x10, 0x20, 0x30, 255], 0)   // the canvas background shows in the bars
        let none = try paint(composition(try document(project: ##"{"v":1,"kind":"color","color":"#ff0000"}"##,
                                                      clip: ##"{"v":1,"kind":"none"}"##))) { _ in self.picture((255, 255, 255)) }
        XCTAssertEqual(none, plain, "the clip's None beats the project's fill")
        let own = try paint(composition(try document(project: ##"{"v":1,"kind":"color","color":"#ff0000"}"##,
                                                     clip: ##"{"v":1,"kind":"color","color":"#00ff00"}"##))) { _ in self.picture((255, 255, 255)) }
        close(px(own, 45, 5), [0, 255, 0, 255], 0)
        let inherit = try paint(composition(try document(project: ##"{"v":1,"kind":"color","color":"#ff0000"}"##,
                                                         clip: ##"{"v":1,"kind":"inherit"}"##))) { _ in self.picture((255, 255, 255)) }
        close(px(inherit, 45, 5), [255, 0, 0, 255], 0)
    }

    func testAGradientRunsAlongItsAngleThroughItsStops() throws {
        let g = ##"{"v":1,"kind":"gradient","gradient":{"angle":180,"stops":[{"offset":0,"color":"#ff0000"},{"offset":1,"color":"#0000ff"}]}}"##
        let img = try paint(composition(try document(project: g))) { _ in self.picture((255, 255, 255)) }
        close(px(img, 45, 0), [255, 0, 0, 255], 4)
        close(px(img, 45, 159), [0, 0, 255, 255], 4)
        // y = 10 is 10.5 / 160 of the way down
        let t = 10.5 / 160
        close(px(img, 45, 10), [Int((255 * (1 - t)).rounded()), 0, Int((255 * t).rounded()), 255], 2)
        close(px(img, 10, 10), px(img, 80, 10), 1)   // a vertical gradient is constant along a row
    }

    func testABlurredCopyHasTheClipsMeanTimesOneMinusDarkenAndCostsNoExtraLayer() throws {
        // A picture whose top half is 200 and bottom half 100 has mean 150 (cover only crops the sides).
        var rgba = [UInt8]()
        for y in 0..<90 { for _ in 0..<160 { let v: UInt8 = y < 45 ? 200 : 100; rgba += [v, v, v, 255] } }
        let source = CanvasImage(width: 160, height: 90, rgba: rgba)
        let blurred = try XCTUnwrap(CanvasFillPainter.blurredCopy(source, width: 45, height: 80, sigma: 3, darken: 0.4))
        var sum = 0
        for i in stride(from: 0, to: blurred.rgba.count, by: 4) { sum += Int(blurred.rgba[i]) }
        XCTAssertEqual(Double(sum) / Double(45 * 80), 150 * 0.6, accuracy: 2)
        let doc = try document(project: ##"{"v":1,"kind":"blur"}"##)
        XCTAssertEqual(composition(doc).layers(at: 0).map(\.clipId), ["A"], "the blurred copy is drawn from the clip's own frame")
        let img = try paint(composition(doc)) { _ in source }
        XCTAssertGreaterThan(px(img, 45, 5)[0], 40, "the bar shows the darkened copy, not black")
        XCTAssertLessThan(px(img, 45, 5)[0], 200)
        close(px(img, 45, 65), [200, 200, 200, 255], 0)   // the picture itself (its top half)
    }

    func testTheFillDoesNotShowThroughTransparentPixelsOfTheClip() throws {
        let doc = try document(project: ##"{"v":1,"kind":"color","color":"#ff0000"}"##)
        var rgba = [UInt8]()
        for y in 0..<90 { for x in 0..<160 { let hole = (60..<100).contains(x) && (30..<60).contains(y); rgba += hole ? [0, 0, 0, 0] : [255, 255, 255, 255] } }
        let img = try paint(composition(doc)) { _ in CanvasImage(width: 160, height: 90, rgba: rgba) }
        close(px(img, 45, 80), [0x10, 0x20, 0x30, 255], 0)   // transparent middle: background, not the fill
        close(px(img, 45, 5), [255, 0, 0, 255], 0)
    }

    func testAnImageFillIsALayerOfItsOwnBehindTheClip() throws {
        let doc = try document(project: ##"{"v":1,"kind":"image","assetId":"photo"}"##)
        let comp = composition(doc)
        let layers = comp.layers(at: 0)
        XCTAssertEqual(layers.map(\.clipId), ["A#fill", "A"])
        XCTAssertEqual(layers[0].kind, .image); XCTAssertEqual(layers[0].source, "/proj/photo.png")
        let img = try paint(comp) { $0.clipId == "A#fill" ? self.picture((0, 0, 255), w: 40, h: 40) : self.picture((255, 255, 255)) }
        close(px(img, 45, 5), [0, 0, 255, 255], 0)
        close(px(img, 45, 80), [255, 255, 255, 255], 0)
        let missing = composition(doc, missing: "photo.png")
        XCTAssertEqual(missing.layers(at: 0).map(\.clipId), ["A"], "a missing image draws nothing")
        XCTAssertTrue(missing.offlineAssetIds.contains("photo"), "and is offline media")
        XCTAssertTrue(PreviewComposition.offlineAssetIds(document: doc, projectDir: URL(fileURLWithPath: "/proj"),
                                                         fileExists: { !$0.hasSuffix("photo.png") }).contains("photo"))
    }

    func testAFillFromANewerVersionIsNotDrawn() throws {
        let doc = try document(project: ##"{"v":2,"kind":"color","color":"#ff0000"}"##)
        let img = try paint(composition(doc)) { _ in self.picture((255, 255, 255)) }
        close(px(img, 45, 5), [0x10, 0x20, 0x30, 255], 0)
    }

    func testAFillIsNotDrawnWhenThePictureCoversTheFrame() throws {
        var doc = try document(project: ##"{"v":1,"kind":"color","color":"#ff0000"}"##)
        doc.sequence.tracks[0].clips[0].fit = .fill   // cover: the picture reaches every edge
        let img = try paint(composition(doc)) { _ in self.picture((10, 20, 30)) }
        close(px(img, 0, 0), [10, 20, 30, 255], 0)
    }

    #if os(Linux)
    func testPreviewAndExportCanvasesAgreeWithinOneLevelAtThreeTimes() throws {
        let fills = [##"{"v":1,"kind":"color","color":"#336699"}"##,
                     ##"{"v":1,"kind":"gradient","gradient":{"angle":135,"stops":[{"offset":0,"color":"#ff8800"},{"offset":1,"color":"#0044aa"}]}}"##,
                     ##"{"v":1,"kind":"blur"}"##]
        for fill in fills {
            let comp = composition(try document(project: fill))
            for (n, time) in [0.0, 0.5, 1.0].enumerated() {
                let shade = UInt8(60 + 60 * n)
                let frame = picture((shade, 200 - shade, shade / 2))
                let exported = try paint(comp, time: time) { _ in frame }
                let target = CairoImageTarget(width: 90, height: 160)
                let p = try ExportFramePainter(composition: comp, width: 90, height: 160, pad: .opaqueBlack)
                target.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 90, height: 160), .opaqueBlack)
                target.canvas.fillRect(p.frame.rect, comp.background)
                for (layer, _, _) in p.layers(at: time) { PreviewPainter.draw(layer, image: frame, on: target.canvas, frame: p.frame.rect, scale: p.frame.scale) }
                let previewed = target.straightRGBA()
                var worst = 0
                for i in 0..<previewed.count { worst = max(worst, abs(Int(previewed[i]) - Int(exported.rgba[i]))) }
                XCTAssertLessThanOrEqual(worst, 1, "\(fill) at \(time)")
            }
        }
    }
    #endif
}
