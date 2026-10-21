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
// Export renders a clip's color grade and stylize effects through the same grading pass as the preview (MpvfxColor,
// applied by the preview painter per frame). Every case renders a real MOV (lossless PNG frames) through the media
// engine and checks decoded pixels.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime
import MpvfxColor

final class ExportColorGradeTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-grade-") else { return }
        root = dir
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        try? cube.write(toFile: "\(dir)/invert.cube", atomically: true, encoding: .utf8)
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/bars.mov") else { return }
        // Colour bars (eight vertical bars, a vertical ramp in each), lossless, with sound.
        try TestMedia.write(TestVideo(tone: 440, pixels: { _ in Self.bars() }), to: "\(root)/bars.mov")
    }
    static func bars() -> [UInt8] {
        let colors: [[Int]] = [[255, 255, 255], [255, 255, 0], [0, 255, 255], [0, 255, 0], [255, 0, 255], [255, 0, 0], [0, 0, 255], [40, 40, 40]]
        return (0..<32).flatMap { y in (0..<64).flatMap { x -> [UInt8] in
            let c = colors[x / 8], k = 0.4 + 0.6 * Double(y) / 31
            return c.map { UInt8(Double($0) * k) } + [255]
        } }
    }
    var root: String { Self.root }

    func project(_ grade: String?, effectId: String = "color-grading", canvas: String = ##"{"width":64,"height":32,"background":"#000000"}"##) throws -> NativeProjectDocument {
        let effects = grade.map { #"[{"id":"g","effectId":"\#(effectId)","enabled":true,"parameters":\#($0)}]"# } ?? "[]"
        return try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":\#(canvas),
         "assets":[{"id":"bars","kind":"video","name":"bars","source":"bars.mov","durationFrames":20}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"bars","assetId":"bars","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,"effects":\#(effects),"parameterTracks":[]}]}]}}
        """#))
    }
    func render(_ document: NativeProjectDocument, _ name: String) throws -> String {
        let output = "\(root)/\(name)"
        try? FileManager.default.removeItem(atPath: output)
        try renderNativeTimeline(.init(project: document, projectDir: root, outputPath: output, format: .mov, quality: .high))
        return output
    }
    /// RGB (or RGBA) frame at `seconds`.
    func picture(_ path: String, _ seconds: Double, format: String = "rgb24") throws -> [UInt8] {
        format == "rgba" ? try Exported(path: path).rgba(seconds).rgba : try Exported(path: path).rgb(seconds)
    }
    func luma(_ rgb: [UInt8]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: rgb.count, by: 3) {
            let r = Double(rgb[i]), g = Double(rgb[i + 1]), b = Double(rgb[i + 2])
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return sum / Double(rgb.count / 3)
    }
    func chroma(_ rgb: [UInt8]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: rgb.count, by: 3) {
            let hi = max(rgb[i], rgb[i + 1], rgb[i + 2]), lo = min(rgb[i], rgb[i + 1], rgb[i + 2])
            sum += Double(hi - lo)
        }
        return sum / Double(rgb.count / 3)
    }
    func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double { zip(a, b).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(a.count) }

    /// The preview's result for the same frame: the source frame graded by the shared pass, as RGB.
    func previewReference(_ grade: String, seconds: Double) throws -> [UInt8] {
        var rgba = try picture("\(root)/bars.mov", seconds, format: "rgba")
        let params = ColorGradeParams(json: try NativeJSONValue.parse(grade).objectValue!)!
        let r = ColorGradeRenderer.forClip(params, clipId: "bars", projectDir: root)!
        r.apply(&rgba, width: 64, height: 32, time: seconds)
        return stride(from: 0, to: rgba.count, by: 4).flatMap { (i: Int) -> [UInt8] in [rgba[i], rgba[i + 1], rgba[i + 2]] }
    }

    func testExportMatchesThePreviewGrade() throws {
        let grade = #"{"preset":"food-pop","adjust":{"temperature":0.4},"details":{"vignette":0.6},"wheels":{"shadows":{"hue":220,"amount":0.6,"level":0}},"curves":{"master":[[0,0],[0.5,0.4],[1,1]]}}"#
        let out = try render(try project(grade), "match.mov")
        let exported = try picture(out, 0.5), reference = try previewReference(grade, seconds: 0.5)
        let plain = try picture("\(root)/bars.mov", 0.5)
        XCTAssertGreaterThan(meanDiff(plain, reference), 8, "the grade is visible")
        XCTAssertLessThan(meanDiff(exported, reference), 3, "export matches the preview's pixels (encoder loss only)")
    }

    func testPrimaryLutAndFinishRender() throws {
        let plain = try picture("\(root)/bars.mov", 0.5)
        let bright = try picture(try render(try project(#"{"adjust":{"exposure":0.6}}"#), "bright.mov"), 0.5)
        XCTAssertGreaterThan(luma(bright), luma(plain) + 10)
        let mono = try picture(try render(try project(#"{"preset":"mono-clean"}"#), "mono.mov"), 0.5)
        XCTAssertLessThan(chroma(mono), 4)
        let inv = try picture(try render(try project(#"{"lut":{"src":"invert.cube","intensity":1}}"#), "lut.mov"), 0.5)
        XCTAssertEqual(luma(inv), 255 - luma(plain), accuracy: 4)
        let vig = try picture(try render(try project(#"{"details":{"vignette":1}}"#), "vignette.mov"), 0.5)
        let cornerAfter = Int(vig[0]) + Int(vig[1]) + Int(vig[2]), cornerBefore = Int(plain[0]) + Int(plain[1]) + Int(plain[2])
        XCTAssertLessThan(cornerAfter, cornerBefore, "vignette darkens the corner")
    }

    func testStylizeEffectsRenderAndMatchThePreview() throws {
        for (key, extra) in [("halftone", ""), ("scanlines", ""), ("pixelate", ""), ("blur", ""), ("crtCurvature", "")] {
            let grade = #"{"effects":{"\#(key)":1\#(extra)}}"#
            let out = try render(try project(grade), "\(key).mov")
            let exported = try picture(out, 0.5), reference = try previewReference(grade, seconds: 0.5)
            XCTAssertGreaterThan(meanDiff(try picture("\(root)/bars.mov", 0.5), reference), 3, "\(key) is visible")
            XCTAssertLessThan(meanDiff(exported, reference), 4, "\(key) export matches the preview")
        }
    }

    func testGradedClipKeepsItsSound() throws {
        let out = try render(try project(#"{"adjust":{"exposure":0.5}}"#), "sound.mov")
        XCTAssertEqual(try Exported(path: out).rms(0.5), 0.125 / 2.0.squareRoot(), accuracy: 0.002, "the 440 Hz tone at full level")
    }

    /// The exported frame is the preview painter's frame for the same grade, pixel for pixel (PNG is lossless).
    func testExportIsThePreviewPaintersGradedFrame() throws {
        let grade = #"{"preset":"food-pop","adjust":{"temperature":0.4},"details":{"vignette":0.6}}"#
        let input = NativeTimelineRenderInput(project: try project(grade), projectDir: root, outputPath: "\(root)/painter.mov", format: .mov)
        let out = try render(input.project, "painter.mov")
        let exported = try Exported(path: out).rgba(0.5).rgba
        XCTAssertLessThanOrEqual(maxAbsDiff(exported, try previewExportFrame(input, at: 0.5)), 1)
    }

    func testColourKeyMovAlphaMatchesPreviewAndRejectsUnsupportedContract() throws {
        let key = #"{"v":1,"kind":"chroma","similarity":0.08,"smoothness":0.18}"#
        let document = try project(key, effectId: "color-key", canvas: ##"{"width":64,"height":32,"background":"#00000000"}"##)
        let input = NativeTimelineRenderInput(project: document, projectDir: root,
                                              outputPath: "\(root)/key.mov", format: .mov)
        let output = try render(document, "key.mov")
        let exported = try Exported(path: output).rgba(0.5).rgba
        let preview = try previewExportFrame(input, at: 0.5)
        XCTAssertLessThanOrEqual(maxAbsDiff(exported, preview), 1)
        let greenAlpha: [UInt8] = (0..<32).flatMap { (y: Int) -> [UInt8] in
            (24..<32).map { (x: Int) -> UInt8 in exported[(y * 64 + x) * 4 + 3] }
        }
        XCTAssertLessThanOrEqual(greenAlpha.max() ?? 255, 1, "the computed matte is written to MOV alpha")

        let unsupported = NativeClipEffect(id: "future", effectId: "color-key", enabled: true,
                                           parameters: try XCTUnwrap(try NativeJSONValue.parse(#"{"v":2,"kind":"future"}"#).objectValue))
        XCTAssertFalse(exportSupportsEffect(unsupported), "an effect ID alone must not claim export support")
        let malformed = NativeClipEffect(id: "bad", effectId: "color-key", enabled: true,
                                         parameters: try XCTUnwrap(try NativeJSONValue.parse(#"{"v":1,"kind":"chroma","spill":2}"#).objectValue))
        XCTAssertFalse(exportSupportsEffect(malformed), "unsupported parameters must not claim export support")
        XCTAssertNoThrow(try assertNativeTimelineSupported(try project(#"{"v":2,"kind":"future"}"#, effectId: "color-key")),
                         "future contracts are intentionally retained and skipped")
    }

    func testOtherEffectsAreStillRefused() throws {
        XCTAssertThrowsError(try render(try project(#"{"amount":1}"#, effectId: "glow"), "glow.mov")) { e in
            XCTAssertTrue("\(e)".contains("not been migrated"))
        }
        XCTAssertNoThrow(try assertNativeTimelineSupported(try project(#"{"adjust":{"exposure":1}}"#)))
    }
}
