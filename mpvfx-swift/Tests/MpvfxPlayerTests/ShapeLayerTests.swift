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
import MpvfxCanvas
import MpvfxShared
import XCTest

@testable import MpvfxPlayer

internal final class ShapeLayerTests: XCTestCase {
    private func document(_ shape: NativeClipShape?) throws -> NativeProjectDocument {
        var project = try PreviewCompositorTests.document()
        project.assets[0].kind = .element
        project.assets[0].source = nil
        var clip = project.sequence.tracks[2].clips[0]
        clip.shape = shape
        clip.staticParameters = [
            "layout.left": .number(20), "layout.top": .number(20), "layout.width": .number(160),
            "layout.height": .number(60),
        ]
        project.sequence.tracks = [.init(id: "shapes", kind: .video, clips: [clip])]
        return try parseNativeProjectDocument(project)
    }

    internal func testLegacyBytesAndDefaultOmission() throws {
        let project = try document(nil)
        let before = try serializeNativeProjectDocument(project)
        XCTAssertFalse(before.contains("\"shape\""))
        let reopened = try parseNativeProjectDocument(try NativeJSONValue.parse(before))
        XCTAssertEqual(try serializeNativeProjectDocument(reopened), before)
        XCTAssertEqual(project.schemaVersion, 1)
        let shape = NativeClipShape(kind: "rectangle")
        XCTAssertEqual(shape.raw, .object(["v": .number(1), "kind": .string("rectangle")]))
    }

    internal func testUnknownContractsAreOpaqueSkippedAndNoticedOnce() throws {
        for raw in [
            #"{"v":2,"kind":"rectangle","radius":{"future":true},"custom":[1,2]}"#,
            #"{"v":1,"kind":"future","strokeWidth":"future"}"#,
        ] {
            let shape = try NativeJSONValue.parse(raw).decode(NativeClipShape.self)
            let project = try document(shape)
            let reopened = try parseNativeProjectDocument(
                try NativeJSONValue.parse(serializeNativeProjectDocument(project)))
            XCTAssertEqual(reopened.sequence.tracks[0].clips[0].shape?.raw, shape.raw)
            XCTAssertTrue(PreviewCompositorTests.composition(reopened).layers(at: 0).isEmpty)
            XCTAssertEqual(reopened.undrawnContentNotices.count, 1)
            var future = reopened
            future.sequence.tracks[0].clips[0].text = NativeClipText(content: "future fallback")
            let kept = try parseNativeProjectDocument(future)
            XCTAssertTrue(PreviewCompositorTests.composition(kept).layers(at: 0).isEmpty)
            XCTAssertEqual(kept.undrawnContentNotices.count, 1)
        }
    }

    internal func testEveryBadFieldReportsTypedIssueWithoutClamping() throws {
        var shape = NativeClipShape(kind: "rectangle")
        for (key, value) in [
            ("radius", NativeJSONValue.number(-1)), ("strokeWidth", .string("bad")),
            ("endX", .number(2)), ("sides", .number(2.5)), ("fill", .string("red")),
            ("dash", .array([.number(0), .string("bad")])),
        ] { shape.raw[key] = value }
        var issues: [NativeProjectDocumentValidationIssue] = []
        validate(shape, &issues)
        XCTAssertEqual(issues.count, 7)
        XCTAssertTrue(issues.allSatisfy { $0.code == .invalidShape })
        XCTAssertThrowsError(try document(shape))
        XCTAssertThrowsError(
            try document(NativeClipShape(kind: "rectangle", radius: 31)),
            "radius exceeding half the 60px box is rejected, not clamped")
    }

