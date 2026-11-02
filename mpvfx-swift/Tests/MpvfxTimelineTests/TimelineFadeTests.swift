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
import MpvfxShared
import MpvfxTheme
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Clip fades on the timeline (#90): the editor command, the drag on the corner handles, the menu and the drawing.
final class TimelineFadeTests: XCTestCase {
    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 300)
        c.setZoom(pixelsPerSecond: 100)
        return (c, e)
    }
    func clip(_ e: TimelineEditor, _ id: String) -> NativeProjectClip? { e.document.sequence.tracks.flatMap(\.clips).first { $0.id == id } }
    /// clip:a: 6 s (180 frames) on the second row, 100 px per second.
    func rect(_ c: TimelineController, _ id: String = "clip:a") throws -> CanvasRect {
        let (row, m) = try XCTUnwrap(c.clip(id))
        return c.view.clipRect(track: row, m, preview: false)
    }
    func drag(_ c: TimelineController, from x0: Double, to x1: Double, y: Double) {
        c.pointerDown(x: x0, y: y)
        c.pointerMove(x: x1, y: y)
        c.pointerUp(x: x1, y: y)
    }

    // MARK: Editor command

    func testSetClipFadeStoresWholeFramesAndIsOneUndoStep() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .start, frames: 29.6))
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 30)
        XCTAssertNil(clip(e, "clip:a")?.fadeOutFrames)
        XCTAssertEqual(e.undoStack.count, 1)
        XCTAssertTrue(e.undo())
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames)
        XCTAssertTrue(e.redo())
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 30)
    }

    func testAZeroFadeRemovesTheField() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 12))
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 0))
        XCTAssertNil(clip(e, "clip:a")?.fadeOutFrames, "a fade of zero is not stored")
    }

    func testFadesCannotCrossOrPassTheClip() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 150))
        XCTAssertEqual(e.maxFadeFrames(clipId: "clip:a", edge: .start), 30)
        XCTAssertFalse(e.setClipFade(clipId: "clip:a", edge: .start, frames: 31))
        XCTAssertEqual(e.lastFailure?.code, .invalidTrim)
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames)
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .start, frames: 30))
        XCTAssertFalse(e.setClipFade(clipId: "clip:b", edge: .end, frames: 121), "longer than the 120-frame clip")
        for bad in [-1.0, .nan, .infinity] { XCTAssertFalse(e.setClipFade(clipId: "clip:b", edge: .start, frames: bad)) }
    }

    func testALockedTrackRefusesTheFade() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        let before = e.document
        XCTAssertFalse(e.setClipFade(clipId: "clip:a", edge: .start, frames: 10))
        XCTAssertFalse(e.addDefaultFade(clipId: "clip:a", edge: .start))
        XCTAssertFalse(e.removeFades(clipId: "clip:a"))
        XCTAssertEqual(e.lastFailure?.message, "Track is locked")
        XCTAssertEqual(e.document, before)
    }

    func testDefaultFadeIsOneSecondAndCutToTheRoom() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.addDefaultFade(clipId: "clip:a", edge: .start))
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 30)
        XCTAssertTrue(e.removeFades(clipId: "clip:a"))
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 160))
        XCTAssertTrue(e.addDefaultFade(clipId: "clip:a", edge: .start), "the 20 frames that are left")
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 20)
        XCTAssertTrue(e.addDefaultFade(clipId: "clip:a", edge: .end), "replaces the long fade-out with the default")
        XCTAssertEqual(clip(e, "clip:a")?.fadeOutFrames, 30)
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 20)
    }

    func testRemoveFadesClearsBothInOneStep() throws {
        let (_, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .start, frames: 10))
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 20))
        let steps = e.undoStack.count
        XCTAssertTrue(e.removeFades(clipId: "clip:a"))
        XCTAssertEqual(e.undoStack.count, steps + 1)
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames); XCTAssertNil(clip(e, "clip:a")?.fadeOutFrames)
        XCTAssertFalse(e.removeFades(clipId: "clip:a"), "nothing left to remove")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(clip(e, "clip:a")?.fadeOutFrames, 20)
    }

    func testTheModelCarriesTheFadesInSeconds() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .start, frames: 15))
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 45))
        let m = try XCTUnwrap(c.clip("clip:a")).clip
        XCTAssertEqual(m.fadeIn, 0.5, accuracy: 1e-9); XCTAssertEqual(m.fadeOut, 1.5, accuracy: 1e-9)
    }

    // MARK: The drag

    func testDraggingTheFadeInHandle30FramesRightSetsFadeInFramesTo30() throws {
        let (c, e) = try make()
        let r = try rect(c)
        drag(c, from: r.x + 4, to: r.x + 4 + 100, y: r.y + 6)    // 100 px = 1 s = 30 frames
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 30)
        XCTAssertEqual(e.undoStack.count, 1, "one undo step")
        XCTAssertEqual(c.view.selection, ["clip:a"])
        XCTAssertNil(c.view.drag); XCTAssertNil(c.gesture)
        XCTAssertTrue(e.undo())
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames)
    }

    func testDraggingTheFadeOutHandleLeftSetsFadeOutFrames() throws {
        let (c, e) = try make()
        let r = try rect(c)
        drag(c, from: r.maxX - 4, to: r.maxX - 4 - 50, y: r.y + 6)
        XCTAssertEqual(clip(e, "clip:a")?.fadeOutFrames, 15)
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames)
    }

    func testTheHandleFollowsThePointerFromWhereItWasGrabbed() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .start, frames: 30))
        let r = try rect(c)
        let apex = r.x + 100
        c.pointerDown(x: apex + 3, y: r.y + 6)
        c.pointerMove(x: apex + 3 + 50, y: r.y + 6)
        guard case let .fade(_, edge, seconds, _)? = c.view.drag else { return XCTFail("no fade preview") }
        XCTAssertEqual(edge, .start); XCTAssertEqual(seconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(c.view.fadePreview(try XCTUnwrap(c.clip("clip:a")).clip).fadeIn, 1.5, accuracy: 1e-9)
        c.pointerUp(x: apex + 53, y: r.y + 6)
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 45)
    }

    func testTheHandleCannotPassTheOppositeFadeOrTheClipEnd() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 150))
        var r = try rect(c)
        drag(c, from: r.x + 4, to: r.x + 4 + 590, y: r.y + 6)
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 30, "stops where the fade-out starts")
        XCTAssertEqual(clip(e, "clip:a")?.fadeOutFrames, 150)
        XCTAssertTrue(e.removeFades(clipId: "clip:a"))
        r = try rect(c)
        drag(c, from: r.x + 4, to: r.x + 4 + 5000, y: r.y + 6)
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 180, "stops at the clip's end")
        r = try rect(c)
        drag(c, from: r.maxX - 4, to: r.x - 300, y: r.y + 6)    // the handle now sits at the clip's end
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames, "dragged back past the start: no fade")
    }

    func testTheDragSnapsToThePlayheadWhenSnappingIsOn() throws {
        let (c, e) = try make()
        c.playback.seek(2)
        let r = try rect(c)
        drag(c, from: r.x + 4, to: r.x + 4 + 203, y: r.y + 6)    // 2.03 s, within 8 px of the playhead at 2 s
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 60)
        XCTAssertTrue(e.undo())
        c.snapEnabled = false
        drag(c, from: r.x + 4, to: r.x + 4 + 203, y: r.y + 6)
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 61, "2.03 s is frame 61 without the snap")
    }

    func testALockedTrackRefusesTheGesture() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        let r = try rect(c)
        let before = e.document
        c.pointerDown(x: r.x + 4, y: r.y + 6)
        let steps = e.undoStack.count
        XCTAssertNil(c.gesture, "no drag starts, the way a trim is refused")
        c.pointerMove(x: r.x + 104, y: r.y + 6); c.pointerUp(x: r.x + 104, y: r.y + 6)
        XCTAssertEqual(e.document, before)
        XCTAssertEqual(e.undoStack.count, steps)
    }

    func testTheTrimHandleBelowTheCornerStillTrims() throws {
        let (c, e) = try make()
        let r = try rect(c, "clip:b")
        let before = clip(e, "clip:b")?.durationFrames
        drag(c, from: r.maxX - 3, to: r.maxX - 33, y: r.y + r.height - 4)    // the edge goes to the pointer: 0.33 s earlier
        XCTAssertEqual(clip(e, "clip:b")?.durationFrames, (before ?? 0) - 10)
        XCTAssertNil(clip(e, "clip:b")?.fadeOutFrames)
    }

    func testElementsHaveNoFadeHandles() throws {
        let (c, _) = try make()
        var model = TimelineClipModel(name: "Title", start: 0, duration: 4, kind: .element)
        model.fadeIn = 0
        c.view.tracks = [TimelineTrackModel(name: "T", kind: "mixed", clips: [model])]
        let r = c.view.clipRect(track: 0, model, preview: false)
        XCTAssertNil(c.fadeHandleHit(x: r.x + 4, y: r.y + 6))
    }

    func testClipsNarrowerThan24PixelsShowNoHandles() {
        let narrow = CanvasRect(x: 100, y: 10, width: 23.9, height: 26)
        XCTAssertNil(TimelineView.fadeHandleRect(narrow, edge: .start, fadePx: 0))
        XCTAssertNil(TimelineView.fadeHandleRect(narrow, edge: .end, fadePx: 0))
        let wide = CanvasRect(x: 100, y: 10, width: 24, height: 26)
        XCTAssertNotNil(TimelineView.fadeHandleRect(wide, edge: .start, fadePx: 0))
        XCTAssertNotNil(TimelineView.fadeHandleRect(wide, edge: .end, fadePx: 0))
    }

    func testTheHandleSitsAtTheRampEndAndStaysInsideTheClip() {
        let r = CanvasRect(x: 100, y: 10, width: 200, height: 26)
        let s = TimelineView.fadeHandleSize
        XCTAssertEqual(TimelineView.fadeHandleRect(r, edge: .start, fadePx: 0)?.x, 100)
        XCTAssertEqual(TimelineView.fadeHandleRect(r, edge: .start, fadePx: 50)?.x, 150)
        XCTAssertEqual(TimelineView.fadeHandleRect(r, edge: .end, fadePx: 0)?.maxX, 300)
        XCTAssertEqual(TimelineView.fadeHandleRect(r, edge: .end, fadePx: 50)?.maxX, 250)
        XCTAssertEqual(TimelineView.fadeHandleRect(r, edge: .start, fadePx: 999)?.maxX, 300, "held inside the clip, \(s) px wide")
    }

    // MARK: The menu

    func testTheClipMenuSetsAndRemovesFades() throws {
        let (c, e) = try make()
        c.openClipMenu("clip:a", x: 10, y: 10)
        func item(_ a: TimelineClipMenu.Action) -> TimelineClipMenu.Item? {
            for entry in c.view.clipMenu?.entries ?? [] { if case .item(let i) = entry, i.action == a { return i } }
            return nil
        }
        XCTAssertEqual(item(.fadeIn)?.checked, false)
        XCTAssertEqual(item(.removeFades)?.enabled, false, "nothing to remove yet")
        XCTAssertTrue(c.runClipMenu(.fadeIn, clipId: "clip:a"))
        XCTAssertTrue(c.runClipMenu(.fadeOut, clipId: "clip:a"))
        XCTAssertEqual(clip(e, "clip:a")?.fadeInFrames, 30); XCTAssertEqual(clip(e, "clip:a")?.fadeOutFrames, 30)
        c.openClipMenu("clip:a", x: 10, y: 10)
        XCTAssertEqual(item(.fadeIn)?.checked, true); XCTAssertEqual(item(.fadeOut)?.checked, true)
        XCTAssertEqual(item(.removeFades)?.enabled, true)
        XCTAssertTrue(c.runClipMenu(.removeFades, clipId: "clip:a"))
        XCTAssertNil(clip(e, "clip:a")?.fadeInFrames); XCTAssertNil(clip(e, "clip:a")?.fadeOutFrames)
    }

    func testTheFadeRowsAreDisabledOnALockedTrackAndAbsentOnAnElement() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        c.openClipMenu("clip:a", x: 10, y: 10)
        let fadeRows = (c.view.clipMenu?.entries ?? []).compactMap { entry -> TimelineClipMenu.Item? in
            if case .item(let i) = entry, [.fadeIn, .fadeOut, .removeFades].contains(i.action) { return i }; return nil
        }
        XCTAssertEqual(fadeRows.map(\.label), ["Fade In", "Fade Out", "Remove Fades"])
        XCTAssertTrue(fadeRows.allSatisfy { !$0.enabled })
        let titleMenu = TimelineClipMenu.entries(kind: .element, splitEnabled: false, thumbnails: false, muted: false, canReattach: false, canDetach: false)
        XCTAssertFalse(titleMenu.contains { if case .item(let i) = $0 { return i.action == .fadeIn }; return false })
    }

    // MARK: Drawing

    /// Draws `c` and returns the canvas that recorded it.
    func record(_ c: TimelineController) -> RecordingCanvas {
        let r = RecordingCanvas()
        c.view.draw(r, size: CanvasSize(1266, 300))
        return r
    }

    func testAFadedClipDrawsItsRampLineAndAnUnfadedOneDoesNot() throws {
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let (c, e) = try make()
            let r = try rect(c)
            let line = CanvasColor(ThemeTokens.white.alpha(0.85))
            let ramps: (RecordingCanvas) -> [CanvasRect] = { $0.strokes.filter { $0.color == line }.map(\.bounds) }
            XCTAssertTrue(ramps(record(c)).isEmpty, "\(mode): no fade, no ramp")
            XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .start, frames: 30))
            XCTAssertTrue(e.setClipFade(clipId: "clip:a", edge: .end, frames: 60))
            let drawn = ramps(record(c))
            XCTAssertTrue(drawn.contains { abs($0.x - r.x) < 0.5 && abs($0.width - 100) < 0.5 && abs($0.y - r.y) < 0.5 && abs($0.height - r.height) < 0.5 },
                          "\(mode): fade-in ramp spans 100 px from the bottom-left to the top")
            XCTAssertTrue(drawn.contains { abs($0.maxX - r.maxX) < 0.5 && abs($0.width - 200) < 0.5 && abs($0.height - r.height) < 0.5 },
                          "\(mode): fade-out ramp spans 200 px to the bottom-right")
        }
    }

    func testTheHandlesShowOnAHoveredOrSelectedClipOnly() throws {
        let (c, _) = try make()
        let r = try rect(c)
        let handle = try XCTUnwrap(TimelineView.fadeHandleRect(r, edge: .start, fadePx: 0))
        let idle = record(c)
        XCTAssertFalse(idle.fills.contains { $0.bounds == handle }, "no handle on an idle clip")
        c.view.selection = ["clip:a"]
        let selected = record(c)
        XCTAssertTrue(selected.fills.contains { abs($0.bounds.x - handle.x) < 0.5 && abs($0.bounds.width - handle.width) < 0.5 && abs($0.bounds.y - handle.y) < 0.5 })
    }

    func testTheCursorIsResizeOverAHandle() throws {
        let (c, _) = try make()
        let r = try rect(c)
        c.pointerMove(x: r.x + 4, y: r.y + 6)
        XCTAssertEqual(c.cursor, .resize)
        XCTAssertEqual(c.view.hoveredClip, "clip:a")
        c.pointerMove(x: r.x + 300, y: r.y + 14)
        XCTAssertEqual(c.cursor, .pointer)
    }

    #if canImport(CoreGraphics)
    /// Writes dark and light captures of faded clips when `MPVFX_SNAPSHOT_DIR` is set (for the PR), and checks that the
    /// ramp changes pixels inside the clip.
    func testFadedClipCapturesInBothThemes() throws {
        defer { Theme.setMode(.dark) }
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            func render(fades: Bool) throws -> CoreGraphicsCanvas {
                var faded = TimelineClipModel(name: "Interview.mp4", start: 0, duration: 12)
                var plain = TimelineClipModel(name: "Broll.mp4", start: 13, duration: 10)
                if fades { faded.fadeIn = 2; faded.fadeOut = 3; plain.fadeIn = 1 }
                plain.id = "plain"
                let view = TimelineView(tracks: [.init(name: "Video 1", clips: [faded, plain])], duration: 24)
                view.selection = [faded.id]
                let controller = TimelineController(view: view, playback: PlaybackState(duration: 24))
                let region = TimelineRegion(controller: controller)
                region.resized(CanvasSize(1280, 200))
                controller.setTrackHeight(48)
                let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: 1280, height: 200))
                region.draw(canvas, size: CanvasSize(1280, 200))
                return canvas
            }
            let with = try render(fades: true), without = try render(fades: false)
            let a = try XCTUnwrap(with.ctx.makeImage()), b = try XCTUnwrap(without.ctx.makeImage())
            XCTAssertNotEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?, "\(mode): the ramps change the picture")
            if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("timeline-fades-\(mode.rawValue).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, a, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
    #endif
}
