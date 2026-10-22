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

/// The preview composition's layers through a cut transition (issue #265): both clips during the range, the
/// incoming one's opacity rising, one decode lane per clip for the whole range, and the incoming lane pre-rolled a
/// second before the range starts.
final class PreviewCutTransitionTests: XCTestCase {
    func composition(kind: String) throws -> PreviewComposition {
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":200,"height":100,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"a","source":"a.mp4","durationFrames":100},
                   {"id":"b","kind":"video","name":"b","source":"b.mp4","durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
           {"id":"A","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":20,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"B","assetId":"b","startFrame":30,"durationFrames":30,"sourceInFrame":20,"muted":false,"effects":[],"parameterTracks":[]}],
          "transitions":[{"v":1,"id":"t","fromClipId":"A","toClipId":"B","kind":"\#(kind)","durationFrames":20,"alignment":"centre","color":"#ff0000"}]}]}}
        """#), engine: nil)
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in true })
    }

    func testADissolveDrawsBothClipsWithTheIncomingOneFadingUpOnOneLaneEach() throws {
        let comp = try composition(kind: "dissolve")
        XCTAssertEqual(comp.layers(at: 1.0).map(\.clipId), ["A"], "before the range")
        let mid = comp.layers(at: 3.0)
        XCTAssertEqual(mid.map(\.clipId), ["A", "B"], "outgoing under incoming")
        XCTAssertEqual(mid.map(\.opacity), [1, 0.5])
        XCTAssertEqual(mid[1].sourceTime(at: 2.0), 1.0, accuracy: 1e-9, "the incoming clip shows its handle before the in point")
        XCTAssertEqual(mid[0].sourceTime(at: 3.5), 5.5, accuracy: 1e-9, "the outgoing clip shows its handle past the out point")
        XCTAssertEqual(comp.layers(at: 2.05).last?.opacity ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(comp.layers(at: 4.0).map(\.clipId), ["B"], "after the range")
        XCTAssertEqual(Set([comp.layers(at: 1.0)[0].laneKey, comp.layers(at: 3.5)[0].laneKey]).count, 1, "A keeps one lane")
        XCTAssertEqual(Set([comp.layers(at: 2.5)[1].laneKey, comp.layers(at: 5.0)[0].laneKey]).count, 1, "B keeps one lane")
        XCTAssertEqual(comp.upcoming(after: 1.05, within: 0.5).map(\.clipId), ["B"], "pre-rolled a second before the range")
        XCTAssertEqual(comp.upcoming(after: 0.95, within: 0.5).map(\.clipId), [])
    }

    func testADipLaysItsColourOverEachClipTowardTheCut() throws {
        let comp = try composition(kind: "dip")
        XCTAssertEqual(comp.layers(at: 2.5).map(\.clipId), ["A"], "a dip borrows no handle")
        XCTAssertEqual(comp.layers(at: 2.5)[0].transitionColorAmount, 0.5, accuracy: 1e-9)
        XCTAssertEqual(comp.layers(at: 2.5)[0].transitionColor, CanvasColor(hex: "#ff0000"))
        XCTAssertEqual(comp.layers(at: 3.0)[0].transitionColorAmount, 1, "all colour at the cut")
        XCTAssertEqual(comp.layers(at: 4.0)[0].transitionColorAmount, 0, "the dip is over")
        let canvas = PreviewRecordingCanvas()
        PreviewPainter.draw(comp.layers(at: 2.5)[0], image: PreviewCompositorTests.solid(9, 0, 0),
                            on: canvas, frame: CanvasRect(x: 0, y: 0, width: 200, height: 100), scale: 1)
        XCTAssertEqual(canvas.ops.filter { if case .fill = $0 { return true }; return false }.count, 1, "one colour fill over the picture")
    }
}