    private func validate(_ shape: NativeClipShape, _ issues: inout [NativeProjectDocumentValidationIssue]) {
        do { _ = try document(shape) } catch let error as NativeProjectDocumentValidationError {
            issues = error.issues
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    internal func testDiagonalArrowHeadBisectsAlongEndTangent() throws {
        let shape = NativeClipShape(kind: "arrow", strokeWidth: 10)
        let p = NativeShapeRendering.path(shape, box: .init(x: 0, y: 0, width: 120, height: 80), scale: 1)
        guard case .move(let a) = p.elements[2], case .line(let tip) = p.elements[3], case .line(let b) = p.elements[4]
        else {
            return XCTFail("Arrow requires two wings meeting at the tip")
        }
        let dx = tip.x - (a.x + b.x) / 2
        let dy = tip.y - (a.y + b.y) / 2
        XCTAssertEqual(dx * 80 - dy * 120, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(dx * 120 + dy * 80, 0)
        XCTAssertEqual(hypot(a.x - tip.x, a.y - tip.y), hypot(b.x - tip.x, b.y - tip.y), accuracy: 1e-9)
    }

    internal func testRoundedRectangleStrokeCornerFollowsAnalyticArcWithinOnePixel() throws {
        let clip = try RasterCanvas(width: 120, height: 120)
        clip.clear(.transparent)
        let shape = NativeClipShape(
            kind: "rectangle", radius: 20, fill: "#ffffff00", stroke: "#ffffff", strokeWidth: 10)
        NativeShapeRendering.draw(
            shape, box: .init(x: 20, y: 20, width: 80, height: 80), scale: 1, opacity: 1, on: clip)
        let image = clip.image()
        // Top-left outer and inner 50% coverage contours have radius 25 and 15 about (40,40).
        // Ignore the one-pixel antialiasing band at either analytic boundary.
        for y in 16..<40 {
            for x in 16..<40 {
                let distance = hypot(Double(x) + 0.5 - 40, Double(y) + 0.5 - 40)
                let alpha = image.rgba[(y * 120 + x) * 4 + 3]
                if distance > 26 || distance < 14 { XCTAssertEqual(alpha, 0) }
                if distance > 16 && distance < 24 {
                    XCTAssertGreaterThan(alpha, 127, "pixel (\(x),\(y)), radius \(distance)")
                }
            }
        }
    }

    internal func testPreviewExportPixelsAndDashesAtTwoTimesScale() throws {
        let shape = NativeClipShape(
            kind: "rectangle", radius: 20, fill: "#22446680", stroke: "#ffffff", strokeWidth: 10, dash: [12, 8])
        let composition = PreviewCompositorTests.composition(try document(shape))
        for scale in [1.0, 2.0] {
            let w = Int(200 * scale)
            let h = Int(100 * scale)
            let canvas = try RasterCanvas(width: w, height: h)
            canvas.clear(composition.background)
            let frame = CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h))
            for layer in composition.layers(at: 0) {
                PreviewPainter.drawText(layer, on: canvas, frame: frame, scale: scale)
            }
            let export = try ExportFramePainter(composition: composition, width: w, height: h, pad: .opaqueBlack)
                .paint(time: 0) { _, _, _, _ in
                    XCTFail("Shapes must not decode media")
                    return nil
                }
            let preview = canvas.image()
            XCTAssertEqual(preview.rgba.count, export.rgba.count)
            XCTAssertLessThanOrEqual(zip(preview.rgba, export.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        }
    }

    internal func testDashLengthsScaleInExportPixels() throws {
        var shape = NativeClipShape(kind: "line", stroke: "#ffffff", strokeWidth: 4, dash: [12, 8])
        shape.raw["startY"] = .number(0.5)
        shape.raw["endY"] = .number(0.5)
        for scale in [1.0, 2.0] {
            let w = Int(200 * scale)
            let h = Int(100 * scale)
            let canvas = try RasterCanvas(width: w, height: h)
            canvas.clear(.transparent)
            NativeShapeRendering.draw(
                shape, box: .init(x: 20 * scale, y: 20 * scale, width: 160 * scale, height: 60 * scale), scale: scale,
                opacity: 1, on: canvas)
            let image = canvas.image()
            for x in [25, 45, 65] {
                XCTAssertEqual(image.rgba[(Int(50 * scale) * w + Int(Double(x) * scale)) * 4 + 3], 255)
            }
            for x in [36, 56, 76] {
                XCTAssertEqual(image.rgba[(Int(50 * scale) * w + Int(Double(x) * scale)) * 4 + 3], 0)
            }
        }
    }

    internal func testEverySupportedKindProducesAVectorPath() {
        for kind in NativeClipShape.kinds {
            XCTAssertFalse(
                NativeShapeRendering.path(
                    NativeClipShape(kind: kind), box: .init(x: 0, y: 0, width: 100, height: 100), scale: 1
                ).elements.isEmpty)
        }
    }
}
