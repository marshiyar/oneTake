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
import MpvfxTimeline
@testable import MpvfxPanels

final class CaptionSettingsTests: XCTestCase {
    func testCaptionReadingRateCanBeChosenFromKeyboardAndFitsTheCompactCard() throws {
        let panel = SettingsPanel(), canvas = PanelMeasureCanvas(), size = CanvasSize(640, 400)
        var changes = [SettingsPanel.Values]()
        panel.onChange = { changes.append($0) }
        panel.open(); panel.draw(canvas, size: size)
        XCTAssertEqual(panel.values.captionReadingRate, 17)
        XCTAssertLessThanOrEqual(panel.cardRect(in: size).maxY, size.height)
        panel.focus.current = .readingRate
        XCTAssertTrue(panel.keyDown(EditorKey(.space)))
        XCTAssertEqual(panel.dropdown.options.map(\.value), (5...40).map { String($0) })
        XCTAssertEqual(panel.dropdown.options[20].label, "25 characters/s")
        panel.dropdown.pick("25")
        XCTAssertEqual(changes.last?.captionReadingRate, 25)
    }
}
