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
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

final class UserLookTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("user-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func store(_ dir: URL) throws -> UserLookStore {
        try UserLookStore(path: dir.appendingPathComponent("looks.json").path) { data, path in
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    func editor() throws -> TimelineEditor { try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime()) }
    func effect(_ exposure: Double = 1) -> NativeClipEffect {
        var grade = ColorGrading(); grade.adjust["exposure"] = exposure; grade.effects["bloom"] = 0.3
        return .init(id: "grade", effectId: ColorGrading.effectId, enabled: true, parameters: grade.json)
    }
    func testSaveRenameDeleteSurviveReopeningTheCatalog() throws {
        let dir = try temporary(), first = try store(dir)
        let look = try first.save(name: "  Warm title  ", effects: [effect()])
        XCTAssertEqual(look.name, "Warm title")
        try first.rename(id: look.id, name: "Warm interview")
        let reopened = try store(dir)
        XCTAssertEqual(reopened.looks.map(\.name), ["Warm interview"])
        XCTAssertEqual(reopened.looks.first?.effects, [effect()])
        try reopened.delete(id: look.id)
        XCTAssertTrue(try store(dir).looks.isEmpty)
    }
    func testWriteFailureLeavesTheOldLookAndFileIntact() throws {
        let dir = try temporary(), good = try store(dir)
        let look = try good.save(name: "Original", effects: [effect()])
        let old = try Data(contentsOf: URL(fileURLWithPath: good.path))
        let failing = try UserLookStore(path: good.path) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try failing.rename(id: look.id, name: "Not saved")) {
            guard case UserLookError.writeFailed = $0 else { return XCTFail("typed write error expected") }
        }
        XCTAssertEqual(failing.looks.first?.name, "Original")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: good.path)), old)
    }
    func testInvalidNameAndCorruptOrNewerCatalogCannotOverwriteLooks() throws {
        let dir = try temporary(), s = try store(dir)
        XCTAssertThrowsError(try s.save(name: "  ", effects: []))
        XCTAssertThrowsError(try s.save(name: String(repeating: "x", count: 121), effects: []))
        try Data(#"{"version":2,"looks":[]}"#.utf8).write(to: URL(fileURLWithPath: s.path))
        XCTAssertThrowsError(try store(dir)) { XCTAssertEqual($0 as? UserLookError, .invalidCatalog) }
    }
    func testApplyToSeveralVisualClipsIsOneUndoStepAndLeavesGeometryAlone() throws {
        let e = try editor()
        let original = e.document
        let look = UserLook(name: "Warm", effects: [effect()])
        XCTAssertEqual(try e.applyUserLook(look, to: ["clip:a", "clip:b"], lutExists: { _ in true }), 2)
        for id in ["clip:a", "clip:b"] {
            XCTAssertEqual(e.colorGrading(clipId: id)?.adjust["exposure"], 1)
            XCTAssertEqual(e.colorGrading(clipId: id)?.effects["bloom"], 0.3)
            XCTAssertEqual(e.clip(id)?.clip.startFrame, original.sequence.tracks.flatMap(\.clips).first { $0.id == id }?.startFrame)
        }
        XCTAssertEqual(e.undoLabel, "Apply look")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, original); XCTAssertFalse(e.canUndo)
        XCTAssertTrue(e.redo())
        let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(reopened.colorGrading(clipId: "clip:b")?.json, e.colorGrading(clipId: "clip:b")?.json)
    }
    func testMissingLutIsTypedAndAtomicAcrossTheSelection() throws {
        let e = try editor(), original = e.document
        var grade = ColorGrading(); grade.lut = .init(src: "/missing/portrait.cube", intensity: 0.8)
        let look = UserLook(name: "Portrait", effects: [.init(id: "grade", effectId: ColorGrading.effectId, enabled: true, parameters: grade.json)])
        XCTAssertThrowsError(try e.applyUserLook(look, to: ["clip:a", "clip:b"], lutExists: { _ in false })) {
            XCTAssertEqual($0 as? UserLookError, .missingLut(look: "Portrait", path: "/missing/portrait.cube"))
            XCTAssertTrue($0.localizedDescription.contains("Restore or replace"))
        }
        XCTAssertEqual(e.document, original); XCTAssertFalse(e.canUndo)
    }
    func testLockedSelectionRefusesTheWholeApply() throws {
        let e = try editor(); var d = e.document
        let t = try XCTUnwrap(d.sequence.tracks.firstIndex { $0.clips.contains { $0.id == "clip:b" } })
        d.sequence.tracks[t].locked = true
        let locked = TimelineEditor(document: d, engine: e.engine)
        XCTAssertThrowsError(try locked.applyUserLook(UserLook(name: "Warm", effects: [effect()]), to: ["clip:a", "clip:b"], lutExists: { _ in true }))
        XCTAssertEqual(locked.document, d); XCTAssertFalse(locked.canUndo)
    }
    func testCaptureKeepsEffectsAndMakesLutLocationIndependentOfTheProject() throws {
        let e = try editor(); var grade = ColorGrading(); grade.lut = .init(src: "media/look.cube", intensity: 0.7)
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", grade))
        let effects = try XCTUnwrap(e.effectsForUserLook(clipId: "clip:a", time: 0, resolveLut: { "/project/" + $0 }))
        XCTAssertEqual(ColorGrading(json: try XCTUnwrap(effects.first?.parameters)).lut?.src, "/project/media/look.cube")
    }
    func testInspectorKeyboardCanSaveRenameApplyToMultipleAndDelete() throws {
        let s = try store(temporary()), e = try editor(), p = InspectorPanel()
        var grade = ColorGrading(); grade.adjust["exposure"] = 0.7
        XCTAssertTrue(e.setColorGrading(clipId: "clip:a", grade))
        p.userLookStore = s; p.editor = e; p.selection = ["clip:a"]; p.openGroupId = "looks"
        p.userLookNameDraft = "Keyboard look"
        func draw() { p.draw(PanelMeasureCanvas(), in: CanvasRect(x: 0, y: 0, width: 400, height: 1800)) }
        func press(_ key: String) throws {
            draw(); XCTAssertNotNil(p.button(key)); p.focus.current = .button(key); p.focus.visible = true
            XCTAssertTrue(p.keyDown(EditorKey(.enter))); draw()
        }
        try press("looks:save"); XCTAssertEqual(s.looks.map(\.name), ["Keyboard look"])
        p.userLookNameDraft = "Renamed"; try press("looks:rename"); XCTAssertEqual(s.looks.first?.name, "Renamed")
        p.selection = ["clip:a", "clip:b"]; try press("looks:apply"); XCTAssertEqual(e.undoLabel, "Apply look")
        try press("looks:delete"); XCTAssertTrue(s.looks.isEmpty)
    }
}
