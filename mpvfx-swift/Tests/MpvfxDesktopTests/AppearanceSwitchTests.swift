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
#if os(Linux)
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxTheme
@testable import MpvfxDesktop

/// The whole editor (shell, side panels, preview card, player chrome, timeline) rendered through Cairo, switched
/// between Dark and Light through the entry points the UI uses (the Shortcuts card's Appearance row,
/// `setAppearance` as the View menu calls it, the OS flip for System), compared with a fresh render of the
/// target mode, and the choice read back by a new session (restart).
final class AppearanceSwitchTests: XCTestCase {
    final class Counter { var n = 0 }
    static let size = CanvasSize(1440, 900)
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() {
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    func userData() -> String {
        let d = NSTemporaryDirectory() + "mpvfx-appearance-switch-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    /// A session wired the way LinuxShell wires one (shell, redraw hook, then appearance), on the built-in demo.
    func makeSession(userData: String, systemPrefersDark: @escaping () -> Bool, redraws: Counter? = nil) throws -> EditorSession {
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        _ = s.installShell(userData: userData) {}
        s.redraw = { redraws?.n += 1 }
        s.installAppearance(userData: userData, systemPrefersDark: systemPrefersDark)
        sessions.append(s)
        return s
    }

    func render(_ s: EditorSession) -> [UInt8] {
        let t = CairoImageTarget(width: Int(Self.size.width), height: Int(Self.size.height))
        s.shell!.draw(t.canvas, size: Self.size)
        return t.straightRGBA()
    }

    /// Fraction of pixels that differ between two renders.
    func differing(_ a: [UInt8], _ b: [UInt8]) -> Double {
        XCTAssertEqual(a.count, b.count)
        var n = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4)
        where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] || a[i + 3] != b[i + 3] { n += 1 }
        return Double(n) / Double(max(1, a.count / 4))
    }

