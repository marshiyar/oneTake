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
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// docs/DESIGN.md Rollout 5 (issue #36): inspector labels are grey in every state, a value turns the accent once the
/// user changed it, and the keyframe controls on a property's row work from the keyboard.
final class InspectorValueColourTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func makeInspector(open group: String) throws -> (InspectorPanel, TimelineEditor, PanelMeasureCanvas) {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        let p = InspectorPanel(); p.editor = editor; p.selection = ["clip:a"]; p.time = 1; p.openGroupId = group
        let c = PanelMeasureCanvas()
        redraw(p, c)
        return (p, editor, c)
    }

    func redraw(_ p: InspectorPanel, _ c: PanelMeasureCanvas) {
        c.reset(); p.draw(c, in: CanvasRect(x: 0, y: 0, width: 360, height: 1400))
    }

    /// The colour `text` was drawn in: in the mono face for a value, the UI face for a label (the last time, when it
    /// was drawn more than once).
    func colour(_ c: PanelMeasureCanvas, _ text: String, value: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> CanvasColor? {
        let family = value ? PanelTheme.monoFamily : PanelTheme.uiFamily
        let found = c.texts.last { $0.0 == text && $0.2.family == family }?.3
        XCTAssertNotNil(found, "\"\(text)\" is drawn in \(family)", file: file, line: line)
        return found
    }

    func testNumberLabelStaysGreyAndAChangedValueIsTheAccent() throws {
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            let (p, editor, c) = try makeInspector(open: "layout")
            let before = try XCTUnwrap(p.number("rotation"))
            XCTAssertEqual(before.tier, .default)
            XCTAssertEqual(colour(c, "Rotation"), PanelTheme.rowLabel, "\(mode) untouched label")
            XCTAssertEqual(colour(c, before.text, value: true), PanelTheme.neutral100, "\(mode) untouched value")

            // Typed into the field, as a user does: one undo step, and the value reads in the accent.
            XCTAssertTrue(p.pointerDown(try XCTUnwrap(p.hits.rect { $0 == .field("rotation") }).center))
            for _ in 0..<before.text.count { _ = p.keyDown(EditorKey(.backspace)) }
            for ch in "15" { _ = p.keyDown(EditorKey(.char(ch))) }
            XCTAssertTrue(p.keyDown(EditorKey(.enter)))
            XCTAssertEqual(editor.undoStack.count, 1)
            redraw(p, c)
            let after = try XCTUnwrap(p.number("rotation"))
            XCTAssertEqual(after.tier, .explicitCustom)
            XCTAssertEqual(colour(c, "Rotation"), PanelTheme.rowLabel, "\(mode) the label stays grey once changed")
            XCTAssertEqual(colour(c, after.text, value: true), PanelTheme.accent, "\(mode) changed value")

            editor.undo(); redraw(p, c)
            XCTAssertEqual(colour(c, try XCTUnwrap(p.number("rotation")).text, value: true), PanelTheme.neutral100, "\(mode) undo restores the ink")
        }
    }

    func testPositionFieldsAndHeadingAreGreyUntilChanged() throws {
        let (p, _, c) = try makeInspector(open: "layout")
        XCTAssertEqual(colour(c, "Position"), PanelTheme.rowLabel)
        XCTAssertEqual(colour(c, "X"), PanelTheme.rowLabel)
        p.number("x")?.commit("120"); redraw(p, c)
        let x = try XCTUnwrap(p.number("x"))
        XCTAssertEqual(x.text.hasPrefix("120"), true, x.text)
        XCTAssertEqual(colour(c, "X"), PanelTheme.rowLabel, "the compact field's label stays grey")
        XCTAssertEqual(colour(c, x.text, value: true), PanelTheme.accent)
    }

    func testSliderLabelStaysGreyAndAChangedValueIsTheAccent() throws {
        let (p, _, c) = try makeInspector(open: "style")
        let before = try XCTUnwrap(p.slider("opacity"))
        XCTAssertEqual(colour(c, "Opacity"), PanelTheme.rowLabel)
        XCTAssertEqual(colour(c, before.display, value: true), PanelTheme.neutral100)
        before.commit(50); redraw(p, c)
        let after = try XCTUnwrap(p.slider("opacity"))
        XCTAssertEqual(after.display, "50%")
        XCTAssertEqual(colour(c, "Opacity"), PanelTheme.rowLabel)
        XCTAssertEqual(colour(c, "50%", value: true), PanelTheme.accent)
    }

    /// Toggle and segmented rows label in the same grey, on or off.
    func testToggleAndSegmentedLabelsAreGrey() {
        let p = InspectorPanel(), c = PanelMeasureCanvas()
        for on in [false, true] {
            p.drawToggle(c, CanvasRect(x: 0, y: 0, width: 300, height: 30),
                         InspectorRow.Toggle(key: "t\(on)", label: on ? "Loop on" : "Loop off", on: on, set: { _ in }))
        }
        p.drawSegmented(c, CanvasRect(x: 0, y: 40, width: 300, height: 32),
                        InspectorRow.Segmented(key: "s", label: "Blend", options: [(key: "a", label: "Normal", active: true)], select: { _ in }))
        XCTAssertEqual(colour(c, "Loop off"), PanelTheme.rowLabel)
        XCTAssertEqual(colour(c, "Loop on"), PanelTheme.rowLabel)
        XCTAssertEqual(colour(c, "Blend"), PanelTheme.rowLabel)
    }

    /// A changed value being typed reads in the field's ink, and disabled values stay neutral600 even when changed.
    func testTypedAndDisabledValuesKeepTheirInk() throws {
        let (p, _, c) = try makeInspector(open: "layout")
        p.number("rotation")?.commit("15"); redraw(p, c)
        XCTAssertTrue(p.pointerDown(try XCTUnwrap(p.hits.rect { $0 == .field("rotation") }).center))
        redraw(p, c)
        let draft = try XCTUnwrap(p.field?.draft)
        XCTAssertEqual(colour(c, draft, value: true), PanelTheme.neutral100, "typed")

        let q = InspectorPanel(), d = PanelMeasureCanvas()
        q.drawNumber(d, CanvasRect(x: 0, y: 0, width: 300, height: 30),
                     InspectorRow.Number(key: "n", label: "N", text: "7px", tier: .explicitCustom, commit: { _ in }, disabled: true), compact: false)
        q.drawSlider(d, CanvasRect(x: 0, y: 40, width: 300, height: 28),
                     InspectorRow.Slider(key: "s", label: "S", position: 50, min: 0, max: 100, display: "50%", format: { "\($0)" },
                                         tier: .explicitCustom, commit: { _ in }, disabled: true))
        XCTAssertEqual(colour(d, "7px", value: true), PanelTheme.neutral600, "disabled number")
        XCTAssertEqual(colour(d, "50%", value: true), PanelTheme.neutral600, "disabled slider")
    }

    /// Principle 6: the grey labels and the accent values reach WCAG AA (4.5:1) on the inspector's inset body and on
    /// the compact fields' panel grey, in both modes.
    func testLabelAndValueContrastIsAA() {
        func t(_ c: CanvasColor) -> ThemeColor { ThemeColor(r: c.r, g: c.g, b: c.b) }
        for mode in ThemeMode.allCases {
            Theme.setMode(mode)
            for (name, ink) in [("label", PanelTheme.rowLabel), ("changed value", PanelTheme.accent), ("value", PanelTheme.neutral100)] {
                for (surface, bg) in [("inset", PanelTheme.panelBgInset), ("panel", PanelTheme.panelBg)] {
                    XCTAssertGreaterThanOrEqual(t(ink).contrast(t(bg)), 4.5, "\(mode) \(name) on \(surface)")
                }
            }
        }
    }

    /// Tab reaches the stopwatch and the previous / add / next keyframe controls on the property's row, in that
    /// order, and Space on the stopwatch starts animating the property.
    func testKeyframeControlsOnTheRowWorkFromTheKeyboard() throws {
        let (p, editor, c) = try makeInspector(open: "layout")
        var stops: [InspectorPanel.Hit] = []
        for _ in 0..<200 {
            guard p.keyDown(EditorKey(.tab)), let cur = p.focus.current else { break }
            if stops.contains(cur) { break }
            stops.append(cur)
        }
        let watch = try XCTUnwrap(stops.firstIndex(of: .stopwatch("rotation")), "Tab reaches the rotation stopwatch")
        XCTAssertEqual(stops.firstIndex(of: .keyframe("rotation")).map { $0 > watch }, true, "◆ after the stopwatch")
        XCTAssertNil(stops.firstIndex(of: .kfPrev("rotation")), "no previous key yet: the stepper is not a stop")

        p.focus.current = .stopwatch("rotation"); p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.space)))
        XCTAssertTrue(editor.isAnimated(clipId: "clip:a", TimelineEditor.rotationId))
        XCTAssertEqual(editor.undoStack.count, 1)
        redraw(p, c)
        XCTAssertEqual(p.keyframe("rotation")?.state, .onKey)
    }
}

