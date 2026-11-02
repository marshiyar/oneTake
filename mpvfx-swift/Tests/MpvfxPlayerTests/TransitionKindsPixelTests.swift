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

final class TransitionKindsPixelTests: XCTestCase {
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
    // Forty frames puts every quarter of the range on an exact timeline frame (40...80).
    private func time(_ progress: Double) -> Double { (40 + 40 * progress) / 30 }

    func composition(_ kind: NativeCutTransitionKind,
                     configure: (inout NativeCutTransition) -> Void = { _ in }) throws -> PreviewComposition {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        var transition = doc.sequence.tracks[0].transitions![0]
        transition.kind = kind
        transition.durationFrames = 40
        configure(&transition)
        doc.sequence.tracks[0].transitions = [transition]
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
    func stage(_ comp: PreviewComposition, time: Double, patterned: Bool = false) throws -> CanvasImage {
        let cx = PreviewCompositor(decodesMedia: false); cx.composition = comp
        for layer in comp.layers(at: time) { cx.cache.store(image(layer, patterned: patterned), lane: layer.laneKey, frame: PreviewDecodeLane.stillFrame) }
        let canvas = try RasterCanvas(width: 100, height: 50)
        cx.draw(canvas, in: CanvasRect(x: 0, y: 0, width: 100, height: 50), time: time, elements: [], context: FrameDrawContext())
        return canvas.image()
    }
    private func assertParity(_ kind: NativeCutTransitionKind, file: StaticString = #filePath, line: UInt = #line) throws {
        let comp = try composition(kind)
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let preview = try stage(comp, time: time(progress))
            let export = try exported(comp, time: time(progress))
            XCTAssertEqual(preview.width, export.width, file: file, line: line)
            XCTAssertEqual(preview.height, export.height, file: file, line: line)
            let difference = zip(preview.rgba, export.rgba).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(difference, 1, "\(kind) at \(progress)", file: file, line: line)
        }
    }

    func testDissolvePreviewMatchesExportAtEveryQuarter() throws { try assertParity(.dissolve) }
    func testDipPreviewMatchesExportAtEveryQuarter() throws { try assertParity(.dip) }
    func testWipePreviewMatchesExportAtEveryQuarter() throws { try assertParity(.wipe) }
    func testPushPreviewMatchesExportAtEveryQuarter() throws { try assertParity(.push) }
    func testSlidePreviewMatchesExportAtEveryQuarter() throws { try assertParity(.slide) }
    func testIrisPreviewMatchesExportAtEveryQuarter() throws { try assertParity(.iris) }
    func testZoomThroughPreviewMatchesExportAtEveryQuarter() throws { try assertParity(.zoomThrough) }

    func testPushLeftAtHalfHasOutgoingOnLeftAndIncomingOnRight() throws {
        let frame = try exported(composition(.push), time: time(0.5))
        for x in 0..<100 {
            XCTAssertEqual(pixel(frame, x, 25), x < 50 ? [255, 0, 0, 255] : [0, 0, 255, 255], "x=\(x)")
        }
    }

    func testSlideLeftAtHalfPlacesIncomingEdgeAtHalfAndKeepsOutgoingStill() throws {
        let comp = try composition(.slide)
        let frame = try exported(comp, time: time(0.5))
        XCTAssertEqual(pixel(frame, 49, 25), [255, 0, 0, 255])
        XCTAssertEqual(pixel(frame, 50, 25), [0, 0, 255, 255])
        // A push would move A's green right half into x=25; a slide leaves its red left half there.
        let patterned = try exported(comp, time: time(0.5), patterned: true)
        XCTAssertEqual(pixel(patterned, 25, 25), [255, 0, 0, 255])
        XCTAssertEqual(pixel(patterned, 75, 25), [255, 255, 0, 255])
    }

    func testHardWipeChangesAcrossOnePixelAndSoftWipeSpansTwentyPixels() throws {
        let hard = try exported(composition(.wipe), time: time(0.5))
        XCTAssertEqual(pixel(hard, 49, 25), [255, 0, 0, 255])
        XCTAssertEqual(pixel(hard, 50, 25), [0, 0, 255, 255])
        XCTAssertFalse((0..<100).contains { let blue = pixel(hard, $0, 25)[2]; return blue > 0 && blue < 255 })

        let soft = try exported(composition(.wipe) { $0.softness = 0.2 }, time: time(0.5))
        let ramp = (0..<100).filter { let blue = pixel(soft, $0, 25)[2]; return blue > 0 && blue < 255 }
        XCTAssertEqual(Double(ramp.count), 20, accuracy: 1)
        XCTAssertEqual(ramp.first, 40)
        XCTAssertEqual(ramp.last, 59)
        for x in 40..<59 { XCTAssertLessThan(pixel(soft, x, 25)[2], pixel(soft, x + 1, 25)[2]) }
    }

