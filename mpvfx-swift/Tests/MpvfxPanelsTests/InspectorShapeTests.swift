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
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels
@testable import MpvfxTimeline

internal final class InspectorShapeTests: XCTestCase {
    private static let frame = CanvasRect(x: 0, y: 0, width: 360, height: 9000)

    private func panel(_ shape: NativeClipShape) throws -> (InspectorPanel, TimelineEditor, String) {
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json, engine: KeyframeRuntime())
        let id = try XCTUnwrap(editor.addShapeClip(shape, left: 100, top: 50, width: 300, height: 200, at: 0))
        let p = InspectorPanel()
        p.editor = editor
        p.selection = [id]
        p.openGroupId = InspectorPanel.shapeGroupId
        redraw(p)
        return (p, editor, id)
    }

    private func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: Self.frame) }
    private func rows(_ p: InspectorPanel) -> [InspectorRow] { p.groups.first { $0.id == InspectorPanel.shapeGroupId }?.addressableRows ?? [] }
    private func number(_ p: InspectorPanel, _ key: String) -> InspectorRow.Number? {
        for row in rows(p) { if case .number(let n) = row.kind, n.key == key { return n } }
        return nil
    }
    private func button(_ p: InspectorPanel, _ key: String) -> InspectorRow.Button? {
        for row in rows(p) { if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == key }) { return b } }
        return nil
    }

    internal func testTheGroupOffersTheValuesOfTheKind() throws {
        let expected: [(String, [String])] = [
            ("rectangle", ["shape.radius", "shape.strokeWidth", "shape.dash", "shape.fill", "shape.stroke"]),
            ("ellipse", ["shape.strokeWidth", "shape.dash", "shape.fill", "shape.stroke"]),
            ("polygon", ["shape.sides", "shape.strokeWidth", "shape.dash", "shape.fill", "shape.stroke"]),
            ("star", ["shape.sides", "shape.innerRadius", "shape.strokeWidth", "shape.dash", "shape.fill", "shape.stroke"]),
            ("arrow", ["shape.headLength", "shape.strokeWidth", "shape.dash", "shape.stroke"]),
            ("line", ["shape.strokeWidth", "shape.dash", "shape.stroke"]),
        ]
        for (kind, keys) in expected {
            let (p, _, _) = try panel(NativeClipShape(kind: kind))
            XCTAssertEqual(button(p, "shape.kind.\(kind)")?.style, .chipActive, kind)
            for key in keys { XCTAssertNotNil(number(p, key), "\(kind) has \(key)") }
            if kind == "line" { XCTAssertNil(number(p, "shape.radius")); XCTAssertNil(number(p, "shape.fill")) }
        }
    }

    internal func testEachEditIsOneUndoStepWithTiersAndReset() throws {
        let (p, editor, id) = try panel(NativeClipShape(kind: "rectangle"))
        let depth = editor.undoStack.count
        XCTAssertEqual(number(p, "shape.radius")?.tier, .default)
        XCTAssertNil(number(p, "shape.radius")?.reset)
        try XCTUnwrap(number(p, "shape.radius")).commit("24")
        redraw(p)
        XCTAssertEqual(editor.clip(id)?.clip.shape?.number("radius"), 24)
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertEqual(editor.undoLabel, "Edit shape")
        XCTAssertEqual(number(p, "shape.radius")?.tier, .explicitCustom)
        let reset = try XCTUnwrap(number(p, "shape.radius")?.reset)
        reset()
        redraw(p)
        XCTAssertNil(editor.clip(id)?.clip.shape?.raw["radius"], "the default is not stored")
        XCTAssertEqual(editor.undoStack.count, depth + 2)
        try XCTUnwrap(number(p, "shape.radius")).commit("999")
        XCTAssertNil(editor.clip(id)?.clip.shape?.raw["radius"], "a radius over half the box is refused, not clamped")
        XCTAssertEqual(editor.undoStack.count, depth + 2)
        try XCTUnwrap(number(p, "shape.strokeWidth")).commit("8")
        try XCTUnwrap(number(p, "shape.dash")).commit("12 8")
        XCTAssertEqual(editor.clip(id)?.clip.shape?.dash, [12, 8])
        redraw(p)
        try XCTUnwrap(number(p, "shape.dash")).commit("")
        XCTAssertEqual(editor.clip(id)?.clip.shape?.dash, [])
    }

    internal func testPickingAKindKeepsTheOtherValuesAndIsOneUndoStep() throws {
        let (p, editor, id) = try panel(NativeClipShape(kind: "rectangle", radius: 10, strokeWidth: 4))
        let depth = editor.undoStack.count
        try XCTUnwrap(button(p, "shape.kind.star")).action()
        redraw(p)
        XCTAssertEqual(editor.clip(id)?.clip.shape?.kind, "star")
        XCTAssertEqual(editor.clip(id)?.clip.shape?.number("strokeWidth"), 4)
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        XCTAssertNotNil(number(p, "shape.innerRadius"))
        try XCTUnwrap(number(p, "shape.sides")).commit("2.5")
        XCTAssertNil(editor.clip(id)?.clip.shape?.raw["sides"], "sides must be a whole number")
        try XCTUnwrap(number(p, "shape.sides")).commit("7")
        XCTAssertEqual(editor.clip(id)?.clip.shape?.number("sides"), 7)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(editor.clip(id)?.clip.shape?.raw["sides"])
    }

    internal func testColoursEditThroughTheShapeAndEveryRowTakesTab() throws {
        let (p, editor, id) = try panel(NativeClipShape(kind: "rectangle"))
        try XCTUnwrap(number(p, "shape.fill")).commit("#ff0000")
        XCTAssertEqual(editor.clip(id)?.clip.shape?.fill.lowercased(), "#ff0000")
        redraw(p)
        let order = PanelFocus<InspectorPanel.Hit>.order(p.hits, p.isFocusable)
        for entry in InspectorPanel.shapeKindLabels { XCTAssertTrue(order.contains(.button("shape.kind.\(entry.kind)")), entry.kind) }
        for key in ["shape.radius", "shape.strokeWidth", "shape.dash", "shape.fill", "shape.stroke"] {
            XCTAssertTrue(order.contains(.field(key)), "\(key) takes Tab")
        }
        p.focus.current = .button("shape.kind.ellipse")
        p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(editor.clip(id)?.clip.shape?.kind, "ellipse", "Return presses the focused pick")
    }

    internal func testNoShapeGroupWithoutAShape() throws {
        let editor = try TimelineEditor(json: InspectorMediaFitTests.json, engine: KeyframeRuntime())
        let p = InspectorPanel()
        p.editor = editor
        p.selection = ["clip:a"]
        XCTAssertFalse(p.groups.contains { $0.id == InspectorPanel.shapeGroupId })
    }
}
