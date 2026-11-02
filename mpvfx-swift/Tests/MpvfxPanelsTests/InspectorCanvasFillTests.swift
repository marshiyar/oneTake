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
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// Issue #320: the Fill rows of the Composition section (the project's canvas fill) and of the Media group (a clip's
/// own): every row is reachable by key, each pick and value is one undo step, and the reset tiers follow the value.
final class InspectorCanvasFillTests: XCTestCase {
    struct MissingRow: Error, CustomStringConvertible { var key: String; var description: String { "no row \(key)" } }

    func panel(select id: String = "clip:a") throws -> (RightPanel, TimelineEditor) {
        let (r, editor) = try InspectorMediaFitTests().panel(select: id)
        return (r, editor)
    }

    func row(_ p: InspectorPanel, _ group: InspectorGroup, _ key: String) -> InspectorRow.Kind? {
        for r in group.addressableRows {
            switch r.kind {
            case .segmented(let s) where s.key == key: return r.kind
            case .number(let n) where n.key == key: return r.kind
            default: continue
            }
        }
        return nil
    }
    func media(_ p: InspectorPanel) -> InspectorGroup { p.groups.first { $0.id == "media" }! }
    func number(_ p: InspectorPanel, _ g: InspectorGroup, _ key: String) throws -> InspectorRow.Number {
        guard case .number(let n)? = row(p, g, key) else { throw MissingRow(key: key) }
        return n
    }
    func options(_ g: InspectorGroup, _ prefix: String) -> [InspectorRow.Button] {
        g.addressableRows.flatMap { r -> [InspectorRow.Button] in
            if case .buttons(let bs) = r.kind { return bs.filter { $0.key.hasPrefix(prefix + ".") && !$0.key.hasSuffix(".reset") } }
            return []
        }
    }
    func pick(_ g: InspectorGroup, _ key: String, _ option: String) throws {
        guard let b = options(g, key).first(where: { $0.key == "\(key).\(option)" }) else { throw MissingRow(key: "\(key).\(option)") }
        b.action()
    }
    func active(_ g: InspectorGroup, _ key: String) -> String? {
        options(g, key).first { $0.style == .chipActive }?.key.replacingOccurrences(of: key + ".", with: "")
    }

    func testTheClipsFillPicksAreOneUndoStepEachAndStartOnTheProjectsFill() throws {
        let (r, editor) = try panel()
        let key = "canvasFill.clip.kind"
        XCTAssertEqual(options(media(r.inspector), key).map(\.key), ["inherit", "none", "color", "gradient", "image", "blur"].map { "\(key).\($0)" })
        XCTAssertEqual(active(media(r.inspector), key), "inherit", "no fill of its own: the project's")
        let depth = editor.undoStack.count
        try pick(media(r.inspector), key, "blur")
        XCTAssertEqual(editor.clip("clip:a")?.clip.fill?.kind, "blur")
        XCTAssertEqual(editor.undoStack.count, depth + 1); XCTAssertEqual(editor.undoLabel, "Set clip fill")
        XCTAssertEqual(active(media(r.inspector), key), "blur")
        try pick(media(r.inspector), key, "inherit")
        XCTAssertNil(editor.clip("clip:a")?.clip.fill, "Project takes the project's fill again")
        XCTAssertEqual(editor.undoStack.count, depth + 2)
    }

