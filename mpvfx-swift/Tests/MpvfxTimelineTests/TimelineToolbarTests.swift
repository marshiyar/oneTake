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
import OneTakeKeyframes

/// Toolbar: buttons, enable rules, track height slider, zoom controls.
final class TimelineToolbarTests: XCTestCase {
    static let width = 1266.0
    func make() throws -> (TimelineToolbar, TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(Self.width, 300)
        return (TimelineToolbar(controller: c), c, e)
    }
    func click(_ tb: TimelineToolbar, _ item: TimelineToolbar.Item, clicks: Int = 1) {
        guard let r = tb.layout(width: Self.width).first(where: { $0.item == item })?.rect else { return XCTFail("no \(item)") }
        tb.pointerDown(x: r.centerX, y: r.centerY, width: Self.width, clickCount: clicks); tb.pointerUp()
    }

    func testLayoutOrderAndGeometry() throws {
        let (tb, _, _) = try make()
        let items = tb.layout(width: Self.width)
        XCTAssertEqual(items.map(\.item), [.select, .razor, .slip, .roll, .snap, .keyframe, .autoKeyframe, .split, .addBeat,
                                           .trackHeight, .zoomOut, .zoomSlider, .zoomIn, .zoomPercent])
        XCTAssertEqual(items[0].rect, CanvasRect(x: 8, y: 2, width: 28, height: 28))
        XCTAssertEqual(items[1].rect.x, 38)
        XCTAssertEqual(items[4].rect.x, 38 + 3 * (28 + 2) + 9 + 2, "divider mx-1 w-px between the four tools and the actions")
        XCTAssertEqual(items.last!.rect.maxX, Self.width - 8, accuracy: 1e-9)
        tb.onRemoveSilence = { _ in }
        XCTAssertTrue(tb.layout(width: Self.width).contains { $0.item == .removeSilence }, "silence button only when wired")
    }

    func testToolsAndToggles() throws {
        let (tb, c, _) = try make()
        click(tb, .razor); XCTAssertEqual(c.tool, .razor); XCTAssertTrue(tb.isPressed(.razor))
        click(tb, .select); XCTAssertEqual(c.tool, .select)
        XCTAssertTrue(c.snapEnabled); click(tb, .snap); XCTAssertFalse(c.snapEnabled)
        XCTAssertFalse(c.autoKeyframeEnabled); click(tb, .autoKeyframe); XCTAssertTrue(c.autoKeyframeEnabled)
        XCTAssertTrue(tb.tooltip(.autoKeyframe).hasPrefix("Auto-keyframe enabled"))
    }

    func testKeyframeButtonTogglesPositionKeyframeOnTheSelection() throws {
        let (tb, c, e) = try make()
        XCTAssertEqual(tb.keyframeState, .none); XCTAssertFalse(tb.isEnabled(.keyframe))
        c.view.selection = ["clip:music"]; XCTAssertEqual(tb.keyframeState, .none, "audio clips have no position")
        c.view.selection = ["clip:a"]; c.playback.seek(1)
        XCTAssertEqual(tb.keyframeState, .inactive)
        click(tb, .keyframe)
        XCTAssertEqual(tb.keyframeState, .active, "\(String(describing: e.lastPropertyFailure))")
        XCTAssertTrue(e.positionKeyframeActive(clipId: "clip:a", time: 1))
        click(tb, .keyframe)
        XCTAssertEqual(tb.keyframeState, .inactive)
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        XCTAssertEqual(tb.keyframeState, .none, "locked track")
    }

    func testSplitNeedsTheSelectedClipUnderThePlayhead() throws {
        let (tb, c, e) = try make()
        XCTAssertFalse(tb.canSplit)
        XCTAssertEqual(tb.tooltip(.split), "Select a clip to split")
        c.view.selection = ["clip:a"]; c.playback.seek(7)
        XCTAssertFalse(tb.canSplit); XCTAssertEqual(tb.tooltip(.split), "Move the playhead inside the clip to split")
        c.playback.seek(2)
        click(tb, .split)
        let v1 = e.document.sequence.tracks.first { $0.id == "track:v1" }!
        XCTAssertEqual(v1.clips.count, 3, "only the selected clip splits")
        XCTAssertEqual(e.document.sequence.tracks.first { $0.id == "track:a1" }!.clips.count, 1)
    }

