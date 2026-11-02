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
// Issue #325: a line, arrow or outline reveals along its path over the length of an In "draw" move. A1: at 50% exactly
// half the path length is drawn (±1 px of arc length). A2: preview and export draw the same pixels.
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxPlayer

internal final class ShapeDrawOnTests: XCTestCase {
    private func length(_ path: CanvasPath) -> Double { NativeShapeDrawOn.length(path) }
    private let box = CanvasRect(x: 0, y: 0, width: 120, height: 80)

    internal func testA1HalfWayDrawsExactlyHalfThePathLengthOfEveryStrokedKind() {
        for shape in [
            NativeClipShape(kind: "line"), NativeClipShape(kind: "arrow"),
            NativeClipShape(kind: "rectangle"), NativeClipShape(kind: "rectangle", radius: 20),
            NativeClipShape(kind: "ellipse"), NativeClipShape(kind: "triangle"), NativeClipShape(kind: "star"),
        ] {
            let path = NativeShapeRendering.path(shape, box: box, scale: 1)
            let whole = length(path)
            XCTAssertGreaterThan(whole, 100, shape.kind)
            for fraction in [0.25, 0.5, 0.9] {
                let drawn = length(NativeShapeDrawOn.trimmed(path, fraction: fraction))
                XCTAssertEqual(drawn, whole * fraction, accuracy: 1, "\(shape.kind) at \(fraction)")
            }
        }
    }

    internal func testA1ALineRevealsFromItsStartAndAnArrowDrawsItsHeadLast() {
        let line = NativeShapeRendering.path(NativeClipShape(kind: "line"), box: box, scale: 1)
        guard case .line(let end) = NativeShapeDrawOn.trimmed(line, fraction: 0.5).elements.last else {
            return XCTFail("A half-drawn line ends in a line segment")
        }
        XCTAssertEqual(end.x, 60, accuracy: 1e-9); XCTAssertEqual(end.y, 40, accuracy: 1e-9, "the diagonal's midpoint")
        let arrow = NativeShapeRendering.path(NativeClipShape(kind: "arrow"), box: box, scale: 1)
        let shaft = hypot(120.0, 80.0)
        let almost = NativeShapeDrawOn.trimmed(arrow, fraction: shaft / length(arrow) * 0.99)
        XCTAssertEqual(almost.elements.count, 2, "still only the shaft before the shaft is complete")
        XCTAssertGreaterThan(NativeShapeDrawOn.trimmed(arrow, fraction: 0.999).elements.count, 2, "the head wings follow the shaft")
    }

    internal func testNothingBeforeTheStartAndTheOriginalPathAtTheEnd() {
        let path = NativeShapeRendering.path(NativeClipShape(kind: "ellipse"), box: box, scale: 1)
        XCTAssertTrue(NativeShapeDrawOn.trimmed(path, fraction: 0).elements.isEmpty)
        XCTAssertTrue(NativeShapeDrawOn.trimmed(path, fraction: -1).elements.isEmpty)
        XCTAssertEqual(NativeShapeDrawOn.trimmed(path, fraction: 1), path, "fully drawn keeps the exact curves")
        XCTAssertEqual(NativeShapeDrawOn.trimmed(path, fraction: 3), path)
    }

    internal func testHalfDrawnLineInksOnlyItsFirstHalfOnTheRaster() throws {
        var shape = NativeClipShape(kind: "line", stroke: "#ffffff", strokeWidth: 4)
        shape.raw["startY"] = .number(0.5); shape.raw["endY"] = .number(0.5)
        let canvas = try RasterCanvas(width: 200, height: 100)
        canvas.clear(.transparent)
        NativeShapeRendering.draw(
            shape, box: .init(x: 20, y: 20, width: 160, height: 60), scale: 1, opacity: 1, drawProgress: 0.5, on: canvas)
        let image = canvas.image()
        func alpha(_ x: Int) -> UInt8 { image.rgba[(50 * 200 + x) * 4 + 3] }
        for x in [22, 60, 98] { XCTAssertEqual(alpha(x), 255, "x \(x) is inside the drawn half") }
        for x in [104, 140, 178] { XCTAssertEqual(alpha(x), 0, "x \(x) is not drawn yet") }
    }

    // MARK: A2 preview and export

    private func document(moves: String) throws -> (NativeProjectDocument, KeyframeEngine) {
        let engine = try KeyframeRuntime()
        var project = try PreviewCompositorTests.document()
        project.assets[0].kind = .element
        project.assets[0].source = nil
        var clip = project.sequence.tracks[2].clips[0]
        var shape = NativeClipShape(kind: "arrow", stroke: "#ffffff", strokeWidth: 6)
        shape.raw["startY"] = .number(0.5); shape.raw["endY"] = .number(0.5)
        clip.shape = shape
        clip.staticParameters = [
            "layout.left": .number(20), "layout.top": .number(20), "layout.width": .number(160), "layout.height": .number(60),
        ]
        clip.moves = try NativeJSONValue.parse(moves).decode(NativeClipMoves.self)
        project.sequence.tracks = [.init(id: "shapes", kind: .video, clips: [clip])]
        return (try parseNativeProjectDocument(project, engine: engine), engine)
    }

    internal func testA2LayerCarriesTheDrawProgressAndPreviewEqualsExportAtTwoScales() throws {
        let (doc, engine) = try document(moves: #"{"v":1,"in":{"kind":"draw","frames":10,"ease":{"type":"linear"}}}"#)
        let composition = PreviewComposition(
            document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: engine, fileExists: { _ in true })
        // The project runs at 10 fps: frame 5 is 0.5 s.
        let half = try XCTUnwrap(composition.layers(at: 0.5).first)
        XCTAssertEqual(half.drawProgress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.opacity, 1, "draw-on does not fade the layer")
        XCTAssertEqual(try XCTUnwrap(composition.layers(at: 1.0).first).drawProgress, 1)
        var inked = [Int]()
        for scale in [1.0, 2.0] {
            let w = Int(200 * scale), h = Int(100 * scale)
            let canvas = try RasterCanvas(width: w, height: h)
            canvas.clear(composition.background)
            let frame = CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h))
            for layer in composition.layers(at: 0.5) { PreviewPainter.drawText(layer, on: canvas, frame: frame, scale: scale) }
            let export = try ExportFramePainter(composition: composition, width: w, height: h, pad: .opaqueBlack)
                .paint(time: 0.5) { _, _, _, _ in
                    XCTFail("Shapes must not decode media")
                    return nil
                }
            let preview = canvas.image()
            XCTAssertLessThanOrEqual(zip(preview.rgba, export.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1, "scale \(scale)")
            // The row through the arrow's shaft: white up to half way (x = 100 at 1x) and the background after it.
            let row = Int(50 * scale) * w
            func white(_ x: Int) -> Bool { export.rgba[(row + Int(Double(x) * scale)) * 4] > 200 }
            XCTAssertTrue(white(60)); XCTAssertFalse(white(140))
            inked.append((0..<w).filter { export.rgba[(row + $0) * 4] > 200 }.count)
        }
        XCTAssertEqual(Double(inked[1]), 2 * Double(inked[0]), accuracy: 6, "the drawn length scales with the export size")
    }
}
