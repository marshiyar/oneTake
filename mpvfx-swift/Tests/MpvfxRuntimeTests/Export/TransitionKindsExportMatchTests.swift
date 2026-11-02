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
// The spatial and zoom transition kinds, preview against export (issue #267): a red clip into a blue one over 30
// frames, read at 25%, 50% and 75% of the range from the preview painter and from the exported MOV.
import Foundation
import XCTest
import OneTakeMedia
import MpvfxCanvas
@testable import MpvfxPlayer
@testable import MpvfxShared
@testable import MpvfxRuntime

final class TransitionKindsExportMatchTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("transition-kinds-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/blue.mov") else { return }
        // 6 s at 10 fps: 60 frames of media, so each 30-frame clip has 15 frames of handle on either side.
        try TestMedia.write(TestVideo(width: 64, height: 32, seconds: 6, color: { _ in [255, 0, 0] }), to: "\(root)/red.mov")
        try TestMedia.write(TestVideo(width: 64, height: 32, seconds: 6, color: { _ in [0, 0, 255] }), to: "\(root)/blue.mov")
    }
    var root: String { Self.root }

    /// Clip "out" (red) [0, 30) and clip "in" (blue) [30, 60), each from source frame 15, with a centred 30-frame
    /// transition (frames 15…45, the cut at 30). `fields` are extra transition keys.
    func document(kind: String, fields: String = "") throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"kinds","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#336699"},
         "assets":[{"id":"r","kind":"video","name":"Red","source":"red.mov","durationFrames":60},
                   {"id":"b","kind":"video","name":"Blue","source":"blue.mov","durationFrames":60}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"out","assetId":"r","startFrame":0,"durationFrames":30,"sourceInFrame":15,"muted":true,"effects":[],"parameterTracks":[]},
           {"id":"in","assetId":"b","startFrame":30,"durationFrames":30,"sourceInFrame":15,"muted":true,"effects":[],"parameterTracks":[]}],
          "transitions":[{"v":1,"id":"t","fromClipId":"out","toClipId":"in","kind":"\#(kind)","durationFrames":30,"alignment":"centre"\#(fields)}]}]}}
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

    /// Frames at 25%, 50% and 75% of the range 15…45.
    static let frames = [(23, "25%"), (30, "50%"), (38, "75%")]

    func assertMatches(kind: String, fields: String = "", name: String, line: UInt = #line) throws {
        let doc = try document(kind: kind, fields: fields)
        let file = try export(doc, name)
        for (frame, label) in Self.frames {
            let preview = try previewFrame(doc, frame: frame)
            let exported = try file.rgba((Double(frame) + 0.5) / 10).rgba
            XCTAssertEqual(preview.count, exported.count, "\(name) \(label): same size", line: line)
            var worst = 0, at = 0
            for i in 0..<min(preview.count, exported.count) where i % 4 != 3 {
                let d = abs(Int(preview[i]) - Int(exported[i]))
                if d > worst { worst = d; at = i / 4 }
            }
            XCTAssertLessThanOrEqual(worst, 1, "\(name) \(label) (frame \(frame)): preview and export differ by \(worst) at pixel \(at % 64),\(at / 64)", line: line)
        }
    }

    func testWipeAt45DegreesMatches() throws { try assertMatches(kind: "wipe", fields: #","angle":45"#, name: "wipe") }
    func testPushMatches() throws { try assertMatches(kind: "push", fields: #","direction":"left""#, name: "push") }
    func testSlideMatches() throws { try assertMatches(kind: "slide", fields: #","direction":"right""#, name: "slide") }
    func testIrisMatches() throws { try assertMatches(kind: "iris", name: "iris") }
    func testZoomThroughMatches() throws { try assertMatches(kind: "zoomThrough", name: "zoom") }
}
