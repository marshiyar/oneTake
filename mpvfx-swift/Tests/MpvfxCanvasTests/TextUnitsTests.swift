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
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class TextUnitsTests: XCTestCase {
    // The same corpus is compiled and run on all three platform canvases.
    private let corpus: [(String, Int)] = [
        ("Hello world", 2), ("سلام دنیا", 2), ("مرحبا عالم", 2),
        ("猫 犬", 2), ("cafe\u{301} noir", 2), ("👩‍👩‍👧‍👦 👋🏽", 0)
    ]
    private func withCanvas(_ body: (CanvasContext) throws -> Void) throws {
        #if os(Linux)
        let target = CairoImageTarget(width: 400, height: 160)
        try body(target.canvas)
        #elseif os(Windows)
        let target = try Direct2DImageTarget(width: 400, height: 160)
        try body(target.canvas)
        #else
        try body(XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 400, height: 160)))
        #endif
    }
    func testA2CorpusNeverSplitsGraphemesAndHasExpectedWords() throws {
        try withCanvas { c in
            for (text, count) in corpus {
                let b = TextBlock(text: text, font: .mono(22), color: .rgba(255,255,255))
                let units = TextLayout.units(b, width: 380, on: c)
                var offset = 0
                let expected = text.map { ch -> Range<Int> in
                    defer { offset += String(ch).utf16.count }
                    return offset..<(offset + String(ch).utf16.count)
                }
                XCTAssertEqual(units.clusters.map(\.range), expected, text)
                XCTAssertEqual(units.words.count, count, text)
                let boundaries = Set(expected.flatMap { [$0.lowerBound, $0.upperBound] })
                for unit in units.words + units.lines {
                    XCTAssertTrue(boundaries.contains(unit.range.lowerBound), text)
                    XCTAssertTrue(boundaries.contains(unit.range.upperBound), text)
                    XCTAssertTrue(unit.rect.width.isFinite && unit.rect.width >= 0, text)
                }
            }
        }
    }
    func testA3RTLUnitsStayInLogicalReadingOrderWithDescendingPositions() throws {
        try withCanvas { c in
            let b = TextBlock(text: "سلام دنیا", font: .mono(22), color: .rgba(255,255,255))
            let u = TextLayout.units(b, width: 380, on: c)
            XCTAssertEqual(u.clusters.map(\.range.lowerBound), u.clusters.map(\.range.lowerBound).sorted())
            XCTAssertGreaterThan(try XCTUnwrap(u.clusters.first).rect.x, try XCTUnwrap(u.clusters.last).rect.x)
        }
    }
    func testSourceOffsetsSurviveRepeatedWordsWrappingBlankLinesAndSpacing() throws {
        try withCanvas { c in
            let b = TextBlock(text: "same same\n\nsame", font: .mono(22), color: .rgba(255,255,255))
            let width = c.measureText("same", font: b.font).width + 1
            let u = TextLayout.units(b, width: width, on: c)
            XCTAssertEqual(u.lines.map(\.range), [0..<4, 5..<9, 10..<10, 11..<15])
            XCTAssertEqual(u.runRanges, [0..<4, 5..<9, 11..<15])
            XCTAssertEqual(u.clusters.last?.range, 14..<15)
            XCTAssertEqual(u.words.map(\.range), [0..<4, 5..<9, 11..<15])
            let spaced = TextBlock(text: "a a", font: .mono(22), color: .rgba(255,255,255), letterSpacing: 2)
            let units = TextLayout.units(spaced, width: 380, on: c)
            XCTAssertEqual(units.clusters.map(\.range), [0..<1, 1..<2, 2..<3])
            XCTAssertEqual(units.runRanges, [0..<1, 2..<3])
            let empty = TextLayout.units(TextBlock(text: "", font: b.font, color: b.color), width: 380, on: c)
            XCTAssertTrue(empty.clusters.isEmpty)
            XCTAssertEqual(empty.lines.map(\.range), [0..<0])
        }
    }

    func testA1AllUnitsEqualStaticPixelsAndSubsetActuallyHidesText() throws {
        func render(_ text: String, selected: Bool, partial: Bool = false) throws -> [UInt8] {
            let b = TextBlock(text: text, font: .mono(24), color: .rgba(255,255,255,0.65))
            let box = CanvasRect(x: 10, y: 10, width: 370, height: 140)
            var pixels: [UInt8] = []
            #if os(Linux)
            let t = CairoImageTarget(width: 400, height: 160)
            let c: CanvasContext = t.canvas
            #elseif os(Windows)
            let t = try Direct2DImageTarget(width: 400, height: 160)
            let c: CanvasContext = t.canvas
            #else
            let t = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 400, height: 160))
            let c: CanvasContext = t
            #endif
            if selected {
                let units = TextLayout.units(b, width: box.width, on: c)
                TextLayout.draw(units, in: box, on: c, selecting: partial ? Array(units.clusters.prefix(1)) : units.clusters)
            } else { TextLayout.draw(b, in: box, on: c) }
            #if os(Linux)
            pixels = t.straightRGBA()
            #elseif os(Windows)
            pixels = try t.straightRGBA()
            #else
            let bytes = try XCTUnwrap(t.ctx.data)
            pixels = Array(UnsafeRawBufferPointer(start: bytes, count: t.ctx.bytesPerRow * 160))
            #endif
            return pixels
        }
        for (text, _) in corpus + [("office AV\nsecond line", 4)] {
            let plain = try render(text, selected: false)
            XCTAssertTrue(plain.contains { $0 != 0 }, text)
            XCTAssertEqual(plain, try render(text, selected: true), text)
        }
        let full = try render("ABC", selected: true)
        let partial = try render("ABC", selected: true, partial: true)
        XCTAssertNotEqual(full, partial)
        XCTAssertTrue(partial.contains { $0 != 0 })
    }
}
