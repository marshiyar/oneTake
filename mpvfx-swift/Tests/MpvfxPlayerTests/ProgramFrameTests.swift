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

/// The colour picker's eyedropper frame (issue #189): the composited program frame, painted as export paints it.
final class ProgramFrameTests: XCTestCase {
    /// A 160×90 canvas with a #336699 background and a test-pattern video over its left half for the first second.
    static let json = #"""
    {"schemaVersion":1,"id":"project:p","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":160,"height":90,"background":"#336699"},
     "assets":[{"id":"asset:a","kind":"video","name":"media.mov","source":"media.mov","durationFrames":30}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
        "staticParameters":{"layout.left":0,"layout.top":0,"layout.width":80,"layout.height":90}}]}]}}
    """#

    func testProgramFrameIsTheCompositedStageAtTheAskedSize() throws {
        let dir = try TestMedia.scratch("program-frame")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try TestMedia.PatternVideo().write(to: dir.appendingPathComponent("media.mov").path)
        let editor = try TimelineEditor(json: Self.json)
        let compositor = PreviewCompositor()
        defer { compositor.stopAll() }
        compositor.composition = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
        let r = PresetPreviewRenderer(compositor: compositor)
        if case .rendering = r.programFrame(time: 0.5, pixelWidth: 64, pixelHeight: 64) { r.wait() }   // the video's frame decodes first
        guard case .ready(let img) = r.programFrame(time: 0.5, pixelWidth: 64, pixelHeight: 64) else { return XCTFail("ready once decoded") }
        XCTAssertEqual(img.width, 64); XCTAssertEqual(img.height, 36, "the 16:9 canvas fits inside 64×64")
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * img.width + x) * 4; return Array(img.rgba[i..<i + 3]) }
        XCTAssertEqual(rgb(60, 18), [0x33, 0x66, 0x99], "the canvas background where no clip is")
        let left = Set((0..<32).flatMap { x in (0..<36).map { y in rgb(x, y) } })
        XCTAssertGreaterThan(left.count, 4, "the video's picture on the left, not the background")
        guard case .ready(let empty) = r.programFrame(time: 2, pixelWidth: 64, pixelHeight: 64) else { return XCTFail("no clip: the background") }
        XCTAssertEqual(Array(empty.rgba[0..<3]), [0x33, 0x66, 0x99])
    }

    func testProgramFrameIsUnavailableWithoutAComposition() {
        let r = PresetPreviewRenderer(compositor: PreviewCompositor())
        guard case .unavailable = r.programFrame(time: 0, pixelWidth: 64, pixelHeight: 64) else { return XCTFail("nothing to paint") }
        guard case .unavailable = r.programFrame(time: 0, pixelWidth: 0, pixelHeight: 64) else { return XCTFail("no size") }
    }
}
