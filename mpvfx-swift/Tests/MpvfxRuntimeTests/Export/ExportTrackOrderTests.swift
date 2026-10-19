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
@testable import MpvfxRuntime
import MpvfxShared

/// Export draws clips bottom row first, so the top timeline row ends on top (as the preview does).
final class ExportTrackOrderTests: XCTestCase {
    func document(topIsA: Bool) throws -> NativeProjectDocument {
        let json = """
        {"schemaVersion":1,"id":"project:o","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"a.mp4","source":"a.mov","durationFrames":100},
                   {"id":"b","kind":"video","name":"b.mp4","source":"b.mov","durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"ta","kind":"video","lane":{"authoredTrack":1,"displayTrack":\(topIsA ? 0 : 1)},"clips":[
           {"id":"A","assetId":"a","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
          {"id":"tb","kind":"video","lane":{"authoredTrack":2,"displayTrack":\(topIsA ? 1 : 0)},"clips":[
           {"id":"B","assetId":"b","startFrame":0,"durationFrames":10,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }

    /// The centre pixel of the exported frame: red is A, blue is B (both cover the whole canvas).
    func topColor(_ doc: NativeProjectDocument) throws -> [UInt8] {
        let dir = try makeMediaTempDir("export-order-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try TestMedia.write(TestVideo(seconds: 1, color: { _ in [255, 0, 0] }), to: "\(dir)/a.mov")
        try TestMedia.write(TestVideo(seconds: 1, color: { _ in [0, 0, 255] }), to: "\(dir)/b.mov")
        try renderNativeTimeline(.init(project: doc, projectDir: dir, outputPath: "\(dir)/out.mov", format: .mov))
        let f = try Exported(path: "\(dir)/out.mov").rgb(0.5)
        let i = (16 * 64 + 32) * 3
        return Array(f[i..<i + 3])
    }

    override func setUp() { super.setUp(); installAppExportFrames() }

    func testOverlayOrderFollowsTimelineRows() throws {
        XCTAssertEqual(try topColor(try document(topIsA: true)), [255, 0, 0], "A on the top row draws on top")
        XCTAssertEqual(try topColor(try document(topIsA: false)), [0, 0, 255], "B on the top row draws on top")
    }
}
