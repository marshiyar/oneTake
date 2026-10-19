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
@testable import MpvfxPlayer
import MpvfxTimeline
import MpvfxCanvas

final class PreviewStageToolsTests: XCTestCase {
    // MARK: Snap engine

    func testSnapToNearestEdgeWithGuide() {
        let target = SnapEngine.Target(CanvasRect(x: 200, y: 0, width: 50, height: 50), id: "t")
        let r = SnapEngine.resolve(moving: CanvasRect(x: 0, y: 100, width: 100, height: 40), dx: 96, dy: 0, targets: [target])
        XCTAssertEqual(r.dx, 100, "right edge 196 snaps to the target's left edge 200")
        XCTAssertEqual(r.dy, 0)
        XCTAssertEqual(r.guides, [SnapEngine.Guide(axis: .x, position: 200, from: 0, to: 140)])
        let far = SnapEngine.resolve(moving: CanvasRect(x: 0, y: 100, width: 100, height: 40), dx: 80, dy: 0, targets: [target])
        XCTAssertEqual(far.dx, 80, "beyond 6px no snap"); XCTAssertTrue(far.guides.isEmpty)
        XCTAssertEqual(SnapEngine.resolve(moving: CanvasRect(x: 0, y: 100, width: 100, height: 40), dx: 96, dy: 0, targets: [target], disabled: true).dx, 96)
    }

    func testOpposingTiesCancelAndElementsBeatGrid() {
        let a = SnapEngine.Target(CanvasRect(x: 103, y: 0, width: 10, height: 10), id: "a")
        let b = SnapEngine.Target(CanvasRect(x: 0, y: 0, width: 97, height: 10), id: "b")
        let r = SnapEngine.resolve(moving: CanvasRect(x: 50, y: 50, width: 50, height: 10), dx: 50, dy: 0, targets: [a, b])
        // proposed left 100: a.left 103 (+3) vs b.right 97 (-3) tie in opposite directions → no snap.
        XCTAssertEqual(r.dx, 50)
        let g = SnapEngine.resolve(moving: CanvasRect(x: 0, y: 0, width: 10, height: 10), dx: 95, dy: 0,
                                   targets: [SnapEngine.Target(CanvasRect(x: 106, y: 50, width: 5, height: 5), id: "e")],
                                   grid: (x: [102], y: []))
        XCTAssertEqual(g.dx, 96, "element edge (1px away) wins over the nearest grid line (2px)")
        XCTAssertEqual(SnapEngine.gridEdges(frame: CanvasRect(x: 0, y: 0, width: 300, height: 90), divisions: 3).x, [100, 200])
        XCTAssertEqual(SnapEngine.gridEdges(frame: CanvasRect(x: 0, y: 0, width: 300, height: 90), divisions: 7).y, [30, 60], "unknown → thirds")
        XCTAssertFalse(SnapEngine.engaged(dx: 2, dy: 2)); XCTAssertTrue(SnapEngine.engaged(dx: 3, dy: 3))
    }

    func testEquidistanceGuides() {
        let a = SnapEngine.Target(CanvasRect(x: 0, y: 0, width: 50, height: 50), id: "a")
        let c = SnapEngine.Target(CanvasRect(x: 200, y: 0, width: 50, height: 50), id: "c")
        let g = SnapEngine.equidistance(moving: CanvasRect(x: 100, y: 0, width: 50, height: 50), targets: [a, c])
        XCTAssertEqual(g, [SnapEngine.SpacingGuide(axis: .x, position: 50, size: 50, from: 0, to: 50),
                           SnapEngine.SpacingGuide(axis: .x, position: 150, size: 50, from: 0, to: 50)])
        XCTAssertTrue(SnapEngine.equidistance(moving: CanvasRect(x: 110, y: 0, width: 50, height: 50), targets: [a, c]).isEmpty)
    }

    // MARK: Zoom

    func testZoomClampsWheelAndPan() {
        XCTAssertEqual(PreviewZoom.clamp(50), 100); XCTAssertEqual(PreviewZoom.clamp(900), 400); XCTAssertEqual(PreviewZoom.clamp(.nan), 100)
        XCTAssertEqual(PreviewZoom.wheelPercent(deltaY: -100, current: 100), 100 * exp(0.07), accuracy: 1e-9, "delta clamps to 10")
        XCTAssertEqual(PreviewZoom.stepPercent(zoomIn: true, current: 100), 125)
        XCTAssertEqual(PreviewZoom.stepPercent(zoomIn: false, current: 100), 100, "never below fit")
        let vp = CanvasSize(800, 450), content = CanvasSize(800, 450)
        let z = PreviewZoom(percent: 200).wheelPan(dx: 1000, dy: -1000, viewport: vp, content: content)
        XCTAssertEqual(z.panX, -400); XCTAssertEqual(z.panY, 225, "pan clamps to half the overflow")
        XCTAssertEqual(PreviewZoom.fit.wheelPan(dx: 50, dy: 50, viewport: vp, content: content), .fit, "no pan at fit")
        // Zooming about a cursor right of centre shifts the pan left so that point stays put.
        let zc = PreviewZoom.fit.wheelZoom(deltaY: -10, cursor: CanvasPoint(100, 0), viewport: vp, content: content)
        XCTAssertGreaterThan(zc.percent, 100); XCTAssertLessThan(zc.panX, 0)
        XCTAssertEqual(PreviewZoom(percent: 250.4).label, "250%"); XCTAssertEqual(PreviewZoom.fit.label, "Fit")
    }

