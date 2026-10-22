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

final class VoiceSettingsTests: XCTestCase {
    func testInputAndCountInCanBeChosenFromKeyboardAndFitACompactCard() throws {
        let panel = SettingsPanel(), canvas = PanelMeasureCanvas(), size = CanvasSize(640, 400)
        panel.inputDevices = [.init(id: "mic", name: "Microphone")]
        var changes = [SettingsPanel.Values]()
        panel.onChange = { changes.append($0) }
        panel.open(); panel.draw(canvas, size: size)
        XCTAssertLessThanOrEqual(panel.cardRect(in: size).maxY, size.height)
        panel.focus.current = .input
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        panel.dropdown.pick("mic")
        XCTAssertEqual(changes.last?.inputDevice, "mic")
        panel.draw(canvas, size: size)
        panel.focus.current = .countIn
        XCTAssertTrue(panel.keyDown(EditorKey(.space)))
        XCTAssertEqual(panel.dropdown.options.map(\.value), ["0", "1", "2", "3", "4", "5"])
        panel.dropdown.pick("0")
        XCTAssertEqual(changes.last?.voiceCountIn, 0)
    }
}
