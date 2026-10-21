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
// Cut transitions drawn by the preview compositor and in the exported file (issue #265, A4 and A5): a white clip
// dissolving to a black one over 30 frames, and a dip to black between two white clips, read at the first, middle and
// last frame of the transition from the preview compositor's output and from the exported MOV (lossless PNG frames).
import Foundation
import XCTest
import OneTakeMedia
import MpvfxCanvas
@testable import MpvfxPlayer
@testable import MpvfxShared
@testable import MpvfxRuntime

final class CutTransitionExportMatchTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("cut-transition-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/black.mov") else { return }
        // 6 s at 10 fps: 60 frames of media, so each 30-frame clip has 15 frames of handle on either side.
        try TestMedia.write(TestVideo(width: 64, height: 32, seconds: 6, color: { _ in [255, 255, 255] }), to: "\(root)/white.mov")
        try TestMedia.write(TestVideo(width: 64, height: 32, seconds: 6, color: { _ in [0, 0, 0] }), to: "\(root)/black.mov")
    }
    var root: String { Self.root }

    /// Clip "out" [0, 30) and clip "in" [30, 60), each from source frame 15, with a centred 30-frame transition
    /// (frames 15…45, the cut at 30). 64x32 at 10 fps, grey background so a hole would show.
    func document(second: String, kind: String) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"cut","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#336699"},
         "assets":[{"id":"w","kind":"video","name":"White","source":"white.mov","durationFrames":60},
                   {"id":"k","kind":"video","name":"Second","source":"\#(second).mov","durationFrames":60}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"out","assetId":"w","startFrame":0,"durationFrames":30,"sourceInFrame":15,"muted":true,"effects":[],"parameterTracks":[]},
           {"id":"in","assetId":"k","startFrame":30,"durationFrames":30,"sourceInFrame":15,"muted":true,"effects":[],"parameterTracks":[]}],
          "transitions":[{"v":1,"id":"t","fromClipId":"out","toClipId":"in","kind":"\#(kind)","durationFrames":30,"alignment":"centre"}]}]}}
        """#))
    }

    /// The preview compositor's picture at `frame`: every layer's frame decoded into its cache, then drawn.
    func previewFrame(_ doc: NativeProjectDocument, frame: Int) throws -> [UInt8] {
        let comp = PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: root), engine: nil)
        let cx = PreviewCompositor()
        defer { cx.stopAll() }
        cx.composition = comp
        let time = (Double(frame) + 0.5) / 10
        for layer in comp.layers(at: time) {
            _ = cx.decodeRawNow(layer, time: time, fps: 10, size: PreviewDecodeSize(width: 64, height: 32))
        }
        let canvas = try RasterCanvas(width: 64, height: 32)
        cx.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 64, height: 32), time: time, elements: [], context: FrameDrawContext())
        return canvas.image().rgba
    }

    func export(_ doc: NativeProjectDocument, _ name: String) throws -> Exported {
        let output = "\(root)/\(name).mov"
        try? FileManager.default.removeItem(atPath: output)
        try renderNativeTimeline(NativeTimelineRenderInput(project: doc, projectDir: root, outputPath: output, format: .mov, quality: .high))
        return Exported(path: output)
    }

    /// The centre pixel's red, green and blue.
    func centre(_ rgba: [UInt8]) -> [Int] { let i = (16 * 64 + 32) * 4; return [Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2])] }

    func assertLevel(_ doc: NativeProjectDocument, _ file: Exported, frame: Int, _ level: Int, _ what: String,
                     line: UInt = #line) throws {
        let preview = centre(try previewFrame(doc, frame: frame))
        let exported = centre(try file.rgba((Double(frame) + 0.5) / 10).rgba)
        for (name, got) in [("preview", preview), ("export", exported)] {
            XCTAssertTrue(got.allSatisfy { abs($0 - level) <= 1 }, "\(what), \(name) frame \(frame): \(got), want \(level) ±1", line: line)
        }
    }

    func testA4AWhiteClipDissolvingToBlackReadsHalfGreyAtTheMiddleInPreviewAndExport() throws {
        let doc = try document(second: "black", kind: "dissolve")
        let file = try export(doc, "dissolve")
        try assertLevel(doc, file, frame: 15, 255, "first frame of the dissolve: all white")
        try assertLevel(doc, file, frame: 30, 128, "middle frame: half grey")
        try assertLevel(doc, file, frame: 45, 0, "last frame (the dissolve's end): all black")
        try assertLevel(doc, file, frame: 10, 255, "before the dissolve")
        try assertLevel(doc, file, frame: 20, 212, "a sixth of the way: 255 × 5/6")
    }

    func testA5ADipToBlackBetweenTwoWhiteClipsReadsBlackAtTheCut() throws {
        let doc = try document(second: "white", kind: "dip")
        let file = try export(doc, "dip")
        try assertLevel(doc, file, frame: 15, 255, "dip start: white")
        try assertLevel(doc, file, frame: 30, 0, "the cut frame: black")
        try assertLevel(doc, file, frame: 45, 255, "dip end: white")
        try assertLevel(doc, file, frame: 22, 136, "7/15 of the way down: 255 × 8/15")
    }
}
