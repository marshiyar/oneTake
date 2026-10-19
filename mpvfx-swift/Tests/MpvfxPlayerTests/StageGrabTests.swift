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
import MpvfxShared

/// Grabbing a clip on the stage: a click selects without moving,
/// a press only moves after BLOCKED_MOVE_THRESHOLD_PX (4 px), a drag keeps the grab offset so the point under the
/// cursor stays under it, corner resizes keep the opposite corner fixed and the handle under the cursor, and the
/// picture the preview paints while a clip is held sits exactly on its selection box. Media clips sit at their
/// natural-size box (layout.left/top not zero), the case that drew a held clip offset by its layout origin.
final class StageGrabTests: XCTestCase {
    final class Rig {
        let editor: TimelineEditor
        let view: PlayerView
        let controller: PlayerController
        let id: String
        let compositor = PreviewCompositor(decodesMedia: false)
        var commits: [StageElement] = []
        init(asset: String = "sq", size: CanvasSize = CanvasSize(1280, 800), zoom: PreviewZoom = .fit,
             rotation: Double = 0, scale: Double? = nil, kind: TimelineClipKind = .video) throws {
            editor = try TimelineEditor(json: MediaNaturalSizeTests.json())
            editor.naturalSize = { a in ["sq": MediaNaturalSizeTests.square, "po": MediaNaturalSizeTests.portrait,
                                         "wi": MediaNaturalSizeTests.wide][a.id] }
            id = try XCTUnwrap(editor.insertClip(assetId: asset, at: 0))
            view = PlayerView(playback: PlaybackState(duration: 10))
            view.canvasSize = CanvasSize(1920, 1080)
            view.toolbar.snapEnabled = false
            controller = PlayerController(view: view)
            controller.size = size
            view.zoom = zoom
            let rect = StageGeometry.rect(editor: editor, clipId: id, kind: .video, time: 0)
            view.elements = [StageElement(id: id, name: "clip", rect: rect, kind: kind, rotation: rotation, scale: scale)]
            controller.onCommit = { [unowned self] e in self.commits.append(e) }
            // The preview draws the document's composition (natural-size boxes) with a decoded picture in its cache.
            let comp = PreviewComposition(document: editor.document, projectDir: URL(fileURLWithPath: "/p"), engine: nil,
                                          naturalSize: editor.naturalSize, fileExists: { _ in true })
            compositor.composition = comp
            if let layer = comp.layers(at: 0).first {
                let n = editor.naturalSize(editor.document.assets.first { $0.id == asset }!)!
                let want = layer.kind == .image ? PreviewDecodeLane.stillFrame : comp.frameIndex(at: 0)
                compositor.cache.store(PreviewCompositorTests.solid(255, 255, 255, w: Int(n.width / 10), h: Int(n.height / 10)),
                                       lane: layer.laneKey, frame: want)
            }
        }
        var element: StageElement { view.elements[0] }
        var chrome: StageElement { view.chromeElement(element, in: controller.size) }
        var viewScale: Double { view.scale(in: controller.size) }
        /// Screen point of an element-local offset from the chrome box centre (rotated with the element).
        func screen(_ e: StageElement, offset o: CanvasPoint) -> CanvasPoint {
            let c = e.centre
            return PlayerView.rotate(CanvasPoint(c.x + o.x, c.y + o.y), about: c, e.rotation)
        }
        /// Element-local offset of a screen point from the chrome box centre.
        func offset(_ e: StageElement, of p: CanvasPoint) -> CanvasPoint {
            let l = PlayerView.rotate(p, about: e.centre, -e.rotation)
            return CanvasPoint(l.x - e.centre.x, l.y - e.centre.y)
        }
        func corner(_ e: StageElement, _ h: PlayerView.HandleCorner) -> CanvasPoint {
            PlayerView.rotate(view.handleCentre(h, of: e.visibleRect), about: e.centre, e.rotation)
        }
        /// Where the preview paints the clip's picture right now (view px), as the stage draws it.
        func painted() throws -> CanvasRect {
            let c = PreviewRecordingCanvas()
            compositor.draw(c, in: view.frameRect(in: controller.size), time: 0,
                            elements: view.elements.map { view.viewElement($0, in: controller.size) },
                            context: FrameDrawContext(liveElementIds: controller.editingIds))
            return try XCTUnwrap(c.images.first).rect
        }
    }

