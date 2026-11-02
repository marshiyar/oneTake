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
import Foundation
import XCTest
import MpvfxCanvas
@testable import MpvfxPanels

/// Draws once on the deterministic measuring canvas so hit regions exist, then returns the centre of a region.
private func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.x + r.width / 2, r.y + r.height / 2) }

/// Renders tab Loudness (#315): Off hides the true-peak ceiling; a target shows it, and picking a value stores it.
final class RenderLoudnessSettingsTests: XCTestCase {
    func panel() -> RightPanel {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        return RightPanel(layout: layout)
    }

    func testLoudnessIsDrawnAndTheCeilingIsHiddenWhileOff() {
        let panel = panel()
        let c = PanelMeasureCanvas()
        panel.draw(c, size: CanvasSize(409, 700))
        XCTAssertNotNil(panel.hits.rect { $0 == .loudness })
        XCTAssertTrue(c.drawnStrings.contains("Loudness"))
        XCTAssertNil(panel.hits.rect { $0 == .truePeak })
        XCTAssertFalse(c.drawnStrings.contains("True-peak ceiling"))
    }

    func testLoudnessOffersTheTargetsAndPickingOneStoresItAndShowsTheCeiling() throws {
        let panel = panel()
        var changes: [RenderSettingsModel] = []
        panel.onSettingsChanged = { changes.append($0) }
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        _ = panel.pointerDown(center(try XCTUnwrap(panel.hits.rect { $0 == .loudness })))
        XCTAssertTrue(panel.dropdown.isOpen)
        XCTAssertEqual(panel.dropdown.options.map(\.value), ["off", "-14", "-16", "-18", "-23", "-24"])
        panel.dropdown.pick("-23")
        XCTAssertEqual(panel.settings.loudness, -23)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.last?.loudness, -23)
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertNotNil(panel.hits.rect { $0 == .truePeak }, "a target shows the true-peak ceiling beside Loudness")
    }

    func testTruePeakCeilingPicksAValueAndNotifiesOnce() throws {
        let panel = panel()
        panel.settings.loudness = -23
        var changes: [RenderSettingsModel] = []
        panel.onSettingsChanged = { changes.append($0) }
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        _ = panel.pointerDown(center(try XCTUnwrap(panel.hits.rect { $0 == .truePeak })))
        XCTAssertTrue(panel.dropdown.isOpen)
        XCTAssertEqual(panel.dropdown.options.map(\.value), ["-0.5", "-1.0", "-1.5", "-2.0", "-3.0"])
        panel.dropdown.pick("-2.0")
        XCTAssertEqual(panel.settings.truePeak, -2)
        XCTAssertEqual(panel.settings.loudness, -23, "picking a ceiling leaves the target as it is")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.last?.truePeak, -2)
    }

    func testPickingOffClearsTheTargetAndHidesTheCeiling() throws {
        let panel = panel()
        panel.settings.loudness = -16
        var changes: [RenderSettingsModel] = []
        panel.onSettingsChanged = { changes.append($0) }
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        _ = panel.pointerDown(center(try XCTUnwrap(panel.hits.rect { $0 == .loudness })))
        panel.dropdown.pick("off")
        XCTAssertNil(panel.settings.loudness)
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes.last?.loudness)
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertNil(panel.hits.rect { $0 == .truePeak })
    }

    func testSettingsSavedBeforeLoudnessExistedDecodeAsOff() throws {
        let saved = #"{"format":"mov","quality":"high","fps":60,"resolution":"1080p","customWidth":1920,"customHeight":1080}"#
        let settings = try JSONDecoder().decode(RenderSettingsModel.self, from: Data(saved.utf8))
        XCTAssertEqual(settings.format, "mov")
        XCTAssertNil(settings.loudness)
        XCTAssertNil(settings.truePeak)
    }

    func testLoudnessSettingsRoundTripThroughCodable() throws {
        var settings = RenderSettingsModel()
        settings.loudness = -16; settings.truePeak = -2
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(RenderSettingsModel.self, from: data), settings)
        let off = try JSONEncoder().encode(RenderSettingsModel())
        let object = try JSONSerialization.jsonObject(with: off) as? [String: Any]
        XCTAssertNil(object?["loudness"], "Off encodes no loudness key")
        XCTAssertNil(object?["truePeak"])
    }
}
