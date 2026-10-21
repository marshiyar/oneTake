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

final class SpeedPopoverTests: XCTestCase {
    let trigger = CanvasRect(x: 200, y: 300, width: 32, height: 28)
    func testLabels() {
        XCTAssertEqual(SpeedPopover.label(1), "1x"); XCTAssertEqual(SpeedPopover.label(0.25), "0.25x"); XCTAssertEqual(SpeedPopover.label(1.5), "1.5x")
    }
    func testToggleSelectAndDismiss() {
        let p = SpeedPopover(); var got: Double?
        p.onRateChange = { got = $0 }
        XCTAssertTrue(p.pointerDown(.init(210, 310), trigger: trigger)); XCTAssertTrue(p.isOpen)
        let m = p.menuRect(trigger: trigger)
        XCTAssertEqual(m.maxX, trigger.maxX); XCTAssertEqual(m.maxY, trigger.y - 6); XCTAssertEqual(m.width, 56)
        p.pointerDown(.init(m.x + 10, m.y + 28 * 4 + 5), trigger: trigger)
        XCTAssertEqual(got, 2); XCTAssertFalse(p.isOpen); XCTAssertEqual(p.playbackRate, 2)
        p.pointerDown(.init(210, 310), trigger: trigger); XCTAssertTrue(p.escape()); XCTAssertFalse(p.isOpen)
        p.pointerDown(.init(210, 310), trigger: trigger); XCTAssertTrue(p.pointerDown(.init(0, 0), trigger: trigger)); XCTAssertFalse(p.isOpen)
        XCTAssertFalse(p.pointerDown(.init(0, 0), trigger: trigger))
    }
    func testDisabled() {
        let p = SpeedPopover(); p.disabled = true; p.pointerDown(.init(210, 310), trigger: trigger); XCTAssertFalse(p.isOpen)
    }
}

final class VolumeSliderTests: XCTestCase {
    func testMuteToggleRules() {
        let v = VolumeSlider(volume: 0.6); var last: (Double, Bool)?
        v.onChange = { last = ($0, $1) }
        v.toggleMute(); XCTAssertTrue(v.muted); XCTAssertEqual(v.muteLabel, "Unmute audio")
        v.toggleMute(); XCTAssertFalse(v.muted); XCTAssertEqual(last?.0, 0.6)
        v.setVolume(0); XCTAssertTrue(v.silent)
        v.toggleMute(); XCTAssertEqual(v.volume, 1); XCTAssertFalse(v.muted)   // silent at 0 → restores 1
        v.muted = true; v.setVolume(0.3); XCTAssertFalse(v.muted)              // raising volume unmutes
        v.setVolume(1.7); XCTAssertEqual(v.volume, 1); v.setVolume(0.333); XCTAssertEqual(v.percentage, 33)
    }
    func testRevealAndScrub() {
        let v = VolumeSlider(volume: 1)
        v.hovered = true; while v.tick(0.016) {}; XCTAssertEqual(v.reveal, 1)
        let f = v.frame(right: 400, y: 10); XCTAssertEqual(f.width, 84)
        let t = v.trackRect(f)
        XCTAssertTrue(v.pointerDown(.init(t.x + t.width * 0.25, t.y), frame: f)); XCTAssertEqual(v.volume, 0.25, accuracy: 0.011)
        v.pointerDrag(.init(t.x - 50, t.y), frame: f); XCTAssertEqual(v.volume, 0); v.pointerUp()
        v.hovered = false; while v.tick(0.016) {}; XCTAssertEqual(v.reveal, 0)
        XCTAssertEqual(v.frame(right: 400, y: 10).width, 28)
    }
}

