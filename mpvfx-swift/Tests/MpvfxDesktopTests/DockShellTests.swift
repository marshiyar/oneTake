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
import MpvfxPanels
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxDesktop

/// The editor window on the dock, through the router every shell (GTK, AppKit, Win32) hands its canvas and events
/// to: the editor's panels as dock panels, gestures through the shell, the panel menu, persistence, and the
/// registration API other panels use.
final class DockShellTests: XCTestCase {
    static let size = CanvasSize(1440, 900)
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() {
        for s in sessions { s.audio?.stop() }
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    func userData() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-dock-shell-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    /// A demo session with its shell installed in `dir`, drawn once at 1440 × 900 (hit regions come from a draw).
    func session(_ dir: String) throws -> (EditorSession, EditorShellRouter) {
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        sessions.append(s)
        let router = s.installShell(userData: dir) {}
        draw(router)
        return (s, router)
    }

    func draw(_ router: EditorShellRouter) { router.draw(PanelMeasureCanvas(), size: Self.size) }

    func tab(_ router: EditorShellRouter, _ panel: DockPanelID) throws -> DockTabBar.Tab {
        try XCTUnwrap(router.dock.tabs.values.joined().first { $0.panel == panel }, panel)
    }

    func click(_ router: EditorShellRouter, _ p: CanvasPoint) {
        router.pointerDown(x: p.x, y: p.y, button: PointerButton.primary, modifiers: [])
        router.pointerUp(x: p.x, y: p.y, button: PointerButton.primary)
        draw(router)
    }

    func savedLayout(_ dir: String) throws -> DockLayout {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("dock-layout.json")))
        guard case .success(let d) = DockCodec.decode(data, registry: .editor) else { XCTFail("saved file refused"); throw DockOpError.invalidTarget }
        return try XCTUnwrap(d.file.layout)
    }

    // MARK: Panels

    func testTheEditorsPanelsAreDockPanelsWithTheirPanes() throws {
        let (_, router) = try session(try userData())
        XCTAssertEqual(Set(router.dock.layout.openPanels), Set(DockPanels.builtIn.filter { !$0.startsClosed }.map(\.id)),
                       "every built-in panel that is not closed by default opens")
        for region in [EditorShellRouter.Region.left, .player, .right, .renders, .timeline] { XCTAssertNotNil(router.panes[region], region.id) }
        let f = try XCTUnwrap(router.frames)
        XCTAssertEqual(router.region(at: f.left.cx, f.left.cy), .left)
        XCTAssertEqual(router.region(at: f.player.cx, f.player.cy), .player)
        XCTAssertEqual(router.region(at: f.previewTopBar.cx, f.previewTopBar.cy), .previewTopBar)
        XCTAssertEqual(router.hit(f.timeline.x + 10, f.timeline.y + 20)?.region, .timeline, "file drops still find the timeline")
        XCTAssertEqual(router.hit(f.timeline.x + 10, f.timeline.y + 20)?.local, CanvasPoint(10, 20))
    }

    func testMarkerShortcutOnlyInTimelineAndPanelJumpUsesPlayback() throws {
        let (session, router) = try self.session(try userData())
        session.timeline.playback.seek(1)
        router.dock.focus("preview")
        _ = router.keyDown(EditorKey(.char("m")))
        XCTAssertNil(session.editor.document.sequence.markers)
        router.dock.focus("timeline")
        XCTAssertTrue(router.keyDown(EditorKey(.char("m"))))
        XCTAssertEqual(session.editor.document.sequence.markers?.first?.time, 1)
        XCTAssertFalse(session.timeline.playback.audioMuted)
        XCTAssertNotNil(router.panes[.of("markers")])
        router.run(.toggle("markers"))
        draw(router)
        XCTAssertTrue(router.dock.layout.isOpen("markers"))
        session.timeline.playback.seek(0)
        let pane = try XCTUnwrap(router.panes[.of("markers")])
        pane.input?.pointerDown(x: 25, y: 10, shift: false)
        XCTAssertEqual(session.timeline.playback.currentTime, 1)
    }

    // MARK: Drag, close, open through the shell

    func testDraggingATabThroughTheShellMovesThePanelAndTheLayoutIsSaved() throws {
        let dir = try userData()
        let (_, router) = try session(dir)
        let start = try tab(router, "media").rect, timelineStrip = try XCTUnwrap(router.dock.geometry.frame(containing: "timeline")).strip
        router.pointerDown(x: start.cx, y: start.cy, button: PointerButton.primary, modifiers: [])
        router.pointerMove(x: 700, y: 300, modifiers: [])
        router.pointerMove(x: timelineStrip.maxX - 60, y: timelineStrip.cy, modifiers: [])
        router.pointerUp(x: timelineStrip.maxX - 60, y: timelineStrip.cy, button: PointerButton.primary)
        XCTAssertEqual(router.dock.layout.root.group(containing: "media")?.panels, ["timeline", "media"])
        router.dockStore?.flush()
        XCTAssertEqual(try savedLayout(dir).root.group(containing: "media")?.panels, ["timeline", "media"])
        // The next window in the same user data opens with it.
        let (_, again) = try session(dir)
        XCTAssertEqual(again.dock.layout.root.group(containing: "media")?.panels, ["timeline", "media"])
    }

    func testTheCloseButtonClosesAPanelAndThePanelMenuReopensItInPlace() throws {
        let (_, router) = try session(try userData())
        click(router, CanvasPoint(try XCTUnwrap(try tab(router, "renders").close).cx, try XCTUnwrap(try tab(router, "renders").close).cy))
        XCTAssertFalse(router.dock.layout.isOpen("renders"))
        let strip = try XCTUnwrap(router.dock.geometry.frame(containing: "preview")).strip
        click(router, CanvasPoint(DockTabBar.menuRect(strip).cx, DockTabBar.menuRect(strip).cy))
        XCTAssertTrue(router.dockMenu.isOpen)
        let values = router.dockMenu.options.map(\.value)
        XCTAssertEqual(values, ["toggle:media", "toggle:preview", "toggle:inspector", "toggle:renders", "toggle:timeline", "toggle:history", "toggle:mixer", "toggle:info", "toggle:effects", "toggle:scopes", "toggle:markers",
                                 "toggle:design.transform", "toggle:design.style", "toggle:design.grade", "toggle:design.effects",
                                 "toggle:design.audio-fx", "toggle:design.media"],
                       "the Preview cannot be closed, so its menu starts with the panel list")
        XCTAssertEqual(Set(router.dockMenu.checked), Set(DockPanels.builtIn.filter { !$0.startsClosed && $0.id != "renders" }.map { "toggle:\($0.id)" }))
        router.dockMenu.pick("toggle:renders")
        XCTAssertEqual(router.dock.layout.root.group(containing: "renders")?.panels,
                       DockPanels.builtIn.filter { $0.defaultDock == .right && !$0.startsClosed }.map(\.id), "back beside Design")
        XCTAssertEqual(router.focused, .renders)
    }

    func testTheGroupMenuClosesItsPanelAndRunsThePanelsOwnCommand() throws {
        let (s, router) = try session(try userData())
        click(router, CanvasPoint(try tab(router, "renders").rect.cx, try tab(router, "renders").rect.cy))
        var actions: [RenderAction] = []
        s.panels?.rendersPanel.onRender = { actions.append($0) }
        let strip = try XCTUnwrap(router.dock.geometry.frame(containing: "renders")).strip
        router.secondaryClick(x: strip.cx, y: strip.cy)
        XCTAssertEqual(router.dockMenu.options.prefix(2).map(\.label), ["Close Renders", "Hide finished renders"])
        router.dockMenu.pick("extra:renders:hide-finished")
        XCTAssertEqual(actions, [.hideFinished])
        router.secondaryClick(x: strip.cx, y: strip.cy)
        router.dockMenu.pick("close:renders")
        XCTAssertFalse(router.dock.layout.isOpen("renders"))
    }

    func testCommandShiftWClosesTheFocusedPanelAndGlobalKeysStillReachTheTimeline() throws {
        let (s, router) = try session(try userData())
        let f = try XCTUnwrap(router.frames)
        click(router, CanvasPoint(f.right.cx, f.right.maxY - 12))
        XCTAssertEqual(router.focused, .right)
        XCTAssertTrue(router.keyDown(EditorKey(.char("w"), shift: true, ctrl: true)))
        XCTAssertFalse(router.dock.layout.isOpen("inspector"))
        click(router, CanvasPoint(f.left.cx, f.left.maxY - 12))
        XCTAssertEqual(router.focused, .left)
        XCTAssertTrue(router.keyDown(EditorKey(.space)), "Space falls through to the timeline and playback")
        XCTAssertTrue(s.playback.isPlaying)
        s.playback.pause()
    }

    func testCtrlTabCyclesFocusThroughThePanels() throws {
        let (_, router) = try session(try userData())
        XCTAssertEqual(router.focused, .timeline)
        XCTAssertTrue(router.keyDown(EditorKey(.tab, ctrl: true)))
        XCTAssertEqual(router.focused, .left)
        XCTAssertTrue(router.keyDown(EditorKey(.tab, ctrl: true)))
        XCTAssertEqual(router.focused, .of(DockPanels.effects), "the Media group's other tab")
        XCTAssertTrue(router.keyDown(EditorKey(.tab, ctrl: true)))
        XCTAssertEqual(router.focused, .player)
    }

    // MARK: The side panels' own hide and reveal

    func testTheBinsHideCommandClosesTheMediaPanelAndARevealOpensDesign() throws {
        let (s, router) = try session(try userData())
        let panels = try XCTUnwrap(s.panels)
        XCTAssertNil(panels.left.hits.rect { $0 == .hideSidebar }, "in the dock the × closes the bin; no hide button")
        panels.left.layout.toggleLeft()
        XCTAssertFalse(router.dock.layout.isOpen("media"))
        XCTAssertFalse(panels.left.layout.effectiveLeftCollapsed, "nothing collapses to a rail in the dock")
        router.close(DockPanels.inspector)
        panels.right.layout.setRightCollapsed(false)
        panels.right.layout.setRightTab(.design)
        XCTAssertTrue(router.dock.layout.isOpen("inspector"))
        XCTAssertEqual(router.focused, .right)
        panels.right.layout.setRightTab(.renders)
        draw(router)
        XCTAssertGreaterThan(try XCTUnwrap(router.frames).renders.width, 0, "the smoke hook's Renders tab shows the Renders panel")
    }

    // MARK: Persistence

    func testACorruptLayoutFileOpensTheDefaultLayout() throws {
        let dir = try userData()
        for bytes in [Data("not json".utf8), Data(repeating: 0x5B, count: 100_000), Data(#"{"version": 9}"#.utf8)] {
            try bytes.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("dock-layout.json")))
            let (_, router) = try session(dir)
            XCTAssertEqual(router.dock.layout, DockDefaults.layout(.editor))
        }
    }

    func testTheOldPanelSizesSeedTheFirstLayout() throws {
        let dir = try userData()
        try Data(#"{"leftWidth": 300, "rightWidth": 350, "timelineHeight": 300}"#.utf8)
            .write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("panel-layout.json")))
        let (_, router) = try session(dir)
        let f = try XCTUnwrap(router.frames)
        XCTAssertEqual(f.left.width, 300, accuracy: 1)
        XCTAssertEqual(f.right.width, 350, accuracy: 1)
        XCTAssertEqual(f.timeline.height, 300, accuracy: 1, "the old timeline height is its content height")
    }

    func testTheLayoutStoreWritesDurablyAndReportsAFailureOnce() throws {
        let dir = try userData()
        let store = DockLayoutStore(userData: dir)
        let file = DockFile(workspaces: ["edit": DockDefaults.layout(.editor)])
        store.save(file)
        store.flush()
        XCTAssertEqual(store.load(registry: .editor, fallback: DockFile(workspaces: [:])), file)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "no temporary file left behind")
        // A folder where the file belongs: every write fails, the failure is reported once.
        let blocked = try userData()
        try FileManager.default.createDirectory(atPath: (blocked as NSString).appendingPathComponent("dock-layout.json"),
                                                withIntermediateDirectories: true)
        let failing = DockLayoutStore(userData: blocked)
        var reports = 0
        failing.onWriteError = { _ in reports += 1 }
        failing.save(file); failing.save(file); failing.flush()
        failing.save(file); failing.flush()
        XCTAssertEqual(reports, 1)
    }

    // MARK: Registration API and menus

    func testAnotherPanelRegistersWithIdTitleDockAndMinimumSize() throws {
        let dir = try userData()
        let (_, router) = try session(dir)
        var painted = 0
        let spec = DockPanelSpec(id: "easing", title: "Easing", defaultDock: .right, minSize: CanvasSize(240, 160))
        try router.registerPanel(spec, pane: ShellPane { _, _ in painted += 1 })
        XCTAssertThrowsError(try router.registerPanel(spec, pane: ShellPane { _, _ in })) {
            XCTAssertEqual($0 as? DockRegistryError, .duplicateID("easing"))
        }
        router.restoreDock(store: DockLayoutStore(userData: dir), seeds: DockSeeds())
        XCTAssertEqual(router.dock.layout.root.group(containing: "easing")?.panels,
                       DockPanels.builtIn.filter { $0.defaultDock == .right && !$0.startsClosed }.map(\.id) + ["easing"],
                       "a panel no saved layout knows opens at its default dock")
        router.dock.focus("easing")
        draw(router)
        XCTAssertGreaterThan(painted, 0)
        XCTAssertEqual(router.windowMenuPanels.map(\.title), ["Media", "Preview", "Design", "Renders", "Timeline", "History", "Mixer", "Info",
                        "Effects", "Scopes", "Markers", "Transform", "Style", "Grade", "Effects", "Audio FX", "Media", "Easing"])
    }

    func testTheWindowMenuListsEveryPanelWithACheckmarkAndTogglesIt() throws {
        let (_, router) = try session(try userData())
        // The Design groups start in the Design tab, and Mixer/Scopes/Markers start closed, so those
        // panels are listed unchecked.
        XCTAssertEqual(Set(router.windowMenuPanels.filter(\.checked).map(\.id)),
                       Set(DockPanels.builtIn.filter { !$0.startsClosed }.map(\.id)))
        router.togglePanelFromMenu("media")
        XCTAssertEqual(router.windowMenuPanels.first { $0.id == "media" }?.checked, false)
        router.togglePanelFromMenu("media")
        XCTAssertEqual(router.windowMenuPanels.first { $0.id == "media" }?.checked, true)
        router.togglePanelFromMenu("timeline")
        XCTAssertTrue(router.dock.layout.isOpen("timeline"), "the timeline cannot be closed: the menu focuses it")
        XCTAssertFalse(router.closeFocusedPanel())
    }

    func testScopesMarkersAndMixerRemainRegisteredTogether() throws {
        let (s, router) = try session(try userData())
        let panels = s.shellInputs.compactMap { ($0 as? DockedPanelInput)?.panel }
        XCTAssertTrue(panels.contains { $0 is ScopesPanel })
        XCTAssertTrue(panels.contains { $0 is MarkersPanel })
        XCTAssertTrue(panels.contains { $0 is MixerPanel })
        for id in [DockPanels.scopes, DockPanels.markers, DockPanels.mixer] {
            XCTAssertNotNil(router.panes[.of(id)])
            XCTAssertFalse(router.dock.layout.isOpen(id))
            router.togglePanelFromMenu(id)
            XCTAssertTrue(router.dock.layout.isOpen(id))
        }
    }
}
/// Centre of a rect (the panels module keeps its own `midX`, `midY` internal).
fileprivate extension CanvasRect {
    var cx: Double { x + width / 2 }
    var cy: Double { y + height / 2 }
}
#endif
