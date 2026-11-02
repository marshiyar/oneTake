import Foundation
import XCTest
@testable import MpvfxShared

/// Issue #457: several grade layers on one clip. Layers are `color-grading` effects in `clip.effects` (see
/// `NativeGradeLayers`), so the saved form of a one-grade project is unchanged.
final class NativeGradeLayerTests: XCTestCase {
    func document(effects: String) -> String {
        #"""
        {"schemaVersion":1,"mediaEngine":"native","id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"m.mov","source":"m.mov","durationFrames":30}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"video","clips":[
          {"id":"clip:a","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,
           "effects":\#(effects),"parameterTracks":[]}]}]}}
        """#
    }
    func parse(_ text: String) throws -> NativeProjectDocument { try parseNativeProjectDocument(try NativeJSONValue.parse(text)) }
    func clip(_ d: NativeProjectDocument) -> NativeProjectClip { d.sequence.tracks[0].clips[0] }

    func grade(_ id: String, _ enabled: Bool, _ exposure: Double) -> String {
        #"{"id":"\#(id)","effectId":"color-grading","enabled":\#(enabled),"parameters":{"adjust":{"exposure":\#(exposure)}}}"#
    }

    /// A one-grade project opens as one layer and saves the same bytes (no migration, no schemaVersion change).
    func testAProjectWithOneGradeOpensAsOneLayerAndSavesUnchanged() throws {
        let once = try serializeNativeProjectDocument(try parse(document(effects: "[\(grade("g", true, 0.5))]")))
        let twice = try serializeNativeProjectDocument(try parse(once))
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.contains(#""schemaVersion": 1"#))
        XCTAssertEqual(NativeGradeLayers.layers(clip(try parse(once))).map(\.id), ["g"])
    }

    func testAProjectWithNoGradeSavesUnchangedAndHasNoLayers() throws {
        let once = try serializeNativeProjectDocument(try parse(document(effects: "[]")))
        XCTAssertEqual(once, try serializeNativeProjectDocument(try parse(once)))
        XCTAssertFalse(once.contains("color-grading"))
        XCTAssertTrue(NativeGradeLayers.layers(clip(try parse(once))).isEmpty)
    }

    /// Order and the enable flag of several layers round-trip through project.json.
    func testSeveralLayersKeepOrderAndEnableFlagThroughSaveAndOpen() throws {
        let text = document(effects: "[\(grade("g1", true, 0.1)),\(grade("g2", false, 0.2)),\(grade("g3", true, 0.3))]")
        let saved = try serializeNativeProjectDocument(try parse(text))
        let layers = NativeGradeLayers.layers(clip(try parse(saved)))
        XCTAssertEqual(layers.map(\.id), ["g1", "g2", "g3"])
        XCTAssertEqual(layers.map(\.enabled), [true, false, true])
        XCTAssertEqual(NativeGradeLayers.enabledLayers(clip(try parse(saved))).map(\.id), ["g1", "g3"])
        XCTAssertEqual(NativeGradeParameter.gradeEffect(clip(try parse(saved)))?.id, "g1", "the first layer stays the clip's grade")
    }

    func testValidationRejectsMoreThanTheLimitAndDuplicateLayerIds() throws {
        let many = (0...NativeGradeLayers.maxLayers).map { grade("g\($0)", true, 0.1) }.joined(separator: ",")
        XCTAssertThrowsError(try parse(document(effects: "[\(many)]")))
        let ok = (0..<NativeGradeLayers.maxLayers).map { grade("g\($0)", true, 0.1) }.joined(separator: ",")
        XCTAssertNoThrow(try parse(document(effects: "[\(ok)]")))
        XCTAssertThrowsError(try parse(document(effects: "[\(grade("x", true, 0)),\(grade("x", true, 0))]")))
    }

    func testAddMoveToggleAndRemoveKeepTheOtherEffects() throws {
        let keyEffect = #"{"id":"fx","effectId":"other-effect","enabled":false}"#
        var c = clip(try parse(document(effects: "[\(keyEffect),\(grade("g1", true, 0.1))]")))
        XCTAssertTrue(NativeGradeLayers.add(to: &c))
        XCTAssertEqual(NativeGradeLayers.layers(c).map(\.id), ["g1", "effect:grade-1"])
        XCTAssertTrue(NativeGradeLayers.move(layerId: "effect:grade-1", to: 0, in: &c))
        XCTAssertEqual(c.effects.map(\.id), ["fx", "effect:grade-1", "g1"], "another effect keeps its place")
        XCTAssertFalse(NativeGradeLayers.move(layerId: "effect:grade-1", to: 0, in: &c))
        XCTAssertTrue(NativeGradeLayers.setEnabled(false, layerId: "g1", in: &c))
        XCTAssertFalse(NativeGradeLayers.setEnabled(false, layerId: "g1", in: &c))
        XCTAssertTrue(NativeGradeLayers.remove(layerId: "effect:grade-1", from: &c))
        XCTAssertEqual(c.effects.map(\.id), ["fx", "g1"])
        while NativeGradeLayers.add(to: &c) {}
        XCTAssertEqual(NativeGradeLayers.layers(c).count, NativeGradeLayers.maxLayers)
    }
}
