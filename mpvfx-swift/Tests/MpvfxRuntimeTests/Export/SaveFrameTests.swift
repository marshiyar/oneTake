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
import MpvfxPlayer
import MpvfxShared
import OneTakeMedia
import XCTest

@testable import MpvfxRuntime

internal final class SaveFrameTests: XCTestCase {
    private var root: String = ""
    override internal func setUpWithError() throws { root = try makeTempDir("save-frame-") }
    override internal func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    private func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(
            try NativeJSONValue.parse(
                #"""
                {"schemaVersion":1,"mediaEngine":"native","id":"still","revision":0,"frameRate":{"numerator":10,"denominator":1},
                 "canvas":{"width":64,"height":32,"background":"#102030"},
                 "assets":[{"id":"picture","kind":"image","name":"picture","source":"picture.bmp","durationFrames":1}],
                 "sequence":{"id":"sequence","name":"Sequence","tracks":[{"id":"video","kind":"video","clips":[
                   {"id":"clip","assetId":"picture","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":true,
                    "staticParameters":{"visual.opacity":0.5},"effects":[],"parameterTracks":[]}]}]}}
                """#
            )
        )
    }

    private func makePicture() throws {
        var pixels: [UInt8] = []
        for _ in 0..<32 {
            for column in 0..<64 { pixels += [UInt8(80 + column), UInt8(120 + column), UInt8(160 + column), 255] }
        }
        try TestMedia.bmp(pixels, width: 64, height: 32).write(to: URL(fileURLWithPath: root + "/picture.bmp"))
    }

    /// A1: a JPEG at quality 95 matches the video export's frame, at the composition size.
    internal func testSavedJPEGMatchesExportedCompositedFrameWithin40dB() throws {
        try makePicture()
        let doc: NativeProjectDocument = try document()
        let output: String = root + "/still.jpg"
        try SaveFrame.jpeg(
            project: doc,
            projectDir: root,
            time: 0.7,
            outputPath: output,
            durableWrite: TestDurableWrite(),
            renderer: PreviewExportFrames.factory
        )
        let still: (rgba: [UInt8], width: Int, height: Int) = try ImageCodec.decode(
            Data(contentsOf: URL(fileURLWithPath: output))
        )
        XCTAssertEqual(still.width, 64)
        XCTAssertEqual(still.height, 32)
        var input: NativeTimelineRenderInput = NativeTimelineRenderInput(
            project: doc,
            projectDir: root,
            outputPath: root + "/video.mov",
            format: .mov
        )
        input.frameRenderer = PreviewExportFrames.factory
        try renderNativeTimeline(input)
        let video: (rgba: [UInt8], time: Double) = try VideoFrameReader(path: root + "/video.mov").frame(at: 0.7, width: 64, height: 32)
        let differences: [Double] = zip(still.rgba, video.rgba).enumerated().filter { $0.offset % 4 != 3 }.map { pair in
            let difference: Double = Double(pair.element.0) - Double(pair.element.1)
            return difference * difference
        }
        let mse: Double = differences.reduce(0, +) / Double(differences.count)
        let psnr: Double = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
        XCTAssertGreaterThanOrEqual(psnr, 40)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root).contains { $0.hasPrefix(".mpvfx-frame-") }
        )
    }

    internal func testSavedFrameUsesTheRequestedPlayheadTime() throws {
        var video: TestVideo = TestVideo()
        video.color = { t in t < 0.5 ? [30, 30, 30] : [220, 220, 220] }
        try TestMedia.write(video, to: root + "/picture.mov")
        var doc: NativeProjectDocument = try document()
        doc.assets[0].kind = .video
        doc.assets[0].source = "picture.mov"
        doc.assets[0].durationFrames = 20
        for (name, time) in [("early", 0.2), ("late", 0.8)] {
            try SaveFrame.jpeg(
                project: doc,
                projectDir: root,
                time: time,
                outputPath: root + "/\(name).jpg",
                durableWrite: TestDurableWrite(),
                renderer: PreviewExportFrames.factory
            )
        }
        let early: [UInt8] = try ImageCodec.decode(Data(contentsOf: URL(fileURLWithPath: root + "/early.jpg"))).rgba
        let late: [UInt8] = try ImageCodec.decode(Data(contentsOf: URL(fileURLWithPath: root + "/late.jpg"))).rgba
        XCTAssertGreaterThan(
            Int(late[0]) - Int(early[0]),
            80,
            "the saved picture must follow the playhead, not always frame zero"
        )
    }

    /// A2: an existing destination survives byte-for-byte with the same typed collision as video export.
    internal func testExistingOutputIsUntouchedAndThrowsTypedError() throws {
        let path: String = root + "/existing.jpg"
        let original: Data = Data("existing image".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(
            try SaveFrame.jpeg(
                project: document(),
                projectDir: root,
                time: 0,
                outputPath: path,
                durableWrite: TestDurableWrite()
            )
        ) {
            XCTAssertEqual($0 as? ExportOutputExistsError, ExportOutputExistsError(path: path))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    /// A2: a destination created while the frame is being painted survives too.
    internal func testOutputCreatedDuringPaintingIsNeverReplacedAndStagingIsCleaned() throws {
        try makePicture()
        let path: String = root + "/race.jpg"
        let original: Data = Data("another writer".utf8)
        let factory: NativeExportFrameRendererFactory = { request in
            try original.write(to: URL(fileURLWithPath: path))
            return try PreviewExportFrames(request)
        }
        XCTAssertThrowsError(
            try SaveFrame.jpeg(
                project: document(),
                projectDir: root,
                time: 0.5,
                outputPath: path,
                durableWrite: TestDurableWrite(),
                renderer: factory
            )
        ) {
            XCTAssertEqual($0 as? ExportOutputExistsError, ExportOutputExistsError(path: path))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root).contains { $0.hasPrefix(".mpvfx-frame-") }
        )
    }

    internal func testNoSelectionOrLayersNeededAndInvalidExtensionDoesNotWriteJPEGAsPNG() throws {
        var doc: NativeProjectDocument = try document()
        doc.sequence.tracks = []
        let path: String = root + "/empty.jpeg"
        try SaveFrame.jpeg(
            project: doc,
            projectDir: root,
            time: 0,
            outputPath: path,
            durableWrite: TestDurableWrite(),
            renderer: PreviewExportFrames.factory
        )
        XCTAssertEqual(try ImageCodec.decode(Data(contentsOf: URL(fileURLWithPath: path))).width, 64)
        XCTAssertThrowsError(
            try SaveFrame.jpeg(
                project: doc,
                projectDir: root,
                time: 0,
                outputPath: root + "/wrong.png",
                durableWrite: TestDurableWrite()
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/wrong.png"))
    }
}