    func testBlurAndDarkenWriteTheirDefaultsAsAbsentAndResetBackToThem() throws {
        let (r, editor) = try panel()
        try pick(media(r.inspector), "canvasFill.clip.kind", "blur")
        var blur = try number(r.inspector, media(r.inspector), "canvasFill.clip.blur")
        XCTAssertEqual(blur.text, "40"); XCTAssertEqual(blur.tier, .default); XCTAssertNil(blur.reset)
        blur.commit("80")
        XCTAssertEqual(editor.clip("clip:a")?.clip.fill?.blur, 80)
        blur = try number(r.inspector, media(r.inspector), "canvasFill.clip.blur")
        XCTAssertEqual(blur.tier, .explicitCustom); XCTAssertNotNil(blur.reset)
        blur.commit("999")   // out of range: refused, nothing recorded
        XCTAssertEqual(editor.clip("clip:a")?.clip.fill?.blur, 80)
        try XCTUnwrap(blur.reset)()
        XCTAssertNil(editor.clip("clip:a")?.clip.fill?.blur, "the default is stored as absent")
        let darken = try number(r.inspector, media(r.inspector), "canvasFill.clip.darken")
        XCTAssertEqual(darken.text, "0.3")
        darken.commit("0.5")
        XCTAssertEqual(editor.clip("clip:a")?.clip.fill?.darken, 0.5)
    }

    func testColorGradientAndImageRowsEditTheFillTheyBelongTo() throws {
        let (r, editor) = try panel()
        let kinds = { (option: String) throws in try self.pick(self.media(r.inspector), "canvasFill.clip.kind", option) }
        try kinds("color")
        try number(r.inspector, media(r.inspector), "canvasFill.clip.color").commit("#112233")
        XCTAssertEqual(editor.clip("clip:a")?.clip.fill?.color, "#112233")
        try number(r.inspector, media(r.inspector), "canvasFill.clip.color").commit("not a colour")
        XCTAssertEqual(editor.clip("clip:a")?.clip.fill?.color, "#112233", "a bad colour changes nothing")
        try kinds("gradient")
        try number(r.inspector, media(r.inspector), "canvasFill.clip.from").commit("#ff0000")
        try number(r.inspector, media(r.inspector), "canvasFill.clip.to").commit("#0000ff")
        try number(r.inspector, media(r.inspector), "canvasFill.clip.angle").commit("90")
        let g = try XCTUnwrap(editor.clip("clip:a")?.clip.fill)
        XCTAssertEqual(g.stops.map(\.color), ["#ff0000", "#0000ff"]); XCTAssertEqual(g.angle, 90)
        try kinds("image")
        XCTAssertNotEqual(editor.clip("clip:a")?.clip.fill?.kind, "image", "no image in the project: the pick is refused")
    }

    func testTheProjectsFillRowsLiveInTheCompositionSectionAndAudioClipsHaveNone() throws {
        let (r, editor) = try panel()
        let composition = r.inspector.compositionGroup(editor)
        let key = "canvasFill.project.kind"
        XCTAssertEqual(options(composition, key).map(\.key), ["none", "color", "gradient", "image", "blur"].map { "\(key).\($0)" },
                       "a project fill never inherits")
        XCTAssertEqual(active(composition, key), "none")
        let depth = editor.undoStack.count
        try pick(composition, key, "color")
        XCTAssertEqual(editor.document.compositionFill?.kind, "color")
        XCTAssertEqual(editor.undoStack.count, depth + 1); XCTAssertEqual(editor.undoLabel, "Set canvas fill")
        try number(r.inspector, r.inspector.compositionGroup(editor), "canvasFill.project.color").commit("#445566")
        XCTAssertEqual(editor.document.compositionFill?.color, "#445566")
        let (audio, _) = try panel(select: "clip:m")
        XCTAssertTrue(options(media(audio.inspector), "canvasFill.clip.kind").isEmpty, "a sound has no frame to fill")
    }

    func testEveryFillRowIsReachableByTheKeyboard() throws {
        let (r, _) = try panel()
        try pick(media(r.inspector), "canvasFill.clip.kind", "blur")
        let keys = media(r.inspector).addressableRows.compactMap { row -> String? in
            switch row.kind { case .custom(let c): c.id; case .number(let n): n.key; default: nil }
        }.filter { $0.hasPrefix("canvasFill.clip") }
        XCTAssertEqual(keys, ["canvasFill.clip.kind", "canvasFill.clip.blur", "canvasFill.clip.darken"])
    }
}
