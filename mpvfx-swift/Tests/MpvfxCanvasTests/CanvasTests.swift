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
@testable import MpvfxCanvas

final class CanvasModelTests: XCTestCase {
    func testHexColors() {
        XCTAssertEqual(CanvasColor(hex: "#3CE6AC"), CanvasColor(r: 60/255, g: 230/255, b: 172/255, a: 1))
        XCTAssertEqual(CanvasColor(hex: "#FF5353FF")?.a, 1)
        XCTAssertEqual(CanvasColor(hex: "#fff"), CanvasColor(r: 1, g: 1, b: 1))
        XCTAssertNil(CanvasColor(hex: "#12"))
    }
    func testRoundedRectClampsRadius() {
        let p = CanvasPath.roundedRect(CanvasRect(x: 0, y: 0, width: 10, height: 4), radius: 50)
        XCTAssertEqual(p.elements.first, .move(CanvasPoint(2, 0)))
        XCTAssertEqual(CanvasPath.roundedRect(CanvasRect(x: 0, y: 0, width: 4, height: 4), radius: 0), .rect(CanvasRect(x: 0, y: 0, width: 4, height: 4)))
    }
}

#if os(Linux)
final class CairoCanvasTests: XCTestCase {
    func assertPixel(_ t: CairoImageTarget, _ x: Int, _ y: Int, _ e: (UInt8, UInt8, UInt8, UInt8), tol: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(x, y)
        for (a, b) in [(p.r, e.0), (p.g, e.1), (p.b, e.2), (p.a, e.3)] where abs(Int(a) - Int(b)) > tol {
            XCTFail("pixel(\(x),\(y)) = \(p) expected \(e)", file: file, line: line); return
        }
    }
    func testFillRectAndAlphaBlend() {
        let t = CairoImageTarget(width: 20, height: 20)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 20, height: 20), CanvasColor(hex: "#0A0A0B")!)
        t.canvas.fillRect(CanvasRect(x: 5, y: 5, width: 5, height: 5), .rgba(255, 255, 255, 0.5))
        assertPixel(t, 0, 0, (10, 10, 11, 255))
        assertPixel(t, 7, 7, (133, 133, 133, 255))   // 10 + (255-10)*0.5
        assertPixel(t, 12, 12, (10, 10, 11, 255))
    }
    func testRoundedRectCornersAreTransparent() {
        let t = CairoImageTarget(width: 20, height: 20)
        t.canvas.fillRoundedRect(CanvasRect(x: 0, y: 0, width: 20, height: 20), radius: 8, CanvasColor(r: 1, g: 0, b: 0))
        assertPixel(t, 0, 0, (0, 0, 0, 0))
        assertPixel(t, 10, 10, (255, 0, 0, 255))
    }
    func testStrokeClipAndTransforms() {
        let t = CairoImageTarget(width: 20, height: 20)
        t.canvas.withState {
            t.canvas.clip(CanvasRect(x: 0, y: 0, width: 10, height: 20))
            t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 20, height: 20), CanvasColor(r: 0, g: 1, b: 0))
        }
        assertPixel(t, 5, 5, (0, 255, 0, 255)); assertPixel(t, 15, 5, (0, 0, 0, 0))
        t.canvas.withState {
            t.canvas.translate(10, 10); t.canvas.scale(2, 2)
            t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 2, height: 2), CanvasColor(r: 0, g: 0, b: 1))
        }
        assertPixel(t, 13, 13, (0, 0, 255, 255)); assertPixel(t, 15, 15, (0, 0, 0, 0))
        t.canvas.stroke(.rect(CanvasRect(x: 0.5, y: 0.5, width: 19, height: 19)), CanvasColor(r: 1, g: 1, b: 1), StrokeStyle(width: 1))
        assertPixel(t, 19, 10, (255, 255, 255, 255))
    }
    func testRotate() {
        let t = CairoImageTarget(width: 20, height: 20)
        t.canvas.translate(10, 10); t.canvas.rotate(.pi / 2)
        t.canvas.fillRect(CanvasRect(x: 2, y: -1, width: 6, height: 2), CanvasColor(r: 1, g: 1, b: 1))  // +x arm -> +y after rotation
        assertPixel(t, 10, 15, (255, 255, 255, 255)); assertPixel(t, 15, 10, (0, 0, 0, 0))
    }
    func testImageDraw() {
        let img = CanvasImage(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 255, 128])
        let t = CairoImageTarget(width: 2, height: 1)
        t.canvas.drawImage(img, in: CanvasRect(x: 0, y: 0, width: 2, height: 1))
        assertPixel(t, 0, 0, (255, 0, 0, 255), tol: 4)
        let p = t.pixel(1, 0); XCTAssertGreaterThan(p.b, 200); XCTAssertEqual(Int(p.a), 128, accuracy: 6)
    }
    func testTextInksPixelsInsideItsBox() {
        let t = CairoImageTarget(width: 80, height: 20)
        t.canvas.drawText("00:00", at: CanvasPoint(5, 5), font: .mono(10), color: CanvasColor(r: 1, g: 1, b: 1))
        var inked = 0, outside = 0
        for y in 0..<20 { for x in 0..<80 where t.pixel(x, y).a > 0 { if (4..<60).contains(x) && (2..<18).contains(y) { inked += 1 } else { outside += 1 } } }
        XCTAssertGreaterThan(inked, 10); XCTAssertEqual(outside, 0)
        let m = t.canvas.measureText("00:00", font: .mono(10))
        XCTAssertGreaterThan(m.width, 20); XCTAssertLessThan(m.width, 50)
    }
}
#endif

