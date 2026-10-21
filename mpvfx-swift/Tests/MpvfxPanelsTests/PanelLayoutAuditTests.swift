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
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The layout audit of the Design tab (docs/DESIGN.md "Layout grid"): at the 280 pt minimum right panel width and the
/// right panel's default widths for 1280 × 800 and 1440 × 900 windows, in dark and light, every audited inspector
/// group must
///
/// - put every row slot on the 8 pt grid (`PanelGrid.unit`), counted from the body's top;
/// - line up labels and controls on the `PanelGrid` columns: a number field, slider track or segmented control
///   starts at the control column, never inside the label column;
/// - draw no text over another text, and no text across a control it does not belong to (issue #154: the "Ease"
///   label under its options);
/// - give every pointer target at least 24 × 24 pt (WCAG 2.2 SC 2.5.8, https://www.w3.org/TR/WCAG22/#target-size-minimum,
///   read 2026-10-21) with no two targets overlapping.
///
/// Panels draw on `PanelMeasureCanvas` (text widths from the font size alone), so the geometry is the same on every OS.
/// The panel is tall enough that the open group is laid out whole, so no scrollbar is drawn.
final class PanelLayoutAuditTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    /// The right panel at the minimum width and at `PanelFit.defaults` for the two target windows.
    static let widths: [(String, Double)] = [
        ("min280", PanelFit.minRight),
        ("1280x800", PanelFit.defaults(1280).right),
        ("1440x900", PanelFit.defaults(1440).right),
    ]
    static let height = 2400.0

    /// The keyed properties: every row shows its stopwatch, ‹ › and the diamond; volume keys show "Keyframe easing".
    static let keyed: [(id: String, value: NativeParameterValue)] = [
        (TimelineEditor.positionId, .vec2(Vec2Value(x: 0, y: 0))), (TimelineEditor.rotationId, .number(15)),
        (TimelineEditor.scaleId, .vec2(Vec2Value(x: 1.2, y: 1.2))), (TimelineEditor.opacityId, .number(0.8)),
        (TimelineEditor.volumeId, .number(0.7)),
    ]

    /// (fixture name, selected clip or nil for the composition, group to open).
    static let fixtures: [(String, String?, String)] = [
        ("transform", "clip:a", "layout"), ("style", "clip:a", "style"), ("media-ease", "clip:a", "media"),
        ("image-media", "clip:logo", "media"), ("composition", nil, InspectorPanel.compositionGroupId),
    ]

    static func panel(clip: String?, group: String, width: Double) throws -> (RightPanel, PanelMeasureCanvas) {
        let r = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        if let clip {
            for p in keyed {
                for t in [0.5, 2.5] { _ = editor.toggleKeyframe(clipId: clip, p.id, time: t, fallback: p.value) }
            }
            r.inspector.selection = [clip]
        }
        r.inspector.editor = editor
        r.inspector.time = 1.5
        if clip == "clip:logo" { r.inspector.cropActive = clip }   // the image fixture shows the crop rows (link edges, T/R/B/L)
        if clip != nil, r.inspector.openGroupId != group { r.inspector.toggleGroup(group) }
        let c = PanelMeasureCanvas()
        r.draw(c, size: CanvasSize(width, height))
        return (r, c)
    }

    /// Every fixture at every width in both appearances.
    func forEachLayout(_ body: (String, RightPanel, PanelMeasureCanvas) throws -> Void) throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            for (wName, w) in Self.widths {
                for (name, clip, group) in Self.fixtures {
                    let (r, c) = try Self.panel(clip: clip, group: group, width: w)
                    try body("\(name) \(wName) \(mode)", r, c)
                }
            }
        }
    }

    /// Regions that hold other targets (a header, a body) rather than being one.
    static func isContainer(_ h: InspectorPanel.Hit) -> Bool {
        switch h {
        case .body, .group, .scrollbar: true
        default: false
        }
    }

    static func targets(_ r: RightPanel) -> [(rect: CanvasRect, action: String)] {
        let header = r.hits.regions.filter { if case .content = $0.action { return false }; return true }
            .map { ($0.rect, "header \($0.action)") }
        let inspector = r.inspector.hits.regions.filter { !isContainer($0.action) }.map { ($0.rect, "\($0.action)") }
        return header + inspector
    }

    static func overlap(_ a: CanvasRect, _ b: CanvasRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.x, b.x) > 0.01 && min(a.maxY, b.maxY) - max(a.y, b.y) > 0.01
    }

    static func contains(_ outer: CanvasRect, _ inner: CanvasRect) -> Bool {
        inner.x >= outer.x - 0.01 && inner.maxX <= outer.maxX + 0.01 && inner.y >= outer.y - 0.01 && inner.maxY <= outer.maxY + 0.01
    }

    /// Each drawn string's box on the measuring canvas (origin = em-box top-left, width from the canvas's metrics).
    static func textBoxes(_ c: PanelMeasureCanvas) -> [(String, CanvasRect)] {
        c.texts.filter { !$0.0.isEmpty }.map { t in
            (t.0, CanvasRect(x: t.1.x, y: t.1.y, width: c.measureText(t.0, font: t.2).width, height: t.2.size))
        }
    }

    // MARK: Rule checks (also run on hand-made inputs below)

    static func gridFailures(_ p: InspectorPanel, width: Double) -> [String] {
        guard let g = p.layoutForAudit(width: width) else { return ["no open group"] }
        let box = CanvasRect(x: 0, y: 0, width: width, height: 0)
        var out: [String] = []
        for (row, slot) in zip(g.rows, InspectorPanel.rowSlots(g, in: box)) {
            if !PanelGrid.isOnGrid(slot.y) || !PanelGrid.isOnGrid(slot.height) { out.append("\(row.kind) at y \(slot.y) h \(slot.height)") }
        }
        if !PanelGrid.isOnGrid(g.spacing) { out.append("group spacing \(g.spacing)") }
        return out
    }

    static func targetFailures(_ targets: [(rect: CanvasRect, action: String)]) -> [String] {
        var out: [String] = []
        for (i, t) in targets.enumerated() {
            if t.rect.width < PanelGrid.minTarget - 0.01 || t.rect.height < PanelGrid.minTarget - 0.01 {
                out.append("\(t.action) is \(t.rect.width)x\(t.rect.height)")
            }
            for u in targets[(i + 1)...] where u.action != t.action && overlap(t.rect, u.rect) { out.append("\(t.action) overlaps \(u.action)") }
        }
        return out
    }

    /// A text over another text, or across a target without lying inside it.
    static func textFailures(_ texts: [(String, CanvasRect)], _ targets: [(rect: CanvasRect, action: String)]) -> [String] {
        var out: [String] = []
        for (i, t) in texts.enumerated() {
            for u in texts[(i + 1)...] where overlap(t.1, u.1) { out.append("\"\(t.0)\" over \"\(u.0)\"") }
            for g in targets where overlap(t.1, g.rect) && !contains(g.rect, t.1) { out.append("\"\(t.0)\" across \(g.action)") }
        }
        return out
    }

    // MARK: Audits

    func testEveryRowSlotIsOnTheGrid() throws {
        try forEachLayout { name, r, _ in
            XCTAssertEqual(Self.gridFailures(r.inspector, width: r.inspector.lastRect.width), [], name)
            for h in r.inspector.hits.regions { if case .group = h.action { XCTAssertTrue(PanelGrid.isOnGrid(h.rect.y), "\(name): \(h.action) at \(h.rect.y)") } }
        }
    }

    func testEveryTargetIsAtLeast24PointsAndNoneOverlap() throws {
        try forEachLayout { name, r, _ in XCTAssertEqual(Self.targetFailures(Self.targets(r)), [], name) }
    }

    func testNoTextOverlapsTextOrAControlItDoesNotBelongTo() throws {
        try forEachLayout { name, r, c in XCTAssertEqual(Self.textFailures(Self.textBoxes(c), Self.targets(r)), [], name) }
    }

    /// Fields, tracks and options start at the control column (or, stacked, at the row's left edge below the label).
    func testControlsStartAtTheControlColumn() throws {
        try forEachLayout { name, r, _ in
            let content = r.inspector.lastRect.width - 2 * PanelGrid.gutter
            let row = CanvasRect(x: PanelGrid.gutter, y: 0, width: content, height: PanelGrid.rowHeight)
            let controlX = PanelGrid.columns(row).control.x
            var seenSegments: Set<String> = []
            for h in r.inspector.hits.regions {
                if case .segment(let key, _) = h.action, !seenSegments.insert(key).inserted { continue }   // only the first option
                switch h.action {
                case .slider, .field, .segment:
                    let x = h.rect.x
                    XCTAssertTrue(abs(x - controlX) < 0.01 || x >= controlX || abs(x - row.x) < 0.01 || Self.isCompactField(h.action, r),
                                  "\(name): \(h.action) starts at \(x), the control column is \(controlX)")
                default: continue
                }
            }
        }
    }

    /// Issue #187 A1: on every unstacked property row (keyed or not, keyframeable or not) the value field, the slider's
    /// value and the segmented control end at one value edge, the reserved reset cell and keyframe gutter after it.
    func testValuesEndAtOneEdge() throws {
        try forEachLayout { name, r, _ in
            guard let g = r.inspector.layoutForAudit(width: r.inspector.lastRect.width) else { return XCTFail(name) }
            let row = CanvasRect(x: PanelGrid.gutter, y: 0, width: r.inspector.lastRect.width - 2 * PanelGrid.gutter, height: 0)
            let edge = InspectorPanel.valueEdge(row)
            for rw in g.rows where !rw.stacked && !rw.rail {
                for (what, maxX) in Self.valueEnds(rw, r.inspector) {
                    XCTAssertEqual(maxX, edge, accuracy: 0.01, "\(name): \(what) ends at \(maxX), the value edge is \(edge)")
                }
            }
        }
    }

    /// Where a row's value ends: a number's field, a pair's second field, a slider's value (the track ends 48 before
    /// it), a segmented row's last option, a toggle's switch cell (4 wider than the switch).
    static func valueEnds(_ row: InspectorRow, _ p: InspectorPanel) -> [(String, Double)] {
        func hit(_ h: InspectorPanel.Hit) -> CanvasRect? { p.hits.rect { $0 == h } }
        switch row.kind {
        case .number(let n): return hit(.field(n.key)).map { [(n.key, $0.maxX)] } ?? []
        case .pair(_, _, let b): return hit(.field(b.key)).map { [(b.key, $0.maxX)] } ?? []
        case .slider(let s): return hit(.slider(s.key)).map { [(s.key, $0.maxX + 8 + InspectorPanel.sliderValueWidth)] } ?? []
        case .segmented(let s): return s.options.last.flatMap { o in hit(.segment(s.key, o.key)).map { [(s.key, $0.maxX)] } } ?? []
        case .toggle(let t): return hit(.toggle(t.key)).map { [(t.key, $0.maxX)] } ?? []
        default: return []
        }
    }

    /// Issue #154: at 280 pt the "Easing…" button sits under its heading, clear of it (the Ease row it replaced is gone).
    func testEasingButtonIsClearOfItsHeadingAtTheMinimumWidth() throws {
        let (r, c) = try Self.panel(clip: "clip:a", group: "media", width: PanelFit.minRight)
        let heading = try XCTUnwrap(Self.textBoxes(c).first { $0.0.lowercased() == "keyframe easing" }, "texts: \(Self.textBoxes(c).map(\.0))")
        let button = try XCTUnwrap(Self.textBoxes(c).first { $0.0 == "Easing…" }, "texts: \(Self.textBoxes(c).map(\.0))")
        XCTAssertFalse(Self.overlap(heading.1, button.1), "heading \(heading.1) over button \(button.1)")
        XCTAssertTrue(r.inspector.hits.regions.contains { if case .button("openEasing") = $0.action { return true }; return false })
    }

    // MARK: The rules on hand-made inputs

    func testTheRulesCatchWhatTheyClaim() {
        let a = CanvasRect(x: 0, y: 0, width: 24, height: 24)
        XCTAssertEqual(Self.targetFailures([(a, "a"), (CanvasRect(x: 24, y: 0, width: 24, height: 24), "b")]), [])
        XCTAssertEqual(Self.targetFailures([(a, "a"), (CanvasRect(x: 20, y: 0, width: 24, height: 24), "b")]), ["a overlaps b"])
        XCTAssertEqual(Self.targetFailures([(CanvasRect(x: 0, y: 0, width: 23, height: 24), "s")]), ["s is 23.0x24.0"])
        let label = ("Ease", CanvasRect(x: 0, y: 0, width: 20, height: 11))
        XCTAssertEqual(Self.textFailures([label, ("Linear", CanvasRect(x: 18, y: 0, width: 30, height: 11))], []), ["\"Ease\" over \"Linear\""])
        XCTAssertEqual(Self.textFailures([label], [(CanvasRect(x: 10, y: -8, width: 40, height: 28), "segment")]), ["\"Ease\" across segment"])
        XCTAssertEqual(Self.textFailures([label], [(CanvasRect(x: -2, y: -8, width: 40, height: 28), "field")]), [])
        XCTAssertTrue(PanelGrid.isOnGrid(48)); XCTAssertFalse(PanelGrid.isOnGrid(43.5))
        XCTAssertEqual(PanelGrid.snapUp(20.5), 24); XCTAssertEqual(PanelGrid.snapUp(32), 32)
        XCTAssertEqual(PanelGrid.labelWidth(contentWidth: 248), 80); XCTAssertEqual(PanelGrid.labelWidth(contentWidth: 200), 72); XCTAssertEqual(PanelGrid.labelWidth(contentWidth: 377), 96)
    }

    /// The compact fields of a pair or quad start after their own one-letter label, inside the row's grid columns.
    static func isCompactField(_ h: InspectorPanel.Hit, _ r: RightPanel) -> Bool {
        guard case .field(let k) = h else { return false }
        return r.inspector.allRows().contains { row in
            switch row.kind {
            case .pair(_, let a, let b): return a.key == k || b.key == k
            case .quad(let ns): return ns.contains { $0.key == k }
            default: return false
            }
        }
    }
}
