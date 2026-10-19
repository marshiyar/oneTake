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
// A portrait composition exports as a portrait file: the output frame is the composition's size (or that size
// scaled with its aspect kept), written by MediaWriter through the real export session and read back with the
// engine's probe and frame reader. No FFmpeg anywhere.
import Foundation
import XCTest
import OneTakeMedia
@testable import MpvfxShared
@testable import MpvfxRuntime

final class ExportCompositionSizeTests: XCTestCase {
    var root = ""
    override func setUpWithError() throws {
        root = try makeMediaTempDir("export-composition-")
        installAppExportFrames()
        try TestMedia.bmp(width: 200, height: 200, rgb: [255, 0, 0], to: "\(root)/square.bmp")
    }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    /// 1080×1920 (9:16) project: one untouched 200×200 red still, 2 frames at 10 fps.
    func portrait() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"tall","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":1080,"height":1920,"background":"#000000"},
         "assets":[{"id":"sq","kind":"image","name":"square","source":"square.bmp","durationFrames":20}],
         "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
           {"id":"c","assetId":"sq","startFrame":0,"durationFrames":2,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#))
    }

    func export(_ doc: NativeProjectDocument, _ name: String, _ settings: ExportSettings) throws -> String {
        let output = "\(root)/\(name)"
        let job = try startExport(project: doc, projectDir: root, outputPath: output, settings: settings)
        guard case .completed? = job.wait(timeout: 300) else { XCTFail("\(String(describing: job.outcome))"); return output }
        return output
    }

    /// Red at the centre and `inside` px from it on each axis, black `outside` px from it: an unsquashed square.
    func assertSquare(_ path: String, inside: Int, outside: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try Exported(path: path).rgba(0.05)
        func red(_ x: Int, _ y: Int) -> Int { Int(f.rgba[(y * f.width + x) * 4]) }
        let cx = f.width / 2, cy = f.height / 2
        for (x, y) in [(cx, cy), (cx - inside, cy), (cx + inside, cy), (cx, cy - inside), (cx, cy + inside)] {
            XCTAssertGreaterThan(red(x, y), 180, "picture at (\(x),\(y))", file: file, line: line)
        }
        for (x, y) in [(cx - outside, cy), (cx + outside, cy), (cx, cy - outside), (cx, cy + outside)] {
            XCTAssertLessThan(red(x, y), 60, "background at (\(x),\(y))", file: file, line: line)
        }
    }

    func testAPortraitCompositionExportsAPortraitFile() throws {
        let doc = try portrait()
        let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps24)
        XCTAssertEqual(planExport(doc, settings: settings).outputDimensions, .init(width: 1080, height: 1920), "auto is the composition size")
        let out = try export(doc, "tall.mp4", settings)
        let video = try XCTUnwrap(try MediaProbe.probe(path: out).video)
        XCTAssertEqual(video.displayWidth, 1080); XCTAssertEqual(video.displayHeight, 1920)
        try assertSquare(out, inside: 90, outside: 115)   // the 200 px still, centred and square
    }

    func testAScaledRenderKeepsTheCompositionAspect() throws {
        let doc = try portrait()
        let target = compositionExportResolution(.shortEdge(720), customWidth: 0, canvas: doc.canvas)
        let settings = ExportSettings(format: .mp4, quality: .draft, fps: .fps24, resolution: target.resolution,
                                      customDimensions: target.customDimensions)
        XCTAssertEqual(planExport(doc, settings: settings).outputDimensions, .init(width: 720, height: 1280), "720p of 9:16")
        let out = try export(doc, "tall-720.mp4", settings)
        let video = try XCTUnwrap(try MediaProbe.probe(path: out).video)
        XCTAssertEqual(video.displayWidth, 720); XCTAssertEqual(video.displayHeight, 1280)
        try assertSquare(out, inside: 58, outside: 76)   // 200 × 720/1080 ≈ 133 px, still square
        // Auto passes through as the composition size; custom keeps the aspect from the width.
        XCTAssertEqual(compositionExportResolution(.auto, customWidth: 0, canvas: doc.canvas).resolution, .scale(.auto))
        XCTAssertEqual(compositionExportResolution(.custom, customWidth: 540, canvas: doc.canvas).customDimensions, .init(width: 540, height: 960))
    }
}