    /// Mean luminance (0...255) of the whole window.
    func meanLuma(_ px: [UInt8]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { sum += 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]) }
        return sum / Double(max(1, px.count / 4))
    }

    /// Clicks a segment of the Shortcuts card's Appearance row through the shell router, as a pointer would.
    func clickAppearanceRow(_ s: EditorSession, _ a: ThemeAppearance) {
        _ = render(s)   // lays out the shell and the transport (trigger rects come from the drawn player)
        let router = s.shell!, f = router.frames!, t = s.transport
        let trig = t.shortcutsTrigger()
        let ox = f.player.x, oy = f.player.y
        if !t.shortcuts.isOpen {
            router.pointerDown(x: ox + trig.x + 4, y: oy + trig.y + 4, shift: false)
            router.pointerUp(x: ox + trig.x + 4, y: oy + trig.y + 4)
        }
        XCTAssertTrue(t.shortcuts.isOpen, "the Shortcuts card opens from its trigger")
        let card = t.shortcuts.cardRect(t.measureContext!, trigger: trig)
        let seg = (ShortcutsPanel.width - 24) / 3, i = Double(ThemeAppearance.allCases.firstIndex(of: a)!)
        let local = CanvasPoint(card.x + 12 + seg * (i + 0.5), card.y + 12 + 13.5 + 6 + 12)
        XCTAssertEqual(t.shortcuts.hitTest(t.measureContext!, local, trigger: trig), .appearance(a))
        router.pointerDown(x: ox + local.x, y: oy + local.y, shift: false)
        router.pointerUp(x: ox + local.x, y: oy + local.y)
    }

    /// A fresh session that starts in `mode` (saved choice), rendered once.
    func reference(_ mode: ThemeMode, cardOpen: Bool) throws -> [UInt8] {
        let ud = userData()
        DesktopPreferences(userData: ud).set(ThemeAppearance.preferenceKey, .string(mode.rawValue))
        let s = try makeSession(userData: ud, systemPrefersDark: { true })
        XCTAssertEqual(Theme.mode, mode)
        if cardOpen { _ = render(s); s.transport.shortcuts.isOpen = true }
        return render(s)
    }

    func testDarkRenderIsTheRecordedPaletteAndLightDiffers() throws {
        let dark = try reference(.dark, cardOpen: false)
        // The shell background (bg-[#18181B]) shows in the window's top-left corner.
        XCTAssertEqual([dark[0], dark[1], dark[2]], [0x18, 0x18, 0x1B])
        let light = try reference(.light, cardOpen: false)
        XCTAssertGreaterThan(differing(dark, light), 0.5, "light mode repaints most of the window")
        XCTAssertGreaterThan(meanLuma(light), meanLuma(dark) + 80)
    }

    /// Dark -> Light from the Shortcuts card's Appearance row: the next paint is the light editor, pixel for pixel
    /// the same as a session that started in Light; then back to Dark matches a fresh Dark render.
    func testShortcutsRowSwitchesTheWholeEditorLive() throws {
        let lightRef = try reference(.light, cardOpen: true)
        let darkRef = try reference(.dark, cardOpen: true)
        let ud = userData()
        DesktopPreferences(userData: ud).set(ThemeAppearance.preferenceKey, .string("dark"))
        let redraws = Counter()
        let s = try makeSession(userData: ud, systemPrefersDark: { true }, redraws: redraws)
        XCTAssertEqual(Theme.mode, .dark)
        clickAppearanceRow(s, .light)
        XCTAssertEqual(Theme.mode, .light)
        XCTAssertEqual(s.appearance?.appearance, .light)
        XCTAssertEqual(s.transport.shortcuts.appearance, .light, "the row shows the new choice")
        XCTAssertGreaterThan(redraws.n, 0, "the switch asks the host to repaint")
        XCTAssertEqual(differing(render(s), lightRef), 0, "after Dark -> Light the editor matches a fresh Light render")
        clickAppearanceRow(s, .dark)
        XCTAssertEqual(Theme.mode, .dark)
        XCTAssertEqual(differing(render(s), darkRef), 0, "after Light -> Dark the editor matches a fresh Dark render")
    }

    /// The View menu path (`setAppearance`, as MacShell.chooseAppearance calls it), System following the OS, and the
    /// choice surviving a restart.
    func testMenuEntryPointSystemFollowAndPersistence() throws {
        let lightRef = try reference(.light, cardOpen: false)
        let darkRef = try reference(.dark, cardOpen: false)
        let ud = userData()
        var osDark = true
        let s = try makeSession(userData: ud, systemPrefersDark: { osDark })
        XCTAssertEqual(s.appearance?.appearance, .system)
        XCTAssertEqual(differing(render(s), darkRef), 0)
        s.setAppearance(.light)
        XCTAssertEqual(differing(render(s), lightRef), 0, "menu Light repaints light")
        XCTAssertEqual(s.transport.shortcuts.appearance, .light)
        s.setAppearance(.dark)
        XCTAssertEqual(differing(render(s), darkRef), 0, "menu Dark repaints dark")
        s.setAppearance(.system)
        osDark = false; s.appearance?.systemAppearanceChanged()
        XCTAssertEqual(differing(render(s), lightRef), 0, "System follows the OS to light")
        osDark = true; s.appearance?.systemAppearanceChanged()
        XCTAssertEqual(differing(render(s), darkRef), 0, "System follows the OS back to dark")
        s.setAppearance(.light)
        // Restart: a new session on the same userData reads Light back and paints light before any switch.
        Theme.setMode(.dark)
        let again = try makeSession(userData: ud, systemPrefersDark: { true })
        XCTAssertEqual(again.appearance?.appearance, .light)
        XCTAssertEqual(again.transport.shortcuts.appearance, .light)
        XCTAssertEqual(differing(render(again), lightRef), 0, "a restart paints the saved Light choice")
    }

    /// The macOS View menu offers the three choices (MacShell wires each to setAppearance).
    func testViewMenuOffersTheAppearanceChoices() {
        let view = MenuModel.bar(for: .macOS).first { $0.label == "View" }
        let cmds: [MenuItem.Command] = [.appearanceSystem, .appearanceLight, .appearanceDark]
        XCTAssertEqual(view?.items.filter { cmds.contains($0.command) }.count, 3)
    }
}
#endif
