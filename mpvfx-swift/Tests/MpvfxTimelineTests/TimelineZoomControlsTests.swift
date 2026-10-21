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
@testable import MpvfxTimeline
import MpvfxCanvas
import MpvfxTheme
import MpvfxShared

final class TimelineZoomControlsTests: XCTestCase {
    func testFitShortcutReadoutAndHoverHint() throws {
        let c = try TimelineZoomFitTests().make(playhead: 8)
        let region = TimelineRegion(controller: c)
        c.setZoom(percent: 400)
        XCTAssertTrue(c.keyDown(EditorKey(.char("Z"), shift: true)))
        XCTAssertEqual(c.view.scrollX, 0); XCTAssertEqual(c.zoomMode, .fit)
        let tb = region.toolbar
        XCTAssertFalse(tb.isEnabled(.zoomOut))
        c.setZoom(percent: 800)
        tb.activate(.zoomFit)
        XCTAssertEqual(c.zoomMode, .fit)
        for scale in [100.0, 400, 1600] {
            c.setZoom(percent: scale)
            let interval = TimelineRuler.majorInterval(duration: c.view.duration, pps: c.view.pixelsPerSecond, frameRate: c.view.frameRate)
            let ticks = c.view.rulerTicks(width: 1266).major
            if ticks.count > 1 { XCTAssertEqual(ticks[1] - ticks[0], interval, accuracy: 1e-6) }
            XCTAssertTrue(tb.tickReadout.contains("/tick"))
            tb.hovered = .zoomPercent
            XCTAssertEqual(region.hint, "Each ruler tick spans \(tb.tickReadout)")
        }
        XCTAssertTrue(PointerModifiers.alt.zoomsWheel)
        XCTAssertTrue(PointerModifiers.meta.zoomsWheel)
        XCTAssertTrue(PointerModifiers.ctrl.zoomsWheel)
    }

    func testMovingLastClipShortensDurationAndUndoRestoresBoth() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON.replacingOccurrences(of: "\"name\":\"Main\",\"tracks\"", with: "\"name\":\"Main\",\"durationFrames\":330,\"tracks\""))
        let before = e.document
        let address = try XCTUnwrap(e.address(clipId: "clip:music"))
        XCTAssertTrue(e.apply(.trimOut(address: address, endFrameExclusive: 240)))
        XCTAssertEqual(e.document.sequence.durationFrames, 315)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, before)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.document.sequence.durationFrames, 315)
        let b = try XCTUnwrap(e.address(clipId: "clip:b"))
        XCTAssertTrue(e.apply(.move(address: b, destination: .init(trackId: b.trackId, startFrame: 180))))
        XCTAssertEqual(e.document.sequence.durationFrames, 300)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document.sequence.durationFrames, 315)
    }

    func testEffectsAndHintInkContrastInBothModes() {
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let row = ThemeTokens.timelineRowPair.value(mode)
            let ink = ThemeTokens.whitePair.value(mode)
            XCTAssertGreaterThanOrEqual(ink.alpha(mode == .light ? 0.68 : 0.62).over(row).contrast(row), 4.5)
            XCTAssertGreaterThanOrEqual(ThemeTokens.textPairs[2].value(mode).contrast(ThemeTokens.panelBgPair.value(mode)), 4.5)
            for fill in [ThemeTokens.clipVideoPair.value(mode), ThemeTokens.clipAudioPair.value(mode)] {
                let bg = ink.alpha(0.12).over(fill)
                XCTAssertGreaterThanOrEqual(ink.alpha(0.92).over(bg).contrast(bg), 4.5)
            }
        }
    }
}

private extension ThemeColor {
    func over(_ background: ThemeColor) -> ThemeColor {
        ThemeColor(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a))
    }
}
