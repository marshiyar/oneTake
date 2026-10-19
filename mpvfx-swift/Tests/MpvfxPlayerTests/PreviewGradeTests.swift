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
import MpvfxPanels

/// End to end: each grade control and stylize effect is edited through the editor command the inspector rows call
/// (`TimelineEditor.setColorGrading`), the preview composition is rebuilt from the edited document, a preview frame
/// is decoded through the compositor, and its pixels must move the way the control says.
final class PreviewGradeTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var dir: URL!
    var editor: TimelineEditor!
    var baseline: CanvasImage!
    let size = PreviewDecodeSize(width: 96, height: 54)

    override func setUpWithError() throws {
        dir = try TestMedia.scratch("grade")
        // Colour bars and a grey ramp (lossless, so the ungraded frame is exact).
        _ = try TestMedia.PatternVideo(width: 96, height: 54).write(to: dir.appendingPathComponent("media.mov").path)
        editor = try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"project:g","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":96,"height":54,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"media.mov","source":"media.mov","durationFrames":30}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#)
        baseline = try frame()
    }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// A preview frame of the current document at `time`, through a fresh composition and the compositor's decoder.
    func frame(time: Double = 0.5) throws -> CanvasImage {
        let comp = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
        XCTAssertEqual(comp.entries.count, 1)
        let cx = PreviewCompositor()
        cx.composition = comp
        let layer = try XCTUnwrap(comp.layers(at: time).first)
        defer { cx.stopAll() }
        return try XCTUnwrap(cx.decodeNow(layer, time: time, fps: 30, size: size))
    }

    /// Edits the grade through the editor command, then returns the new preview frame.
    func edited(_ change: (inout ColorGrading) -> Void, time: Double = 0.5) throws -> CanvasImage {
        var g = editor.colorGrading(clipId: "clip:a") ?? ColorGrading()
        change(&g)
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g), "the edit reaches the document")
        return try frame(time: time)
    }

    // MARK: Pixel statistics

    struct Stats { var r = 0.0, g = 0.0, b = 0.0, luma = 0.0, chroma = 0.0, lumaSD = 0.0 }
    func stats(_ img: CanvasImage, region: (x: Range<Int>, y: Range<Int>)? = nil) -> Stats {
        var s = Stats(), n = 0.0, lumas: [Double] = []
        let xs = region?.x ?? 0..<img.width, ys = region?.y ?? 0..<img.height
        for y in ys { for x in xs {
            let i = (y * img.width + x) * 4
            let r = Double(img.rgba[i]), g = Double(img.rgba[i + 1]), b = Double(img.rgba[i + 2])
            s.r += r; s.g += g; s.b += b; s.chroma += max(r, g, b) - min(r, g, b)
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            s.luma += l; lumas.append(l); n += 1
        } }
        s.r /= n; s.g /= n; s.b /= n; s.chroma /= n; s.luma /= n
        s.lumaSD = (lumas.map { ($0 - s.luma) * ($0 - s.luma) }.reduce(0, +) / n).squareRoot()
        return s
    }
    func diff(_ a: CanvasImage, _ b: CanvasImage) -> Double {
        zip(a.rgba, b.rgba).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(a.rgba.count)
    }

    // MARK: Presets and amount

    func testPresetsAndAmount() throws {
        let warm = try edited { $0 = $0.applying(ColorGrading.preset("warm-daylight")!) }
        XCTAssertGreaterThan(stats(warm).r - stats(warm).b, stats(baseline).r - stats(baseline).b, "Warm Daylight warms")
        let mono = try edited { $0 = $0.applying(ColorGrading.preset("mono-clean")!) }
        XCTAssertLessThan(stats(mono).chroma, 3, "Mono Clean removes colour")
        let half = try edited { $0.intensity = 0.5 }
        XCTAssertGreaterThan(stats(half).chroma, stats(mono).chroma + 10, "a lower amount brings colour back")
        XCTAssertLessThan(stats(half).chroma, stats(baseline).chroma, "but not all of it")
    }

    // MARK: Primary

    func testPrimaryAdjustments() throws {
        let base = stats(baseline)
        func adjusted(_ k: String, _ v: Double) throws -> Stats {
            try stats(edited { $0 = ColorGrading(); $0.adjust[k] = v })
        }
        XCTAssertGreaterThan(try adjusted("exposure", 0.5).luma, base.luma + 5, "exposure brightens")
        XCTAssertGreaterThan(try adjusted("contrast", 0.5).lumaSD, base.lumaSD + 3, "contrast spreads tones")
        XCTAssertLessThan(try adjusted("highlights", -0.5).luma, base.luma - 2, "highlights pull down the bright tones")
        XCTAssertGreaterThan(try adjusted("shadows", 0.5).luma, base.luma + 2, "shadows lift")
        XCTAssertGreaterThan(try adjusted("whites", 0.5).luma, base.luma + 2, "white point brightens")
        XCTAssertLessThan(try adjusted("blacks", 0.5).luma, base.luma - 2, "black point darkens")
        let warm = try adjusted("temperature", 0.5)
        XCTAssertGreaterThan(warm.r - warm.b, base.r - base.b + 5, "warmth adds red, takes blue")
        let tint = try adjusted("tint", 0.5)
        XCTAssertLessThan(tint.g, base.g - 3, "tint takes green")
        XCTAssertGreaterThan(try adjusted("vibrance", 0.6).chroma, base.chroma + 2, "vibrance adds colour")
        XCTAssertLessThan(try adjusted("saturation", -0.6).chroma, base.chroma - 10, "saturation removes colour")
    }

    // MARK: Wheels

    func testWheels() throws {
        let base = stats(baseline)
        let lifted = try stats(edited { $0.wheels["midtones"] = .init(hue: 0, amount: 0, level: 0.5) })
        XCTAssertGreaterThan(lifted.luma, base.luma + 5, "a wheel's level lifts its range")
        let red = try stats(edited { $0 = ColorGrading(); $0.wheels["shadows"] = .init(hue: 0, amount: 1, level: 0) })
        XCTAssertGreaterThan(red.r - red.b, base.r - base.b + 3, "a red shadow wheel pushes red")
        let blue = try stats(edited { $0 = ColorGrading(); $0.wheels["highlights"] = .init(hue: 240, amount: 1, level: 0) })
        XCTAssertGreaterThan(blue.b - blue.r, base.b - base.r + 3, "a blue highlight wheel pushes blue")
    }

    // MARK: Curves (all seven modes)

    func testCurves() throws {
        let base = stats(baseline)
        XCTAssertLessThan(try stats(edited { $0.curves["master"] = [[0, 0], [0.5, 0.3], [1, 1]] }).luma, base.luma - 5, "master curve down darkens")
        XCTAssertGreaterThan(try stats(edited { $0 = ColorGrading(); $0.curves["red"] = [[0, 0], [0.5, 0.75], [1, 1]] }).r, base.r + 10, "red curve")
        XCTAssertGreaterThan(try stats(edited { $0 = ColorGrading(); $0.curves["green"] = [[0, 0], [0.5, 0.75], [1, 1]] }).g, base.g + 10, "green curve")
        XCTAssertGreaterThan(try stats(edited { $0 = ColorGrading(); $0.curves["blue"] = [[0, 0], [0.5, 0.75], [1, 1]] }).b, base.b + 10, "blue curve")
        let hue = try edited { $0 = ColorGrading(); $0.hueCurves["hueVsHue"] = [[0, 90], [120, 90], [240, 90]] }
        XCTAssertGreaterThan(diff(hue, baseline), 5, "hue vs hue shifts hues")
        XCTAssertLessThan(try stats(edited { $0 = ColorGrading(); $0.hueCurves["hueVsSaturation"] = [[0, -1], [120, -1], [240, -1]] }).chroma,
                          base.chroma - 10, "hue vs saturation removes colour")
        XCTAssertGreaterThan(try stats(edited { $0 = ColorGrading(); $0.hueCurves["hueVsLuma"] = [[0, 0.3], [120, 0.3], [240, 0.3]] }).luma,
                             base.luma + 5, "hue vs luma brightens")
    }

    /// What the curve graph draws is what the picture gets: every pixel's red goes where `ColorCurveMath` (the graph's
    /// evaluator) puts it, for the user's screenshot curve (a steep rise after a flat floor, where the old graph spline
    /// overshot to about 1.2) and for end points dragged inward (which the renderer completes with (0,0) and (1,1)).
    func testPreviewAppliesTheCurveTheGraphDraws() throws {
        let screenshot = try curveError([[0, 0], [0.58, 0], [0.62, 0.65], [1, 1]])
        XCTAssertLessThanOrEqual(screenshot.red, 2.5, "screenshot curve: red off the drawn curve (levels)")
        XCTAssertLessThanOrEqual(screenshot.others, 1, "screenshot curve: green and blue untouched")
        let inward = try curveError([[0.2, 0.9], [0.8, 0.1]])
        XCTAssertLessThanOrEqual(inward.red, 2.5, "end points dragged inward: red off the drawn curve (levels)")
        // A near-vertical rise: 8-bit lookup rows interpolate across it, so only pixels on the rise may differ more.
        XCTAssertLessThanOrEqual(try curveError([[0, 0], [0.5, 0], [0.5001, 1], [1, 1]]).red, 64)
    }

    /// The preview graded with `red` as the R curve: the largest distance (levels) between each pixel's red and the
    /// graph's curve at its input red, and the largest change of green or blue.
    func curveError(_ red: [[Double]]) throws -> (red: Double, others: Int) {
        let graded = try edited { $0 = ColorGrading(); $0.curves["red"] = red }
        let px = stride(from: 0, to: baseline.rgba.count, by: 4)
        let worst = px.map { abs(Double(graded.rgba[$0]) - ColorCurveMath.sample(red, at: Double(baseline.rgba[$0]) / 255) * 255) }.max() ?? 0
        let others = px.map { max(abs(Int(graded.rgba[$0 + 1]) - Int(baseline.rgba[$0 + 1])), abs(Int(graded.rgba[$0 + 2]) - Int(baseline.rgba[$0 + 2]))) }.max() ?? 0
        return (worst, others)
    }

    // MARK: Secondaries

    func testSecondaryQualifier() throws {
        let edited = try self.edited { g in
            g = ColorGrading()
            var s = ColorGrading.Secondary()
            s.hueCenter = 0; s.hueRange = 25; s.hueSoftness = 0; s.saturation = -1
            g.secondaries = [s]
        }
        // Reds lose their colour; other pixels stay put.
        var redsBefore = 0.0, redsAfter = 0.0, otherChanged = 0
        for i in stride(from: 0, to: baseline.rgba.count, by: 4) {
            let r = Int(baseline.rgba[i]), g = Int(baseline.rgba[i + 1]), b = Int(baseline.rgba[i + 2])
            let isRed = r > 150 && g < 60 && b < 60
            let isGreenOrBlue = (g > r + 60 || b > r + 60)
            if isRed {
                redsBefore += Double(r - max(g, b))
                redsAfter += Double(Int(edited.rgba[i]) - max(Int(edited.rgba[i + 1]), Int(edited.rgba[i + 2])))
            } else if isGreenOrBlue, edited.rgba[i..<i + 3] != baseline.rgba[i..<i + 3] { otherChanged += 1 }
        }
        XCTAssertGreaterThan(redsBefore, 0, "the card has red")
        XCTAssertLessThan(redsAfter, redsBefore * 0.3, "qualified reds are desaturated")
        XCTAssertEqual(otherChanged, 0, "greens and blues are outside the qualifier")
    }

    // MARK: LUT

    func testLut() throws {
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        try cube.write(to: dir.appendingPathComponent("invert.cube"), atomically: true, encoding: .utf8)
        let inv = try edited { $0 = ColorGrading(); $0.lut = .init(src: "invert.cube", intensity: 1) }
        XCTAssertEqual(stats(inv).luma, 255 - stats(baseline).luma, accuracy: 3, "the LUT inverts")
        let half = try edited { $0.lut = .init(src: "invert.cube", intensity: 0.5) }
        XCTAssertLessThan(stats(half).lumaSD, stats(baseline).lumaSD * 0.2, "half strength mixes toward grey")
    }

    // MARK: Finish

    func testFinish() throws {
        let vignette = try edited { $0 = ColorGrading(); $0.details["vignette"] = 1 }
        let w = baseline.width, h = baseline.height
        let corner = { (img: CanvasImage) in self.stats(img, region: (0..<8, 0..<8)).luma }
        let centre = { (img: CanvasImage) in self.stats(img, region: (w / 2 - 4..<w / 2 + 4, h / 2 - 4..<h / 2 + 4)).luma }
        XCTAssertLessThan(corner(vignette), corner(baseline) * 0.6, "vignette darkens the corners")
        XCTAssertEqual(centre(vignette), centre(baseline), accuracy: 1, "and leaves the centre")
        let grain = try edited { $0 = ColorGrading(); $0.details["grain"] = 1 }
        XCTAssertGreaterThan(diff(grain, baseline), 1, "grain adds noise")
        let later = try frame(time: 0.6)
        XCTAssertNotEqual(grain.rgba, later.rgba, "grain moves over time")
    }

    // MARK: Stylize effects (all 18)

    func testEveryStylizeEffectChangesThePreview() throws {
        for key in ColorGrading.activeEffectKeys {
            let img = try edited { g in
                g = ColorGrading(); g.effects[key] = 1
                if key == "digitalGlitch" { g.effects["digitalGlitchColorSplit"] = 1; g.effects["digitalGlitchBlockDisplacement"] = 1; g.effects["digitalGlitchBlockOpacity"] = 1 }
            }
            // Film artifacts are sparse dust and scratches: any change counts.
            XCTAssertGreaterThan(diff(img, baseline), key == "filmArtifacts" ? 0 : 0.5, "\(key) changes the preview frame")
        }
        // A few directions.
        XCTAssertLessThan(try stats(edited { $0 = ColorGrading(); $0.effects["blur"] = 1 }).lumaSD, stats(baseline).lumaSD, "blur softens")
        XCTAssertLessThan(try stats(edited { $0 = ColorGrading(); $0.effects["scanlines"] = 1 }).luma, stats(baseline).luma - 5, "scanlines darken")
        XCTAssertGreaterThan(try stats(edited { $0 = ColorGrading(); $0.effects["bloom"] = 2 }).luma, stats(baseline).luma + 3, "bloom glows")
    }

    func testRemovingTheGradeRestoresTheFrame() throws {
        _ = try edited { $0.adjust["exposure"] = 1 }
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", nil))
        XCTAssertEqual(try frame().rgba, baseline.rgba)
    }

    func testGradeEditKeepsTheDecoderAndRegradesAtDrawTime() throws {
        let comp0 = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
        let layer0 = try XCTUnwrap(comp0.layers(at: 0.5).first)
        let cx = PreviewCompositor()
        defer { cx.stopAll() }
        cx.composition = comp0
        let plain = try XCTUnwrap(cx.decodeNow(layer0, time: 0.5, fps: 30, size: size))
        let lane = try XCTUnwrap(cx.lanes[layer0.laneKey])
        let restarts = lane.restarts, decoded = lane.framesDecoded

        var g = ColorGrading(); g.adjust["exposure"] = 0.8
        XCTAssertTrue(editor.setColorGrading(clipId: "clip:a", g))
        let comp1 = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
        let layer1 = try XCTUnwrap(comp1.layers(at: 0.5).first)
        XCTAssertEqual(layer1.laneKey, layer0.laneKey, "the grade is not part of the lane: frames are cached raw")
        cx.composition = comp1
        let bright = try XCTUnwrap(cx.decodeNow(layer1, time: 0.5, fps: 30, size: size))
        XCTAssertTrue(cx.lanes[layer1.laneKey] === lane, "the same decoder serves the edited grade")
        XCTAssertEqual(lane.restarts, restarts, "a grade edit does not restart the decoder")
        XCTAssertEqual(lane.framesDecoded, decoded, "nor decode the frame again")
        XCTAssertGreaterThan(stats(bright).luma, stats(plain).luma + 10, "the new grade shows on the next draw")
        XCTAssertEqual(cx.cache.frame(lane: layer1.laneKey, frame: 15)?.rgba, plain.rgba, "the cache keeps the raw frame")
        XCTAssertGreaterThan(cx.framesGraded, 0)
    }
}
