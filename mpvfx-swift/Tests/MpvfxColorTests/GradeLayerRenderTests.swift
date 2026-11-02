import XCTest
@testable import MpvfxColor
import MpvfxShared

/// Issue #457: the renderer applies the grade layers in order, through the one `render` every consumer calls.
final class GradeLayerRenderTests: XCTestCase {
    func params(_ s: String) -> ColorGradeParams {
        let v = try! JSONDecoder().decode(NativeJSONValue.self, from: Data(s.utf8))
        guard case .object(let o) = v else { fatalError() }
        return ColorGradeParams(json: o)!
    }
    func renderer(_ s: String, following: [ColorGradeRenderer] = []) -> ColorGradeRenderer {
        ColorGradeRenderer(params: params(s), seedKey: "c", following: following)
    }
    static let exposure = #"{"adjust":{"exposure":0.8}}"#
    static let contrast = #"{"adjust":{"contrast":0.9}}"#
    static func sample() -> [UInt8] {
        var out = [UInt8]()
        for i in 0..<64 {
            out.append(UInt8(30 + i * 3)); out.append(UInt8(90 + i)); out.append(UInt8(200 - i * 2)); out.append(255)
        }
        return out
    }
    var pixels: [UInt8] { Self.sample() }
    func run(_ r: ColorGradeRenderer) -> [UInt8] { var p = pixels; r.render(&p, width: 8, height: 8, time: 0, using: CPUColorRenderer()); return p }

    func testLayersApplyOneAfterTheOtherInOrder() {
        let stacked = run(renderer(Self.exposure, following: [renderer(Self.contrast)]))
        var manual = pixels
        renderer(Self.exposure).apply(&manual, width: 8, height: 8, time: 0)
        renderer(Self.contrast).apply(&manual, width: 8, height: 8, time: 0)
        XCTAssertEqual(stacked, manual)
        XCTAssertNotEqual(stacked, run(renderer(Self.exposure)), "the second layer changes the picture")
    }

    func testTheOrderOfLayersChangesThePicture() {
        let ab = run(renderer(Self.exposure, following: [renderer(Self.contrast)]))
        let ba = run(renderer(Self.contrast, following: [renderer(Self.exposure)]))
        XCTAssertNotEqual(ab, ba)
    }

    func testASingleLayerIsUnchangedAndTheSignatureCoversTheStack() {
        let one = renderer(Self.exposure)
        XCTAssertTrue(one.following.isEmpty)
        XCTAssertNotEqual(one.signature, renderer(Self.exposure, following: [renderer(Self.contrast)]).signature)
        XCTAssertNotEqual(renderer(Self.exposure, following: [renderer(Self.contrast)]).signature,
                          renderer(Self.contrast, following: [renderer(Self.exposure)]).signature)
    }
}