    func assertClose(_ a: CanvasPoint, _ b: CanvasPoint, _ accuracy: Double = 1e-6, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "\(msg) x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "\(msg) y", file: file, line: line)
    }

    // MARK: select-click (the reported bug)

    /// The exact user action: click a natural-size, contain-fit media clip (its box does not fill the frame) on a
    /// zoomed preview to select it. Its position, size and rotation are bit-identical afterwards, nothing commits,
    /// and the picture the preview paints is the same rect before the press, while held and after release
    /// (it used to jump by the clip's layout.left/top while the button was down).
    func testSelectClickOnANaturalSizeClipAtNon1xZoomIsBitIdentical() throws {
        let zooms = [PreviewZoom(percent: 200), PreviewZoom(percent: 150, panX: 30, panY: -15), PreviewZoom(percent: 125)]
        for asset in ["sq", "po", "wi"] { for zoom in zooms { for size in [CanvasSize(1280, 800), CanvasSize(2000, 1200)] {
            let r = try Rig(asset: asset, size: size, zoom: zoom)
            let tag = "\(asset) zoom \(zoom.percent) at \(size.width)x\(size.height)"
            XCTAssertNotEqual(r.viewScale, 1, tag)
            XCTAssertNotNil(r.editor.naturalLayout(clipId: r.id), "untouched natural box (\(tag))")
            r.view.playback.seek(0)
            let start = r.element, paintedBefore = try r.painted()
            XCTAssertNotEqual(start.rect.x + start.rect.y, 0, "box sits off the frame origin (\(tag))")
            let p = CanvasPoint(r.chrome.centre.x + 12, r.chrome.centre.y - 7)
            XCTAssertTrue(r.view.viewportRect(in: r.controller.size).contains(p), tag)
            r.controller.pointerDown(x: p.x, y: p.y)
            XCTAssertEqual(r.view.selectedIds, [r.id], "the click selects (\(tag))")
            XCTAssertEqual(try r.painted(), paintedBefore, "no jump while the button is down (\(tag))")
            r.controller.pointerUp(x: p.x, y: p.y)
            let end = r.element
            XCTAssertEqual(end.rect.x.bitPattern, start.rect.x.bitPattern, tag)
            XCTAssertEqual(end.rect.y.bitPattern, start.rect.y.bitPattern, tag)
            XCTAssertEqual(end.rect.width.bitPattern, start.rect.width.bitPattern, tag)
            XCTAssertEqual(end.rect.height.bitPattern, start.rect.height.bitPattern, tag)
            XCTAssertEqual(end.rotation.bitPattern, start.rotation.bitPattern, tag)
            XCTAssertEqual(end, start, tag)
            XCTAssertTrue(r.commits.isEmpty, "a click commits no edit (\(tag))")
            XCTAssertEqual(try r.painted(), paintedBefore, "same picture after release (\(tag))")
            XCTAssertEqual(r.view.playback.currentTime, 0, "the playhead stays (\(tag))")
        } } }
    }

    /// Trackpad tap: press and release with 1-2 px of jitter in between. Nothing moves, nothing commits, the
    /// painted picture never shifts.
    func testTrackpadTapWithSubThresholdJitterIsBitIdentical() throws {
        for zoom in [PreviewZoom.fit, PreviewZoom(percent: 200)] { for (rot, k) in [(0.0, nil), (30.0, 1.5)] as [(Double, Double?)] {
            let r = try Rig(asset: "sq", zoom: zoom, rotation: rot, scale: k)
            let tag = "zoom \(zoom.percent) rot \(rot)"
            r.view.playback.seek(1.25)
            let start = r.element, paintedBefore = try r.painted()
            let p = r.chrome.centre
            r.controller.pointerDown(x: p.x, y: p.y)
            for d in [CanvasPoint(1, 0), CanvasPoint(1, 1), CanvasPoint(2, -1), CanvasPoint(-1, 2), CanvasPoint(2, 2)] {
                r.controller.pointerMove(x: p.x + d.x, y: p.y + d.y)
                XCTAssertEqual(r.element, start, "jitter \(d) moves nothing (\(tag))")
                XCTAssertEqual(try r.painted(), paintedBefore, "jitter \(d) paints in place (\(tag))")
            }
            r.controller.pointerUp(x: p.x + 2, y: p.y + 2)
            XCTAssertEqual(r.element, start, tag)
            XCTAssertEqual(r.element.rect.x.bitPattern, start.rect.x.bitPattern, tag)
            XCTAssertEqual(r.element.rect.y.bitPattern, start.rect.y.bitPattern, tag)
            XCTAssertTrue(r.commits.isEmpty, tag)
            XCTAssertEqual(r.view.playback.currentTime, 1.25, "a tap never moves the playhead (\(tag))")
        } }
    }

