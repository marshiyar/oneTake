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
// Hold frame through the real export and the preview's decode lanes: a numbered-frame video (frame n is the solid
// colour [n, 255 - n, 77]) held at frame 120 for 60 frames, exported as a lossless MOV and read back.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime
@testable import MpvfxPlayer

final class HoldFrameExportTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("hold-export-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/numbered.mov") else { return }
        try TestMedia.write(TestVideo(width: 32, height: 16, fps: 30, seconds: 8, pixels: { t in
            let n = Int((t * 30).rounded())
            return TestMedia.solid([UInt8(n), UInt8(255 - n), 77], 32, 16)
        }), to: "\(root)/numbered.mov")
    }
    var root: String { Self.root }
    // No parameter tracks: nothing here needs the keyframe engine.
    let engine: KeyframeEngine? = nil

    /// 30 fps, 32x16; the numbered video from frame 0 for 240 frames. `look` adds a grade, crop and transform.
    func document(look: Bool = false) throws -> NativeProjectDocument {
        let extras = look ? #"""
            ,"effects":[{"id":"grade","effectId":"color-grading","enabled":true,"parameters":{"adjust":{"exposure":0.5}}}],
             "crop":{"top":2,"right":1,"bottom":0,"left":3},"staticParameters":{"transform.rotation":15,"transform.scale":0.8}
            """# : #","effects":[]"#
        return try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"mediaEngine":"native","id":"hold","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":32,"height":16,"background":"#000000"},
         "assets":[{"id":"num","kind":"video","name":"numbered","source":"numbered.mov","durationFrames":240}],
         "sequence":{"id":"seq","name":"Main","tracks":[{"id":"v1","kind":"video","clips":[
           {"id":"clip","assetId":"num","startFrame":0,"durationFrames":240,"sourceInFrame":0,"muted":true,"parameterTracks":[]\(extras)}]}]}}
        """), engine: engine)
    }

    func held(_ d: NativeProjectDocument, _ mode: NativeTimelineHoldMode = .insert) throws -> NativeTimelineHoldPlan {
        try planNativeTimelineHold(d, .init(address: .init(sequenceId: "seq", trackId: "v1", clipId: "clip"), frame: 120,
                                            lengthFrames: 60, mode: mode), engine: engine).get()
    }

    func frames(_ d: NativeProjectDocument) throws -> PreviewExportFrames {
        var r = NativeExportFrameRequest(document: d, projectDir: root, width: 32, height: 16)
        r.keyframeEngine = engine
        return try PreviewExportFrames(r)
    }

    /// The numbered frame a picture shows (its centre pixel's red).
    func number(_ rgba: [UInt8]) -> Int { Int(rgba[(8 * 32 + 16) * 4]) }

    func testA1TheExportShowsFrame120ThroughTheHoldThenFrame121() throws {
        let doc = try held(try document()).document
        let output = "\(root)/held.mov"
        try? FileManager.default.removeItem(atPath: output)
        let input = NativeTimelineRenderInput(project: doc, projectDir: root, outputPath: output, format: .mov, quality: .high)
        try renderNativeTimeline(input)
        let file = Exported(path: output)
        XCTAssertEqual(try file.probe.video?.frames, 299, "240 frames, one of them held for 60")
        let shown = try [0, 119, 120, 121, 150, 179, 180, 181, 298].map { f in (f, number(try file.rgba((Double(f) + 0.5) / 30).rgba)) }
        XCTAssertEqual(shown.map(\.1), [0, 119, 120, 120, 120, 120, 121, 122, 239], "\(shown)")
        let heldFrames = try (120..<180).map { number(try file.rgba((Double($0) + 0.5) / 30).rgba) }
        XCTAssertEqual(Set(heldFrames), [120], "every exported frame of the hold is frame 120")
        // Preview equals export at the first, a middle and the last frame of the hold and either side of it.
        for f in [119, 120, 150, 179, 180] {
            let t = (Double(f) + 0.5) / 30
            XCTAssertLessThanOrEqual(maxAbsDiff(try file.rgba(t).rgba, try previewExportFrame(input, at: t)), 1, "frame \(f)")
        }
    }

    func testA2OverwriteExportsTheSameLength() throws {
        let doc = try held(try document(), .overwrite).document
        let output = "\(root)/overwritten.mov"
        try? FileManager.default.removeItem(atPath: output)
        try renderNativeTimeline(NativeTimelineRenderInput(project: doc, projectDir: root, outputPath: output, format: .mov, quality: .high))
        XCTAssertEqual(try Exported(path: output).probe.video?.frames, 240)
        XCTAssertEqual(number(try Exported(path: output).rgba(180.5 / 30).rgba), 180, "after the hold the clip keeps its timing")
    }

    func testA3TheHoldKeepsGradeCropAndTransform() throws {
        let source = try document(look: true)
        let original = try frames(source).frame(at: 120.0 / 30)
        let hold = try frames(try held(source).document)
        for f in [120, 150, 179] {
            XCTAssertEqual(maxAbsDiff(try hold.frame(at: Double(f) / 30), original), 0, "hold frame \(f) is the clip's frame 120, graded and cropped")
        }
        XCTAssertNotEqual(maxAbsDiff(original, try frames(try document()).frame(at: 120.0 / 30)), 0, "the look changes the picture")
    }

    func testA4HoldsDecodeOnlyTheirFirstFrame() throws {
        let doc = try held(try document()).document
        let export = try frames(doc)
        _ = try export.frame(at: 119.0 / 30)
        let before = export.framesDecoded
        for f in 120..<180 { _ = try export.frame(at: Double(f) / 30) }
        XCTAssertEqual(export.framesDecoded - before, 1, "export decodes the held frame once")

        let compositor = PreviewCompositor()
        let composition = PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: root), engine: engine)
        compositor.composition = composition
        let size = PreviewDecodeSize(width: 32, height: 16)
        var shown: Set<Int> = []
        for f in 120..<180 {
            let t = Double(f) / 30
            let layer = try XCTUnwrap(composition.layers(at: t).first)
            XCTAssertTrue(layer.isStill)
            shown.insert(number(try XCTUnwrap(compositor.decodeRawNow(layer, time: t, fps: 30, size: size)).image.rgba))
        }
        XCTAssertEqual(shown, [120])
        let lanes = compositor.lanes.values.filter { $0.layer.holdSourceTime != nil }
        XCTAssertEqual(lanes.map(\.framesDecoded), [1], "the preview's still lane decodes the held frame once")
        compositor.stopAll()
    }
}
