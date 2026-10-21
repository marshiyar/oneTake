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
import MpvfxTimeline
@testable import MpvfxPanels

final class MarkersPanelTests: XCTestCase {
    func make() throws -> (MarkersPanel, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON), p = MarkersPanel()
        p.editor = e; return (p, e)
    }
    func testLegacyDocumentStaysWithoutMarkersAndRoundTripsAllFields() throws {
        let (_, e) = try make()
        XCTAssertNil(e.document.sequence.markers)
        XCTAssertFalse(try serializeNativeProjectDocument(e.document).contains("\"markers\""))
        XCTAssertNotNil(e.addMarker(at: 1.25, name: "Beat", color: "#12ABef", note: "A note\nwith a line"))
        let encoded = try serializeNativeProjectDocument(e.document)
        let parsed = try parseNativeProjectDocument(try NativeJSONValue.parse(encoded))
        XCTAssertEqual(parsed.sequence.markers, e.document.sequence.markers)
    }
    func testUnknownMarkerFieldsSurviveParseEditAndSave() throws {
        let (_, e) = try make(); _ = e.addMarker(at: 1)
        var raw = try NativeJSONValue.from(e.document), seq = try NativeJSONValue.from(e.document.sequence)
        var marker = seq["markers"]!.arrayValue![0]
        marker["future"] = .object(["enabled": .bool(true)])
        seq["markers"] = .array([marker]); raw["sequence"] = seq
        let editor = TimelineEditor(document: try parseNativeProjectDocument(raw))
        var updated = try XCTUnwrap(editor.document.sequence.markers?.first); updated.name = "Renamed"
        XCTAssertTrue(editor.updateMarker(updated))
        let saved = try NativeJSONValue.parse(serializeNativeProjectDocument(editor.document))
        XCTAssertEqual(saved["sequence"]?["markers"]?.arrayValue?.first?["future"], marker["future"])
    }
    func testValidatorRejectsMalformedFieldsAndDuplicateIDs() throws {
        let (_, e) = try make()
        _ = e.addMarker(at: 1)
        let base = try NativeJSONValue.from(e.document)
        for (key, value) in [("time", NativeJSONValue.number(-1)), ("name", .string(" ")), ("color", .string("red")), ("note", .number(4)), ("id", .string(""))] {
            var raw = base
            var marker = raw["sequence"]!["markers"]!.arrayValue![0]
            marker[key] = value
            var sequence = raw["sequence"]!; sequence["markers"] = .array([marker]); raw["sequence"] = sequence
            XCTAssertFalse(validateNativeProjectDocument(raw).isEmpty, key)
        }
        var raw = base, sequence = base["sequence"]!
        let marker = sequence["markers"]!.arrayValue![0]
        sequence["markers"] = .array([marker, marker]); raw["sequence"] = sequence
        XCTAssertTrue(validateNativeProjectDocument(raw).contains { $0.code == .duplicateId })
        XCTAssertNil(e.addMarker(at: .infinity))
        XCTAssertNil(e.addMarker(at: .nan))
        XCTAssertEqual(e.undoStack.count, 1)
    }
    func testAddEditDeleteUndoRedoRestoresExactDocument() throws {
        let (_, e) = try make(); let original = e.document
        let id = try XCTUnwrap(e.addMarker(at: 1, name: "First")); let added = e.document
        var marker = try XCTUnwrap(e.document.sequence.markers?.first)
        marker.name = "Second"; marker.time = 2; marker.note = "Changed"; marker.color = "#FF0000"
        XCTAssertTrue(e.updateMarker(marker)); let edited = e.document
        XCTAssertFalse(e.updateMarker(marker))
        XCTAssertTrue(e.deleteMarker(id)); XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, edited)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, added)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, original)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.document, added)
    }
    func testPanelClickJumpDoubleClickRenameDeleteAndKeyboard() throws {
        let (p, e) = try make(); _ = e.addMarker(at: 1.5, name: "Old")
        let c = PanelMeasureCanvas(); p.draw(c, size: CanvasSize(300, 200))
        XCTAssertTrue(c.drawnStrings.contains("Old"))
        var jumps: [Double] = []; p.onJump = { jumps.append($0) }; var time = 10.0; p.now = { time }
        XCTAssertTrue(p.pointerDown(.init(25, 10), shift: false)); XCTAssertEqual(jumps, [1.5])
        time += 0.2; XCTAssertTrue(p.pointerDown(.init(25, 10), shift: false)); XCTAssertNotNil(p.editingID)
        for ch in "New" { XCTAssertTrue(p.keyDown(.init(.char(ch)))) }
        XCTAssertTrue(p.keyDown(.init(.enter))); XCTAssertNil(p.editingID)
        XCTAssertEqual(e.document.sequence.markers?.first?.name, "New")
        XCTAssertEqual(e.undoStack.count, 2)
        XCTAssertTrue(p.keyDown(.init(.delete))); XCTAssertEqual(p.rows.count, 0)
        XCTAssertTrue(e.undo()); XCTAssertEqual(p.rows.first?.name, "New")
        XCTAssertTrue(p.keyDown(.init(.down))); XCTAssertEqual(jumps.last, 1.5)
        XCTAssertTrue(p.keyDown(.init(.function(2)))); XCTAssertTrue(p.keyDown(.init(.char("m"))))
        XCTAssertTrue(p.keyDown(.init(.escape))); XCTAssertEqual(p.rows.count, 1)
        XCTAssertEqual(p.rows.first?.name, "New", "Escape discards draft and M never adds while editing")
    }
    func testPanelEditsAllFieldsAndRefusesInvalidCommit() throws {
        let (p, e) = try make(); let id = try XCTUnwrap(e.addMarker(at: 1))
        XCTAssertTrue(p.beginEditing(id))
        _ = p.keyDown(.init(.tab)); _ = p.keyDown(.init(.char("-"))); _ = p.keyDown(.init(.char("1")))
        XCTAssertFalse(p.commitEditing()); XCTAssertEqual(p.rows.first?.time, 1)
        _ = p.keyDown(.init(.tab, shift: true)); _ = p.keyDown(.init(.tab)); _ = p.keyDown(.init(.char("2")))
        _ = p.keyDown(.init(.tab)); for ch in "#00FF00" { _ = p.keyDown(.init(.char(ch))) }
        _ = p.keyDown(.init(.tab)); for ch in "Note" { _ = p.keyDown(.init(.char(ch))) }
        XCTAssertTrue(p.commitEditing()); XCTAssertEqual(p.rows.first?.time, 2)
        XCTAssertEqual(p.rows.first?.color, "#00FF00"); XCTAssertEqual(p.rows.first?.note, "Note")
    }
    func testRegisteredClosedByDefaultAndMAddsAtPlayheadWithoutMuting() throws {
        XCTAssertEqual(DockRegistry.editor.title("markers"), "Markers")
        XCTAssertTrue(DockRegistry.editor.spec("markers")?.startsClosed == true)
        let (_, e) = try make(); let view = TimelineView(tracks: [], duration: 10), playback = PlaybackState(duration: 10, fps: 30)
        let controller = TimelineController(view: view, playback: playback, editor: e)
        playback.seek(1)
        XCTAssertTrue(controller.keyDown(.init(.char("m"))))
        XCTAssertEqual(e.document.sequence.markers?.first?.time, 1)
        XCTAssertFalse(playback.audioMuted)
        XCTAssertEqual(view.markers.count, 1)
        XCTAssertTrue(controller.keyDown(.init(.char("m"), isRepeat: true)))
        XCTAssertEqual(view.markers.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertTrue(view.markers.isEmpty)
    }
}