#if os(Linux)   // these draw into CairoImageTarget (Cairo is the Linux canvas)
final class ShortcutsPanelTests: XCTestCase {
    func ctx() -> CairoImageTarget { CairoImageTarget(width: 400, height: 400) }
    let trigger = CanvasRect(x: 300, y: 360, width: 28, height: 28)
    func testSectionsMatchSource() {
        XCTAssertEqual(shortcutSections.map(\.title), ["Playback", "Keyframes (when an element is selected)", "Editing", "Gesture recording modifiers", "Canvas", "Crop", "Panels", "Work area"])
        XCTAssertEqual(shortcutSections.reduce(0) { $0 + $1.hints.count }, 9 + 7 + 10 + 6 + 4 + 2 + 2 + 6)
        XCTAssertEqual(formatPanelTime(44.9), "00:44"); XCTAssertEqual(formatPanelTime(7200), "120:00"); XCTAssertEqual(formatPanelTime(-1), "00:00")
        XCTAssertEqual(historyShortcutLabel(true, mac: false), "Ctrl+Shift+Z"); XCTAssertEqual(historyShortcutLabel(false, mac: true), "Cmd+Z")
    }
    func testOpenScrollJumpAndClear() {
        let t = ctx(); let c = t.canvas; let p = ShortcutsPanel()
        p.duration = 10; p.fps = 30; p.inPoint = 2; var seek: Double?; var cleared = false
        p.onSeek = { seek = $0 }; p.onClearIn = { cleared = true }
        p.pointerDown(c, .init(310, 370), trigger: trigger); XCTAssertTrue(p.isOpen)
        let card = p.cardRect(c, trigger: trigger)
        XCTAssertEqual(card.height, 280); XCTAssertEqual(card.width, 220); XCTAssertEqual(card.maxY, trigger.y - 8)
        XCTAssertGreaterThan(p.maxScroll(c, trigger: trigger), 300)
        // Focus the field (first region in content order without history), type, Enter.
        var fieldPoint: CanvasPoint?
        for y in stride(from: card.y, to: card.maxY, by: 2) where p.hitTest(c, .init(card.x + 40, y), trigger: trigger) == .jumpField { fieldPoint = .init(card.x + 40, y); break }
        p.pointerDown(c, fieldPoint!, trigger: trigger); XCTAssertTrue(p.jumpFocused)
        for ch in ["4", "5"] { XCTAssertTrue(p.key(ch, text: ch)) }
        XCTAssertTrue(p.key("Return", text: nil)); XCTAssertEqual(seek!, 1.5, accuracy: 1e-9)
        p.jumpText = "9999"; p.commitJump(); XCTAssertEqual(seek, 10)
        var clearPoint: CanvasPoint?
        for y in stride(from: card.y, to: card.maxY, by: 1) where p.hitTest(c, .init(card.maxX - 20, y), trigger: trigger) == .clearIn { clearPoint = .init(card.maxX - 20, y); break }
        p.pointerDown(c, clearPoint!, trigger: trigger); XCTAssertTrue(cleared); XCTAssertNil(p.inPoint)
        p.scrollBy(c, 10_000, trigger: trigger); XCTAssertEqual(p.scroll, p.maxScroll(c, trigger: trigger))
        XCTAssertTrue(p.key("Escape", text: nil)); XCTAssertFalse(p.isOpen)
    }
    func testHistoryButtons() {
        let t = ctx(); let c = t.canvas; let p = ShortcutsPanel(); var undo = 0, redo = 0
        p.history = .init(canUndo: true, canRedo: false, undoLabel: "Move clip"); p.onUndo = { undo += 1 }; p.onRedo = { redo += 1 }
        p.isOpen = true
        let card = p.cardRect(c, trigger: trigger)
        var hits: [ShortcutsPanel.Hit: CanvasPoint] = [:]
        for y in stride(from: card.y, to: card.maxY, by: 2) { let h = p.hitTest(c, .init(card.x + 50, y), trigger: trigger); if hits[h] == nil { hits[h] = .init(card.x + 50, y) } }
        p.pointerDown(c, hits[.undo]!, trigger: trigger); p.pointerDown(c, hits[.redo]!, trigger: trigger)
        XCTAssertEqual(undo, 1); XCTAssertEqual(redo, 0)
    }
}

/// Renders the popovers over a transport bar into .build/port-tmp for visual review.
final class PanelScreenshotTests: XCTestCase {
    static let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/port-tmp").standardized

    func render(_ name: String, w: Int = 520, h: Int = 420, _ body: (CanvasContext, CanvasRect) -> Void) throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let t = CairoImageTarget(width: w * 2, height: h * 2); let c = t.canvas
        c.scale(2, 2)
        c.fillRect(CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)), CanvasColor(hex: "#0a0a0b")!)
        let bar = CanvasRect(x: 0, y: Double(h) - 44, width: Double(w), height: 44)
        c.fillRect(bar, CanvasColor(hex: "#0f0f10")!); c.fillRect(CanvasRect(x: 0, y: bar.y, width: bar.width, height: 1), PanelStyle.divider)
        body(c, bar)
        XCTAssertEqual(t.writePNG(Self.out.appendingPathComponent(name).path), 0)
    }

    func testRenderPanels() throws {
        let volF = { (v: VolumeSlider) in v.frame(right: 440, y: 384) }
        let kbTrig = CanvasRect(x: 476, y: 384, width: 28, height: 28)
        func chrome(_ c: CanvasContext, speed: SpeedPopover, vol: VolumeSlider, sc: ShortcutsPanel) {
            let f = volF(vol); speed.draw(c, trigger: CanvasRect(x: f.x - 4 - 32, y: 384, width: 32, height: 28)); vol.draw(c, frame: volF(vol)); sc.draw(c, trigger: kbTrig)
        }
        let speed = SpeedPopover(playbackRate: 1.5); speed.isOpen = true; speed.hoveredIndex = 3
        try render("panel-speed-popover.png") { c, _ in chrome(c, speed: speed, vol: VolumeSlider(volume: 0.7), sc: ShortcutsPanel()) }

        let vol = VolumeSlider(volume: 0.62); vol.hovered = true; while vol.tick(0.02) {}
        try render("panel-volume-slider.png") { c, _ in chrome(c, speed: SpeedPopover(), vol: vol, sc: ShortcutsPanel()) }
        let muted = VolumeSlider(volume: 0.62, muted: true)
        try render("panel-volume-muted.png") { c, _ in chrome(c, speed: SpeedPopover(), vol: muted, sc: ShortcutsPanel()) }

        let sc = ShortcutsPanel(); sc.isOpen = true; sc.inPoint = 2.4; sc.duration = 12; sc.jumpText = "120"; sc.jumpFocused = true
        sc.history = .init(canUndo: true, canRedo: false, undoLabel: "Move clip")
        try render("panel-shortcuts.png") { c, _ in chrome(c, speed: SpeedPopover(), vol: VolumeSlider(), sc: sc) }
        let sc2 = ShortcutsPanel(); sc2.isOpen = true
        try render("panel-shortcuts-scrolled.png") { c, _ in sc2.scrollBy(c, 420, trigger: kbTrig); chrome(c, speed: SpeedPopover(), vol: VolumeSlider(), sc: sc2) }
    }
}
#endif
