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

/// Issue #104: every control on the Settings card works from the keyboard (WCAG 2.1.1, 2.4.3, 2.4.7).
final class SettingsPanelKeyboardTests: XCTestCase {
    let size = CanvasSize(1440, 900)
    static let twoDevices: [SettingsPanel.Device] = [.init(id: "sink.a", name: "Speakers"),
                                                     .init(id: "sink.b", name: "Headset")]

    func openCard(devices: [SettingsPanel.Device] = SettingsPanelKeyboardTests.twoDevices)
        -> (SettingsPanel, PanelMeasureCanvas) {
        let s = SettingsPanel()
        s.devices = devices
        s.open()
        let c = PanelMeasureCanvas()
        s.draw(c, size: size)
        return (s, c)
    }

    /// Sends `k` and redraws, as the host does after every key the card took.
    @discardableResult
    func press(_ s: SettingsPanel, _ c: PanelMeasureCanvas, _ k: EditorKey) -> Bool {
        let taken = s.keyDown(k)
        s.draw(c, size: size)
        return taken
    }

    /// Acceptance 1: the card opens on its first control with the ring shown; Tab and ⇧Tab cycle inside the modal.
    func testOpeningFocusesTheFirstControlAndTabCyclesInsideTheCard() throws {
        let s = SettingsPanel()
        s.values.exportFolder = "/media/exports"   // Reset is shown, and is a stop
        s.devices = [.init(id: "sink.a", name: "Speakers")]
        s.onOpen = { [unowned s] in s.values.appearance = .dark }   // the host refreshes the values as the card opens
        s.open()
        let c = PanelMeasureCanvas()
        s.draw(c, size: size)
        XCTAssertEqual(s.focus.current, .appearance(.dark), "the chosen appearance segment, read after onOpen")
        XCTAssertTrue(s.focus.visible)
        XCTAssertEqual(s.focus.ringRect(s.hits), s.hits.rect { $0 == .appearance(.dark) }, "the ring is drawn on it")

        let forward: [SettingsPanel.Hit] = [.audio, .cache, .chooseFolder, .resetFolder, .close,
                                            .appearance(.dark), .audio]   // past Close, round to the first control
        for want in forward {
            XCTAssertTrue(press(s, c, EditorKey(.tab)), "Tab is taken by the modal card")
            XCTAssertEqual(s.focus.current, want)
            XCTAssertTrue(s.focus.visible)
        }
        let backward: [SettingsPanel.Hit] = [.appearance(.dark), .close, .resetFolder]
        for want in backward {
            XCTAssertTrue(press(s, c, EditorKey(.tab, shift: true)))
            XCTAssertEqual(s.focus.current, want)
        }
        XCTAssertTrue(s.isOpen)

        // No device to choose: the disabled audio field is skipped.
        let (bare, bareCanvas) = openCard(devices: [])
        XCTAssertTrue(press(bare, bareCanvas, EditorKey(.tab)))
        XCTAssertEqual(bare.focus.current, .cache)

        // A pointer press hides the ring; reopening starts on the first control again.
        let cache = try XCTUnwrap(s.hits.rect { $0 == .cache })
        XCTAssertTrue(s.pointerDown(center(cache)))
        XCTAssertFalse(s.focus.visible)
        XCTAssertNil(s.focus.ringRect(s.hits))
        s.close()
        XCTAssertNil(s.focus.current)
        s.onOpen = nil
        s.values.appearance = .light
        s.open(); s.draw(c, size: size)
        XCTAssertEqual(s.focus.current, .appearance(.light))
        XCTAssertTrue(s.focus.visible)
    }

