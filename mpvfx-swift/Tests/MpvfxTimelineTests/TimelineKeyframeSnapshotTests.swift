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
import OneTakeKeyframes

#if os(Linux)   // CairoImageTarget is the Linux canvas
/// #201 snapshots: the timeline at 1440×900 with a keyed clip, collapsed (one summary row) and expanded (rows by
/// kind), in dark and light. Each kind's mark is checked at its centre for its colour; the PNGs are written to
/// `MPVFX_SNAPSHOT_DIR` (else `.build/port-tmp`) as `timeline-keyframes-<state>-<mode>.png`.
final class TimelineKeyframeSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark); super.tearDown() }

    static var outputDir: String {
        ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/port-tmp").path
    }

    /// clip:a keyed with every kind the demo can carry: Position + Scale at 1 s, Opacity at 2 s, Tilt X at 3 s,
    /// Volume at 4 s, an eased Rotation key at 5 s, a held Depth key at 5.5 s.
    func render(expanded: Bool, mode: ThemeMode) throws -> (TimelineController, CairoImageTarget) {
        Theme.setMode(mode)
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1440, 900); c.setZoom(percent: 300)
        let keys: [(String, NativeParameterValue, Double, NativeInterpolation)] = [
            (TimelineEditor.positionId, .vec2(Vec2Value(x: 0, y: 0)), 30, .linear), (TimelineEditor.scaleId, .vec2(Vec2Value(x: 1, y: 1)), 30, .linear),
            (TimelineEditor.opacityId, .number(1), 60, .linear), (NativeTransform3D.rotationXId, .number(5), 90, .linear),
            (TimelineEditor.volumeId, .number(1), 120, .linear), (TimelineEditor.rotationId, .number(5), 150, .cubicBezier(CubicBezierControlPoints(x1: 0.4, y1: 0, x2: 0.2, y2: 1))),
            (NativeTransform3D.zId, .number(0), 165, .hold),
        ]
        let cmds: [NativeProjectAtomicPropertyCommand] = try keys.map { pid, v, f, out in
            .keyframe(.upsert(address: try XCTUnwrap(e.parameterAddress(clipId: "clip:a", pid)), valueType: TimelineEditor.valueType(v), frame: f,
                              value: v, baselineValue: v, outgoing: out))
        }
        XCTAssertTrue(e.applyProperty(.batch(cmds)))
        c.view.selection = ["clip:a"]
        if expanded { XCTAssertTrue(c.keyDown(EditorKey(.char("u")))) }
        let t = CairoImageTarget(width: 1440, height: 900)
        c.view.draw(t.canvas, size: CanvasSize(1440, 900))
        try FileManager.default.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)
        t.writePNG("\(Self.outputDir)/timeline-keyframes-\(expanded ? "expanded" : "collapsed")-\(mode).png")
        return (c, t)
    }

    func colour(_ t: CairoImageTarget, _ x: Double, _ y: Double) -> ThemeColor {
        let p = t.pixel(Int(x.rounded(.down)), Int(y.rounded(.down)))
        return ThemeColor(r: Double(p.r) / 255, g: Double(p.g) / 255, b: Double(p.b) / 255)
    }

    func assertColour(_ t: CairoImageTarget, _ x: Double, _ y: Double, _ want: ThemeColor, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let got = colour(t, x, y)
        XCTAssertLessThanOrEqual(max(abs(got.r - want.r), abs(got.g - want.g), abs(got.b - want.b)) * 255, 12, "\(what): \(got) vs \(want)", file: file, line: line)
    }

    func rowY(_ c: TimelineController, _ j: Int) -> Double { c.view.rowTop(1) + c.view.trackHeight + (Double(j) + 0.5) * TimelineLayout.laneHeight }

    func distance(_ a: ThemeColor, _ b: ThemeColor) -> Double { max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) * 255 }

    func checkCollapsed(_ mode: ThemeMode) throws {
        let (c, t) = try render(expanded: false, mode: mode)
        XCTAssertEqual(c.view.laneRows(try XCTUnwrap(c.view.tracks[1].clips.first)), [.summary])
        let y = rowY(c, 0)
        assertColour(t, c.view.x(for: 1), y, ThemeTokens.keyframeTransformPair.value(mode), "\(mode) Position + Scale: one transform mark")
        assertColour(t, c.view.x(for: 2), y, ThemeTokens.keyframeOpacityPair.value(mode), "\(mode) opacity circle")
        assertColour(t, c.view.x(for: 3), y, ThemeTokens.keyframe3DPair.value(mode), "\(mode) 3D hexagon")
        assertColour(t, c.view.x(for: 4), y, ThemeTokens.keyframeAudioPair.value(mode), "\(mode) audio square")
    }

    func checkExpanded(_ mode: ThemeMode) throws {
        let (c, t) = try render(expanded: true, mode: mode)
        let rows = c.view.laneRows(try XCTUnwrap(c.view.tracks[1].clips.first))
        XCTAssertEqual(rows, [.summary, .kind(.transform), .property("position"), .property("rotation"), .property("scale"),
                              .kind(.threeD), .property("depth"), .property("tiltX"), .property("opacity"), .property("audio")])
        let position = try XCTUnwrap(rows.firstIndex(of: .property("position"))), volume = try XCTUnwrap(rows.firstIndex(of: .property("audio")))
        assertColour(t, c.view.x(for: 1), rowY(c, position), ThemeTokens.keyframeTransformPair.value(mode), "\(mode) transform diamond")
        assertColour(t, c.view.x(for: 4), rowY(c, volume), ThemeTokens.keyframeAudioPair.value(mode), "\(mode) volume square")
        // The eased Rotation key: left half filled, right half open (the row shows through).
        let rotation = try XCTUnwrap(rows.firstIndex(of: .property("rotation"))), r = TimelineView.keyframeMarkRadius
        assertColour(t, c.view.x(for: 5) - r * 0.4, rowY(c, rotation), ThemeTokens.keyframeTransformPair.value(mode), "\(mode) ease: left half")
        XCTAssertGreaterThan(distance(colour(t, c.view.x(for: 5) + r * 0.4, rowY(c, rotation)), ThemeTokens.keyframeTransformPair.value(mode)), 60,
                             "\(mode) ease: right half open")
    }

    func testCollapsedSummaryLaneDark() {
        XCTAssertNoThrow(try checkCollapsed(.dark))
    }
    func testCollapsedSummaryLaneLight() {
        XCTAssertNoThrow(try checkCollapsed(.light))
    }
    func testExpandedLanesByKindDark() {
        XCTAssertNoThrow(try checkExpanded(.dark))
    }
    func testExpandedLanesByKindLight() {
        XCTAssertNoThrow(try checkExpanded(.light))
    }
}

#endif