    func testEaseInWipeEdgeLagsLinearAtQuarter() throws {
        let linear = try exported(composition(.wipe), time: time(0.25))
        let eased = try exported(composition(.wipe) {
            $0.ease = .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 1, y2: 1))
        }, time: time(0.25))
        let linearEdge = try XCTUnwrap((0..<100).first { pixel(linear, $0, 25)[2] == 255 })
        let easedEdge = try XCTUnwrap((0..<100).first { pixel(eased, $0, 25)[2] == 255 })
        XCTAssertEqual(linearEdge, 75)
        XCTAssertGreaterThan(easedEdge, linearEdge)
    }

    func testAngledWipeProjectsPixelCentresAcrossAllCorners() throws {
        for angle in [0.0, 45, 90, 135, 180, 225, 270, 315] {
            let comp = try composition(.wipe) { $0.angle = angle }
            let frame = try exported(comp, time: time(0.25))
            let radians = angle * .pi / 180
            let vx = cos(radians), vy = sin(radians)
            let low = min(0, vx * 100) + min(0, vy * 50)
            let travel = abs(vx) * 100 + abs(vy) * 50
            for y in 0..<50 { for x in 0..<100 {
                let q = ((Double(x) + 0.5) * vx + (Double(y) + 0.5) * vy - low) / travel
                // Avoid a floating point tie exactly on the edge at the diagonal angles.
                if abs(q - 0.25) < 1e-9 { continue }
                XCTAssertEqual(pixel(frame, x, y), q < 0.25 ? [0, 0, 255, 255] : [255, 0, 0, 255], "angle=\(angle), (\(x),\(y))")
            } }
        }
    }

    func testIrisRevealsCentreFirstAndHasExactEndpointsForBothShapes() throws {
        for shape in NativeIrisShape.allCases {
            let comp = try composition(.iris) { $0.irisShape = shape }
            let early = try exported(comp, time: time(0.25))
            XCTAssertEqual(pixel(early, 50, 25), [0, 0, 255, 255])
            for (x, y) in [(0, 0), (99, 0), (0, 49), (99, 49)] {
                XCTAssertEqual(pixel(early, x, y), [255, 0, 0, 255])
            }
            let start = try exported(comp, time: time(0))
            let end = try exported(comp, time: time(1))
            for y in 0..<50 { for x in 0..<100 {
                XCTAssertEqual(pixel(start, x, y), [255, 0, 0, 255])
                XCTAssertEqual(pixel(end, x, y), [0, 0, 255, 255])
            } }
        }
    }

    func testIrisUsesAuthoredCentreAndShape() throws {
        let circle = try exported(composition(.iris) { $0.centreX = 0.25; $0.centreY = 0.25 }, time: time(0.5))
        let rectangle = try exported(composition(.iris) {
            $0.centreX = 0.25; $0.centreY = 0.25; $0.irisShape = .rectangle
        }, time: time(0.5))
        XCTAssertEqual(pixel(circle, 25, 12), [0, 0, 255, 255])
        XCTAssertEqual(pixel(rectangle, 25, 12), [0, 0, 255, 255])
        // The circle reaches farther vertically than the rectangle in this wide frame.
        XCTAssertEqual(pixel(circle, 25, 35), [0, 0, 255, 255])
        XCTAssertEqual(pixel(rectangle, 25, 35), [255, 0, 0, 255])
    }

    func testZoomThroughScalesBothSidesAboutFrameCentreAndClipsToFrame() throws {
        let frame = CanvasRect(x: 10, y: 10, width: 100, height: 50)
        for incoming in [false, true] {
            let canvas = try RasterCanvas(width: 120, height: 70)
            canvas.clear(.transparent)
            let transition = PreviewSpatialTransition(kind: .zoomThrough, direction: .left, softness: 0,
                                                      progress: 0.25, incoming: incoming)
            PreviewPainter.drawSpatial(transition, on: canvas, frame: frame) { context, rect, _ in
                context.fillRect(CanvasRect(x: rect.x + 20, y: rect.y, width: 10, height: rect.height),
                                 CanvasColor(r: 1, g: 1, b: 1))
            }
            let result = canvas.image()
            // Outgoing scale 1.25 puts the stripe at 22.5...35; incoming scale 1.75 at 7.5...25.
            XCTAssertEqual(pixel(result, 12, 35)[3], incoming ? 255 : 0)
            XCTAssertEqual(pixel(result, 30, 35)[3], incoming ? 0 : 255)
            XCTAssertEqual(pixel(result, 8, 35)[3], 0)
            XCTAssertEqual(pixel(result, 24, 5)[3], 0)
            XCTAssertEqual(pixel(result, 24, 65)[3], 0)
        }
    }

    func testZoomThroughEndpointsPreserveExactUnscaledPictures() throws {
        let comp = try composition(.zoomThrough)
        for progress in [0.0, 1.0] {
            let sampleTime = time(progress)
            let frame = try exported(comp, time: sampleTime, patterned: true)
            let clipId = progress == 0 ? "A" : "B"
            let layer = try XCTUnwrap(comp.layers(at: sampleTime).first { $0.clipId == clipId })
            XCTAssertEqual(frame.rgba, image(layer, patterned: true).rgba, "progress=\(progress)")
        }
        // Composition supplies the incoming opacity once: halfway is an equal red/blue blend.
        let mid = pixel(try exported(comp, time: time(0.5)), 50, 25)
        XCTAssertEqual(Double(mid[0]), 128, accuracy: 1)
        XCTAssertEqual(Double(mid[2]), 128, accuracy: 1)
    }
}