    func testRemoveSilenceAndAddBeat() throws {
        let (tb, c, _) = try make()
        var silenced: String?
        tb.onRemoveSilence = { silenced = $0 }
        c.view.selection = ["clip:music"]; XCTAssertFalse(tb.canRemoveSilence, "video only")
        c.view.selection = ["clip:a"]; XCTAssertTrue(tb.canRemoveSilence)
        click(tb, .removeSilence); XCTAssertEqual(silenced, "clip:a")
        tb.isRemovingSilence = true; XCTAssertFalse(tb.canRemoveSilence)

        XCTAssertFalse(tb.canAddBeat, "no analysis")
        tb.beatMusicClipId = "clip:music"; c.playback.seek(3)
        XCTAssertTrue(tb.canAddBeat)
        click(tb, .addBeat)
        XCTAssertEqual(c.view.beats.map(\.time), [3])
        XCTAssertFalse(c.addBeat(at: 3), "no duplicate")
        var added: Double?
        tb.onAddBeat = { added = $0 }
        c.playback.seek(4); click(tb, .addBeat); XCTAssertEqual(added, 4)
    }

    func testTrackHeightSliderStepsAndResizesRows() throws {
        let (tb, c, _) = try make()
        var saved: Double?
        c.onTrackHeightChange = { saved = $0 }
        XCTAssertEqual(c.view.trackHeight, 28, "compact rows by default (docs/DESIGN.md step 4)")
        let r = tb.layout(width: Self.width).first { $0.item == .trackHeight }!.rect
        let track = tb.sliderTrack(.trackHeight, in: r)
        tb.pointerDown(x: track.maxX - 1, y: r.centerY, width: Self.width); tb.pointerUp()
        XCTAssertEqual(c.view.trackHeight, 96); XCTAssertEqual(saved, 96)
        tb.pointerDown(x: track.centerX, y: r.centerY, width: Self.width); tb.pointerUp()
        XCTAssertEqual(c.view.trackHeight.truncatingRemainder(dividingBy: 4), 0, "the slider steps by 4 px")
        tb.pointerDown(x: track.x, y: r.centerY, width: Self.width); tb.pointerUp()
        XCTAssertEqual(c.view.trackHeight, 28)
        c.setTrackHeight(61); XCTAssertEqual(c.view.trackHeight, 61, "rounded, clamped (the store keeps any integer)")
        c.setTrackHeight(200); XCTAssertEqual(c.view.trackHeight, 96)
        c.setTrackHeight(64)
        XCTAssertEqual(c.view.rowTop(1) - c.view.rowTop(0), 64)
        let clip = c.view.tracks[1].clips[0]
        XCTAssertEqual(c.view.clipRect(track: 1, clip).height, 64 - 2 * TimelineLayout.clipY)
        XCTAssertEqual(c.hitTest(x: c.view.x(for: 1), y: c.view.rowTop(1) + 60), .clip(id: "clip:a", row: 1, edge: nil))
    }

    func testZoomButtonsSliderAndPercent() throws {
        let (tb, c, _) = try make()
        XCTAssertEqual(tb.zoomPercent, 100)
        click(tb, .zoomIn); XCTAssertEqual(tb.zoomPercent, 200)
        click(tb, .zoomOut); click(tb, .zoomOut); XCTAssertEqual(tb.zoomPercent, 50)
        let fit = c.fitPixelsPerSecond
        XCTAssertEqual(TimelineZoom.percent(slider: TimelineZoom.slider(percent: 400, fit: fit), fit: fit), 400)
        XCTAssertEqual(TimelineZoom.slider(percent: TimelineZoom.minPercent, fit: fit), 0)
        XCTAssertEqual(TimelineZoom.slider(percent: TimelineZoom.maxPercent(fit: fit), fit: fit), 100, accuracy: 1e-9)
        let r = tb.layout(width: Self.width).first { $0.item == .zoomSlider }!.rect
        tb.pointerDown(x: r.maxX, y: r.centerY, width: Self.width); tb.pointerUp()
        XCTAssertEqual(tb.zoomPercent, TimelineZoom.maxPercent(fit: fit))
        click(tb, .zoomSlider, clicks: 2)
        XCTAssertEqual(c.zoomMode, .fit, "double-click returns to fit")
        XCTAssertEqual(tb.tooltip(.zoomSlider), "100%")
    }

    func testIconPathParsesAbsoluteAndRelative() {
        let p = TimelineIconPath.parse("M3 2h10M8 4v8l2-2", viewBox: 16, into: CanvasRect(x: 0, y: 0, width: 32, height: 32))
        XCTAssertEqual(p.elements, [.move(.init(6, 4)), .line(.init(26, 4)), .move(.init(16, 8)), .line(.init(16, 24)), .line(.init(20, 20))])
        let q = TimelineIconPath.parse("M2 0.5L10 6Z", viewBox: 12, into: CanvasRect(x: 0, y: 0, width: 12, height: 12))
        XCTAssertEqual(q.elements, [.move(.init(2, 0.5)), .line(.init(10, 6)), .close])
    }

