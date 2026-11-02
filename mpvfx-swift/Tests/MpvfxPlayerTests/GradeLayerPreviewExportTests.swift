import XCTest
@testable import MpvfxPlayer
import MpvfxColor
import MpvfxShared
import OneTakeKeyframes

/// Issue #457: preview and export grade a clip's layers through the one renderer `PreviewComposition.layers(at:)`
/// hands both (`PreviewGrader.gradeNow` for the export painter, the same `render` for the preview grader), so the
/// layers, their order and their enable flags give the same pixels in both.
final class GradeLayerPreviewExportTests: XCTestCase {
    func composition(effects: String) throws -> PreviewComposition {
        let engine = try KeyframeRuntime()
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"m.mov","source":"m.mov","durationFrames":30}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"video","clips":[
          {"id":"clip:a","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,
           "effects":\#(effects),"parameterTracks":[]}]}]}}
        """#), engine: engine)
        return PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/project"), engine: engine, fileExists: { _ in true })
    }
    func g(_ id: String, _ enabled: Bool, _ key: String, _ v: Double) -> String {
        #"{"id":"\#(id)","effectId":"color-grading","enabled":\#(enabled),"parameters":{"adjust":{"\#(key)":\#(v)}}}"#
    }
    static func sample() -> [UInt8] {
        var out = [UInt8]()
        for i in 0..<64 {
            out.append(UInt8(30 + i * 3)); out.append(UInt8(90 + i)); out.append(UInt8(200 - i * 2)); out.append(255)
        }
        return out
    }
    var source: [UInt8] { Self.sample() }

    func graded(_ comp: PreviewComposition) throws -> [UInt8]? {
        guard let grade = comp.layers(at: 0.1).first?.grade else { return nil }
        var px = source
        grade.render(&px, width: 8, height: 8, time: 0.1, using: CPUColorRenderer())
        return px
    }

    func testTheCompositionGradesEveryEnabledLayerInOrder() throws {
        let both = try XCTUnwrap(try graded(try composition(effects: "[\(g("g1", true, "exposure", 0.8)),\(g("g2", true, "contrast", 0.9))]")))
        let first = try XCTUnwrap(try graded(try composition(effects: "[\(g("g1", true, "exposure", 0.8))]")))
        let swapped = try XCTUnwrap(try graded(try composition(effects: "[\(g("g2", true, "contrast", 0.9)),\(g("g1", true, "exposure", 0.8))]")))
        XCTAssertNotEqual(both, first)
        XCTAssertNotEqual(both, swapped)
        // Layer by layer, as separate gradings one after the other.
        var manual = source
        for (key, v) in [("exposure", 0.8), ("contrast", 0.9)] {
            let p = try XCTUnwrap(ColorGradeParams(json: ["adjust": .object([key: .number(v)])]))
            ColorGradeRenderer(params: p, seedKey: "x").apply(&manual, width: 8, height: 8, time: 0.1)
        }
        XCTAssertEqual(both, manual)
    }

    func testASwitchedOffLayerDrawsNothingAndAllOffMeansNoGrade() throws {
        let off = try graded(try composition(effects: "[\(g("g1", true, "exposure", 0.8)),\(g("g2", false, "contrast", 0.9))]"))
        XCTAssertEqual(off, try graded(try composition(effects: "[\(g("g1", true, "exposure", 0.8))]")))
        XCTAssertNil(try graded(try composition(effects: "[\(g("g1", false, "exposure", 0.8))]")))
    }

    func testALaterLayerStillDrawsWhenTheFirstIsSwitchedOff() throws {
        XCTAssertEqual(try graded(try composition(effects: "[\(g("g1", false, "exposure", 0.8)),\(g("g2", true, "contrast", 0.9))]")),
                       try graded(try composition(effects: "[\(g("g2", true, "contrast", 0.9))]")))
    }
}