    func testControllerWheelZoomShowsReadoutAndFitButtonResets() {
        let (v, c) = stage()
        var clock = 10.0; v.now = { clock }
        let vp = v.viewportRect(in: c.size)
        XCTAssertFalse(c.scroll(x: 5, y: 5, dx: 0, dy: -10, zoom: true), "over the tools bar: not the preview's")
        XCTAssertTrue(c.scroll(x: vp.x + vp.width / 2, y: vp.y + vp.height / 2, dx: 0, dy: -10, zoom: true))
        XCTAssertEqual(v.zoom.percent, 100 * exp(0.07), accuracy: 1e-9)
        XCTAssertEqual(v.zoomHudOpacity(), 1)
        let f = v.frameRect(in: c.size), fit = v.fittedRect(in: c.size)
        XCTAssertEqual(f.width, fit.width * v.zoom.scale, accuracy: 1e-6)
        clock += 1.5; XCTAssertEqual(v.zoomHudOpacity(), 0.75, accuracy: 1e-9, "fading (ease-in)")
        clock += 0.2; XCTAssertEqual(v.zoomHudOpacity(), 0, "faded after 1.4 s + 200 ms")
        let fb = try! XCTUnwrap(v.fitButtonRect(in: c.size, nil))
        c.pointerDown(x: fb.x + 4, y: fb.y + 4)
        XCTAssertTrue(v.zoom.isAtFit); XCTAssertNil(v.fitButtonRect(in: c.size, nil))
        // Middle-button drag pans a zoomed frame.
        v.zoom = PreviewZoom(percent: 200)
        c.pointerDown(x: 300, y: 200, button: 1); c.pointerMove(x: 340, y: 210); c.pointerUp(x: 340, y: 210)
        XCTAssertEqual(v.zoom.panX, 40); XCTAssertEqual(v.zoom.panY, 10)
    }

    // MARK: Tools bar

    func testToolbarToggleGridPresetsAndKeys() {
        let (v, c) = stage()
        var changes = 0
        v.toolbar.onPrefsChange = { _ in changes += 1 }
        let items = v.toolbar.layout(width: c.size.width, cropAvailable: false, cropActive: false, nil)
        let grid = items.first { $0.0 == .grid }!.1, snap = items.first { $0.0 == .snap }!.1
        XCTAssertEqual(grid.maxX, c.size.width - 8, "px-2, right-aligned"); XCTAssertEqual(snap.maxX, grid.x - 4, "gap-1")
        XCTAssertFalse(items.contains { $0.0 == .record }, "Record only when recording is wired")
        c.pointerDown(x: snap.x + 4, y: snap.y + 4); XCTAssertFalse(v.toolbar.snapEnabled)
        c.pointerDown(x: grid.x + 4, y: grid.y + 4); XCTAssertTrue(v.toolbar.gridVisible)
        let chevron = items.first { $0.0 == .gridOptions }!.1
        c.pointerDown(x: chevron.midX, y: chevron.midY); XCTAssertTrue(v.toolbar.gridPopoverOpen)
        let pop = v.toolbar.layout(width: c.size.width, cropAvailable: false, cropActive: false, nil)
        let quarters = pop.first { $0.0 == .gridPreset(4) }!.1
        c.pointerDown(x: quarters.midX, y: quarters.midY)
        XCTAssertEqual(v.toolbar.gridDivisions, 4); XCTAssertFalse(v.toolbar.gridPopoverOpen)
        c.pointerDown(x: chevron.midX, y: chevron.midY)
        let toggle = v.toolbar.layout(width: c.size.width, cropAvailable: false, cropActive: false, nil).first { $0.0 == .snapToGridToggle }!.1
        c.pointerDown(x: toggle.midX, y: toggle.midY); XCTAssertTrue(v.toolbar.snapToGrid)
        c.pointerDown(x: 300, y: 300); XCTAssertFalse(v.toolbar.gridPopoverOpen, "outside click closes the popover")
        XCTAssertTrue(c.keyDown(EditorKey(.char("g")))); XCTAssertFalse(v.toolbar.gridVisible)
        XCTAssertFalse(c.keyDown(EditorKey(.char("s"))), "bare S stays Split")
        XCTAssertEqual(changes, 5)
        var recorded = 0
        v.toolbar.onToggleRecording = { recorded += 1 }
        XCTAssertTrue(v.toolbar.layout(width: c.size.width, cropAvailable: false, cropActive: false, nil).contains { $0.0 == .record })
        XCTAssertTrue(c.keyDown(EditorKey(.char("r")))); XCTAssertEqual(recorded, 1)
    }

