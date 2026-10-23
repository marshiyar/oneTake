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
import MpvfxTimeline
@testable import MpvfxPanels

final class RenderPresetTests: XCTestCase {
    func panel() -> RightPanel {
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440)
        layout.setRightTab(.renders)
        return RightPanel(layout: layout)
    }

    func testA2ApplyCopiesEverySettingAndNotifiesThePreferenceWriterOnce() {
        let panel = panel()
        var settings = RenderSettingsModel()
        settings.format = "mov"; settings.quality = "high"; settings.fps = 60
        settings.resolution = "custom"; settings.customWidth = 1280; settings.customHeight = 720
        panel.renderPresets = [.init(name: "Portrait", settings: settings)]
        var changes: [RenderSettingsModel] = []
        panel.onSettingsChanged = { changes.append($0) }
        XCTAssertTrue(panel.applyRenderPreset(named: "Portrait"))
        XCTAssertEqual(panel.settings, settings)
        XCTAssertEqual(changes, [settings])
        XCTAssertEqual(panel.presetName, "Portrait")
    }

    func testA2UnsupportedFormatIsDisabledWithAReasonAndCannotChangeSettings() throws {
        let panel = panel(), before = RenderSettingsModel()
        var unsupported = before; unsupported.format = "webm"
        panel.renderPresets = [.init(name: "Old", settings: unsupported)]
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        let rect = try XCTUnwrap(panel.hits.rect { $0 == .preset })
        _ = panel.pointerDown(CanvasPoint(rect.midX, rect.midY))
        let option = try XCTUnwrap(panel.dropdown.options.first)
        XCTAssertTrue(option.disabled)
        XCTAssertTrue(option.label.contains("webm is not supported"))
        panel.dropdown.pick("Old")
        XCTAssertEqual(panel.settings, before)
        XCTAssertFalse(panel.applyRenderPreset(named: "Old"))
        XCTAssertEqual(panel.settings, before)
        XCTAssertTrue(panel.actionError?.contains("webm is not supported") == true)
    }

    func testPresetControlsAreKeyboardReachableAndSaveUpdateAndDeleteUseTheirNames() throws {
        let panel = panel()
        panel.presetName = "Archive"
        panel.renderPresets = [.init(name: "Archive", settings: panel.settings)]
        var saved: [String] = [], deleted: [String] = []
        panel.onSavePreset = { name, _ in saved.append(name) }
        panel.onDeletePreset = { deleted.append($0) }
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        for hit in [RightPanel.Hit.preset, .presetName, .savePreset, .deletePreset] {
            var steps = 0
            while panel.focus.current != hit && steps < 30 { _ = panel.keyDown(EditorKey(.tab)); steps += 1 }
            XCTAssertEqual(panel.focus.current, hit)
            XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
            if hit == .preset { panel.dropdown.close() }
            if hit == .presetName { XCTAssertTrue(panel.keyDown(EditorKey(.enter))) }
        }
        XCTAssertEqual(saved, ["Archive"])
        XCTAssertEqual(deleted, ["Archive"])
        panel.jobs = [.init(id: "running", name: "export", status: .rendering)]
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(409, 700))
        XCTAssertNil(panel.hits.rect { $0 == .savePreset })
        XCTAssertNil(panel.hits.rect { $0 == .deletePreset })
        XCTAssertFalse(panel.applyRenderPreset(named: "Archive"))
    }
}
