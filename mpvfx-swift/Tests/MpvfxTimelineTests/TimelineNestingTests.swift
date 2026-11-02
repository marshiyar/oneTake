import XCTest
@testable import MpvfxTimeline
import MpvfxShared

/// Nest, Un-nest and Make unique on the editor: each is one undo step and refusals leave the document alone.
final class TimelineNestingTests: XCTestCase {
    static let json = """
    {"schemaVersion":1,"mediaEngine":"native","id":"nest","revision":0,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":64,"height":36,"background":"#000000"},
     "assets":[{"id":"cam","kind":"video","name":"cam","source":"cam.mov","durationFrames":300}],
     "sequence":{"id":"seq","name":"Main","tracks":[
       {"id":"v2","kind":"video","clips":[{"id":"b","assetId":"cam","startFrame":10,"durationFrames":50,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]},
       {"id":"v1","kind":"video","clips":[{"id":"a","assetId":"cam","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
    """

    func testNestAndUnnestAreOneUndoStepEach() throws {
        let e = try TimelineEditor(json: Self.json)
        let original = e.document
        let nestId = try XCTUnwrap(e.nestClips(["a", "b"]))
        XCTAssertEqual(e.undoStack.count, 1); XCTAssertEqual(e.undoLabel, "Nest clips")
        XCTAssertEqual(e.document.sequences?.count, 1)
        XCTAssertNotNil(e.unnestClip(nestId))
        XCTAssertEqual(e.undoStack.count, 2); XCTAssertEqual(e.undoLabel, "Un-nest clip")
        XCTAssertEqual(e.document.sequence.tracks, original.sequence.tracks)
        XCTAssertNil(e.document.sequences)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document.sequences?.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.document, original)
    }

    func testARefusedNestLeavesTheDocumentAndHistoryAlone() throws {
        let e = try TimelineEditor(json: Self.json)
        XCTAssertTrue(e.setTrackLocked("v1", true))
        let before = e.document, steps = e.undoStack.count
        XCTAssertNil(e.nestClips(["a"]))
        XCTAssertEqual(e.lastFailure?.message, "Track v1 is locked")
        XCTAssertEqual(e.document, before); XCTAssertEqual(e.undoStack.count, steps)
    }
}
