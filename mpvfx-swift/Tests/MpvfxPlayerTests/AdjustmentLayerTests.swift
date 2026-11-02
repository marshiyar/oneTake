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

/// Adjustment layers (#326): an element clip with `adjustment: true` grades the composite of the tracks below it, in
/// the preview compositor and in the export painter, which share `PreviewPainter.applyAdjustment`.
final class AdjustmentLayerTests: XCTestCase {
    static let base: (UInt8, UInt8, UInt8) = (180, 120, 60)

    /// Two stills back to back on the lower track (frames 0..<10 and 10..<20 at 10 fps), and an adjustment over
    /// frames 5..<15 (half of each) on the track above, with `exposure` and `opacity`.
    static func composition(exposure: Double?, opacity: Double? = nil, adjustment: Bool = true, hiddenTrack: Bool = false) throws -> PreviewComposition {
        let grade = exposure.map { #""effects":[{"id":"g","effectId":"color-grading","enabled":true,"parameters":{"adjust":{"exposure":\#($0)}}}]"# }
            ?? #""effects":[]"#
        let statics = opacity.map { #","staticParameters":{"transform.opacity":\#($0)}"# } ?? ""
        let flag = adjustment ? #","adjustment":true"# : ""
        let hidden = hiddenTrack ? #","hidden":true"# : ""
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"project:adj","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":100,"height":50,"background":"#102030"},
         "assets":[{"id":"w","kind":"image","name":"w.png","source":"w.png","durationFrames":100,"width":16,"height":9},
                   {"id":"adj","kind":"element","name":"Adjustment","durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"t2","kind":"video","lane":{"authoredTrack":2,"displayTrack":0}\#(hidden),"clips":[
           {"id":"ADJ","assetId":"adj","startFrame":5,"durationFrames":10,"sourceInFrame":0,"muted":false,\#(grade),"parameterTracks":[]\#(flag)\#(statics)}]},
          {"id":"t1","kind":"video","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
           {"id":"A","assetId":"w","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"fit":"stretch"},
           {"id":"B","assetId":"w","startFrame":10,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],"fit":"stretch"}]}]}}
        """#), engine: nil)
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in true })
    }

    static func picture() -> CanvasImage { PreviewCompositorTests.solid(base.0, base.1, base.2, w: 16, h: 9) }

    func pixel(_ img: CanvasImage, _ x: Int = 50, _ y: Int = 25) -> [Int] {
        let i = (y * img.width + x) * 4
        return img.rgba[i..<i + 3].map(Int.init)
    }

    func exported(_ comp: PreviewComposition, frame: Int) throws -> CanvasImage {
        try ExportFramePainter(composition: comp, width: 100, height: 50, pad: .transparent)
            .paint(time: Double(frame) / 10) { _, _, _, _ in Self.picture() }
    }

    func previewed(_ comp: PreviewComposition, frame: Int) throws -> CanvasImage {
        let time = Double(frame) / 10
        let cx = PreviewCompositor(decodesMedia: false)
        cx.composition = comp
        for layer in comp.layers(at: time) where layer.kind != .adjustment {
            cx.cache.store(Self.picture(), lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame)
        }
        let canvas = try RasterCanvas(width: 100, height: 50)
        cx.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 100, height: 50), time: time, elements: [], context: FrameDrawContext())
        return canvas.image()
    }

    func close(_ a: [Int], _ b: [Int], within n: Int = 1, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        for k in 0..<3 { XCTAssertEqual(a[k], b[k], accuracy: n, "\(message) channel \(k): \(a) vs \(b)", file: file, line: line) }
    }

    /// What the same grade does to the picture when it sits on a clip of its own (the grade pipeline's reference).
    func gradedReference(exposure: Double) throws -> [Int] {
        let comp = try Self.composition(exposure: exposure)
        let grade = try XCTUnwrap(comp.layers(at: 0.7).first { $0.kind == .adjustment }?.grade)
        let image = PreviewGrader(pressure: nil).gradeNow(PreviewCompositorTests.solid(Self.base.0, Self.base.1, Self.base.2, w: 4, h: 4), grade: grade, time: 0)
        return pixel(image, 1, 1)
    }

    // A2: exposure -1 over two clips darkens both by what the grade does on a clip of its own (the pipeline defines a stop), only inside the adjustment's time range.
    func testA2ExposureMinusOneGradesBothClipsOnlyInsideItsRange() throws {
        let comp = try Self.composition(exposure: -1)
        let plain = [Int(Self.base.0), Int(Self.base.1), Int(Self.base.2)]
        let darker = try gradedReference(exposure: -1)
        XCTAssertLessThan(darker[0], plain[0] - 20, "one stop is a visible darkening")
        for (frame, adjusted) in [(2, false), (7, true), (12, true), (17, false)] {
            let want = adjusted ? darker : plain
            close(pixel(try exported(comp, frame: frame)), want, "export frame \(frame)")
            close(pixel(try previewed(comp, frame: frame)), want, "preview frame \(frame)")
        }
    }

    // A3: opacity 0.5 is the midpoint between adjusted and unadjusted.
    func testA3HalfOpacityIsTheMidpoint() throws {
        let comp = try Self.composition(exposure: -1, opacity: 0.5)
        let plain = [Int(Self.base.0), Int(Self.base.1), Int(Self.base.2)]
        let darker = try gradedReference(exposure: -1)
        let mid = (0..<3).map { (plain[$0] + darker[$0] + 1) / 2 }
        close(pixel(try exported(comp, frame: 7)), mid, "export")
        close(pixel(try previewed(comp, frame: 7)), mid, "preview")
        let none = try Self.composition(exposure: -1, opacity: 0)
        close(pixel(try exported(none, frame: 7)), plain, "opacity 0 changes nothing")
    }

    // A4: preview and export agree; no adjustment leaves every pixel as it was.
    func testA4PreviewAndExportAgree() throws {
        let comp = try Self.composition(exposure: -1)
        for frame in [2, 5, 7, 12, 14, 15, 17] {
            let e = try exported(comp, frame: frame), p = try previewed(comp, frame: frame)
            for (x, y) in [(0, 0), (50, 25), (99, 49), (10, 40)] { close(pixel(e, x, y), pixel(p, x, y), "frame \(frame) at \(x),\(y)") }
        }
    }

    func testA4WithoutAnAdjustmentNothingChanges() throws {
        let plainClip = try Self.composition(exposure: -1, adjustment: false)
        XCTAssertNil(plainClip.layers(at: 0.7).first { $0.kind == .adjustment })
        let ungraded = try Self.composition(exposure: nil)
        let reference = try exported(ungraded, frame: 7)
        XCTAssertEqual(pixel(reference), [Int(Self.base.0), Int(Self.base.1), Int(Self.base.2)], "an adjustment with no grade changes nothing")
        XCTAssertEqual(try exported(ungraded, frame: 2).rgba, try exported(ungraded, frame: 2).rgba)
    }

    func testAHiddenAdjustmentTrackHasNoEffect() throws {
        let comp = try Self.composition(exposure: -1, hiddenTrack: true)
        XCTAssertNil(comp.layers(at: 0.7).first { $0.kind == .adjustment })
        close(pixel(try exported(comp, frame: 7)), [Int(Self.base.0), Int(Self.base.1), Int(Self.base.2)])
    }
}
