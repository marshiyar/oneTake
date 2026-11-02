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
import MpvfxShared
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// Issue #297: the Masks group adds, edits and removes masks; every control is addressable by key, each edit is one
/// undo step, defaults are stored as absent, and a sound has no Masks group.
final class InspectorMasksTests: XCTestCase {
    struct MissingRow: Error, CustomStringConvertible { var key: String; var description: String { "no row \(key)" } }

    func panel(select id: String = "clip:a") throws -> (RightPanel, TimelineEditor) {
        try InspectorMediaFitTests().panel(select: id)
    }
    func masks(_ p: InspectorPanel) -> InspectorGroup? { p.groups.first { $0.id == "masks" } }
    func button(_ p: InspectorPanel, _ key: String) throws -> InspectorRow.Button {
        for row in masks(p)?.addressableRows ?? [] { if case .buttons(let bs) = row.kind, let b = bs.first(where: { $0.key == key }) { return b } }
        throw MissingRow(key: key)
    }
    func number(_ p: InspectorPanel, _ key: String) throws -> InspectorRow.Number {
        for row in masks(p)?.addressableRows ?? [] { if case .number(let n) = row.kind, n.key == key { return n } }
        throw MissingRow(key: key)
    }
    func segmented(_ p: InspectorPanel, _ key: String) throws -> InspectorRow.Segmented {
        for row in masks(p)?.addressableRows ?? [] { if case .segmented(let s) = row.kind, s.key == key { return s } }
        throw MissingRow(key: key)
    }
    func toggle(_ p: InspectorPanel, _ key: String) throws -> InspectorRow.Toggle {
        for row in masks(p)?.addressableRows ?? [] { if case .toggle(let t) = row.kind, t.key == key { return t } }
        throw MissingRow(key: key)
    }

    func testAMaskIsAddedByKindWithOneUndoStepAndASoundHasNoGroup() throws {
        let (r, editor) = try panel()
        XCTAssertEqual(masks(r.inspector)?.summary, "none")
        let depth = editor.undoStack.count
        try button(r.inspector, "masks.add.ellipse").action()
        XCTAssertEqual(editor.masks(clipId: "clip:a").map(\.kind), ["ellipse"])
        XCTAssertEqual(editor.undoStack.count, depth + 1); XCTAssertEqual(editor.undoLabel, "Add mask")
        XCTAssertEqual(masks(r.inspector)?.summary, "1")
        let (audio, _) = try panel(select: "clip:m")
        XCTAssertNil(masks(audio.inspector), "a sound has nothing to mask")
    }

    func testTypedValuesAreOneStepEachDefaultsAreAbsentAndResetsFollowTheTier() throws {
        let (r, editor) = try panel()
        try button(r.inspector, "masks.add.rectangle").action()
        var width = try number(r.inspector, "masks.mask-1.width")
        XCTAssertEqual(width.text, "50"); XCTAssertEqual(width.tier, .explicitCustom, "added at half the layer: not the default of 100 %")
        width.commit("100")
        XCTAssertNil(editor.masks(clipId: "clip:a").first?.width, "100 % is the default, stored as absent")
        let depth = editor.undoStack.count
        try number(r.inspector, "masks.mask-1.feather").commit("24")
        XCTAssertEqual(editor.masks(clipId: "clip:a").first?.feather, 24)
        XCTAssertEqual(editor.undoStack.count, depth + 1)
        let feather = try number(r.inspector, "masks.mask-1.feather")
        XCTAssertEqual(feather.tier, .explicitCustom); XCTAssertNotNil(feather.reset)
        try XCTUnwrap(feather.reset)()
        XCTAssertNil(editor.masks(clipId: "clip:a").first?.feather)
        XCTAssertNil(try number(r.inspector, "masks.mask-1.feather").reset, "nothing to reset at the default")
        try number(r.inspector, "masks.mask-1.opacity").commit("150")
        XCTAssertNil(editor.masks(clipId: "clip:a").first?.opacity, "above 100 % is refused")
        try number(r.inspector, "masks.mask-1.opacity").commit("40")
        XCTAssertEqual(try XCTUnwrap(editor.masks(clipId: "clip:a").first?.opacity), 0.4, accuracy: 1e-9)
        width = try number(r.inspector, "masks.mask-1.width")
        XCTAssertEqual(width.text, "100"); XCTAssertEqual(width.tier, .default)
    }

    func testModeInvertAndRemove() throws {
        let (r, editor) = try panel()
        try button(r.inspector, "masks.add.rectangle").action()
        try segmented(r.inspector, "masks.mask-1.mode").select("subtract")
        XCTAssertEqual(editor.masks(clipId: "clip:a").first?.mode, "subtract")
        XCTAssertEqual(try segmented(r.inspector, "masks.mask-1.mode").options.first { $0.active }?.key, "subtract")
        try segmented(r.inspector, "masks.mask-1.mode").select("add")
        XCTAssertNil(editor.masks(clipId: "clip:a").first?.mode, "add is the default")
        try toggle(r.inspector, "masks.mask-1.invert").set(true)
        XCTAssertEqual(editor.masks(clipId: "clip:a").first?.invert, true)
        try button(r.inspector, "masks.mask-1.remove").action()
        XCTAssertTrue(editor.masks(clipId: "clip:a").isEmpty)
        XCTAssertEqual(editor.undoLabel, "Remove mask")
        _ = editor.undo()
        XCTAssertEqual(editor.masks(clipId: "clip:a").count, 1, "one undo brings it back")
    }

    func testEachKindListsTheFieldsItUses() {
        XCTAssertEqual(InspectorPanel.maskFields("linear").map(\.key), ["x", "y", "angle", "feather", "expansion", "opacity"])
        XCTAssertEqual(InspectorPanel.maskFields("band").map(\.key), ["x", "y", "width", "angle", "feather", "expansion", "opacity"])
        XCTAssertEqual(InspectorPanel.maskFields("ellipse").map(\.key), ["x", "y", "width", "height", "angle", "feather", "expansion", "opacity"])
    }
}