    func testJitterUpToTheThresholdDoesNotMove() throws {
        let r = try Rig()
        let start = r.element
        let p = r.chrome.centre
        r.controller.pointerDown(x: p.x, y: p.y)
        for d in [CanvasPoint(-3, 1), CanvasPoint(2.8, 2.8), CanvasPoint(0, -3.9)] {   // all under 4 px
            r.controller.pointerMove(x: p.x + d.x, y: p.y + d.y)
            XCTAssertEqual(r.element, start, "jitter \(d) under the 4 px threshold moves nothing")
        }
        r.controller.pointerMove(x: p.x + 4, y: p.y)   // at the threshold the drag starts, from the press point
        XCTAssertEqual(r.element.rect.x, start.rect.x + 4 / r.viewScale, accuracy: 1e-9)
        r.controller.pointerUp(x: p.x + 4, y: p.y)
        XCTAssertEqual(r.commits.count, 1)
    }

    // MARK: move keeps the grab offset

    /// A drag of N view px moves the clip N / scale composition px at several view sizes and zooms, for natural-size
    /// clips that do not fill the frame, rotated and scaled; the grabbed point stays under the cursor the whole way
    /// (so the clip's centre keeps its offset from the cursor) and the painted picture stays on the selection box.
    func testDragKeepsTheGrabbedPointUnderTheCursorAtEveryScale() throws {
        let sizes = [CanvasSize(1280, 800), CanvasSize(640, 420), CanvasSize(2200, 1300)]
        let zooms = [PreviewZoom.fit, PreviewZoom(percent: 200), PreviewZoom(percent: 150, panX: 40, panY: -20)]
        let shapes: [(String, Double, Double?)] = [("sq", 0, nil), ("wi", 0, nil), ("po", 0, nil), ("sq", 30, nil), ("wi", -45, 1.5), ("sq", 0, 0.6)]
        for size in sizes { for zoom in zooms { for (asset, rot, k) in shapes {
            let r = try Rig(asset: asset, size: size, zoom: zoom, rotation: rot, scale: k)
            let tag = "\(asset) rot \(rot) scale \(k ?? 1) at \(size.width)x\(size.height) zoom \(zoom.percent)"
            let start = r.element, startChrome = r.chrome
            let grab = CanvasPoint(min(startChrome.rect.width * 0.25, 30), min(startChrome.rect.height * 0.2, 18))   // off-centre
            let p = r.screen(startChrome, offset: grab)
            let centreOffset = CanvasPoint(startChrome.centre.x - p.x, startChrome.centre.y - p.y)
            r.controller.pointerDown(x: p.x, y: p.y)
            XCTAssertEqual(r.view.selectedIds, [r.id], tag)
            let n = CanvasPoint(37, -23)
            for i in 1...6 {
                let f = Double(i) / 6, q = CanvasPoint(p.x + n.x * f, p.y + n.y * f)
                r.controller.pointerMove(x: q.x, y: q.y)
                guard hypot(n.x * f, n.y * f) >= PlayerController.dragThreshold else { continue }
                assertClose(r.offset(r.chrome, of: q), grab, 1e-6, "grabbed point under the cursor (\(tag), step \(i))")
                assertClose(CanvasPoint(r.chrome.centre.x - q.x, r.chrome.centre.y - q.y), centreOffset, 1e-6, "centre offset (\(tag))")
            }
            if k == nil, rot == 0 {
                let pic = try r.painted(), sel = r.chrome.rect
                XCTAssertEqual(pic.x, sel.x, accuracy: 0.5, "picture follows the box (\(tag))")
                XCTAssertEqual(pic.y, sel.y, accuracy: 0.5, "picture follows the box (\(tag))")
            }
            let s = r.viewScale
            XCTAssertEqual(r.element.rect.x - start.rect.x, n.x / s, accuracy: 1e-6, tag)
            XCTAssertEqual(r.element.rect.y - start.rect.y, n.y / s, accuracy: 1e-6, tag)
            XCTAssertEqual(r.element.rect.width, start.rect.width, tag); XCTAssertEqual(r.element.rect.height, start.rect.height, tag)
            XCTAssertEqual(r.element.rotation, start.rotation, tag)
            r.controller.pointerUp(x: p.x + n.x, y: p.y + n.y)
            XCTAssertEqual(r.commits.count, 1, tag)
        } } }
    }