    /// Acceptance 2: Left and Right move to and apply the neighbouring System / Light / Dark segment.
    func testLeftAndRightMoveAndApplyTheFocusedSegment() {
        let (s, c) = openCard()
        var applied: [ThemeAppearance] = []
        s.onChange = { applied.append($0.appearance) }
        XCTAssertEqual(s.focus.current, .appearance(.system))
        XCTAssertTrue(press(s, c, EditorKey(.right)))
        XCTAssertEqual(s.values.appearance, .light)
        XCTAssertEqual(s.focus.current, .appearance(.light), "focus moves with the choice")
        XCTAssertTrue(press(s, c, EditorKey(.right)))
        XCTAssertTrue(press(s, c, EditorKey(.right)), "the end holds")
        XCTAssertEqual(s.values.appearance, .dark)
        XCTAssertTrue(press(s, c, EditorKey(.left)))
        XCTAssertEqual(applied, [.light, .dark, .light], "each move applies once; holding at the end applies nothing")
        XCTAssertEqual(s.focus.ringRect(s.hits), s.hits.rect { $0 == .appearance(.light) })

        // The segments are one Tab stop; arrows on another control change nothing.
        XCTAssertTrue(press(s, c, EditorKey(.tab)))
        XCTAssertEqual(s.focus.current, .audio)
        XCTAssertTrue(press(s, c, EditorKey(.right)))
        XCTAssertEqual(s.values.appearance, .light)
        XCTAssertEqual(applied.count, 3)
    }

    /// Acceptance 3: Enter or Space opens the audio and cache lists, arrows choose, Enter commits (`dropdown.key`).
    func testEnterOrSpaceOpensTheListsArrowsChooseAndEnterCommits() {
        let (s, c) = openCard()
        var changes: [SettingsPanel.Values] = []
        s.onChange = { changes.append($0) }

        press(s, c, EditorKey(.tab))
        XCTAssertEqual(s.focus.current, .audio)
        XCTAssertTrue(press(s, c, EditorKey(.enter)))
        XCTAssertTrue(s.dropdown.isOpen)
        XCTAssertEqual(s.dropdown.key, "audio")
        XCTAssertTrue(press(s, c, EditorKey(.down)), "from the current choice, System default")
        XCTAssertTrue(press(s, c, EditorKey(.down)))
        XCTAssertTrue(press(s, c, EditorKey(.enter)))
        XCTAssertFalse(s.dropdown.isOpen)
        XCTAssertEqual(changes.last?.audioDevice, "sink.b")
        XCTAssertEqual(s.focus.current, .audio, "focus stays on the field the list belonged to")
        XCTAssertTrue(s.focus.visible)

        press(s, c, EditorKey(.tab))
        XCTAssertEqual(s.focus.current, .cache)
        XCTAssertTrue(press(s, c, EditorKey(.space)))
        XCTAssertEqual(s.dropdown.key, "cache")
        for _ in 0..<3 { press(s, c, EditorKey(.down)) }   // Automatic, then 512 MB, 1 GB, 2 GB
        XCTAssertTrue(press(s, c, EditorKey(.enter)))
        XCTAssertEqual(changes.last?.previewCacheMB, 2048)

        // Escape in an open list closes the list only.
        XCTAssertTrue(press(s, c, EditorKey(.space)))
        XCTAssertTrue(press(s, c, EditorKey(.escape)))
        XCTAssertFalse(s.dropdown.isOpen)
        XCTAssertTrue(s.isOpen)
        XCTAssertEqual(changes.count, 2)
    }

    /// Acceptance 3, the folder row: Enter on Choose… asks the host; Space on Reset clears the folder and keeps
    /// focus on the row.
    func testEnterOrSpacePressesTheFolderButtons() {
        let (s, c) = openCard()
        var chooses = 0
        s.onChooseExportFolder = { chooses += 1 }
        for _ in 0..<3 { press(s, c, EditorKey(.tab)) }   // Appearance, then Audio output, Preview cache, Choose…
        XCTAssertEqual(s.focus.current, .chooseFolder)
        XCTAssertTrue(press(s, c, EditorKey(.enter)))
        XCTAssertEqual(chooses, 1, "Enter on Choose… asks the host for a folder")
        s.exportFolderChosen("/media/exports")
        s.draw(c, size: size)
        press(s, c, EditorKey(.tab))
        XCTAssertEqual(s.focus.current, .resetFolder)
        XCTAssertTrue(press(s, c, EditorKey(.space)))
        XCTAssertNil(s.values.exportFolder)
        XCTAssertEqual(s.focus.current, .chooseFolder, "Reset is gone; focus stays on the row")
        XCTAssertNotNil(s.focus.ringRect(s.hits))
    }

