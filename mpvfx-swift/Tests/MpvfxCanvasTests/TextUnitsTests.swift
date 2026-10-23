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
#if os(Windows)
import CMpvfxWin32
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import MpvfxCanvas
import XCTest
internal final class TextUnitsTests: XCTestCase {
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

    internal func testA2CorpusNeverSplitsGraphemesAndHasExpectedWords() throws {
        try withCanvas { canvas in
            for (text, count) in corpus {
                let block = TextBlock(text: text, font: .mono(22), color: .rgba(255, 255, 255))
                let units = TextLayout.units(block, width: 380, on: canvas)
                var offset = 0
                let expected = text.map { character -> Range<Int> in
                    defer {
                        offset += String(character).utf16.count
                    }
                    return offset..<(offset + String(character).utf16.count)
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

    internal func testA3RTLUnitsStayInLogicalReadingOrderWithDescendingPositions() throws {
        try withCanvas { canvas in

            let block = TextBlock(text: "سلام دنیا", font: .mono(22), color: .rgba(255, 255, 255))
            let units = TextLayout.units(block, width: 380, on: canvas)

            XCTAssertEqual(units.clusters.map(\.range.lowerBound), units.clusters.map(\.range.lowerBound).sorted())
            XCTAssertGreaterThan(try XCTUnwrap(units.clusters.first).rect.x, try XCTUnwrap(units.clusters.last).rect.x)
            // A one-character directional run has two carets at each boundary; neither may collapse its box.

            let mixed = canvas.textUnits("aשb", font: .mono(22))

            XCTAssertEqual(mixed.count, 3)
            XCTAssertTrue(mixed.allSatisfy { $0.rect.width > 0 })
        }
    }

    internal func testSourceOffsetsSurviveRepeatedWordsWrappingBlankLinesAndSpacing() throws {
        try withCanvas { canvas in

            let block = TextBlock(text: "same same\n\nsame", font: .mono(22), color: .rgba(255, 255, 255))
            let width = canvas.measureText("same", font: block.font).width + 1
            let units = TextLayout.units(block, width: width, on: canvas)

            XCTAssertEqual(units.lines.map(\.range), [0..<4, 5..<9, 10..<10, 11..<15])
            XCTAssertEqual(units.runRanges, [0..<4, 5..<9, 11..<15])
            XCTAssertEqual(units.clusters.last?.range, 14..<15)
            XCTAssertEqual(units.words.map(\.range), [0..<4, 5..<9, 11..<15])

            let spaced = TextBlock(text: "a a", font: .mono(22), color: .rgba(255, 255, 255), letterSpacing: 2)
            let spacedUnits = TextLayout.units(spaced, width: 380, on: canvas)

            XCTAssertEqual(spacedUnits.clusters.map(\.range), [0..<1, 1..<2, 2..<3])
            XCTAssertEqual(spacedUnits.runRanges, [0..<1, 2..<3])

            let emptyBlock = TextBlock(text: "", font: block.font, color: block.color)
            let empty = TextLayout.units(emptyBlock, width: 380, on: canvas)

            XCTAssertTrue(empty.clusters.isEmpty)
            XCTAssertEqual(empty.lines.map(\.range), [0..<0])
        }
    }

    internal func testJustifiedSeparatorsHaveExpandedGapBoxes() throws {
        try withCanvas { canvas in

            let font = CanvasFont.mono(22)
            let width = canvas.measureText("a b", font: font).width + 2
            let block = TextBlock(text: "a b c", font: font, color: .rgba(255, 255, 255), align: .justify)
            let units = TextLayout.units(block, width: width, on: canvas)

            XCTAssertEqual(units.clusters.map(\.range), [0..<1, 1..<2, 2..<3, 4..<5])

            let first = try XCTUnwrap(units.clusters.first)
            let separator = try XCTUnwrap(units.clusters.first { $0.range == 1..<2 })

            let second = try XCTUnwrap(units.clusters.first { $0.range == 2..<3 })
            XCTAssertEqual(separator.rect.x, first.rect.maxX, accuracy: 1e-6)
            XCTAssertEqual(separator.rect.maxX, second.rect.x, accuracy: 1e-6)
            XCTAssertGreaterThan(separator.rect.width, canvas.measureText(" ", font: font).width)
        }
    }

    internal func testLetterSpacingIsOwnedByEveryClusterIncludingWhitespaceAndTrailingAdvance() throws {
        try withCanvas { canvas in

            let font = CanvasFont.mono(22)

            for text in ["ab", "a b", "a", "a "] {
                let block = TextBlock(text: text, font: font, color: .rgba(255, 255, 255), letterSpacing: 10)
                let units = TextLayout.units(block, width: 380, on: canvas)

                for pair in zip(units.clusters, units.clusters.dropFirst()) {
                    XCTAssertEqual(pair.0.rect.maxX, pair.1.rect.x, accuracy: 1e-6, text)
                }
                XCTAssertEqual(try XCTUnwrap(units.clusters.last).rect.maxX,
                               try XCTUnwrap(units.lines.first).rect.maxX, accuracy: 1e-6, text)
            }
        }
    }

    internal func testEmptyNativeUnitsDoNotPoisonTheNextDraw() throws {
        try withCanvas { canvas in
            XCTAssertTrue(canvas.textUnits("", font: .mono(22)).isEmpty)
            #if os(Windows)
            let native = try XCTUnwrap(canvas as? Direct2DCanvas)

            XCTAssertNil(native.drawError)
            canvas.drawText("valid", at: CanvasPoint(10, 10), font: .mono(22), color: .rgba(255, 255, 255))
            XCTAssertNil(native.drawError)
            #endif
        }
    }

    internal func testNativeWholeGraphemeBoxesMatchTheCompleteShapedAdvance() throws {
        try withCanvas { canvas in

            let font: CanvasFont = .mono(22)

            for text in ["e\u{301}", "👩‍👩‍👧‍👦", "👋🏽"] {
                let units = canvas.textUnits(text, font: font)

                XCTAssertEqual(units.count, 1)
                XCTAssertEqual(try XCTUnwrap(units.first).rect.width,
                               canvas.measureText(text, font: font).width, accuracy: 1, text)
            }
        }
    }

    internal func testA1AllUnitsEqualStaticPixelsAndSubsetActuallyHidesText() throws {
        func render(_ text: String, selected: Bool, partial: Bool = false) throws -> [UInt8] {
            let block = TextBlock(text: text, font: .mono(24), color: .rgba(255, 255, 255, 0.65))
            let box = CanvasRect(x: 10, y: 10, width: 370, height: 140)
            var pixels: [UInt8] = []

            #if os(Linux)
            let target = CairoImageTarget(width: 400, height: 160)
            let canvas: CanvasContext = target.canvas

            #elseif os(Windows)
            let target = try Direct2DImageTarget(width: 400, height: 160)
            let canvas: CanvasContext = target.canvas

            #else
            let target = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 400, height: 160))
            let canvas: CanvasContext = target

            #endif
            if selected {
                let units = TextLayout.units(block, width: box.width, on: canvas)

                let selected = partial ? Array(units.clusters.prefix(1)) : units.clusters

                TextLayout.draw(units, in: box, on: canvas, selecting: selected)
            } else {
                TextLayout.draw(block, in: box, on: canvas)
            }
            #if os(Linux)
            pixels = target.straightRGBA()
            #elseif os(Windows)
            pixels = try target.straightRGBA()
            #else
            let bytes = try XCTUnwrap(target.ctx.data)

            pixels = Array(UnsafeRawBufferPointer(start: bytes, count: target.ctx.bytesPerRow * 160))
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
