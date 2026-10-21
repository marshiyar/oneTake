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
import MpvfxCanvas
import MpvfxShared
@testable import MpvfxPlayer

final class SpatialTransitionPixelTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":100,"height":50,"background":"#000000"},
     "assets":[{"id":"a1","kind":"image","name":"Interview 1","source":"a.png","width":100,"height":50,"durationFrames":300},
               {"id":"a2","kind":"image","name":"Interview 2","source":"b.png","width":100,"height":50,"durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}],
      "transitions":[{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30,"alignment":"centre"}]}]}}
    """#
    func composition(_ kind: NativeCutTransitionKind, direction: NativeTransitionDirection = .left, softness: Double = 0, color: String = "#000000") throws -> PreviewComposition {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        var t = doc.sequence.tracks[0].transitions![0]
        t.kind = kind; t.direction = direction; t.softness = softness; t.color = color
        doc.sequence.tracks[0].transitions = [t]
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/project"), engine: nil, fileExists: { _ in true })
    }
    func image(_ layer: PreviewLayer, patterned: Bool = false) -> CanvasImage {
        var rgba = [UInt8](repeating: 255, count: 100 * 50 * 4)
        for y in 0..<50 { for x in 0..<100 {
            let color: [UInt8]
            if patterned { color = layer.clipId == "A" ? (x < 50 ? [255, 0, 0] : [0, 255, 0]) : (x < 50 ? [255, 255, 0] : [0, 0, 255]) }
            else { color = layer.clipId == "A" ? [255, 0, 0] : [0, 0, 255] }
            let i = (y * 100 + x) * 4
            for channel in 0..<3 { rgba[i + channel] = color[channel] }
        } }
        return CanvasImage(width: 100, height: 50, rgba: rgba)
    }
    func pixel(_ image: CanvasImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * image.width + x) * 4; return Array(image.rgba[i..<i + 4])
    }
    func exported(_ comp: PreviewComposition, time: Double = 2, patterned: Bool = false) throws -> CanvasImage {
        try ExportFramePainter(composition: comp, width: 100, height: 50, pad: .transparent).paint(time: time) { layer, _, _, _ in self.image(layer, patterned: patterned) }
    }
    func stage(_ comp: PreviewComposition, time: Double) throws -> CanvasImage {
        let cx = PreviewCompositor(decodesMedia: false); cx.composition = comp
        for layer in comp.layers(at: time) { cx.cache.store(image(layer), lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame) }
        let canvas = try RasterCanvas(width: 100, height: 50)
        cx.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 100, height: 50), time: time, elements: [], context: FrameDrawContext())
        return canvas.image()
    }
    func testWipePixelsRevealIncomingPictureFromAllFourDirections() throws {
        for direction in NativeTransitionDirection.allCases {
            let frame = try exported(composition(.wipe, direction: direction))
            let newPoint: (Int, Int), oldPoint: (Int, Int)
            switch direction {
            case .left: newPoint = (75, 25); oldPoint = (25, 25)
            case .right: newPoint = (25, 25); oldPoint = (75, 25)
            case .up: newPoint = (50, 37); oldPoint = (50, 12)
            case .down: newPoint = (50, 12); oldPoint = (50, 37)
            }
            XCTAssertEqual(pixel(frame, newPoint.0, newPoint.1), [0, 0, 255, 255], "\(direction)")
            XCTAssertEqual(pixel(frame, oldPoint.0, oldPoint.1), [255, 0, 0, 255], "\(direction)")
        }
    }
    func testSoftWipeBlendsAdvancingEdgeAndPreservesExactEndpoints() throws {
        let comp = try composition(.wipe, softness: 0.5)
        let mid = try exported(comp), edge = pixel(mid, 50, 25)
        XCTAssertTrue(edge[0] > 80 && edge[0] < 180); XCTAssertTrue(edge[2] > 80 && edge[2] < 180)
        XCTAssertEqual(pixel(mid, 0, 25), [255, 0, 0, 255]); XCTAssertEqual(pixel(mid, 99, 25), [0, 0, 255, 255])
        XCTAssertEqual(pixel(try exported(comp, time: 1.5), 99, 25), [255, 0, 0, 255])
        XCTAssertEqual(pixel(try exported(comp, time: 2.5), 0, 25), [0, 0, 255, 255])
    }
    func testPushMovesBothPicturesAndLeavesNoGapInEachDirection() throws {
        let mid = try exported(composition(.push), patterned: true)
        XCTAssertEqual(pixel(mid, 25, 25), [0, 255, 0, 255])
        XCTAssertEqual(pixel(mid, 75, 25), [255, 255, 0, 255])
        for direction in NativeTransitionDirection.allCases {
            let frame = try exported(composition(.push, direction: direction))
            XCTAssertTrue(stride(from: 3, to: frame.rgba.count, by: 4).allSatisfy { frame.rgba[$0] == 255 })
        }
    }
    func testDipBlackAndWhiteReachChosenPixelColorAtCut() throws {
        for (color, expected) in [("#000000", [UInt8](arrayLiteral: 0, 0, 0, 255)), ("#ffffff", [UInt8](arrayLiteral: 255, 255, 255, 255))] {
            XCTAssertEqual(pixel(try exported(composition(.dip, color: color)), 50, 25), expected)
        }
    }
    func testPreviewEqualsExportForEveryKindDirectionAndEndpoint() throws {
        for kind in [NativeCutTransitionKind.wipe, .push, .dip] {
            for direction in NativeTransitionDirection.allCases {
                let comp = try composition(kind, direction: direction, softness: 0.4, color: "#ffffff")
                for time in [1.5, 1.75, 2, 2.25, 2.5] {
                    XCTAssertEqual(try stage(comp, time: time).rgba, try exported(comp, time: time).rgba, "\(kind) \(direction) \(time)")
                }
            }
        }
    }
}