    func testCropToolDraftApplyCancelReset() {
        let (v, c) = stage()
        var commits: [StageElement] = []
        c.onCommit = { commits.append($0) }
        v.elements = [StageElement(id: "m", name: "M", rect: CanvasRect(x: 0, y: 0, width: 1000, height: 500), kind: .video)]
        let f = v.frameRect(in: c.size)
        c.pointerDown(x: f.midX, y: f.midY); c.pointerUp(x: f.midX, y: f.midY)
        XCTAssertTrue(v.cropAvailable)
        let crop = v.toolbar.layout(width: c.size.width, cropAvailable: true, cropActive: false, nil).first { $0.0 == .crop }!.1
        c.pointerDown(x: crop.midX, y: crop.midY); XCTAssertTrue(v.cropActive)
        // Drag the left edge 100 px in: a draft, nothing committed yet.
        c.pointerDown(x: f.x, y: f.midY); c.pointerMove(x: f.x + 100, y: f.midY); c.pointerUp(x: f.x + 100, y: f.midY)
        XCTAssertEqual(v.elements[0].crop.left, 100, accuracy: 1e-9); XCTAssertTrue(commits.isEmpty)
        let bar = v.toolbar.layout(width: c.size.width, cropAvailable: true, cropActive: true, nil)
        let cancel = bar.first { $0.0 == .cropCancel }!.1, apply = bar.first { $0.0 == .cropApply }!.1, reset = bar.first { $0.0 == .cropReset }!.1
        c.pointerDown(x: cancel.midX, y: cancel.midY)
        XCTAssertFalse(v.cropActive); XCTAssertEqual(v.elements[0].crop, .zero, "Cancel restores"); XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(c.keyDown(EditorKey(.char("c")))); XCTAssertTrue(v.cropActive)
        c.pointerDown(x: f.maxX, y: f.midY); c.pointerMove(x: f.maxX - 50, y: f.midY); c.pointerUp(x: f.maxX - 50, y: f.midY)
        c.pointerDown(x: reset.midX, y: reset.midY); XCTAssertEqual(v.elements[0].crop, .zero, "Reset clears the draft"); XCTAssertTrue(v.cropActive)
        c.pointerDown(x: f.maxX, y: f.midY); c.pointerMove(x: f.maxX - 50, y: f.midY); c.pointerUp(x: f.maxX - 50, y: f.midY)
        c.pointerDown(x: apply.midX, y: apply.midY)
        XCTAssertFalse(v.cropActive); XCTAssertEqual(commits.count, 1); XCTAssertEqual(commits[0].crop.right, 50, accuracy: 1e-9)
    }

    // MARK: Selection

    func testShiftClickMarqueeAndGroupMove() {
        let (v, c) = stage()
        v.toolbar.snapEnabled = false
        var commits: [String] = [], selections: [[String]] = []
        c.onCommit = { commits.append($0.id) }
        c.onSelectionChange = { selections.append($0) }
        v.elements = [StageElement(id: "a", name: "A", rect: CanvasRect(x: 100, y: 100, width: 100, height: 100), kind: .element),
                      StageElement(id: "b", name: "B", rect: CanvasRect(x: 400, y: 100, width: 100, height: 100), kind: .element)]
        let f = v.frameRect(in: c.size)
        c.pointerDown(x: f.x + 150, y: f.y + 150); c.pointerUp(x: f.x + 150, y: f.y + 150)
        c.pointerDown(x: f.x + 450, y: f.y + 150, shift: true); c.pointerUp(x: f.x + 450, y: f.y + 150)
        XCTAssertEqual(v.selectedIds, ["a", "b"])
        XCTAssertEqual(v.groupBounds(in: c.size), CanvasRect(x: f.x + 100, y: f.y + 100, width: 400, height: 100))
        // Drag inside the group box (between the members) moves both, one commit each.
        c.pointerDown(x: f.x + 300, y: f.y + 150); c.pointerMove(x: f.x + 310, y: f.y + 170); c.pointerUp(x: f.x + 310, y: f.y + 170)
        XCTAssertEqual(v.elements.map(\.rect.x), [110, 410]); XCTAssertEqual(commits, ["a", "b"])
        c.pointerDown(x: f.x + 460, y: f.y + 170, shift: true); c.pointerUp(x: f.x + 460, y: f.y + 170)
        XCTAssertEqual(v.selectedIds, ["a"], "shift-click toggles off")
        // Marquee from empty canvas over B only.
        c.pointerDown(x: f.x + 380, y: f.y + 50); c.pointerMove(x: f.x + 600, y: f.y + 300)
        XCTAssertEqual(v.marqueeCandidates, ["b"]); XCTAssertNotNil(v.marquee)
        c.pointerUp(x: f.x + 600, y: f.y + 300)
        XCTAssertEqual(v.selectedIds, ["b"]); XCTAssertNil(v.marquee)
        XCTAssertEqual(selections.last, ["b"])
        // Hover outline target.
        c.pointerMove(x: f.x + 160, y: f.y + 160); XCTAssertEqual(v.hoveredElement, "a")
        c.pointerMove(x: f.x + 900, y: f.y + 400); XCTAssertNil(v.hoveredElement)
    }

