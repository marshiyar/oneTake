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

/// The transform box through the controller's pointer and key entry points: edge stretch, corner aspect rules,
/// ⌥ from the anchor, rotating outside a corner and with the chip, the anchor (drag, pivot, double-click reset),
/// ⇧ axis lock, ⌘/Ctrl without snapping, resize snapping, the readout, 24 pt targets at any zoom, the cursor,
/// one commit per gesture and locked layers.
final class TransformBoxInteractionTests: XCTestCase {
    final class Rig {
        let view = PlayerView(playback: PlaybackState(duration: 10))
        let controller: PlayerController
        var commits: [StageElement] = []
        var groups: [[StageElement]] = []
        var now = 100.0
        static let defaultRect = CanvasRect(x: 600, y: 300, width: 400, height: 300)
        init(kind: TimelineClipKind = .element, rect: CanvasRect = Rig.defaultRect, rotation: Double = 0) {
            view.canvasSize = CanvasSize(1920, 1080)
            view.toolbar.snapEnabled = false
            controller = PlayerController(view: view)
            controller.size = CanvasSize(1440, 900)
            view.now = { [unowned self] in self.now }
            view.elements = [StageElement(id: "a", name: "A", rect: rect, kind: kind, rotation: rotation)]
            view.selectedIds = ["a"]
            controller.onCommit = { [unowned self] e in self.commits.append(e) }
        }
        var element: StageElement { view.elements[0] }
        var chrome: StageElement { view.chromeElement(element, in: controller.size) }
        var s: Double { view.scale(in: controller.size) }
        func point(_ u: CanvasPoint) -> CanvasPoint { TransformBox.screenPoint(chrome, unit: u) }
        /// Press at `from`, move to `to` (with `modifiers` held), release.
        func drag(_ from: CanvasPoint, _ to: CanvasPoint, modifiers: PointerModifiers = [], release: Bool = true) {
            controller.pointerDown(x: from.x, y: from.y)
            controller.modifiers = modifiers
            controller.pointerMove(x: to.x, y: to.y)
            if release { controller.pointerUp(x: to.x, y: to.y) }
        }
    }