#if os(Windows)
/// The Direct2D backend drawn into an offscreen WIC bitmap: the same pixel checks as the Cairo backend.
final class Direct2DCanvasTests: XCTestCase {
    func assertPixel(_ t: Direct2DImageTarget, _ x: Int, _ y: Int, _ e: (UInt8, UInt8, UInt8, UInt8), tol: Int = 2, file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try t.pixel(x, y)
        for (a, b) in [(p.r, e.0), (p.g, e.1), (p.b, e.2), (p.a, e.3)] where abs(Int(a) - Int(b)) > tol {
            XCTFail("pixel(\(x),\(y)) = \(p) expected \(e)", file: file, line: line); return
        }
    }
    func testFillRectAndAlphaBlend() throws {
        let t = try Direct2DImageTarget(width: 20, height: 20)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 20, height: 20), CanvasColor(hex: "#0A0A0B")!)
        t.canvas.fillRect(CanvasRect(x: 5, y: 5, width: 5, height: 5), .rgba(255, 255, 255, 0.5))
        try assertPixel(t, 0, 0, (10, 10, 11, 255))
        try assertPixel(t, 7, 7, (133, 133, 133, 255))   // 10 + (255-10)*0.5
        try assertPixel(t, 12, 12, (10, 10, 11, 255))
    }
    func testRoundedRectCornersAreTransparent() throws {
        let t = try Direct2DImageTarget(width: 20, height: 20)
        t.canvas.fillRoundedRect(CanvasRect(x: 0, y: 0, width: 20, height: 20), radius: 8, CanvasColor(r: 1, g: 0, b: 0))
        try assertPixel(t, 0, 0, (0, 0, 0, 0))
        try assertPixel(t, 10, 10, (255, 0, 0, 255))
    }
    func testStrokeClipAndTransforms() throws {
        let t = try Direct2DImageTarget(width: 20, height: 20)
        t.canvas.withState {
            t.canvas.clip(CanvasRect(x: 0, y: 0, width: 10, height: 20))
            t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 20, height: 20), CanvasColor(r: 0, g: 1, b: 0))
        }
        try assertPixel(t, 5, 5, (0, 255, 0, 255)); try assertPixel(t, 15, 5, (0, 0, 0, 0))
        t.canvas.withState {
            t.canvas.translate(10, 10); t.canvas.scale(2, 2)
            t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 2, height: 2), CanvasColor(r: 0, g: 0, b: 1))
        }
        try assertPixel(t, 13, 13, (0, 0, 255, 255)); try assertPixel(t, 15, 15, (0, 0, 0, 0))
        t.canvas.stroke(.rect(CanvasRect(x: 0.5, y: 0.5, width: 19, height: 19)), CanvasColor(r: 1, g: 1, b: 1), StrokeStyle(width: 1))
        try assertPixel(t, 19, 10, (255, 255, 255, 255))
    }
    func testRotate() throws {
        let t = try Direct2DImageTarget(width: 20, height: 20)
        t.canvas.translate(10, 10); t.canvas.rotate(.pi / 2)
        t.canvas.fillRect(CanvasRect(x: 2, y: -1, width: 6, height: 2), CanvasColor(r: 1, g: 1, b: 1))  // +x arm -> +y after rotation
        try assertPixel(t, 10, 15, (255, 255, 255, 255)); try assertPixel(t, 15, 10, (0, 0, 0, 0))
    }
    func testImageDraw() throws {
        let img = CanvasImage(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 255, 128])
        let t = try Direct2DImageTarget(width: 2, height: 1)
        t.canvas.drawImage(img, in: CanvasRect(x: 0, y: 0, width: 2, height: 1))
        try assertPixel(t, 0, 0, (255, 0, 0, 255), tol: 4)
        let p = try t.pixel(1, 0); XCTAssertGreaterThan(p.b, 200); XCTAssertEqual(Int(p.a), 128, accuracy: 6)
    }
    func testTextInksPixelsInsideItsBox() throws {
        let t = try Direct2DImageTarget(width: 80, height: 20)
        t.canvas.drawText("00:00", at: CanvasPoint(5, 5), font: .mono(10), color: CanvasColor(r: 1, g: 1, b: 1))
        let px = try t.straightRGBA()
        var inked = 0, outside = 0
        for y in 0..<20 { for x in 0..<80 where px[(y * 80 + x) * 4 + 3] > 0 { if (4..<60).contains(x) && (2..<18).contains(y) { inked += 1 } else { outside += 1 } } }
        XCTAssertGreaterThan(inked, 10); XCTAssertEqual(outside, 0)
        let m = t.canvas.measureText("00:00", font: .mono(10))
        XCTAssertGreaterThan(m.width, 20); XCTAssertLessThan(m.width, 50)
        XCTAssertNil(t.canvas.drawError)
    }
    func testDashedStrokeLeavesGaps() throws {
        let t = try Direct2DImageTarget(width: 20, height: 4)
        var p = CanvasPath(); p.move(to: CanvasPoint(0, 2)); p.line(to: CanvasPoint(20, 2))
        t.canvas.stroke(p, CanvasColor(r: 1, g: 1, b: 1), StrokeStyle(width: 2, dash: [4, 4]))
        try assertPixel(t, 2, 2, (255, 255, 255, 255)); try assertPixel(t, 6, 2, (0, 0, 0, 0)); try assertPixel(t, 10, 2, (255, 255, 255, 255))
    }
    func testPNGRoundTrip() throws {
        let t = try Direct2DImageTarget(width: 4, height: 4)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 4, height: 4), CanvasColor(r: 1, g: 0, b: 0))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-d2d-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try t.writePNG(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}
#endif