    func testMoveSnapsToFrameCentreAndPublishesGuides() {
        let (v, c) = stage()
        v.elements = [StageElement(id: "a", name: "A", rect: CanvasRect(x: 100, y: 100, width: 100, height: 100), kind: .element)]
        let f = v.frameRect(in: c.size)
        c.pointerDown(x: f.x + 150, y: f.y + 150)
        // Centre 150 + 347 = 497 is 3 px from the frame centre 500: snaps to left edge 450.
        c.pointerMove(x: f.x + 150 + 347, y: f.y + 150)
        XCTAssertEqual(v.elements[0].rect.x, 450, accuracy: 1e-9)
        XCTAssertTrue(v.snapGuides.contains { $0.axis == .x && abs($0.position - (f.x + 500)) < 1e-9 })
        c.pointerUp(x: 0, y: 0); XCTAssertTrue(v.snapGuides.isEmpty, "guides clear on release")
    }

    func testCanvasMenuZOrderAndDelete() {
        let (v, c) = stage()
        var z: [([String], StageZOrderAction)] = [], deleted: [[String]] = []
        c.onZOrder = { z.append(($0, $1)) }
        c.onDelete = { deleted.append($0) }
        c.zOrderEnabled = { _ in [.sendBackward, .sendToBack] }
        v.elements = [StageElement(id: "a", name: "A", rect: CanvasRect(x: 100, y: 100, width: 100, height: 100), kind: .element)]
        let f = v.frameRect(in: c.size)
        c.secondaryClick(x: f.x + 150, y: f.y + 150)
        let menu = try! XCTUnwrap(v.contextMenu)
        XCTAssertEqual(v.selectedIds, ["a"]); XCTAssertEqual(menu.enabled, [.sendBackward, .sendToBack])
        let mf = menu.frame(in: CanvasRect(x: 0, y: 0, width: c.size.width, height: c.size.height))
        c.pointerDown(x: mf.x + 20, y: mf.y + 5 + 14)   // "Bring to front": disabled, menu stays
        XCTAssertNotNil(v.contextMenu); XCTAssertTrue(z.isEmpty)
        c.pointerDown(x: mf.x + 20, y: mf.y + 5 + 28 * 3 + 14)   // "Send to back"
        XCTAssertNil(v.contextMenu); XCTAssertEqual(z.first?.1, .sendToBack)
        c.secondaryClick(x: f.x + 150, y: f.y + 150)
        c.pointerDown(x: mf.x + 20, y: mf.y + 5 + 28 * 4 + 9 + 14)   // Delete
        XCTAssertEqual(deleted, [["a"]])
        c.secondaryClick(x: f.x + 150, y: f.y + 150)
        XCTAssertTrue(c.keyDown(EditorKey(.escape))); XCTAssertNil(v.contextMenu)
    }

    func testIconArcsEndWhereTheyShould() {
        var p = CanvasPath(); p.move(to: .init(3, 9)); p.arc(to: .init(7, 5), rx: 4, ry: 4, largeArc: false, sweep: true)
        let end = try! XCTUnwrap(p.currentPoint)
        XCTAssertEqual(end.x, 7, accuracy: 1e-9); XCTAssertEqual(end.y, 5, accuracy: 1e-9)
        if case .curve(let c1, _, _) = p.elements[1] { XCTAssertEqual(c1.x, 3, accuracy: 1e-9, "starts tangent to the vertical line") }
        XCTAssertEqual(PlayerIcons.playPause(0).elements.count, 10)
        if case .move(let a) = PlayerIcons.playPause(1).elements[5] { XCTAssertEqual(a.x, 73) }
    }

    func stage() -> (PlayerView, PlayerController) {
        let v = PlayerView(playback: PlaybackState(duration: 10)); v.canvasSize = CanvasSize(1000, 500)
        let c = PlayerController(view: v); c.size = CanvasSize(1016, 36 + 516 + 40)
        return (v, c)
    }
}

extension CanvasRect {
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
}
