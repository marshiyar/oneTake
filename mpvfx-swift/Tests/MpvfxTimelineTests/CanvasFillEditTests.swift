import XCTest
import MpvfxShared
import OneTakeKeyframes
@testable import MpvfxTimeline

/// Canvas fill edits are one undo step each, saved with the document, and refused when the document would not take them.
final class CanvasFillEditTests: XCTestCase {
    func editor() throws -> TimelineEditor { try TimelineEditor(json: CompositionSizeTests.json, engine: KeyframeRuntime()) }

    func testSettingTheProjectFillIsOneUndoStepAndSurvivesReopening() throws {
        let e = try editor()
        let fill = NativeFill(kind: "color", color: "#112233")
        XCTAssertTrue(e.setCompositionCanvasFill(fill))
        XCTAssertEqual(e.document.compositionFill, fill)
        XCTAssertFalse(e.setCompositionCanvasFill(fill), "the same fill is no edit")
        let reopened = try TimelineEditor(json: try serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
        XCTAssertEqual(reopened.document.compositionFill?.color, "#112233")
        _ = e.undo()
        XCTAssertNil(e.document.compositionFill, "one undo removes it")
    }

    func testAClipFillIsOneUndoStepAndABadFillIsRefused() throws {
        let e = try editor()
        XCTAssertTrue(e.setClipCanvasFill(clipId: "natural", NativeFill(kind: "blur", blur: 30)))
        XCTAssertEqual(e.clip("natural")?.clip.fill?.blur, 30)
        XCTAssertFalse(e.setClipCanvasFill(clipId: "natural", NativeFill(kind: "blur", blur: 999)), "out of range")
        XCTAssertFalse(e.setClipCanvasFill(clipId: "missing", NativeFill(kind: "none")))
        XCTAssertFalse(e.setCompositionCanvasFill(NativeFill(kind: "image", assetId: "sq")), "a video is not an image fill")
        XCTAssertEqual(e.clip("natural")?.clip.fill?.blur, 30)
        _ = e.undo()
        XCTAssertNil(e.clip("natural")?.clip.fill)
    }
}