private extension CanvasRect {
    var center: CanvasPoint { CanvasPoint(x + width / 2, y + height / 2) }
}

#if os(Linux)   // Cairo draws real pixels.
/// The Design tab at the window's 900 px height (1440×900), opened to Transform with Rotation changed, in dark and
/// light, at 1x and 2x. `MPVFX_SNAPSHOT_DIR` writes `inspector-values-<mode>-<scale>x.png` for review.
final class InspectorValueSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func testInspectorValuesInDarkAndLight() throws {
        for (mode, panel, inset) in [(ThemeMode.dark, "#1d1d1d", "#191919"), (.light, "#fafafa", "#f4f4f5")] {
            Theme.setMode(mode)
            for scale in [1.0, 2.0] {
                let r = try PanelSnapshotTests.rightFixture(open: "layout", h: 900)
                r.inspector.time = 1
                r.inspector.number("rotation")?.commit("15")
                XCTAssertEqual(r.inspector.number("rotation")?.tier, .explicitCustom)
                let t = CairoImageTarget(width: Int(409 * scale), height: Int(900 * scale))
                t.canvas.scale(scale, scale)
                t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 409, height: 900), PanelTheme.studioBg)
                r.draw(t.canvas, size: CanvasSize(409, 900))
                if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    XCTAssertEqual(t.writePNG("\(dir)/inspector-values-\(mode)-\(Int(scale))x.png"), 0)
                }
                // Font-independent pixels: the flat panel under the tab strip and the open group's inset body.
                for (x, y, hex) in [(200.0, 70.0, panel), (200.0, 122.0, inset)] {
                    let px = t.pixel(Int(x * scale), Int(y * scale)), want = try XCTUnwrap(CanvasColor(hex: hex))
                    let ok = [(Double(px.r), want.r), (Double(px.g), want.g), (Double(px.b), want.b)].allSatisfy { abs($0 - $1 * 255) <= 6 }
                    XCTAssertTrue(ok, "\(mode) @\(scale)x pixel (\(x),\(y)) = rgb(\(px.r),\(px.g),\(px.b)), want \(hex)")
                }
            }
        }
    }
}
#endif
