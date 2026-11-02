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

/// Cut-transition kinds in the Transition group: the Kind row shows every
/// known kind by title, switching kind keeps length and alignment, each kind
/// shows only its own option rows, and each option edit round-trips in one
/// undo step (angle, shape, centre, strength, ease, softness for iris).
final class InspectorTransitionKindsTests: XCTestCase {
    static let json = #"""
    {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":32,"background":"#000000"},
     "assets":[{"id":"a1","kind":"video","name":"Interview 1","source":"a.mov","durationFrames":300},
               {"id":"a2","kind":"video","name":"Interview 2","source":"b.mov","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"v1","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
       {"id":"A","assetId":"a1","startFrame":0,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"B","assetId":"a2","startFrame":60,"durationFrames":60,"sourceInFrame":30,"muted":false,"effects":[],"parameterTracks":[]}],
      "transitions":[{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"dissolve","durationFrames":30,"alignment":"centre"}]}]}}
    """#

    func panel(kind: NativeCutTransitionKind = .dissolve) throws -> (InspectorPanel, TimelineEditor) {
        // The transition starts as `kind`, so the editor's undo history is empty.
        let editor = try TimelineEditor(json: Self.json.replacingOccurrences(of: #""kind":"dissolve""#, with: #""kind":"\#(kind.rawValue)""#))
        let panel = InspectorPanel(); panel.editor = editor; panel.selection = ["A"]; panel.openGroupId = "transitions"
        return (panel, editor)
    }

    func rows(_ panel: InspectorPanel) -> [InspectorRow] { panel.groups.first { $0.id == "transitions" }?.addressableRows ?? [] }

    func pick(_ panel: InspectorPanel, _ key: String, _ value: String) throws {
        for row in rows(panel) { if case .segmented(let field) = row.kind, field.key == key { field.select(value); return } }
        XCTFail("Missing control \(key)")
    }

    func commitNumber(_ panel: InspectorPanel, _ key: String, _ text: String) throws {
        for row in rows(panel) { if case .number(let field) = row.kind, field.key == key { field.commit(text); return } }
        XCTFail("Missing control \(key)")
    }

    func commitSlider(_ panel: InspectorPanel, _ key: String, _ position: Double) throws {
        for row in rows(panel) { if case .slider(let field) = row.kind, field.key == key { field.commit(position); return } }
        XCTFail("Missing control \(key)")
    }

    func hasRow(_ panel: InspectorPanel, key: String) -> Bool {
        rows(panel).contains {
            switch $0.kind {
            case .segmented(let s): return s.key == key
            case .slider(let s): return s.key == key
            case .number(let n): return n.key == key
            case .buttons(let b): return b.contains { $0.key == key }
            case .pair(_, let a, let b): return a.key == key || b.key == key
            default: return false
            }
        }
    }

    func transition(_ editor: TimelineEditor) -> NativeCutTransition {
        editor.document.sequence.tracks[0].transitions![0]
    }

    // MARK: Kind row

    func testKindRowListsEveryKnownKindByTitle() throws {
        let (panel, _) = try panel()
        for row in rows(panel) {
            if case .segmented(let field) = row.kind, field.key == "transition:kind" {
                XCTAssertEqual(field.options.map(\.label), NativeCutTransitionKind.allCases.map(\.title))
                return
            }
        }
        XCTFail("Missing control transition:kind")
    }

    func testSwitchingKindKeepsLengthAndAlignment() throws {
        let (panel, editor) = try panel()
        let original = editor.document
        try pick(panel, "transition:kind", "wipe")
        XCTAssertEqual(transition(editor).kind, .wipe)
        XCTAssertEqual(transition(editor).durationFrames, 30, "switching kind keeps the length")
        XCTAssertEqual(transition(editor).alignment, .centre, "switching kind keeps the alignment")
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original, "one undo restores the kind")
    }

    // MARK: Option rows only for their kinds

    func testOptionRowsOnlyAppearForTheirKinds() throws {
        let direction: Set<NativeCutTransitionKind> = [.wipe, .push, .slide]
        let angle: Set<NativeCutTransitionKind> = [.wipe]
        let shape: Set<NativeCutTransitionKind> = [.iris]
        let centre: Set<NativeCutTransitionKind> = [.iris]
        let strength: Set<NativeCutTransitionKind> = [.zoomThrough]
        let softness: Set<NativeCutTransitionKind> = [.wipe, .iris]
        for kind in NativeCutTransitionKind.allCases {
            let (p, _) = try panel(kind: kind)
            XCTAssertEqual(hasRow(p, key: "transition:direction"), direction.contains(kind), "\(kind.rawValue): direction row")
            XCTAssertEqual(hasRow(p, key: "transition:angle"), angle.contains(kind), "\(kind.rawValue): angle row")
            XCTAssertEqual(hasRow(p, key: "transition:shape"), shape.contains(kind), "\(kind.rawValue): shape row")
            XCTAssertEqual(hasRow(p, key: "transition:centreX"), centre.contains(kind), "\(kind.rawValue): centreX row")
            XCTAssertEqual(hasRow(p, key: "transition:centreY"), centre.contains(kind), "\(kind.rawValue): centreY row")
            XCTAssertEqual(hasRow(p, key: "transition:strength"), strength.contains(kind), "\(kind.rawValue): strength row")
            XCTAssertEqual(hasRow(p, key: "transition:ease"), true, "\(kind.rawValue): ease row")
            XCTAssertEqual(hasRow(p, key: "transition:softness"), softness.contains(kind), "\(kind.rawValue): softness row")
        }
    }

    // MARK: One-undo-step round trips

    func testWipeAngleRoundTripsInOneUndoStep() throws {
        let (panel, editor) = try panel(kind: .wipe)
        let original = editor.document
        try commitNumber(panel, "transition:angle", "90")
        XCTAssertEqual(transition(editor).angle, 90)
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original, "one undo clears the angle")
    }

    func testWipeAngleEmptyTextClearsToDirection() throws {
        let (panel, editor) = try panel(kind: .wipe)
        try commitNumber(panel, "transition:angle", "90")
        XCTAssertEqual(transition(editor).angle, 90)
        try commitNumber(panel, "transition:angle", "")
        XCTAssertNil(transition(editor).angle, "empty text clears back to the direction")
    }

    func testIrisShapeRoundTripsInOneUndoStep() throws {
        let (panel, editor) = try panel(kind: .iris)
        let original = editor.document
        try pick(panel, "transition:shape", "rectangle")
        XCTAssertEqual(transition(editor).irisShape, .rectangle)
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original, "one undo restores the circle default")
    }

    func testIrisCentreRoundTripsInOneUndoStep() throws {
        let (panel, editor) = try panel(kind: .iris)
        try commitNumber(panel, "transition:centreX", "25")
        XCTAssertEqual(transition(editor).centreX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(transition(editor).centreX, 0.5, accuracy: 1e-9, "one undo restores the frame centre")
        try commitNumber(panel, "transition:centreY", "75")
        XCTAssertEqual(transition(editor).centreY, 0.75, accuracy: 1e-9)
    }

    func testZoomThroughStrengthRoundTripsInOneUndoStep() throws {
        let (panel, editor) = try panel(kind: .zoomThrough)
        let original = editor.document
        try commitSlider(panel, "transition:strength", 3)
        XCTAssertEqual(transition(editor).strength, 3, accuracy: 1e-9)
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original, "one undo restores the default strength")
    }

    func testEaseRoundTripsInOneUndoStep() throws {
        let (panel, editor) = try panel(kind: .slide)
        let original = editor.document
        try pick(panel, "transition:ease", "inout")
        XCTAssertEqual(transition(editor).ease,
            .cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1)))
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original, "one undo restores linear timing")
    }

    func testSoftnessRoundTripsInOneUndoStepForIris() throws {
        let (panel, editor) = try panel(kind: .iris)
        let original = editor.document
        try commitSlider(panel, "transition:softness", 40)
        XCTAssertEqual(transition(editor).softness, 0.4, accuracy: 1e-9)
        XCTAssertEqual(editor.undoStack.count, 1, "one undo step")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.document, original, "one undo restores the hard edge")
    }
}
