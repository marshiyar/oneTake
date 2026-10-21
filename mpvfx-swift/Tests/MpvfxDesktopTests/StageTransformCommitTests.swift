import Foundation
import XCTest
import MpvfxCanvas
import MpvfxPlayer
import MpvfxShared
import MpvfxTimeline
@testable import MpvfxDesktop

/// Transform-box drags through the session: one drag is one undo step (crop and size together), an animated
/// property gets a keyframe at the playhead through the keyframe API, and a locked track's layer is not transformed.
final class StageTransformCommitTests: XCTestCase {
    func makeSession() throws -> EditorSession {
        let s = try EditorSession(projectPath: nil, demo: true)
        s.audio?.stop()
        s.player.size = CanvasSize(1440, 900)
        s.timeline.view.selection = ["clip:a"]   // syncStage takes the stage selection from the timeline's
        s.syncStage()
        return s
    }

    func element(_ s: EditorSession) throws -> StageElement {
        try XCTUnwrap(s.player.view.elements.first { $0.id == "clip:a" })
    }

    /// Drags the selected clip's east handle `dx` view px and releases.
    func dragEastHandle(_ s: EditorSession, by dx: Double) throws {
        let ve = s.player.view.chromeElement(try element(s), in: s.player.size)
        let p = TransformBox.screenPoint(ve, unit: TransformHandle.e.unit)
        s.player.pointerDown(x: p.x, y: p.y)
        s.player.pointerMove(x: p.x + dx, y: p.y)
        s.player.pointerUp(x: p.x + dx, y: p.y)
    }

    func testOneDragIsOneUndoStepForItsCropAndSize() throws {
        let s = try makeSession()
        XCTAssertTrue(s.editor.setCrop(clipId: "clip:a", NativeClipCrop(top: 20, right: 40, bottom: 20, left: 40)))
        s.syncStage()
        let before = s.editor.document, entries = s.editor.undoStack.count
        let width = try element(s).rect.width
        try dragEastHandle(s, by: -60)
        XCTAssertLessThan(try element(s).rect.width, width, "the box got narrower")
        XCTAssertNotEqual(s.editor.crop(clipId: "clip:a"), NativeClipCrop(top: 20, right: 40, bottom: 20, left: 40), "crop scaled with it")
        XCTAssertEqual(s.editor.undoStack.count, entries + 1, "crop and size are one entry")
        XCTAssertEqual(s.editor.undoLabel, EditorSession.stageTransformLabel)
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(s.editor.document, before, "one undo restores both")
    }

    func testADragOnAnAnimatedSizeWritesAKeyframeAtThePlayhead() throws {
        let s = try makeSession()
        let a = try XCTUnwrap(s.editor.parameterAddress(clipId: "clip:a", TimelineEditor.widthId))
        let w = try element(s).rect.width
        XCTAssertTrue(s.editor.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: 0,
                                                                          value: .number(w), baselineValue: .number(w))))))
        s.playback.seek(2)   // frame 60 at 30 fps
        s.syncStage()
        let staticBefore = s.editor.clip("clip:a")?.clip.staticParameters?[TimelineEditor.widthId]
        try dragEastHandle(s, by: -60)
        let track = try XCTUnwrap(s.editor.clip("clip:a")?.clip.parameterTracks.first { $0.parameterId == TimelineEditor.widthId })
        XCTAssertEqual(track.keyframes.map(\.frame).sorted(), [0, 60], "the first key kept, a new key at the playhead")
        XCTAssertEqual(s.editor.clip("clip:a")?.clip.staticParameters?[TimelineEditor.widthId], staticBefore,
                       "the static width is not what changed")
    }

    func testALockedTrackLayerIsSelectedButNotTransformed() throws {
        let s = try makeSession()
        XCTAssertTrue(s.editor.setTrackLocked("track:v1", true))
        s.syncStage()
        XCTAssertTrue(try element(s).locked)
        let before = s.editor.document, entries = s.editor.undoStack.count
        try dragEastHandle(s, by: -60)
        let ve = s.player.view.chromeElement(try element(s), in: s.player.size)
        s.player.pointerDown(x: ve.centre.x + 30, y: ve.centre.y + 30)
        s.player.pointerMove(x: ve.centre.x + 90, y: ve.centre.y + 60)
        s.player.pointerUp(x: ve.centre.x + 90, y: ve.centre.y + 60)
        XCTAssertEqual(s.editor.document, before, "nothing written")
        XCTAssertEqual(s.editor.undoStack.count, entries)
        XCTAssertEqual(s.player.view.toast?.message, PlayerController.lockedMessage)
    }
}
