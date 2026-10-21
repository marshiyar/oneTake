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
import MpvfxShared
import MpvfxTheme
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

#if os(Linux)   // CairoImageTarget is the Linux canvas
/// #201: the inspector's ◆ is the timeline's mark for the property's kind (same shape, same colour), in dark and
/// light; the shortcuts card carries the legend. PNGs go to `MPVFX_SNAPSHOT_DIR` (else `.build/port-tmp`).
final class KeyframeMarkPanelTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark); super.tearDown() }

    static var outputDir: String {
        ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/port-tmp").path
    }

    /// The Design inspector (the 360 pt column of a 1440×900 window) on clip:a at 1 s, Transform open with its 3D
    /// rows, keyed at the playhead on Position, Rotation, Tilt X and Depth.
    func renderInspector(_ mode: ThemeMode) throws -> (InspectorPanel, CairoImageTarget) {
        Theme.setMode(mode)
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        for pid in [TimelineEditor.positionId, TimelineEditor.rotationId, NativeTransform3D.rotationXId, NativeTransform3D.zId] {
            XCTAssertTrue(e.setAnimated(clipId: "clip:a", [(pid, pid == TimelineEditor.positionId ? .vec2(Vec2Value(x: 0, y: 0)) : .number(0))], true, time: 1))
        }
        let p = InspectorPanel(); p.editor = e; p.selection = ["clip:a"]; p.time = 1; p.transform3DOpen = true
        let t = CairoImageTarget(width: 360, height: 900)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 360, height: 900), PanelTheme.panelBgInset)
        p.draw(t.canvas, in: CanvasRect(x: 0, y: 0, width: 360, height: 900))
        try FileManager.default.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)
        t.writePNG("\(Self.outputDir)/inspector-keyframe-marks-\(mode).png")
        return (p, t)
    }

    func assertMark(_ p: InspectorPanel, _ t: CairoImageTarget, _ key: String, _ kind: TimelineKeyframeKind, _ mode: ThemeMode,
                    file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try XCTUnwrap(p.hits.rect { $0 == .keyframe(key) }, "\(key) ◆ drawn", file: file, line: line)
        let px = t.pixel(Int(r.x + r.width / 2), Int(r.y + r.height / 2)), want = kind.colorPair.value(mode)
        let d = max(abs(Double(px.r) / 255 - want.r), abs(Double(px.g) / 255 - want.g), abs(Double(px.b) / 255 - want.b)) * 255
        XCTAssertLessThanOrEqual(d, 14, "\(key) in \(mode): rgb(\(px.r),\(px.g),\(px.b)) vs the \(kind) colour", file: file, line: line)
    }

    func checkInspector(_ mode: ThemeMode) throws {
        let (p, t) = try renderInspector(mode)
        try assertMark(p, t, "x", .transform, mode)
        try assertMark(p, t, "rotation", .transform, mode)
        try assertMark(p, t, "tiltX", .threeD, mode)
        try assertMark(p, t, "depth", .threeD, mode)
        XCTAssertEqual(p.number("tiltX")?.keyframe?.kind, .threeD)
        XCTAssertEqual(p.number("scale")?.keyframe?.state, InspectorRow.KeyframeState.none, "an unanimated row keeps the ghost outline")
    }

    func testInspectorMarksMatchTheTimelineDark() {
        XCTAssertNoThrow(try checkInspector(.dark))
    }
    func testInspectorMarksMatchTheTimelineLight() {
        XCTAssertNoThrow(try checkInspector(.light))
    }

    func testShortcutsCardCarriesTheLegend() throws {
        XCTAssertEqual(keyframeLegend.map(\.kind), TimelineKeyframeKind.allCases, "one legend row per kind, in lane order")
        XCTAssertEqual(keyframeEaseLegend.map(\.ease), TimelineKeyframeEase.allCases)
        let panel = ShortcutsPanel(); panel.isOpen = true
        let t = CairoImageTarget(width: 260, height: 2000)
        let tall = panel.layout(t.canvas)
        XCTAssertGreaterThan(tall.height, 13.5 + 6 + 6 * 18, "the legend adds its rows to the card")
        tall.draws.forEach { $0(t.canvas, CanvasRect(x: 0, y: 0, width: 220, height: tall.height)) }
        try FileManager.default.createDirectory(atPath: Self.outputDir, withIntermediateDirectories: true)
        t.writePNG("\(Self.outputDir)/shortcuts-keyframe-legend.png")
    }
}
#endif