    // MARK: Region (toolbar + tracks) and persisted preferences

    func makeRegion(_ store: TimelineUIPreferencesStore? = nil) throws -> (TimelineRegion, TimelineController) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        let r = TimelineRegion(controller: c, preferences: store)
        r.resized(CanvasSize(Self.width, 333))
        return (r, c)
    }

    func testRegionSplitsToolbarFromTracks() throws {
        let (r, c) = try makeRegion()
        XCTAssertEqual(c.viewport, CanvasSize(Self.width, 300), "tracks get the height under the toolbar")
        let razor = r.toolbar.layout(width: Self.width).first { $0.item == .razor }!.rect
        r.pointerDown(x: razor.centerX, y: razor.centerY); r.pointerUp(x: razor.centerX, y: razor.centerY)
        XCTAssertEqual(c.tool, .razor)
        r.pointerMove(x: razor.centerX, y: razor.centerY)
        XCTAssertEqual(r.toolbar.hovered, .razor)
        // A press below the strip lands on the controller shifted by the toolbar height.
        c.tool = .select
        let clip = c.view.tracks[1].clips[0], cr = c.view.clipRect(track: 1, clip)
        r.pointerDown(x: cr.centerX, y: cr.centerY + TimelineToolbar.height); r.pointerUp(x: cr.centerX, y: cr.centerY + TimelineToolbar.height)
        XCTAssertEqual(c.view.selection, [clip.id])
        r.pointerMove(x: cr.centerX, y: cr.centerY + TimelineToolbar.height)
        XCTAssertNil(r.toolbar.hovered, "leaving the strip clears the hover")
        // A ruler press scrubs.
        r.pointerDown(x: c.view.x(for: 2), y: TimelineToolbar.height + 5); r.pointerUp(x: c.view.x(for: 2), y: TimelineToolbar.height + 5)
        XCTAssertEqual(c.playback.currentTime, 2, accuracy: 0.05)
    }

    func testRegionDoubleClickOnZoomSliderFits() throws {
        let (r, c) = try makeRegion()
        var clock = 100.0; r.now = { clock }
        let z = r.toolbar.layout(width: Self.width).first { $0.item == .zoomSlider }!.rect
        r.pointerDown(x: z.maxX - 20, y: z.centerY); r.pointerUp(x: z.maxX - 20, y: z.centerY)
        XCTAssertEqual(c.zoomMode, .manual)
        clock += 0.2
        r.pointerDown(x: z.maxX - 20, y: z.centerY); r.pointerUp(x: z.maxX - 20, y: z.centerY)
        XCTAssertEqual(c.zoomMode, .fit)
    }

    func testTrackHeightZoomAndSnapPersist() throws {
        let store = MemoryTimelineUIPreferencesStore()
        let (r, c) = try makeRegion(store)
        c.setTrackHeight(72); c.setZoom(percent: 400); c.snapEnabled = false
        XCTAssertEqual(store.prefs, TimelineUIPreferences(timelineTrackHeight: 72, timelineZoomMode: .manual,
                                                          timelineManualZoomPercent: 400, timelineSnapEnabled: false))
        _ = r
        let (r2, c2) = try makeRegion(store)
        XCTAssertEqual(c2.view.trackHeight, 72); XCTAssertEqual(c2.zoomMode, .manual)
        XCTAssertEqual(r2.toolbar.zoomPercent, 400); XCTAssertFalse(c2.snapEnabled)
        c2.zoomToFit(); XCTAssertEqual(store.prefs.timelineZoomMode, .fit)
    }

    func testPreferencesFileKeepsOtherKeysAndValidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-prefs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ui.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"leftWidth":300,"timelineTrackHeight":140.4,"timelineZoomMode":"zoomy","timelineManualZoomPercent":250}"#.utf8).write(to: url)
        let store = FileTimelineUIPreferencesStore(url: url)
        let p = store.load()
        XCTAssertEqual(p.timelineTrackHeight, 96, "clamped like readStorage")
        XCTAssertNil(p.timelineZoomMode, "unknown mode dropped")
        XCTAssertEqual(p.timelineManualZoomPercent, 250)
        var q = p; q.timelineSnapEnabled = true; store.save(q)
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(o["leftWidth"] as? Double, 300, "other preference keys survive")
        XCTAssertEqual(o["timelineSnapEnabled"] as? Bool, true)
    }
}