    /// Acceptance 4 (the card's part; the shell's is in `SettingsWindowTests`): Escape, or Enter on Close, closes it.
    func testEscapeOrEnterOnCloseClosesTheCard() {
        let (s, c) = openCard()
        XCTAssertTrue(press(s, c, EditorKey(.escape)))
        XCTAssertFalse(s.isOpen)
        XCTAssertNil(s.focus.current)
        XCTAssertFalse(s.keyDown(EditorKey(.tab)), "closed: keys go back to the editor")

        s.open()
        s.draw(c, size: size)
        XCTAssertTrue(press(s, c, EditorKey(.tab, shift: true)), "back from the first control comes round to Close")
        XCTAssertEqual(s.focus.current, .close)
        XCTAssertTrue(press(s, c, EditorKey(.enter)))
        XCTAssertFalse(s.isOpen)
        XCTAssertNil(s.focus.current)
    }
}

#if os(Linux)   // Cairo is the Linux canvas; these draw real pixels.
/// Acceptance 5: the focus ring in pixels, in dark and light. Set `MPVFX_SNAPSHOT_DIR` to also write the PNGs
/// (`settings-focus-<mode>-<scale>x.png` and the same card without the ring, `settings-nofocus-…`).
final class SettingsPanelFocusSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func render(_ s: SettingsPanel, _ name: String, scale: Double) -> CairoImageTarget {
        let size = CanvasSize(1440, 900)
        let t = CairoImageTarget(width: Int(size.width * scale), height: Int(size.height * scale))
        let c = t.canvas
        c.scale(scale, scale)
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), PanelTheme.studioBg)
        s.draw(c, size: size)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name)-\(Int(scale))x.png"), 0)
        }
        return t
    }

    func assertPixel(_ t: CairoImageTarget, _ x: Double, _ y: Double, scale: Double, _ hex: String, tol: Int,
                     file: StaticString = #filePath, line: UInt = #line) {
        let p = t.pixel(Int(x * scale), Int(y * scale))
        guard let want = CanvasColor(hex: hex) else { return XCTFail("bad hex \(hex)", file: file, line: line) }
        let w = (Int(want.r * 255 + 0.5), Int(want.g * 255 + 0.5), Int(want.b * 255 + 0.5))
        let ok = abs(Int(p.r) - w.0) <= tol && abs(Int(p.g) - w.1) <= tol && abs(Int(p.b) - w.2) <= tol
        XCTAssertTrue(ok, "pixel (\(x),\(y))@\(scale)x = rgb(\(p.r),\(p.g),\(p.b)), want \(hex)",
                      file: file, line: line)
    }

    /// At 1440×900 the card is 520×258 at (460, 321) and the audio field is (612, 427, 348, 28), so the 2px ring
    /// covers y 425…427 above it; without the ring that pixel is the card (`popover`: #252525 dark, #FFFFFF light).
    func testFocusRingOnTheAudioFieldInDarkAndLight() throws {
        let modes: [(ThemeMode, String, String)] = [(.dark, "#4c8df0", "#252525"), (.light, "#1a5fcc", "#ffffff")]
        for (mode, accent, card) in modes {
            Theme.setMode(mode)
            for scale in [1.0, 2.0] {
                let s = SettingsPanel()
                s.devices = [.init(id: "sink.a", name: "Speakers")]
                s.open()
                s.draw(PanelMeasureCanvas(), size: CanvasSize(1440, 900))
                XCTAssertTrue(s.keyDown(EditorKey(.tab)))
                XCTAssertEqual(s.focus.current, .audio)
                var t = render(s, "settings-focus-\(mode.rawValue)", scale: scale)
                let field = try XCTUnwrap(s.hits.rect { $0 == .audio })
                XCTAssertEqual(field, CanvasRect(x: 612, y: 427, width: 348, height: 28))
                assertPixel(t, field.midX, field.y - 1, scale: scale, accent, tol: 30)
                s.focus.pointerPressed()
                t = render(s, "settings-nofocus-\(mode.rawValue)", scale: scale)
                assertPixel(t, field.midX, field.y - 1, scale: scale, card, tol: 2)
            }
        }
    }
}
#endif
