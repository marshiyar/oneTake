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
// Export draws an untouched media clip at the default box (fitTimelineAssetGeometry of its natural size), the box
// the preview and the stage selection use, with the picture filling it: no letterbox inside the box.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime

final class ExportNaturalSizeTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-natural-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        installAppExportFrames()
        let dir = Self.root
        guard !FileManager.default.fileExists(atPath: "\(dir)/wide.mov") else { return }
        try TestMedia.write(TestVideo(width: 72, height: 72), to: "\(dir)/square.mov")
        try TestMedia.bmp(width: 36, height: 72, rgb: [255, 0, 0], to: "\(dir)/portrait.bmp")
        try TestMedia.write(TestVideo(width: 128, height: 32), to: "\(dir)/wide.mov")
    }

    /// 64×36 (16:9) project, one clip of `source`.
    func project(_ source: String, kind: String = "video", assetExtra: String = "", staticParameters: String = "{}") throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"test","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"m","kind":"\#(kind)","name":"m","source":"\#(source)","durationFrames":20\#(assetExtra)}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"c","assetId":"m","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"staticParameters":\#(staticParameters),"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }
    func render(_ document: NativeProjectDocument, _ name: String) throws -> [UInt8] {
        let output = "\(Self.root)/\(name)"
        try? FileManager.default.removeItem(atPath: output)
        try renderNativeTimeline(.init(project: document, projectDir: Self.root, outputPath: output, format: .mov, quality: .high))
        return try Exported(path: output).rgb(0.5)
    }
    func red(_ f: [UInt8], _ x: Int, _ y: Int) -> Int { Int(f[(y * 64 + x) * 3]) }

    /// Red inside `box` (2 px in from each edge, clear of chroma blur), black 2 px outside it.
    func assertBox(_ f: [UInt8], _ b: NativeClipLayoutBox, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let x0 = Int(b.left), y0 = Int(b.top), x1 = Int(b.left + b.width) - 1, y1 = Int(b.top + b.height) - 1
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        for (x, y) in [(x0 + 1, cy), (x1 - 1, cy), (cx, y0 + 1), (cx, y1 - 1), (cx, cy)] {
            XCTAssertGreaterThan(red(f, x, y), 180, "\(what): media at (\(x),\(y))", file: file, line: line)
        }
        for (x, y) in [(x0 - 2, cy), (x1 + 2, cy), (cx, y0 - 2), (cx, y1 + 2)] where x >= 0 && x < 64 && y >= 0 && y < 36 {
            XCTAssertLessThan(red(f, x, y), 60, "\(what): nothing at (\(x),\(y))", file: file, line: line)
        }
    }

    func testSquarePortraitAndWideClipsExportAtTheirFittedRects() throws {
        let square = NativeClipLayoutBox(left: 14, top: 0, width: 36, height: 36)
        XCTAssertEqual(fitTimelineAssetGeometry(.init(width: 72, height: 72), compWidth: 64, compHeight: 36), square)
        assertBox(try render(try project("square.mov"), "out-square.mov"), square, "square")
        let portrait = NativeClipLayoutBox(left: 23, top: 0, width: 18, height: 36)
        XCTAssertEqual(fitTimelineAssetGeometry(.init(width: 36, height: 72), compWidth: 64, compHeight: 36), portrait)
        assertBox(try render(try project("portrait.bmp", kind: "image"), "out-portrait.mov"), portrait, "portrait image")
        let wide = NativeClipLayoutBox(left: 0, top: 10, width: 64, height: 16)
        XCTAssertEqual(fitTimelineAssetGeometry(.init(width: 128, height: 32), compWidth: 64, compHeight: 36), wide)
        assertBox(try render(try project("wide.mov"), "out-wide.mov"), wide, "wide")
    }

    func testTheSizeCachedOnTheAssetAndAnOldFullCanvasSizeExportTheSameBox() throws {
        let square = NativeClipLayoutBox(left: 14, top: 0, width: 36, height: 36)
        assertBox(try render(try project("square.mov", assetExtra: #","width":72,"height":72"#), "cached.mov"), square, "cached size")
        assertBox(try render(try project("square.mov", staticParameters: #"{"layout.width":64,"layout.height":36}"#), "legacy.mov"),
                  square, "old project with the untouched full-canvas size")
        // An edited size is drawn as authored.
        let f = try render(try project("square.mov", staticParameters: #"{"layout.left":0,"layout.top":0,"layout.width":20,"layout.height":20}"#), "edited.mov")
        assertBox(f, NativeClipLayoutBox(left: 0, top: 0, width: 20, height: 20), "edited size")
    }

    /// Export sizes untouched clips from the engine's probe: the display size of stills and videos.
    func testProbeReportsTheNaturalSize() throws {
        let m = try probeExportMedia(root: try ProjectFS.realpath(Self.root), source: "portrait.bmp")
        XCTAssertEqual(m.natural, NativeMediaNaturalSize(width: 36, height: 72))
        let v = try probeExportMedia(root: try ProjectFS.realpath(Self.root), source: "wide.mov")
        XCTAssertEqual(v.natural, NativeMediaNaturalSize(width: 128, height: 32))
        XCTAssertFalse(v.audio, "no sound track")
    }
}
