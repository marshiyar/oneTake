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
import MpvfxCanvas
import OneTakeKeyframes
@testable import MpvfxTimeline

final class TimelineChunk6Tests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"id":"project:c6","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:a","kind":"video","name":"clip_001.mp4","durationFrames":600},
               {"id":"asset:m","kind":"audio","name":"vo.wav","durationFrames":900}],
     "sequence":{"id":"sequence:main","name":"Main","audioGroups":[{"id":"dialogue","label":"Dialogue","volume":1,"muted":false}],"tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,
        "effects":[{"id":"fx:grade","effectId":"color-grade","enabled":true,"parameters":{}}],
        "parameterTracks":[{"schemaVersion":1,"id":"parameter:a:rotation","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30,"denominator":1},
          "keyframes":[{"id":"r0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"r1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]}]},
      {"id":"track:a1","kind":"audio","lane":{"authoredTrack":2,"displayTrack":1},"clips":[
       {"id":"clip:m1","assetId":"asset:m","startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"audioGroupId":"dialogue","effects":[],"parameterTracks":[]}]},
      {"id":"track:a2","kind":"audio","lane":{"authoredTrack":3,"displayTrack":2},"clips":[
       {"id":"clip:m2","assetId":"asset:m","startFrame":30,"durationFrames":120,"sourceInFrame":0,"muted":false,"audioGroupId":"dialogue","effects":[],"parameterTracks":[]}]}]}}
    """#

    func make() throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: Self.json, engine: try? KeyframeRuntime())
        let v = TimelineView(tracks: [], duration: 0)
        let c = TimelineController(view: v, playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1200, 600)
        return (c, e)
    }
    typealias L = TimelineLayout

    func testModelsLanesEffectsGroups() throws {
        let (c, e) = try make()
        let a = c.view.tracks[0].clips[0]
        XCTAssertEqual(a.effects, [TimelineEffectModel(id: "native:fx:grade", label: "Color Grade")])
        XCTAssertEqual(a.lanes.map(\.label), ["Rotation"])
        XCTAssertEqual(a.lanes[0].keyframes, [0, 2])
        XCTAssertEqual(e.timelineGroups, [TimelineGroupModel(id: "dialogue", label: "Dialogue", memberTrackIds: ["track:a1", "track:a2"])])
        XCTAssertEqual(c.view.bands, [.track(0), .group("dialogue"), .track(1), .track(2)])
        // #201: a keyed clip starts with one summary row instead of auto-expanding a row per property.
        XCTAssertFalse(c.view.expandedClips.contains("clip:a"), "starts collapsed")
        XCTAssertEqual(c.view.laneRows(a), [.summary])
    }

    func testVariableRowHeightsAndHitTests() throws {
        let (c, _) = try make()
        let v = c.view
        // Media row H, then one 18 px effect strip and one 28 px lane; the group header is G tall.
        let H = L.defaultTrackHeight, G = L.groupHeaderHeight, row0 = H + 18 + 28
        XCTAssertEqual(v.trackRowHeight(0), row0)
        XCTAssertEqual(v.rowTop(0), 40)
        XCTAssertEqual(v.groupHeaderTop("dialogue"), 40 + row0)
        XCTAssertEqual(v.rowTop(1), 40 + row0 + G)
        let x = v.x(for: 1)
        XCTAssertEqual(c.hitTest(x: x, y: 40 + H / 2), .clip(id: "clip:a", row: 0, edge: nil))
        XCTAssertEqual(c.hitTest(x: x, y: 40 + H + 5), .clipExtra(id: "clip:a", row: 0))            // effect strip
        XCTAssertEqual(c.hitTest(x: x, y: 40 + H + 18 + 10), .clipExtra(id: "clip:a", row: 0))      // lane
        XCTAssertEqual(c.hitTest(x: v.x(for: 10), y: 40 + H + 18 + 10), .empty(row: 0))
        XCTAssertEqual(c.hitTest(x: 18, y: 40 + row0 + G / 2), .groupHeader(id: "dialogue", caret: true))
        XCTAssertEqual(c.hitTest(x: x, y: v.rowTop(1) + 20), .clip(id: "clip:m1", row: 1, edge: nil))
        XCTAssertEqual(c.hitTest(x: v.x(for: 2), y: v.rowTop(2) + 20), .clip(id: "clip:m2", row: 2, edge: nil))
        XCTAssertEqual(v.trackIndex(nearY: v.rowTop(2) + 10), 2)
        XCTAssertEqual(v.trackIndex(nearY: 10_000), 2)
    }

    func testUTogglesExpansion() throws {
        let (c, _) = try make()
        c.view.selection = ["clip:a"]
        // Collapsed: the media row + effect strip 18 + the summary row 28; U adds the Rotation row under it.
        XCTAssertEqual(c.view.trackRowHeight(0), c.view.trackHeight + 18 + 28)
        XCTAssertTrue(c.keyDown(EditorKey(.char("u"))))
        XCTAssertTrue(c.view.expandedClips.contains("clip:a"))
        XCTAssertEqual(c.view.trackRowHeight(0), c.view.trackHeight + 18 + 56)
        XCTAssertTrue(c.keyDown(EditorKey(.char("u"))))
        XCTAssertEqual(c.view.trackRowHeight(0), L.defaultTrackHeight + 18 + 28)
        c.view.selection = ["clip:m1"]
        XCTAssertFalse(c.keyDown(EditorKey(.char("u"))), "no lanes, nothing to toggle")
    }

    func testGroupCollapseHidesMembers() throws {
        let (c, _) = try make()
        c.pointerDown(x: 18, y: c.view.groupHeaderTop("dialogue")! + 24); c.pointerUp(x: 18, y: 0)
        XCTAssertEqual(c.view.tracks.map(\.id), ["track:v1"])
        XCTAssertEqual(c.view.bands, [.track(0), .group("dialogue")])
        c.pointerDown(x: 18, y: c.view.groupHeaderTop("dialogue")! + 24); c.pointerUp(x: 18, y: 0)
        XCTAssertEqual(c.view.tracks.count, 3)
    }

    func testRazorKeys() throws {
        let (c, _) = try make()
        XCTAssertTrue(c.keyDown(EditorKey(.char("b")))); XCTAssertEqual(c.tool, .razor)
        XCTAssertTrue(c.keyDown(EditorKey(.char("b")))); XCTAssertEqual(c.tool, .select)
        c.keyDown(EditorKey(.char("b")))
        XCTAssertTrue(c.keyDown(EditorKey(.char("v")))); XCTAssertEqual(c.tool, .select)
        c.keyDown(EditorKey(.char("b"))); c.view.selection = ["clip:a"]
        c.keyDown(EditorKey(.escape)); XCTAssertEqual(c.tool, .razor); XCTAssertTrue(c.view.selection.isEmpty)
        c.keyDown(EditorKey(.escape)); XCTAssertEqual(c.tool, .select)
    }

    func testClipMenuEntriesAndActions() throws {
        let (c, e) = try make()
        c.playback.seek(2)
        let v = c.view
        c.secondaryClick(x: v.x(for: 1), y: 60)
        let m = try XCTUnwrap(v.clipMenu)
        let labels = m.entries.map { e -> String in if case .item(let i) = e { return i.label }; return "—" }
        XCTAssertEqual(labels, ["Split", "—", "Cut", "Copy", "Paste", "Copy grade", "Paste grade", "Duplicate", "Rename…", "Disable", "—", "Show thumbnails", "—", "Mute", "Keep audio pitch", "—", "Delete"])
        XCTAssertTrue(c.runClipMenu(.mute, clipId: "clip:a"))
        XCTAssertTrue(c.view.tracks[0].clips[0].muted)
        XCTAssertTrue(e.undo()); XCTAssertFalse(c.view.tracks[0].clips[0].muted)
        // Clicking "Split" in the drawn menu splits at the playhead.
        let split = try XCTUnwrap(m.itemRects().first { $0.0.action == .split }).1
        c.pointerDown(x: split.x + 20, y: split.y + 10)
        XCTAssertNil(v.clipMenu)
        XCTAssertEqual(c.view.tracks[0].clips.count, 2)
        // Audio clip: no thumbnails row, split disabled outside.
        c.playback.seek(9)
        c.secondaryClick(x: v.x(for: 1), y: v.rowTop(1) + 20)
        let am = try XCTUnwrap(v.clipMenu)
        guard case .item(let s) = am.entries[0] else { return XCTFail() }
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(am.entries.contains { if case .item(let i) = $0 { return i.action == .thumbnails }; return false })
        c.pointerDown(x: am.rect.x + 20, y: am.itemRects()[0].1.y + 10)   // disabled: stays open
        XCTAssertNotNil(v.clipMenu)
        c.keyDown(EditorKey(.escape)); XCTAssertNil(v.clipMenu)
    }

    func testStripColorHash() {
        XCTAssertEqual(TimelineStripColor.index("a"), 97 % 5)
        XCTAssertEqual(TimelineStripColor.index("ab"), (97 * 31 + 98) % 5)
    }

    func testDrawsWithoutCrash() throws {
        let (c, _) = try make()
        c.view.selection = ["clip:a"]
        c.secondaryClick(x: c.view.x(for: 1), y: 60)
        let r = RecordingCanvas()
        c.view.draw(r, size: CanvasSize(1200, 600))
        XCTAssertTrue(r.texts.contains("Color Grade")); XCTAssertTrue(r.texts.contains("Keyframes"), "the summary row's header")
        XCTAssertTrue(r.texts.contains("Dialogue")); XCTAssertTrue(r.texts.contains("Show thumbnails"))
    }
}

final class RecordingCanvas: CanvasContext {
    var texts: [String] = []
    /// Every fill and stroke with its colour and the bounding box of its path (no transforms: the timeline draws none).
    var fills: [(color: CanvasColor, bounds: CanvasRect)] = [], strokes: [(color: CanvasColor, bounds: CanvasRect)] = []
    func save() {}; func restore() {}
    func translate(_ dx: Double, _ dy: Double) {}; func scale(_ sx: Double, _ sy: Double) {}; func rotate(_ radians: Double) {}
    func clip(_ path: CanvasPath) {}
    func fill(_ path: CanvasPath, _ color: CanvasColor) { fills.append((color, Self.bounds(path))) }
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) { strokes.append((color, Self.bounds(path))) }
    static func bounds(_ path: CanvasPath) -> CanvasRect {
        let pts: [CanvasPoint] = path.elements.flatMap { e -> [CanvasPoint] in
            switch e { case .move(let p), .line(let p): [p]; case .curve(let a, let b, let p): [a, b, p]; case .close: [] }
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
        return CanvasRect(x: x0, y: y0, width: (xs.max() ?? 0) - x0, height: (ys.max() ?? 0) - y0)
    }
    /// Whether a fill (or stroke) of `color` has its centre within 1 px of `p`.
    func painted(_ color: CanvasColor, at p: CanvasPoint, stroke: Bool = false) -> Bool {
        (stroke ? strokes : fills).contains { $0.color == color && abs($0.bounds.centerX - p.x) <= 1 && abs($0.bounds.centerY - p.y) <= 1 }
    }
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) { texts.append(text) }
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * 5, font.size) }
    var images: [(image: CanvasImage, rect: CanvasRect)] = []
    func drawImage(_ image: CanvasImage, in rect: CanvasRect) { images.append((image, rect)) }
}