    /// The painted picture sits on the selection box before the press, while pressed and while dragged
    /// (the live stage rect already carries layout.left/top; it must not be offset by them again).
    func testHeldClipPaintsOnItsSelectionBox() throws {
        for (asset, size) in [("sq", CanvasSize(1280, 800)), ("wi", CanvasSize(900, 700)), ("po", CanvasSize(1600, 900))] {
            let r = try Rig(asset: asset, size: size)
            func assertOnSelection(_ msg: String) throws {
                let pic = try r.painted(), sel = r.chrome.rect
                for (a, b, edge) in [(pic.x, sel.x, "left"), (pic.y, sel.y, "top"), (pic.maxX, sel.maxX, "right"), (pic.maxY, sel.maxY, "bottom")] {
                    XCTAssertEqual(a, b, accuracy: 0.5, "\(asset) \(edge) \(msg)")
                }
            }
            try assertOnSelection("before the press")
            let p = CanvasPoint(r.chrome.centre.x + 10, r.chrome.centre.y - 6)
            r.controller.pointerDown(x: p.x, y: p.y)
            XCTAssertTrue(r.controller.editingIds.contains(r.id))
            try assertOnSelection("while pressed")
            r.controller.pointerMove(x: p.x + 60, y: p.y + 25)
            try assertOnSelection("while dragged")
            r.controller.pointerUp(x: p.x + 60, y: p.y + 25)
        }
    }

    // MARK: corner resize

    /// A corner drag keeps the opposite corner fixed on the stage, and the grabbed handle stays under the cursor
    /// (grab offset kept), for free elements and proportional media, rotated and scaled.
    func testCornerDragKeepsTheOppositeCornerAndTheHandleUnderTheCursor() throws {
        let opposite: [PlayerView.HandleCorner: PlayerView.HandleCorner] = [.nw: .se, .ne: .sw, .sw: .ne, .se: .nw]
        let cases: [(TimelineClipKind, Double, Double?, CanvasSize, PreviewZoom)] = [
            // Tall views so every corner of the (zoomed, rotated) box stays inside the stage viewport.
            (.element, 0, nil, CanvasSize(1280, 1100), .fit), (.video, 0, nil, CanvasSize(1600, 1500), PreviewZoom(percent: 125)),
            (.video, 30, nil, CanvasSize(900, 1000), .fit), (.element, -20, 0.6, CanvasSize(1600, 1500), PreviewZoom(percent: 150)),
            (.video, 60, 0.75, CanvasSize(1600, 1500), PreviewZoom(percent: 125)),
        ]
        for (kind, rot, k, size, zoom) in cases { for h in PlayerView.HandleCorner.allCases {
            let r = try Rig(asset: "sq", size: size, zoom: zoom, rotation: rot, scale: k, kind: kind)
            r.view.selectedIds = [r.id]
            let tag = "\(kind) rot \(rot) scale \(k ?? 1) zoom \(zoom.percent) corner \(h)"
            let ve = r.chrome, rect = ve.visibleRect
            let anchorBefore = r.corner(ve, opposite[h]!)
            let handle = r.view.handleCentre(h, of: rect)
            let grab = CanvasPoint(3, -2)                      // pressed a little off the dot's centre
            let press = PlayerView.rotate(CanvasPoint(handle.x + grab.x, handle.y + grab.y), about: ve.centre, ve.rotation)
            XCTAssertTrue(r.view.viewportRect(in: r.controller.size).contains(press), "press inside the stage (\(tag))")
            r.controller.pointerDown(x: press.x, y: press.y)
            // Outward along the diagonal (proportional, so media follows exactly), in the element's frame.
            let sx: Double = (h == .ne || h == .se) ? 1 : -1, sy: Double = (h == .sw || h == .se) ? 1 : -1
            let d = 40.0, dl = CanvasPoint(sx * d, sy * d * rect.height / rect.width)
            let targetLocal = CanvasPoint(handle.x + dl.x + grab.x, handle.y + dl.y + grab.y)
            let cursor = PlayerView.rotate(targetLocal, about: ve.centre, ve.rotation)
            r.controller.pointerMove(x: cursor.x, y: cursor.y)
            let after = r.chrome
            assertClose(r.corner(after, opposite[h]!), anchorBefore, 1e-6, "opposite corner fixed (\(tag))")
            let expected = PlayerView.rotate(CanvasPoint(targetLocal.x - grab.x, targetLocal.y - grab.y), about: ve.centre, ve.rotation)
            assertClose(r.corner(after, h), expected, 1e-6, "handle under the cursor, grab offset kept (\(tag))")
            XCTAssertEqual(after.rotation, rot, tag)
            XCTAssertEqual(r.element.scale, k, "scale untouched (\(tag))")
            r.controller.pointerUp(x: cursor.x, y: cursor.y)
            XCTAssertEqual(r.commits.count, 1, tag)
        } }
    }

