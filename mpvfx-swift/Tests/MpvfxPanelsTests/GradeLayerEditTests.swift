import XCTest
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// Issue #457: every grade layer edit is one undo step.
final class GradeLayerEditTests: XCTestCase {
    func testEachLayerEditIsOneUndoStep() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        var clock = 1000.0
        editor.now = { clock += 10; return clock }
        XCTAssertTrue(editor.addGradeLayer(clipId: "clip:a"))
        XCTAssertTrue(editor.addGradeLayer(clipId: "clip:a"))
        let ids = editor.gradeLayers(clipId: "clip:a").map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(editor.setGradeLayerEnabled(clipId: "clip:a", layerId: ids[0], false))
        XCTAssertEqual(editor.gradeLayers(clipId: "clip:a").map(\.enabled), [false, true])
        XCTAssertTrue(editor.moveGradeLayer(clipId: "clip:a", layerId: ids[1], to: 0))
        XCTAssertEqual(editor.gradeLayers(clipId: "clip:a").map(\.id), [ids[1], ids[0]])
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.gradeLayers(clipId: "clip:a").map(\.id), ids)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.gradeLayers(clipId: "clip:a").map(\.enabled), [true, true])
        XCTAssertTrue(editor.removeGradeLayer(clipId: "clip:a", layerId: ids[1]))
        XCTAssertEqual(editor.gradeLayers(clipId: "clip:a").count, 1)
        XCTAssertTrue(editor.undo()); XCTAssertEqual(editor.gradeLayers(clipId: "clip:a").count, 2)
        XCTAssertFalse(editor.setGradeLayerEnabled(clipId: "clip:a", layerId: ids[0], true), "no change, no step")
    }
}
