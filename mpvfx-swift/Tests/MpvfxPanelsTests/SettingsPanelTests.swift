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
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxPanels

private func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.x + r.width / 2, r.y + r.height / 2) }

/// Issue #32: the Settings card's rows report every change; it is modal and closes on Escape or a press outside.
final class SettingsPanelTests: XCTestCase {
    func testRowsReportChangesAndTheCardIsModal() throws {
        let s = SettingsPanel()
        var changes: [SettingsPanel.Values] = [], chooses = 0
        s.onChange = { changes.append($0) }
        s.onChooseExportFolder = { chooses += 1 }
        s.devices = [.init(id: "sink.a", name: "Speakers"), .init(id: "sink.b", name: "Headset")]
        let c = PanelMeasureCanvas(), size = CanvasSize(1440, 900)
        s.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.isEmpty, "closed: nothing drawn")
        XCTAssertFalse(s.pointerDown(CanvasPoint(10, 10)), "closed: presses go to the editor")

        s.open(); s.draw(c, size: size)
        let labels: Set = ["Settings", "Appearance", "Audio output", "System default", "Preview cache", "Automatic", "Export folder", "App renders folder", "Choose…"]
        XCTAssertEqual(labels.subtracting(c.drawnStrings), [], "every row is drawn")
        XCTAssertFalse(c.drawnStrings.contains("Reset"), "no folder chosen: nothing to reset")

        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .appearance(.light) }))))
        XCTAssertEqual(changes.last?.appearance, .light)

        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .audio }))))
        XCTAssertEqual(s.dropdown.options.map(\.label), ["System default", "Speakers", "Headset"])
        s.dropdown.pick("sink.b")
        XCTAssertEqual(changes.last?.audioDevice, "sink.b")

        s.draw(c, size: size)
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .cache }))))
        XCTAssertEqual(s.dropdown.options.map(\.label), ["Automatic", "512 MB", "1 GB", "2 GB", "4 GB", "8 GB"])
        s.dropdown.pick("2048")
        XCTAssertEqual(changes.last?.previewCacheMB, 2048)

        s.draw(c, size: size)
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .chooseFolder }))))
        XCTAssertEqual(chooses, 1)
        s.exportFolderChosen("/media/exports")
        XCTAssertEqual(changes.last?.exportFolder, "/media/exports")
        c.reset(); s.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains("/media/exports"))
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .resetFolder }))))
        XCTAssertNil(changes.last?.exportFolder)
        XCTAssertEqual(changes.count, 5)
        XCTAssertEqual(s.values, SettingsPanel.Values(appearance: .light, audioDevice: "sink.b", previewCacheMB: 2048, exportFolder: nil))

        // An open list hands command shortcuts on (and closes); plain keys stay with it.
        s.draw(c, size: size)
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .cache }))))
        XCTAssertTrue(s.dropdown.isOpen)
        XCTAssertTrue(s.keyDown(EditorKey(.char("j"))))
        XCTAssertFalse(s.keyDown(EditorKey(.char(","), ctrl: true)), "Ctrl+, reaches the editor to close the card")
        XCTAssertFalse(s.dropdown.isOpen)
        XCTAssertTrue(s.isOpen)

        // Keys: plain keys stay with the card, command shortcuts pass through, Escape closes.
        XCTAssertTrue(s.keyDown(EditorKey(.char("j"))))
        XCTAssertFalse(s.keyDown(EditorKey(.char("s"), ctrl: true)))
        XCTAssertTrue(s.keyDown(EditorKey(.escape)))
        XCTAssertFalse(s.isOpen)

        // A press outside the card closes it and is not passed on.
        s.open(); s.draw(c, size: size)
        XCTAssertTrue(s.pointerDown(CanvasPoint(4, 4)))
        XCTAssertFalse(s.isOpen)
    }

    func testAChosenDeviceThatIsGoneStaysVisible() {
        let s = SettingsPanel()
        s.values.audioDevice = "sink.unplugged"
        s.open()
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(800, 600))
        XCTAssertTrue(c.drawnStrings.contains("sink.unplugged"))
        XCTAssertFalse(c.drawnStrings.contains { $0.hasPrefix("Not connected") }, "not called missing before the list arrives")
        s.devices = [.init(id: "sink.a", name: "Speakers")]
        c.reset(); s.draw(c, size: CanvasSize(800, 600))
        XCTAssertTrue(c.drawnStrings.contains("Not connected: the system default plays until it is back."))
        s.devices = [.init(id: "sink.unplugged", name: "USB Headset")]
        c.reset(); s.draw(c, size: CanvasSize(800, 600))
        XCTAssertTrue(c.drawnStrings.contains("USB Headset"))
        XCTAssertFalse(c.drawnStrings.contains { $0.hasPrefix("Not connected") })
        XCTAssertEqual(SettingsPanel.cacheLabel(1536), "1536 MB")
    }

    /// A long export folder keeps its end (the folder's own name) and drops leading components.
    func testLongExportFolderKeepsItsEnd() {
        let s = SettingsPanel()
        s.values.exportFolder = "/home/editor/Videos/Client Projects/2026/Autumn campaign/Final exports for review"
        s.open()
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(1440, 900))
        let shown = c.drawnStrings.first { $0.hasSuffix("Final exports for review") }
        XCTAssertNotNil(shown, "\(c.drawnStrings)")
        XCTAssertTrue(shown?.hasPrefix("…/") == true, shown ?? "")
        XCTAssertEqual(SettingsPanel.fitted(c, "/short", font: PanelTheme.font(11), width: 400), "/short")
    }

    /// A failed save is shown on the card until a later save succeeds.
    func testSaveErrorIsShown() {
        let s = SettingsPanel()
        s.open()
        let c = PanelMeasureCanvas(), size = CanvasSize(1440, 900)
        s.draw(c, size: size)
        let plain = s.cardRect(in: size)
        s.saveError = "Could not save settings"
        c.reset(); s.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains("Could not save settings"))
        XCTAssertGreaterThan(s.cardRect(in: size).height, plain.height, "the card grows to fit the line")
        s.saveError = nil
        c.reset(); s.draw(c, size: size)
        XCTAssertFalse(c.drawnStrings.contains("Could not save settings"))
    }
}