    func testClickOnAHandleWithNoMovementChangesNothing() throws {
        for (rot, k) in [(0.0, nil), (30.0, 0.7)] as [(Double, Double?)] { for h in PlayerView.HandleCorner.allCases {
            let r = try Rig(size: CanvasSize(1600, 1500), zoom: PreviewZoom(percent: 125), rotation: rot, scale: k)
            r.view.selectedIds = [r.id]
            let start = r.element, ve = r.chrome
            let c = r.view.handleCentre(h, of: ve.visibleRect)
            let p = PlayerView.rotate(CanvasPoint(c.x + 4, c.y - 3), about: ve.centre, ve.rotation)
            XCTAssertTrue(r.view.viewportRect(in: r.controller.size).contains(p), "press inside the stage (\(h))")
            r.controller.pointerDown(x: p.x, y: p.y)
            var isResize = false
            if case .resize? = r.controller.gesture { isResize = true }
            XCTAssertTrue(isResize, "handle pressed (\(h), rot \(rot))")
            r.controller.pointerMove(x: p.x + 1.5, y: p.y - 2)   // jitter
            XCTAssertEqual(r.element, start, "jitter on a handle resizes nothing (\(h))")
            r.controller.pointerUp(x: p.x + 1.5, y: p.y - 2)
            XCTAssertEqual(r.element, start, "click on handle \(h) changes nothing")
            XCTAssertTrue(r.commits.isEmpty)
        } }
    }

    // MARK: commit round trip

    /// The rect a drag commits lands the clip where it was dropped (the base it offsets is the natural box
    /// origin), so the picture does not jump on release either.
    func testCommittedMoveLandsWhereTheClipWasDropped() throws {
        let r = try Rig(asset: "wi", zoom: PreviewZoom(percent: 150))
        let start = r.element
        let p = r.chrome.centre
        r.controller.pointerDown(x: p.x, y: p.y)
        r.controller.pointerMove(x: p.x + 50, y: p.y + 30)
        r.controller.pointerUp(x: p.x + 50, y: p.y + 30)
        let dropped = try XCTUnwrap(r.commits.first)
        let base = StageGeometry.baseRect(editor: r.editor, clipId: r.id, kind: .video, time: 0)
        let tr = StageGeometry.transform(base: base, start: start, end: dropped)
        XCTAssertTrue(r.editor.applyTransform(clipId: r.id, time: 0, tr))
        let landed = StageGeometry.rect(editor: r.editor, clipId: r.id, kind: .video, time: 0)
        XCTAssertEqual(landed.x, dropped.rect.x, accuracy: 1e-9); XCTAssertEqual(landed.y, dropped.rect.y, accuracy: 1e-9)
        XCTAssertEqual(landed.width, dropped.rect.width); XCTAssertEqual(landed.height, dropped.rect.height)
    }

    /// The stage chrome follows a uniform transform.scale (the preview scales the picture about its centre).
    func testUniformScaleIsReadForTheStageChrome() throws {
        let r = try Rig()
        XCTAssertNil(StageGeometry.uniformScale(editor: r.editor, clipId: r.id, time: 0))
        let t = r.editor.document.sequence.tracks[0]
        let a = NativeProjectParameterAddress(sequenceId: r.editor.sequenceId, trackId: t.id, clipId: r.id, parameterId: "transform.scale")
        XCTAssertTrue(r.editor.applyProperty(.atomic(.setStatic(address: a, value: .number(1.5)))))
        XCTAssertEqual(StageGeometry.uniformScale(editor: r.editor, clipId: r.id, time: 0), 1.5)
    }
}
