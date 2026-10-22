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
@testable import MpvfxShared

final class NativeGridLayoutTests: XCTestCase {
    func rects(_ layout: NativeGridLayout, _ w: Double, _ h: Double) throws -> [[Double]] {
        try nativeGridCells(layout, width: w, height: h, options: .init(gutter: 12, margin: 30)).map {
            [$0.left, $0.top, $0.width, $0.height]
        }
    }

    func testA1LandscapeCellsMatchTheGutterAndMarginTable() throws {
        XCTAssertEqual(try rects(.sideBySide, 1920, 1080), [[30,30,924,1020], [966,30,924,1020]])
        XCTAssertEqual(try rects(.stacked, 1920, 1080), [[30,30,1860,504], [30,546,1860,504]])
        XCTAssertEqual(try rects(.threeUp, 1920, 1080), [[30,30,612,1020], [654,30,612,1020], [1278,30,612,1020]])
        XCTAssertEqual(try rects(.grid2x2, 1920, 1080), [[30,30,924,504], [966,30,924,504], [30,546,924,504], [966,546,924,504]])
        XCTAssertEqual(try rects(.largeLeft, 1920, 1080), [[30,30,1232,1020], [1274,30,616,504], [1274,546,616,504]])
        XCTAssertEqual(try rects(.pictureInPicture, 1920, 1080), [[30,30,1860,1020], [1314,726,576,324]])
    }

    func testA1PortraitCellsMatchTheGutterAndMarginTable() throws {
        XCTAssertEqual(try rects(.sideBySide, 1080, 1920), [[30,30,504,1860], [546,30,504,1860]])
        XCTAssertEqual(try rects(.stacked, 1080, 1920), [[30,30,1020,924], [30,966,1020,924]])
        XCTAssertEqual(try rects(.threeUp, 1080, 1920), [[30,30,332,1860], [374,30,332,1860], [718,30,332,1860]])
        XCTAssertEqual(try rects(.grid2x2, 1080, 1920), [[30,30,504,924], [546,30,504,924], [30,966,504,924], [546,966,504,924]])
        XCTAssertEqual(try rects(.largeLeft, 1080, 1920), [[30,30,672,1860], [714,30,336,924], [714,966,336,924]])
        XCTAssertEqual(try rects(.pictureInPicture, 1080, 1920), [[30,30,1020,1860], [726,1314,324,576]])
    }

    func testPiPCornersAndImpossibleGeometry() throws {
        let origins: [(NativeGridCorner, Double, Double)] = [(.topLeft,30,30), (.topRight,1314,30), (.bottomLeft,30,726), (.bottomRight,1314,726)]
        for (corner, x, y) in origins {
            let cells = try nativeGridCells(.pictureInPicture, width: 1920, height: 1080, options: .init(margin: 30, corner: corner))
            XCTAssertEqual(cells[1].left, x); XCTAssertEqual(cells[1].top, y)
        }
        for layout in NativeGridLayout.allCases {
            XCTAssertThrowsError(try nativeGridCells(layout, width: .nan, height: 1080))
            XCTAssertThrowsError(try nativeGridCells(layout, width: 1920, height: 1080, options: .init(margin: 1000)))
        }
        XCTAssertThrowsError(try nativeGridCells(.sideBySide, width: 100, height: 100, options: .init(gutter: 100)))
    }

    func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J("""
        {"schemaVersion":1,"id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"i","kind":"image","name":"i","source":"i.png","durationFrames":1}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"v","kind":"video","clips":[
         {"id":"a","assetId":"i","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[],
          "crop":{"top":10,"left":10,"right":0,"bottom":0},"staticParameters":{"transform.scale":2,"transform.position.x":40,"transform.rotation":30}},
         {"id":"b","assetId":"i","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """), engine: KeyframeEngineStandIn())
    }

    func testA2OrderedLayersOccupyTheirCellsAndPersistUsingExistingFields() throws {
        let before = try document()
        let next = try planNativeGridLayout(before, clipIds: ["b","a"], layout: .sideBySide, frame: 10,
                                            options: .init(gutter: 12, margin: 30, fit: .fill), engine: KeyframeEngineStandIn())
        let clips = next.sequence.tracks[0].clips
        XCTAssertEqual(clips[0].staticParameters?["layout.left"], .number(966))
        XCTAssertEqual(clips[1].staticParameters?["layout.left"], .number(30))
        for clip in clips {
            XCTAssertEqual(clip.staticParameters?["layout.width"], .number(924))
            XCTAssertEqual(clip.staticParameters?["layout.height"], .number(1020))
            XCTAssertEqual(clip.staticParameters?["transform.position"], .vec2(.init(x: 0, y: 0)))
            XCTAssertEqual(clip.staticParameters?["transform.rotation"], .number(0))
            XCTAssertNil(clip.crop); XCTAssertEqual(clip.fit, .fill)
        }
        XCTAssertEqual(clips[0].staticParameters?["transform.scale"], .number(1))
        XCTAssertEqual(clips[0].staticParameters?["transform.position.x"], .number(0))
        XCTAssertEqual(try parseNativeProjectDocument(next, engine: KeyframeEngineStandIn()), next)
        XCTAssertNotNil(before.sequence.tracks[0].clips[0].crop)
    }

    func testA3TooManyLayersReportsBothCountsAndChangesNothing() throws {
        let before = try document(), saved = before
        XCTAssertThrowsError(try planNativeGridLayout(before, clipIds: ["a","b","c"], layout: .sideBySide, frame: 10)) {
            XCTAssertEqual($0 as? NativeGridFailure, .tooManyLayers(selected: 3, cells: 2))
        }
        XCTAssertEqual(before, saved)
    }

    func testLockedDuplicateMissingAndOffClipSelectionsAreRefused() throws {
        var d = try document()
        d.sequence.tracks[0].locked = true
        XCTAssertThrowsError(try planNativeGridLayout(d, clipIds: ["a"], layout: .stacked, frame: 10))
        d.sequence.tracks[0].locked = false
        for ids in [["a","a"], ["missing"], []] {
            XCTAssertThrowsError(try planNativeGridLayout(d, clipIds: ids, layout: .stacked, frame: 10))
        }
        XCTAssertThrowsError(try planNativeGridLayout(d, clipIds: ["a"], layout: .stacked, frame: 100))
    }

    func testAnimatedWidthGetsAKeyAtThePlayheadAndKeepsEarlierKeys() throws {
        let engine = KeyframeEngineStandIn(), d = try document()
        let address = NativeProjectParameterAddress(sequenceId: "s", trackId: "v", clipId: "a", parameterId: "layout.width")
        let seeded = try applyNativeProjectPropertyCommand(d, .atomic(.keyframe(.upsert(address: address, valueType: .number,
            frame: 0, value: .number(800), baselineValue: .number(800)))), engine: engine).document
        let next = try planNativeGridLayout(seeded, clipIds: ["a"], layout: .sideBySide, frame: 10, engine: engine)
        let track = try XCTUnwrap(next.sequence.tracks[0].clips[0].parameterTracks.first { $0.parameterId == "layout.width" })
        XCTAssertEqual(track.keyframes.first { $0.frame == 0 }?.value, .number(800))
        XCTAssertEqual(track.keyframes.first { $0.frame == 10 }?.value, .number(960))
    }
}