    func close(_ a: CanvasPoint, _ b: CanvasPoint, _ tol: Double = 1e-6, _ msg: String = "", line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tol, "x \(msg)", line: line); XCTAssertEqual(a.y, b.y, accuracy: tol, "y \(msg)", line: line)
    }

    func testEdgeHandlesStretchOneAxisOfTheBox() {
        for h in TransformHandle.edges {
            let r = Rig()
            let start = r.element, p = r.point(h.unit)
            let out = CanvasPoint(p.x + (h.unit.x - 0.5) * 60, p.y + (h.unit.y - 0.5) * 60)   // 30 px outward
            r.drag(p, out)
            if h.movesX {
                XCTAssertEqual(r.element.rect.width, start.rect.width + 30 / r.s, accuracy: 1e-6, "\(h)")
                XCTAssertEqual(r.element.rect.height, start.rect.height, accuracy: 1e-9, "\(h)")
            } else {
                XCTAssertEqual(r.element.rect.height, start.rect.height + 30 / r.s, accuracy: 1e-6, "\(h)")
                XCTAssertEqual(r.element.rect.width, start.rect.width, accuracy: 1e-9, "\(h)")
            }
            XCTAssertEqual(r.commits.count, 1, "one commit per drag (\(h))")
        }
    }

    func testMediaCornersKeepTheirAspectAndShiftFreesThem() {
        let r = Rig(kind: .video)
        let se = r.point(TransformHandle.se.unit)
        r.drag(se, CanvasPoint(se.x + 60, se.y))
        XCTAssertEqual(r.element.rect.width / r.element.rect.height, 4.0 / 3, accuracy: 1e-9, "video corner keeps 4:3")
        let free = Rig(kind: .video)
        free.drag(se, CanvasPoint(se.x + 60, se.y), modifiers: .shift)
        XCTAssertEqual(free.element.rect.height, 300, accuracy: 1e-6, "⇧ frees the corner: only the width follows")
        XCTAssertGreaterThan(free.element.rect.width, 400)
    }

    func testShapeCornersAreFreeAndShiftKeepsTheirAspect() {
        let r = Rig(kind: .element)
        let se = r.point(TransformHandle.se.unit)
        r.drag(se, CanvasPoint(se.x + 60, se.y))
        XCTAssertEqual(r.element.rect.height, 300, accuracy: 1e-6, "free corner")
        let locked = Rig(kind: .element)
        locked.drag(se, CanvasPoint(se.x + 60, se.y), modifiers: .shift)
        XCTAssertEqual(locked.element.rect.width / locked.element.rect.height, 4.0 / 3, accuracy: 1e-9, "⇧ keeps 4:3")
    }

    func testAltScalesAboutTheAnchor() {
        let r = Rig()
        let centre = r.chrome.centre, e = r.point(TransformHandle.e.unit)
        r.drag(e, CanvasPoint(e.x + 20, e.y), modifiers: .alt)
        close(r.chrome.centre, centre, 1e-6, "centre fixed")
        XCTAssertEqual(r.element.rect.width, 400 + 40 / r.s, accuracy: 1e-6, "both sides grow")
    }

    func testDraggingJustOutsideACornerRotatesAndShiftSnapsToFifteenDegrees() {
        let r = Rig()
        let ne = r.point(TransformHandle.ne.unit), c = r.chrome.centre
        let zone = CanvasPoint(ne.x + 20, ne.y - 20)
        r.controller.pointerMove(x: zone.x, y: zone.y)
        XCTAssertEqual(r.controller.stageCursor, .rotate, "rotate cursor outside the corner")
        r.controller.pointerDown(x: zone.x, y: zone.y)
        let turned = PlayerView.rotate(zone, about: c, 37)
        r.controller.modifiers = .shift
        r.controller.pointerMove(x: turned.x, y: turned.y)
        XCTAssertEqual(r.element.rotation, 30, accuracy: 1e-9, "37° snaps to 30°")
        XCTAssertEqual(r.element.rect, Rig().element.rect, "about the centre the box stays put")
        XCTAssertEqual(r.view.transformChrome.readout?.text, "30.0°")
        r.controller.pointerUp(x: turned.x, y: turned.y)
        XCTAssertEqual(r.commits.count, 1)
        XCTAssertNil(r.view.transformChrome.readout, "readout clears on release")
    }

    func testTheRotateChipStillRotates() {
        let r = Rig()
        let chip = r.view.rotateHandleCentre(r.chrome), c = r.chrome.centre
        let to = PlayerView.rotate(chip, about: c, -45)
        r.drag(chip, to)
        XCTAssertEqual(r.element.rotation, -45, accuracy: 0.01)
        XCTAssertEqual(r.commits.count, 1)
    }

    func testRotationTurnsAboutAMovedAnchorAndADoubleClickResetsIt() {
        let r = Rig()
        let anchor = r.chrome.centre, nw = r.point(TransformHandle.nw.unit)
        r.drag(anchor, CanvasPoint(nw.x + 3, nw.y + 2))
        XCTAssertEqual(r.view.transformChrome.anchor("a"), CanvasPoint(0, 0), "snaps onto the corner")
        XCTAssertTrue(r.commits.isEmpty, "moving the anchor is not a document edit")
        let pivot = r.point(CanvasPoint(0, 0))
        let chip = r.view.rotateHandleCentre(r.chrome)
        r.controller.pointerDown(x: chip.x, y: chip.y)
        let to = PlayerView.rotate(chip, about: pivot, 90)
        r.controller.pointerMove(x: to.x, y: to.y)
        r.controller.pointerUp(x: to.x, y: to.y)
        XCTAssertEqual(r.element.rotation, 90, accuracy: 0.01)
        close(r.point(CanvasPoint(0, 0)), pivot, 0.05, "the top-left corner stayed under the anchor")
        // Double-click the anchor: back to the centre.
        let a = r.point(CanvasPoint(0, 0))
        r.controller.pointerDown(x: a.x, y: a.y); r.controller.pointerUp(x: a.x, y: a.y)
        r.now += 0.2
        r.controller.pointerDown(x: a.x, y: a.y); r.controller.pointerUp(x: a.x, y: a.y)
        XCTAssertEqual(r.view.transformChrome.anchor("a"), TransformBox.centreAnchor)
    }

    func testShiftLocksTheMoveToTheLargerAxis() {
        let r = Rig()
        let start = r.element, c = CanvasPoint(r.chrome.centre.x + 40, r.chrome.centre.y + 40)   // off the anchor
        r.drag(c, CanvasPoint(c.x + 80, c.y + 15), modifiers: .shift)
        XCTAssertEqual(r.element.rect.y, start.rect.y, "vertical locked")
        XCTAssertEqual(r.element.rect.x, start.rect.x + 80 / r.s, accuracy: 1e-9)
    }

    func testCommandOrCtrlDragsWithoutSnapping() {
        for held in [PointerModifiers.ctrl, .meta] {
            let r = Rig(rect: CanvasRect(x: 100, y: 100, width: 100, height: 100))
            r.view.toolbar.snapEnabled = true
            let f = r.view.frameRect(in: r.controller.size), c = r.chrome.centre
            let target = f.x + f.width / 2 - 3   // 3 px left of the frame centre
            let grab = CanvasPoint(c.x + 20, c.y + 20)   // off the anchor
            r.drag(grab, CanvasPoint(target + 20, grab.y), modifiers: held, release: false)
            XCTAssertEqual(r.chrome.centre.x, target, accuracy: 1e-6, "no snap with \(held)")
            XCTAssertTrue(r.view.snapGuides.isEmpty)
            r.controller.modifiers = []
            r.controller.pointerMove(x: target + 20, y: grab.y)
            XCTAssertEqual(r.chrome.centre.x, f.x + f.width / 2, accuracy: 1e-6, "snaps again once released")
        }
    }

    func testResizeSnapsTheDraggedEdgeToTheFrameCentreWithAGuide() {
        let r = Rig(rect: CanvasRect(x: 100, y: 100, width: 600, height: 300))
        r.view.toolbar.snapEnabled = true
        let f = r.view.frameRect(in: r.controller.size), e = r.point(TransformHandle.e.unit)
        let mid = f.x + f.width / 2
        r.drag(e, CanvasPoint(mid + 4, e.y), release: false)
        XCTAssertEqual(r.chrome.visibleRect.maxX, mid, accuracy: 1e-6, "right edge snapped to the frame centre")
        XCTAssertTrue(r.view.snapGuides.contains { $0.axis == .x && abs($0.position - mid) < 1e-6 })
        XCTAssertEqual(r.view.transformChrome.readout?.text, "W 860 × H 300")
        r.controller.pointerUp(x: mid + 4, y: e.y)
        XCTAssertTrue(r.view.snapGuides.isEmpty)
    }

    func testMoveReadoutShowsThePositionFromTheOrigin() {
        let r = Rig()
        r.controller.readoutOrigin = { _ in CanvasPoint(100, 50) }
        let c = CanvasPoint(r.chrome.centre.x + 40, r.chrome.centre.y + 40)
        r.drag(c, CanvasPoint(c.x + 10 * r.s, c.y + 20 * r.s), release: false)
        XCTAssertEqual(r.view.transformChrome.readout?.text, "X 510  Y 270")
    }

    func testHandleTargetsAreTwentyFourPointsAtEveryZoom() {
        for zoom in [PreviewZoom.fit, PreviewZoom(percent: 300)] {
            let r = Rig(rect: CanvasRect(x: 860, y: 440, width: 200, height: 200))
            r.view.zoom = zoom
            let ve = r.chrome, se = TransformBox.localPoint(ve, unit: TransformHandle.se.unit)
            let edge = PlayerView.rotate(CanvasPoint(se.x + 11.5, se.y - 11.5), about: ve.centre, 0)
            XCTAssertEqual(r.controller.transformHit(edge, ve), .handle(.se), "11.5 pt from the dot still hits (zoom \(zoom.percent))")
        }
        let small = Rig(rect: CanvasRect(x: 900, y: 500, width: 40, height: 40))
        XCTAssertFalse(small.view.showsHandle(.e, of: small.chrome), "short sides leave the room to the corners")
        XCTAssertTrue(small.view.showsHandle(.se, of: small.chrome))
    }

    func testCursorFollowsTheHoveredPart() {
        let r = Rig(rotation: 90)
        let e = r.point(TransformHandle.e.unit)
        r.controller.pointerMove(x: e.x, y: e.y)
        XCTAssertEqual(r.controller.stageCursor, .resize(degrees: 90), "the east handle of a box turned 90° resizes vertically")
        let c = r.chrome.centre
        r.controller.pointerMove(x: c.x + 40, y: c.y + 40)
        XCTAssertEqual(r.controller.stageCursor, .move)
        r.controller.pointerMove(x: c.x, y: c.y)
        XCTAssertEqual(r.controller.stageCursor, .anchor)
    }

    func testAGroupMoveCommitsEveryMemberAtOnce() {
        let r = Rig()
        r.view.elements.append(StageElement(id: "b", name: "B", rect: CanvasRect(x: 100, y: 100, width: 200, height: 200), kind: .element))
        r.view.selectedIds = ["a", "b"]
        r.controller.onCommitGroup = { [unowned r] es in r.groups.append(es) }
        let c = r.chrome.centre
        r.drag(c, CanvasPoint(c.x + 30, c.y + 30))
        XCTAssertEqual(r.groups.count, 1, "one group commit")
        XCTAssertEqual(r.groups.first?.map(\.id).sorted(), ["a", "b"])
        XCTAssertTrue(r.commits.isEmpty)
    }

    /// Codacy review on #338: a group of only locked layers started a gesture with no members, and its snap read
    /// the first member's bounds out of range.
    func testAGroupOfOnlyLockedLayersDoesNotMoveOrCrash() {
        let r = Rig()
        r.view.elements[0].locked = true
        r.view.elements.append(StageElement(id: "b", name: "B", rect: CanvasRect(x: 100, y: 100, width: 200, height: 200),
                                            kind: .element, locked: true))
        r.view.selectedIds = ["a", "b"]
        r.view.toolbar.snapEnabled = true
        let start = r.view.elements, c = CanvasPoint(r.chrome.centre.x + 40, r.chrome.centre.y + 40)
        r.drag(c, CanvasPoint(c.x + 30, c.y + 30))
        XCTAssertEqual(r.view.elements, start)
        XCTAssertTrue(r.commits.isEmpty)
        XCTAssertEqual(r.view.toast?.message, PlayerController.lockedMessage)
    }

    func testLockedLayersSelectButDoNotTransform() {
        let r = Rig()
        r.view.elements[0].locked = true
        r.view.selectedIds = []
        let start = r.element, c = r.chrome.centre
        r.drag(c, CanvasPoint(c.x + 50, c.y + 50))
        XCTAssertEqual(r.view.selectedIds, ["a"], "a locked layer can be selected")
        XCTAssertEqual(r.element, start, "but not moved")
        XCTAssertEqual(r.view.toast?.message, PlayerController.lockedMessage)
        let se = r.point(TransformHandle.se.unit)
        r.drag(CanvasPoint(se.x - 2, se.y - 2), CanvasPoint(se.x + 40, se.y + 40))
        XCTAssertEqual(r.element, start, "nor resized")
        XCTAssertTrue(r.controller.keyDown(EditorKey(.right)), "the arrow is consumed")
        r.controller.flushNudge()
        XCTAssertEqual(r.element, start, "nor nudged")
        XCTAssertTrue(r.commits.isEmpty)
        r.controller.pointerMove(x: c.x, y: c.y)
        XCTAssertEqual(r.controller.stageCursor, .notAllowed)
    }
}
