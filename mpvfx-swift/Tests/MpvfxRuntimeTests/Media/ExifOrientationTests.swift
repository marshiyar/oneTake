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
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

/// A JPEG with EXIF orientation 6 (stored 40×20 sideways, shown 20×40 upright): the import probe
/// reports the upright natural size, and export draws the picture upright. The JPEGs come from the media engine's
/// encoder with an EXIF segment spliced in (TestMedia.jpeg).
final class ExifOrientationTests: XCTestCase {
    var dir = ""
    override func setUpWithError() throws {
        dir = try makeMediaTempDir("exif-")
        // 40×20 red with a 10×10 blue square in the stored top-left corner.
        var stored = TestMedia.solid((255, 0, 0), width: 40, height: 20)
        for y in 0..<10 { for x in 0..<10 { stored.replaceSubrange(((y * 40 + x) * 4)..<((y * 40 + x) * 4 + 3), with: [0, 0, 255]) } }
        try TestMedia.jpeg(stored, width: 40, height: 20).write(to: URL(fileURLWithPath: "\(dir)/plain.jpg"))
        for o in 1...8 { try TestMedia.jpeg(stored, width: 40, height: 20, orientation: o).write(to: URL(fileURLWithPath: "\(dir)/o\(o).jpg")) }
    }
    override func tearDown() { if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) } }

    func testReadsEveryOrientationInBothByteOrders() {
        XCTAssertEqual(nativeImageOrientation(path: "\(dir)/plain.jpg"), 1)
        for o in 1...8 { XCTAssertEqual(nativeImageOrientation(path: "\(dir)/o\(o).jpg"), o) }
        XCTAssertEqual(nativeImageOrientation(path: "\(dir)/missing.jpg"), 1)
    }

    func testImportProbeReportsTheUprightNaturalSize() throws {
        let m6 = try readProjectMediaMetadata(dir, "o6.jpg")
        XCTAssertEqual(m6.width, 20); XCTAssertEqual(m6.height, 40)
        let m3 = try readProjectMediaMetadata(dir, "o3.jpg")
        XCTAssertEqual(m3.width, 40); XCTAssertEqual(m3.height, 20, "180° keeps the sides")
        let imported = describeImportedMedia(projectDir: dir, files: ["o8.jpg", "plain.jpg"]).media
        XCTAssertEqual(imported.map(\.width), [20, 40]); XCTAssertEqual(imported.map(\.height), [40, 20])
    }

    /// Export draws the picture upright: rendered as MOV (lossless) through the preview's painter, read back by the engine.
    func testExportDrawsThePictureUpright() throws {
        installAppExportFrames()
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(##"""
        {"schemaVersion":1,"mediaEngine":"native","id":"exif","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":20,"height":40,"background":"#000000"},
         "assets":[{"id":"p","kind":"image","name":"o6.jpg","source":"o6.jpg","durationFrames":10}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[
           {"id":"c","assetId":"p","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """##))
        let out = "\(dir)/exif.mov"
        try renderNativeTimeline(.init(project: doc, projectDir: dir, outputPath: out, format: .mov, quality: .high))
        let f = try Exported(path: out).rgb(0.5)
        XCTAssertEqual(f.count, 20 * 40 * 3, "a 20×40 upright frame")
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 20 + x) * 3; return (Int(f[i]), Int(f[i + 1]), Int(f[i + 2])) }
        // Turned 90° clockwise: the stored top-left square lands top-right.
        XCTAssertGreaterThan(px(15, 4).2, 150, "blue top-right \(px(15, 4))"); XCTAssertLessThan(px(15, 4).0, 100)
        XCTAssertGreaterThan(px(4, 4).0, 150, "red top-left \(px(4, 4))")
        XCTAssertGreaterThan(px(4, 34).0, 150, "red at the bottom \(px(4, 34))")
    }
}
